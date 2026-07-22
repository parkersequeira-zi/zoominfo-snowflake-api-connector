# ZoomInfo Connector

Call the ZoomInfo GTM API from Snowflake SQL. The app authenticates to ZoomInfo with **OAuth
Client Credentials** using **your organization's own ZoomInfo API credentials** — calls hit your
ZoomInfo account. Setup is two one-time admin steps (create a **secret** with your ZoomInfo
`client_id`/`client_secret`, and an **external access integration** so the app can reach
`api.zoominfo.com`), then bind both to the app.

## 1. Get your ZoomInfo API credentials

In the ZoomInfo DevPortal, obtain an **API application** with the **Client Credentials** grant and
note its **Client ID** and **Client Secret**. (This is the same credential type ZoomInfo's other
API integrations use — no per-user sign-in.)

## 2. Create the secret and external access integration (admin, once)

```sql
-- Your ZoomInfo API credentials as a JSON string.
CREATE OR REPLACE SECRET ZI_OAUTH_CLIENT_SECRET
  TYPE = GENERIC_STRING
  SECRET_STRING = '{
    "client_id": "YOUR_CLIENT_ID",
    "client_secret": "YOUR_CLIENT_SECRET"
  }';

-- Where the app is allowed to make outbound calls.
CREATE OR REPLACE NETWORK RULE ZI_API_NETWORK_RULE
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('api.zoominfo.com');

-- Lets the app reach ZoomInfo, using the secret above.
CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION EXTERNAL_ACCESS_INTEGRATION_ZI_API
  ALLOWED_NETWORK_RULES = (ZI_API_NETWORK_RULE)
  ALLOWED_AUTHENTICATION_SECRETS = (ZI_OAUTH_CLIENT_SECRET)
  ENABLED = TRUE;
```

## 3. Bind them to the app

Open the app → **Security / Configuration**, and bind:
- **ZoomInfo API credentials** → `ZI_OAUTH_CLIENT_SECRET`
- **ZoomInfo API external access** → `EXTERNAL_ACCESS_INTEGRATION_ZI_API`

(Equivalent SQL: `ALTER APPLICATION <app> SET REFERENCE ...`.) Binding **both** references triggers
the app to create its API procedures. No sign-in step — the app authenticates with your bound
credentials.

## 4. Call the procedures

**Enrich a contact** (by email; pass `[]` for default output fields):

```sql
CALL core.enrich_contact(
  PARSE_JSON('[{"emailAddress": "henry@zoominfo.com"}]'),
  ARRAY_CONSTRUCT('id', 'email', 'firstName', 'lastName', 'companyName')
);
```

**Enrich a company** (by website):

```sql
CALL core.enrich_company(
  PARSE_JSON('[{"companyWebsite": "www.zoominfo.com"}]'),
  ARRAY_CONSTRUCT('id', 'name', 'website', 'revenue', 'employeeCount')
);
```

**Search contacts** (page 1, 25 per page):

```sql
CALL core.search_contact(
  PARSE_JSON('{"companyName": "ZoomInfo", "jobTitle": "engineer"}'),
  1, 25
);
```

**Search companies**:

```sql
CALL core.search_company(
  PARSE_JSON('{"metroRegion": "usa.california.sanfrancisco", "industryCodes": "software"}'),
  1, 25
);
```

Each procedure returns a `VARIANT` — the raw ZoomInfo JSON:API response. Flatten `data` with
`LATERAL FLATTEN` to turn results into rows, e.g.:

```sql
WITH r AS (
  CALL core.enrich_contact(PARSE_JSON('[{"emailAddress":"henry@zoominfo.com"}]'), ARRAY_CONSTRUCT())
)
SELECT
  f.value:id::STRING             AS contact_id,
  f.value:attributes:email::STRING AS email,
  f.value:meta:matchStatus::STRING AS match_status
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) AS r,
     LATERAL FLATTEN(input => r.$1:data) AS f;
```

**Discover valid fields & check usage** (all free — no credits):

```sql
-- Confirm the app is configured and can reach ZoomInfo (returns a plain status).
CALL core.test_connection();

-- Which output fields can I request from company enrich (and do I have access)?
CALL core.lookup_enrich('company', 'output');

-- Which fields can I filter on in company search?
CALL core.lookup_search('company', 'input');

-- My account's current API usage and limits
CALL core.get_usage();
```

## Usage & limits

- The app must have **both references bound** (credentials secret + external access); procedures
  called before that return a clear configuration error.
- **Enrich** accepts up to **25** inputs per call and consumes credits per matched record.
- **Search** returns identifiers and boolean "hints" (no credits) — use enrich for full detail.
- **Lookup** (`lookup_search` / `lookup_enrich`) and **`get_usage`** are free — use lookup to
  discover valid filter values and output-field names before building search/enrich calls.
- The account access token is fetched via Client Credentials and cached; it is re-fetched
  automatically when it expires (or on a `401`).
- On HTTP 429 the app retries with backoff, honoring `Retry-After`. Persistent errors surface as a
  Snowflake error carrying the ZoomInfo status code and response body.
