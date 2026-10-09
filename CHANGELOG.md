# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/). While the version is 0.x, a minor version
may change the API; each such change is listed here.

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
