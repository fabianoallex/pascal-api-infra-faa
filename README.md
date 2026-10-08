# pascal-api-infra-faa

Infrastructure for REST APIs on [Horse](https://github.com/HashLoad/horse), for **Delphi** and
**Free Pascal / Lazarus** (FPC 3.2.2+, `{$MODE DELPHI}`), from one source tree.

It ports the ideas of `delphi-api-infra-faa` (Delphi only) to both compilers, on top of
[pascal-common-faa](https://github.com/fabianoallex/pascal-common-faa) (optional types, clocks,
threading), [pascal-jsonmapper-faa](https://github.com/fabianoallex/pascal-jsonmapper-faa)
(JSON ⇄ DTO) and [pascal-db-faa](https://github.com/fabianoallex/pascal-db-faa) (database layer,
paging). It is not a drop-in replacement for the Delphi library: DTOs map **published**
properties, because FPC 3.2.2's RTTI sees nothing else.

Version **0.1.0**, work in progress: the core is written, the Horse middlewares are next. See
[docs/plan.md](docs/plan.md).

## Contents

| Unit | What it gives you |
|---|---|
| `PascalApi.Config` | `TAppConfig`: settings from the environment, then a `.env` file, then a default |
| `PascalApi.OrderBy` | `TOrderBySpec`: the client's `"name,-state"` to an ORDER BY fragment, through an allow-list |
| `PascalApi.Pagination` | query-string page/limit to `TPageRequest` (pascal-db-faa), and the paged JSON envelope |
| `PascalApi.RateLimitState` | the sliding window behind rate limiting, on a monotonic clock |
| `PascalApi.FileLog` | asynchronous file logging, one file per category, rotated by size; `TLogTruncate` |
| `PascalApi.Dto` | marker interfaces and base classes for DTOs, including paged search and paged response |
| `PascalApi.Messaging` | broker-agnostic consumer/publisher contracts and a registry of adapters by name |
| `PascalApi.Text` | UTF-8 bytes ⇄ string, MD5, UTF-8-safe prefix — the same on both compilers |
| `PascalApi.Version` | `PASCALAPI_VERSION`, for compile-time checks |

## Using it

Add the library's `src` and its three dependencies to the project, each from **your** single copy
(git submodules of your project), never from this repository's `external/`:

- Delphi: search path with `src`, `pascal-common-faa/src`, `pascal-common-faa/bridges/jsonmapper`,
  `pascal-jsonmapper-faa/src`, `pascal-db-faa/src`.
- Lazarus: require `packages/pascal_api_infra_faa.lpk` (it requires `pascal_common_faa` and
  `pascal_db_faa`); for JSON, also `pascaljsonmapper_pkg` and `pascal_common_faa_jsonmapper`.

Console and service programs on FPC call `SetMultiByteConversionCodePage(CP_UTF8)` at startup
(LCL programs already run in UTF-8); on Unix, put `cthreads` and `cwstring` first in the
program's `uses`.

## Tests

```
git submodule update --init
sh tools/test_fpc.sh            # FPC on Windows (lazbuild)
sh tools/test_fpc_docker.sh     # FPC 3.2.2 on Linux, in Docker
sh tools/ci-test.sh             # what CI runs
```

On Delphi, open `PascalApi.groupproj` and run `PascalApi.UnitTests` (Win32 and Win64; "Build All"
builds only the active platform). Every suite must end with 0 leaks.

## License

MIT. See [LICENSE](LICENSE).
