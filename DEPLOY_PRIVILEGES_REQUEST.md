# Snowflake privileges needed to deploy & test the ZoomInfo Connector

**Account:** `<SNOWFLAKE_ACCOUNT>`, region `<REGION>`
**Requesting user:** `<USER>`
**Target database / schema:** `DEV_PRODUCT.ZI_API_NATIVE_APP`

The connector is a Snowflake Native App that calls the ZoomInfo GTM API over the
public internet. My personal Snowflake user has no account-level privileges, so it
cannot create the external access integration the app requires, nor a schema in
`DEV_PRODUCT`. This doc records the POC division of responsibilities and the grants
needed to make it work.

## POC responsibility split

**Snowflake team creates:**
1. Schema `ZI_API_NATIVE_APP` in database `DEV_PRODUCT`.
2. The `EXTERNAL_ACCESS_INTEGRATION_ZI_API` object (the EXTERNAL ACCESS INTEGRATION
   the app binds to — lets the app reach `api.zoominfo.com`). External access must be
   supported on the account (a real account, not a trial).
3. A role scoped to the `DEV_PRODUCT.ZI_API_NATIVE_APP` schema, granted to my
   personal Snowflake user (`<USER>`).

**I create (using that granted, schema-scoped role):**
1. `ZI_API_NETWORK_RULE` (NETWORK RULE, egress to `api.zoominfo.com`).
2. `ZI_OAUTH_CLIENT_SECRET` (SECRET holding the ZoomInfo OAuth client config JSON).
3. The application package.
4. The application itself.

## Grants (Snowflake team runs as ACCOUNTADMIN)

```sql
USE ROLE ACCOUNTADMIN;

-- Schema that will hold the app objects the developer creates.
CREATE SCHEMA IF NOT EXISTS DEV_PRODUCT.ZI_API_NATIVE_APP;

-- The external access integration the app binds to (Snowflake team owns this object).
CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION EXTERNAL_ACCESS_INTEGRATION_ZI_API
  ALLOWED_NETWORK_RULES = (DEV_PRODUCT.ZI_API_NATIVE_APP.ZI_API_NETWORK_RULE)
  ALLOWED_AUTHENTICATION_SECRETS = (DEV_PRODUCT.ZI_API_NATIVE_APP.ZI_OAUTH_CLIENT_SECRET)
  ENABLED = TRUE;
-- NOTE: the network rule + secret are created by the developer (below), so either
-- create this integration after those exist, or create it with ALLOWED_* left to be
-- added once they do.

-- A role scoped to the schema, granted to the developer.
CREATE ROLE IF NOT EXISTS ZI_API_NATIVE_APP_ROLE;
GRANT USAGE ON DATABASE DEV_PRODUCT                       TO ROLE ZI_API_NATIVE_APP_ROLE;
GRANT USAGE ON SCHEMA   DEV_PRODUCT.ZI_API_NATIVE_APP     TO ROLE ZI_API_NATIVE_APP_ROLE;
GRANT CREATE NETWORK RULE ON SCHEMA DEV_PRODUCT.ZI_API_NATIVE_APP TO ROLE ZI_API_NATIVE_APP_ROLE;
GRANT CREATE SECRET       ON SCHEMA DEV_PRODUCT.ZI_API_NATIVE_APP TO ROLE ZI_API_NATIVE_APP_ROLE;

-- Build + install the Native App (provider side).
GRANT CREATE APPLICATION PACKAGE ON ACCOUNT TO ROLE ZI_API_NATIVE_APP_ROLE;
GRANT CREATE APPLICATION         ON ACCOUNT TO ROLE ZI_API_NATIVE_APP_ROLE;

-- Let the app (and the developer's procedures) use the integration.
GRANT USAGE ON INTEGRATION EXTERNAL_ACCESS_INTEGRATION_ZI_API TO ROLE ZI_API_NATIVE_APP_ROLE;

GRANT ROLE ZI_API_NATIVE_APP_ROLE TO USER <USER>;
```

`<USER>` already has a usable warehouse, so no warehouse grant is needed.

## After the grants

Using `ZI_API_NATIVE_APP_ROLE`, I will:
1. Create `ZI_API_NETWORK_RULE` and `ZI_OAUTH_CLIENT_SECRET` in
   `DEV_PRODUCT.ZI_API_NATIVE_APP`.
2. `snow app run -c <connection> --role ZI_API_NATIVE_APP_ROLE` to build the
   application package and install the application.
3. Bind the app's two references — `zoominfo_oauth_client` → `ZI_OAUTH_CLIENT_SECRET`
   and `zoominfo_external_access` → `EXTERNAL_ACCESS_INTEGRATION_ZI_API` — which
   triggers creation of the 4 data procedures + 2 OAuth sign-in procedures.
4. Open the app's "Connect ZoomInfo" page, sign in, and call the 4 procedures to
   verify end-to-end before publishing.

> `zoominfo_oauth_client` and `zoominfo_external_access` are the app's internal
> reference (alias) names declared in `app/manifest.yml`; they are unrelated to the
> object names above and are intentionally left unchanged.
