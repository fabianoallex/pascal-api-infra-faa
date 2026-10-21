# DTOs and JSON

How JSON comes in and goes out of an API built on this library: request and response DTOs,
values that may be absent or null, the query string, the database, and the same DTOs on a queue
(pascal-amqp-faa) or between two processes (pascal-pipes-faa). The mapper is
[pascal-jsonmapper-faa](https://github.com/fabianoallex/pascal-jsonmapper-faa); the optional
types are pascal-common-faa's (`PascalCommon.Optionals`, and the bridge
`PascalCommon.JsonMapper.Optionals`).

**Where the code comes from.** Samples 01 and 02 (request DTOs, the PATCH, the query string),
checked over HTTP by `tools/http_scenarios.sh` and `tools/http_scenarios_db.sh` on every build;
and sample 04 (`MessagingSample.lpr`, `PipesJsonSample.lpr`), built by hand and run on
FPC 3.2.2/Windows on 2026-10-15. The behaviour of the mapper itself is backed by its own suite
(99 tests on both compilers; the test names are given where a claim rests on one). The table of
malformed bodies in step 2 was measured on FPC; the rows marked "checked" run on every build.

## What it solves

A request body has to become typed values, and a client can send anything: a missing member, a
`null`, a string where a number goes, a member the API doesn't know, a typo, a body that isn't
JSON. A response must be valid UTF-8 JSON, the same on Delphi and FPC. And the same DTO often
travels further: to the database, to a queue, to another process. The library gives one mapper
for all of it, DTOs mapped from **published** properties (the only ones FPC 3.2.2's RTTI sees),
and three optional types that say, member by member, whether absent and null are allowed.

## The smallest working program

From `samples/01-api` (`ApiSample.Cities.pas` and `ApiSample.dpr`, shortened):

```pascal
type
  ICityInsert = interface(IInsertDTOBase)
    ['{FD6E7D51-6C63-4083-A65E-50DDB992FE61}']   // generate your own GUID
    function GetName: string;
    function GetState: string;
    function GetPopulation: IOptInteger;
    property Name: string read GetName;
    property State: string read GetState;
    property Population: IOptInteger read GetPopulation;
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
    function GetPopulation: IOptInteger;   // Result := TOptionals.Safe(FPopulation)
  published
    property Name: string read FName write FName;
    property State: string read FState write FState;
    property Population: IOptInteger read FPopulation write FPopulation;
  end;
{$M-}

initialization
  TJsonMapper.Shared.RegisterMapping<ICityInsert, TCityInsert>;

// the program: once, at startup
uses PascalCommon.JsonMapper.Optionals;      // registers the optional types' converter
TJsonMapper.Shared.UnknownMembers := umError;

procedure PostCity(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  TJsonSend.Send(ARes, AddCity(TJsonMapper.Shared.FromJson<ICityInsert>(AReq.Body)), 201);
end;
```

`{"name":"Natal","state":"rn"}` creates a city whose population is `null`; `"population":"many"`
is a 400 naming `$.population`; `"popultion":5` is a 400 naming `$.popultion` (all checked).

## Step by step

### 1. Declare a DTO

- **An interface for the callers, a class for the mapper.** The handler asks for `ICityInsert`;
  `RegisterMapping<I, C>` tells the mapper which class to create. The class's own constructor
  runs. Register in the `initialization` of the unit that declares the DTO.
- **The interface mirrors the class, read-only.** Each published property of the class has a
  property of the same name and type in the interface, read through its getter
  (`property Name: string read GetName;`), so whoever holds only the interface sees every member
  (`ACity.Name`) and can't change it. The mapper reads the class, never the interface, so the
  mirror changes nothing on the wire or in the OpenAPI document (probe 2026-10-19: same members,
  same JSON). The bases' `Page`, `Limit`, `OrderBy`, `Search` and `Total` are read-only too since
  0.18.0.
- **Fill a DTO through its class, while an interface variable holds it.** The reference count
  lives in the interface: an object kept only in a class variable is freed by the first interface
  that lets it go, and the class variable is left pointing at freed memory.

  ```pascal
  LCity := TCity.Create;
  Result := LCity;                        // the interface holds it (Result: ICity)
  LCity.Name := AResult.Strings['NAME'];  // edited through the class
  ```

- **Code that receives the interface treats the DTO as a value.** A different value goes into a
  local variable or a new DTO (sample 01's `AddCity` builds the stored city from the
  `ICityInsert` it got), never into the one received, and never through
  `(ACity as TObject) as TCityInsert`: the caller may still use it, and a mock wouldn't be that
  class.
- **Published properties under `{$M+}`**, the members the JSON has. Public properties are
  ignored on both compilers (FPC 3.2.2's RTTI doesn't see them, so Delphi ignores them too;
  mapper test `PublicProperty_IsIgnored`). Read-only properties are written, never read
  (`ReadOnlyProperty_IsIgnored`).
- **The bases in `PascalApi.Dto`** (`TInsertDTOBase`, `TUpdateDTOBase`, `TResponseDTOBase`,
  `TFindPaginationDTOBase`, `TResponsePaginationDTOBase`) are markers with no members, except the
  two paging ones. They add nothing to the JSON; they say what a DTO is for.
- **A GUID per interface**, generated, never typed.
- **Getters of optional members return `TOptionals.Safe(FField)`**: an absent member leaves the
  field `nil`, and `Safe` turns `nil` into the type's Undefined (or Null for `INullXxx`), so callers
  test `HasValue`/`IsNull` and never `Assigned`.

### 2. Read a request body

`THorseBody.Read<I>(AReq)` (0.20.0) reads the body as the DTO and enforces what
`TApiSchema.Describe` declares for it (lengths, `Enum`, `Minimum`, `Maximum`): a broken limit is a
400 listing every failing field ([Errors](errors.md), step 2). Under it is
`TJsonMapper.Shared.FromJson<I>(AReq.Body)`, which the rest of this step is about. The error handler turns what the parser and the
mapper raise into a 400 with the reason (`TApiMessages.InvalidJson`); nothing to catch in the
handler. Measured against sample 01 on FPC:

| Body sent to `POST /cities` | Answer |
|---|---|
| `{"name":"Natal","state":"RN","population":"abc"}` | 400 `$.population: expected integer, found JSON string` (checked) |
| `"population":1.5` / `true` | 400 `expected integer, found JSON number` / `boolean` |
| `"population":99999999999` | 400 `$.population: 99999999999 is out of range (-2147483648..2147483647)` (mapper test `Error_NumberOutOfRange_HasPath`) |
| `"name":123` | 400 `$.name: expected string, found JSON number` |
| `"popultion":10` (a typo) | 400 `$.popultion: unknown member` with `umError` (checked); **201 and population `null`** without it |
| `{"NAME":"Natal","STATE":"RN"}` | 201: names are read case-insensitively (`Names_AreCaseInsensitive_UnknownIgnored`) |
| `{"name":"First","name":"Second",...}` | 400 `$.name: duplicate member ("name" and "name")` (checked; pascal-jsonmapper-faa 0.4.0) |
| `{"NAME":"First","name":"Second",...}` | 400: names that differ only in (ASCII) case are the same member (checked) |
| `{"name":"Natal",` / `` (empty) | 400 `Member name expected (at position 17)` / `Value expected (at position 1)` (checked) |
| `[1,2]` / `"x"` / `null` | 400 `$: expected object, found JSON array` / `string` / `null` |
| `{...} xyz` | 400 `Unexpected content after the JSON value` |
| comments, single quotes, `NaN`, `010` | 400: strict JSON only |
| `[[[...]]]` 600 levels deep | 400 `Maximum nesting depth exceeded`; the process answers on (512 levels; `Parse_DeepNesting_Raises`) |
| `"Jo\u00e3o \ud83d\ude00"` | 201, stored and answered as UTF-8 `João 😀` (sample 02 checks the `\u00e3`) |
| a lone `\ud83d` | 201 with U+FFFD in its place (`Parse_LoneSurrogate_BecomesReplacementChar`) |
| `"a\u0000b"` | 201, written back as `"a\u0000b"` |
| a body of 50 MB | **201** after 1.4 s; the process grew from 11 MB to 60 MB (step 10) |

**Turn on `UnknownMembers := umError`.** Without it, a misspelled member is dropped in silence:
the client thinks it set `popultion` and gets a city with no population. With it, the body is
rejected before anything is assigned (`Strict_RejectedBody_ChangesNothing`). The samples set it
at startup since this guide; a client that sends extra members on purpose (a newer client against
an older API) then gets 400s, which is the trade.

**`null` into a plain scalar keeps the value it had** (`Null_IntoScalar_KeepsValue`): `"name":null`
into a `string` leaves `''`, which sample 01's own check turns into `"name" is required.` A member
that may be null is an `INullXxx` or `IOptNullXxx` (step 3), never a plain type.

### 3. Absent, null or a value: the three optional types

pascal-common-faa has three flavors of each type (`String`, `Integer`, `Int64`, `Double`,
`Single`, `Currency`, `DateTime`, `Boolean`, `Guid`):

| Type | Absent | `null` | Written when unset |
|---|---|---|---|
| `IOptXxx` | allowed (Undefined) | **400** (`null is not allowed here (optional, not nullable)`, checked) | member omitted |
| `INullXxx` | reads as Null | Null | **`null`**, never omitted |
| `IOptNullXxx` | Undefined | Null | member omitted |

The rule of thumb: `IOptXxx` for what a client may leave out of a request (`population` in a
create), `INullXxx` for what a response always has but may be empty (a `NULL` column),
`IOptNullXxx` for a PATCH, where absent, null and a value mean three different things. The
bridge's table and its two deliberate differences from delphi-api-infra-faa are in
pascal-jsonmapper-faa's `docs/converters.md`.

Sample 02's PATCH (`DbApiSample.Cities.pas`):

```pascal
type
  /// Name and state may not be null (the columns are NOT NULL); population may.
  ICityPatch = interface(IUpdateDTOBase)
    ['{D69D9227-473F-495A-95B3-C505E3E4BB25}']
    function GetName: IOptString;
    function GetState: IOptString;
    function GetPopulation: IOptNullInteger;
    property Name: IOptString read GetName;
    property State: IOptString read GetState;
    property Population: IOptNullInteger read GetPopulation;
  end;

{$M+}
  TCityPatch = class(TUpdateDTOBase, ICityPatch)
  ...
  published
    property Name: IOptString read FName write FName;
    property State: IOptString read FState write FState;
    property Population: IOptNullInteger read FPopulation write FPopulation;
  end;
{$M-}
```

| `PATCH /cities/2408102` | Answer (all checked) |
|---|---|
| `{"population":890480}` | 200, the other members unchanged |
| `{}` | 200, nothing changed (no `UPDATE` is sent) |
| `{"population":null}` | 200, population `null` |
| `{"name":"Natal RN","state":"rn"}` | 200, both changed, population untouched |
| `{"name":null}` | 400 `$.name: null is not allowed here ...` |
| `{"population":-1}` / `{"popultion":1}` | 400: the same limits as the create / unknown member |
| an unknown code | 404 |

### 4. From the DTO to the database, and back

The PATCH's repository method normalizes the members inside their optionals, then turns each
member that came into a block of SQL, so an absent member never reaches the `UPDATE`
(pascal-db-faa's `ProcessTag`, the same as its sample 06):

```pascal
// Normalized inside the optionals, by the rules of DbApiSample.Normalizers:
// an absent member stays absent, so there is no if here.
LName := TOptionals.Normalize(APatch.Name, TNorm.CityName);
LState := TOptionals.Normalize(APatch.State, TNorm.StateCode);
LPopulation := APatch.Population;
// The document's limits (name at most 100, state 2, population >= 0) were
// enforced at the edge by THorseBody.Read; what it can't say is checked here,
// for the members that came: an absent name isn't checked.
LCheck := TPcValidation.Create;
LCheck.Check('name', LName, TValid.Required);
LCheck.RaiseIfAny;

// 'UPDATE CITIES SET CODE = CODE [NAME {], NAME = :NAME [} NAME] ' +
// '[STATE {], STATE = :STATE [} STATE] [POPULATION {], POPULATION = :POPULATION [} POPULATION] ' +
// 'WHERE CODE = :CODE'
LQuery.Sql := FFactory.SqlLoader['CITY.UPDATE']
  .ProcessTag('NAME', LName.HasValue)
  .ProcessTag('STATE', LState.HasValue)
  .ProcessTag('POPULATION', LPopulation.HasValue).SQL;
// No if per member: an absent optional binds nothing (its block is gone),
// a Null binds NULL, a value binds it.
LQuery.Params.Strings['CODE'] := ACode;
LQuery.Params.OptStrings['NAME'] := LName;
LQuery.Params.OptStrings['STATE'] := LState;
LQuery.Params.OptNullIntegers['POPULATION'] := LPopulation;
```

This is what the optional types are for: the DTO's member goes to its parameter as it is, and
the three states need no `if`. The normalizers keep the state (Undefined stays Undefined, Null
stays Null, only a value changes), and they work wherever the value goes: a parameter, a
message, a response. The checks don't open the optionals either: `TPcValidation.Check` has an
overload per shape of member and checks an optional only when it holds a value
(`PascalCommon.Validators`, 1.21.0). Sample 02's scenario sends `"  Natal   RN  "` and `"rn"`
and gets `"Natal RN"` and `"RN"` back (`" rn"` would break the document's `MaxLength(2)` at the
edge).

The rules have a name and live in one unit, `DbApiSample.Normalizers`: a factory that inherits
pascal-common-faa's `TPcStringNormalizers` (unit `PascalCommon.Normalizers`, 1.14.0), so typing
`TNorm.` lists the sample's rules next to the library's `Trim`, `Upper`, `Lower`, `FromFunc` and
`Chain`:

```pascal
type
  TNorm = class(TPcStringNormalizers)
  public
    class function CollapseSpaces: IPcStringNormalizer; static;
    class function CityName: IPcStringNormalizer; static;
    class function StateCode: IPcStringNormalizer; static;
  end;

implementation

function CollapseSpacesOf(const AValue: string): string; // a plain function
...

class function TNorm.CollapseSpaces: IPcStringNormalizer;
begin
  Result := FromFunc(CollapseSpacesOf);
end;

class function TNorm.CityName: IPcStringNormalizer;
begin
  Result := Chain([Trim, CollapseSpaces]); // applied in order, as one
end;

class function TNorm.StateCode: IPcStringNormalizer;
begin
  Result := Chain([Trim, Upper]);
end;
```

- A normalizer changes the value, never the state. To turn `''` into Null or Undefined, call
  `NullIfEmpty` or `UndefinedIfEmpty` after it: `TOptionals.Safe(LDto.Nickname).Trim.NullIfEmpty`.
- The same operations are chainable methods (`X.Trim.Upper`, `X.Normalize(N)`, `X.Map(F)`). A
  method can't be called on `nil`: start with `TOptionals.Safe(X)`, or use the `TOptionals`
  form, which reads `nil` as Undefined (the sample's form).
- A rule with a parameter (a maximum length) is a class implementing `IPcStringNormalizer`; the
  reference count frees it, so no `try/finally`. `Map` and `Normalize` exist for every optional
  type, with its own function type and factory (`TPcCurrencyNormalizers`,
  `TPcDateTimeNormalizers`...).
- `PascalCommon.Normalizers` doesn't depend on the optionals, so the same rules also clean a
  plain value: `TNorm.CityName.Apply(S)`.
- Keep the limits in the checks: sample 02 doesn't cut the name at 100 characters, because a
  normalizer that did would hide a client's mistake instead of answering 400.
- Inherit the factory; don't write a class helper for it (Delphi and FPC 3.2 see one helper per
  type, so two would hide each other). The details: pascal-common-faa's README, "One place for
  your normalizers".

The create works the same way: its population is a tagged block in the `INSERT`, gone when the
member is absent (the column takes its default, `NULL`), and bound with
`OptIntegers['POPULATION'] := ACity.Population`, no `if`. Sample 03 does it through the tenant
filter: `TTenantFilter.Prepare` takes the processed SQL ([Multi-tenancy](multitenancy.md)).

For an `IOptNullXxx`, **`HasValue` means "the member came"**, with a value or with `null`;
`IsNull` tells the two apart. Back from the database, `AResult.NullableIntegers['POPULATION']`
gives an `INullInteger` straight into the response DTO, and a `NULL` column is written as `null`
(sample 02 checks `"population":null` for Florianópolis). Details: [Database access](database.md).

### 5. Write a response

- **A DTO:** `TJsonMapper.Shared.ToJson<ICity>(LCity)`; a list:
  `Serialize<TCityArray>(LItems)` with a **named** array type (`TCityArray = TArray<ICity>`: on
  FPC, `Serialize<TArray<ICity>>` doesn't parse, `>>` reads as `shr`).
- **Small answers by hand:** `TJsonWriter` (it escapes for you), as sample 01's `WriteCity` and
  sample 04's `/consumed` do. Never concatenate a value into JSON text yourself.
- **Always out through `TJsonSend.Send`**: UTF-8 bytes and `charset=utf-8` on both compilers
  ([Getting started](getting-started.md), step 3).
- **Names** are camelCase by default (`PopulationTotal` → `populationTotal`). `Naming := jnSnakeCase`
  or `jnAsDeclared` for the whole mapper, `RenameMember(TCity, 'Kind', 'type')` for one member
  (a Pascal keyword, say). The mapper refuses two properties that would share a JSON name.
- **Paged responses:** `PageEnvelopeJson` around the items ([Getting started](getting-started.md),
  step 6).

### 6. Types beyond strings and integers

From the mapper's contract and suite, not measured again here:

- **Numbers** keep their source text: an `Int64` above 2^53 survives a round trip
  (`Parse_BigInteger_KeepsExactText`); `Double`/`Single` are written as the shortest text that
  reads back exactly, the same on both compilers (`RoundTrip_Double_RandomBits`). `Currency` is
  exact up to `High`/`Low(Currency)`, with more than 4 decimals rounded half to even
  (`0.00025` → `0.0002`), on pascal-jsonmapper-faa 0.6.0 or later; measured here over HTTP
  (sample 01's `POST /prices`, `tools/http_scenarios.sh`). A value outside the range is a 400
  with its path.
  A JavaScript client still loses an integer above 2^53: send such ids as strings.
- **Dates** (`TDateTime`, `IOptDateTime`...) are ISO 8601. **No zone is written**, and an offset
  on input is converted to UTC (`Parse_WithOffset_ConvertsToUtc`): keep `TDateTime` values in UTC
  inside the API, or the client can't tell what a written time means.
- **Enums** by name; an unknown name is a 400 with the path (`Error_UnknownEnumName`).
- **GUIDs** only through `IOptGuid`/`INullGuid`/`IOptNullGuid` (the bridge writes them with
  braces); the mapper has no rule for a bare `TGUID`.
- **Nested DTOs and arrays** of DTOs or scalars (`Nested_InterfaceAndArrays`). A class-typed
  property is never created by the mapper: it fills the instance the property already holds.
- Anything else: a converter (`IJsonConverter`, pascal-jsonmapper-faa's `docs/converters.md`).

The OpenAPI document is built from the same mapper (`TJsonMapper.Members`), so it can't name a
member the wire doesn't have; the optional types become "not required" and "nullable" there
([OpenAPI](openapi.md)). Sample 02 checks the PATCH DTO's schema in its document.

### 7. The query string

Query parameters are text, not JSON. Since 0.19.0 a Find DTO is read from them by the members the
route documents (`TRouteDoc`'s `QueryParams<ICityFind>`), in one call (sample 02's `GetCities`):

```pascal
LFind := THorseQueryParams.Read<ICityFind>(AReq);   // PascalApi.Horse.Middlewares
// without Horse: TQueryParams.Read<ICityFind>(TJsonMapper.Shared, AValues), PascalApi.QueryParams
```

Each member the document lists (strings, integers, numbers, booleans, enumerations, dates and the
optionals of those; `ApiQueryParamType` is the one rule for both) is looked up by its JSON name,
ignoring case, written into a JSON object and given to the mapper, so a value meets the body's
rules: an `IOptInteger` is absent or a number, an integer past its type is refused, a
`TUtcDateTime` needs its zone. An empty or missing parameter is absent; a member that isn't an
optional is **required**, as the document says (0.23.0): missing, empty or blank, it is a
`required` failure of that field (`"service" is required.`), every missing one in one 400
(`invalid_fields`), the same failure `TValid.Required` gives a body's member (until 0.22.0 it was
read as `''` or 0 without a word). A parameter the DTO
doesn't have is ignored (unlike a body: a query string often carries a cache buster). A value of
the wrong kind is a 400 naming the parameter (`"limit" must be an integer.`, `"active" must be
true or false.`, `"price" must be a number.`: `TApiMessages.InvalidQueryInteger`,
`InvalidQueryBoolean`, `InvalidQueryNumber`); what the mapper refuses is a 400 as
`name: reason` (`page: 99999999999 is out of range (-2147483648..2147483647)`). Booleans are
`true` or `false` only. Tested in `PascalApi.QueryParamsTests`, checked over HTTP by sample 02.
Objects and arrays are skipped, as the document skips them.

Until 0.19.0 each handler copied the members by hand with `ParseQueryInt`/`ParseQueryStr`
(`PascalApi.Pagination`), which stay for a single value: `ParseQueryInt` takes only an optional
`-` and decimal digits within `Integer`; anything else is a 400 naming the parameter. Until 0.13.0 it used `TryStrToInt`: `abc`
silently became the default, `$3`, `0x3`, `+3` and ` 3` were read as 3, and on FPC 3.2.2 a number
past `Integer` wrapped around (`page=99999999999` became page 1215752191, measured). Tested in
`PascalApi.PaginationTests` and checked over HTTP by samples 01 and 02.

### 8. Beyond HTTP: the same DTO in a message

A DTO doesn't care where its JSON goes. Two rules carry over from HTTP:

- **Check before you send.** Read the body into the DTO in the handler, so a bad request is a
  400 to its client and never a message nobody can read.
- **Every receiver handles its errors.** On a queue or a pipe there is no error handler to turn
  an exception into an answer. pascal-amqp-faa 0.4.1 sends a consumer's exception to
  `OnConsumerError` (step 9) and pascal-pipes-faa 0.3.0 a handler's to `OnError` (step 10): assign
  them. Before those versions, both lost the message silently (measured).

### 9. On a queue (pascal-amqp-faa)

Sample 04 (`MessagingSample.lpr`):

```pascal
/// The body read into an IOrder and checked, written back by the mapper.
function OrderJson(AReq: THorseRequest): string;
var
  LOrder: IOrder;
begin
  LOrder := TJsonMapper.Shared.FromJson<IOrder>(AReq.Body);
  if Trim(LOrder.Item) = '' then
    raise EValidationException.Create('"item" is required.');
  if LOrder.Quantity <= 0 then
    raise EValidationException.Create('"quantity" must be positive.');
  Result := TJsonMapper.Shared.ToJson<IOrder>(LOrder);
end;

/// UTF-8 bytes with content type application/json (PublishText says text/plain).
function PublishJson(AChannel: TAMQPChannel; const AJson: string): UInt64;
var
  LProps: TAMQPBasicProperties;
begin
  LProps := TAMQPBasicProperties.Empty;
  LProps.SetContentType('application/json');
  LProps.SetPersistent;
  Result := AChannel.Publish('', GQueue, PaStringToUtf8Bytes(AJson), LProps);
end;
```

The consumer reads it back; what it can't read goes to the channel's `OnConsumerError`
(**pascal-amqp-faa 0.4.1 or later**):

```pascal
procedure TApp.OnOrder(AChannel: TAMQPChannel; const ADelivery: TAMQPDelivery);
var
  LOrder: IOrder;
begin
  // No try: a message that can't be read raises, and OnOrderError logs it.
  LOrder := TJsonMapper.Shared.FromJson<IOrder>(ADelivery.BodyAsText);
  ... // the work
  AChannel.Ack(ADelivery.DeliveryTag);
end;

procedure TApp.OnOrderError(AChannel: TAMQPChannel; const ADelivery: TAMQPDelivery;
  AError: Exception; var AAction: TAMQPConsumerErrorAction);
begin
  // AError belongs to the library (never free or re-raise it). AAction comes
  // as ceaReject (Nack without requeue) for a pending message: kept.
  TErrorHandlerMiddleware.LogError(Format('order rejected: %s: %s',
    [AError.ClassName, AError.Message]), TraceIdOf(TPcTracing.Current));
end;

// At startup, on its own channel (the queue was declared on GPublisher):
GConsumer := GAmqp.CreateChannel;
GConsumer.OnConsumerError := GApp.OnOrderError;
GConsumer.Consume(GQueue, GApp.OnOrder);
```

Measured on FPC with RabbitMQ 3 (pascal-amqp-faa 0.3.0 for the first point and the last, 0.4.1
for the second):

- `POST /orders` with `"quantity":"x"`, an unknown member or a quantity of 0: 400, nothing
  published. A good order with `"café"`: 202, and the consumer read `café` as UTF-8 (`/consumed`
  answered `"lastItem":"caf\xc3\xa9"`).
- A bad message published on purpose (`/orders/raw`, `"quantity":"x"` and `not json`): each logged
  by `OnOrderError` (`order rejected: EJsonInputError: $.quantity: expected integer, found JSON
  string trace_id=...`, the message's trace: the handler runs inside its `process` span) and rejected without requeue; the queue
  ended with nothing ready and nothing unacknowledged, and nothing came back after a restart.
  The queue has no dead-letter exchange, so they were dropped: give it one where a message must
  not be lost.
- **With 0.3.0 and no `try` in the callback**, the same bad message stayed unacknowledged, with
  nothing in the log (the pool swallowed the exception), and came back on every restart. On 0.3.0,
  catch in the callback and `Nack` yourself.

The rest of messaging inside an API (one connection per process, confirms, spans, a broker that
is down): [Messaging, Redis, IPC](messaging.md).

### 10. Between processes (pascal-pipes-faa)

pascal-pipes-faa carries bytes; text and JSON are up to the application. It ships an optional
`Pipes.Json` unit over each compiler's own JSON library (`System.JSON` on Delphi, `fpjson` on FPC),
which write different text for the same value. To keep one JSON on both ends, use the mapper
with `SendText`/`RequestText`, as sample 04's `PipesJsonSample.lpr` does:

```pascal
procedure TServerSide.OnRequest(Sender: TObject; AConnId: TPipeConnectionId;
  const ARequest: TBytes; out AReply: TBytes);
var
  LOrder: IOrder;
  LReply: TOrderReply;
  LReplyIntf: IOrderReply;
begin
  // An exception here goes back to the client as an error reply.
  LOrder := TJsonMapper.Shared.FromJson<IOrder>(FrameText(ARequest));
  LReply := TOrderReply.Create;
  LReplyIntf := LReply;
  LReply.Accepted := LOrder.Quantity > 0;
  LReply.Item := LOrder.Item;
  AReply := PaStringToUtf8Bytes(TJsonMapper.Shared.ToJson<IOrderReply>(LReplyIntf));
end;

procedure TServerSide.OnMessage(Sender: TObject; AConnId: TPipeConnectionId; const AData: TBytes);
var
  LOrder: IOrder;
begin
  // No try: an exception goes to OnError (pascal-pipes-faa 0.2.0 or later).
  LOrder := TJsonMapper.Shared.FromJson<IOrder>(FrameText(AData));
  ...
end;

procedure TServerSide.OnError(Sender: TObject; AConnId: TPipeConnectionId; const AError: string);
begin
  // Runs on the same thread, right after the handler that failed; the
  // connection stays open (Server.DisconnectClient(AConnId) would close it).
  Writeln('error on connection ', AConnId, ': ', AError);
end;

GServer.OnMessage := GSide.OnMessage;
GServer.OnError := GSide.OnError;
```

(`FrameText` decodes the frame's UTF-8 and raises when it isn't.) Use **pascal-pipes-faa 0.3.0 or
later** (0.2.0 behaves the same, with its messages in Portuguese). Measured on FPC 3.2.2/Windows:

- A request: `{"accepted":true,"item":"rice"}`. A bad one: the client's `RequestText` raised
  `EPipeError: server replied with error: $.quantity: expected integer, found JSON string`. The
  server's exception text reaches the client, so keep
  messages that the other process may see free of secrets.
- A fire-and-forget message whose handler raised: the server's `OnError` got
  `OnMessage raised EJsonInputError: $.quantity: expected integer, found JSON string`,
  and the connection kept working. **With 0.1.1 the same message was lost without a trace**:
  `OnError` wasn't called, on either side. On 0.1.1, catch inside `OnMessage`.

### 11. How big a body may be

Nothing in Horse or in this library limits a request body: Horse reads it whole before any
middleware runs, so a middleware could only refuse it after paying for it. A 50 MB body (a member
the DTO doesn't have, before `umError`) was accepted in 1.4 s and the process grew from 11 MB to
60 MB (FPC, measured). **Limit it in front of the API**, at the reverse proxy (nginx's
`client_max_body_size`, for example; not measured here), with a size your largest real request
fits in. The parser's own limit is nesting depth (512), not size.

## Choices

### `umError` or ignoring unknown members

`umError` catches typos and fields the API never had, at the cost of refusing a client that
sends extra members on purpose. Ignoring is the mapper's default and the right choice only when
clients are expected to run ahead of the API. The samples use `umError`.

### `IOptXxx`, `INullXxx` or `IOptNullXxx`

Step 3's rule of thumb. A plain `Integer` with `0` for "unknown" is never right in a DTO: the
client can't tell "unknown" from zero, and `null` would keep the previous value.

### The mapper or `TJsonWriter`

The mapper for DTOs (and for anything the OpenAPI document describes); `TJsonWriter` for small,
fixed answers. Both escape and both write the same bytes on both compilers.

### The mapper or a compiler's JSON library

`System.JSON` and `fpjson` don't agree on numbers or on `\u` escapes (fpjson 3.2.2 decodes them
through the system code page unless it is UTF-8; pascal-jsonmapper-faa's `PascalJsonMapper.Json`
header). Where both ends must agree, one library on both: the mapper.

## Pitfalls

- **A typo in a member name, accepted** (step 2): turn on `umError`.
- **A member sent twice, on pascal-jsonmapper-faa 0.3.0**: it kept one of the values (the first,
  or the second when the names differed in case), while many parsers keep the last, so something
  in front of the API (a gateway, a WAF) could read the same body differently. 0.4.0 refuses it
  (400), whatever `UnknownMembers` says; `tools/http_scenarios.sh` checks it. Use 0.4.0 or later.
- **Error messages that named Pascal classes**: until pascal-jsonmapper-faa 0.5.0 the 400s said
  `TCityInsert.Name` or `no published property of TOrder`. 0.5.0 raises `EJsonInputError` for
  input at fault, with JSON terms only (the Pascal side in `Detail`); the error handler answers
  it 400 and any other `EJsonMapperError` (a programming error) 500, logged.
- **A large `Currency` on pascal-jsonmapper-faa before 0.6.0 (FPC)**: on Win64
  `123456789012345.6789` came back as `...6768`, `High(Currency)` with its sign flipped, and
  `0.00025` as `0.0003` (measured with `POST /prices`). Use 0.6.0 or later.
- **`null` into a plain type keeps the old value** (step 2).
- **Public properties**: invisible to the mapper on both compilers.
- **A DTO kept only in a class variable**: freed when the first interface reference to it goes
  away (passed to a routine that takes the interface, for example), and the class variable then
  points at freed memory. Assign it to an interface variable first, then fill it through the
  class (step 1).
- **`Length` for a "max N characters" rule**: it counts bytes on FPC and UTF-16 units on Delphi;
  use `PaCharCount` ([OpenAPI](openapi.md), step 5).
- **Times without a zone** (step 6).
- **A consumer callback that raises with no `OnConsumerError`**: rejected and, without a
  dead-letter exchange, dropped, with nothing logged (on pascal-amqp-faa 0.3.0: stuck; step 9).
  **A pipe handler that raises** with no `OnError` assigned, or on pascal-pipes-faa 0.1.1: lost
  (step 10).
- **`PublishText` for JSON**: it labels the message `text/plain`; publish bytes with
  `application/json` (step 9).
- **No body size limit** (step 11).
- **Testing with curl from Git Bash on Windows**: put non-ASCII and `\u` escapes in a file
  (`--data-binary @file`); curl.exe gets its arguments in the ANSI code page, and a test that
  types them on the command line sends something else.
- **Reading non-ASCII in a console log on Windows (FPC)**: `Writeln` converts to the console's
  code page, so `é` showed as the byte `0x82` (code page 850) in sample 04's log while the message
  itself was UTF-8 (measured). Check bytes in the response, not in the console.

## Testing your application

- **Over HTTP**, as `tools/http_scenarios_db.sh` does: for each DTO, a wrong type, an unknown
  member, `null` where it isn't allowed, and each limit; for a PATCH, absent, `null` and a value
  for every member that allows them.
- **Bytes, not text**: compare the response's bytes for non-ASCII (the scenarios use `body_is`
  with UTF-8 in the script, and send bodies from files).
- **Both compilers**: the same script against the Delphi and the FPC build of the sample. The
  mapper is meant to answer the same on both; the checks are what show it.
- **Messages**: publish a bad message on purpose (sample 04's `/orders/raw`) and check that it
  is logged and that the queue is left with nothing unacknowledged
  (`rabbitmqctl list_queues name messages_ready messages_unacknowledged`).

## Reference

- [pascal-jsonmapper-faa](https://github.com/fabianoallex/pascal-jsonmapper-faa): the contract
  (README), converters and the optionals bridge's rules (`docs/converters.md`).
- pascal-common-faa: `PascalCommon.Optionals` (the 27 interfaces, `TOptionals.Safe`, the
  normalizers that keep the state), `PascalCommon.Normalizers` (the factories, 1.14.0)
  and `bridges/jsonmapper/PascalCommon.JsonMapper.Optionals`.
- `PascalApi.Dto` (the bases), `PascalApi.Pagination` (`ParseQueryInt`, `ParseQueryStr`,
  `PageRequestFrom`), `PascalApi.Http` (`TJsonSend`, `EValidationException`, `TApiMessages`).
- Samples: `samples/01-api` (POST), `samples/02-db` (PATCH, the query string, `NULL`),
  `samples/04-messaging` (`MessagingSample.lpr`, `PipesJsonSample.lpr`).
- Guides: [Errors and validation](errors.md), [Database access](database.md),
  [OpenAPI](openapi.md), [Messaging, Redis, IPC](messaging.md).
