# ZoomInfo Connector

Call the ZoomInfo GTM API from Snowflake SQL. Users sign in to their **own** ZoomInfo account, and
the app calls ZoomInfo on their behalf. Setup has two one-time admin steps (an **external access
integration** so the app can reach `api.zoominfo.com`, and a **secret** holding your ZoomInfo OAuth
app credentials), then each user connects by signing in.

## 1. Register an OAuth app in the ZoomInfo DevPortal

Create an OAuth application (Authorization Code + PKCE). Note its **Client ID**, **Client Secret**,
the **scopes** you enabled, and add a **Sign-in Redirect URI** (the URL ZoomInfo returns the
authorization code to). You'll paste the code it shows back into the app.

## 2. Create the network rule, secret, and integration (admin, once)

Run this once in your account (as a role with the required privileges). Replace the placeholders.

```sql
-- Where the app is allowed to make outbound calls.
CREATE OR REPLACE NETWORK RULE zoominfo_network_rule
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('api.zoominfo.com');

-- Your ZoomInfo OAuth app config as a JSON string.
CREATE OR REPLACE SECRET zoominfo_oauth_client
  TYPE = GENERIC_STRING
  SECRET_STRING = '{
    "client_id": "YOUR_CLIENT_ID",
    "client_secret": "YOUR_CLIENT_SECRET",
    "redirect_uri": "https://your-registered-redirect",
    "scope": "your space delimited scopes"
  }';

-- Lets the app reach ZoomInfo, using the secret above.
CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION zoominfo_access_integration
  ALLOWED_NETWORK_RULES = (zoominfo_network_rule)
  ALLOWED_AUTHENTICATION_SECRETS = (zoominfo_oauth_client)
  ENABLED = TRUE;
```

> `redirect_uri` must **exactly** match one of the Sign-in Redirect URIs registered in the DevPortal.
> `scope` is optional; omit it to request all of the app's scopes.

## 3. Bind them to the app

Open the app → **Security / Configuration**, and bind:
- **ZoomInfo OAuth client** → `zoominfo_oauth_client`
- **ZoomInfo API external access** → `zoominfo_access_integration`

(Equivalent SQL: `ALTER APPLICATION <app> SET REFERENCE ...`.) Binding both references triggers the
app to create the four API procedures and attach the integration to the sign-in page.

## 4. Sign in (each user)

Open the app's **Connect ZoomInfo** page. Click **Open the ZoomInfo sign-in page**, log in and
approve, copy the authorization **code** ZoomInfo shows, paste it back, and click **Connect**. Your
connection is stored privately against your Snowflake user. Each user who wants to call the
procedures signs in once this way.

## 5. Call the procedures

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

## Usage & limits

- You must **sign in on the Connect page first**; procedures called before connecting return a clear
  "not connected" error.
- **Enrich** accepts up to **25** inputs per call and consumes credits per matched record.
- **Search** returns identifiers and boolean "hints" (no credits) — use enrich for full detail.
- Access tokens are refreshed automatically using your stored refresh token; if the refresh token
  is ever invalidated, reconnect on the **Connect ZoomInfo** page.
- On HTTP 429 the app retries with backoff, honoring `Retry-After`. Persistent errors surface as a
  Snowflake error carrying the ZoomInfo status code and response body.
