# pascal-api-infra-faa

Infrastructure for REST APIs on [Horse](https://github.com/HashLoad/horse), for **Delphi** and
**Free Pascal / Lazarus** (FPC 3.2.2+, `{$MODE DELPHI}`), from one source tree.

It ports the ideas of `delphi-api-infra-faa` (Delphi only) to both compilers, on top of
[pascal-common-faa](https://github.com/fabianoallex/pascal-common-faa) (optional types, clocks,
threading), [pascal-jsonmapper-faa](https://github.com/fabianoallex/pascal-jsonmapper-faa)
(JSON ⇄ DTO) and [pascal-db-faa](https://github.com/fabianoallex/pascal-db-faa) (database layer,
paging). It is not a drop-in replacement for the Delphi library: DTOs map **published**
properties, because FPC 3.2.2's RTTI sees nothing else.

Version **0.1.1** (see the [changelog](CHANGELOG.md)): the core and the Horse middlewares; OpenAPI and
MCP come later. See [docs/plan.md](docs/plan.md).

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
| `PascalApi.Http` | HTTP exceptions (`EValidationException`, `ENotFoundException`...), exception → status mapping, CORS, Bearer, client IP, access log line; replaceable client messages (English or Portuguese) |
| `PascalApi.Crypto` | SHA-256, HMAC-SHA256, Base64url (FPC 3.2.2 has no SHA-256) |
| `PascalApi.Jwt` | HS256 JSON Web Tokens: sign, verify (alg, signature, exp, nbf), claims |
| `PascalApi.Horse.Middlewares` (`src/horse`) | Horse middlewares: error handler, CORS, request log, Bearer auth, JWT, rate limit |
| `PascalApi.Version` | `PASCALAPI_VERSION`, for compile-time checks |

## A quick look

```pascal
TErrorHandlerMiddleware.Register(LOnError);            // {"error": ...} + status for any exception
THorse.Use(TLoggerMiddleware.New);                      // one access line per request, X-Request-Id
THorse.Use(TCorsMiddleware.New('https://app.example.com'));
THorse.Use(TJwtMiddleware.New(TAppConfig.Get('JWT_SECRET'), ['/health', '/auth/login']));
THorse.Use('/reports', TRateLimitMiddleware.New(60, 60));

THorse.Get('/cities', GetCities);   // raise ENotFoundException / EValidationException freely;
                                    // answer with TJsonSend.Send(Res, Json) (UTF-8 on both compilers)
THorse.Listen(9000);
```

On FPC a Horse callback is a plain procedure, so each middleware keeps its settings in the unit:
one configuration per process.

## Samples

| Sample | Shows | Checked by |
|---|---|---|
| [01-api](samples/01-api/ApiSample.dpr) | every middleware (errors, CORS, log, JWT, rate limit), paging and validation, in memory | `tools/http_scenarios.sh` (65 checks) |
| [02-db](samples/02-db/DbApiSample.dpr) | SQLite through pascal-db-faa (SQLdb on FPC, FireDAC on Delphi): migrations, paging and ordering in SQL, filters, 409 from a unique key, NULL as `null` | `tools/http_scenarios_db.sh` (31 checks) |

Both run with one source on Delphi and Lazarus/FPC. On FPC for Windows, sample 02 needs
sqlite.org's `sqlite3.dll` next to the executable (see `tools/test_http.sh`).

## Using it

Add the library's `src` and its dependencies to the project, each from **your** single copy
(git submodules of your project), never from this repository's `external/`:

- Delphi: search path with `src`, `pascal-common-faa/src`, `pascal-common-faa/bridges/jsonmapper`,
  `pascal-jsonmapper-faa/src`, `pascal-db-faa/src`; for the middlewares also `src/horse` and
  Horse's `src`.
- Lazarus: require `packages/pascal_api_infra_faa.lpk` (it requires `pascal_common_faa`,
  `pascaljsonmapper_pkg` and `pascal_db_faa`); for DTO JSON, also `pascal_common_faa_jsonmapper`.
  The middlewares are not in the package (Horse has none): add `src/horse` and Horse's `src` to
  the project's search path. On **Windows**, FPC 3.2.2 needs a one-line workaround in Horse
  3.3.2's `Horse.FPC.inc`; `tools/prepare_horse.sh` shows it.

Console and service programs on FPC call `SetMultiByteConversionCodePage(CP_UTF8)` at startup
(LCL programs already run in UTF-8); on Unix, put `cthreads` and `cwstring` first in the
program's `uses`.

## Tests

```
git submodule update --init
sh tools/test_fpc.sh            # FPC on Windows (lazbuild)
sh tools/test_fpc_docker.sh     # FPC 3.2.2 on Linux, in Docker
sh tools/test_http.sh           # both samples over HTTP (FPC on Windows)
sh tools/test_http_docker.sh    # the same on Linux, in Docker
sh tools/ci-test.sh             # what CI runs
```

On Delphi, open `PascalApi.groupproj` and run `PascalApi.UnitTests` (Win32 and Win64; "Build All"
builds only the active platform). Every suite must end with 0 leaks.

## License

MIT. See [LICENSE](LICENSE).
