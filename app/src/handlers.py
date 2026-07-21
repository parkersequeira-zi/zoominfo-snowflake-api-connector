"""
Snowpark procedure handlers for the ZoomInfo connector Native App.

Auth is OAuth 2.0 Authorization Code + PKCE. The interactive sign-in happens in
the "Connect ZoomInfo" Streamlit page, which stores each Snowflake user's
access/refresh tokens in app_state.oauth_tokens (keyed by CURRENT_USER). These
handlers:

  * load the CALLING user's stored tokens,
  * build a ZoomInfoClient that refreshes-on-401 (persisting ZoomInfo's rotated
    refresh token back to app_state.oauth_tokens),
  * build the JSON:API request body ZoomInfo's GTM endpoints expect,
  * call the endpoint and return the parsed JSON (a VARIANT in SQL).

The OAuth client config (client_id/secret/redirect_uri/scope) is read from the
consumer-bound secret, exposed to the procedure as `zoominfo_oauth_client` (see
the SECRETS clause in setup_script.sql). `_snowflake` is the module Snowflake
injects into Python handlers for secret access.
"""

import json
import time

import _snowflake

import zoominfo_client
from zoominfo_client import ZoomInfoClient

# Sensible defaults applied when the caller passes an empty outputFields list.
_DEFAULT_CONTACT_FIELDS = [
    "id", "firstName", "lastName", "email", "jobTitle",
    "phone", "companyId", "companyName",
]
_DEFAULT_COMPANY_FIELDS = [
    "id", "name", "website", "revenue", "employeeCount",
    "industries", "country", "ticker",
]

_TOKENS_TABLE = "app_state.oauth_tokens"


def _oauth_cfg():
    """Read the OAuth client config JSON from the bound secret."""
    raw = _snowflake.get_generic_secret_string("zoominfo_oauth_client")
    cfg = json.loads(raw)
    missing = [k for k in ("client_id", "client_secret", "redirect_uri") if not cfg.get(k)]
    if missing:
        raise ValueError(
            f"zoominfo_oauth_client is missing required field(s): {', '.join(missing)}. "
            "Expected a JSON object with client_id, client_secret, redirect_uri (and optional scope)."
        )
    return cfg


def _load_tokens(session):
    """Return the calling user's stored token row as a dict, or None if absent."""
    rows = session.sql(
        f"SELECT access_token, refresh_token, expires_at "
        f"FROM {_TOKENS_TABLE} WHERE sf_user = CURRENT_USER()"
    ).collect()
    if not rows:
        return None
    r = rows[0]
    return {
        "access_token": r["ACCESS_TOKEN"],
        "refresh_token": r["REFRESH_TOKEN"],
        "expires_at": r["EXPIRES_AT"],
    }


def _save_tokens(session, access_token, refresh_token, expires_at):
    """Upsert the calling user's tokens (keyed by CURRENT_USER)."""
    session.sql(
        f"MERGE INTO {_TOKENS_TABLE} t "
        f"USING (SELECT CURRENT_USER() AS sf_user) s "
        f"ON t.sf_user = s.sf_user "
        f"WHEN MATCHED THEN UPDATE SET "
        f"  access_token = ?, refresh_token = ?, expires_at = ?, updated_at = CURRENT_TIMESTAMP() "
        f"WHEN NOT MATCHED THEN INSERT (sf_user, access_token, refresh_token, expires_at, updated_at) "
        f"  VALUES (s.sf_user, ?, ?, ?, CURRENT_TIMESTAMP())",
        params=[access_token, refresh_token, expires_at,
                access_token, refresh_token, expires_at],
    ).collect()


def _get_client(session):
    """Build a ZoomInfoClient for the calling user, wired to refresh + persist.

    Raises a clear error if the user has not connected their ZoomInfo account yet.
    """
    tokens = _load_tokens(session)
    if not tokens or not tokens.get("access_token"):
        raise ValueError(
            "You are not connected to ZoomInfo. Open the app's 'Connect ZoomInfo' "
            "page, sign in, and paste the authorization code, then try again."
        )

    cfg = _oauth_cfg()

    def refresher():
        current = _load_tokens(session)
        if not current or not current.get("refresh_token"):
            raise ValueError(
                "Your ZoomInfo session expired and no refresh token is available. "
                "Reconnect on the 'Connect ZoomInfo' page."
            )
        tok = zoominfo_client.refresh(cfg, current["refresh_token"])
        # ZoomInfo rotates the refresh token; persist whatever it returns.
        _save_tokens(
            session,
            tok["access_token"],
            tok.get("refresh_token", current["refresh_token"]),
            zoominfo_client.token_expires_at(tok),
        )
        return tok["access_token"]

    access_token = tokens["access_token"]
    # Proactively refresh if we know the token is at/near expiry, avoiding a
    # guaranteed 401 round-trip.
    expires_at = tokens.get("expires_at")
    if expires_at is not None and int(expires_at) - zoominfo_client._REFRESH_SKEW_SECONDS <= int(time.time()):
        access_token = refresher()

    return ZoomInfoClient(access_token, token_refresher=refresher)


def _as_list(value):
    """Normalize a VARIANT arg (list, or a single object) into a list."""
    if value is None:
        return []
    if isinstance(value, list):
        return value
    return [value]


# --------------------------------------------------------------------------- #
# OAuth sign-in (called by the Connect ZoomInfo Streamlit page)
# These procedures hold the EAI + secret REFERENCE bindings; the Streamlit
# object itself needs no external access. begin_connect builds the PKCE
# authorize URL; connect_with_code exchanges the pasted code for tokens and
# stores them for the calling user.
# --------------------------------------------------------------------------- #

def begin_connect(session):
    """Return {authorize_url, verifier, state} to start the PKCE sign-in.

    The verifier is returned to the caller (the Streamlit page) so it can be
    passed back to connect_with_code — it must be the SAME verifier that produced
    the code_challenge in the authorize URL.
    """
    cfg = _oauth_cfg()
    verifier = zoominfo_client.make_code_verifier()
    state = zoominfo_client.make_state()
    return {
        "authorize_url": zoominfo_client.build_authorize_url(cfg, state=state, verifier=verifier),
        "verifier": verifier,
        "state": state,
    }


def connect_with_code(session, code, verifier):
    """Exchange an authorization code + PKCE verifier for tokens and store them."""
    if not code:
        raise ValueError("Authorization code is required.")
    if not verifier:
        raise ValueError("Missing PKCE verifier — restart the sign-in from the Connect page.")
    cfg = _oauth_cfg()
    tok = zoominfo_client.exchange_code(cfg, code, verifier)
    _save_tokens(
        session,
        tok["access_token"],
        tok.get("refresh_token"),
        zoominfo_client.token_expires_at(tok),
    )
    return {"status": "connected", "scope": tok.get("scope", "")}


# --------------------------------------------------------------------------- #
# Enrich
# --------------------------------------------------------------------------- #

def enrich_contact(session, match_input, output_fields):
    """Enrich up to 25 contacts. `match_input` is an array of match criteria."""
    inputs = _as_list(match_input)
    if not inputs:
        raise ValueError("match_input must contain at least one contact criteria object.")
    if len(inputs) > 25:
        raise ValueError("ZoomInfo enrich accepts at most 25 inputs per request.")

    fields = _as_list(output_fields) or _DEFAULT_CONTACT_FIELDS
    body = {
        "data": {
            "type": "ContactEnrich",
            "attributes": {
                "matchPersonInput": inputs,
                "outputFields": fields,
            },
        }
    }
    return _get_client(session).post("/data/v1/contacts/enrich", body)


def enrich_company(session, match_input, output_fields):
    """Enrich up to 25 companies. `match_input` is an array of match criteria."""
    inputs = _as_list(match_input)
    if not inputs:
        raise ValueError("match_input must contain at least one company criteria object.")
    if len(inputs) > 25:
        raise ValueError("ZoomInfo enrich accepts at most 25 inputs per request.")

    fields = _as_list(output_fields) or _DEFAULT_COMPANY_FIELDS
    body = {
        "data": {
            "type": "CompanyEnrich",
            "attributes": {
                "matchCompanyInput": inputs,
                "outputFields": fields,
            },
        }
    }
    return _get_client(session).post("/data/v1/companies/enrich", body)


# --------------------------------------------------------------------------- #
# Search
# --------------------------------------------------------------------------- #

def _page_params(page_number, page_size):
    params = {}
    if page_number:
        params["page[number]"] = int(page_number)
    if page_size:
        params["page[size]"] = int(page_size)
    return params


def search_contact(session, criteria, page_number, page_size):
    """Search for contacts. `criteria` is the search attributes object."""
    body = {
        "data": {
            "type": "ContactSearch",
            "attributes": criteria or {},
        }
    }
    params = _page_params(page_number, page_size)
    return _get_client(session).post("/data/v1/contacts/search", body, params=params)


def search_company(session, criteria, page_number, page_size):
    """Search for companies. `criteria` is the search attributes object."""
    body = {
        "data": {
            "type": "CompanySearch",
            "attributes": criteria or {},
        }
    }
    params = _page_params(page_number, page_size)
    return _get_client(session).post("/data/v1/companies/search", body, params=params)
