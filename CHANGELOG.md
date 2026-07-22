# Changelog

All notable changes to the ZoomInfo Connector for Snowflake are documented here.
This project adheres to [Semantic Versioning](https://semver.org/).

## [1.0.0] — unreleased

Initial release.

### Auth
- OAuth 2.0 **Client Credentials** — the consumer binds their own ZoomInfo API
  `client_id`/`client_secret` as a Snowflake `SECRET`. Account-level access token,
  cached in `app_state.token_cache` and refreshed on expiry/401. No per-user sign-in.

### Procedures (`core`)
- `enrich_contact`, `enrich_company` — up to 25 records/call (JSON:API).
- `enrich_scoops(company_id)`, `enrich_technologies(company_id)` — per-company enrich (flat
  companyId input, all fields returned). `enrich_corporate_hierarchy(match_input, output_fields)`
  — batch company enrich.
- `search_contact`, `search_company`, `search_scoops`, `search_news`, `search_intent` — paginated
  search (page size capped at 100). Intent requires the Intent product.
- `lookup_search`, `lookup_enrich`, `lookup_intent_topics` — discover valid filter values, enrich
  output fields, and intent topics (free).
- `get_usage` — account API usage and limits (free).
- `test_connection` — health check returning a plain-language status.
- `flatten_records(VARIANT)` table function — turn any JSON:API response into one row per record.

### Observability
- Non-sensitive operational logging (`log_level: info`, `trace_level: on_event`) routed to the
  consumer's event table. No criteria values, tokens, or PII are logged.

### Hardening
- Reference-bearing `*_impl` procedures behind public SQL wrappers (consumers cannot
  call reference-bearing procedures directly).
- Error messages surface a bounded, non-sensitive detail — never raw response bodies
  or the token-endpoint body.
- Input validation: enrich ≤25 inputs; search `page_size` clamped to 100; `criteria`
  must be an object.
