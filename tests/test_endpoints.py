"""Tests for the new GTM endpoint handlers: correct path, JSON:API type, body shape."""
import pytest

import handlers


class SpyClient:
    """Captures the last post/get call instead of hitting the network."""

    def __init__(self):
        self.last = None

    def post(self, path, body, params=None):
        self.last = {"method": "POST", "path": path, "body": body, "params": params}
        return {"data": []}

    def get(self, path, params=None):
        self.last = {"method": "GET", "path": path, "params": params}
        return {"data": []}


@pytest.fixture
def spy(monkeypatch):
    client = SpyClient()
    monkeypatch.setattr(handlers, "_get_client", lambda session: client)
    return client


# --------------------------------------------------------------------------- #
# Search endpoints — path + JSON:API type + paging
# --------------------------------------------------------------------------- #

@pytest.mark.parametrize("fn,path,jsonapi_type", [
    (handlers.search_contact, "/data/v1/contacts/search", "ContactSearch"),
    (handlers.search_company, "/data/v1/companies/search", "CompanySearch"),
    (handlers.search_scoops, "/data/v1/scoops/search", "ScoopSearch"),
    (handlers.search_news, "/data/v1/news/search", "NewsSearch"),
    (handlers.search_intent, "/data/v1/intent/search", "IntentSearch"),
])
def test_search_routing(spy, fn, path, jsonapi_type):
    fn(object(), {"k": "v"}, 1, 50)
    assert spy.last["path"] == path
    assert spy.last["body"]["data"]["type"] == jsonapi_type
    assert spy.last["body"]["data"]["attributes"] == {"k": "v"}
    assert spy.last["params"]["page[size]"] == 50


# --------------------------------------------------------------------------- #
# Enrich endpoints — path + type + correct input key
# --------------------------------------------------------------------------- #

@pytest.mark.parametrize("fn,path,jsonapi_type,input_key", [
    (handlers.enrich_contact, "/data/v1/contacts/enrich", "ContactEnrich", "matchPersonInput"),
    (handlers.enrich_company, "/data/v1/companies/enrich", "CompanyEnrich", "matchCompanyInput"),
    (handlers.enrich_corporate_hierarchy, "/data/v1/companies/corporate-hierarchy/enrich",
     "CorporateHierarchyEnrich", "matchCompanyInput"),
])
def test_enrich_routing(spy, fn, path, jsonapi_type, input_key):
    fn(object(), [{"companyId": "1"}], ["name"])
    assert spy.last["path"] == path
    assert spy.last["body"]["data"]["type"] == jsonapi_type
    assert spy.last["body"]["data"]["attributes"][input_key] == [{"companyId": "1"}]
    assert spy.last["body"]["data"]["attributes"]["outputFields"] == ["name"]


def test_batch_enrich_rejects_empty_and_oversized(spy):
    with pytest.raises(ValueError):
        handlers.enrich_corporate_hierarchy(object(), [], [])
    with pytest.raises(ValueError):
        handlers.enrich_corporate_hierarchy(object(), [{"companyId": i} for i in range(26)], [])


def test_batch_enrich_omits_outputfields_when_none(spy):
    # corporate-hierarchy has no default fields — omit outputFields entirely if empty.
    handlers.enrich_corporate_hierarchy(object(), [{"companyId": "1"}], [])
    assert "outputFields" not in spy.last["body"]["data"]["attributes"]


# --------------------------------------------------------------------------- #
# Per-company enrich (scoops, technologies) — flat companyId, no matchCompanyInput
# --------------------------------------------------------------------------- #

@pytest.mark.parametrize("fn,path,jsonapi_type", [
    (handlers.enrich_scoops, "/data/v1/scoops/enrich", "ScoopEnrich"),
    (handlers.enrich_technologies, "/data/v1/companies/technologies/enrich", "TechnologyEnrich"),
])
def test_per_company_enrich_routing(spy, fn, path, jsonapi_type):
    fn(object(), "344589814")
    assert spy.last["path"] == path
    attrs = spy.last["body"]["data"]["attributes"]
    assert spy.last["body"]["data"]["type"] == jsonapi_type
    assert attrs == {"companyId": "344589814"}          # flat, not matchCompanyInput
    assert "matchCompanyInput" not in attrs
    assert "outputFields" not in attrs


def test_per_company_enrich_requires_id(spy):
    with pytest.raises(ValueError):
        handlers.enrich_scoops(object(), None)


# --------------------------------------------------------------------------- #
# intent-topics lookup (GET, no args)
# --------------------------------------------------------------------------- #

def test_lookup_intent_topics(spy):
    handlers.lookup_intent_topics(object())
    assert spy.last["method"] == "GET"
    assert spy.last["path"] == "/data/v1/lookup/intent-topics"
