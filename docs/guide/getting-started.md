# Getting started

From an empty folder to a Horse API that answers JSON, turns exceptions into HTTP statuses, logs
every request and checks a token, on Delphi and on Lazarus/FPC from one source. The code comes
from `samples/01-api`, which compiles on both compilers and is checked over HTTP by
`tools/http_scenarios.sh` (149 checks), except the smallest program below, which says where it
was checked.

## What it solves

Horse gives you routes. An API needs more around them: JSON that arrives as UTF-8 on both
compilers, the same `{"error": "..."}` answer for every failure, an access log with a request
id, CORS, a JWT check, limits, paging. Written by hand, each of these differs a little between
Delphi and FPC, and between one project and the next.

The library gives you those pieces as Horse middlewares and plain functions, with the same
behaviour on both compilers. You write handlers that return JSON or raise an exception; the
middlewares do the rest.

What stays with your application: the routes, the handlers, your data, and the login route that
issues tokens.

## The smallest working program

Two routes, the error handler and the access log:

```pascal
program HelloApi;

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX}
  cthreads,
  cwstring,
  {$ENDIF}
  SysUtils,
  Horse,
  PascalApi.Http,
  PascalApi.Horse.Middlewares;

procedure GetHealth(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  TJsonSend.Send(ARes, '{"status":"ok"}');
end;

procedure GetCity(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  if AReq.Params['id'] <> '1' then
    raise ENotFoundException.Create('City ' + AReq.Params['id'] + ' not found.');
  TJsonSend.Send(ARes, '{"id":1,"name":"São Paulo"}');
end;

begin
  {$IFDEF FPC}
  SetMultiByteConversionCodePage(CP_UTF8);
  {$ENDIF}
  TErrorHandlerMiddleware.Register;      // exceptions -> {"error": ...} + status
  THorse.Use(TLoggerMiddleware.New);     // one access line per request
  THorse.Get('/health', GetHealth);
  THorse.Get('/cities/:id', GetCity);
  Writeln('Listening on 9000');
  THorse.Listen(9000);
end.
```

What it answers (curl against this program, built with FPC 3.2.2 on Windows for this guide on
2026-10-14; not built on Delphi, and not part of CI: sample 01 is the checked version of the same
calls):

```
GET /health      200  {"status":"ok"}                 Content-Type: application/json; charset=utf-8
GET /cities/1    200  {"id":1,"name":"São Paulo"}     (UTF-8 bytes: S 303 243 o)
GET /cities/7    404  {"error":"City 7 not found."}
```

Every answer carries an `X-Request-Id` header, and the console gets one line per request:

```
[2026-10-14 09:17:03] GET /cities/7 404 0ms 127.0.0.1 29 "-" "curl/8.12.1" 0cf29816769e2395c9f3ae8ef33faf4f
```

The last field is the same id as the response's `X-Request-Id` (a W3C trace id), so a client's
complaint can be found in the log.

## Step by step

### 1. Add the dependencies

The library needs three sibling libraries and Horse. Add each one to **your** project once, as a
git submodule, and point the compiler at them. Never use the copies inside
`pascal-api-infra-faa/external/`: those are only for this repository's own tests, and an
application must have one copy of each library.

```
git submodule add https://github.com/fabianoallex/pascal-api-infra-faa external/pascal-api-infra-faa
git submodule add https://github.com/fabianoallex/pascal-common-faa    external/pascal-common-faa
git submodule add https://github.com/fabianoallex/pascal-jsonmapper-faa external/pascal-jsonmapper-faa
git submodule add https://github.com/fabianoallex/pascal-db-faa        external/pascal-db-faa
git submodule add https://github.com/HashLoad/horse                    external/horse
```

Then check out a tag in each one. The minimum versions are checked when you compile:

| Library | Minimum | Checked by |
|---|---|---|
| pascal-common-faa | 1.8.1 | `PascalApi.Dto` stops the build (`PASCALCOMMON_VERSION`) |
| pascal-db-faa | 0.12.0 | `PascalApi.Http` stops the build (`PASCALDB_VERSION`) |
| pascal-jsonmapper-faa | 0.3.0 | only the Lazarus package (`MinVersion` in the `.lpk`) |
| Horse | 3.3.3 on FPC for Windows | 3.3.2 doesn't compile there (see [Pitfalls](#pitfalls)) |

The versions this repository tests with are the ones pinned in its `external/` folder
(`git submodule status`).

**Delphi:** add these folders to the project's search path:

```
external/pascal-api-infra-faa/src
external/pascal-api-infra-faa/src/horse
external/horse/src
external/pascal-common-faa/src
external/pascal-common-faa/bridges/jsonmapper
external/pascal-jsonmapper-faa/src
external/pascal-db-faa/src
```

That is what `samples/01-api/ApiSample.dproj` has (`DCC_UnitSearchPath`), with `..\..\` instead
of `external/pascal-api-infra-faa/`.

**Lazarus:** require the packages `pascal_api_infra_faa` (`packages/pascal_api_infra_faa.lpk`,
which pulls in `pascal_common_faa`, `pascaljsonmapper_pkg` and `pascal_db_faa`) and
`pascal_common_faa_jsonmapper` (for DTOs). Horse has no Lazarus package, and the middlewares
(`src/horse`) are not in the library's package because they need Horse, so add them to the
project's own paths:

```
Other unit files:  external/pascal-api-infra-faa/src/horse;external/horse/src
Include files:     external/pascal-api-infra-faa/src;external/horse/src
```

That is what `samples/01-api/ApiSample.lpi` has.

### 2. The program file

One `.dpr` serves both compilers. The first lines are the same in every sample:

```pascal
{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX}
  cthreads,
  cwstring,
  {$ENDIF}
  SysUtils,
  Horse,
  ...

begin
  {$IFDEF FPC}
  SetMultiByteConversionCodePage(CP_UTF8);
  {$ENDIF}
```

- `{$MODE DELPHI}{$H+}`: FPC accepts the Delphi syntax the library and Horse are written in.
- `cthreads` first on Unix: Horse answers requests on threads, and FPC on Unix has no thread
  support unless this unit comes first.
- `cwstring` on Unix: without it, FPC on Linux turned `'São'` held in a Variant into invalid
  UTF-8 (measured in pascal-db-faa's tests).
- `SetMultiByteConversionCodePage(CP_UTF8)`: a console program on FPC for Windows runs in
  code page 1252, and UTF-8 text decoded into a `string` lost every character outside it (`→`
  became `?`; measured in pascal-db-faa). For this guide, the smallest program above was also
  built without the call: `"São Paulo"` written as a literal came out with the same bytes, so the
  loss shows on decoded data, not on literals. Keep the call anyway: request bodies are decoded
  data. LCL programs already run in UTF-8.

The measurements are recorded in the `dual-compiler-delphi-lazarus` skill
(`references/rtl-gotchas.md`, "Encoding").

### 3. Answer with JSON

Send JSON with `TJsonSend.Send`, never with Horse's `Res.Send(string)`:

```pascal
procedure GetHealth(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  TJsonSend.Send(ARes, '{"status":"ok"}');
end;
```

`TJsonSend.Send(ARes, AJson, AStatus)` sends UTF-8 bytes with
`Content-Type: application/json; charset=utf-8`; the status is 200 unless you pass another
(`TJsonSend.Send(ARes, LJson, 201)`). On Delphi, `Res.Send(string)` with plain
`application/json` broke accented text (4 HTTP checks failed on Delphi 12 Win32 and Win64 before
`TJsonSend` existed). FPC doesn't show the problem, which is why it's easy to miss.

To build JSON, use pascal-jsonmapper-faa's `TJsonWriter` (it escapes for you), or the mapper for
a DTO (step 5). The sample's helper:

```pascal
function JsonMember(const AName, AValue: string): string;
var
  LWriter: TJsonWriter;
begin
  LWriter := TJsonWriter.Create;
  try
    LWriter.BeginObject;
    LWriter.Name(AName);
    LWriter.WriteString(AValue);
    LWriter.EndObject;
    Result := LWriter.ToString;
  finally
    LWriter.Free;
  end;
end;
```

### 4. Report errors by raising

A handler doesn't write error responses. It raises, and the error handler answers
`{"error": "<message>"}` with the status that fits:

```pascal
TErrorHandlerMiddleware.Register(GCallbacks.LogError);   // any time before Listen

procedure GetCity(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  TJsonSend.Send(ARes, CityJson(StrToIntDef(AReq.Params['id'], 0)));
  // CityJson raises ENotFoundException.Create(Format('City %d not found.', [AId]))
end;
```

The error handler isn't in the middleware chain (it is Horse's `THorse.OnError`), so where you
call `Register` doesn't matter, as long as it is before `Listen`. Its optional argument receives
a log line for the errors worth looking at (500, 503, 422, lock conflicts), not for client
errors like 404.

What sample 01 answers, each line checked by `tools/http_scenarios.sh`:

| The handler raises | Status | Body |
|---|---|---|
| `ENotFoundException.Create('City 99 not found.')` | 404 | `{"error":"City 99 not found."}` |
| `EValidationException.Create('"name" is required.')` | 400 | `{"error":"\"name\" is required."}` |
| a malformed body (`{"name":`) | 400 | `Invalid request body: ...` |
| a JSON member of the wrong type (`"population":"many"`) | 400 | names the member, `$.population` |
| `EDatabaseUnavailableException.Create(LDriverError)` | 503 | a fixed message and the `requestId`, without the driver's text |
| any other exception (`EInvalidOpException.Create('something broke')`) | 500 | `{"error":"An unexpected error occurred.","requestId":"<id>"}` |

**Errors that go to the log carry an id in the body.** For a 500, a 503, a 422 or a lock
conflict, the client gets a fixed message and a `requestId`. The exception's own message,
which may name a file, a host or a table, goes to the log only, in a line that ends with the
same id:

```
HTTP/1.1 500
X-Request-Id: 4bf92f3577b34da6a3ce929d0e0e4736

{"error":"An unexpected error occurred.","requestId":"4bf92f3577b34da6a3ce929d0e0e4736"}
```

```
ERROR GET /fail/server -> 500: EInvalidOpException: something broke trace_id=4bf92f3577b34da6a3ce929d0e0e4736
```

When a user reports a failure, ask for the `requestId` your frontend shows, and search the log
for `trace_id=<it>` (checked: the scenario finds the 500's message in the sample's log by the id
the client got). The id is also the `X-Request-Id` header and the request's trace id, so it
finds the access line and the spans too. It needs `TLoggerMiddleware`, which sets the id; without
it neither the body nor the log line has an id, and an `X-Request-Id` the client sent is never
copied into them (measured on FPC/Windows with a program without the logger, 2026-10-14; the
scenarios always run with it). Client errors (400, 404, 409 from a unique key) are expected
outcomes: they aren't logged and carry no id.

Until 0.13.0 the 500 sent the exception's message to the client.

The messages come from `TApiMessages` (English by default, `TApiMessages.Portuguese` available;
the 500's is `InternalError`). The full list will be in the Errors and validation guide
(planned; until then, `MapException` in `PascalApi.Http`).

### 5. Read a request body into a DTO

DTOs are classes whose JSON members are their **published** properties, under `{$M+}`, behind
an interface. From `samples/01-api/ApiSample.Cities.pas`:

```pascal
type
  ICityInsert = interface(IInsertDTOBase)
    ['{FD6E7D51-6C63-4083-A65E-50DDB992FE61}']   // generate your own GUID
    function GetName: string;
    function GetState: string;
    function GetPopulation: IOptInteger;
  end;

{$M+}
  TCityInsert = class(TInsertDTOBase, ICityInsert)
  private
    FName: string;
    FState: string;
    FPopulation: IOptInteger;
  public
    function GetName: string;
    function GetState: string;
    function GetPopulation: IOptInteger;
  published
    property Name: string read FName write FName;
    property State: string read FState write FState;
    property Population: IOptInteger read FPopulation write FPopulation;
  end;
{$M-}

initialization
  TJsonMapper.Shared.RegisterMapping<ICityInsert, TCityInsert>;
```

The handler asks the mapper for the interface, validates, and raises when something is wrong:

```pascal
procedure PostCity(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  TJsonSend.Send(ARes, AddCity(TJsonMapper.Shared.FromJson<ICityInsert>(AReq.Body)), 201);
end;

function AddCity(const ACity: ICityInsert): string;
begin
  if Trim(ACity.GetName) = '' then
    raise EValidationException.Create('"name" is required.');
  if Length(ACity.GetState) <> 2 then
    raise EValidationException.Create('"state" must have 2 letters.');
  ...
end;
```

`IOptInteger` (pascal-common-faa) is a value that may be absent: `{"name":"Natal","state":"rn"}`
creates a city whose `population` is `null` (checked). Use it for every member a client may
leave out, instead of a magic `0`.

Why published and not public: FPC 3.2.2's RTTI sees only published properties, and has no
custom attributes. This is the main difference from delphi-api-infra-faa.

### 6. A paged, ordered list

`GET /cities?page=1&limit=2&orderBy=-name`:

```pascal
procedure GetCities(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LPage: TPageRequest;
  LTotal: Int64;
  LItems: string;
begin
  // page 1 and limit 2 when absent; a limit over 10 becomes 10
  LPage := PageRequestFrom(ParseQueryInt(AReq.Query['page']), ParseQueryInt(AReq.Query['limit']), 2, 10);
  LItems := CityPageJson(AReq.Query['orderBy'], LPage, LTotal);
  TJsonSend.Send(ARes, PageEnvelopeJson(TPageMeta.Create(LPage, LTotal), LItems));
end;
```

The client's `orderBy` goes through an allow-list, so it can never inject SQL:

```pascal
function OrderSpec: TOrderBySpec;
begin
  Result := TOrderBySpec.New
    .Allow('name', 'NAME')       // client name -> column
    .Allow('state', 'STATE')
    .Default('name')
    .AlwaysLast('ID');           // a tiebreaker, so pages don't overlap
end;

LOrder := OrderSpec.Build(AOrderBy);   // 'NAME DESC, ID' for '-name'; raises -> 400
```

The answer is one object, the page's numbers and then the items:
`{"page":1,"limit":2,"total":5,"totalPages":3,"hasNext":true,"hasPrev":false,"items":[...]}`, and
`orderBy=population` answers 400 `Invalid order field: "population"` (both checked). Sample 01
sorts in memory; with a database the same `TOrderBySpec.Build` goes into the SQL, which the
Database access guide (planned; until then `samples/02-db`) covers.

### 7. Add the middlewares, in order

Sample 01's startup, shortened:

```pascal
GSecret := TAppConfig.Get('JWT_SECRET', 'development-secret-change-me');

TErrorHandlerMiddleware.Register(GCallbacks.LogError);
THorse.Use(TLoggerMiddleware.New);
THorse.Use(TMetricsMiddleware.New);
THorse.Use(TCorsMiddleware.New('https://app.example.com'));
THorse.Use(TJwtMiddleware.New(GSecret, ['/health', '/metrics', '/auth/login', '/swagger']));

GRateLimit := TRateLimitOptions.Default;
GRateLimit.Limit := 3;
GRateLimit.WindowSeconds := 60;
GRateLimit.KeyExtractor := GCallbacks.ClientKey;
THorse.Use('/limited', TRateLimitMiddleware.New(GRateLimit));   // one path only

THorse.Get('/cities', GetCities);
...
THorse.Listen(GPort);
```

Horse runs global middlewares in the order of the `THorse.Use` calls. Why this order:

| Position | Why | Checked by |
|---|---|---|
| logger first | it times the whole request and sets `X-Request-Id`, which the others and the handler read | the handler sees the trace id (`GET /trace`) |
| CORS before JWT | a browser's preflight (`OPTIONS`) carries no token | preflight answered 204 with the CORS headers, no token |
| JWT, with the public paths excluded | login, health and metrics must work without a token | 401 without a token; `/auth/login` and `/health` open; `/auth/login-admin` is **not** excluded by `/auth/login` (whole segments) |
| the rate limit on a path | `THorse.Use('/limited', ...)` limits only that path | `/cities/1` still 200 when `/limited` answers 429 |

`TAppConfig.Get('JWT_SECRET', default)` reads the environment first, then a `.env` file in the
executable's folder, then the default. The development default is for the sample: give the real secret through the
environment in production. More in the Configuration guide (planned; until then
`PascalApi.Config`).

The login route signs a token with `TJwt.SignHS256(LClaims, GSecret)`, and a handler reads the
verified claims with `TJwtMiddleware.Claims(AReq)` (the caller frees the result). Both are in
sample 01 (`PostLogin`, `GetMe`); the Authentication guide (planned) covers them.

### 8. Callbacks are methods

Some middlewares take a function from you: the rate limit's key, the error handler's log
procedure, a health check. On Delphi these are `reference to` types; on FPC 3.2.2 they are
`of object`, because FPC 3.2.2 has no anonymous methods. A method of an object works on both,
so the samples put them in a small class:

```pascal
type
  TSampleCallbacks = class
  public
    function ClientKey(AReq: THorseRequest): string;
    procedure LogError(const ALine: string);
  end;

function TSampleCallbacks.ClientKey(AReq: THorseRequest): string;
begin
  Result := AReq.Headers['X-Client'];
  if Result = '' then
    Result := 'anonymous';
end;

procedure TSampleCallbacks.LogError(const ALine: string);
begin
  Writeln('ERROR ', ALine);
end;
```

Create the object before registering the middlewares and free it after `Listen` returns. Don't
write `function(...) begin ... end` inline: it compiles on Delphi only.

### 9. Run the samples

The three samples are complete programs to start from:

| Sample | Start it | Check it |
|---|---|---|
| `samples/01-api`: every middleware, in memory | `ApiSample 9310` | `sh tools/http_scenarios.sh 9310` |
| `samples/02-db`: SQLite through pascal-db-faa | `DbApiSample 9330 --reset` | `sh tools/http_scenarios_db.sh 9330` |
| `samples/03-tenants`: multi-tenancy | `TenantApiSample 9350 --reset` | `sh tools/http_scenarios_tenants.sh 9350` |

Build them in the Delphi IDE (`PascalApi.groupproj`) or with Lazarus (`.lpi`). On FPC for
Windows, samples 02 and 03 need sqlite.org's `sqlite3.dll` next to the executable.
`sh tools/test_http.sh` builds all three with lazbuild, starts them and runs the checks.

## Choices

### Which sample to copy

- **01-api** when you are learning the middlewares, or your data isn't in a database yet.
- **02-db** for a database API: migrations, paging and ordering in SQL, 409 from a unique key.
- **03-tenants** when one API serves several customers ([guide](multitenancy.md)).

### A global middleware or one on a path

`THorse.Use(M)` runs `M` for every request. `THorse.Use('/reports', M)` runs it only for that
path and below. Sample 01 uses the second form for its rate limit. But the middlewares keep one
configuration per process (next section), so you can't have two different rate limits on two
paths.

## Pitfalls

- **`Res.Send(string)` for JSON.** Accented text breaks on Delphi only (step 3). Use
  `TJsonSend.Send`.
- **One configuration per middleware, per process.** On FPC a Horse callback is a plain
  procedure, so each middleware keeps its settings in a unit variable: calling `New` again
  replaces the settings everywhere the middleware is used. Configure everything once, before
  `Listen`. This is by design (the unit's header), the same on both compilers.
- **No `TLoggerMiddleware`, no id.** Without the logger, a 500's body and log line have no
  `requestId`, and support can't match a user's report to the log (step 4).
- **A message meant for the user, raised as a plain `Exception`.** It becomes the fixed 500
  message. Raise `EValidationException` (400), `ENotFoundException` (404) or another
  `EHttpException` when the client should read your text.
- **Horse 3.3.2 on FPC for Windows doesn't compile**
  (`No matching implementation for interface method Equals(constref ...)`). Use 3.3.3 or later;
  the samples use 3.3.12.
- **A route that doesn't exist answers Horse's own `Not Found`**, as `text/html`, not JSON.
  Measured with the smallest program on FPC/Windows (2026-10-14); sample 01's checks see only
  the 404 status. Horse also runs the global middlewares twice for such a request; the logger
  writes one line anyway (checked: one `X-Request-Id`), but a middleware of your own with side
  effects would run twice.
- **The middlewares aren't in the Lazarus package.** "Can't find unit
  PascalApi.Horse.Middlewares" on Lazarus means `src/horse` is missing from the project's paths
  (step 1).
- **Two copies of a library.** Each `*-faa` library must come from one folder in your project.
  Pointing the search path at a copy inside another library's `external/` mixes versions.
- **Text sent from curl on Windows.** Git Bash hands `curl.exe` its arguments in the ANSI code
  page, so `--data-binary '{"name":"Maceió"}'` arrives as invalid UTF-8. That is the test tool,
  not your server: put the body in a file with explicit UTF-8 bytes
  (`printf '{"name":"Macei\303\263"}' > body.json`, then `--data-binary @body.json`).

## Testing your application

Test the behaviour over HTTP, against the running program. On FPC, Horse's `Listen` blocks
and has no `StopListen`, so the library's own checks don't start a server inside a test runner:
they start the sample as a process and run a shell script with curl. `tools/http_scenarios.sh`
is the model: a small `req` function, then one line per check:

```sh
req GET /cities/99 "" -H "$AUTH"
status_is 404 "city 99"
body_is '{"error":"City 99 not found."}' "city 99"
```

Run the same script against the Delphi build and the FPC build: the bugs that show on one
compiler only (the JSON encoding of step 3, for example) were found this way, not by unit tests.

Keep the logic that doesn't need HTTP (validation, mapping, ordering) in plain units, and test
it with DUnitX on Delphi and FPCUnit on FPC. The library's acceptance is 0 failures and 0 leaks
on both (FastMM, heaptrc); see the `dual-compiler-delphi-lazarus` skill for mirrored tests.

## Reference

- `samples/01-api`: `ApiSample.dpr` (the program, the middleware order), `ApiSample.Cities.pas`
  (the DTO, ordering, paging).
- `tools/http_scenarios.sh`: the 149 checks against sample 01.
- `PascalApi.Horse.Middlewares` (`src/horse`): the comment at the top of the unit and each
  middleware's declaration.
- `PascalApi.Http`: `MapException` (exception → status and message), `TApiMessages`.
- [README](../../README.md): the list of units, and "A quick look".
- [CLAUDE.md](../../CLAUDE.md), section "Horse": the measured Horse and compiler differences
  behind the pitfalls above.
- The other guides: [index](README.md).
