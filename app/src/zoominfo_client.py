"""
ZoomInfo GTM API client for use inside a Snowflake Native App.

Authentication uses ZoomInfo's OAuth 2.0 **Client Credentials** flow: one
`client_id`/`client_secret` (supplied by the consumer, per ZoomInfo account) is
exchanged directly for an access token — no interactive user sign-in, no PKCE.
This mirrors ZoomInfo's own connector pattern (e.g. the Fivetran ZoomInfo
connector). Each consumer binds THEIR OWN ZoomInfo API credentials, so calls are
attributed to that consumer's ZoomInfo account (account-level, not per end user).

  POST https://api.zoominfo.com/gtm/oauth/v1/token
    Authorization: Basic base64(client_id:client_secret)
    Content-Type: application/x-www-form-urlencoded
    body: grant_type=client_credentials
  Response: {access_token, expires_in}   (no refresh token — just re-request)

The data procedures read a cached account token and call the GTM data API; on
401/expiry they re-fetch the token. `requests` is available in the Snowflake
Anaconda channel and declared in the procedure PACKAGES list.
"""

import base64
import json
import time

import requests

TOKEN_URL = "https://api.zoominfo.com/gtm/oauth/v1/token"
GTM_BASE_URL = "https://api.zoominfo.com/gtm"

# Re-authenticate this many seconds before a token's stated expiry so an
# in-flight request never races the expiry boundary.
_REFRESH_SKEW_SECONDS = 60


class ZoomInfoError(Exception):
    """Raised when a ZoomInfo API call fails. Carries the HTTP status."""

    def __init__(self, status_code, message):
        self.status_code = status_code
        super().__init__(f"ZoomInfo API error {status_code}: {message}")


# ZoomInfo error bodies are JSON:API `{"error":..., "error_description":...}` or
# `{"errors":[...]}`. We surface a short, non-sensitive summary rather than the raw
# body, so tokens / PII / internal detail never reach a Snowflake error message.
_MAX_DETAIL = 300


def _safe_error_detail(text):
    """Extract a bounded, non-sensitive detail string from a response body.

    Prefers the standard OAuth/JSON:API error fields; falls back to a truncated
    snippet. Never returns access tokens or full bodies.
    """
    if not text:
        return ""
    try:
        obj = json.loads(text)
    except ValueError:
        return text[:_MAX_DETAIL]
    if isinstance(obj, dict):
        # OAuth-style
        for k in ("error_description", "error", "message", "detail"):
            v = obj.get(k)
            if isinstance(v, str) and v:
                return v[:_MAX_DETAIL]
        # JSON:API errors array
        errs = obj.get("errors")
        if isinstance(errs, list) and errs:
            first = errs[0]
            if isinstance(first, dict):
                v = first.get("detail") or first.get("title")
                if isinstance(v, str) and v:
                    return v[:_MAX_DETAIL]
    return ""


# --------------------------------------------------------------------------- #
# Token endpoint (Client Credentials)
# --------------------------------------------------------------------------- #

def _basic_auth_header(client_id, client_secret):
    raw = f"{client_id}:{client_secret}".encode("utf-8")
    return "Basic " + base64.b64encode(raw).decode("ascii")


def get_access_token(cfg):
    """Fetch a fresh account access token via the Client Credentials grant.

    `cfg` must contain `client_id` and `client_secret`. Returns the parsed token
    response dict: {access_token, expires_in, ...}.
    """
    headers = {
        "Authorization": _basic_auth_header(cfg["client_id"], cfg["client_secret"]),
        "Content-Type": "application/x-www-form-urlencoded",
        "Accept": "application/json",
    }
    resp = requests.post(
        TOKEN_URL,
        headers=headers,
        data={"grant_type": "client_credentials"},
        timeout=30,
    )
    if not resp.ok:
        # The token endpoint's body can reflect credential context — surface only
        # a bounded, safe detail (e.g. the OAuth error_description).
        raise ZoomInfoError(
            resp.status_code,
            f"authentication failed — check client_id/client_secret and that the "
            f"client_credentials grant is enabled. {_safe_error_detail(resp.text)}".strip(),
        )
    try:
        return json.loads(resp.text)
    except ValueError:
        raise ZoomInfoError(resp.status_code, "unexpected (non-JSON) token response.")


def token_expires_at(token_response, now=None):
    """Absolute epoch expiry from a token response's `expires_in` (seconds)."""
    now = int(time.time()) if now is None else now
    try:
        return now + int(token_response["expires_in"])
    except (KeyError, ValueError, TypeError):
        return now + 3600


# --------------------------------------------------------------------------- #
# Data client
# --------------------------------------------------------------------------- #

class ZoomInfoClient:
    """Thin HTTP client for the ZoomInfo GTM data API.

    Constructed with a current `access_token` and a `token_refresher` callback.
    On a 401 the client invokes the refresher exactly once to obtain a fresh
    access token, then retries the request. The refresher must return the new
    access token string (and is responsible for caching it).
    """

    def __init__(self, access_token, token_refresher=None, base_url=GTM_BASE_URL):
        self._access_token = access_token
        self._refresher = token_refresher
        self._base_url = base_url.rstrip("/")

    def _headers(self, json_body=True):
        # ZoomInfo's GTM endpoints are JSON:API — they require the
        # application/vnd.api+json media type and return 406 for plain
        # application/json. GET requests send Accept only (no Content-Type).
        headers = {
            "Authorization": f"Bearer {self._access_token}",
            "Accept": "application/vnd.api+json",
        }
        if json_body:
            headers["Content-Type"] = "application/vnd.api+json"
        return headers

    def _request(self, method, path, body=None, params=None, max_retries=3):
        """Issue a request, refreshing once on 401 and backing off on 429.

        Returns the parsed JSON response; raises ZoomInfoError otherwise.
        """
        url = f"{self._base_url}{path}"
        attempt = 0
        refreshed = False
        while True:
            if method == "POST":
                resp = requests.post(
                    url,
                    headers=self._headers(json_body=True),
                    data=json.dumps(body),
                    params=params or {},
                    timeout=60,
                )
            else:  # GET
                resp = requests.get(
                    url,
                    headers=self._headers(json_body=False),
                    params=params or {},
                    timeout=60,
                )
            if resp.status_code == 401 and self._refresher and not refreshed:
                # Access token likely expired; refresh once and retry.
                self._access_token = self._refresher()
                refreshed = True
                continue
            if resp.status_code == 429 and attempt < max_retries:
                retry_after = resp.headers.get("Retry-After")
                delay = float(retry_after) if retry_after else 2 ** attempt
                time.sleep(delay)
                attempt += 1
                continue
            if not resp.ok:
                raise ZoomInfoError(resp.status_code, _safe_error_detail(resp.text))
            if not resp.text:
                return {}
            return json.loads(resp.text)

    def post(self, path, body, params=None, max_retries=3):
        """POST a JSON body to a GTM path (search / enrich endpoints)."""
        return self._request("POST", path, body=body, params=params, max_retries=max_retries)

    def get(self, path, params=None, max_retries=3):
        """GET a GTM path (lookup / usage endpoints)."""
        return self._request("GET", path, params=params, max_retries=max_retries)
