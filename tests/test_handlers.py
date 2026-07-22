"""Tests for handlers — input validation, paging, and health check."""
import pytest

import handlers
import zoominfo_client as zc


# --------------------------------------------------------------------------- #
# _as_list / _check_criteria / _page_params
# --------------------------------------------------------------------------- #

def test_as_list_normalizes():
    assert handlers._as_list(None) == []
    assert handlers._as_list({"a": 1}) == [{"a": 1}]
    assert handlers._as_list([1, 2]) == [1, 2]


def test_check_criteria_accepts_dict_and_none():
    assert handlers._check_criteria(None) == {}
    assert handlers._check_criteria({"companyName": "x"}) == {"companyName": "x"}


def test_check_criteria_rejects_non_object():
    with pytest.raises(ValueError):
        handlers._check_criteria(["not", "a", "dict"])


def test_page_params_caps_at_100():
    p = handlers._page_params(1, 99999)
    assert p["page[size]"] == handlers._MAX_PAGE_SIZE == 100
    assert p["page[number]"] == 1


def test_page_params_passthrough_small():
    assert handlers._page_params(2, 25) == {"page[number]": 2, "page[size]": 25}


def test_page_params_rejects_bad_values():
    with pytest.raises(ValueError):
        handlers._page_params(0, 10)
    with pytest.raises(ValueError):
        handlers._page_params(1, 0)


# --------------------------------------------------------------------------- #
# enrich input caps
# --------------------------------------------------------------------------- #

def test_enrich_contact_requires_input(fake_session):
    with pytest.raises(ValueError):
        handlers.enrich_contact(fake_session(), [], [])


def test_enrich_contact_rejects_over_25(fake_session):
    with pytest.raises(ValueError):
        handlers.enrich_contact(fake_session(), [{"e": i} for i in range(26)], [])


# --------------------------------------------------------------------------- #
# _oauth_cfg
# --------------------------------------------------------------------------- #

def test_oauth_cfg_reads_secret(snowflake_stub):
    snowflake_stub._secret = '{"client_id": "A", "client_secret": "B"}'
    cfg = handlers._oauth_cfg()
    assert cfg == {"client_id": "A", "client_secret": "B"}


def test_oauth_cfg_missing_field_raises(snowflake_stub):
    snowflake_stub._secret = '{"client_id": "A"}'
    with pytest.raises(ValueError) as ei:
        handlers._oauth_cfg()
    assert "client_secret" in str(ei.value)


# --------------------------------------------------------------------------- #
# test_connection health check
# --------------------------------------------------------------------------- #

def test_connection_ok(monkeypatch, fake_session, snowflake_stub):
    snowflake_stub._secret = '{"client_id": "A", "client_secret": "B"}'
    monkeypatch.setattr(zc, "get_access_token", lambda cfg: {"access_token": "AT", "expires_in": 3600})
    monkeypatch.setattr(zc.ZoomInfoClient, "get", lambda self, path, params=None: {"data": {"usage": []}})
    out = handlers.test_connection(fake_session())
    assert out["status"] == "ok"


def test_connection_reports_bad_credentials(monkeypatch, fake_session, snowflake_stub):
    snowflake_stub._secret = '{"client_id": "A", "client_secret": "B"}'

    def boom(cfg):
        raise zc.ZoomInfoError(401, "authentication failed")

    monkeypatch.setattr(zc, "get_access_token", boom)
    out = handlers.test_connection(fake_session())
    assert out["status"] == "error"
    assert "client_credentials" in out["message"]  # actionable hint present


def test_connection_reports_unbound_secret(monkeypatch, fake_session):
    def boom():
        raise ValueError("no secret")

    monkeypatch.setattr(handlers, "_oauth_cfg", boom)
    out = handlers.test_connection(fake_session())
    assert out["status"] == "error"
    assert "not bound" in out["message"]
