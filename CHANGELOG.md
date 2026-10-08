# Changelog

## Unreleased (0.1.0)

First version: the core ported from `delphi-api-infra-faa`, dual-compiler.

- `PascalApi.Config`, `PascalApi.OrderBy`, `PascalApi.Pagination`, `PascalApi.RateLimitState`,
  `PascalApi.FileLog`, `PascalApi.Dto`, `PascalApi.Messaging`, `PascalApi.Text`,
  `PascalApi.Version`.
- `PascalApi.Http`, `PascalApi.Crypto`, `PascalApi.Jwt` and the Horse middlewares
  (`src/horse/PascalApi.Horse.Middlewares`): error handler, CORS, request log, Bearer auth, JWT,
  rate limit. `samples/01-api`.
- Depends on pascal-common-faa 1.3.0, pascal-jsonmapper-faa 0.2.1, pascal-db-faa 0.12.0 and, for
  the middlewares, Horse 3.3.2 (`72cc45f`).
