# Errors and validation

What a client gets when a request fails, and how a handler makes it happen: by raising an
exception. The code comes from `samples/01-api` and `samples/02-db`. `PascalApi.HttpTests`
covers the mapping from exception to status and message, and `tools/http_scenarios.sh` and
`tools/http_scenarios_db.sh` check the answers over HTTP. A few behaviours below were measured
with a probe program on FPC 3.2.2/Windows for this guide (2026-10-14), and each one says so.
None of those were measured on Delphi.

## What it solves

An API fails in many ways: a field is missing, a record doesn't exist, two requests insert the
same key, the database is down, the code has a bug. The client needs a status it can act on and
a message it can show. The people running the API need the details, but those must not reach
the client: an exception's own message can name a file, a host, a table or a user.

The library answers every failure the same way: a status and `{"error": "<message>"}`. A handler
never writes an error response itself; it raises, and the error handler picks the status and
the message from the exception's class. Errors that point to a problem on the server get a
fixed message, a `requestId` the user can quote, and a line in your log with the details.

## The smallest working program

```pascal
uses
  SysUtils, Horse, PascalApi.Http, PascalApi.Horse.Middlewares;

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
  TErrorHandlerMiddleware.Register;    // exceptions -> status + {"error": ...}
  THorse.Use(TLoggerMiddleware.New);   // first: the request id, and middleware errors
  THorse.Get('/cities/:id', GetCity);
  THorse.Listen(9000);
end.
```

```
GET /cities/7    404  {"error":"City 7 not found."}
```

This is the program from [Getting started](getting-started.md), whose step 4 introduces errors.
This guide covers the rest.

## Step by step

### 1. Raise; don't answer

A handler reports a failure by raising one of the library's exceptions (`PascalApi.Http`). The
error handler, registered with `TErrorHandlerMiddleware.Register`, answers it:

| Raise | Status | The client gets |
|---|---|---|
| `EValidationException.Create(AMessage)` | 400 | your message |
| `ENotFoundException.Create` | 404 | `TApiMessages.NotFound` ("Resource not found.") |
| `ENotFoundException.Create(AMessage)` | 404 | your message |
| `EConflictException.Create(AMessage)` | 409 | your message |
| `EHttpException.Create(AStatus, AMessage)` | `AStatus` | your message |

All five are client errors: expected outcomes, not logged, with no `requestId` (tested:
`HttpExceptions_KeepStatusAndMessage`, `NotFound_DefaultMessage`; `EHttpException.Create(418,
...)` keeps its 418, and the probe answered `EHttpException.Create(422, 'Value out of range.')`
with a 422 and that body).

From `samples/01-api/ApiSample.Cities.pas`:

```pascal
function CityJson(AId: Integer): string;
...
  raise ENotFoundException.Create(Format('City %d not found.', [AId]));
end;
```

**Your message goes to the client as it is.** Write it for the client, and never put an internal
detail in it (a SQL text, a file path): the library only hides the messages of exceptions it
doesn't know (step 4).

### 2. Validate the input

A request is checked in three places, and each one has its own error:

**The JSON itself**, when the body becomes a DTO
(`TJsonMapper.Shared.FromJson<ICityInsert>(AReq.Body)`, see [Getting started](getting-started.md),
step 5). The error handler turns the mapper's exceptions into 400:

| Body | Status | Message (checked over HTTP) |
|---|---|---|
| `{"name":` (malformed) | 400 | `Invalid request body: ...` with the parser's message and position |
| `{"population":"many"}` (a string for a number) | 400 | names the member: `...$.population...` |

A mapper error *without* a JSON path (`Interface ICity has no mapping`) is a programming error,
a DTO you forgot to register, and stays a 500 (tested: `JsonMapperErrorWithoutPath_Is500`).

**The rules of the data**, in the handler or the repository, with `EValidationException`. From
`samples/02-db/DbApiSample.Cities.pas`:

```pascal
LCode := Trim(ACity.GetCode);
if not IsDigits(LCode, 7) then
  raise EValidationException.Create('"code" must be the 7-digit IBGE code.');
if Trim(ACity.GetName) = '' then
  raise EValidationException.Create('"name" is required.');
if PaCharCount(Trim(ACity.GetName)) > 100 then
  raise EValidationException.Create('"name" must have at most 100 characters.');
if Length(Trim(ACity.GetState)) <> 2 then
  raise EValidationException.Create('"state" must have 2 letters.');
if ACity.GetPopulation.HasValue and (ACity.GetPopulation.Value < 0) then
  raise EValidationException.Create('"population" can''t be negative.');
```

These are the limits the sample's OpenAPI document declares: the document describes them, and
only this code enforces them ([OpenAPI](openapi.md), step 5, with what each broken limit did
before the sample checked it).

The mapper doesn't know which members are required: "required" is a check you write, like the
ones above. An optional member left out arrives without a value (checked: sample 01 creates a
city without `population`, and it answers `"population":null`); a string member left out wasn't
checked over HTTP, so test for `''` as the samples do.

**The database's constraints**, the last line: a rule that two requests could break at the same
time (a unique code) is only safe in the database. pascal-db-faa classifies the driver's error,
and the error handler answers it:

```pascal
LQuery.ExecSql; // EConstraintViolationException (cvUnique) -> 409
```

```
POST /cities {"code":"3550308",...}   409  {"error":"A record with these values already exists."}
```

(checked by `tools/http_scenarios_db.sh`: "duplicate code").

### 3. What the database's errors become

| pascal-db-faa raises | Status | Message (`TApiMessages`) | Logged |
|---|---|---|---|
| `EConstraintViolationException`, unique | 409 | `ConstraintUnique` | no |
| `EConstraintViolationException`, foreign key | 409 | `ConstraintForeignKey` | no |
| `EConstraintViolationException`, NOT NULL | 422 | `ConstraintNotNull` | yes |
| `EConstraintViolationException`, CHECK | 422 | `ConstraintCheck` | yes |
| `ELockConflictException` (lock, deadlock, changed row) | 409 | `LockConflict` | yes |
| `EDatabaseUnavailableException` | 503 | `DatabaseUnavailable` | yes |
| `EPoolTimeoutException` (every pooled connection busy for the whole wait) | 503 | `ServerBusy` | yes |

All tested in `PascalApi.HttpTests` (`Constraint...`, `LockConflict_Is409_Logged`,
`DatabaseUnavailable_Is503_DetailOnlyInLog`, `PoolTimeout_Is503_Logged`); both 503s are also
checked over HTTP (sample 01, `/fail/database` and `/fail/busy`), and so is the unique key
(sample 02). Until 0.13.0 a pool timeout was a 500. See [Database access](database.md).

The messages are fixed: the driver's text never reaches the client. Why the split: a duplicate
key is the client's data meeting existing data, an expected outcome. A NOT NULL or CHECK error
means your validation let through a value the table refuses: a bug worth seeing in the log,
even though the client gets a 4xx.

### 4. What the client never sees

Any exception the table above and step 1 don't name (an access violation, a file that can't be
opened, `EInvalidOpException`) is a 500 with a fixed message. The logged errors (500, 503, 422,
lock conflicts) carry a `requestId` in the body, and the log line ends with the same id:

```
HTTP/1.1 500
X-Request-Id: 4bf92f3577b34da6a3ce929d0e0e4736

{"error":"An unexpected error occurred.","requestId":"4bf92f3577b34da6a3ce929d0e0e4736"}
```

```
ERROR GET /fail/server -> 500: EInvalidOpException: something broke trace_id=4bf92f3577b34da6a3ce929d0e0e4736
```

The log line goes to the procedure you pass to `Register`:

```pascal
TErrorHandlerMiddleware.Register(GCallbacks.LogError);   // a method, on FPC (Getting started, step 8)

procedure TSampleCallbacks.LogError(const ALine: string);
begin
  Writeln('ERROR ', ALine);
end;
```

Its form is `<method> <path> -> <status>: <class>: <message>` for a 500, and, for the database's
errors, the library's class followed by the driver's class and message in parentheses
(`POST /cities -> 422: EConstraintViolationException (Exception: NAME cannot be NULL)`, tested).
`tools/http_scenarios.sh` checks that the 500's body has the fixed message and the id, that it
doesn't have the exception's message, and that the sample's log has `something broke
trace_id=<the id>`.

The id comes from `TLoggerMiddleware`. Without it there is no id in the body or the log line,
and an `X-Request-Id` the client sent is never copied into either (see [Getting
started](getting-started.md), step 4).

### 5. Errors raised in a middleware

A middleware can fail too: a token check, a tenant looked up in a database, your own rate-limit
key function. `TLoggerMiddleware` answers those exceptions exactly as the error handler answers
a handler's: same status, same message, same log line and `requestId`.

This is needed because Horse treats them differently. Horse sends a handler's exception to
`THorse.OnError`, but on FPC its router re-raises a middleware's exception without calling
`OnError`. fpWeb then answered `500 text/html` with an error page holding the exception's message
and the stack addresses, and the access line said 200 (measured with the probe, FPC/Windows,
with both a global and a path middleware). Delphi's router does call `OnError` there (read in
Horse 3.3.12's code, not measured).

So **register `TLoggerMiddleware` first**: only the middlewares after it are covered. Sample 01
has a middleware that raises (`/fail/middleware`), and `tools/http_scenarios.sh` checks the 500
JSON with its `requestId`, a 400 from an `EValidationException` raised there, the log line and
the access line's status. Until this was fixed (after 0.13.0), a `TDbTenantCatalog` whose
database was down would have sent the driver's message to the client this way on FPC (not
measured with the tenant middleware itself; it is the same path).

### 6. The messages, in English or Portuguese

The messages the library writes are in `TApiMessages.Current`, English by default. Choose once,
at startup, before `Listen`:

```pascal
TApiMessages.Current := TApiMessages.Portuguese;
```

```
GET /pt   404  {"error":"Recurso não encontrado."}
```

(tested: `Messages_CanBeReplaced`; over HTTP with the probe.) To change one message, start from
a set and replace the field:

```pascal
var
  LMessages: TApiMessages;
...
LMessages := TApiMessages.Portuguese;
LMessages.NotFound := 'Registro não encontrado.';
TApiMessages.Current := LMessages;
```

| Field | English | Used for |
|---|---|---|
| `NotFound` | Resource not found. | `ENotFoundException.Create` without a message |
| `InvalidEncoding` | The request text is not valid UTF-8. | 400, a body that isn't UTF-8 |
| `InvalidJson` | Invalid request body: %s | 400, the parser's or mapper's message in `%s` |
| `DatabaseUnavailable` | The database is unavailable. Try again shortly. | 503 |
| `LockConflict` | The record is locked or was changed by another operation. Try again. | 409 |
| `ConstraintUnique` | A record with these values already exists. | 409 |
| `ConstraintForeignKey` | The record refers to data that does not exist, or other data refers to it. | 409 |
| `ConstraintNotNull` | A required field is missing. | 422 |
| `ConstraintCheck` | A value is outside the accepted rules. | 422 |
| `TokenMissing`, `TokenBadFormat`, `TokenInvalid` | | 401, authentication (`TAuthMiddleware`, `TJwtMiddleware`) |
| `RateLimited` | Rate limit exceeded. Try again in %d second(s). | 429 (`%d`: seconds) |
| `TenantMissing`, `TenantUnknown`, `TenantSuspended` | | multi-tenancy, see [Multi-tenancy](multitenancy.md) |
| `ServerBusy` | The server is busy. Try again shortly. | 503, no free database connection in time |
| `InvalidQueryInteger` | "%s" must be an integer. | 400, from `ParseQueryInt` (`%s` is the parameter) |
| `InternalError` | An unexpected error occurred. | 500 |

A field with `%s` or `%d` goes through `Format`: keep the placeholder when you replace it.

Your own messages (`EValidationException.Create('"name" is required.')`) are yours: the library
doesn't translate them.

## Choices

### 400 or 422 for invalid data

The library uses 400 for everything the client sent wrong, including business rules
(`EValidationException`), and keeps 422 for the database's NOT NULL and CHECK errors, which mean
a validation is missing on the server. If your clients expect 422 for invalid fields, raise
`EHttpException.Create(422, AMessage)`: it isn't logged, like any `EHttpException`.

### Your own exception classes

Derive from `EHttpException` to give an error of your domain a name and a status:

```pascal
type
  EPaymentRequired = class(EHttpException)
  public
    constructor Create(const AMessage: string);
  end;

constructor EPaymentRequired.Create(const AMessage: string);
begin
  inherited Create(402, AMessage);
end;
```

The error handler only looks at `EHttpException` and its status; a subclass works with no
registration. Any other exception class is a 500.

### English or Portuguese

One language per process. The messages are chosen at startup, not per request: there is no
`Accept-Language` support. An API with clients in both languages would send a code the client
translates, which the library doesn't have today.

## Pitfalls

- **No `TErrorHandlerMiddleware.Register`.** Horse answers every handler exception itself:
  `500 text/html` with `Internal Application Error: <the exception's message>`, even for an
  `ENotFoundException` (measured with the probe, FPC/Windows: a 404 and a 422 both became 500,
  and a 500's message reached the client).
- **Raising Horse's `EHorseException`.** Horse answers it before the error handler sees it: its
  own JSON (`{ "error" : "..." }`), no `requestId`, no log line, no `TApiMessages` (measured with
  the probe). Horse's typed readers raise it too:
  `AReq.Query.Field('n').AsInteger` with `n=abc` answered `400 {"error":"The n param 'abc' is not
  valid a integer type."}`, in English only. Read the text and convert it yourself:
  `ParseQueryInt('n', AReq.Query['n'])` (`PascalApi.Pagination`) gives an absent value for an
  empty one and a 400 naming the parameter for anything but digits (`"n" must be an integer.`,
  in `TApiMessages`; tested, and checked over HTTP by both samples' scenarios).
- **A middleware before `TLoggerMiddleware`.** Its exceptions aren't covered (step 5). Keep the
  logger first.
- **An id that isn't a number.** Sample 01 reads `/cities/:id` with `StrToIntDef(..., 0)`, so
  `/cities/abc` looks for city 0 and answers 404. That's a choice of the sample; raise
  `EValidationException` if a malformed id should be a 400.
- **Counting characters on FPC.** `Length` counts bytes on FPC and UTF-16 units on Delphi, so a
  rule like `Length(State) <> 2` refuses a two-letter value with an accented letter on FPC only.
  Count with `PaCharCount` (`PascalApi.Text`, tested), as the samples do for a name's 100
  characters; their `Length` rules are on ASCII values.
- **A body that isn't UTF-8.** On Delphi, Horse decodes the body as UTF-8 and raises on invalid
  bytes, which becomes `400 InvalidEncoding`; on FPC the bytes are kept and no error is raised
  (from the comment in `MapException`; the scenario only checks that such a body is not a 500).
- **An unknown route** is answered by Horse, before any handler: `404 text/html` `Not Found`, not
  JSON (measured with the [Getting started](getting-started.md) program).

## Testing your application

Test the mapping of your own exceptions without a server, with `MapException`:

```pascal
R := MapException(EValidationException.Create('name is required'), 'POST', '/cities');
TAssert.AssertEquals(400, R.Status);
TAssert.AssertEquals('name is required', R.Message);
TAssert.AssertEquals('', R.LogLine);   // a client error isn't logged
```

`LogLine` is what your log procedure would get (without the `trace_id`, which the error handler
adds). A test that changes `TApiMessages.Current` puts `TApiMessages.English` back in its
teardown, as `PascalApi.HttpTests` does.

Over HTTP, check the status and the whole body for each error your API documents, and that a
500's body lacks the exception's message. From `tools/http_scenarios.sh`:

```sh
req GET /fail/server "" -H "$AUTH"
status_is 500 "server error"
FAIL_ID="$(header X-Request-Id)"
body_is "{\"error\":\"An unexpected error occurred.\",\"requestId\":\"$FAIL_ID\"}" "server error"
body_lacks 'something broke' "server error: the exception's message stays in the log"
```

and, with the server's output in a file, that the log line has the id the client got:

```sh
grep -q "something broke trace_id=$FAIL_ID" "$SERVER_LOG" && ok || fail "log: the 500"
```

## Reference

- `PascalApi.Http`: the exceptions, `TApiMessages`, `MapException`, `ErrorJson`, and the comment
  at the top of the unit (what changed from delphi-api-infra-faa).
- `PascalApi.Horse.Middlewares`: `TErrorHandlerMiddleware`, `TLoggerMiddleware` (middleware
  errors).
- `PascalApi.HttpTests` (`TErrorMappingTests`): every row of the tables above.
- `samples/01-api`: `/fail/server`, `/fail/database`, `/fail/middleware`, validation in
  `ApiSample.Cities.pas`; `tools/http_scenarios.sh`.
- `samples/02-db`: validation and the unique key in `DbApiSample.Cities.pas`;
  `tools/http_scenarios_db.sh`.
- pascal-db-faa: the classification of the drivers' errors (`EConstraintViolationException`,
  `ELockConflictException`, `EDatabaseUnavailableException`).
