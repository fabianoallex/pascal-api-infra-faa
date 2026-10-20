# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/). While the version is 0.x, a minor version
may change the API; each such change is listed here.

## [Unreleased]

## [0.22.0] - 2026-10-20

### Added

- `TQueryArgs` takes optional filters as they are: `OptStrings`, `OptIntegers`, `OptInt64s`,
  `OptBooleans`, `OptDoubles` and `OptFlags` (`IParams`' names), each with the `IOptXxx` and,
  optionally, the SQL tag whose block holds its condition. An absent value (or nil) binds nothing
  and removes the block; a present one binds and keeps it. `TPagedQuery.Run` and
  `TTenantPagedQuery.Run` process the arguments' tags on both statements
  (`TQueryArgs.ProcessTags`), so a repository writes each filter once instead of a `HasValue` for
  the tag and an `if` for the parameter (pascal-agenda-faa had both in six repositories). Absent
  filters are kept in the arguments: a block nobody processes loses its markers and keeps its
  content (pascal-db-faa's `TSQLResult.SQL`). Callers that process their tags themselves keep
  working: a tag already processed isn't found again. Sample 02 and `docs/guide/database.md` use
  it.
- Sample 03 runs on PostgreSQL too: `DB_ENGINE=postgresql`, one database per name (`control`,
  `shared`, `tenant_<id>` for each dedicated tenant), which must exist; `--reset` empties each one
  (`DROP SCHEMA public CASCADE`). Its SQL moved to `COMMON` behind `TFallbackSqlSource`, and the
  catalog's `SUSPENDED` flag is bound with `Flags`. `tools/test_http.sh` and
  `tools/test_http_docker.sh` (CI) run its scenarios, `--check-key-store` and the rotation with two
  instances on PostgreSQL after SQLite; the rotation's checks that open the SQLite file are skipped
  there. Six runs of the scenarios on PostgreSQL (FPC, Windows) were clean, three of them through
  the refresh race (the 0.20.1 fix).

## [0.21.0] - 2026-10-20

Needs pascal-db-faa 0.17.0 (`IParams.Flags`, `TFallbackSqlSource`). Both come from
pascal-agenda-faa's first PostgreSQL run (`docs/plan.md`, section 10).

### Added

- `TQueryArgs.Flags(Name, Value)`: a flag stored in a `SMALLINT`/`INTEGER` column, bound as the
  Integer 1/0 (`IParams.Flags`). `TQueryArgs.Booleans` stays, for the database's Boolean type:
  PostgreSQL refuses a Boolean parameter for an integer column (a filter on one answered 500),
  and SQLite takes it, so only a PostgreSQL run shows it (pascal-db-faa's gotcha 54).
- Sample 02 runs on PostgreSQL too: `DB_ENGINE=postgresql` with `DB_HOST`, `DB_PORT`,
  `DB_NAME`, `DB_USER`, `DB_PASSWORD` and `PG_CLIENT` (the names pascal-agenda-faa uses);
  `--reset` drops its tables. Its SQL moved to one directory, `COMMON`, behind
  `TFallbackSqlSource`. `tools/test_http.sh` (a throwaway container, when Docker is there) and
  `tools/test_http_docker.sh` (CI) run its scenarios on both; the scenarios know the two
  differences (where a NULL sorts, the pool's name), and the span check wants PostgreSQL's
  statements too. The CI image gains `libpq5`.

### Changed

- The minimum pascal-db-faa is 0.17.0 (`PascalApi.Http`, `pascal_api_infra_faa.lpk`).

## [0.20.1] - 2026-10-19

### Fixed

- Two refreshes racing on one token could leave the winner's next token alive on PostgreSQL. The
  0.19.1 guard (the winner reads its spent token again after storing the next one) relied on the
  loser's family revoke either seeing the next token or committing before that re-read. Under
  PostgreSQL's `READ COMMITTED` the revoke takes its snapshot when it starts, so it can miss a
  token committed while it runs and still commit after the re-read. pascal-agenda-faa's race
  scenario, on its new PostgreSQL run, saw it in 4 of 7 runs on Linux (FPC, SQLdb, PostgreSQL 17);
  SQLite, one writer at a time, never.

### Added

- `IRefreshTokenAtomicRotation.MarkUsedAndAdd`: marks the token used and stores the next one in
  one transaction. `TDbRefreshTokenStore` (its `MARK_USED` and `INSERT` SQL in one transaction)
  and `TMemoryRefreshTokenStore` (one hold of its lock) implement it, and `TRefreshTokens.Rotate`
  uses it when the store has it: the loser's `MarkUsed` waits for the winner's commit, and its
  revoke sees the next token. Optional: a store of your own keeps compiling and keeps the 0.19.1
  guard.

## [0.20.0] - 2026-10-19

Validation, phase F2 of `docs/validation-design.md`: what the OpenAPI document declares is
enforced, and a 400 lists every failing field. Needs pascal-common-faa 1.21.0
(`PascalCommon.Validators`, phase F1).

### Added

- The error handler answers pascal-common-faa's `EPcValidationError` with a 400:
  `{"error": <the first field's message>, "code": "invalid_fields", "fields": [{"field", "code",
  "message"}...]}` (`TErrorResponse.Fields`, `ErrorJson(..., AFields)`,
  `API_CODE_INVALID_FIELDS`). The document's `Error` schema gains `code` (sent since 0.17.0) and
  `fields`.
- `TApiSchema.Check(AInterface, ADto, var AValidation)`: what `Describe` declares, enforced
  (`MinLength`, `MaxLength`, `Enum` on text, counted in characters; `Minimum`, `Maximum` on
  numbers), under the members' JSON names; an optional member only when it holds a value.
  `Pattern` stays documentation; nested DTOs aren't walked.
- `TApiInput.FromJson<I>` (`FromJson` + `Check` + `RaiseIfAny`) and `THorseBody.Read<I>(AReq)` on
  it. `TQueryParams.Read<I>` (so `THorseQueryParams.Read<I>`) applies the same check. All opt-in:
  a handler that calls `FromJson` itself sees no change.
- Sample 02 validates through them: its hand-written limits are gone (the `Describe` holds them),
  and `DbApiSample.Validators` (`TValid = class(TPcStringValidators)`) has the two rules the
  document can't say (the IBGE code, a name besides blanks). Scenarios: every failing field in
  one answer; the PATCH sends `"rn"` (a `MaxLength(2)` refuses `" rn"` at the edge).

### Changed

- pascal-common-faa 1.21.0 is the minimum (`PascalApi.Dto`'s check, the `.lpk`).
  `PaCharCount` is `PcCharCount` underneath.

## [0.19.1] - 2026-10-19

`PascalApi.RefreshTokens` gets a tested sample and a guide; writing them found a race that
handed out a live token of a revoked family.
Verified on FPC 3.2.2 Windows and Linux and Delphi 12 Win32 and Win64: 382 tests, 0 leaks;
HTTP 253 + 95 + 160 + 36 + 30 checks.

### Fixed

- `TRefreshTokens.Rotate`: when two refreshes of one token raced, the loser's revoke could land
  before the winner stored its next token, which then survived the revoke and was returned (a
  live token of a revoked family). The winner now reads the spent token again after storing the
  next one, and when it was revoked meanwhile, revokes the family again and raises `rrRaced`:
  both requests can be refused, never two winners and no live token left
  (`Rotate_Raced_LoserRevokedBeforeTheNextWasStored`). Found while writing sample 01.
- The `OnSecurity` line for scope `''` no longer says "of scope  revoked" (two spaces):
  "refresh token family <id> revoked: <reason>"; with a scope it is unchanged.

### Added

- Samples 01 and 03: `POST /auth/login` also answers a refresh token (`ITokens`: `token`,
  `expiresIn`, `refreshToken`, `refreshExpiresIn`, with `Cache-Control: no-store`);
  `POST /auth/refresh` and `POST /auth/logout`, open paths, documented in OpenAPI with their
  DTOs and the 401, left out of MCP (`NoMcp`). `ACCESS_TOKEN_SECONDS` and
  `REFRESH_TOKEN_SECONDS` set the lifetimes. Sample 01 keeps the tokens in memory and has
  `POST /auth/logout-all` (`RevokeUser` for the caller); sample 03 keeps them in its control
  database (`REFRESH_TOKENS`, migration 4, the `REFRESH.*` SQL), the tenant as the scope,
  checked against the catalog before the token is exchanged.
- HTTP scenarios: rotation, a spent token that comes back revoking the newest one and the
  `SECURITY` line, two refreshes at once (never two 200s), expiry (`tools/test_http.sh` and
  `tools/test_http_docker.sh` set `REFRESH_TOKEN_SECONDS=3`), malformed tokens, logout
  answering the same for any token, a secret under another tenant's prefix, an unknown or
  suspended tenant, a user the check refuses, sign out everywhere, no token in the log, no MCP
  tool for the routes; with two instances of sample 03, a token issued by one rotated by the
  other and the reuse seen by the first. Sample 01: 253 checks (195 before), sample 03: 160
  (107), two instances: 36 (31) on the database and 30 (25) on Redis.
- `docs/guide/refresh-tokens.md`: why, the format and the hash, the family and reuse, the race
  and the conditional `UPDATE`, the user and tenant checks, logout and `RevokeUser`, the table
  for SQLite and PostgreSQL, purging, your own store's contract, the pitfalls. Linked from the
  index, the README, `authentication.md`, `jwt-keys.md`, `multitenancy.md` and `mcp.md`; the
  guides that quoted the samples' old login follow the new code.

## [0.19.0] - 2026-10-19

Two pieces every list route of pascal-agenda-faa, the library's first application, wrote by hand
(five copies each): reading the Find DTO from the query string, and the paged query. Needs
pascal-jsonmapper-faa 0.7.0.

### Added

- `PascalApi.QueryParams`: `TQueryParams.Read<IFind>(AMapper, AValues)` fills a Find DTO from
  query-string values by the members the OpenAPI document lists for it (`QueryParams<IFind>`),
  through the mapper, so a value meets a body's rules (optionals, ranges, `TUtcDateTime`'s
  zone, converters). Empty is absent; unknown parameters are ignored; names ignore case; a
  value of the wrong kind is a 400 naming the parameter; the mapper's `$.name: reason` becomes
  `name: reason`. `THorseQueryParams.Read<IFind>(AReq)` (`PascalApi.Horse.Middlewares`) reads
  `AReq.Query`. Sample 02's `GetCities` uses it; `PascalApi.QueryParamsTests`.
- `ApiQueryParamType` (`PascalApi.OpenApi`): how a member travels in a query string, the one
  rule the document's query parameters and `TQueryParams` share.
- `PascalApi.PagedQuery`: `TPagedQuery.Run<T>` (on a factory) and `TTenantPagedQuery.Run<T>` (on
  a tenant's scope, through `TTenantFilter.Prepare`): the `COUNT` and the page through the same
  filters in one transaction, `${ORDER}` and `${PAGE}` replaced, the same `TQueryArgs` bound to
  both, each row read by a plain function (`TPageRowFunc<T>`). `TQueryArgs` is a value with
  `IParams`' setter names, each returning a changed copy. Sample 02's repository uses it;
  `PascalApi.PagedQueryTests` on pascal-db-faa's mock.
- `PascalApi.RefreshTokens`: refresh tokens used once. `TRefreshTokens` issues
  `<scope>.<secret>` tokens (the scope a tenant id, or none), stores only their SHA-256,
  rotates them (the next token in the same family), and revokes the family when a used token
  comes back, when two rotations race on one token (the store's `MarkUsed` is True for one) or
  when the application's `TRefreshUserCheck` refuses the user; `OnSecurity` hears of each.
  `Revoke` (logout) and `RevokeUser` (a new password, a user deactivated). Every refusal is an
  `ERefreshTokenRejected` with a `Reason` for logs. Stores: `IRefreshTokenStore`,
  `TDbRefreshTokenStore` on the application's named SQL (`REFRESH.*`, `TENANT_ID` = the scope),
  `TMemoryRefreshTokenStore`. The core of pascal-agenda-faa's flow, at the user's choice;
  `docs/jwt-keys-design.md` had left refresh tokens to the application.
- `TApiMessages.InvalidQueryNumber` and `InvalidQueryBoolean` (English and Portuguese).
- `TUtcDateTime` members (pascal-jsonmapper-faa 0.7.0) are `date-time` in the document.

### Changed

- pascal-jsonmapper-faa 0.7.0 is the minimum (`.lpk`). The test submodules: pascal-common-faa
  1.20.0, pascal-jsonmapper-faa 0.7.0, pascal-db-faa 0.16.0.

## [0.18.0] - 2026-10-19

A DTO's interface now shows every member, read-only, so code that sees only the interface (a
repository, a test) knows what the DTO carries without opening the class. Raised from
pascal-agenda-faa. **Breaking** for code that wrote the paged bases through their interfaces.

### Changed

- **Breaking: the paged DTO bases are read-only through their interfaces.**
  `IFindPaginationDTOBase` (`Page`, `Limit`, `OrderBy`, `Search`) and
  `IResponsePaginationDTOBase` (`Page`, `Limit`, `Total`) lost their setters, and
  `TFindPaginationDTOBase`/`TResponsePaginationDTOBase` their `SetXxx` methods. Fill them through
  the class while an interface variable holds the object:
  `LFill := TCityFind.Create; LFind := LFill; LFill.Page := ...` (was `LFind.Page := ...` on an
  `ICityFind`). The JSON is the same.
- **DTO convention** (`PascalApi.Dto`'s header, `docs/guide/dtos-json.md` step 1): a DTO's
  interface mirrors every published property of its class, with the same name and type,
  read-only through its getter (`property Name: string read GetName;`); the code that creates a
  DTO fills it through the class, and code that receives the interface treats it as a value.
  The mapper reads the class only, so the JSON and the OpenAPI document don't change (measured
  with a probe on FPC: same members, same JSON). Samples 01 to 04 follow it.

## [0.17.0] - 2026-10-18

Found by pascal-agenda-faa, the library's first application: an HTTP exception built with
`CreateFmt` answered `HTTP/1.1 0`, and a handler had no way to send a 401 with its scheme or a
machine-readable code.

### Fixed

- **`EValidationException.CreateFmt` answered `HTTP/1.1 0`.** The constructors the HTTP
  exceptions inherit from `Exception` (`CreateFmt`, `CreateRes`...) never set `StatusCode`, so
  it stayed 0 and the error handler sent status 0, which clients refuse (curl: "Unsupported
  HTTP/1 subversion"; measured on FPC Windows by pascal-agenda-faa, the library's first
  application). `EHttpException.AfterConstruction` now gives such an exception its class's
  `DefaultStatusCode` (400, 404, 409, 401; 500 for `EHttpException`), and `MapException` answers
  a status outside 100-599 with a 500, logged. Tested; `/fail/createfmt` in sample 01.

### Added

- `EUnauthorizedException` (401) for handlers, and an optional code on `EHttpException`,
  `EValidationException` and `EConflictException` (`Create(..., ACode)`, property `Code`), sent
  as `"code"` next to `"error"` (`ErrorJson(AMessage, ARequestId, ACode)`,
  `TErrorResponse.Code`). Every 401 an `EHttpException` becomes carries `WWW-Authenticate:
  Bearer` (`TErrorResponse.Challenge`), as the authentication middlewares' 401s do; until now a
  handler's 401 had none, which HTTP requires. `/fail/unauthorized` in sample 01.
- `EHttpException.DefaultStatusCode` (virtual class function), for subclasses.

## [0.16.0] - 2026-10-18

The middlewares' marks on a request live in Horse's request scope instead of request headers,
and CORS headers no longer come twice on a 404. Cryptography (SHA-256, HMAC, Base64url) moved
to pascal-common-faa, which is now required at 1.17.0.

### Fixed

- **`TCorsMiddleware` sent its headers twice on a path no route matches.** Horse 3.3.12 runs the
  global middlewares twice there, and the second pass added `Access-Control-Allow-Origin`, `Vary`
  and the rest again (measured on FPC and Delphi). A browser refuses an answer with two
  `Access-Control-Allow-Origin`, so a 404 reached a front end as a CORS error. The middleware
  now marks the request (`TPascalApiRequestState.CorsSent`) and adds them once;
  `tools/http_scenarios.sh` checks it on `GET /swagger/missing`.

### Added

- Sample 03's `--check-key-store`: stores one generation twice through `TDbJwtKeyStore` in the
  control database and expects the second `TryAdd` to be False with one row (two instances racing
  on a rotation, as the database adapter sees it), then exits 0 or 1. `tools/test_http.sh` and
  `tools/test_http_docker.sh` run it before the rotation scenarios.

### Changed

- **The middlewares' marks on a request moved from request headers to Horse's request scope.**
  `TPascalApiRequestState` (`PascalApi.Horse.Middlewares`), kept in `THorseRequest.Services` and
  freed with the request, holds what the logger, the rate limit, the metrics and the tenant
  middleware note on a request (a pass already done when Horse runs the global middlewares
  twice, the trace id, the tenant). They were headers named `':pascalapi-logged'#10` and so on:
  a name chosen so no client could send it, after Indy let a client's `:pascalapi-logged: 1`
  hide a request. The request scope is out of a client's reach whatever the parser does. No
  change to the public calls (`TTenantMiddleware.Current`, `TenantIdOf`).
- **`PascalApi.Crypto` is now wrappers of pascal-common-faa 1.17.0's `PascalCommon.Crypto`**
  (SHA-256, HMAC-SHA256, Base64url, constant-time comparison moved there, next to its AES-GCM).
  The `Pa*` functions and `TSha256Digest` (now an alias of `TPcSha256Digest`) stay. **Requires
  pascal-common-faa 1.17.0** (`PASCALCOMMON_VERSION` in `PascalApi.Dto`, the `.lpk`).

## [0.15.0] - 2026-10-18

JWT signing keys that rotate without logging anyone out: named by `kid`, generated and rotated
by the library in a database or Redis, one ring per tenant, sealed under a master key
([guide](docs/guide/jwt-keys.md), [design](docs/jwt-keys-design.md)). All opt-in:
`TJwtMiddleware.New(ASecret)` is unchanged. Requires pascal-common-faa 1.16.0.

### Added

- **JWT signing keys named by `kid`** (`PascalApi.JwtKeys`, phase 1 of
  [docs/jwt-keys-design.md](docs/jwt-keys-design.md)): rotate the HS256 secret without
  invalidating the tokens already issued. `TStaticJwtKeyRing` (keys from `JWT_KEYS`,
  `kid:secret[@notAfter],...`, the first one signs) with an optional legacy secret for tokens
  without `kid`; `TJwtKeys.Sign`/`Decode`; `TJwtMiddleware.New(ARing, ...)` and
  `TJwtMiddleware.Sign` (refuses claims without an integer `exp`, or one that would outlive the
  signing key); `TJwt.SignHS256(AClaimsJson, ASecret, AKid)` and `TJwt.ReadKid`. An unknown
  `kid`, or one past its `notAfter`, is the same 401 as a bad signature. Opt-in:
  `TJwtMiddleware.New(ASecret)` is unchanged (sample 01's 186 checks). Sample 03 uses a ring;
  `tools/http_scenarios_tenants.sh` checks it (107 checks). Guide: Authentication, step 8.
- **Generated JWT signing keys that rotate by themselves** (phase 2 of
  [docs/jwt-keys-design.md](docs/jwt-keys-design.md)): `TRotatingJwtKeyRing` with
  `TJwtRotationOptions` (rotate every 30 days, a new key signs 120 s after it is stored, an
  old key verifies one token lifetime more, reload every 60 s), on a store every instance
  shares: `IJwtKeyStore`, `TDbJwtKeyStore` (the application's SQL by name; a unique key on
  `TENANT_ID` and `GENERATION` settles two instances rotating at once), `TMemoryJwtKeyStore`
  (tests), and `TRedisJwtKeyStore` in `src/redis/PascalApi.Redis.JwtKeys` (pascal-redis-faa,
  outside the package). Sample 03: `JWT_KEY_STORE=db` or `redis`;
  `tools/http_scenarios_jwt_rotation.sh` checks both with two instances (22 checks each).
- **A JWT signing key per tenant** (phase 3 of [docs/jwt-keys-design.md](docs/jwt-keys-design.md)):
  `TTenantJwtKeyRing` (`PascalApi.Tenancy`), one rotating ring per tenant on one store, the
  tenant inside the kid (`acme/<16 hex>`); a token verifies only when its tenant claim names
  its key's tenant. Rings for the catalog's tenants (read again every `ReloadSeconds`) and for a
  tenant that signs; a kid naming any other tenant asks neither the store nor the catalog.
  `IJwtKeyRing.SigningKey` now takes the claims, and the ring has `ScopeClaim`; `TJwtKey` has
  `Scope`. Sample 03's `db`/`redis` modes use it; `tools/http_scenarios_jwt_rotation.sh`
  tries acme's key on a token claiming globex (29 checks on the database, 25 on Redis).
- **Sealed JWT signing keys**: `TSealedJwtKeyStore` wraps any key store and keeps the secrets
  sealed with AES-256-GCM (`TAesGcmSecretCipher`, pascal-common-faa's `PascalCommon.AesGcm`)
  under master keys listed with an id (`JWT_KEYS_MASTER_KEY=m2:<base64>,m1:<base64>`; the first
  seals, all open). A sealed secret is bound to its tenant, kid and generation; plain secrets
  stored before still load unless sealing is required. `IJwtSecretCipher` leaves room for a
  KMS. Sample 03 seals in both its `db` and `redis` modes (`SECRET` column now `VARCHAR(255)`).
- Guide [JWT signing keys and rotation](docs/guide/jwt-keys.md): the key rings, the stores, a
  key per tenant, sealed secrets, and procedures (from one secret to a ring, revoking a leaked
  key, rotating the master key, turning sealing on). Steps 8-11 of the authentication guide
  moved there. Two tests back its revocation steps (`Revoke_WipeTheScope`,
  `Revoke_OnlyTheSigningKey_ThePreviousSignsAgain`).
- Guide [Your project on both compilers](docs/guide/dual-compiler.md): the layout, project
  files, code rules, mirrored tests and CI for an application of your own on Delphi and
  Lazarus/FPC, and the Claude Code skills that carry the rules (pascal-skills-faa).

### Changed

- **Requires pascal-common-faa 1.16.0** (was 1.8.1): `PascalApi.JwtKeys` takes its random bytes
  from `PascalCommon.Random` (1.15.0) and seals with `PascalCommon.AesGcm` (1.16.0). `PASCALCOMMON_VERSION` in `PascalApi.Dto` and the `.lpk` say so.
- pascal-redis-faa 0.2.0 is a new submodule, only for the tests and sample 03 (Redis store).
- The pascal-common-faa submodule (used by this repository's tests and samples) moved from
  1.10.0 to 1.16.0. Sample 02 names its normalization rules in a factory
  (`DbApiSample.Normalizers`, `TNorm = class(TPcStringNormalizers)` from
  `PascalCommon.Normalizers`, 1.14.0), and the DTOs and JSON guide shows it.

## [0.14.0] - 2026-10-16

The user guides (`docs/guide/`, twelve topics), the fixes found while writing them, and the
sibling libraries' fixes. Requires pascal-db-faa 0.15.0 and pascal-jsonmapper-faa 0.6.0.

### Security

- **A 500 no longer sends the exception's message to the client.** `MapException` answered an
  unmapped exception with `E.Message`, which can carry a path, a host or SQL (the origin,
  delphi-api-infra-faa, did the same). The client now gets `TApiMessages.InternalError`
  (`'An unexpected error occurred.'`, `'Ocorreu um erro inesperado.'`); the class and message
  stay in the error handler's log line. An `EJsonMapperError` without a JSON path (a DTO not
  registered) is one such 500.
- **The error handler copied a client's `X-Request-Id` into the log** when `TLoggerMiddleware`
  wasn't in use: `trace_id=` took the raw header. It now takes only the id the logger set, and
  none without the logger (measured on FPC/Windows with a program without the logger).
- **An exception raised in a middleware reached the client with its message and stack (FPC).**
  Horse 3.3.12's FPC router re-raises a middleware's exception without calling
  `THorse.OnError`, and fpWeb answered `500 text/html` with the message and the stack addresses,
  while the access line said 200 (measured, FPC 3.2.2/Windows). A `TDbTenantCatalog` with its
  database down, or a raising rate-limit key function, would take that path.
  `TLoggerMiddleware` now answers such an exception as the error handler does (status, fixed
  message, `requestId`, log line), so the middlewares after it are covered on both compilers and
  the access line has the real status. Sample 01 gains `/fail/middleware`;
  `tools/http_scenarios.sh` checks it.
- **The rate limit's IP key could be escaped with `X-Forwarded-For`.** The default key was the
  header's first address, which the client writes: six requests with a new value each all passed
  a limit of 3 (measured, FPC 3.2.2/Windows). The key is now `TrustedClientIp`: the connection's
  address, with the header trusted only from a loopback peer or from the proxies declared in the
  new `TClientAddress.ProxyHops` (default 0), read from the right. **An API behind a proxy that
  relied on the old key must set `TClientAddress.ProxyHops`** (1 for one proxy). The MCP executor
  now forwards the chain as a proxy does (`ForwardedForChain`), so a tool call keeps its caller's
  key.
- **Anyone could put any address in the access log and the spans.** `client_ip` (the log line)
  and `client.address` (the server span) were `X-Forwarded-For`'s first address. They now come
  from `TClientAddress.Resolve`, the same trusted address as the rate limit's key, from one
  setting for the process (`TClientAddress.ProxyHops`). `tools/http_scenarios.sh` checks the
  access line (the old Delphi build logged the client-written `203.0.113.9`: 2 checks failed).
  `ClientIp` stays, unused by the library.
- The metrics middleware's internal mark ends with a line feed, as the logger's
  (`':pascalapi-metered'#10`); its comment gave the reason proved false for the logger. A raw
  `:pascalapi-metered: 1` line didn't hide a request from the metrics on either compiler
  (measured); `tools/http_scenarios.sh` checks it (164 checks).
- **The rate limit's memory grew with every key ever seen.** A key's bucket was never freed:
  1,000,000 distinct keys held 231 MiB after their windows ended, and with the hole above a client
  could grow it at will (measured). `TRateLimitState` now frees the keys whose window is over,
  once per window, and shrinks its table: 0 KiB left in the same run.
- **A failed MCP tool call sent the transport's message to the client, and logged nothing.**
  When the executor couldn't reach the API (down, wrong base URL, timeout), the result's text was
  `Could not call the API: ` + the exception's message, which named the API's host and port
  (`Connection to 127.0.0.1:1 timed out.`, measured with a probe on FPC). The client now gets the
  fixed `MCP_CALL_FAILED` (`Could not call the API.`), and the message goes to the error handler's
  log with the method, the path (without the query string) and the trace id. Sample 01 gains
  `/mcp/unreachable`; `tools/http_scenarios.sh` (168 checks) checks the text and the log line.
- **The rate limit counted a request to a route that doesn't exist twice**, and sent its headers
  twice (Horse runs the global middlewares twice there; measured). It marks the request now, as
  the logger does; `tools/http_scenarios_tenants.sh` (88 checks) checks it.
- **A pool timeout was a 500.** pascal-db-faa's `EPoolTimeoutException` (every pooled connection
  busy for the whole wait) derives from `Exception`, so `MapException` answered it as an unexpected
  error. It is now 503 with the new `TApiMessages.ServerBusy` ("The server is busy. Try again
  shortly." / "O servidor está ocupado. Tente novamente em instantes."), logged with the pool's
  state, as pascal-db-faa's docs suggest (capacity, not the database down). Test
  `PoolTimeout_Is503_Logged`; sample 01 gains `/fail/busy`, checked by `tools/http_scenarios.sh`.
- **`TJwtMiddleware.Claims` decoded a token signed with an empty key when `TJwtMiddleware.New`
  was never called** (only `TAuthMiddleware` in use: the secret was ''). Measured with a probe.
  `TJwt.Decode` now refuses an empty secret (`jrBadSignature`; anyone can sign with an empty
  key), and `Claims` returns nil without a configured secret. Test
  `Decode_EmptySecret_Refused`.

### Changed

- `external/pascal-jsonmapper-faa` on v0.6.0: a `Currency` is exact over its whole range on FPC
  3.2.2. Before, on Win64, `123456789012345.6789` came back as `...6768`, `High(Currency)` with
  its sign flipped, and `0.00025` as `0.0003` (half to even now gives `0.0002`); measured here
  with sample 01's new `POST /prices`, which `tools/http_scenarios.sh` checks (186 checks; 3
  failed on 0.5.0).
- **pascal-jsonmapper-faa 0.6.0 or later is required** (the `.lpk` asked for 0.3.0, though
  `PascalApi.Http` uses 0.5.0's `EJsonInputError` since the change below; 0.6.0 for the exact
  `Currency` on FPC). It has no version constant, so on Delphi only an older one before 0.5.0
  stops the build (`EJsonInputError` undeclared).
- **pascal-db-faa 0.15.0 or later is required** (was 0.12.0; `PascalApi.Http` stops the build,
  and the `.lpk` asks for it). Its `TSQLResult` operations return a changed copy and never change
  the record they are called on, so `TTenantFilter.Prepare` drops its local copy. 0.15.0 is a
  breaking change there: a call whose result is ignored no longer changes the variable (assign it,
  `LSql := LSql.ProcessTag(...)`). The samples already assign every result.
- `external/pascal-common-faa` on v1.10.0: `PcSetSafeLogUtf8` makes `SafeWriteln` (the access
  log, `FileLog`'s fallback) write UTF-8 to a file or a pipe, which neither compiler did (code page
  850 on FPC, 1252 on Delphi; found by sample 04's log). The samples turn it on and write all their
  log lines through `SafeWriteln`; the library leaves it to the application (process-wide, off by
  default), and its minimum stays 1.8.1. Sample 01's `/fail/server` message has non-ASCII on
  purpose, and `tools/http_scenarios.sh` checks its UTF-8 bytes in the log (it failed with the
  switch off: `a\x87\xc6o`). Guide: `docs/guide/observability.md`, step 2.
- `external/pascal-jsonmapper-faa` on v0.5.0, and the error handler maps by class: an
  `EJsonInputError` (the JSON is at fault; its message has JSON terms only) is a 400, any other
  `EJsonMapperError` a 500, logged. Until now any mapper message starting with `$` was a 400, so a
  programming error with a path (`$.sub: class property ... is nil`) reached the client with
  Pascal names. Tests `JsonInputError_Is400_NotLogged`, `JsonMapperErrorWithPath_Is500_Logged`
  (281 in all). Sample 04 runs with pascal-pipes-faa 0.3.0 (messages in English) and
  pascal-amqp-faa 0.4.1 (`OnConsumerError` inside the message's span: its log line has the trace
  id again).
- `external/pascal-jsonmapper-faa` on v0.4.0: a JSON member sent twice is refused (400,
  `$.name: duplicate member (...)`), also when the names differ only in case; 0.3.0 kept one of
  the values. `tools/http_scenarios.sh` checks both (175 checks). `samples/04-messaging`'s
  `PipesJsonSample` needs pascal-pipes-faa 0.2.0: its `OnMessage` has no `try`, and the server's
  `OnError` logs what a handler raises (0.1.1 lost it). `MessagingSample` needs pascal-amqp-faa
  0.4.0: its consumer has no `try`, and the channel's `OnConsumerError` logs what it raises before
  the message is rejected (0.3.0 left it unacknowledged).
- `external/pascal-common-faa` on v1.9.0, for its string normalizers (`TOptionals.Trim`,
  `Upper`...: the value changes inside the optional, the state stays), which sample 02's PATCH
  uses so it binds each member with no `if` (asked for by the user; the normalizers were added
  there for this). Sample 02's INSERT lost its `if` too: the population's column is a tagged
  block, gone when the member is absent (the database writes NULL). The library's own minimum stays 1.8.1 (`PascalApi.Dto`): nothing in `src`
  uses them.
- **Breaking: `ParseQueryInt(AName, AText)`** (`PascalApi.Pagination`) takes the parameter's name
  and answers **400** (`EValidationException`, `TApiMessages.InvalidQueryInteger`:
  `"limit" must be an integer.`) for anything but an optional `-` and decimal digits within
  `Integer`; empty is still absent. It used `TryStrToInt` and returned an absent value for text it
  couldn't read: `abc` silently became the default, `$3`, `0x3`, `+3` and ` 3` were read as 3, and
  on FPC 3.2.2 a number past `Integer` wrapped around (`page=99999999999` became page 1215752191,
  measured through sample 02). New `TryParseQueryInteger`. Tests in `PascalApi.PaginationTests`
  (277 in all); samples 01 and 02 check it over HTTP. Callers add the name:
  `ParseQueryInt('page', AReq.Query['page'])`.
- Samples 01-04 set `TJsonMapper.Shared.UnknownMembers := umError`: a member the DTO doesn't have
  is a 400 with its path (`$.popultion`), where the mapper's default dropped it in silence (a typo
  gave a 201 with the value missing, measured). Checked by all three scenario scripts (sample 03:
  a `tenantId` in the body is refused).
- `external/pascal-db-faa` on v0.14.2, two FireDAC + SQLite fixes measured through sample 02 on
  Delphi 12 (FPC's SQLdb already behaved): a row whose text is longer than its `VARCHAR(n)`
  (SQLite stores it) is read whole, where 0.14.0 raised `[FireDAC][DatS]-32` on every read and
  answered 500 (0.14.1); and trailing spaces are kept, where a stored `'Spaces  '` came back as
  `"Spaces"` (0.14.2). The guides (`database.md`, `openapi.md`) recommend
  `CHECK (length(...) <= n)` to refuse values longer than the column (422).
- **Samples 02 and 03 enforce the limits their OpenAPI documents declare.** The documents said
  `pattern ^[0-9]{7}$` for the code, `maxLength 100` for a name and `minimum 0` for the
  population, but nothing checked them: `+123456` and `-5` were stored, and a 150-character name
  was 201 on FPC and 500 on Delphi, where FireDAC stored the row and then refused to read it back,
  so the city and every list containing it answered 500 (measured). They now answer 400.
  `tools/http_scenarios_db.sh` (71 checks) and `tools/http_scenarios_tenants.sh` (92) check
  each limit, and a name of 100 two-byte characters; the Delphi build from before failed 7 and 5
  of them. Found while measuring for `docs/guide/openapi.md`.
- **A 401 carries `WWW-Authenticate`**, which HTTP requires (RFC 9110): `Bearer` when the
  request had no Bearer token, `Bearer error="invalid_token"` when its token was refused (RFC
  6750), from `TJwtMiddleware`, `TAuthMiddleware` and `TTenantMiddleware`. New
  `BearerChallenge` in `PascalApi.Http` (tested); `tools/http_scenarios.sh` and
  `tools/http_scenarios_tenants.sh` check the header.
- **`.env` file: spaces around `=` are ignored, and the last line of a repeated key wins.**
  `TAppConfig` kept the spaces after `=` (`PORT = 9000` was ` 9000`; `NAME = "x"` kept the
  space and the quotes) and returned the first line of a repeated key, so `A=` before `A=later`
  gave the default. Now the value is trimmed before its quotes are removed (quoted spaces are
  kept), and later lines override earlier ones, as in a shell. Found while measuring for
  `docs/guide/configuration.md`. A comment after a value is still part of it, and `export A=...`
  still isn't read (both tested or measured, both in the guide).
- **The errors the handler logs carry the request id in the body**:
  `{"error": "...", "requestId": "<trace id>"}` for 500, 503, 422 and lock conflicts, the same
  id the log line ends with (`trace_id=`) and the `X-Request-Id` header, so a user can quote it
  to support. Client errors (400, 404, 409 from a unique key) are unchanged. New
  `ErrorJson(AMessage, ARequestId)` overload; the OpenAPI `Error` schema gains an optional
  `requestId`. `tools/http_scenarios.sh` checks the body, that the exception's
  message isn't in it, and that the sample's log has it with the client's id.

### Added

- `TTenantFilter.Prepare(AQuery, AScope, ASql: TSQLResult)` (`PascalApi.Tenancy`): the same as
  the one that takes the SQL's name, from SQL already processed (`ProcessTag`), so a block per
  optional member needs no `if`; the tenant's condition and `:TENANT_ID` still come in the same
  call. Sample 03's INSERT uses it (its population is a tagged block, like sample 02's). Tests
  `Filter_PrepareProcessedSql_BlockRemoved_ReplacesAndBinds` and `..._BlockKept_...`.
  It works on a copy of `ASql`: `TSQLResult.ReplaceLiteral` changes `Self`, and called on the
  `const` parameter it leaked the new string on FPC 3.2.2/Linux (one block per call, heaptrc) and
  changed the caller's variable on Win64 (measured; the dual-compiler skill's `rtl-gotchas.md`,
  "Memory / interfaces"). The first version's tests missed it (their SQL had no `${TENANT}`, so
  nothing was replaced); `Filter_PrepareProcessedSql_TenantTag_ReplacesAndBinds` (280 in all)
  failed on both before the copy. An earlier note blamed the call between the two overloads; that
  was wrong.
- `docs/guide/dtos-json.md`: DTOs and JSON, from request bodies (what each kind of bad body gets,
  measured) and the three optional types to the query string, the database, and the same DTOs on
  a queue and between processes. Sample 02 gains `PATCH /cities/:code` (`ICityPatch`: absent
  leaves a member, `null` clears population, a value sets it; `tools/http_scenarios_db.sh`, 93
  checks). Sample 04's orders are a JSON DTO (checked before publishing, `application/json`, a
  consumer that logs and rejects what it can't read: without that, a bad message stayed
  unacknowledged and silent, and came back on every restart, measured), and
  `PipesJsonSample.lpr` sends DTOs over pascal-pipes-faa (`build_fpc.sh` builds it with
  `PIPES_FAA`).
- `docs/guide/`: guides for the library's users, one per topic, to one template (index:
  `docs/guide/README.md`). The first is multi-tenancy (`docs/guide/multitenancy.md`); the others
  are listed there as planned. Then getting started (`docs/guide/getting-started.md`), configuration
  (`docs/guide/configuration.md`), errors and validation (`docs/guide/errors.md`),
  authentication (`docs/guide/authentication.md`), rate limiting
  (`docs/guide/rate-limiting.md`), database access (`docs/guide/database.md`), logging and
  observability (`docs/guide/observability.md`), OpenAPI (`docs/guide/openapi.md`), MCP
  (`docs/guide/mcp.md`) and messaging, Redis and IPC (`docs/guide/messaging.md`, measured
  against Redis and RabbitMQ with `samples/04-messaging`).
- `samples/04-messaging`: the API behind the messaging guide (pascal-redis-faa and
  pascal-amqp-faa inside a Horse API). FPC only and built by hand (`build_fpc.sh`), not by CI:
  those two libraries aren't this repository's dependencies. It logs each failed AMQP reconnect
  attempt (`OnReconnectError`, pascal-amqp-faa 0.3.0); the guide's reconnection measurements were
  repeated with 0.3.0, which fixed the silent failure to reconnect that 0.2.0 showed.
- `TErrorHandlerMiddleware.LogError`: writes a line through the callback given to `Register`, for
  an error handled away from `OnError`. `LogError(ALine, ARequestId)` is the MCP executor's;
  `LogError(AReq, ALine)` is a handler's (a cache that falls back when Redis is down), with the id
  `TLoggerMiddleware` set, never a client's own `X-Request-Id`.
- `PaCharCount` (`PascalApi.Text`): the number of characters in a string, the same on both
  compilers (`Length` counts bytes on FPC and UTF-16 units on Delphi), for a rule like "at most
  100 characters". Test `CharCount_CountsCharactersNotBytes`.
- **`${TENANT.alias}` in tenant SQL, for a JOIN.** `TTenantFilter.Prepare` replaces each
  `${TENANT.c}` with `c.TENANT_ID = :TENANT_ID` (plain `${TENANT}` is unchanged). Measured on
  SQLite: plain `${TENANT}` with two joined tables that have the column is "ambiguous column
  name", and a join whose `ON` lacks the tenant returns the other tenants' joined rows. Each
  joined table gets its own tag, in its `ON` (`docs/multitenancy-design.md`, decision 8;
  `docs/guide/multitenancy.md`, step 2).
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
