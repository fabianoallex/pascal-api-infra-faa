# Plan

Where pascal-api-infra-faa came from, what is decided, and what is left. Dated entries; the
newest state is at the top of each section.

## Goal

Offer what `delphi-api-infra-faa` offers to a Horse REST API, on Delphi **and** Lazarus/FPC
3.2.2, as a separate library. Decided with the user on 2026-10-08:

- `delphi-api-infra-faa` **stays separate**, serving its existing Delphi-only consumer. This
  library doesn't replace it and isn't a drop-in for it.
- Scope: **phases 1 to 3** first (the core and the middlewares), then OpenAPI (phase 4, 0.3.0)
  and MCP (phase 5, 0.5.0). All five are done.

## Evaluation (2026-10-08)

The origin's own assessment (`delphi-api-infra-faa/docs/lazarus-compat.md`, 2026-08-21) listed
five blockers. Since then, three were solved by the sibling libraries:

| Blocker (2026-08) | Now |
|---|---|
| FireDAC (adapter + `Common.Helpers`) | pascal-db-faa: SQLdb, Zeos and FireDAC adapters |
| `System.JSON` | pascal-jsonmapper-faa's own DOM (`PascalJsonMapper.Json`), identical output on both compilers |
| `TJsonMapper` on extended RTTI | pascal-jsonmapper-faa, with published properties (a convention change) |
| Closures (`reference to`) | open then; solved in phase 3 (`PASCALAPI_FUNCREFS`, named procedures for Horse) |
| SwagDoc + `[SwagProp]` attributes | open then; solved in phase 4 (own writer, fluent `TApiSchema.Describe`) |

Measured on 2026-10-08:
- FPC 3.2.2 (`C:\lazarus4.0`) ships HMAC only for MD5 and SHA-1 (`packages/hash/src/hmac.pp`);
  there is no SHA-256 at all. The JWT middleware (HS256) needs its own SHA-256 + HMAC, checked
  against the RFC 4231 vectors.
- Horse's callback on FPC is a plain `procedure(...)` (`Horse.Callback.pas:26`, v3.3.0
  `72cc45f`), neither `of object` nor `reference to`: a middleware can't capture its settings.

Already known (pascal-dfe-broker, 2026-09-20): Horse v3.3.0 builds and runs on FPC/Linux unchanged
and on FPC/Windows with one line of `Horse.FPC.inc` changed (`const` vs `constref`); Delphi Win32
confirmed, Win64 not tested.

## Phases

### 1. Skeleton — done (2026-10-08)

`.inc`, version unit, DUnitX masters + generated FPCUnit mirrors, `.lpk`, `.groupproj`/`.lpg`,
local and Docker test scripts, GitHub Actions workflow, submodules pinned to tags.

### 2. Core without HTTP — done on FPC Windows (2026-10-08)

`Text`, `Config`, `OrderBy`, `Pagination`, `RateLimitState`, `FileLog`, `Dto`, `Messaging` (removed in 0.6.0):
106 tests, 0 leaks on FPC 3.2.2 Win64, FPC 3.2.2 Linux x86_64 (Docker, `tools/ci-test.sh`),
Delphi 12 CE Win32 and Win64.

Decisions taken in the port (each unit's header has the details):
- `Common.Pagination`'s records are not repeated: pascal-db-faa's `PascalDb.Paging` has them;
  this library adds query-string parsing and the JSON envelope.
- `TAppConfig.SetEnvironmentReader`: tests replace the environment instead of changing it
  (FPC on Unix doesn't see a `setenv` after startup).
- `TLogTruncate` measures UTF-8 bytes on both compilers and never splits a character.
- Log rotation never overwrites an archive from the same second (`_1`, `_2`...).
- Ported interfaces have new GUIDs.

### 3. Middlewares — done (2026-10-08)

Error handler, CORS, request log, Bearer auth, JWT (HS256), rate limit, on Horse `72cc45f`
(tag 3.3.2) as a submodule.

- Pure decisions in `PascalApi.Http`; `PascalApi.Crypto` (SHA-256, HMAC, Base64url) and
  `PascalApi.Jwt` (sign + verify, alg check, exp/nbf); Horse glue in
  `src/horse/PascalApi.Horse.Middlewares`.
- Same calls as the origin (`THorse.Use(TCorsMiddleware.New(...))`); the settings live in the
  unit: **one configuration per process** per middleware (accepted by the user, 2026-10-08: no
  known consumer configures the same middleware twice). Callbacks (`TTokenValidator`,
  `TLogProc`, `TRateLimitKeyExtractor`) follow `PASCALAPI_FUNCREFS`.
- Verified: unit suite 156 tests, 0 leaks, on FPC 3.2.2 Win64 and Linux and Delphi 12 CE Win32 and
  Win64; `samples/01-api` over HTTP, 65 curl checks (`tools/http_scenarios.sh`), on FPC Windows
  (Horse with the then-needed `tools/prepare_horse.sh` workaround; removed with Horse 3.3.12), FPC Linux and Delphi
  Win32/Win64.
- The Delphi HTTP run found what the unit tests couldn't: `Res.Send(string)` broke accented JSON
  on Delphi (4 checks); `TJsonSend.Send` (UTF-8 bytes) fixed it. Also a Delphi-only compile error
  in the sample (two anonymous `array of T` types are incompatible on Delphi, accepted by FPC).
- Measured: FPC 3.2.2/Linux `DateTimeToUnix(Now, False)` equals `date +%s` with the system time
  zone set to UTC, America/Sao_Paulo and Asia/Tokyo (`Now` is UTC there, offset 0), so JWT
  exp/nbf are right on Linux.
- Found: `THorseRequest.RemoteAddr` is '' with the console provider (see CLAUDE.md); fixed here by
  falling back to `RawWebRequest.RemoteAddr`. Probably affects the origin's IP rate limit too.
- Differences from the origin: excluded path prefixes match whole segments; JSON body errors are
  400; messages are replaceable (`TApiMessages`, English default, Portuguese available).
- The `constref` workaround: no PR needed, Horse fixed it in 3.3.3 (`7a9a9cb`, issue #542,
  2026-08-19); this repository moved to Horse 3.3.12 and dropped it.

### Sample with a real database — done (2026-10-08)

`samples/02-db`: SQLite through pascal-db-faa, SQLdb on FPC and FireDAC on Delphi; 31 HTTP checks
(`tools/http_scenarios_db.sh`) green on FPC Windows and Linux and Delphi 12 Win32/Win64. It found a real defect:
`ParseQueryInt`/`ParseQueryStr` returned `nil` for a missing parameter, and a repository testing
`HasValue` on it crashed; they now return an absent optional (breaking, for 0.2.0).

### 4. OpenAPI / Swagger — done (2026-10-08)

Generate the document with pascal-jsonmapper-faa's DOM instead of SwagDoc (Delphi only). The
schema structure comes from published properties; the metadata the origin takes from attributes
(`[SwagProp]` description/example, `[SwagMin]`, `[SwagMax]`, `[SwagEnum]`, `[SwagPattern]`)
must be registered in code, because FPC 3.2.2 has no attributes. Decided (user, 2026-10-08):
**fluent**, next to the DTO's `RegisterMapping`, along the lines of
`Describe(TOrder, 'status').Desc('...').Example('open').Enum('open,paid')`.

### Messaging layer removed (2026-10-09, 0.6.0)

Decided by the user: `PascalApi.Messaging` (broker-agnostic contracts and an adapter registry,
from the origin) goes away, and the documentation points to pascal-amqp-faa for messaging, and to
pascal-redis-faa and pascal-pipes-faa for Redis and IPC, as the first choice
(`docs/related-libraries.md`, the top of `CLAUDE.md`, `AGENTS.md`, the README). Why: no adapter
existed on FPC, nothing used the registry, and depending on pascal-amqp-faa in the package would
make every API link a broker client.

### 5. MCP server — done (2026-10-09)

Protocol revision 2026-07-28 only (the user's decision: no legacy `initialize`). Reads the model
of phase 4; tool calls by HTTP loopback (`fphttpclient` on FPC, `THTTPClient` on Delphi) through
every middleware, with `Authorization` and `X-Forwarded-For` passed on; query arguments in the
query string (the origin's defect fixed); results as text plus `isError`. `McpDeriveName` and
the tag filter ported with the origin's test cases. CI drives both samples with the official
Python SDK (`mcp` 2.0.0). Design and decisions: `docs/mcp-design.md`.

Measured with the SDK, missed in the first reading of the specification: `server/discover` and
`tools/list` must carry `ttlMs` and `cacheScope` (cacheable results); the SDK rejects a
`tools/list` without them.

### 6. Observability — done: phases A, B and C (2026-10-09), D and pool metrics (2026-10-12)

W3C trace context, Prometheus metrics, health endpoints and OpenTelemetry (OTLP/HTTP JSON)
export, in four stages (A: trace context and correlated logs; B: metrics and health; C: spans and
OTLP; D: hooks in the sibling libraries). Decided by the user: the contracts go to
pascal-common-faa (in order of stability; not a separate library for now), A and B first, and
`X-Request-Id` becomes the 32-digit trace id (breaking, 0.8.0). Design, open decisions and risks:
`docs/observability-design.md`.

Phase A (trace context and correlated logs) released as 0.8.0, verified on FPC Windows and
Linux and Delphi 12 Win32/Win64: the request id is the trace id, `traceparent` reaches the handler and the MCP
tool calls, JSON access log opt-in. Found on the way: Horse runs global middlewares twice when
no route matches (the logger now runs once per request).

Phase B (metrics and health) released as 0.9.0, verified on FPC Windows and Linux and Delphi 12
Win32/Win64:
`PascalApi.Horse.Observability` on pascal-common-faa 1.6.0's `PascalCommon.Metrics`; CI checks
both samples' `/metrics` with `promtool`. Found: Horse's `MatchedRoute` keeps a partial match.

Phase C (spans and OTLP export) released as 0.10.0, verified on FPC Windows and Linux and
Delphi 12 Win32/Win64: `PascalApi.Tracing` (unstable until phase D) and `PascalApi.Otlp`; CI runs an
OpenTelemetry Collector next to the samples and checks the spans it received.

Phase D (the sibling libraries join the trace) prepared as 0.11.0 on 2026-10-12, after
pascal-common-faa 1.7.0/1.8.0 (`PascalCommon.Tracing`), pascal-db-faa 0.13.0, pascal-redis-faa
0.2.0 and pascal-amqp-faa 0.2.0: `PascalApi.Tracing` removed (breaking), the submodules on
common v1.8.0 and db v0.13.0, `ReadAppConfig` for the `.env`; CI checks sample 02's database
spans under the request. Verified on FPC Windows and Linux and Delphi 12 Win32/Win64.

Next (agreed 2026-10-12): pool metrics recorded by pascal-db-faa on `PcMetrics`, with
OpenTelemetry's `db.client.connection.*` names; the handoff is in `docs/observability-design.md`
("Pool metrics in pascal-db-faa"). Redis and AMQP spans stay out of this repository's samples.

Pool metrics done on 2026-10-12: pascal-db-faa 0.14.0 records them; here the submodule moved
and `tools/http_scenarios_db.sh` checks them (65 checks). `promtool` rejects the OpenTelemetry
name `db_client_connection_count` (its `_count` lint); the user chose to accept that one warning
in CI (`tools/promtool_check.sh`). No release: no library code changed.

### 7. Multi-tenancy — done in the library (2026-10-13)

Opt-in support for multi-tenant APIs, decided outside the database: tenant resolution (JWT claim
first), an explicit tenant context, a catalog, and one data-scope contract with two shipped
modes (database per tenant, shared database with `tenant_id`; not schema per tenant), with
repositories that always filter by `tenant_id`. Ten decisions taken with the user; one waits on
a measurement in pascal-db-faa (pool metrics after a pool closes). First as
`samples/03-tenants`, then promoted. Design: `docs/multitenancy-design.md`.

`samples/03-tenants` done on 2026-10-13, verified on FPC Windows and Linux (CI script: 57
checks, with the cross-tenant attempts in both modes) and on Delphi 12 Win32/Win64. It changed
two details: the data scope carries the `IDBFactory` (the repository needs its `SqlLoader`), and
the filter is set by one call (a forgotten bind is a silent 404 on SQLdb/SQLite).

Promoted the same day: `PascalApi.Tenancy` and `src/horse/PascalApi.Horse.Tenancy`, with
`PascalApi.TenancyTests` (24 tests) and idle databases dropped (`AIdleSeconds`), safe for the
metrics because a freed pool gives its series back (already tested in pascal-db-faa 0.14.0).
The keyed pool registry stayed in the resolver (no second consumer for pascal-db-faa). Verified
on FPC Windows and Linux and Delphi 12 Win32/Win64 (239 tests, 0 leaks; sample 03, 57 checks).
Released as 0.12.0.

After 0.12.0, the three follow-ups (released as 0.13.0): `tenant.id` in the access log and spans
(`TLoggerMiddleware.AddField`), the rate limit by plan (`TRateLimitOptions.LimitFor`,
`TTenantInfo.Plan`), and the catalog from a control database with a cache
(`TDbTenantCatalog`, `TCachedTenantCatalog`). On the way: a client could hide a request from
the access log on Delphi (Indy kept a raw `:pascalapi-logged` line); fixed. And on Delphi, with
stdout in a file or a pipe, the end of the last access line stayed in the RTL's buffer: fixed
in pascal-common-faa 1.8.1 (`SafeWriteln` flushes on both compilers), now the minimum.

### 8. Guides for the library's users — done (2026-10-14)

The design documents record decisions for the maintainers; nothing explained to a user how to
build an application. `docs/guide/` holds guides, one per topic, all written to the template in
`docs/guide/README.md` (what it solves, the smallest program, step by step, choices, pitfalls,
testing, reference), with code taken from the samples. Done: multi-tenancy
(`docs/guide/multitenancy.md`), getting started (`docs/guide/getting-started.md`), configuration
(`docs/guide/configuration.md`), errors and validation (`docs/guide/errors.md`), authentication
(`docs/guide/authentication.md`), rate limiting (`docs/guide/rate-limiting.md`), database access
(`docs/guide/database.md`), logging and observability (`docs/guide/observability.md`), OpenAPI
(`docs/guide/openapi.md`), MCP (`docs/guide/mcp.md`), messaging, Redis and IPC (`docs/guide/messaging.md`): every topic
the index planned. Added on 2026-10-15, at the user's request: DTOs and JSON
(`docs/guide/dtos-json.md`), which also brought `ParseQueryInt`'s 400 and `umError` in the samples.
Added on 2026-10-18, at the user's request: JWT signing keys and rotation (`docs/guide/jwt-keys.md`),
steps 8-11 of the authentication guide plus procedures for a live API; the guide template got an
optional "Procedures" part for it.

`TSQLResult`'s methods (`ProcessTag`, `ReplaceLiteral`, `ApplyOperator`, `ApplyFilter`) changed
`Self` and returned it. Called on a `const TSQLResult` parameter, that leaked the new string on
FPC 3.2.2/Linux and changed the caller's variable on Win64 (measured in `TTenantFilter.Prepare`,
fixed here with a local copy; the dual-compiler skill's `rtl-gotchas.md`, "Memory /
interfaces"). **pascal-db-faa 0.15.0** (2026-10-16; the submodule is on it) returns a
changed copy instead, measured on five platforms (its gotcha 53; Delphi Win32 gave "Invalid
pointer operation" before). This library now requires 0.15.0, and `Prepare` dropped its copy.

Candidates for the sibling libraries, found while measuring for the DTOs and JSON guide and left
for their own sessions (the user's decision, 2026-10-15):

- **pascal-jsonmapper-faa 0.3.0: a member sent twice kept one value** (`{"name":"First",
  "name":"Second"}` stored `First`; with `"NAME"` first, the second won, so "the first wins" was
  never exact); many parsers keep the last, so a gateway in front of the API can read the same body
  differently. **Fixed in 0.4.0** (2026-10-15; the submodule is on it): a duplicate is refused,
  whatever `UnknownMembers` says, also when the names differ only in ASCII case or are the
  declared name and the `Naming` one; the API answers 400 `$.name: duplicate member (...)`
  (`tools/http_scenarios.sh`). Its messages named Pascal classes (`TCityInsert.Name`,
  `no published property of TOrder`), which reached the client: **fixed in 0.5.0** (2026-10-15),
  which raises `EJsonInputError` for input at fault, in JSON terms only (the Pascal side in
  `Detail`). The error handler here now maps by class: `EJsonInputError` 400, any other
  `EJsonMapperError` 500, logged (a programming error with a path was a 400 that named classes).
  On FPC 3.2.2 a large `Currency` lost its last digits (`123456789012345.6789` came back as
  `...6768` on Win64, `High(Currency)` with its sign flipped): **fixed in 0.6.0** (2026-10-16),
  which never goes through floating point; sample 01's `POST /prices` checks it over HTTP (3 of
  its checks failed on 0.5.0).
- **pascal-amqp-faa 0.3.0: an exception in a consumer callback was swallowed** by
  pascal-common-faa's pool (`TAMQPDeliveryWork.Execute` re-raises into it): the message was
  neither acknowledged nor rejected, nothing was logged, and it came back on every restart
  (measured with a JSON consumer and RabbitMQ 3). **Fixed in 0.4.0** (2026-10-15): the channel's
  `OnConsumerError` gets it, and the message is rejected without requeue unless the handler says
  otherwise (no dead-letter exchange: dropped). Sample 04 logs there and lost its `try`
  (measured). In 0.4.0 its log line had no trace id (the `process` span had finished when the
  handler ran); **0.4.1** runs the handler inside that span, and the line carries the message's
  trace id again (measured: the same trace as the span, which ends with the error status).
- **pascal-pipes-faa 0.1.1: an exception in `OnMessage` reached nobody**: `OnError` wasn't called
  on either side (measured on FPC/Windows). **Fixed in 0.2.0** (2026-10-15): an exception that
  escapes any handler goes to the same component's `OnError`, on the handler's thread, in every
  dispatch mode; `PipesJsonSample` assigns one and lost its `try` (measured: `OnMessage levantou
  EJsonMapperError: $.quantity: ...`). Its README now lists FPC on Windows too. **0.3.0** turned
  its runtime messages into English (`server replied with error: ...`, `OnMessage raised ...`;
  measured with `PipesJsonSample`).

Fixed in pascal-amqp-faa 0.3.0 (2026-10-15; the messaging guide re-measured with it), found while
measuring for the messaging guide: with `AutoReconnect` on, a non-durable queue declared on one channel
and consumed on another never recovered after a broker restart (90 s of `EAMQPConnection`, no
callback, nothing logged), because each channel replays only its own topology and a failed attempt
is swallowed; declaring the queue on the consuming channel too recovered in 16 s. Also, without
`AutoReconnect`, a publish on a dead connection raised `EWriteError` ("Stream write error"), not
the `EAMQPConnection` its README lists (pascal-amqp-faa 0.2.0, FPC 3.2.2/Windows, RabbitMQ 3).
0.3.0 replays the whole connection, raises `EAMQPConnection` with the reason, and adds
`OnReconnectError`/`LastReconnectError`; with it the same restart recovered with the queue
declared on one channel only.

Fixed in pascal-db-faa 0.14.1 (2026-10-15; the submodule is on 0.14.2), found while measuring
for the OpenAPI guide: FireDAC raised `[FireDAC][DatS]-32 Variable length column
overflow` when it reads a value longer than its column, which SQLite stores anyway. pascal-db-faa
doesn't classify it, so here it is a 500: the insert of a 150-character name into
`VARCHAR(100)` answered 500 with the row saved, and every later read of that row answered 500
(sample 02, Delphi 12 Win32). Samples 02 and 03 now check the length first. 0.14.1 maps SQLite
strings to memo fields in the FireDAC adapter, so the whole value is read, as SQLdb and Zeos did:
a 150-character name written straight into sample 02's file now reads back with 200 on Delphi
(was 500 on the 0.14.0 build). To refuse such values in the database, declare
`CHECK (length(NAME) <= 100)`: the insert then raises `EConstraintViolationException` (`cvCheck`,
measured on pascal-db-faa's three adapters), a 422 here. Whether the API's insert answered 500
because the handler reads the row back was never verified, and no longer matters.

### 9. JWT signing keys with rotation — designed (2026-10-18)

One secret today: rotating it invalidates every token. Opt-in key ring named by `kid`, keys that
go pending, signing, verifying and gone, so a rotation keeps the tokens already issued;
automatic generation and rotation with keys in a database table (pascal-db-faa) or, as an
option, in Redis (pascal-redis-faa; several instances race on a unique generation, `HSETNX` in
Redis); one ring per tenant, the tenant inside the `kid` and checked against the verified
claim. Decisions taken with the user: database store with Redis as an option (in
`src/redis`, outside the `.lpk`), plain-text secrets for now, per-tenant rings. Random bytes need pascal-common-faa to
make its system source public first (phase 2). Design and phases: `docs/jwt-keys-design.md`.

Phase 1 done on 2026-10-18 (unreleased): `PascalApi.JwtKeys` with the static ring (`JWT_KEYS`)
and a legacy secret, `TJwtMiddleware.New(ARing)` and `Sign`; sample 03 uses it. FPC on Windows
and Linux and Delphi 12 Win32/Win64 (304 tests, 0 leaks; 186 + 93 + 107 checks).

Phase 2 done on 2026-10-18 (unreleased): pascal-common-faa 1.15.0 (`PascalCommon.Random`, now the
minimum), `TRotatingJwtKeyRing` with the database, memory and Redis stores (`src/redis`,
pascal-redis-faa 0.2.0 as a test-only submodule); sample 03's `JWT_KEY_STORE=db|redis`, checked
by `tools/http_scenarios_jwt_rotation.sh` with two instances (22 checks each). FPC on Windows
and Linux and Delphi 12 Win32/Win64: 323 tests, 0 leaks; 186 + 93 + 107 + 22 + 22 checks.

Phase 3 done on 2026-10-18 (unreleased): `TTenantJwtKeyRing` in `PascalApi.Tenancy`, a key ring
per tenant with the claim checked against the key's tenant; sample 03's `db`/`redis` modes use
it (29 and 25 checks). FPC on Windows and Linux and Delphi 12 Win32/Win64: 330 tests, 0 leaks.
Three choices taken as consequences of the design ("Phase 3 as built" in
`docs/jwt-keys-design.md`), shown to the user, no change asked. All three phases done.

Sealed secrets on 2026-10-18 (unreleased; decision 6 revised with the user's four choices):
pascal-common-faa 1.16.0 (`PascalCommon.AesGcm`, now the minimum), `TSealedJwtKeyStore` and
`TAesGcmSecretCipher` here; sample 03 seals in both modes. FPC on Windows and Linux and Delphi
12 Win32/Win64: 340 tests, 0 leaks; 186 + 93 + 107 + 31 + 25 checks.

### 10. Candidates from pascal-agenda-faa — proposed (2026-10-18)

The first real application on this library: pascal-agenda-faa (multi-tenant scheduling for
clinics and salons, a sibling repository; scope and milestones in its `docs/design.md`). Each
candidate is built there first, in its own unit under this repository's code rules, and comes
here (opt-in) only after it works there and turns out generic, by the user's decision.

| Candidate | Would live in | Status |
|---|---|---|
| Password hashing (PBKDF2-HMAC-SHA256) | pascal-common-faa | **PBKDF2 added in pascal-common-faa 1.18.0**; the stored form stays in the application |
| A Find DTO filled from the query string | `PascalApi.QueryParams` | found 2026-10-19 (five list routes copied each member by hand); user chose to promote; **done in 0.19.0** (`TQueryParams`, `THorseQueryParams`, `ApiQueryParamType`), sample 02 |
| The paged query: count and page through the same filters, one transaction | `PascalApi.PagedQuery` | found 2026-10-19 (five repositories with the same `FindPage`); **done in 0.19.0** (`TPagedQuery`, `TTenantPagedQuery`, `TQueryArgs`), sample 02 |
| An instant type: zone required on input, `Z` on output | pascal-jsonmapper-faa | found 2026-10-19 (time off carried as strings); **done in pascal-jsonmapper-faa 0.7.0** (`TUtcDateTime`), `date-time` in the document here in 0.19.0 |
| LIKE patterns escaped with `!` | pascal-db-faa | found 2026-10-19: the application wrote its own with `ESCAPE '\'` and answered 500 on a search combined with a filter (pascal-db-faa's gotcha 26); **done in pascal-db-faa 0.16.0** (`PdbLikeContains`) |
| Search key: lower case, accents removed | pascal-common-faa | **done in pascal-common-faa 1.20.0** (`PcFoldForSearch`) |
| Refresh tokens (rotation, reuse detection) | `PascalApi.RefreshTokens` | user chose the core only (2026-10-19), reopening "an application's flow" in `docs/jwt-keys-design.md`; **done in 0.19.0** (`TRefreshTokens`, `IRefreshTokenStore`, `TDbRefreshTokenStore`, `TMemoryRefreshTokenStore`); proven end to end by pascal-agenda-faa's HTTP scenarios; no sample or guide here yet |
| `Idempotency-Key` middleware | `PascalApi.Idempotency` | proposed |
| `ETag`/`If-Match` (412/428) | `PascalApi.Http` | proposed |
| Tenant from the path or host | `PascalApi.Tenancy` | **reopened**: multi-tenancy decision 5 (the real case: public booking routes by slug, user 2026-10-18) |
| Signed links (HMAC + expiry, JWT key ring) | `PascalApi.SignedUrl` | proposed |
| IANA time zones on both compilers | pascal-common-faa | proposed; own design phase (user, 2026-10-18) |
| Outbox + relay to AMQP | a bridge (`src/amqp` or pascal-amqp-faa) | needs a second case |
| Scheduler with a lease | pascal-common-faa | needs a second case |
| RFC 9457 errors | `TErrorHandlerMiddleware` option | needs a second case |
| Typed HTTP client (refresh, retry, trace) | to be decided | needs a second case |
| **Bug**: `EValidationException.CreateFmt` (any `EHttpException` subclass) leaves `StatusCode` 0, answered as `HTTP/1.1 0` | `PascalApi.Http` | found 2026-10-18 by pascal-agenda-faa (measured on FPC Windows); **fixed in 0.17.0**: `AfterConstruction` + `DefaultStatusCode`, and `MapException` answers a status outside 100-599 with 500 |
| A handler's 401 with `WWW-Authenticate`, and a `code` member in error bodies | `PascalApi.Http` / error handler | found 2026-10-18 by pascal-agenda-faa (its login writes both by hand); **added in 0.17.0**: `EUnauthorizedException`, `Code`, `TErrorResponse.Challenge` |
| DTO interfaces that show every member: the interface mirrors the class's published properties, read-only; DTOs are filled through the class | `PascalApi.Dto` (convention), samples, `docs/guide/dtos-json.md` | raised 2026-10-19 from pascal-agenda-faa's `Agenda.Services` (code that sees only the interface didn't see the members); user chose read-only and read-only paged bases (breaking); **done in 0.18.0**: FPC Windows/Linux and Delphi 12 Win32/Win64, 347 tests, 195 + 93 + 107 + 31 + 25 checks |
