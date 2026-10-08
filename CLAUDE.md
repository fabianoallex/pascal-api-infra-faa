# pascal-api-infra-faa — Guide for AI agents

Infrastructure for REST APIs on Horse, **dual-compiler** (Delphi + Lazarus/FPC 3.2.2): query-string
paging and ordering, configuration, file logging, rate limiting, DTO bases, messaging contracts
and (phase 3, not yet written) Horse middlewares. Built on pascal-common-faa,
pascal-jsonmapper-faa and pascal-db-faa.

For the general dual-compiler rules (project anatomy, `.inc`, mirrored tests, CI), use the
`dual-compiler-delphi-lazarus` skill. This file records only what is specific to this repo. The
plan, the phases and what is still open are in `docs/plan.md`.

---

## Language

Everything in this repository is in **English**: code, identifiers, comments, runtime messages,
test names and assertion messages, documentation and commit messages. Test *data* may contain
non-ASCII values on purpose (`'São Paulo → ok'`).

---

## Origin: delphi-api-infra-faa

The units are ports of `delphi-api-infra-faa` (Delphi only), which **stays separate** and keeps
serving its Delphi consumer; this repository doesn't replace it and isn't a drop-in for it. Fixes
don't flow between the two automatically. Each unit's header says what changed in the port.

| Here | There |
|---|---|
| `PascalApi.Config` | `Common.Config` (without `SetIniFile`/`IniPath`) |
| `PascalApi.OrderBy` | `Common.OrderBy` |
| `PascalApi.Pagination` (+ pascal-db-faa's `PascalDb.Paging`) | `Common.Pagination` |
| `PascalApi.RateLimitState` | `Common.RateLimitState` |
| `PascalApi.FileLog` | `Common.FileLog` |
| `PascalApi.Dto` | `Common.DTO.Base` |
| `PascalApi.Messaging` | `Messaging.Interfaces` + `Messaging.Adapters.Registry` |
| `PascalApi.Text` | — (new: UTF-8 bytes, MD5, UTF-8 prefix) |
| pascal-jsonmapper-faa | `Common.JsonMapper` |
| pascal-db-faa | `src/Db`, `Common.Helpers` |

**The DTO convention is different:** JSON is mapped from **published** properties under `{$M+}`
(pascal-jsonmapper-faa's contract), not from public properties read by Delphi's extended RTTI.
Swagger attributes (`[SwagProp]` etc.) don't exist here: FPC 3.2.2 has no custom attributes at
all (measured, skill `references/rtti-gotchas.md`).

---

## Dependencies

`external/` holds the three libraries as git submodules, pinned to tags: pascal-common-faa
`v1.3.0`, pascal-jsonmapper-faa `v0.2.1`, pascal-db-faa `v0.12.0`. They are **only for this
repository's tests**: a consumer provides its own single copy of each (submodule + search path),
never `pascal-api-infra-faa/external/...`. Clone with `git submodule update --init` (no
`--recursive`: pascal-db-faa's own `external/` is not needed).

- Minimum pascal-common-faa version checked in `PascalApi.Dto` (`PASCALCOMMON_VERSION`).
- Delphi search path of a test project: `src`, `external/pascal-common-faa/src`,
  `external/pascal-common-faa/bridges/jsonmapper`, `external/pascal-jsonmapper-faa/src`,
  `external/pascal-db-faa/src`.
- Lazarus: `packages/pascal_api_infra_faa.lpk` requires `pascal_common_faa` and `pascal_db_faa`
  with `DefaultFilename ... Prefer="True"` pointing at `external/`. The test project also requires
  `pascaljsonmapper_pkg` and `pascal_common_faa_jsonmapper` (mapper listed before the bridge).

---

## Code rules (every unit in `src/`)

- **`{$I pascalapi.inc}` right after `unit ...;`** (`{$MODE DELPHI}{$H+}` on FPC,
  `PASCALAPI_WINDOWS`, `PASCALAPI_FUNCREFS`).
- **`uses` without namespaces** (`SysUtils`, `Generics.Collections`). A Delphi-only unit goes
  inside `{$IFNDEF FPC}` (`System.Hash` in `PascalApi.Text`).
- **No anonymous methods** and no `TThread.CreateAnonymousThread`: FPC 3.2.2 has neither. A
  `TThread` subclass (`TFileLogFlushThread`) or a named routine.
- **Public callbacks follow `PASCALAPI_FUNCREFS`**: `reference to` on Delphi, `of object` on FPC
  (same as `PASCALDB_FUNCREFS`). Plain function pointers where no state is captured
  (`TEnvironmentReader`).
- **No string helpers** (`.Split`, `.StartsWith`, `.Substring`): plain `Pos`/`Copy`/`Trim`.
- **Text that leaves the process is UTF-8, measured in bytes on both compilers** (`PascalApi.Text`).
  `Length` counts UTF-16 units on Delphi and bytes on FPC, so anything that cuts or sizes text
  for output (`TLogTruncate`) works on UTF-8 bytes and never splits a character.
- **Shared defaults are created in `initialization`, never lazily** (a lazy default raced in
  pascal-common-faa's `TClock`): `TAppConfig`'s reader and path, the `FileLog` instance, the
  messaging registry.
- **Time through pascal-common-faa's `TClock`/`TTicker`** (replaceable in tests); durations with
  `TTicker`, never `TClock`.
- **GUIDs are generated** (`[guid]::NewGuid()`), never typed; a hook rejects suspicious ones.
- **Top-of-file comment** in every unit, program and test, between `unit X;` (+ `{$I ...}`) and
  `interface`. Plain prose. If it quotes a `}` (a GUID in an example), use `(* ... *)` — a `}`
  closes a `{ }` comment early (this happened in `PascalApi.Dto`: "String exceeds line").

---

## Tests

Masters are DUnitX (`tests/Unit/*Tests.pas`), written in FPCUnit's assertion dialect through
`PascalApi.DUnitXCompat`. The FPCUnit mirrors in `tests/Unit/fpc` are **generated**: never edit
them, run `python tools/gen_fpc_mirror.py`. No `Assert.WillRaise` (it takes a closure): catch the
exception in a helper and assert on what it returned.

| Command | What |
|---|---|
| `sh tools/test_fpc.sh` | regenerate mirrors, `lazbuild` + run the FPCUnit suite (Windows) |
| `sh tools/test_fpc_docker.sh` | the same suite with plain `fpc` on Linux (Docker, `FPC_IMAGE`) |
| `sh tools/ci-test.sh` | what CI runs (builds the FPC 3.2.2 image if needed) |
| Delphi | open `PascalApi.groupproj`, build `PascalApi.UnitTests` (Win32 and Win64), run it |

Acceptance on every side: 0 errors, 0 failures, 0 leaks (heaptrc / FastMM). Delphi Community
Edition can't build from the command line: the user builds in the IDE, then the executable
can be run from here (`tests/Unit/Win32/Debug/PascalApi.UnitTests.exe`).

Never pipe `lazbuild` into `head`/`Select-Object -First`: the compiler hangs when the pipe closes
(seen in pascal-dfe-broker). Redirect to a file, as the scripts do.

New unit checklist: unit in `src/`, test master in `tests/Unit/`, then add both to
`packages/pascal_api_infra_faa.lpk`, `tests/Unit/PascalApi.UnitTests.dpr` + `.dproj` and
`tests/Unit/fpc/PascalApiUnitTestsFpc.lpr`.
