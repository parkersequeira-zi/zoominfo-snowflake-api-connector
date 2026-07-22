-- =====================================================================
-- ZoomInfo Native App — consumer object setup (POC)
--
-- Run these as:
--   ROLE     SCH_ZI_API_NATIVE_APP_DEV_PRODUCT_WRITE_ROLE
--   DATABASE DEV_PRODUCT
--   SCHEMA   ZI_API_NATIVE_APP
--
-- The developer (using the schema-scoped write role above) creates the
-- NETWORK RULE and SECRET. The Snowflake team owns the schema, database, and
-- the EXTERNAL_ACCESS_INTEGRATION_ZI_API object that binds these two.
--
-- SECURITY: SECRET_STRING is a placeholder in the committed version of this
-- file. Fill in the real value LOCALLY before running; do NOT commit the real
-- credential to git.
-- =====================================================================

USE ROLE SCH_ZI_API_NATIVE_APP_DEV_PRODUCT_WRITE_ROLE;
USE DATABASE DEV_PRODUCT;
USE SCHEMA ZI_API_NATIVE_APP;

-- Network rule: allow outbound access to the ZoomInfo API
CREATE OR REPLACE NETWORK RULE ZI_API_NETWORK_RULE
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('api.zoominfo.com');

-- Secret: holds the OAuth client credentials for the app
CREATE OR REPLACE SECRET ZI_OAUTH_CLIENT_SECRET
  TYPE = GENERIC_STRING
  SECRET_STRING = '<PLACEHOLDER_REPLACE_BEFORE_RUNNING>';

