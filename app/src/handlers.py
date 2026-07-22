"""
Snowpark procedure handlers for the ZoomInfo connector Native App.

Auth is OAuth 2.0 **Client Credentials**: the consumer binds their own ZoomInfo
API credentials (client_id/client_secret) as a Snowflake SECRET, exposed to the
procedure as `zoominfo_oauth_client`. These handlers:

  * read the consumer's credentials from the bound secret,
  * obtain (and cache, in app_state.token_cache) an account-level access token,
  * build the JSON:API request body ZoomInfo's GTM endpoints expect,
  * call the endpoint and return the parsed JSON (a VARIANT in SQL).

There is no per-user sign-in and no per-user token storage — the token is
account-level (attributed to the consumer's ZoomInfo account). `_snowflake` is
the module Snowflake injects into Python handlers for secret access.
"""

import json
import logging
import time

import _snowflake

import zoominfo_client
from zoominfo_client import ZoomInfoClient

# Module logger. Snowflake routes this to the consumer's configured event table
# when logging is enabled. Only non-sensitive operational data is logged here
# (procedure/endpoint/status) — never criteria values, tokens, or PII.
_log = logging.getLogger("zoominfo_connector")

# Sensible defaults applied when the caller passes an empty outputFields list.
_DEFAULT_CONTACT_FIELDS = [
    "id", "firstName", "lastName", "email", "jobTitle",
    "phone", "companyId", "companyName",
]
_DEFAULT_COMPANY_FIELDS = [
    "id", "name", "website", "revenue", "employeeCount",
    "industries", "country", "ticker",
]

_TOKEN_CACHE_TABLE = "app_state.token_cache"


def _oauth_cfg():
    """Read the consumer's ZoomInfo API credentials from the bound secret.

    Expects a JSON object with client_id and client_secret (scope optional).
    """
    raw = _snowflake.get_generic_secret_string("zoominfo_oauth_client")
    cfg = json.loads(raw)
    missing = [k for k in ("client_id", "client_secret") if not cfg.get(k)]
    if missing:
        raise ValueError(
            f"zoominfo_oauth_client is missing required field(s): {', '.join(missing)}. "
            "Expected a JSON object with client_id and client_secret (scope optional)."
        )
    return cfg


# --------------------------------------------------------------------------- #
# Account token cache (single row in app_state.token_cache)
# --------------------------------------------------------------------------- #

def _load_cached_token(session):
    """Return {access_token, expires_at} from the cache, or None if absent."""
    rows = session.sql(
        f"SELECT access_token, expires_at FROM {_TOKEN_CACHE_TABLE} WHERE id = 1"
    ).collect()
    if not rows:
        return None
    r = rows[0]
    return {"access_token": r["ACCESS_TOKEN"], "expires_at": r["EXPIRES_AT"]}


def _store_token(session, access_token, expires_at):
    """Upsert the single cached account token row."""
    session.sql(
        f"MERGE INTO {_TOKEN_CACHE_TABLE} t "
        f"USING (SELECT 1 AS id) s ON t.id = s.id "
        f"WHEN MATCHED THEN UPDATE SET "
        f"  access_token = ?, expires_at = ?, updated_at = CURRENT_TIMESTAMP() "
        f"WHEN NOT MATCHED THEN INSERT (id, access_token, expires_at, updated_at) "
        f"  VALUES (1, ?, ?, CURRENT_TIMESTAMP())",
        params=[access_token, expires_at, access_token, expires_at],
    ).collect()


def _fetch_and_cache_token(session, cfg):
    """Fetch a fresh account token via Client Credentials and cache it."""
    tok = zoominfo_client.get_access_token(cfg)
    expires_at = zoominfo_client.token_expires_at(tok)
    _store_token(session, tok["access_token"], expires_at)
    return tok["access_token"]


def _get_client(session):
    """Build a ZoomInfoClient using a cached (or freshly fetched) account token.

    Refreshes proactively when the cached token is at/near expiry, and lazily
    (via the refresher callback) on a 401.
    """
    cfg = _oauth_cfg()

    def refresher():
        return _fetch_and_cache_token(session, cfg)

    cached = _load_cached_token(session)
    access_token = cached["access_token"] if cached else None
    expires_at = cached["expires_at"] if cached else None

    if (
        not access_token
        or expires_at is None
        or int(expires_at) - zoominfo_client._REFRESH_SKEW_SECONDS <= int(time.time())
    ):
        access_token = refresher()

    return ZoomInfoClient(access_token, token_refresher=refresher)


def _as_list(value):
    """Normalize a VARIANT arg (list, or a single object) into a list."""
    if value is None:
        return []
    if isinstance(value, list):
        return value
    return [value]


# ZoomInfo caps search page size at 100.
_MAX_PAGE_SIZE = 100


def _page_params(page_number, page_size):
    params = {}
    if page_number is not None:
        n = int(page_number)
        if n < 1:
            raise ValueError("page_number must be >= 1.")
        params["page[number]"] = n
    if page_size is not None:
        s = int(page_size)
        if s < 1:
            raise ValueError("page_size must be >= 1.")
        # Clamp to ZoomInfo's max rather than forwarding an oversized value that
        # the API would reject with an opaque error.
        params["page[size]"] = min(s, _MAX_PAGE_SIZE)
    return params


def _check_criteria(criteria):
    """Search criteria must be a JSON object (dict) or None/empty."""
    if criteria is None:
        return {}
    if not isinstance(criteria, dict):
        raise ValueError("criteria must be a JSON object of search attributes.")
    return criteria


# --------------------------------------------------------------------------- #
# Shared search / enrich (all GTM data endpoints are JSON:API)
# --------------------------------------------------------------------------- #

def _search(session, path, jsonapi_type, criteria, page_number, page_size):
    """POST a JSON:API search request and return the parsed response."""
    body = {"data": {"type": jsonapi_type, "attributes": _check_criteria(criteria)}}
    params = _page_params(page_number, page_size)
    _log.info("search %s", path)
    return _get_client(session).post(path, body, params=params)


def _enrich(session, path, jsonapi_type, input_key, match_input, output_fields, default_fields):
    """POST a JSON:API enrich request (<=25 inputs) and return the parsed response.

    `input_key` is the attribute name ZoomInfo expects for the match list
    (matchPersonInput for contacts, matchCompanyInput for company-scoped enrich).
    """
    inputs = _as_list(match_input)
    if not inputs:
        raise ValueError("match_input must contain at least one criteria object.")
    if len(inputs) > 25:
        raise ValueError("ZoomInfo enrich accepts at most 25 inputs per request.")
    fields = _as_list(output_fields) or (default_fields or [])
    attributes = {input_key: inputs}
    if fields:
        attributes["outputFields"] = fields
    body = {"data": {"type": jsonapi_type, "attributes": attributes}}
    _log.info("enrich %s (%d inputs)", path, len(inputs))
    return _get_client(session).post(path, body)


# --------------------------------------------------------------------------- #
# Enrich
# --------------------------------------------------------------------------- #

def enrich_contact(session, match_input, output_fields):
    """Enrich up to 25 contacts. `match_input` is an array of match criteria."""
    return _enrich(session, "/data/v1/contacts/enrich", "ContactEnrich",
                   "matchPersonInput", match_input, output_fields, _DEFAULT_CONTACT_FIELDS)


def enrich_company(session, match_input, output_fields):
    """Enrich up to 25 companies. `match_input` is an array of match criteria."""
    return _enrich(session, "/data/v1/companies/enrich", "CompanyEnrich",
                   "matchCompanyInput", match_input, output_fields, _DEFAULT_COMPANY_FIELDS)


def enrich_corporate_hierarchy(session, match_input, output_fields):
    """Enrich corporate hierarchy for up to 25 companies (batch, matchCompanyInput)."""
    return _enrich(session, "/data/v1/companies/corporate-hierarchy/enrich",
                   "CorporateHierarchyEnrich", "matchCompanyInput", match_input, output_fields, None)


def _enrich_per_company(session, path, jsonapi_type, company_id, params=None):
    """POST a per-company enrich request with a flat {companyId} attribute.

    Scoops and Technologies enrich are per-company (one companyId, not a
    matchCompanyInput batch) and take no outputFields — the API returns all
    fields. `company_id` is a single ZoomInfo company id.
    """
    if not company_id:
        raise ValueError("company_id is required.")
    body = {"data": {"type": jsonapi_type, "attributes": {"companyId": str(company_id)}}}
    _log.info("enrich %s (company)", path)
    return _get_client(session).post(path, body, params=params)


def enrich_scoops(session, company_id):
    """Enrich scoops for a single company (per-company; 1 credit)."""
    return _enrich_per_company(
        session, "/data/v1/scoops/enrich", "ScoopEnrich", company_id,
        params={"sort": "-originalPublishedDate"},
    )


def enrich_technologies(session, company_id):
    """Enrich the full technology stack for a single company (per-company)."""
    return _enrich_per_company(
        session, "/data/v1/companies/technologies/enrich", "TechnologyEnrich", company_id,
    )


# --------------------------------------------------------------------------- #
# Search
# --------------------------------------------------------------------------- #

def search_contact(session, criteria, page_number, page_size):
    """Search for contacts. `criteria` is the search attributes object."""
    return _search(session, "/data/v1/contacts/search", "ContactSearch",
                   criteria, page_number, page_size)


def search_company(session, criteria, page_number, page_size):
    """Search for companies. `criteria` is the search attributes object."""
    return _search(session, "/data/v1/companies/search", "CompanySearch",
                   criteria, page_number, page_size)


def search_scoops(session, criteria, page_number, page_size):
    """Search scoops (company signals). `criteria` is the search attributes object."""
    return _search(session, "/data/v1/scoops/search", "ScoopSearch",
                   criteria, page_number, page_size)


def search_news(session, criteria, page_number, page_size):
    """Search news. `criteria` is the search attributes object."""
    return _search(session, "/data/v1/news/search", "NewsSearch",
                   criteria, page_number, page_size)


def search_intent(session, criteria, page_number, page_size):
    """Search intent signals. `criteria` must include intent topic(s).

    Requires the Intent product; unlicensed accounts get a clean 403 from ZoomInfo.
    Use `lookup_intent_topics()` to discover valid topic names.
    """
    return _search(session, "/data/v1/intent/search", "IntentSearch",
                   criteria, page_number, page_size)


# --------------------------------------------------------------------------- #
# Lookup + Usage (GET, free — no credits)
# --------------------------------------------------------------------------- #

def lookup_search(session, entity, field_type):
    """Valid values/fields for building SEARCH criteria.

    `entity` e.g. 'company' or 'contact'; `field_type` e.g. 'input'. Use this to
    discover the taxonomy (industries, regions, job functions, …) that search
    criteria expect, instead of guessing.
    """
    if not entity:
        raise ValueError("entity is required (e.g. 'company' or 'contact').")
    params = {"filter[entity]": entity}
    if field_type:
        params["filter[fieldType]"] = field_type
    return _get_client(session).get("/data/v1/lookup/search", params=params)


def lookup_enrich(session, entity, field_type):
    """Available ENRICH output fields for an entity (and whether you have access).

    `entity` e.g. 'company', 'contact', 'corporate-hierarchy'; `field_type`
    defaults to 'output'. Use this to pick valid outputFields for enrich calls.
    """
    if not entity:
        raise ValueError("entity is required (e.g. 'company' or 'contact').")
    params = {"filter[entity]": entity, "filter[fieldType]": field_type or "output"}
    return _get_client(session).get("/data/v1/lookup/enrich", params=params)


def get_usage(session):
    """Return the account's current ZoomInfo API usage and limits (free)."""
    return _get_client(session).get("/data/v1/users/usage")


def lookup_intent_topics(session):
    """List the intent topics the account is licensed for (free).

    Use these topic names when building `search_intent` criteria.
    """
    return _get_client(session).get("/data/v1/lookup/intent-topics")


# --------------------------------------------------------------------------- #
# Health check
# --------------------------------------------------------------------------- #

def test_connection(session):
    """Verify the app is configured and can reach ZoomInfo, in plain language.

    Returns {"status": "ok", ...} on success, or {"status": "error", "message": ...}
    with an actionable message — so consumers can self-diagnose without reading a
    Python traceback. Makes one free /users/usage call.
    """
    try:
        cfg = _oauth_cfg()
    except Exception:
        return {
            "status": "error",
            "message": (
                "ZoomInfo API credentials are not bound. Bind the credentials secret "
                "(client_id/client_secret) to the app's 'ZoomInfo API credentials' reference."
            ),
        }
    try:
        usage = ZoomInfoClient(_fetch_and_cache_token(session, cfg)).get("/data/v1/users/usage")
        return {"status": "ok", "message": "Connected to ZoomInfo.", "usage": usage}
    except zoominfo_client.ZoomInfoError as exc:
        hint = ""
        if exc.status_code in (400, 401, 403):
            hint = (
                " Check the client_id/client_secret and that the ZoomInfo app has the "
                "client_credentials grant enabled."
            )
        return {"status": "error", "message": f"{exc}.{hint}"}
    except Exception as exc:  # noqa: BLE001 — surface a clean message, not a traceback
        return {"status": "error", "message": f"Unexpected error: {type(exc).__name__}: {exc}"}
