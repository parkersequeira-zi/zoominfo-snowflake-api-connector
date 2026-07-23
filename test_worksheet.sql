-- =====================================================================
-- ZoomInfo Connector — test worksheet (paste into a Snowsight worksheet)
--
-- Prereqs (already done for the current install in ZOOMINFO-DISCOVERORG):
--   - App ZI_API_CONNECTOR_APP installed
--   - Both references bound (credentials secret + external access integration)
--   - The bound secret holds a client_credentials-enabled client_id/client_secret
--
-- Secondary roles ALL is needed so the warehouse grant (via TEAM_PRODUCT) applies.
-- Swap WH_PRODUCT_XSMALL for any warehouse your role can use.
-- =====================================================================

USE SECONDARY ROLES ALL;
USE WAREHOUSE WH_PRODUCT_XSMALL;

-- ---------------------------------------------------------------------
-- 0. Health check — always start here
-- ---------------------------------------------------------------------
CALL ZI_API_CONNECTOR_APP.core.test_connection();
-- Expect: {"status":"ok","message":"Connected to ZoomInfo.", ...}
-- If "error": the message tells you what to fix (bind secret / enable
-- client_credentials grant).

-- ---------------------------------------------------------------------
-- 1. Discover valid fields (free — no credits). Do this before search/enrich.
-- ---------------------------------------------------------------------
CALL ZI_API_CONNECTOR_APP.core.lookup_search('company', 'input');   -- filter fields for company search
CALL ZI_API_CONNECTOR_APP.core.lookup_enrich('company', 'output');  -- output fields for company enrich
CALL ZI_API_CONNECTOR_APP.core.lookup_search('contact', 'input');
CALL ZI_API_CONNECTOR_APP.core.lookup_intent_topics();              -- your licensed intent topics

-- ---------------------------------------------------------------------
-- 2. Search (free). Returns a VARIANT; flatten to rows below.
-- ---------------------------------------------------------------------
CALL ZI_API_CONNECTOR_APP.core.search_company(PARSE_JSON('{"companyName":"ZoomInfo"}'), 1, 5);

-- Flatten the previous result into rows:
SELECT
  f.value:id::STRING                 AS company_id,
  f.value:attributes:name::STRING    AS name,
  f.value:attributes:website::STRING AS website,
  f.value:attributes:revenue         AS revenue
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) r,
     LATERAL FLATTEN(input => r.$1:data) f;

CALL ZI_API_CONNECTOR_APP.core.search_contact(
  PARSE_JSON('{"companyName":"ZoomInfo","jobTitle":"engineer"}'), 1, 5);

CALL ZI_API_CONNECTOR_APP.core.search_scoops(PARSE_JSON('{}'), 1, 5);
CALL ZI_API_CONNECTOR_APP.core.search_news(PARSE_JSON('{}'), 1, 5);
-- Intent requires the Intent product; unlicensed accounts get a clean error:
CALL ZI_API_CONNECTOR_APP.core.search_intent(PARSE_JSON('{"topics":["Cloud Computing"]}'), 1, 5);

-- ---------------------------------------------------------------------
-- 3. Enrich (consumes credits per matched record). Batch endpoints take an
--    array (<=25) of match criteria + optional output fields.
-- ---------------------------------------------------------------------
CALL ZI_API_CONNECTOR_APP.core.enrich_company(
  PARSE_JSON('[{"companyWebsite":"www.zoominfo.com"}]'),
  ARRAY_CONSTRUCT('id','name','revenue','employeeCount'));

CALL ZI_API_CONNECTOR_APP.core.enrich_contact(
  PARSE_JSON('[{"emailAddress":"henry@zoominfo.com"}]'),
  ARRAY_CONSTRUCT('id','firstName','lastName','email','companyName'));

CALL ZI_API_CONNECTOR_APP.core.enrich_corporate_hierarchy(
  PARSE_JSON('[{"companyId":"344589814"}]'), ARRAY_CONSTRUCT());

-- Per-company enrich (scoops, technologies) take a single company_id string:
CALL ZI_API_CONNECTOR_APP.core.enrich_technologies('344589814');
CALL ZI_API_CONNECTOR_APP.core.enrich_scoops('344589814');

-- ---------------------------------------------------------------------
-- 4. Usage — check your credit consumption / limits (free)
-- ---------------------------------------------------------------------
CALL ZI_API_CONNECTOR_APP.core.get_usage();

-- ---------------------------------------------------------------------
-- 5. flatten_records UDTF — flatten a response VARIANT you already hold
--    (e.g. from a view/CTE). Returns (id, record_type, attributes, meta).
-- ---------------------------------------------------------------------
-- Example with a literal; swap in any procedure's VARIANT result:
SELECT * FROM TABLE(ZI_API_CONNECTOR_APP.core.flatten_records(
  PARSE_JSON('{"data":[{"id":"1","type":"Company","attributes":{"name":"Acme"}}]}')));
