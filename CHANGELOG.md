# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/). While the version is 0.x, a minor version
may change the API; each such change is listed here.

## [Unreleased]

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
