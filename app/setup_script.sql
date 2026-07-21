-- =====================================================================
-- ZoomInfo Connector — Native App setup script
-- Runs each time the app is installed or upgraded. Must be idempotent.
--
-- Auth model: OAuth 2.0 Authorization Code + PKCE. End users sign in to
-- ZoomInfo via the "Connect ZoomInfo" Streamlit page; their access/refresh
-- tokens are stored per Snowflake user in app_state.oauth_tokens. The four data
-- procedures read the caller's token and refresh it on expiry.
-- =====================================================================

CREATE APPLICATION ROLE IF NOT EXISTS app_public;

-- Versioned schema: code (procedures) placed here is kept consistent across
-- upgrades so running calls are not disrupted mid-upgrade.
CREATE OR ALTER VERSIONED SCHEMA core;
GRANT USAGE ON SCHEMA core TO APPLICATION ROLE app_public;

-- ---------------------------------------------------------------------
-- Per-user OAuth token store
-- Rotating tokens are written by the app after login/refresh, so they live in
-- an app-owned table (not a read-only consumer secret). Keyed by Snowflake user
-- so each user has their own ZoomInfo connection.
--
-- STATEFUL data must NOT live in a versioned schema (each version gets its own
-- copy, so data wouldn't persist across upgrades). Use a regular schema.
-- ---------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS app_state;

CREATE TABLE IF NOT EXISTS app_state.oauth_tokens (
  sf_user       STRING NOT NULL PRIMARY KEY,
  access_token  STRING,
  refresh_token STRING,
  expires_at    NUMBER,
  updated_at    TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Make the state schema visible to the app role. The app's own procedures reach
-- the table via owner's rights regardless, but this exposes it for inspection.
GRANT USAGE ON SCHEMA app_state TO APPLICATION ROLE app_public;
-- ---------------------------------------------------------------------
-- Reference-binding callbacks
-- The consumer binds their SECRET and EXTERNAL ACCESS INTEGRATION to the
-- references declared in manifest.yml. These callbacks drive the config UI
-- and record the binding. Names match register_callback/configuration_callback
-- in the manifest.
-- ---------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE core.get_configuration(ref_name STRING)
  RETURNS STRING
  LANGUAGE SQL
AS
$$
BEGIN
  CASE (ref_name)
    WHEN 'ZOOMINFO_OAUTH_CLIENT' THEN
      RETURN OBJECT_CONSTRUCT(
        'type', 'CONFIGURATION',
        'payload', OBJECT_CONSTRUCT(
          'host_ports', ARRAY_CONSTRUCT('api.zoominfo.com'),
          'secret_type', 'GENERIC_STRING'
        )
      )::STRING;
    WHEN 'ZOOMINFO_EXTERNAL_ACCESS' THEN
      RETURN OBJECT_CONSTRUCT(
        'type', 'CONFIGURATION',
        'payload', OBJECT_CONSTRUCT(
          'host_ports', ARRAY_CONSTRUCT('api.zoominfo.com'),
          'allowed_secrets', 'LIST',
          'secret_references', ARRAY_CONSTRUCT('ZOOMINFO_OAUTH_CLIENT')
        )
      )::STRING;
    ELSE
      RETURN '';
  END CASE;
END;
$$;

GRANT USAGE ON PROCEDURE core.get_configuration(STRING) TO APPLICATION ROLE app_public;

-- The four ZoomInfo API procedures read the consumer-bound OAuth client SECRET
-- and reach ZoomInfo through the consumer-bound EXTERNAL ACCESS INTEGRATION. A
-- Python procedure's SECRETS/EAI bindings are validated at CREATE time, so these
-- procedures CANNOT be created during install (the consumer has not bound the
-- references yet). Instead they are created by core.create_api_procedures(),
-- which the register callback invokes once BOTH references are bound. See:
-- https://docs.snowflake.com/en/developer-guide/native-apps/requesting-refs
CREATE OR REPLACE PROCEDURE core.create_api_procedures()
  RETURNS STRING
  LANGUAGE SQL
AS
$$
BEGIN
  CREATE OR REPLACE PROCEDURE core.enrich_contact(match_input VARIANT, output_fields ARRAY)
    RETURNS VARIANT
    LANGUAGE PYTHON
    RUNTIME_VERSION = '3.11'
    PACKAGES = ('snowflake-snowpark-python', 'requests')
    IMPORTS = ('/src/zoominfo_client.py', '/src/handlers.py')
    HANDLER = 'handlers.enrich_contact'
    EXTERNAL_ACCESS_INTEGRATIONS = (REFERENCE('zoominfo_external_access'))
    SECRETS = ('zoominfo_oauth_client' = REFERENCE('zoominfo_oauth_client'));
  GRANT USAGE ON PROCEDURE core.enrich_contact(VARIANT, ARRAY) TO APPLICATION ROLE app_public;

  CREATE OR REPLACE PROCEDURE core.enrich_company(match_input VARIANT, output_fields ARRAY)
    RETURNS VARIANT
    LANGUAGE PYTHON
    RUNTIME_VERSION = '3.11'
    PACKAGES = ('snowflake-snowpark-python', 'requests')
    IMPORTS = ('/src/zoominfo_client.py', '/src/handlers.py')
    HANDLER = 'handlers.enrich_company'
    EXTERNAL_ACCESS_INTEGRATIONS = (REFERENCE('zoominfo_external_access'))
    SECRETS = ('zoominfo_oauth_client' = REFERENCE('zoominfo_oauth_client'));
  GRANT USAGE ON PROCEDURE core.enrich_company(VARIANT, ARRAY) TO APPLICATION ROLE app_public;

  CREATE OR REPLACE PROCEDURE core.search_contact(criteria VARIANT, page_number INT, page_size INT)
    RETURNS VARIANT
    LANGUAGE PYTHON
    RUNTIME_VERSION = '3.11'
    PACKAGES = ('snowflake-snowpark-python', 'requests')
    IMPORTS = ('/src/zoominfo_client.py', '/src/handlers.py')
    HANDLER = 'handlers.search_contact'
    EXTERNAL_ACCESS_INTEGRATIONS = (REFERENCE('zoominfo_external_access'))
    SECRETS = ('zoominfo_oauth_client' = REFERENCE('zoominfo_oauth_client'));
  GRANT USAGE ON PROCEDURE core.search_contact(VARIANT, INT, INT) TO APPLICATION ROLE app_public;

  CREATE OR REPLACE PROCEDURE core.search_company(criteria VARIANT, page_number INT, page_size INT)
    RETURNS VARIANT
    LANGUAGE PYTHON
    RUNTIME_VERSION = '3.11'
    PACKAGES = ('snowflake-snowpark-python', 'requests')
    IMPORTS = ('/src/zoominfo_client.py', '/src/handlers.py')
    HANDLER = 'handlers.search_company'
    EXTERNAL_ACCESS_INTEGRATIONS = (REFERENCE('zoominfo_external_access'))
    SECRETS = ('zoominfo_oauth_client' = REFERENCE('zoominfo_oauth_client'));
  GRANT USAGE ON PROCEDURE core.search_company(VARIANT, INT, INT) TO APPLICATION ROLE app_public;

  -- OAuth sign-in procedures. These hold the EAI + secret bindings so the
  -- Streamlit "Connect ZoomInfo" page itself needs no external access — it just
  -- calls these. begin_connect builds the PKCE authorize URL; connect_with_code
  -- exchanges the pasted authorization code for tokens.
  CREATE OR REPLACE PROCEDURE core.begin_connect()
    RETURNS VARIANT
    LANGUAGE PYTHON
    RUNTIME_VERSION = '3.11'
    PACKAGES = ('snowflake-snowpark-python', 'requests')
    IMPORTS = ('/src/zoominfo_client.py', '/src/handlers.py')
    HANDLER = 'handlers.begin_connect'
    EXTERNAL_ACCESS_INTEGRATIONS = (REFERENCE('zoominfo_external_access'))
    SECRETS = ('zoominfo_oauth_client' = REFERENCE('zoominfo_oauth_client'));
  GRANT USAGE ON PROCEDURE core.begin_connect() TO APPLICATION ROLE app_public;

  CREATE OR REPLACE PROCEDURE core.connect_with_code(code STRING, verifier STRING)
    RETURNS VARIANT
    LANGUAGE PYTHON
    RUNTIME_VERSION = '3.11'
    PACKAGES = ('snowflake-snowpark-python', 'requests')
    IMPORTS = ('/src/zoominfo_client.py', '/src/handlers.py')
    HANDLER = 'handlers.connect_with_code'
    EXTERNAL_ACCESS_INTEGRATIONS = (REFERENCE('zoominfo_external_access'))
    SECRETS = ('zoominfo_oauth_client' = REFERENCE('zoominfo_oauth_client'));
  GRANT USAGE ON PROCEDURE core.connect_with_code(STRING, STRING) TO APPLICATION ROLE app_public;

  RETURN 'api procedures created';
END;
$$;

-- Create the API procedures only once BOTH references are bound. SYSTEM$GET_ALL_REFERENCES
-- returns a JSON array of the currently bound references; we require both by name. This is
-- order-independent: whichever reference is bound second triggers creation.
CREATE OR REPLACE PROCEDURE core.create_api_procedures_if_ready()
  RETURNS STRING
  LANGUAGE SQL
AS
$$
DECLARE
  bound STRING;
BEGIN
  bound := SYSTEM$GET_ALL_REFERENCES();
  IF (bound LIKE '%ZOOMINFO_OAUTH_CLIENT%' AND bound LIKE '%ZOOMINFO_EXTERNAL_ACCESS%') THEN
    CALL core.create_api_procedures();
    RETURN 'created';
  END IF;
  RETURN 'waiting for both references';
END;
$$;

CREATE OR REPLACE PROCEDURE core.register_reference(ref_name STRING, operation STRING, ref_or_alias STRING)
  RETURNS STRING
  LANGUAGE SQL
AS
$$
BEGIN
  CASE (operation)
    WHEN 'ADD' THEN
      SELECT SYSTEM$SET_REFERENCE(:ref_name, :ref_or_alias);
      -- Both references may now be bound; (re)create the API procedures if so.
      CALL core.create_api_procedures_if_ready();
    WHEN 'REMOVE' THEN
      SELECT SYSTEM$REMOVE_REFERENCE(:ref_name);
    WHEN 'CLEAR' THEN
      SELECT SYSTEM$REMOVE_REFERENCE(:ref_name);
    ELSE
      RETURN 'unknown operation: ' || operation;
  END CASE;
  RETURN NULL;
END;
$$;

GRANT USAGE ON PROCEDURE core.register_reference(STRING, STRING, STRING) TO APPLICATION ROLE app_public;

-- ---------------------------------------------------------------------
-- Streamlit "Connect ZoomInfo" page
-- Runs the interactive PKCE sign-in and writes tokens to app_state.oauth_tokens.
-- Created bare at install (no EAI/secret) so it exists for the manifest's
-- default_streamlit and the consumer can open the app. Its EAI + secret binding
-- is attached later by create_api_procedures() once both references are bound
-- (ALTER STREAMLIT), because those bindings are validated against a bound
-- reference. Warehouse references are not supported for Native App Streamlit, so
-- no QUERY_WAREHOUSE is set (the app uses the caller's warehouse).
-- ---------------------------------------------------------------------
CREATE STREAMLIT IF NOT EXISTS core.connect_zoominfo
  FROM '/src'
  MAIN_FILE = 'streamlit_app.py';

GRANT USAGE ON STREAMLIT core.connect_zoominfo TO APPLICATION ROLE app_public;
