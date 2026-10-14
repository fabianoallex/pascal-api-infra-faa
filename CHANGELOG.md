# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/). While the version is 0.x, a minor version
may change the API; each such change is listed here.

## [Unreleased]

### Added

- **`${TENANT.alias}` in tenant SQL, for a JOIN.** `TTenantFilter.Prepare` replaces each
  `${TENANT.c}` with `c.TENANT_ID = :TENANT_ID` (plain `${TENANT}` is unchanged). Measured on
  SQLite: plain `${TENANT}` with two joined tables that have the column is "ambiguous column
  name", and a join whose `ON` lacks the tenant returns the other tenants' joined rows. Each
  joined table gets its own tag, in its `ON` (`docs/multitenancy-design.md`, decision 8).
- **Sample 03: a JOIN of two tenant tables.** `STATES` (migration 3), `POST /states` and
  `GET /cities/:code/details` (a `LEFT JOIN` with `${TENANT.c}` and `${TENANT.s}`).
  `tools/http_scenarios_tenants.sh` checks it (84 checks): another tenant's state on the shared
  database must not be joined; with the state's tag left out of `ON`, 2 checks failed, and moved
  to `WHERE`, 3.

## [0.13.0] - 2026-10-14

The multi-tenancy follow-ups (`tenant.id` in the log and spans, rate limit by plan, the catalog
from a control database) and two access-log fixes on Delphi.

### Security

- **A client could hide a request from the access log on Delphi.** `TLoggerMiddleware` marked
  each request with the header name `:pascalapi-logged`, assuming no client can send a name
  starting with ':'. Indy (the Delphi console provider) kept a raw `:pascalapi-logged: 1` line,
  so the logger skipped that request: no access line and no server span (measured on Delphi 12
  Win32 and Win64; fpWeb on FPC cuts the name at the first ':' and wasn't affected). Present
  since 0.8.0. The mark's name now ends with a line feed, which no HTTP parser leaves in a
  header name; so does the tenant middleware's (`':pascalapi-tenant'#10`), which also removes
  its name from every request before deciding. `tools/http_scenarios.sh` and
  `tools/http_scenarios_tenants.sh` send such lines with a socket.

### Changed

- **Minimum pascal-common-faa is 1.8.1** (`PascalApi.Dto`, the `.lpk`). On Delphi for Windows,
  with stdout in a file or a pipe (a service, Docker), the end of the last access line stayed
  in the RTL's 128-byte buffer until more output came, and was lost if the process died: the
  RTL flushes `Writeln` only for a console. pascal-common-faa 1.8.1's `SafeWriteln` flushes on
  both compilers. Found by sample 03's scenarios on Delphi 12 Win32/Win64 (a JSON access line
  cut at `...,"dur`).

### Added

- `TLoggerMiddleware.AddField(AName, AValueOf)`: an application's field, read after the handler
  (a plain `TRequestValueFunc`), in the access line and as an attribute of the server span; and
  `AccessLogLine`/`AccessLogJson` overloads with `TLogFields` (` name=value` in text, quoted
  when needed; a string member in JSON). None by default.
- `TRateLimitOptions.LimitFor`: the limit of each request (e.g. by the tenant's plan); nil, or a
  result of 0 or less, is `Limit`. `X-RateLimit-Limit` follows it.
- `PascalApi.Tenancy`: `TTenantInfo.Plan` (`plan:<name>` in `TConfigTenantCatalog`),
  `TDbTenantCatalog` (the catalog from a control database, through the application's SQL by
  name: columns `ID`, `MODE`, `SUSPENDED`, `PLAN`), `TCachedTenantCatalog` (another catalog's
  found tenants for a TTL, with `Invalidate`/`InvalidateAll`). `PascalApi.Horse.Tenancy`:
  `TenantIdOf`, for `TLoggerMiddleware.AddField('tenant.id', TenantIdOf)`.
- `samples/03-tenants`: the catalog in `control.sqlite` (seeded from `TENANTS`) through
  `TDbTenantCatalog` and `TCachedTenantCatalog`; rate limit per tenant with the plan `free`
  (tenant `hooli`) at 5 a minute; `tenant.id` in the access log and on the spans, exported to an
  OpenTelemetry collector (checked in CI by `tools/otlp_check.py`); idle tenant databases closed
  after `DB_IDLE_SECONDS`. `tools/http_scenarios_tenants.sh`: 73 checks.
- `tools/test_http.sh` and `tools/test_http_docker.sh` pass `SERVER_LOG` (the server's output
  file) to the scenario scripts.

## [0.12.0] - 2026-10-13

Multi-tenancy, opt-in (`docs/multitenancy-design.md`): ten decisions taken with the user, proven
first in a sample (`samples/03-tenants`) on both compilers, then moved to the library. An
application that doesn't use the two new units sees no change: samples 01 and 02 pass their
scenarios unchanged.

### Added

- `PascalApi.Tenancy` and `src/horse/PascalApi.Horse.Tenancy`: multi-tenancy, opt-in (no other
  unit uses them), promoted from `samples/03-tenants` (`docs/multitenancy-design.md`).
  `TConfigTenantCatalog` (tenants from one configuration string), `TTenantDataResolver` (an
  `IDBFactory` per database: `tenant_<id>` for a dedicated tenant, `shared` for the others,
  created on first use under a lock, pools named `dedicated`/`shared`; with `AIdleSeconds`, a
  database no request asked for in that time is dropped), `TTenantFilter.Prepare`,
  `CheckTenant`, `TenantIdFromClaims`, `TenantRejection` (401 no tenant or a removed one, 403
  suspended with `"code":"tenant_suspended"`), and `TTenantMiddleware` (the claim `tenant_id`
  by default, after `TJwtMiddleware`; `Current(AReq)`). Tested in `PascalApi.TenancyTests`
  (24 tests); sample 03 now uses them.
- `TApiMessages`: `TenantMissing`, `TenantUnknown`, `TenantSuspended` (English and Portuguese).
- `samples/03-tenants` (`TenantApiSample`): a multi-tenant API on the units above. The tenant
  comes from the token's `tenant_id` claim; dedicated tenants get a database each, the others
  share one, and every row carries `TENANT_ID`. `tools/http_scenarios_tenants.sh` (57 checks) tries one tenant's
  token on another's rows in both modes, and checks the 401/403 answers for a removed, missing
  or suspended tenant; it runs in `tools/test_http.sh` and in CI. Measured on the way: a
  forgotten bind of `:TENANT_ID` is a silent 404 on SQLdb/SQLite (so `TTenantFilter.Prepare`
  sets the condition and the parameter in one call), and pools sharing a metric name add up.

### Changed

- `external/pascal-db-faa` on v0.14.0, whose connection pool records OpenTelemetry's
  `db.client.connection.*` metrics on `PcMetrics` by itself: sample 02's `/metrics` shows them
  with no change in this library. `tools/http_scenarios_db.sh` checks them (65 checks): the
  connection count by state (`idle`, `used`) of the pool `sqlite`, `db_client_connection_max` 5,
  and the `db_client_connection_wait_time_seconds` count growing with the requests.
- CI: `tools/promtool_check.sh` runs `promtool check metrics` and accepts one lint warning
  only, the `_count` suffix of `db_client_connection_count` (the OpenTelemetry name; promtool
  2.53 can't turn that rule off). A format error or any other lint warning still fails.

Verified: 239 unit tests with 0 leaks on FPC 3.2.2 Win64 and Linux x86_64 and Delphi 12 CE Win32
and Win64; HTTP scenarios 146 (sample 01) + 65 (sample 02) + 57 (sample 03) on FPC Windows and
Linux, and sample 03's 57 on Delphi Win32 and Win64.

## [0.11.0] - 2026-10-12

Phase D of the observability design (`docs/observability-design.md`): the span contracts moved
to pascal-common-faa 1.7.0 (`PascalCommon.Tracing`), so pascal-db-faa 0.13.0, pascal-redis-faa
0.2.0 and pascal-amqp-faa 0.2.0 open spans that join an API's trace without depending on this
library.

### Removed (breaking)

- `PascalApi.Tracing` (announced as unstable in 0.10.0). Use pascal-common-faa's
  `PascalCommon.Tracing`: `TTracing` is `TPcTracing`, `ISpan` is `IPcSpan`, `ISpanExporter` is
  `IPcSpanExporter`, `TSpanData` is `TPcSpanData`, `TTracingOptions` is `TPcTracingOptions`,
  `UnixNanoOfLocal` is `PcUnixNanoOfLocal`, and so on (the name map is in pascal-common-faa's
  `docs/migrating.md`). `TOtlpHttpExporter` implements `IPcSpanExporter`.

### Changed

- `TPcTracingOptions.FromEnvironment(AName, AVersion)` reads only the process environment;
  `TTracingOptions.FromEnvironment` read through `TAppConfig`, so a `.env` file counted. To keep
  that, pass the new `ReadAppConfig` (`PascalApi.Config`) as the lookup:
  `TPcTracingOptions.FromEnvironment('cities-api', '1.0.0', ReadAppConfig)`. Both samples do.
- `TLogProc` (`PascalApi.Http`) is now declared as pascal-common-faa's `TPcLogProc` (same
  signature), so it goes to `TPcTracing.Start` as it is.
- `ParseKeyValueList` moved from `PascalApi.Tracing` to `PascalApi.Otlp` (only the exporter uses
  it).
- Requires pascal-common-faa **1.7.0** or later (`PascalApi.Dto`, `MinVersion` in the `.lpk`).
  pascal-db-faa 0.13.0, pascal-redis-faa 0.2.0 and pascal-amqp-faa 0.2.0 require 1.8.0; the
  submodules here are pascal-common-faa v1.8.0 and pascal-db-faa v0.13.0.

### Added

- `ReadAppConfig` (`PascalApi.Config`): `TAppConfig.Get(AName, '')` as a plain function.
- CI: `tools/otlp_check.py` checks pascal-db-faa's spans from sample 02 (no code change there):
  `SELECT` client spans with `db.system.name` `sqlite` under the request's server span, and
  committed `transaction` spans with their statements as children.

Verified: 215 unit tests with 0 leaks and 146 + 61 HTTP checks on FPC 3.2.2 Win64 and Linux
x86_64 and Delphi 12 Win32 and Win64; on Linux (CI), an OpenTelemetry Collector accepted every batch and
`tools/otlp_check.py` passed, the new database checks included.

## [0.10.0] - 2026-10-09

Phase C of the observability design (`docs/observability-design.md`): spans exported to an
OpenTelemetry collector over OTLP/HTTP.

### Added

- `PascalApi.Tracing` (**unstable API**: it moves to pascal-common-faa in phase D): `ISpan`,
  `TTracing.StartSpan` (a child of the thread's current span), `StartSpanWith`, `Current`,
  parent-based sampling with a ratio for new traces (`ShouldSample`), and a batch processor on
  its own thread with a bounded queue (oldest dropped, `DroppedCount`) handing spans to an
  `ISpanExporter`; `TTracingOptions.FromEnvironment` reads `OTEL_SERVICE_NAME`,
  `OTEL_RESOURCE_ATTRIBUTES`, `OTEL_TRACES_SAMPLER_ARG` and `OTEL_BSP_*`. Not started, every
  call still works and records nothing.
- `PascalApi.Otlp`: `OtlpTracesJson` (the OTLP/HTTP JSON body, pure) and `TOtlpHttpExporter`
  (`OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`, `OTEL_EXPORTER_OTLP_ENDPOINT`,
  `OTEL_EXPORTER_OTLP_HEADERS`, `OTEL_EXPORTER_OTLP_TIMEOUT`; fphttpclient on FPC, THTTPClient
  on Delphi).
- `TLoggerMiddleware` opens each request's server span with the ids it resolves (named
  `<method> <route>`, HTTP semantic-convention attributes, error status for a 5xx) and, when
  tracing is started, samples new traces by the ratio (the `traceparent` flag says so).
- The MCP executor wraps each tool call in a client span: MCP request -> tool call -> the
  route's server span, one trace.
- Samples export to a collector when `OTEL_EXPORTER_OTLP_ENDPOINT` is set; sample 01's
  `GET /trace` adds a child span. CI runs an OpenTelemetry Collector (contrib 0.111.0) next to
  the samples and checks what it received (`tools/otlp_check.py`, `tools/otelcol.yaml`).

Verified: 230 unit tests with 0 leaks, and 146 + 61 HTTP checks, on FPC 3.2.2 Win64 and Linux
x86_64 and Delphi 12 Win32 and Win64; on all four, an OpenTelemetry Collector accepted every
span batch and `tools/otlp_check.py` passed (on Windows, at UTC-03: the timestamps are UTC).

## [0.9.0] - 2026-10-09

Phase B of the observability design (`docs/observability-design.md`): metrics and health.

### Added

- `PascalApi.Horse.Observability` (`src/horse`):
  - `TMetricsMiddleware.New` records `http.server.request.duration` (histogram, seconds,
    OpenTelemetry's buckets; labels `http.request.method`, `http.route`,
    `http.response.status_code`) and `http.server.active_requests` (up-down counter) in
    pascal-common-faa's `PcMetrics`, or a registry given to it.
  - `TMetricsEndpoint.Register('/metrics')`: the registry in the Prometheus text format.
  - `THealthEndpoint`: `GET <path>/live` and `GET <path>/ready`, which runs the checks given to
    `AddCheck` (200, or 503 when one returns False or raises; failure reasons to an optional
    `TLogProc`, never to the client).
- `PascalApi.Http`: `MetricMethod` (unknown methods as `_OTHER`), `MetricRoute` (the route
  template, never the raw path; `''` on a partial match), `HealthJson` and `THealthCheckResult`.
- Samples: both use the metrics middleware and serve `/metrics` and `/health`; sample 01 has a
  `maintenance` readiness check switched by `PUT /maintenance`, sample 02 a `database` check
  (`SELECT 1` through the pool). CI checks both samples' `/metrics` with Prometheus' `promtool`
  2.53.0.

### Changed

- Requires **pascal-common-faa 1.6.0** (`PascalCommon.Metrics`).

### Fixed

- README: the version line still said 0.7.0 in the 0.8.0 release.

Verified: 209 unit tests with 0 leaks, and 146 + 61 HTTP checks, on FPC 3.2.2 Win64 and Linux
x86_64 and Delphi 12 Win32 and Win64; `promtool check metrics` on both samples' `/metrics` from
all four builds.

## [0.8.0] - 2026-10-09

Phase A of the observability design (`docs/observability-design.md`): W3C trace context and
correlated logs.

### Changed

- **The request id is the W3C trace id** (breaking): `X-Request-Id` on the request and the
  response, and the last field of the access line, are 32 lowercase hex digits instead of 8. The
  id comes from a valid incoming `traceparent`, else from an incoming `X-Request-Id` of exactly
  32 lowercase hex digits (nginx's `$request_id`), else it is new; any other `X-Request-Id` is
  ignored, as before.
- `TLoggerMiddleware` also sets `traceparent` on the request, naming a new span for the request
  (a child of the caller's), and passes `tracestate` on when the `traceparent` was valid: what a
  handler's outgoing call should send.
- The error handler's line ends with ` trace_id=<id>` when `TLoggerMiddleware` is in use.
- The MCP executor forwards `traceparent` and `tracestate`: a tool call's request is in the MCP
  request's trace. `TMcpForward` has two new fields, `TraceParent` and `TraceState`.
- Requires **pascal-common-faa 1.5.0** (`PascalCommon.TraceContext`), checked in `PascalApi.Dto`
  and the `.lpk`.

### Added

- `ResolveRequestTrace` and `TRequestTrace` (`PascalApi.Http`): the trace context of a request
  from its headers, pure.
- JSON access log: `TLoggerMiddleware.New(AOnLog, alfJson)` writes one object per request
  (`AccessLogJson`) with `trace_id`, `span_id` and `parent_span_id`; the text line stays the
  default. `samples/02-db` uses it.
- `WithTraceId` (`PascalApi.Http`).
- `samples/01-api`: `GET /trace` returns what the handler sees (`X-Request-Id`, `traceparent`,
  `tracestate`); `tools/http_scenarios.sh` checks the trace context directly and through MCP.

### Removed

- `NewRequestId` (breaking): the id comes from `ResolveRequestTrace`.

### Fixed

- One access line and one `X-Request-Id` per request on routes that don't exist. When no
  route matches, Horse 3.3.12 runs the router a second time with `/*`, so global middlewares ran
  twice: two lines (with different ids, before this release) and two `X-Request-Id` headers. The
  logger now runs once per request.

Verified: 204 unit tests with 0 leaks, and 122 + 56 HTTP checks, on FPC 3.2.2 Win64 and Linux
x86_64 and Delphi 12 Win32 and Win64; the official MCP SDK on FPC Linux (CI).

## [0.7.0] - 2026-10-09

### Added

- Bearer authentication in the OpenAPI document (Swagger UI's Authorize button):
  `TApiDocument.BearerAuth`/`BearerFormat` write `components.securitySchemes.bearerAuth` and a
  document-wide `security` requirement; `TApiOperation.NoAuth` lifts it (`"security": []`).
  `TRouteDoc.Serve` sets them from the middleware that enforces them: when `TJwtMiddleware.New`
  (format `JWT`) or `TAuthMiddleware.Bearer` ran before it, every operation needs the token
  except the paths the middleware excludes. New `Configured`/`Excludes` class functions on both
  middlewares.

### Changed

- Documentation: the `RemoteAddr` note (measured on Delphi too), the evaluation table in
  `docs/plan.md`, check counts.

## [0.6.0] - 2026-10-09

### Removed

- **`PascalApi.Messaging`** (breaking): the broker-agnostic interfaces (`IMessageConsumer`,
  `IMessagePublisher`, `IMessageHandler`, `IMessagePayload`, `IMessagingFactory`), `TMessagingConfig`
  and `TMessagingRegistry`. No adapter implemented them on FPC and nothing used the registry. Use
  [pascal-amqp-faa](https://github.com/fabianoallex/pascal-amqp-faa) directly; for Redis and
  inter-process communication, pascal-redis-faa and pascal-pipes-faa.

### Added

- `docs/related-libraries.md`, `AGENTS.md`, and a section at the top of `CLAUDE.md` and in the
  README: the sibling libraries for messaging, Redis and IPC, as the first choice for an API built
  on this one, with how to add them.

### Migration

An application that implemented `IMessagingFactory` keeps working by moving those interfaces into
its own code (they are plain declarations, no behavior), or better, calls pascal-amqp-faa's
`TAMQPConnection`/`TAMQPChannel` directly.

## [0.5.0] - 2026-10-09

### Added

- MCP server (phase 5), protocol revision **2026-07-28** only (stateless, no `initialize`).
  `PascalApi.Mcp` (pure): the routes documented with `TRouteDoc` become tools (name from the
  `operationId`, else the origin's `McpDeriveName`; JSON Schema 2020-12 input schema flattening
  path, query and body arguments, with the DTOs' metadata; description with the returned
  fields), and the JSON-RPC dispatcher (`server/discover`, `tools/list`, `tools/call`; `_meta`
  and `MCP-Protocol-Version`/`Mcp-Method`/`Mcp-Name` header checks, with the revision's error
  codes and HTTP statuses). `src/horse/PascalApi.Horse.Mcp`: `TMcpEndpoint.Register(path,
  baseUrl, name, version[, tags[, allowedOrigins]])`; a tool call is an HTTP request to the API
  itself (fphttpclient / THTTPClient), so every middleware applies, with the caller's
  `Authorization` and address (`X-Forwarded-For`) passed on; `Origin` checked (403). Both
  samples expose `/mcp`; CI drives them with the official MCP Python SDK (`mcp` 2.0.0,
  `tools/mcp_client_check.py`). Design: `docs/mcp-design.md`.
- `PascalApi.OpenApi`: `ApiJsonSchema` (a DTO as a self-contained JSON Schema 2020-12: nested
  DTOs inline, `"type":[T,"null"]` for nullable members, `examples`) and `ApiOperationParams`
  (an operation's parameters, the Find DTO's expanded).

### Fixed (compared with delphi-api-infra-faa's MCP server)

- A GET tool's arguments go to the query string; the origin put them in a JSON body that GET
  doesn't send, so filters, page and order never reached the route.
- The caller's `Authorization` header is passed on, so tools of a JWT-protected API work.

### Changed

- Tested with Horse 3.3.12 (was 3.3.2). Horse 3.3.3 fixed the `const`/`constref` mismatch that
  kept 3.3.2 from compiling on FPC 3.2.2 for Windows, so `tools/prepare_horse.sh` and its patched
  copy (`.horse-src`) are gone: every target uses Horse unchanged. Applications on FPC for
  Windows need Horse 3.3.3 or later.

## [0.4.0] - 2026-10-08

### Added

- `TRouteDocBuilder.QueryParams<I>` (and `TApiOperation.QueryDto`): one query parameter per
  published property of a Find DTO, with the mapper's names, `IOptXxx` members not required and
  descriptions from `TApiSchema.Describe`; inherited members (page, limit, orderBy, search from
  `TFindPaginationDTOBase`) included, arrays and objects left out. `samples/02-db` documents its
  list route this way.

## [0.3.0] - 2026-10-08

### Added

- OpenAPI 3.0.3 (phase 4). `PascalApi.OpenApi`: the document from route descriptions and DTO
  types, schemas inferred from the published properties through pascal-jsonmapper-faa's
  `Members` (the names on the wire), optional interfaces as not required/nullable, enumerations,
  nested DTOs and arrays; metadata registered in code with `TApiSchema.Describe` (FPC has no
  attributes). `src/horse/PascalApi.Horse.OpenApi`: `TRouteDoc.Get(...)...Register(Handler)`
  registers and documents a route in one call; `TRouteDoc.Serve` publishes `/swagger` (Swagger
  UI from unpkg, `swagger-ui-dist` pinned) and `/swagger/doc.json`. Both samples document their
  routes; CI validates both documents with `openapi-spec-validator`. Design:
  `docs/openapi-design.md`.

### Fixed

- `TOrderBySpec.DocHint` showed the SQL expression of a tiebreaker that isn't a client field
  (a column name); such a tiebreaker is now left out of the hint.

### Changed

- Requires pascal-jsonmapper-faa 0.3.0 (`TJsonMapper.Members`).

## [0.2.0] - 2026-10-08

### Added

- `samples/02-db`: a Horse API over SQLite through pascal-db-faa (SQLdb on FPC, FireDAC on
  Delphi): migrations, paging and ordering in SQL (`TOrderBySpec` + `PdbPagingClause`), a state
  filter in a tagged SQL block, 409 from the database's primary key, NULL as JSON `null`.
  `tools/http_scenarios_db.sh` checks it over HTTP (31 checks); `tools/test_http.sh` and
  `tools/test_http_docker.sh` (CI) run both samples.

### Changed

- **Breaking:** `ParseQueryInt` and `ParseQueryStr` (`PascalApi.Pagination`) return an absent
  optional instead of `nil` for an empty or invalid value, as every getter of the library does.
  Code comparing their result with `nil` must test `HasValue` instead. A caller testing
  `HasValue` on a missing parameter got an access violation before (found by `samples/02-db`).

## [0.1.1] - 2026-10-08

### Changed

- `PaUtf8BytesToString` decodes through pascal-common-faa 1.4.0's `PcTryUtf8BytesToString`, the
  same code pascal-db-faa had (it moved to pascal-common-faa because both libraries had a copy).
  Behavior, exception (`ETextEncodingException`) and message unchanged.
- Minimum pascal-common-faa: 1.4.0 (`PascalApi.Dto`, the `.lpk`). Tested against pascal-db-faa
  0.12.1.

## [0.1.0] - 2026-10-08

First version: the infrastructure of `delphi-api-infra-faa` (Delphi only) ported to Delphi and
Lazarus/FPC 3.2.2 from one source tree. Not a drop-in replacement: DTOs map published
properties (pascal-jsonmapper-faa's contract) and each Horse middleware has one configuration
per process. OpenAPI/Swagger and MCP are not in this version.

### Added

- Core (`packages/pascal_api_infra_faa.lpk`): `PascalApi.Config` (environment, `.env`, default),
  `PascalApi.OrderBy` (client ordering through an allow-list), `PascalApi.Pagination` (query
  string to pascal-db-faa's `TPageRequest`, paged JSON envelope), `PascalApi.RateLimitState`
  (sliding window on a monotonic clock), `PascalApi.FileLog` (asynchronous, per category,
  rotated by size; `TLogTruncate` in UTF-8 bytes), `PascalApi.Dto` (DTO bases),
  `PascalApi.Messaging` (broker-agnostic contracts and registry), `PascalApi.Text` (UTF-8, MD5),
  `PascalApi.Http` (HTTP exceptions, exception to status mapping, CORS, Bearer, client IP, access
  log line, replaceable client messages in English or Portuguese), `PascalApi.Crypto` (SHA-256,
  HMAC-SHA256, Base64url), `PascalApi.Jwt` (HS256 sign and verify: alg, signature, exp, nbf),
  `PascalApi.Version`.
- Horse middlewares (`src/horse/PascalApi.Horse.Middlewares`, outside the package): error
  handler, CORS, request log with `X-Request-Id`, Bearer authentication, JWT, rate limit, and
  `TJsonSend` (JSON as UTF-8 bytes on both compilers).
- `samples/01-api`, a Horse API using every middleware, and `tools/http_scenarios.sh`, 65 checks
  over HTTP with curl.
- Depends on pascal-common-faa 1.3.0, pascal-jsonmapper-faa 0.2.1, pascal-db-faa 0.12.0 and, for
  the middlewares, Horse 3.3.2 (`72cc45f`).

Verified: 156 unit tests with 0 leaks, and the 65 HTTP checks, on FPC 3.2.2 Win64 and Linux
x86_64 and Delphi 12 CE Win32 and Win64.
