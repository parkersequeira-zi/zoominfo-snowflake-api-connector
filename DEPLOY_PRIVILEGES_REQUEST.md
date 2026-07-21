# Snowflake privileges needed to deploy & test the ZoomInfo Connector

**Account:** `<SNOWFLAKE_ACCOUNT>`, region `<REGION>`
**Requesting user:** `<USER>`
**Target role:** `<DEPLOY_ROLE>`

`<DEPLOY_ROLE>` is a data-access role (SELECT on views) and has **no account-level
privileges**, so it cannot deploy a Snowflake Native App or create the external
access objects the app requires. Confirmed by attempting `snow app run` →
"Insufficient privileges to create application package ... using role: <DEPLOY_ROLE>".

The connector is a Snowflake Native App that calls the ZoomInfo GTM API over the
public internet. Please grant the privileges below to `<DEPLOY_ROLE>` (or create a
dedicated role with them and grant it to `<USER>`).

## Grants (run as ACCOUNTADMIN)

```sql
USE ROLE ACCOUNTADMIN;

-- Build + install the Native App (provider side)
GRANT CREATE APPLICATION PACKAGE ON ACCOUNT TO ROLE <DEPLOY_ROLE>;
GRANT CREATE APPLICATION         ON ACCOUNT TO ROLE <DEPLOY_ROLE>;

-- Create the external access integration the app binds to. This lets the app
-- reach api.zoominfo.com. (External access must be supported on the account —
-- i.e. a real account, not a trial.)
GRANT CREATE INTEGRATION ON ACCOUNT TO ROLE <DEPLOY_ROLE>;

-- A database to hold the consumer network rule + OAuth client secret.
-- Skip this if you instead point me at an existing database where <DEPLOY_ROLE>
-- can CREATE SCHEMA / NETWORK RULE / SECRET.
GRANT CREATE DATABASE ON ACCOUNT TO ROLE <DEPLOY_ROLE>;
```

`<DEPLOY_ROLE>` already has a usable warehouse, so no warehouse grant is needed.

## After the grants

I will:
1. `snow app run -c <connection> --role <DEPLOY_ROLE>` to install the app.
2. Create the network rule + OAuth client secret + external access integration,
   and bind them to the app's two references (this triggers creation of the 4
   data procedures + 2 OAuth sign-in procedures).
3. Open the app's "Connect ZoomInfo" page, sign in, and call the 4 procedures to
   verify end-to-end before publishing.
