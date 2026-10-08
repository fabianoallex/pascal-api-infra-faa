# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/). While the version is 0.x, a minor version
may change the API; each such change is listed here.

## [Unreleased]

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
