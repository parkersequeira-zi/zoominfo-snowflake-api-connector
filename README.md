# ZoomInfo Connector for Snowflake

A Snowflake Native App that calls the [ZoomInfo GTM API](https://docs.zoominfo.com/reference/overview)
directly from SQL. Users **sign in to their own ZoomInfo account** via OAuth 2.0
(Authorization Code flow with **PKCE**); the app then exposes stored procedures for contact/company
**enrich** and **search** that call ZoomInfo on the signed-in user's behalf.

## Procedures

| Procedure | Purpose | ZoomInfo endpoint |
|-----------|---------|-------------------|
| `core.enrich_contact(match_input VARIANT, output_fields ARRAY)`  | Enrich up to 25 contacts  | `POST /data/v1/contacts/enrich`  |
| `core.enrich_company(match_input VARIANT, output_fields ARRAY)`  | Enrich up to 25 companies | `POST /data/v1/companies/enrich` |
| `core.search_contact(criteria VARIANT, page_number INT, page_size INT)`  | Find contacts | `POST /data/v1/contacts/search`  |
| `core.search_company(criteria VARIANT, page_number INT, page_size INT)` | Find companies | `POST /data/v1/companies/search` |

## Layout

```
zoominfo-connector/
  snowflake.yml            # Snowflake CLI project definition
  app/
    manifest.yml           # Native App manifest (references + default Streamlit)
    README.md              # consumer-facing docs (installed with the app)
    setup_script.sql       # roles, schema, token table, procedures, Streamlit, callbacks
    src/
      zoominfo_client.py   # PKCE helpers + OAuth token exchange/refresh + HTTP client
      handlers.py          # Snowpark handlers for the 4 procedures (per-user tokens)
      streamlit_app.py     # "Connect ZoomInfo" interactive sign-in page
      environment.yml      # Streamlit package pins (streamlit, requests)
```

## How authentication works

ZoomInfo OAuth (Authorization Code + PKCE) is interactive, so it can't run inside a stored procedure.
Auth is split into two tiers:

1. **Sign-in (interactive, per user)** — the app's **Connect ZoomInfo** Streamlit page builds a PKCE
   authorize URL (`code_challenge` = base64url SHA256 of a local `code_verifier`), the user signs in
   at ZoomInfo, and pastes back the returned authorization `code`. The page exchanges the code +
   verifier at `POST /gtm/oauth/v1/token` for an `access_token` + `refresh_token`, stored **per
   Snowflake user** in `app_state.oauth_tokens`.
2. **Data calls (server-side)** — the procedures read the calling user's stored `access_token`, call
   the GTM API, and on `401`/expiry use the stored `refresh_token` to get a fresh access token.
   ZoomInfo **rotates** refresh tokens, so the new refresh token is persisted each time.

## Build & deploy (provider)

Prerequisites: Snowflake CLI v3+, a connection with `CREATE APPLICATION PACKAGE`/`CREATE APPLICATION`.

```bash
cd zoominfo-connector
snow app run -c <your-connection>
```

Then create the objects the app needs (external access integration + OAuth client secret), bind the
references, and sign in — see [app/README.md](app/README.md) for the consumer setup plus `CALL`
examples.

## Notes

- The four data procedures are created lazily by the `register_reference` callback once **both** the
  OAuth client secret and the external access integration references are bound — Snowflake validates
  those bindings at procedure-CREATE time, so they can't be created during install.
- `requests` comes from the Snowflake Anaconda channel — no vendoring, and no private key / JWT
  signing anymore.
