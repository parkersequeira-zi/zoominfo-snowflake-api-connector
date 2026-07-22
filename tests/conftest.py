"""Shared test fixtures: make the app/src modules importable off-Snowflake.

`handlers.py` imports `_snowflake` (injected by Snowflake at runtime). We register
a stub module so the import succeeds under pytest, then let individual tests set
the secret value it returns.
"""
import os
import sys
import types

import pytest

# Put app/src on the path so `import zoominfo_client` / `import handlers` work.
_SRC = os.path.join(os.path.dirname(__file__), "..", "app", "src")
sys.path.insert(0, os.path.abspath(_SRC))

# Stub the Snowflake-injected `_snowflake` module before handlers imports it.
_snowflake_stub = types.ModuleType("_snowflake")
_snowflake_stub._secret = '{"client_id": "CID", "client_secret": "SEC"}'


def _get_generic_secret_string(name):
    return _snowflake_stub._secret


_snowflake_stub.get_generic_secret_string = _get_generic_secret_string
sys.modules.setdefault("_snowflake", _snowflake_stub)


@pytest.fixture
def snowflake_stub():
    """Access/override the stubbed _snowflake secret in a test."""
    return _snowflake_stub


class FakeResult:
    """Mimics a Snowpark row-collection result for session.sql(...).collect()."""

    def __init__(self, rows):
        self._rows = rows

    def collect(self):
        return self._rows


class FakeSession:
    """Minimal Snowpark session double: records SQL, returns queued row-sets."""

    def __init__(self, results=None):
        self.executed = []
        self._results = list(results or [])

    def sql(self, query, params=None):
        self.executed.append((query, params))
        rows = self._results.pop(0) if self._results else []
        return FakeResult(rows)


@pytest.fixture
def fake_session():
    return FakeSession
