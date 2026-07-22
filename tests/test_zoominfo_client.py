"""Tests for zoominfo_client — token flow, headers, retries, error redaction."""
import base64
import json

import pytest

import zoominfo_client as zc


# --------------------------------------------------------------------------- #
# Fake requests transport
# --------------------------------------------------------------------------- #

class FakeResp:
    def __init__(self, status_code=200, body="", headers=None):
        self.status_code = status_code
        self.text = body if isinstance(body, str) else json.dumps(body)
        self.headers = headers or {}

    @property
    def ok(self):
        return 200 <= self.status_code < 300


class FakeRequests:
    """Records calls and returns queued responses; patched over zc.requests."""

    def __init__(self, responses):
        self._responses = list(responses)
        self.calls = []

    def _next(self, method, url, **kw):
        self.calls.append({"method": method, "url": url, **kw})
        return self._responses.pop(0)

    def post(self, url, **kw):
        return self._next("POST", url, **kw)

    def get(self, url, **kw):
        return self._next("GET", url, **kw)


@pytest.fixture
def patch_requests(monkeypatch):
    def _install(responses):
        fake = FakeRequests(responses)
        monkeypatch.setattr(zc, "requests", fake)
        return fake
    return _install


# --------------------------------------------------------------------------- #
# Token endpoint (Client Credentials)
# --------------------------------------------------------------------------- #

def test_get_access_token_sends_basic_auth_and_grant(patch_requests):
    fake = patch_requests([FakeResp(200, {"access_token": "AT", "expires_in": 3600})])
    tok = zc.get_access_token({"client_id": "CID", "client_secret": "SEC"})
    assert tok["access_token"] == "AT"
    call = fake.calls[0]
    assert call["url"] == zc.TOKEN_URL
    assert call["headers"]["Authorization"] == "Basic " + base64.b64encode(b"CID:SEC").decode()
    assert call["data"] == {"grant_type": "client_credentials"}
    assert call["headers"]["Content-Type"] == "application/x-www-form-urlencoded"


def test_get_access_token_error_is_redacted(patch_requests):
    # The token body must never be echoed verbatim; only the safe detail.
    patch_requests([FakeResp(400, {"error": "unauthorized_client",
                                   "error_description": "grant type not allowed"})])
    with pytest.raises(zc.ZoomInfoError) as ei:
        zc.get_access_token({"client_id": "CID", "client_secret": "SEC"})
    msg = str(ei.value)
    assert "grant type not allowed" in msg      # safe detail surfaced
    assert "unauthorized_client" not in msg     # raw error code not leaked
    assert ei.value.status_code == 400


def test_token_expires_at_uses_expires_in():
    assert zc.token_expires_at({"expires_in": 100}, now=1000) == 1100


def test_token_expires_at_defaults_on_missing():
    assert zc.token_expires_at({}, now=1000) == 1000 + 3600


# --------------------------------------------------------------------------- #
# _safe_error_detail
# --------------------------------------------------------------------------- #

def test_safe_error_detail_prefers_description():
    assert zc._safe_error_detail('{"error_description": "boom"}') == "boom"


def test_safe_error_detail_jsonapi_errors_array():
    assert zc._safe_error_detail('{"errors":[{"detail":"bad filter"}]}') == "bad filter"


def test_safe_error_detail_non_json_truncated():
    long = "x" * 1000
    out = zc._safe_error_detail(long)
    assert len(out) <= zc._MAX_DETAIL


def test_safe_error_detail_empty():
    assert zc._safe_error_detail("") == ""


# --------------------------------------------------------------------------- #
# Data client — headers, GET vs POST, retries
# --------------------------------------------------------------------------- #

def test_post_uses_jsonapi_headers(patch_requests):
    fake = patch_requests([FakeResp(200, {"data": []})])
    c = zc.ZoomInfoClient("AT")
    c.post("/data/v1/companies/search", {"data": {}})
    h = fake.calls[0]["headers"]
    assert h["Content-Type"] == "application/vnd.api+json"
    assert h["Accept"] == "application/vnd.api+json"
    assert h["Authorization"] == "Bearer AT"


def test_get_sends_accept_only_no_content_type(patch_requests):
    fake = patch_requests([FakeResp(200, {"data": {}})])
    c = zc.ZoomInfoClient("AT")
    c.get("/data/v1/users/usage")
    h = fake.calls[0]["headers"]
    assert h["Accept"] == "application/vnd.api+json"
    assert "Content-Type" not in h


def test_post_refreshes_once_on_401(patch_requests):
    fake = patch_requests([FakeResp(401), FakeResp(200, {"data": [1]})])
    calls = {"n": 0}

    def refresher():
        calls["n"] += 1
        return "NEW_TOKEN"

    c = zc.ZoomInfoClient("OLD", token_refresher=refresher)
    out = c.post("/data/v1/companies/search", {"data": {}})
    assert out == {"data": [1]}
    assert calls["n"] == 1
    # second attempt used the refreshed token
    assert fake.calls[1]["headers"]["Authorization"] == "Bearer NEW_TOKEN"


def test_post_does_not_refresh_twice(patch_requests):
    patch_requests([FakeResp(401), FakeResp(401)])

    def refresher():
        return "NEW"

    c = zc.ZoomInfoClient("OLD", token_refresher=refresher)
    with pytest.raises(zc.ZoomInfoError) as ei:
        c.post("/x", {})
    assert ei.value.status_code == 401


def test_post_retries_on_429_then_succeeds(patch_requests, monkeypatch):
    monkeypatch.setattr(zc.time, "sleep", lambda *_: None)  # don't actually sleep
    patch_requests([FakeResp(429, headers={"Retry-After": "0"}),
                    FakeResp(200, {"data": "ok"})])
    c = zc.ZoomInfoClient("AT")
    assert c.post("/x", {}) == {"data": "ok"}


def test_post_error_is_redacted(patch_requests):
    patch_requests([FakeResp(422, {"errors": [{"detail": "invalid field foo"}]})])
    c = zc.ZoomInfoClient("AT")
    with pytest.raises(zc.ZoomInfoError) as ei:
        c.post("/x", {})
    assert "invalid field foo" in str(ei.value)
    assert ei.value.status_code == 422


def test_post_empty_body_returns_empty_dict(patch_requests):
    patch_requests([FakeResp(200, "")])
    c = zc.ZoomInfoClient("AT")
    assert c.post("/x", {}) == {}
