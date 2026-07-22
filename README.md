# ZoomInfo Connector for Snowflake

A Snowflake Native App that calls the [ZoomInfo GTM API](https://docs.zoominfo.com/reference/overview)
directly from SQL. It authenticates with **OAuth 2.0 Client Credentials** using the consumer's own
ZoomInfo API credentials (account-level), and exposes stored procedures for contact/company
**enrich** and **search**.

## Procedures

| Procedure | Purpose | ZoomInfo endpoint |
|-----------|---------|-------------------|
| `core.enrich_contact(match_input VARIANT, output_fields ARRAY)`  | Enrich up to 25 contacts  | `POST /data/v1/contacts/enrich`  |
| `core.enrich_company(match_input VARIANT, output_fields ARRAY)`  | Enrich up to 25 companies | `POST /data/v1/companies/enrich` |
| `core.search_contact(criteria VARIANT, page_number INT, page_size INT)`  | Find contacts | `POST /data/v1/contacts/search`  |
| `core.search_company(criteria VARIANT, page_number INT, page_size INT)` | Find companies | `POST /data/v1/companies/search` |
| `core.lookup_search(entity STRING, field_type STRING)` | Valid values/fields for search criteria | `GET /data/v1/lookup/search` |
| `core.lookup_enrich(entity STRING, field_type STRING)` | Available enrich output fields (+ access) | `GET /data/v1/lookup/enrich` |
| Procedure | Purpose | ZoomInfo endpoint |
|-----------|---------|-------------------|
| `core.enrich_contact(match_input VARIANT, output_fields ARRAY)`  | Enrich up to 25 contacts  | `POST /data/v1/contacts/enrich`  |
| `core.enrich_company(match_input VARIANT, output_fields ARRAY)`  | Enrich up to 25 companies | `POST /data/v1/companies/enrich` |
| `core.enrich_scoops(company_id STRING)`  | Enrich scoops for one company | `POST /data/v1/scoops/enrich` |
| `core.enrich_technologies(company_id STRING)`  | Enrich one company's tech stack | `POST /data/v1/companies/technologies/enrich` |
| `core.enrich_corporate_hierarchy(match_input VARIANT, output_fields ARRAY)`  | Enrich corporate hierarchy | `POST /data/v1/companies/corporate-hierarchy/enrich` |
| `core.search_contact(criteria VARIANT, page_number INT, page_size INT)`  | Find contacts | `POST /data/v1/contacts/search`  |
| `core.search_company(criteria VARIANT, page_number INT, page_size INT)` | Find companies | `POST /data/v1/companies/search` |
| `core.search_scoops(criteria VARIANT, page_number INT, page_size INT)` | Find scoops (company signals) | `POST /data/v1/scoops/search` |
| `core.search_news(criteria VARIANT, page_number INT, page_size INT)` | Find news | `POST /data/v1/news/search` |
| `core.search_intent(criteria VARIANT, page_number INT, page_size INT)` | Find intent signals (Intent product) | `POST /data/v1/intent/search` |
| `core.lookup_search(entity STRING, field_type STRING)` | Valid values/fields for search criteria | `GET /data/v1/lookup/search` |
| `core.lookup_enrich(entity STRING, field_type STRING)` | Available enrich output fields (+ access) | `GET /data/v1/lookup/enrich` |
| `core.lookup_intent_topics()` | Licensed intent topic names | `GET /data/v1/lookup/intent-topics` |
| `core.get_usage()` | Account API usage and limits | `GET /data/v1/users/usage` |
| `core.test_connection()` | Health check — verifies config + reachability | (calls `get_usage`) |

Every procedure returns the raw ZoomInfo JSON:API response as a `VARIANT`. To get rows, `CALL` the
procedure then flatten the result with `LATERAL FLATTEN`:

```sql
CALL core.search_company(PARSE_JSON('{"companyName":"ZoomInfo"}'), 1, 25);
SELECT f.value:id::STRING              AS id,
       f.value:attributes:name::STRING AS name,
       f.value:attributes:revenue      AS revenue
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) r,
     LATERAL FLATTEN(input => r.$1:data) f;
```

A `core.flatten_records(VARIANT)` table function is also provided for flattening a response VARIANT
you already hold (e.g. inside a view/CTE): `SELECT * FROM TABLE(core.flatten_records(<variant>))`
returns `(id, record_type, attributes, meta)` per record.

`lookup_*`, `get_usage`, `search_*`, and `test_connection` are free (no credits); `enrich_*` consume
credits per matched record. `search_intent` / `lookup_intent_topics` require the Intent product —
unlicensed accounts get a clean error.

## Layout

```
zoominfo-connector/
  snowflake.yml            # Snowflake CLI project definition
  CHANGELOG.md             # release notes
  LICENSE                  # Apache-2.0
  requirements-dev.txt     # test/CI dependencies
  app/
    manifest.yml           # Native App manifest (version + secret/EAI references)
    README.md              # consumer-facing docs (installed with the app)
    setup_script.sql       # roles, schema, token cache, procedures, callbacks
    src/
      zoominfo_client.py   # Client Credentials token + GTM data HTTP client
      handlers.py          # Snowpark handlers for the procedures (account token cache)
  tests/                   # pytest suite (mock-based; no real credentials)
  scripts/                 # helper scripts (e.g. update the credentials secret)
  snowflake/               # consumer-side object setup (network rule + secret)
```

## How authentication works

Auth is **OAuth 2.0 Client Credentials** — the same pattern ZoomInfo's other API integrations use
(e.g. the Fivetran ZoomInfo connector). There is no interactive sign-in and no per-user token.

1. **Credentials** — the consumer binds their own ZoomInfo API `client_id`/`client_secret` as a
   Snowflake `SECRET`, and an external access integration allowing `api.zoominfo.com`.
2. **Token** — the procedures exchange those credentials for an account access token
   (`POST /gtm/oauth/v1/token`, `grant_type=client_credentials`), cache it in
   `app_state.token_cache`, and re-fetch it on expiry or a `401`.
3. **Data calls** — the procedures call the GTM data API with the bearer token; 429s are retried
   with backoff honoring `Retry-After`.

> A per-user Authorization Code + PKCE model (with a ZoomInfo-hosted token broker) was considered and
> rejected in favor of account-level Client Credentials, matching how ZoomInfo's other connectors authenticate.

## Build & deploy (provider)

Prerequisites: Snowflake CLI v3+, a connection with `CREATE APPLICATION PACKAGE`/`CREATE APPLICATION`.

```bash
cd zoominfo-connector
snow app run -c <your-connection>
```

Then create the secret (your ZoomInfo `client_id`/`client_secret`) and the external access
integration, and bind both references — see [app/README.md](app/README.md) for the consumer setup
plus `CALL` examples.

## Releasing (Marketplace)

`snow app run` installs an **unversioned dev** app. To publish, cut a versioned release from the
application package (the version is declared in `app/manifest.yml`):

```sql
-- Add a version/patch to the package from the uploaded stage content.
ALTER APPLICATION PACKAGE ZI_API_CONNECTOR_PKG
  ADD VERSION v1_0 USING '@ZI_API_CONNECTOR_PKG.stage_content.zoominfo_stage';

-- Point the default release directive at it (consumers install this).
ALTER APPLICATION PACKAGE ZI_API_CONNECTOR_PKG
  SET DEFAULT RELEASE DIRECTIVE VERSION = v1_0 PATCH = 0;
```

Then create/attach a provider listing in Snowsight. Bump `version:` in `manifest.yml` and record
changes in [CHANGELOG.md](CHANGELOG.md) for each release.

## Development

```bash
pip install -r requirements-dev.txt
pytest                       # mock-based unit tests — no real credentials or Snowflake needed
```

CI (`.github/workflows/ci.yml`) runs the suite and a compile check on the handler modules on
Python 3.11 (the procedure runtime).

## Credential model (product decision)

This connector uses **account-level Client Credentials**: each consumer supplies their **own**
ZoomInfo API `client_id`/`client_secret` (with the `client_credentials` grant enabled in the
ZoomInfo DevPortal). It is therefore a **bring-your-own-credentials** listing — it is not eligible
for ZoomInfo **Partner App** submission (that requires the interactive Authorization Code + PKCE
flow, which needs a ZoomInfo-hosted token broker). Confirm this is the intended distribution model
before publishing; not every ZoomInfo customer has API/DevPortal access.

## Observability

The app emits non-sensitive operational logs (procedure name, endpoint, status) via Python
`logging` — never criteria values, tokens, or PII. `manifest.yml` sets `log_level: info` and
`trace_level: on_event`. To capture these, the consumer sets an event table on the application, e.g.:

```sql
ALTER APPLICATION ZI_API_CONNECTOR_APP SET LOG_LEVEL = INFO;
-- Logs/traces flow to the account's active event table
-- (see Snowflake "Logging and tracing for native apps").
```

## Notes

- The data/lookup/usage procedures are created lazily by the `register_reference` callback once **both** the
  credentials secret and the external access integration references are bound — Snowflake validates
  those bindings at procedure-CREATE time, so they can't be created during install.
- `requests` comes from the Snowflake Anaconda channel — no vendoring, and no private key / JWT
  signing.
