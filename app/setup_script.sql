-- =====================================================================
-- ZoomInfo Connector — Native App setup script
-- Runs each time the app is installed or upgraded. Must be idempotent.
--
-- Auth model: OAuth 2.0 Client Credentials. The consumer binds their own
-- ZoomInfo API credentials (client_id/client_secret) as a SECRET; the app
-- exchanges them for an account-level access token, caches it in
-- app_state.token_cache, and calls ZoomInfo's data API. No per-user sign-in.
-- =====================================================================

CREATE APPLICATION ROLE IF NOT EXISTS app_public;

-- Versioned schema: code (procedures) placed here is kept consistent across
-- upgrades so running calls are not disrupted mid-upgrade.
CREATE OR ALTER VERSIONED SCHEMA core;
GRANT USAGE ON SCHEMA core TO APPLICATION ROLE app_public;

-- ---------------------------------------------------------------------
-- Account access-token cache
-- The Client Credentials token is account-level (not per user), so a single
-- cached row suffices. Written by the app after each token fetch.
--
-- STATEFUL data must NOT live in a versioned schema (each version gets its own
-- copy, so data wouldn't persist across upgrades). Use a regular schema.
-- ---------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS app_state;

CREATE TABLE IF NOT EXISTS app_state.token_cache (
  id           NUMBER NOT NULL PRIMARY KEY,   -- always 1 (single row)
  access_token STRING,
  expires_at   NUMBER,
  updated_at   TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Make the state schema visible to the app role. The app's own procedures reach
-- the table via owner's rights regardless, but this exposes it for inspection.
GRANT USAGE ON SCHEMA app_state TO APPLICATION ROLE app_public;

-- ---------------------------------------------------------------------
-- Reference-binding callbacks
-- The consumer binds their SECRET and EXTERNAL ACCESS INTEGRATION to the
-- references declared in manifest.yml. These callbacks drive the config UI
-- and record the binding.
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

-- The four ZoomInfo API procedures read the consumer-bound API credentials SECRET
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
  -- Inner "impl" procedures carry the EAI + SECRETS reference clauses. Consumers
  -- cannot call reference-bearing procedures directly, so these are NOT granted
  -- to app_public — the top-level SQL wrappers (created at install) call them.
  CREATE OR REPLACE PROCEDURE core.enrich_contact_impl(match_input VARIANT, output_fields ARRAY)
    RETURNS VARIANT
    LANGUAGE PYTHON
    RUNTIME_VERSION = '3.11'
    PACKAGES = ('snowflake-snowpark-python', 'requests')
    IMPORTS = ('/src/zoominfo_client.py', '/src/handlers.py')
    HANDLER = 'handlers.enrich_contact'
    EXTERNAL_ACCESS_INTEGRATIONS = (REFERENCE('zoominfo_external_access'))
    SECRETS = ('zoominfo_oauth_client' = REFERENCE('zoominfo_oauth_client'));

  CREATE OR REPLACE PROCEDURE core.enrich_company_impl(match_input VARIANT, output_fields ARRAY)
    RETURNS VARIANT
    LANGUAGE PYTHON
    RUNTIME_VERSION = '3.11'
    PACKAGES = ('snowflake-snowpark-python', 'requests')
    IMPORTS = ('/src/zoominfo_client.py', '/src/handlers.py')
    HANDLER = 'handlers.enrich_company'
    EXTERNAL_ACCESS_INTEGRATIONS = (REFERENCE('zoominfo_external_access'))
    SECRETS = ('zoominfo_oauth_client' = REFERENCE('zoominfo_oauth_client'));

  CREATE OR REPLACE PROCEDURE core.search_contact_impl(criteria VARIANT, page_number INT, page_size INT)
    RETURNS VARIANT
    LANGUAGE PYTHON
    RUNTIME_VERSION = '3.11'
    PACKAGES = ('snowflake-snowpark-python', 'requests')
    IMPORTS = ('/src/zoominfo_client.py', '/src/handlers.py')
    HANDLER = 'handlers.search_contact'
    EXTERNAL_ACCESS_INTEGRATIONS = (REFERENCE('zoominfo_external_access'))
    SECRETS = ('zoominfo_oauth_client' = REFERENCE('zoominfo_oauth_client'));

  CREATE OR REPLACE PROCEDURE core.search_company_impl(criteria VARIANT, page_number INT, page_size INT)
    RETURNS VARIANT
    LANGUAGE PYTHON
    RUNTIME_VERSION = '3.11'
    PACKAGES = ('snowflake-snowpark-python', 'requests')
    IMPORTS = ('/src/zoominfo_client.py', '/src/handlers.py')
    HANDLER = 'handlers.search_company'
    EXTERNAL_ACCESS_INTEGRATIONS = (REFERENCE('zoominfo_external_access'))
    SECRETS = ('zoominfo_oauth_client' = REFERENCE('zoominfo_oauth_client'));

  CREATE OR REPLACE PROCEDURE core.lookup_search_impl(entity STRING, field_type STRING)
    RETURNS VARIANT
    LANGUAGE PYTHON
    RUNTIME_VERSION = '3.11'
    PACKAGES = ('snowflake-snowpark-python', 'requests')
    IMPORTS = ('/src/zoominfo_client.py', '/src/handlers.py')
    HANDLER = 'handlers.lookup_search'
    EXTERNAL_ACCESS_INTEGRATIONS = (REFERENCE('zoominfo_external_access'))
    SECRETS = ('zoominfo_oauth_client' = REFERENCE('zoominfo_oauth_client'));

  CREATE OR REPLACE PROCEDURE core.lookup_enrich_impl(entity STRING, field_type STRING)
    RETURNS VARIANT
    LANGUAGE PYTHON
    RUNTIME_VERSION = '3.11'
    PACKAGES = ('snowflake-snowpark-python', 'requests')
    IMPORTS = ('/src/zoominfo_client.py', '/src/handlers.py')
    HANDLER = 'handlers.lookup_enrich'
    EXTERNAL_ACCESS_INTEGRATIONS = (REFERENCE('zoominfo_external_access'))
    SECRETS = ('zoominfo_oauth_client' = REFERENCE('zoominfo_oauth_client'));

  CREATE OR REPLACE PROCEDURE core.get_usage_impl()
    RETURNS VARIANT
    LANGUAGE PYTHON
    RUNTIME_VERSION = '3.11'
    PACKAGES = ('snowflake-snowpark-python', 'requests')
    IMPORTS = ('/src/zoominfo_client.py', '/src/handlers.py')
    HANDLER = 'handlers.get_usage'
    EXTERNAL_ACCESS_INTEGRATIONS = (REFERENCE('zoominfo_external_access'))
    SECRETS = ('zoominfo_oauth_client' = REFERENCE('zoominfo_oauth_client'));

  CREATE OR REPLACE PROCEDURE core.test_connection_impl()
    RETURNS VARIANT
    LANGUAGE PYTHON
    RUNTIME_VERSION = '3.11'
    PACKAGES = ('snowflake-snowpark-python', 'requests')
    IMPORTS = ('/src/zoominfo_client.py', '/src/handlers.py')
    HANDLER = 'handlers.test_connection'
    EXTERNAL_ACCESS_INTEGRATIONS = (REFERENCE('zoominfo_external_access'))
    SECRETS = ('zoominfo_oauth_client' = REFERENCE('zoominfo_oauth_client'));

  -- Additional GTM endpoints (scoops / news / intent search; scoops / technologies /
  -- corporate-hierarchy enrich; intent-topics lookup).
  CREATE OR REPLACE PROCEDURE core.search_scoops_impl(criteria VARIANT, page_number INT, page_size INT)
    RETURNS VARIANT LANGUAGE PYTHON RUNTIME_VERSION = '3.11'
    PACKAGES = ('snowflake-snowpark-python', 'requests')
    IMPORTS = ('/src/zoominfo_client.py', '/src/handlers.py') HANDLER = 'handlers.search_scoops'
    EXTERNAL_ACCESS_INTEGRATIONS = (REFERENCE('zoominfo_external_access'))
    SECRETS = ('zoominfo_oauth_client' = REFERENCE('zoominfo_oauth_client'));

  CREATE OR REPLACE PROCEDURE core.search_news_impl(criteria VARIANT, page_number INT, page_size INT)
    RETURNS VARIANT LANGUAGE PYTHON RUNTIME_VERSION = '3.11'
    PACKAGES = ('snowflake-snowpark-python', 'requests')
    IMPORTS = ('/src/zoominfo_client.py', '/src/handlers.py') HANDLER = 'handlers.search_news'
    EXTERNAL_ACCESS_INTEGRATIONS = (REFERENCE('zoominfo_external_access'))
    SECRETS = ('zoominfo_oauth_client' = REFERENCE('zoominfo_oauth_client'));

  CREATE OR REPLACE PROCEDURE core.search_intent_impl(criteria VARIANT, page_number INT, page_size INT)
    RETURNS VARIANT LANGUAGE PYTHON RUNTIME_VERSION = '3.11'
    PACKAGES = ('snowflake-snowpark-python', 'requests')
    IMPORTS = ('/src/zoominfo_client.py', '/src/handlers.py') HANDLER = 'handlers.search_intent'
    EXTERNAL_ACCESS_INTEGRATIONS = (REFERENCE('zoominfo_external_access'))
    SECRETS = ('zoominfo_oauth_client' = REFERENCE('zoominfo_oauth_client'));

  CREATE OR REPLACE PROCEDURE core.enrich_scoops_impl(company_id STRING)
    RETURNS VARIANT LANGUAGE PYTHON RUNTIME_VERSION = '3.11'
    PACKAGES = ('snowflake-snowpark-python', 'requests')
    IMPORTS = ('/src/zoominfo_client.py', '/src/handlers.py') HANDLER = 'handlers.enrich_scoops'
    EXTERNAL_ACCESS_INTEGRATIONS = (REFERENCE('zoominfo_external_access'))
    SECRETS = ('zoominfo_oauth_client' = REFERENCE('zoominfo_oauth_client'));

  CREATE OR REPLACE PROCEDURE core.enrich_technologies_impl(company_id STRING)
    RETURNS VARIANT LANGUAGE PYTHON RUNTIME_VERSION = '3.11'
    PACKAGES = ('snowflake-snowpark-python', 'requests')
    IMPORTS = ('/src/zoominfo_client.py', '/src/handlers.py') HANDLER = 'handlers.enrich_technologies'
    EXTERNAL_ACCESS_INTEGRATIONS = (REFERENCE('zoominfo_external_access'))
    SECRETS = ('zoominfo_oauth_client' = REFERENCE('zoominfo_oauth_client'));

  CREATE OR REPLACE PROCEDURE core.enrich_corporate_hierarchy_impl(match_input VARIANT, output_fields ARRAY)
    RETURNS VARIANT LANGUAGE PYTHON RUNTIME_VERSION = '3.11'
    PACKAGES = ('snowflake-snowpark-python', 'requests')
    IMPORTS = ('/src/zoominfo_client.py', '/src/handlers.py') HANDLER = 'handlers.enrich_corporate_hierarchy'
    EXTERNAL_ACCESS_INTEGRATIONS = (REFERENCE('zoominfo_external_access'))
    SECRETS = ('zoominfo_oauth_client' = REFERENCE('zoominfo_oauth_client'));

  CREATE OR REPLACE PROCEDURE core.lookup_intent_topics_impl()
    RETURNS VARIANT LANGUAGE PYTHON RUNTIME_VERSION = '3.11'
    PACKAGES = ('snowflake-snowpark-python', 'requests')
    IMPORTS = ('/src/zoominfo_client.py', '/src/handlers.py') HANDLER = 'handlers.lookup_intent_topics'
    EXTERNAL_ACCESS_INTEGRATIONS = (REFERENCE('zoominfo_external_access'))
    SECRETS = ('zoominfo_oauth_client' = REFERENCE('zoominfo_oauth_client'));

  RETURN 'api procedures created';
END;
$$;

-- Create the API procedures only once BOTH references are bound. Probes each
-- reference with SYSTEM$GET_ALL_REFERENCES(<name>) (which throws when unbound),
-- so binding either reference triggers this and creation happens when the
-- second one lands. Order-independent.
CREATE OR REPLACE PROCEDURE core.create_api_procedures_if_ready()
  RETURNS STRING
  LANGUAGE SQL
AS
$$
DECLARE
  secret_ok BOOLEAN DEFAULT FALSE;
  eai_ok BOOLEAN DEFAULT FALSE;
  refs STRING;
BEGIN
  -- SYSTEM$GET_ALL_REFERENCES(<ref_name>) throws if that reference has no
  -- association yet, so probe each inside its own handler and treat a throw as
  -- "not bound". Both must be bound before the API procedures can be created
  -- (their SECRETS/EAI clauses are validated against bound references at CREATE).
  BEGIN
    refs := SYSTEM$GET_ALL_REFERENCES('ZOOMINFO_OAUTH_CLIENT');
    secret_ok := (refs IS NOT NULL AND refs <> '[]');
  EXCEPTION
    WHEN OTHER THEN secret_ok := FALSE;
  END;
  BEGIN
    refs := SYSTEM$GET_ALL_REFERENCES('ZOOMINFO_EXTERNAL_ACCESS');
    eai_ok := (refs IS NOT NULL AND refs <> '[]');
  EXCEPTION
    WHEN OTHER THEN eai_ok := FALSE;
  END;

  IF (secret_ok AND eai_ok) THEN
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
-- Public wrapper procedures (created at install; no reference clauses)
-- Consumers cannot directly call the reference-bearing *_impl procedures, so
-- these thin SQL wrappers — which the consumer CALLs — invoke the impls in the
-- app's owner rights. The impls are created later by create_api_procedures()
-- once both references are bound; these wrappers just need to exist and be
-- granted. A wrapper called before the impl exists returns a clear error.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE core.enrich_contact(match_input VARIANT, output_fields ARRAY)
  RETURNS VARIANT
  LANGUAGE SQL
AS
$$
DECLARE
  result VARIANT;
BEGIN
  CALL core.enrich_contact_impl(:match_input, :output_fields) INTO :result;
  RETURN :result;
END;
$$;
GRANT USAGE ON PROCEDURE core.enrich_contact(VARIANT, ARRAY) TO APPLICATION ROLE app_public;

CREATE OR REPLACE PROCEDURE core.enrich_company(match_input VARIANT, output_fields ARRAY)
  RETURNS VARIANT
  LANGUAGE SQL
AS
$$
DECLARE
  result VARIANT;
BEGIN
  CALL core.enrich_company_impl(:match_input, :output_fields) INTO :result;
  RETURN :result;
END;
$$;
GRANT USAGE ON PROCEDURE core.enrich_company(VARIANT, ARRAY) TO APPLICATION ROLE app_public;

CREATE OR REPLACE PROCEDURE core.search_contact(criteria VARIANT, page_number INT, page_size INT)
  RETURNS VARIANT
  LANGUAGE SQL
AS
$$
DECLARE
  result VARIANT;
BEGIN
  CALL core.search_contact_impl(:criteria, :page_number, :page_size) INTO :result;
  RETURN :result;
END;
$$;
GRANT USAGE ON PROCEDURE core.search_contact(VARIANT, INT, INT) TO APPLICATION ROLE app_public;

CREATE OR REPLACE PROCEDURE core.search_company(criteria VARIANT, page_number INT, page_size INT)
  RETURNS VARIANT
  LANGUAGE SQL
AS
$$
DECLARE
  result VARIANT;
BEGIN
  CALL core.search_company_impl(:criteria, :page_number, :page_size) INTO :result;
  RETURN :result;
END;
$$;
GRANT USAGE ON PROCEDURE core.search_company(VARIANT, INT, INT) TO APPLICATION ROLE app_public;

CREATE OR REPLACE PROCEDURE core.lookup_search(entity STRING, field_type STRING)
  RETURNS VARIANT
  LANGUAGE SQL
AS
$$
DECLARE
  result VARIANT;
BEGIN
  CALL core.lookup_search_impl(:entity, :field_type) INTO :result;
  RETURN :result;
END;
$$;
GRANT USAGE ON PROCEDURE core.lookup_search(STRING, STRING) TO APPLICATION ROLE app_public;

CREATE OR REPLACE PROCEDURE core.lookup_enrich(entity STRING, field_type STRING)
  RETURNS VARIANT
  LANGUAGE SQL
AS
$$
DECLARE
  result VARIANT;
BEGIN
  CALL core.lookup_enrich_impl(:entity, :field_type) INTO :result;
  RETURN :result;
END;
$$;
GRANT USAGE ON PROCEDURE core.lookup_enrich(STRING, STRING) TO APPLICATION ROLE app_public;

CREATE OR REPLACE PROCEDURE core.get_usage()
  RETURNS VARIANT
  LANGUAGE SQL
AS
$$
DECLARE
  result VARIANT;
BEGIN
  CALL core.get_usage_impl() INTO :result;
  RETURN :result;
END;
$$;
GRANT USAGE ON PROCEDURE core.get_usage() TO APPLICATION ROLE app_public;

CREATE OR REPLACE PROCEDURE core.test_connection()
  RETURNS VARIANT
  LANGUAGE SQL
AS
$$
DECLARE
  result VARIANT;
BEGIN
  CALL core.test_connection_impl() INTO :result;
  RETURN :result;
END;
$$;
GRANT USAGE ON PROCEDURE core.test_connection() TO APPLICATION ROLE app_public;

-- Additional GTM endpoint wrappers -------------------------------------------
CREATE OR REPLACE PROCEDURE core.search_scoops(criteria VARIANT, page_number INT, page_size INT)
  RETURNS VARIANT LANGUAGE SQL AS
$$ DECLARE result VARIANT;
BEGIN CALL core.search_scoops_impl(:criteria, :page_number, :page_size) INTO :result; RETURN :result; END; $$;
GRANT USAGE ON PROCEDURE core.search_scoops(VARIANT, INT, INT) TO APPLICATION ROLE app_public;

CREATE OR REPLACE PROCEDURE core.search_news(criteria VARIANT, page_number INT, page_size INT)
  RETURNS VARIANT LANGUAGE SQL AS
$$ DECLARE result VARIANT;
BEGIN CALL core.search_news_impl(:criteria, :page_number, :page_size) INTO :result; RETURN :result; END; $$;
GRANT USAGE ON PROCEDURE core.search_news(VARIANT, INT, INT) TO APPLICATION ROLE app_public;

CREATE OR REPLACE PROCEDURE core.search_intent(criteria VARIANT, page_number INT, page_size INT)
  RETURNS VARIANT LANGUAGE SQL AS
$$ DECLARE result VARIANT;
BEGIN CALL core.search_intent_impl(:criteria, :page_number, :page_size) INTO :result; RETURN :result; END; $$;
GRANT USAGE ON PROCEDURE core.search_intent(VARIANT, INT, INT) TO APPLICATION ROLE app_public;

CREATE OR REPLACE PROCEDURE core.enrich_scoops(company_id STRING)
  RETURNS VARIANT LANGUAGE SQL AS
$$ DECLARE result VARIANT;
BEGIN CALL core.enrich_scoops_impl(:company_id) INTO :result; RETURN :result; END; $$;
GRANT USAGE ON PROCEDURE core.enrich_scoops(STRING) TO APPLICATION ROLE app_public;

CREATE OR REPLACE PROCEDURE core.enrich_technologies(company_id STRING)
  RETURNS VARIANT LANGUAGE SQL AS
$$ DECLARE result VARIANT;
BEGIN CALL core.enrich_technologies_impl(:company_id) INTO :result; RETURN :result; END; $$;
GRANT USAGE ON PROCEDURE core.enrich_technologies(STRING) TO APPLICATION ROLE app_public;

CREATE OR REPLACE PROCEDURE core.enrich_corporate_hierarchy(match_input VARIANT, output_fields ARRAY)
  RETURNS VARIANT LANGUAGE SQL AS
$$ DECLARE result VARIANT;
BEGIN CALL core.enrich_corporate_hierarchy_impl(:match_input, :output_fields) INTO :result; RETURN :result; END; $$;
GRANT USAGE ON PROCEDURE core.enrich_corporate_hierarchy(VARIANT, ARRAY) TO APPLICATION ROLE app_public;

CREATE OR REPLACE PROCEDURE core.lookup_intent_topics()
  RETURNS VARIANT LANGUAGE SQL AS
$$ DECLARE result VARIANT;
BEGIN CALL core.lookup_intent_topics_impl() INTO :result; RETURN :result; END; $$;
GRANT USAGE ON PROCEDURE core.lookup_intent_topics() TO APPLICATION ROLE app_public;

-- ---------------------------------------------------------------------
-- Flatten helper (table function)
-- ZoomInfo returns records under data[] as {id, type, attributes:{...}}. The
-- procedures return that whole VARIANT; this UDTF turns it into one row per
-- record so results are query-friendly. Created at install (no references),
-- so it's always available. Usage:
--   SELECT f.* FROM TABLE(core.flatten_records(
--     (CALL core.search_company(PARSE_JSON('{"companyName":"ZoomInfo"}'), 1, 25)))) f;
-- (or pass any VARIANT you captured from a procedure result.)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION core.flatten_records(response VARIANT)
  RETURNS TABLE (id STRING, record_type STRING, attributes VARIANT, meta VARIANT)
  AS
$$
  SELECT
    value:id::STRING           AS id,
    value:type::STRING         AS record_type,
    value:attributes           AS attributes,
    value:meta                 AS meta
  FROM LATERAL FLATTEN(input => response:data)
$$;
GRANT USAGE ON FUNCTION core.flatten_records(VARIANT) TO APPLICATION ROLE app_public;
