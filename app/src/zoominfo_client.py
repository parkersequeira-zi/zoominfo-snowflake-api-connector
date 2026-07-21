"""
ZoomInfo GTM API client for use inside a Snowflake Native App.

Authentication uses ZoomInfo's OAuth 2.0 **Authorization Code flow with PKCE**,
where an end user interactively signs in to their ZoomInfo account. Because a
Snowflake stored procedure has no browser, the interactive step happens in the
app's Streamlit "Connect ZoomInfo" page:

  1. The app builds an authorize URL with a PKCE `code_challenge` (base64url
     SHA256 of a locally generated `code_verifier`) and a `state` value, and the
     user opens it, signs in, and authorizes.
        GET https://api.zoominfo.com/gtm/oauth/v1/authorize
  2. ZoomInfo returns an authorization `code` (pasted back into the app).
  3. The app exchanges the code + `code_verifier` for tokens.
        POST https://api.zoominfo.com/gtm/oauth/v1/token
     Response: {access_token, expires_in, refresh_token, id_token, scope, ...}

The four data procedures do NOT sign in. They read the caller's stored
access token and call the GTM API; on 401/expiry they use the stored
`refresh_token` to obtain a fresh access token. ZoomInfo **rotates** refresh
tokens — each refresh returns a new refresh token and invalidates the old one —
so callers must persist whatever this module returns.

`requests` is available in the Snowflake Anaconda channel and declared in the
procedure PACKAGES list. No private key / JWT signing is used anymore.
"""

import base64
import hashlib
import json
import os
import time
from urllib.parse import urlencode

import requests

AUTHORIZE_URL = "https://api.zoominfo.com/gtm/oauth/v1/authorize"
TOKEN_URL = "https://api.zoominfo.com/gtm/oauth/v1/token"
GTM_BASE_URL = "https://api.zoominfo.com/gtm"

# Re-authenticate this many seconds before a token's stated expiry so an
# in-flight request never races the expiry boundary.
_REFRESH_SKEW_SECONDS = 60


class ZoomInfoError(Exception):
    """Raised when a ZoomInfo API call fails. Surfaces the HTTP status and body."""

    def __init__(self, status_code, message):
        self.status_code = status_code
        super().__init__(f"ZoomInfo API error {status_code}: {message}")


# --------------------------------------------------------------------------- #
# PKCE helpers
# --------------------------------------------------------------------------- #

def _b64url(raw):
    """base64url-encode bytes without padding, as required by PKCE (RFC 7636)."""
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def make_code_verifier():
    """Return a high-entropy, base64url code_verifier (43-128 chars per spec)."""
    return _b64url(os.urandom(64))


def make_state():
    """Return an opaque anti-CSRF state value."""
    return _b64url(os.urandom(24))


def code_challenge(verifier):
    """S256 challenge: base64url( SHA256( verifier ) )."""
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    return _b64url(digest)


def build_authorize_url(cfg, state, verifier, scope=None):
    """Build the ZoomInfo authorize URL the user opens to sign in.

    `cfg` is the OAuth client config dict (client_id, redirect_uri, and an
    optional default `scope`). `scope` overrides cfg's scope when provided.
    """
    params = {
        "client_id": cfg["client_id"],
        "redirect_uri": cfg["redirect_uri"],
        "response_type": "code",
        "code_challenge": code_challenge(verifier),
        "code_challenge_method": "S256",
        "state": state,
    }
    effective_scope = scope if scope is not None else cfg.get("scope")
    if effective_scope:
        params["scope"] = effective_scope
    return f"{AUTHORIZE_URL}?{urlencode(params)}"


# --------------------------------------------------------------------------- #
# Token endpoint (code exchange + refresh)
# --------------------------------------------------------------------------- #

def _basic_auth_header(client_id, client_secret):
    raw = f"{client_id}:{client_secret}".encode("utf-8")
    return "Basic " + base64.b64encode(raw).decode("ascii")


def _token_request(cfg, form):
    """POST to the token endpoint with HTTP Basic client auth; return parsed JSON."""
    headers = {
        "Authorization": _basic_auth_header(cfg["client_id"], cfg["client_secret"]),
        "Content-Type": "application/x-www-form-urlencoded",
        "Accept": "application/json",
    }
    resp = requests.post(TOKEN_URL, headers=headers, data=form, timeout=30)
    if not resp.ok:
        raise ZoomInfoError(resp.status_code, resp.text)
    try:
        return json.loads(resp.text)
    except ValueError as exc:
        raise ZoomInfoError(resp.status_code, f"unexpected token response: {resp.text}") from exc


def exchange_code(cfg, code, verifier):
    """Exchange an authorization code + PKCE verifier for the initial token set."""
    return _token_request(cfg, {
        "grant_type": "authorization_code",
        "code": code,
        "code_verifier": verifier,
        "redirect_uri": cfg["redirect_uri"],
    })


def refresh(cfg, refresh_token):
    """Exchange a refresh token for a new token set.

    ZoomInfo rotates refresh tokens: the response carries a NEW refresh_token
    and the one passed in is invalidated. Callers must persist the returned
    refresh_token.
    """
    return _token_request(cfg, {
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
    })


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
    access token, then retries the request. The refresher is responsible for
    persisting rotated tokens; it must return the new access token string.
    """

    def __init__(self, access_token, token_refresher=None, base_url=GTM_BASE_URL):
        self._access_token = access_token
        self._refresher = token_refresher
        self._base_url = base_url.rstrip("/")

    def _headers(self):
        return {
            "Authorization": f"Bearer {self._access_token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        }

    def post(self, path, body, params=None, max_retries=3):
        """POST a JSON body to a GTM path.

        Retries with backoff on 429 (honoring Retry-After) and refreshes once on
        401. Returns the parsed JSON response; raises ZoomInfoError otherwise.
        """
        url = f"{self._base_url}{path}"
        attempt = 0
        refreshed = False
        while True:
            resp = requests.post(
                url,
                headers=self._headers(),
                data=json.dumps(body),
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
                raise ZoomInfoError(resp.status_code, resp.text)
            if not resp.text:
                return {}
            return json.loads(resp.text)
