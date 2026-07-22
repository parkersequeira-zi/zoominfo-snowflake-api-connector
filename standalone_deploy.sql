-- =====================================================================
-- ZoomInfo Connector — STANDALONE deployment (no Native App framework)
--
-- Recreates the same objects the Native App's setup_script.sql builds, but
-- as ordinary account objects you own. Use this when the Native App install
-- path is blocked (e.g. trial account without app-create privileges).
--
-- Differences vs. the Native App:
--   * The consumer-bound SECRET + EXTERNAL ACCESS INTEGRATION "references"
--     become real, account-level objects you CREATE here (backed by a
--     NETWORK RULE for outbound HTTPS to api.zoominfo.com).
--   * There are no reference-binding callbacks (get_configuration /
--     register_reference / create_api_procedures*). The API procedures are
--     created directly, because the secret + EAI already exist.
--   * The Python modules zoominfo_client.py and handlers.py are INLINED into
--     each procedure body (there is no app /src stage to IMPORT from). The
--     handler bodies are unchanged logic; only the import wiring differs.
--
-- Auth model is identical: OAuth 2.0 Authorization Code + PKCE, per-user
-- tokens in APP_STATE.OAUTH_TOKENS keyed by CURRENT_USER().
--
-- Edit the placeholders in Section 0, then run top to bottom as a role with
-- CREATE DATABASE / INTEGRATION privileges (e.g. ACCOUNTADMIN, or a role with
-- CREATE INTEGRATION granted).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Placeholders — EDIT THESE
-- ---------------------------------------------------------------------
SET db_name          = 'ZOOMINFO_CONNECTOR';
SET app_role         = 'ZOOMINFO_APP_ROLE';   -- role that will call the procedures
SET zi_client_id     = '<YOUR_ZOOMINFO_CLIENT_ID>';
SET zi_client_secret = '<YOUR_ZOOMINFO_CLIENT_SECRET>';
SET zi_redirect_uri  = '<YOUR_REGISTERED_REDIRECT_URI>';
SET zi_scope         = '';                    -- optional OAuth scope string

-- ---------------------------------------------------------------------
-- 1. Database + schemas
--    CORE   — procedures + Streamlit (was the app's versioned schema)
--    APP_STATE — stateful per-user token store (regular schema)
-- ---------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS IDENTIFIER($db_name);
USE DATABASE IDENTIFIER($db_name);

CREATE SCHEMA IF NOT EXISTS CORE;
CREATE SCHEMA IF NOT EXISTS APP_STATE;

-- ---------------------------------------------------------------------
-- 2. Per-user OAuth token store (unchanged from setup_script.sql)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS APP_STATE.OAUTH_TOKENS (
  sf_user       STRING NOT NULL PRIMARY KEY,
  access_token  STRING,
  refresh_token STRING,
  expires_at    NUMBER,
  updated_at    TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ---------------------------------------------------------------------
-- 3. Outbound network access to ZoomInfo
--    NETWORK RULE + SECRET + EXTERNAL ACCESS INTEGRATION replace the
--    consumer-bound references the manifest declared.
-- ---------------------------------------------------------------------
CREATE OR REPLACE NETWORK RULE CORE.ZI_API_NETWORK_RULE
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('api.zoominfo.com');

-- The OAuth client config, stored as a JSON string (matches what the handler's
-- _oauth_cfg() expects: client_id, client_secret, redirect_uri, optional scope).
CREATE OR REPLACE SECRET CORE.ZI_OAUTH_CLIENT_SECRET
  TYPE = GENERIC_STRING
  SECRET_STRING = OBJECT_CONSTRUCT(
    'client_id',     $zi_client_id,
    'client_secret', $zi_client_secret,
    'redirect_uri',  $zi_redirect_uri,
    'scope',         $zi_scope
  )::STRING;

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION EXTERNAL_ACCESS_INTEGRATION_ZI_API
  ALLOWED_NETWORK_RULES = (CORE.ZI_API_NETWORK_RULE)
  ALLOWED_AUTHENTICATION_SECRETS = (CORE.ZI_OAUTH_CLIENT_SECRET)
  ENABLED = TRUE;

-- ---------------------------------------------------------------------
-- 4. Data + auth procedures
--    Same six procedures as the app. Because there is no app /src stage,
--    the two Python modules are inlined at the top of each handler body.
--    The secret is exposed to the handler as `zoominfo_oauth_client`.
-- ---------------------------------------------------------------------

-- 4a. enrich_contact ---------------------------------------------------
CREATE OR REPLACE PROCEDURE CORE.ENRICH_CONTACT(match_input VARIANT, output_fields ARRAY)
  RETURNS VARIANT
  LANGUAGE PYTHON
  RUNTIME_VERSION = '3.11'
  PACKAGES = ('snowflake-snowpark-python', 'requests')
  HANDLER = 'run'
  EXTERNAL_ACCESS_INTEGRATIONS = (EXTERNAL_ACCESS_INTEGRATION_ZI_API)
  SECRETS = ('zoominfo_oauth_client' = CORE.ZI_OAUTH_CLIENT_SECRET)
AS
$$
import base64, hashlib, json, os, time
from urllib.parse import urlencode
import requests
import _snowflake

AUTHORIZE_URL = "https://api.zoominfo.com/gtm/oauth/v1/authorize"
TOKEN_URL = "https://api.zoominfo.com/gtm/oauth/v1/token"
GTM_BASE_URL = "https://api.zoominfo.com/gtm"
_REFRESH_SKEW_SECONDS = 60
_TOKENS_TABLE = "APP_STATE.OAUTH_TOKENS"
_DEFAULT_CONTACT_FIELDS = ["id","firstName","lastName","email","jobTitle","phone","companyId","companyName"]

class ZoomInfoError(Exception):
    def __init__(self, status_code, message):
        self.status_code = status_code
        super().__init__(f"ZoomInfo API error {status_code}: {message}")

def _basic_auth_header(cid, csec):
    return "Basic " + base64.b64encode(f"{cid}:{csec}".encode("utf-8")).decode("ascii")

def _token_request(cfg, form):
    headers = {"Authorization": _basic_auth_header(cfg["client_id"], cfg["client_secret"]),
               "Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"}
    resp = requests.post(TOKEN_URL, headers=headers, data=form, timeout=30)
    if not resp.ok:
        raise ZoomInfoError(resp.status_code, resp.text)
    return json.loads(resp.text)

def zi_refresh(cfg, refresh_token):
    return _token_request(cfg, {"grant_type": "refresh_token", "refresh_token": refresh_token})

def token_expires_at(tr, now=None):
    now = int(time.time()) if now is None else now
    try:
        return now + int(tr["expires_in"])
    except (KeyError, ValueError, TypeError):
        return now + 3600

class ZoomInfoClient:
    def __init__(self, access_token, token_refresher=None, base_url=GTM_BASE_URL):
        self._access_token = access_token
        self._refresher = token_refresher
        self._base_url = base_url.rstrip("/")
    def _headers(self):
        return {"Authorization": f"Bearer {self._access_token}",
                "Content-Type": "application/json", "Accept": "application/json"}
    def post(self, path, body, params=None, max_retries=3):
        url = f"{self._base_url}{path}"
        attempt = 0; refreshed = False
        while True:
            resp = requests.post(url, headers=self._headers(), data=json.dumps(body),
                                 params=params or {}, timeout=60)
            if resp.status_code == 401 and self._refresher and not refreshed:
                self._access_token = self._refresher(); refreshed = True; continue
            if resp.status_code == 429 and attempt < max_retries:
                ra = resp.headers.get("Retry-After")
                time.sleep(float(ra) if ra else 2 ** attempt); attempt += 1; continue
            if not resp.ok:
                raise ZoomInfoError(resp.status_code, resp.text)
            return json.loads(resp.text) if resp.text else {}

def _oauth_cfg():
    cfg = json.loads(_snowflake.get_generic_secret_string("zoominfo_oauth_client"))
    missing = [k for k in ("client_id","client_secret","redirect_uri") if not cfg.get(k)]
    if missing:
        raise ValueError(f"zoominfo_oauth_client missing: {', '.join(missing)}")
    return cfg

def _load_tokens(session):
    rows = session.sql(f"SELECT access_token, refresh_token, expires_at FROM {_TOKENS_TABLE} WHERE sf_user = CURRENT_USER()").collect()
    if not rows: return None
    r = rows[0]
    return {"access_token": r["ACCESS_TOKEN"], "refresh_token": r["REFRESH_TOKEN"], "expires_at": r["EXPIRES_AT"]}

def _save_tokens(session, at, rt, exp):
    session.sql(f"MERGE INTO {_TOKENS_TABLE} t USING (SELECT CURRENT_USER() AS sf_user) s "
                f"ON t.sf_user = s.sf_user WHEN MATCHED THEN UPDATE SET access_token=?, refresh_token=?, expires_at=?, updated_at=CURRENT_TIMESTAMP() "
                f"WHEN NOT MATCHED THEN INSERT (sf_user, access_token, refresh_token, expires_at, updated_at) VALUES (s.sf_user, ?, ?, ?, CURRENT_TIMESTAMP())",
                params=[at, rt, exp, at, rt, exp]).collect()

def _get_client(session):
    tokens = _load_tokens(session)
    if not tokens or not tokens.get("access_token"):
        raise ValueError("Not connected to ZoomInfo. Run CONNECT_WITH_CODE first.")
    cfg = _oauth_cfg()
    def refresher():
        cur = _load_tokens(session)
        if not cur or not cur.get("refresh_token"):
            raise ValueError("Session expired and no refresh token. Reconnect.")
        tok = zi_refresh(cfg, cur["refresh_token"])
        _save_tokens(session, tok["access_token"], tok.get("refresh_token", cur["refresh_token"]), token_expires_at(tok))
        return tok["access_token"]
    at = tokens["access_token"]; exp = tokens.get("expires_at")
    if exp is not None and int(exp) - _REFRESH_SKEW_SECONDS <= int(time.time()):
        at = refresher()
    return ZoomInfoClient(at, token_refresher=refresher)

def _as_list(v):
    if v is None: return []
    return v if isinstance(v, list) else [v]

def run(session, match_input, output_fields):
    inputs = _as_list(match_input)
    if not inputs:
        raise ValueError("match_input must contain at least one contact criteria object.")
    if len(inputs) > 25:
        raise ValueError("ZoomInfo enrich accepts at most 25 inputs per request.")
    fields = _as_list(output_fields) or _DEFAULT_CONTACT_FIELDS
    body = {"data": {"type": "ContactEnrich", "attributes": {"matchPersonInput": inputs, "outputFields": fields}}}
    return _get_client(session).post("/data/v1/contacts/enrich", body)
$$;

-- 4b. enrich_company ---------------------------------------------------
CREATE OR REPLACE PROCEDURE CORE.ENRICH_COMPANY(match_input VARIANT, output_fields ARRAY)
  RETURNS VARIANT
  LANGUAGE PYTHON
  RUNTIME_VERSION = '3.11'
  PACKAGES = ('snowflake-snowpark-python', 'requests')
  HANDLER = 'run'
  EXTERNAL_ACCESS_INTEGRATIONS = (EXTERNAL_ACCESS_INTEGRATION_ZI_API)
  SECRETS = ('zoominfo_oauth_client' = CORE.ZI_OAUTH_CLIENT_SECRET)
AS
$$
import base64, hashlib, json, os, time
import requests
import _snowflake

TOKEN_URL = "https://api.zoominfo.com/gtm/oauth/v1/token"
GTM_BASE_URL = "https://api.zoominfo.com/gtm"
_REFRESH_SKEW_SECONDS = 60
_TOKENS_TABLE = "APP_STATE.OAUTH_TOKENS"
_DEFAULT_COMPANY_FIELDS = ["id","name","website","revenue","employeeCount","industries","country","ticker"]

class ZoomInfoError(Exception):
    def __init__(self, status_code, message):
        self.status_code = status_code
        super().__init__(f"ZoomInfo API error {status_code}: {message}")

def _basic_auth_header(cid, csec):
    return "Basic " + base64.b64encode(f"{cid}:{csec}".encode("utf-8")).decode("ascii")

def _token_request(cfg, form):
    headers = {"Authorization": _basic_auth_header(cfg["client_id"], cfg["client_secret"]),
               "Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"}
    resp = requests.post(TOKEN_URL, headers=headers, data=form, timeout=30)
    if not resp.ok:
        raise ZoomInfoError(resp.status_code, resp.text)
    return json.loads(resp.text)

def zi_refresh(cfg, refresh_token):
    return _token_request(cfg, {"grant_type": "refresh_token", "refresh_token": refresh_token})

def token_expires_at(tr, now=None):
    now = int(time.time()) if now is None else now
    try:
        return now + int(tr["expires_in"])
    except (KeyError, ValueError, TypeError):
        return now + 3600

class ZoomInfoClient:
    def __init__(self, access_token, token_refresher=None, base_url=GTM_BASE_URL):
        self._access_token = access_token
        self._refresher = token_refresher
        self._base_url = base_url.rstrip("/")
    def _headers(self):
        return {"Authorization": f"Bearer {self._access_token}",
                "Content-Type": "application/json", "Accept": "application/json"}
    def post(self, path, body, params=None, max_retries=3):
        url = f"{self._base_url}{path}"
        attempt = 0; refreshed = False
        while True:
            resp = requests.post(url, headers=self._headers(), data=json.dumps(body),
                                 params=params or {}, timeout=60)
            if resp.status_code == 401 and self._refresher and not refreshed:
                self._access_token = self._refresher(); refreshed = True; continue
            if resp.status_code == 429 and attempt < max_retries:
                ra = resp.headers.get("Retry-After")
                time.sleep(float(ra) if ra else 2 ** attempt); attempt += 1; continue
            if not resp.ok:
                raise ZoomInfoError(resp.status_code, resp.text)
            return json.loads(resp.text) if resp.text else {}

def _oauth_cfg():
    cfg = json.loads(_snowflake.get_generic_secret_string("zoominfo_oauth_client"))
    missing = [k for k in ("client_id","client_secret","redirect_uri") if not cfg.get(k)]
    if missing:
        raise ValueError(f"zoominfo_oauth_client missing: {', '.join(missing)}")
    return cfg

def _load_tokens(session):
    rows = session.sql(f"SELECT access_token, refresh_token, expires_at FROM {_TOKENS_TABLE} WHERE sf_user = CURRENT_USER()").collect()
    if not rows: return None
    r = rows[0]
    return {"access_token": r["ACCESS_TOKEN"], "refresh_token": r["REFRESH_TOKEN"], "expires_at": r["EXPIRES_AT"]}

def _save_tokens(session, at, rt, exp):
    session.sql(f"MERGE INTO {_TOKENS_TABLE} t USING (SELECT CURRENT_USER() AS sf_user) s "
                f"ON t.sf_user = s.sf_user WHEN MATCHED THEN UPDATE SET access_token=?, refresh_token=?, expires_at=?, updated_at=CURRENT_TIMESTAMP() "
                f"WHEN NOT MATCHED THEN INSERT (sf_user, access_token, refresh_token, expires_at, updated_at) VALUES (s.sf_user, ?, ?, ?, CURRENT_TIMESTAMP())",
                params=[at, rt, exp, at, rt, exp]).collect()

def _get_client(session):
    tokens = _load_tokens(session)
    if not tokens or not tokens.get("access_token"):
        raise ValueError("Not connected to ZoomInfo. Run CONNECT_WITH_CODE first.")
    cfg = _oauth_cfg()
    def refresher():
        cur = _load_tokens(session)
        if not cur or not cur.get("refresh_token"):
            raise ValueError("Session expired and no refresh token. Reconnect.")
        tok = zi_refresh(cfg, cur["refresh_token"])
        _save_tokens(session, tok["access_token"], tok.get("refresh_token", cur["refresh_token"]), token_expires_at(tok))
        return tok["access_token"]
    at = tokens["access_token"]; exp = tokens.get("expires_at")
    if exp is not None and int(exp) - _REFRESH_SKEW_SECONDS <= int(time.time()):
        at = refresher()
    return ZoomInfoClient(at, token_refresher=refresher)

def _as_list(v):
    if v is None: return []
    return v if isinstance(v, list) else [v]

def run(session, match_input, output_fields):
    inputs = _as_list(match_input)
    if not inputs:
        raise ValueError("match_input must contain at least one company criteria object.")
    if len(inputs) > 25:
        raise ValueError("ZoomInfo enrich accepts at most 25 inputs per request.")
    fields = _as_list(output_fields) or _DEFAULT_COMPANY_FIELDS
    body = {"data": {"type": "CompanyEnrich", "attributes": {"matchCompanyInput": inputs, "outputFields": fields}}}
    return _get_client(session).post("/data/v1/companies/enrich", body)
$$;

-- 4c. search_contact ---------------------------------------------------
CREATE OR REPLACE PROCEDURE CORE.SEARCH_CONTACT(criteria VARIANT, page_number INT, page_size INT)
  RETURNS VARIANT
  LANGUAGE PYTHON
  RUNTIME_VERSION = '3.11'
  PACKAGES = ('snowflake-snowpark-python', 'requests')
  HANDLER = 'run'
  EXTERNAL_ACCESS_INTEGRATIONS = (EXTERNAL_ACCESS_INTEGRATION_ZI_API)
  SECRETS = ('zoominfo_oauth_client' = CORE.ZI_OAUTH_CLIENT_SECRET)
AS
$$
import base64, json, time
import requests
import _snowflake

TOKEN_URL = "https://api.zoominfo.com/gtm/oauth/v1/token"
GTM_BASE_URL = "https://api.zoominfo.com/gtm"
_REFRESH_SKEW_SECONDS = 60
_TOKENS_TABLE = "APP_STATE.OAUTH_TOKENS"

class ZoomInfoError(Exception):
    def __init__(self, status_code, message):
        self.status_code = status_code
        super().__init__(f"ZoomInfo API error {status_code}: {message}")

def _basic_auth_header(cid, csec):
    return "Basic " + base64.b64encode(f"{cid}:{csec}".encode("utf-8")).decode("ascii")

def _token_request(cfg, form):
    headers = {"Authorization": _basic_auth_header(cfg["client_id"], cfg["client_secret"]),
               "Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"}
    resp = requests.post(TOKEN_URL, headers=headers, data=form, timeout=30)
    if not resp.ok:
        raise ZoomInfoError(resp.status_code, resp.text)
    return json.loads(resp.text)

def zi_refresh(cfg, refresh_token):
    return _token_request(cfg, {"grant_type": "refresh_token", "refresh_token": refresh_token})

def token_expires_at(tr, now=None):
    now = int(time.time()) if now is None else now
    try:
        return now + int(tr["expires_in"])
    except (KeyError, ValueError, TypeError):
        return now + 3600

class ZoomInfoClient:
    def __init__(self, access_token, token_refresher=None, base_url=GTM_BASE_URL):
        self._access_token = access_token
        self._refresher = token_refresher
        self._base_url = base_url.rstrip("/")
    def _headers(self):
        return {"Authorization": f"Bearer {self._access_token}",
                "Content-Type": "application/json", "Accept": "application/json"}
    def post(self, path, body, params=None, max_retries=3):
        url = f"{self._base_url}{path}"
        attempt = 0; refreshed = False
        while True:
            resp = requests.post(url, headers=self._headers(), data=json.dumps(body),
                                 params=params or {}, timeout=60)
            if resp.status_code == 401 and self._refresher and not refreshed:
                self._access_token = self._refresher(); refreshed = True; continue
            if resp.status_code == 429 and attempt < max_retries:
                ra = resp.headers.get("Retry-After")
                time.sleep(float(ra) if ra else 2 ** attempt); attempt += 1; continue
            if not resp.ok:
                raise ZoomInfoError(resp.status_code, resp.text)
            return json.loads(resp.text) if resp.text else {}

def _oauth_cfg():
    cfg = json.loads(_snowflake.get_generic_secret_string("zoominfo_oauth_client"))
    missing = [k for k in ("client_id","client_secret","redirect_uri") if not cfg.get(k)]
    if missing:
        raise ValueError(f"zoominfo_oauth_client missing: {', '.join(missing)}")
    return cfg

def _load_tokens(session):
    rows = session.sql(f"SELECT access_token, refresh_token, expires_at FROM {_TOKENS_TABLE} WHERE sf_user = CURRENT_USER()").collect()
    if not rows: return None
    r = rows[0]
    return {"access_token": r["ACCESS_TOKEN"], "refresh_token": r["REFRESH_TOKEN"], "expires_at": r["EXPIRES_AT"]}

def _save_tokens(session, at, rt, exp):
    session.sql(f"MERGE INTO {_TOKENS_TABLE} t USING (SELECT CURRENT_USER() AS sf_user) s "
                f"ON t.sf_user = s.sf_user WHEN MATCHED THEN UPDATE SET access_token=?, refresh_token=?, expires_at=?, updated_at=CURRENT_TIMESTAMP() "
                f"WHEN NOT MATCHED THEN INSERT (sf_user, access_token, refresh_token, expires_at, updated_at) VALUES (s.sf_user, ?, ?, ?, CURRENT_TIMESTAMP())",
                params=[at, rt, exp, at, rt, exp]).collect()

def _get_client(session):
    tokens = _load_tokens(session)
    if not tokens or not tokens.get("access_token"):
        raise ValueError("Not connected to ZoomInfo. Run CONNECT_WITH_CODE first.")
    cfg = _oauth_cfg()
    def refresher():
        cur = _load_tokens(session)
        if not cur or not cur.get("refresh_token"):
            raise ValueError("Session expired and no refresh token. Reconnect.")
        tok = zi_refresh(cfg, cur["refresh_token"])
        _save_tokens(session, tok["access_token"], tok.get("refresh_token", cur["refresh_token"]), token_expires_at(tok))
        return tok["access_token"]
    at = tokens["access_token"]; exp = tokens.get("expires_at")
    if exp is not None and int(exp) - _REFRESH_SKEW_SECONDS <= int(time.time()):
        at = refresher()
    return ZoomInfoClient(at, token_refresher=refresher)

def _page_params(page_number, page_size):
    params = {}
    if page_number: params["page[number]"] = int(page_number)
    if page_size: params["page[size]"] = int(page_size)
    return params

def run(session, criteria, page_number, page_size):
    body = {"data": {"type": "ContactSearch", "attributes": criteria or {}}}
    return _get_client(session).post("/data/v1/contacts/search", body, params=_page_params(page_number, page_size))
$$;

-- 4d. search_company ---------------------------------------------------
CREATE OR REPLACE PROCEDURE CORE.SEARCH_COMPANY(criteria VARIANT, page_number INT, page_size INT)
  RETURNS VARIANT
  LANGUAGE PYTHON
  RUNTIME_VERSION = '3.11'
  PACKAGES = ('snowflake-snowpark-python', 'requests')
  HANDLER = 'run'
  EXTERNAL_ACCESS_INTEGRATIONS = (EXTERNAL_ACCESS_INTEGRATION_ZI_API)
  SECRETS = ('zoominfo_oauth_client' = CORE.ZI_OAUTH_CLIENT_SECRET)
AS
$$
import base64, json, time
import requests
import _snowflake

TOKEN_URL = "https://api.zoominfo.com/gtm/oauth/v1/token"
GTM_BASE_URL = "https://api.zoominfo.com/gtm"
_REFRESH_SKEW_SECONDS = 60
_TOKENS_TABLE = "APP_STATE.OAUTH_TOKENS"

class ZoomInfoError(Exception):
    def __init__(self, status_code, message):
        self.status_code = status_code
        super().__init__(f"ZoomInfo API error {status_code}: {message}")

def _basic_auth_header(cid, csec):
    return "Basic " + base64.b64encode(f"{cid}:{csec}".encode("utf-8")).decode("ascii")

def _token_request(cfg, form):
    headers = {"Authorization": _basic_auth_header(cfg["client_id"], cfg["client_secret"]),
               "Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"}
    resp = requests.post(TOKEN_URL, headers=headers, data=form, timeout=30)
    if not resp.ok:
        raise ZoomInfoError(resp.status_code, resp.text)
    return json.loads(resp.text)

def zi_refresh(cfg, refresh_token):
    return _token_request(cfg, {"grant_type": "refresh_token", "refresh_token": refresh_token})

def token_expires_at(tr, now=None):
    now = int(time.time()) if now is None else now
    try:
        return now + int(tr["expires_in"])
    except (KeyError, ValueError, TypeError):
        return now + 3600

class ZoomInfoClient:
    def __init__(self, access_token, token_refresher=None, base_url=GTM_BASE_URL):
        self._access_token = access_token
        self._refresher = token_refresher
        self._base_url = base_url.rstrip("/")
    def _headers(self):
        return {"Authorization": f"Bearer {self._access_token}",
                "Content-Type": "application/json", "Accept": "application/json"}
    def post(self, path, body, params=None, max_retries=3):
        url = f"{self._base_url}{path}"
        attempt = 0; refreshed = False
        while True:
            resp = requests.post(url, headers=self._headers(), data=json.dumps(body),
                                 params=params or {}, timeout=60)
            if resp.status_code == 401 and self._refresher and not refreshed:
                self._access_token = self._refresher(); refreshed = True; continue
            if resp.status_code == 429 and attempt < max_retries:
                ra = resp.headers.get("Retry-After")
                time.sleep(float(ra) if ra else 2 ** attempt); attempt += 1; continue
            if not resp.ok:
                raise ZoomInfoError(resp.status_code, resp.text)
            return json.loads(resp.text) if resp.text else {}

def _oauth_cfg():
    cfg = json.loads(_snowflake.get_generic_secret_string("zoominfo_oauth_client"))
    missing = [k for k in ("client_id","client_secret","redirect_uri") if not cfg.get(k)]
    if missing:
        raise ValueError(f"zoominfo_oauth_client missing: {', '.join(missing)}")
    return cfg

def _load_tokens(session):
    rows = session.sql(f"SELECT access_token, refresh_token, expires_at FROM {_TOKENS_TABLE} WHERE sf_user = CURRENT_USER()").collect()
    if not rows: return None
    r = rows[0]
    return {"access_token": r["ACCESS_TOKEN"], "refresh_token": r["REFRESH_TOKEN"], "expires_at": r["EXPIRES_AT"]}

def _save_tokens(session, at, rt, exp):
    session.sql(f"MERGE INTO {_TOKENS_TABLE} t USING (SELECT CURRENT_USER() AS sf_user) s "
                f"ON t.sf_user = s.sf_user WHEN MATCHED THEN UPDATE SET access_token=?, refresh_token=?, expires_at=?, updated_at=CURRENT_TIMESTAMP() "
                f"WHEN NOT MATCHED THEN INSERT (sf_user, access_token, refresh_token, expires_at, updated_at) VALUES (s.sf_user, ?, ?, ?, CURRENT_TIMESTAMP())",
                params=[at, rt, exp, at, rt, exp]).collect()

def _get_client(session):
    tokens = _load_tokens(session)
    if not tokens or not tokens.get("access_token"):
        raise ValueError("Not connected to ZoomInfo. Run CONNECT_WITH_CODE first.")
    cfg = _oauth_cfg()
    def refresher():
        cur = _load_tokens(session)
        if not cur or not cur.get("refresh_token"):
            raise ValueError("Session expired and no refresh token. Reconnect.")
        tok = zi_refresh(cfg, cur["refresh_token"])
        _save_tokens(session, tok["access_token"], tok.get("refresh_token", cur["refresh_token"]), token_expires_at(tok))
        return tok["access_token"]
    at = tokens["access_token"]; exp = tokens.get("expires_at")
    if exp is not None and int(exp) - _REFRESH_SKEW_SECONDS <= int(time.time()):
        at = refresher()
    return ZoomInfoClient(at, token_refresher=refresher)

def _page_params(page_number, page_size):
    params = {}
    if page_number: params["page[number]"] = int(page_number)
    if page_size: params["page[size]"] = int(page_size)
    return params

def run(session, criteria, page_number, page_size):
    body = {"data": {"type": "CompanySearch", "attributes": criteria or {}}}
    return _get_client(session).post("/data/v1/companies/search", body, params=_page_params(page_number, page_size))
$$;

-- 4e. begin_connect — build the PKCE authorize URL ---------------------
CREATE OR REPLACE PROCEDURE CORE.BEGIN_CONNECT()
  RETURNS VARIANT
  LANGUAGE PYTHON
  RUNTIME_VERSION = '3.11'
  PACKAGES = ('snowflake-snowpark-python', 'requests')
  HANDLER = 'run'
  EXTERNAL_ACCESS_INTEGRATIONS = (EXTERNAL_ACCESS_INTEGRATION_ZI_API)
  SECRETS = ('zoominfo_oauth_client' = CORE.ZI_OAUTH_CLIENT_SECRET)
AS
$$
import base64, hashlib, json, os
from urllib.parse import urlencode
import _snowflake

AUTHORIZE_URL = "https://api.zoominfo.com/gtm/oauth/v1/authorize"

def _b64url(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")

def make_code_verifier():
    return _b64url(os.urandom(64))

def make_state():
    return _b64url(os.urandom(24))

def code_challenge(verifier):
    return _b64url(hashlib.sha256(verifier.encode("ascii")).digest())

def build_authorize_url(cfg, state, verifier, scope=None):
    params = {"client_id": cfg["client_id"], "redirect_uri": cfg["redirect_uri"],
              "response_type": "code", "code_challenge": code_challenge(verifier),
              "code_challenge_method": "S256", "state": state}
    eff = scope if scope is not None else cfg.get("scope")
    if eff: params["scope"] = eff
    return f"{AUTHORIZE_URL}?{urlencode(params)}"

def _oauth_cfg():
    cfg = json.loads(_snowflake.get_generic_secret_string("zoominfo_oauth_client"))
    missing = [k for k in ("client_id","client_secret","redirect_uri") if not cfg.get(k)]
    if missing:
        raise ValueError(f"zoominfo_oauth_client missing: {', '.join(missing)}")
    return cfg

def run(session):
    cfg = _oauth_cfg()
    verifier = make_code_verifier()
    state = make_state()
    return {"authorize_url": build_authorize_url(cfg, state=state, verifier=verifier),
            "verifier": verifier, "state": state}
$$;

-- 4f. connect_with_code — exchange code for tokens, store them ---------
CREATE OR REPLACE PROCEDURE CORE.CONNECT_WITH_CODE(code STRING, verifier STRING)
  RETURNS VARIANT
  LANGUAGE PYTHON
  RUNTIME_VERSION = '3.11'
  PACKAGES = ('snowflake-snowpark-python', 'requests')
  HANDLER = 'run'
  EXTERNAL_ACCESS_INTEGRATIONS = (EXTERNAL_ACCESS_INTEGRATION_ZI_API)
  SECRETS = ('zoominfo_oauth_client' = CORE.ZI_OAUTH_CLIENT_SECRET)
AS
$$
import base64, json, time
import requests
import _snowflake

TOKEN_URL = "https://api.zoominfo.com/gtm/oauth/v1/token"
_TOKENS_TABLE = "APP_STATE.OAUTH_TOKENS"

class ZoomInfoError(Exception):
    def __init__(self, status_code, message):
        self.status_code = status_code
        super().__init__(f"ZoomInfo API error {status_code}: {message}")

def _basic_auth_header(cid, csec):
    return "Basic " + base64.b64encode(f"{cid}:{csec}".encode("utf-8")).decode("ascii")

def _token_request(cfg, form):
    headers = {"Authorization": _basic_auth_header(cfg["client_id"], cfg["client_secret"]),
               "Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"}
    resp = requests.post(TOKEN_URL, headers=headers, data=form, timeout=30)
    if not resp.ok:
        raise ZoomInfoError(resp.status_code, resp.text)
    return json.loads(resp.text)

def exchange_code(cfg, code, verifier):
    return _token_request(cfg, {"grant_type": "authorization_code", "code": code,
                                "code_verifier": verifier, "redirect_uri": cfg["redirect_uri"]})

def token_expires_at(tr, now=None):
    now = int(time.time()) if now is None else now
    try:
        return now + int(tr["expires_in"])
    except (KeyError, ValueError, TypeError):
        return now + 3600

def _oauth_cfg():
    cfg = json.loads(_snowflake.get_generic_secret_string("zoominfo_oauth_client"))
    missing = [k for k in ("client_id","client_secret","redirect_uri") if not cfg.get(k)]
    if missing:
        raise ValueError(f"zoominfo_oauth_client missing: {', '.join(missing)}")
    return cfg

def _save_tokens(session, at, rt, exp):
    session.sql(f"MERGE INTO {_TOKENS_TABLE} t USING (SELECT CURRENT_USER() AS sf_user) s "
                f"ON t.sf_user = s.sf_user WHEN MATCHED THEN UPDATE SET access_token=?, refresh_token=?, expires_at=?, updated_at=CURRENT_TIMESTAMP() "
                f"WHEN NOT MATCHED THEN INSERT (sf_user, access_token, refresh_token, expires_at, updated_at) VALUES (s.sf_user, ?, ?, ?, CURRENT_TIMESTAMP())",
                params=[at, rt, exp, at, rt, exp]).collect()

def run(session, code, verifier):
    if not code:
        raise ValueError("Authorization code is required.")
    if not verifier:
        raise ValueError("Missing PKCE verifier — restart the sign-in from BEGIN_CONNECT.")
    cfg = _oauth_cfg()
    tok = exchange_code(cfg, code, verifier)
    _save_tokens(session, tok["access_token"], tok.get("refresh_token"), token_expires_at(tok))
    return {"status": "connected", "scope": tok.get("scope", "")}
$$;

-- ---------------------------------------------------------------------
-- 5. Grants — let the calling role use everything
-- ---------------------------------------------------------------------
GRANT USAGE ON DATABASE IDENTIFIER($db_name) TO ROLE IDENTIFIER($app_role);
GRANT USAGE ON SCHEMA CORE TO ROLE IDENTIFIER($app_role);
GRANT USAGE ON SCHEMA APP_STATE TO ROLE IDENTIFIER($app_role);
GRANT SELECT, INSERT, UPDATE ON TABLE APP_STATE.OAUTH_TOKENS TO ROLE IDENTIFIER($app_role);
GRANT USAGE ON INTEGRATION EXTERNAL_ACCESS_INTEGRATION_ZI_API TO ROLE IDENTIFIER($app_role);

GRANT USAGE ON PROCEDURE CORE.ENRICH_CONTACT(VARIANT, ARRAY) TO ROLE IDENTIFIER($app_role);
GRANT USAGE ON PROCEDURE CORE.ENRICH_COMPANY(VARIANT, ARRAY) TO ROLE IDENTIFIER($app_role);
GRANT USAGE ON PROCEDURE CORE.SEARCH_CONTACT(VARIANT, INT, INT) TO ROLE IDENTIFIER($app_role);
GRANT USAGE ON PROCEDURE CORE.SEARCH_COMPANY(VARIANT, INT, INT) TO ROLE IDENTIFIER($app_role);
GRANT USAGE ON PROCEDURE CORE.BEGIN_CONNECT() TO ROLE IDENTIFIER($app_role);
GRANT USAGE ON PROCEDURE CORE.CONNECT_WITH_CODE(STRING, STRING) TO ROLE IDENTIFIER($app_role);

-- ---------------------------------------------------------------------
-- 6. Usage (run as the app_role)
-- ---------------------------------------------------------------------
--   CALL CORE.BEGIN_CONNECT();
--     -> open authorize_url in a browser, sign in, copy the returned code,
--        and keep the returned verifier.
--   CALL CORE.CONNECT_WITH_CODE('<code>', '<verifier>');
--   CALL CORE.ENRICH_CONTACT(
--          PARSE_JSON('[{"emailAddress":"jane@acme.com"}]'),
--          ARRAY_CONSTRUCT('id','firstName','lastName','email'));
--   CALL CORE.SEARCH_COMPANY(PARSE_JSON('{"companyName":"Acme"}'), 1, 25);
