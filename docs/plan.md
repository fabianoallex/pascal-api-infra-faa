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

### 8. Guides for the library's users — started (2026-10-14)

The design documents record decisions for the maintainers; nothing explained to a user how to
build an application. `docs/guide/` holds guides, one per topic, all written to the template in
`docs/guide/README.md` (what it solves, the smallest program, step by step, choices, pitfalls,
testing, reference), with code taken from the samples. Done: multi-tenancy
(`docs/guide/multitenancy.md`), getting started (`docs/guide/getting-started.md`), configuration
(`docs/guide/configuration.md`), errors and validation (`docs/guide/errors.md`), authentication
(`docs/guide/authentication.md`), rate limiting (`docs/guide/rate-limiting.md`), database access
(`docs/guide/database.md`), logging and observability (`docs/guide/observability.md`), OpenAPI
(`docs/guide/openapi.md`). Planned: the other topics listed in `docs/guide/README.md` (MCP,
sibling libraries).

A candidate for pascal-db-faa, found while measuring for the OpenAPI guide and left for later
(the user's decision, 2026-10-14): FireDAC raises `[FireDAC][DatS]-32 Variable length column
overflow` when it reads a value longer than its column, which SQLite stores anyway. pascal-db-faa
doesn't classify it, so here it is a 500: the insert of a 150-character name into
`VARCHAR(100)` answered 500 with the row saved, and every later read of that row answered 500
(sample 02, Delphi 12 Win32). Samples 02 and 03 now check the length first.
