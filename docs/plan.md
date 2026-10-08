# Plan

Where pascal-api-infra-faa came from, what is decided, and what is left. Dated entries; the
newest state is at the top of each section.

## Goal

Offer what `delphi-api-infra-faa` offers to a Horse REST API, on Delphi **and** Lazarus/FPC
3.2.2, as a separate library. Decided with the user on 2026-10-08:

- `delphi-api-infra-faa` **stays separate**, serving its existing Delphi-only consumer. This
  library doesn't replace it and isn't a drop-in for it.
- Scope for now: **phases 1 to 3** below (the core and the middlewares). Swagger/OpenAPI and MCP
  (phases 4 and 5) come later.

## Evaluation (2026-10-08)

The origin's own assessment (`delphi-api-infra-faa/docs/lazarus-compat.md`, 2026-08-21) listed
five blockers. Since then, three were solved by the sibling libraries:

| Blocker (2026-08) | Now |
|---|---|
| FireDAC (adapter + `Common.Helpers`) | pascal-db-faa: SQLdb, Zeos and FireDAC adapters |
| `System.JSON` | pascal-jsonmapper-faa's own DOM (`PascalJsonMapper.Json`), identical output on both compilers |
| `TJsonMapper` on extended RTTI | pascal-jsonmapper-faa, with published properties (a convention change) |
| Closures (`reference to`) | still open: phase 3 |
| SwagDoc + `[SwagProp]` attributes | still open: phase 4 |

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

`Text`, `Config`, `OrderBy`, `Pagination`, `RateLimitState`, `FileLog`, `Dto`, `Messaging`:
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
  (Horse with the `tools/prepare_horse.sh` workaround), FPC Linux (Horse unchanged) and Delphi
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
- Still open: the PR to Horse for the `constref` workaround.

### Sample with a real database — done (2026-10-08)

`samples/02-db`: SQLite through pascal-db-faa, SQLdb on FPC and FireDAC on Delphi; 31 HTTP checks
(`tools/http_scenarios_db.sh`) green on FPC Windows and Linux and Delphi 12 Win32/Win64. It found a real defect:
`ParseQueryInt`/`ParseQueryStr` returned `nil` for a missing parameter, and a repository testing
`HasValue` on it crashed; they now return an absent optional (breaking, for 0.2.0).

### 4. OpenAPI / Swagger — later

Generate the document with pascal-jsonmapper-faa's DOM instead of SwagDoc (Delphi only). The
schema structure comes from published properties; the metadata the origin takes from attributes
(`[SwagProp]` description/example, `[SwagMin]`, `[SwagMax]`, `[SwagEnum]`, `[SwagPattern]`)
must be registered in code, because FPC 3.2.2 has no attributes. Decided (user, 2026-10-08):
**fluent**, next to the DTO's `RegisterMapping`, along the lines of
`Describe(TOrder, 'status').Desc('...').Example('open').Enum('open,paid')`.

### 5. MCP server — later

Reads the model of phase 4 instead of SwagDoc's; HTTP loopback with `fphttpclient` on FPC and
`THTTPClient` on Delphi (the pattern of pascal-dfe-broker's `DFe.Transmissor.Http.Cliente`).
`MCP.Utils` (tool names, tag filter) is pure and moves with it.
