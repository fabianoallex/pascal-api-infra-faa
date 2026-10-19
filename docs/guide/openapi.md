# OpenAPI

How to describe the API's routes and DTOs so that an OpenAPI 3.0.3 document and a Swagger UI page
come out of the program itself. The code comes from the three samples. `PascalApi.OpenApiTests`
checks the document's JSON member by member. `tools/http_scenarios*.sh` fetch each sample's
`/swagger/doc.json`, and CI validates the three documents with `openapi-spec-validator`. A few
behaviours below were measured against the samples for this guide (FPC 3.2.2 and Delphi 12,
Windows, 2026-10-14), and each one says so. The decisions behind the design are in
[docs/openapi-design.md](../openapi-design.md).

## What it solves

A client of your API needs to know its routes, what each one takes and what it answers. Written
by hand, that description drifts from the code the first time someone adds a route and forgets
it. Here a route is registered in Horse and described in the document **by the same call**, and
each DTO's schema is derived from the class the JSON mapper uses, so the names and types in the
document are the ones on the wire.

FPC 3.2.2 has no custom attributes, so what a type can't tell (a description, an example, a
limit) is written in code, next to the DTO's mapping, and checked when the program starts.

## The smallest working program

```pascal
uses
  Horse, PascalApi.Horse.OpenApi;

TRouteDoc.Get('/health').Summary('Liveness').NoContent(200, 'Up').Register(GetHealth);
TRouteDoc.Serve('/swagger', 'My API', '1.0.0');   // after every route
THorse.Listen(9000);
```

`TRouteDoc.Get(...)...Register(GetHealth)` is `THorse.Get('/health', GetHealth)` plus the
operation in the document. `Serve` adds two routes: `/swagger/doc.json` (the document) and
`/swagger` (Swagger UI).

## Step by step

### 1. Register each route through `TRouteDoc`

From `samples/02-db/DbApiSample.dpr`:

```pascal
TRouteDoc.Get('/cities')
  .Summary('List cities, a page at a time').Tag('cities')
  .QueryParams<ICityFind>
  .ResponsePaged<ICity>(200, 'A page of cities')
  .Error(400, 'An order field that is not allowed')
  .Register(GetCities);
TRouteDoc.Get('/cities/:code')
  .Summary('One city').Tag('cities')
  .PathParam('code', 'IBGE code (7 digits)')
  .Response<ICity>(200)
  .Error(404, 'No city with this code')
  .Register(GetCity);
TRouteDoc.Post('/cities')
  .Summary('Create a city').Tag('cities')
  .Body<ICityInsert>
  .Response<ICity>(201, 'Created')
  .Error(400, 'Invalid data')
  .Error(409, 'A city with this code already exists')
  .Register(PostCity);
```

`Get`, `Post`, `Put`, `Patch` and `Delete` start a builder; `Register` adds the operation to the
document, registers the handler in Horse, and frees the builder. The handler is the same named
procedure `THorse.Get` takes ([Getting started](getting-started.md), step 3). A chain that never
reaches `Register` leaks its builder (from the code: only `Register` frees it).

The path is Horse's (`/cities/:code`); the document writes OpenAPI's (`/cities/{code}`). A path
parameter you don't declare with `PathParam` is still documented, as a required string (tested:
`Path_ConvertedAndUndeclaredParamsAdded`).

What each builder method documents:

| Method | Documents |
|---|---|
| `Summary`, `Descr`, `Tag`, `OperationId` | the operation's text, its group in Swagger UI, its id |
| `PathParam(name, desc, type)` | a path parameter (`ptString`, `ptInteger`, `ptNumber`, `ptBoolean`) |
| `QueryParam(name, desc, type, required)` | one query parameter |
| `QueryParams<IFind>` | one query parameter per published property of a Find DTO (step 4) |
| `Body<I>` | the request body: the schema of the DTO `I` |
| `Response<I>`, `ResponseArray<I>`, `ResponsePaged<I>` | a response with `I`, an array of `I`, or the paging envelope with `I` in `items` |
| `NoContent(code, desc)` | a response without a schema |
| `Error(code, desc)` | a response with the error handler's body, `{"error": "...", "requestId": "..."}` |
| `NoMcp` | documented, but not offered as an MCP tool |

A response without a description gets the status's name (`"200": {"description": "OK"}`).

### 2. The DTO's schema comes from its class

`Body<ICityInsert>` documents the class registered for `ICityInsert` in `TJsonMapper.Shared`:
its **published** properties, with the names and the order the mapper writes. From sample 02's
`/swagger/doc.json`, for the classes in `samples/02-db/DbApiSample.Cities.pas`:

```pascal
TCityInsert = class(TInsertDTOBase, ICityInsert)
published
  property Code: string read FCode write FCode;
  property Name: string read FName write FName;
  property State: string read FState write FState;
  property Population: IOptInteger read FPopulation write FPopulation;
end;

TCity = class(TResponseDTOBase, ICity)
published
  ...
  property Population: INullInteger read FPopulation write FPopulation;
end;
```

```json
"CityInsert": {"type": "object", "properties": {...,
  "population": {"type": "integer", "format": "int32", ...}},
  "required": ["code", "name", "state"]}
"City": {"type": "object", "properties": {...,
  "population": {"type": "integer", "format": "int32", "nullable": true, ...}},
  "required": ["code", "name", "state", "population"]}
```

How a property's type becomes a schema (each row tested in `PascalApi.OpenApiTests`):

| Published property | Schema | Required | Nullable |
|---|---|---|---|
| `string` | `string` | yes | no |
| `Integer`, `Int64` | `integer`, format `int32` / `int64` | yes | no |
| `Double`, `Single`, `Currency` | `number`, format `double` / `float` / none | yes | no |
| `Boolean` | `boolean` | yes | no |
| `TDateTime`, `TDate`, `TTime` | `string`, format `date-time` / `date` / `time` | yes | no |
| an enumeration | `string` with `enum`: the value names | yes | no |
| `IOptXxx` | the base type | **no** | no |
| `INullXxx` | the base type | yes | **yes** |
| `IOptNullXxx` | the base type | **no** | **yes** |
| a DTO interface registered with the mapper | `$ref` to its schema | yes | no |
| a dynamic array | `array` of the element's schema | yes | no |

The schema's name is the interface's without the leading `I` (`ICityInsert` → `CityInsert`).
Names follow the mapper's rules: with `Naming := jnSnakeCase` or a `RenameMember`, the document
shows the renamed member, never the Pascal name (tested: `NamesFollowTheMapper`). The documents
are byte-identical on FPC and Delphi (measured for this guide: each of the three samples, FPC
3.2.2 against Delphi 12 Win32).

### 3. What the type can't tell: `TApiSchema.Describe`

Descriptions, examples and limits are registered next to the mapping, in the unit's
`initialization`. From sample 02:

```pascal
initialization
  TJsonMapper.Shared.RegisterMapping<ICityInsert, TCityInsert>;
  TJsonMapper.Shared.RegisterMapping<ICity, TCity>;
  TJsonMapper.Shared.RegisterMapping<ICityFind, TCityFind>;
  // OpenAPI metadata the types can't tell (FPC has no attributes).
  TApiSchema.Describe(TypeInfo(ICityInsert), 'A new city')
    .Prop('Code').Desc('IBGE code').Example('4205407').Pattern('^[0-9]{7}$')
    .Prop('Name').Desc('City name').Example('Florianópolis').MaxLength(100)
    .Prop('State').Desc('Two-letter state').Example('SC').MinLength(2).MaxLength(2)
    .Prop('Population').Desc('Inhabitants, when known').Example('537211').Minimum(0);
```

- `Prop` takes the **Pascal property name**. A name the class doesn't publish raises
  `EApiSchemaError` at once, so a typo stops the program at startup instead of leaving a member
  undocumented (tested: `Describe_UnknownProperty_Raises`).
- `RegisterMapping` comes first: `Describe` for an interface the mapper doesn't know raises too
  (tested: `Describe_UnregisteredInterface_Raises`).
- `Example` takes text and writes it with the property's JSON type: `'537211'` becomes the number
  `537211` for an integer, `'4205407'` stays a string for a string (tested).
- `Enum([...])` lists the allowed values (tested on an enumeration, whose value names it
  replaces).
- `Desc`, `Format`, `Pattern`, `Minimum`, `Maximum`, `MinLength`, `MaxLength` are written as
  OpenAPI's keywords of the same names (tested).

**The document describes the limits; it doesn't enforce them.** Nothing between Horse and your
handler reads the document. Step 5 shows what a request that breaks them does.

### 4. A paged search: `QueryParams<IFind>`

A Find DTO (the query string of a list, [Getting started](getting-started.md), step 6) becomes
one query parameter per published property, inherited ones included, named as the mapper names
them and described by its own `Describe`:

```pascal
TApiSchema.Describe(TypeInfo(ICityFind))
  .Prop('Page').Desc('Page number, from 1')
  .Prop('Limit').Desc('Cities per page (default 2, at most 50)')
  .Prop('OrderBy').Desc(CityOrderSpec.DocHint)
  .Prop('Search').Desc('Not used by this sample')
  .Prop('State').Desc('Only the cities of this state (two letters)');
```

```json
{"name":"state","in":"query","description":"Only the cities of this state (two letters)","required":false,"schema":{"type":"string"}}
{"name":"page","in":"query","description":"Page number, from 1","required":false,"schema":{"type":"integer"}}
```

(both lines checked by `tools/http_scenarios_db.sh`). An `IOptXxx` member isn't required; an
array member is left out, since a query parameter here is one value (tested:
`QueryDto_ExpandsToQueryParams`). `CityOrderSpec.DocHint` lists the fields `orderBy` accepts,
from the same `TOrderBySpec` the repository uses ([Database access](database.md), step 4), so
the two can't disagree.

### 5. Enforce the documented limits in the handler

Measured against sample 02 before it checked them (FPC and Delphi Win32):

| Request | The document says | FPC | Delphi |
|---|---|---|---|
| `"code":"+123456"` | `pattern ^[0-9]{7}$` | 201, stored | 201, stored |
| `"population":-5` | `minimum 0` | 201, stored | 201, stored |
| a 150-character `name` | `maxLength 100` | 201, stored | **500**, and stored (below) |
| `"population":"abc"` | `integer` | 400 (the mapper) | 400 (the mapper) |
| an unknown member `"color":"red"` | not in the schema | 201, the member ignored | 201, the member ignored |
| `?page=abc` | `integer` | 200, page 1 | 200, page 1 |

Only the JSON types are checked, by the mapper ([Errors and validation](errors.md), step 2).
Everything else is the handler's job. Samples 02 and 03 now check each limit their documents
declare, in the repository's `Insert`:

```pascal
// The limits the OpenAPI document declares (TApiSchema.Describe below): the
// document describes them, only this enforces them.
LCode := Trim(ACity.Code);
if not IsDigits(LCode, 7) then
  raise EValidationException.Create('"code" must be the 7-digit IBGE code.');
if Trim(ACity.Name) = '' then
  raise EValidationException.Create('"name" is required.');
if PaCharCount(Trim(ACity.Name)) > 100 then
  raise EValidationException.Create('"name" must have at most 100 characters.');
if Length(Trim(ACity.State)) <> 2 then
  raise EValidationException.Create('"state" must have 2 letters.');
if ACity.Population.HasValue and (ACity.Population.Value < 0) then
  raise EValidationException.Create('"population" can''t be negative.');
```

`IsDigits` is the sample's: `StrToIntDef` would take `+123456`. `PaCharCount` (`PascalApi.Text`)
counts characters, the same on both compilers. `Length` counts bytes on FPC and UTF-16 units on
Delphi, so `Length(Name) > 100` would refuse 60 accented letters on FPC only. The scenarios check
each limit: 400 for each one broken, and 201 for a name of 100 two-byte characters
(`tools/http_scenarios_db.sh`, `tools/http_scenarios_tenants.sh`). Run against the Delphi build
from before the change, sample 02's scenario failed 7 checks and sample 03's failed 5.

**The database won't check it either.** SQLite doesn't enforce `VARCHAR(100)` and stores the
longer value, through SQLdb and FireDAC alike. Until pascal-db-faa 0.14.1, FireDAC then refused to
*read* it back (`[FireDAC][DatS]-32. Variable length column [NAME] overflow`): the insert answered
500 with the row already saved, and `GET /cities/1000001` and every list containing that row
answered 500 until the row was deleted (measured on sample 02, Delphi 12 Win32). 0.14.1 reads the
whole value, as SQLdb always did (a 150-character name written straight into the file: 200 on
both compilers). Checking the length before the insert is still what keeps the row out; to have
the database refuse it too, declare `CHECK (length(NAME) <= 100)` in the migration
([Database access](database.md), "SQLite").

### 6. Serve the document and Swagger UI

```pascal
TRouteDoc.Serve('/swagger', 'Cities API (pascal-api-infra-faa sample 02)', '1.0.0');
```

- `/swagger/doc.json` answers the document (`"openapi":"3.0.3"`, checked by every scenario).
- `/swagger` answers a Swagger UI page whose script and style come from unpkg
  (`swagger-ui-dist`, pinned to `SWAGGER_UI_VERSION`, 5.17.14). **The browser that opens the page
  needs internet; the API doesn't.** The scenarios check that the page names
  `swagger-ui-dist@`; whether it renders wasn't checked by any script.
- `Serve` writes the document **once**. A route registered after `Serve` works but isn't in the
  document (from the code: the JSON is built in `Serve` and kept).
- The two routes go through the global middlewares like any other. Behind `TJwtMiddleware`, list
  the base path among the excluded prefixes, as samples 01 and 03 do, or the page can't load the
  document without a token:

  ```pascal
  THorse.Use(TJwtMiddleware.New(GSecret, ['/health', '/metrics', '/auth/login', '/swagger']));
  ```

### 7. Authentication in the document comes from the middleware

`Serve` asks the authentication middleware what it enforces, so the document has no second list
of public paths to keep in step:

- With `TJwtMiddleware.New` run before `Serve`, the document gets a bearer scheme with format
  `JWT`, required by every operation:

  ```json
  "security": [{"bearerAuth": []}],
  "components": {"securitySchemes": {"bearerAuth": {"type": "http", "scheme": "bearer", "bearerFormat": "JWT"}}}
  ```

- An operation whose path the middleware excludes gets `"security": []`: from sample 01,
  `"/auth/login": {"post": {..., "security": [], ...}}`. With the scheme, Swagger UI shows its
  **Authorize** button (not checked by a script).
- Without an authentication middleware, the document has no `securitySchemes` (checked by
  sample 02's scenario).

Sample 01's scenario checks the scheme, the requirement, `/health`'s `"security": []` and that a
protected path keeps the requirement. With `TAuthMiddleware.Bearer` (your own check) instead,
`Serve` writes the same scheme without a format (from the code; no test or sample uses it).

### 8. Routes without DTOs

A response written by hand (`TJsonSend.Send(ARes, '{"token":"..."}')`) has no type to derive a
schema from. Sample 01 documents only its status and a description:

```pascal
TRouteDoc.Post('/auth/login').Summary('Get a token (1 hour)').Tag('public')
  .NoContent(200, '{"token": "..."}').Error(400, '"user" is missing').Register(PostLogin);
```

The description is free text. A client generator gets no type for it, and no check compares it
with what the handler sends.

## Choices

### DTOs or hand-written JSON

A DTO gives the document a schema, the client a generated type, and the MCP tools an input
schema. Hand-written JSON is quicker for a route with one or two members (a token, a status) and
documents only its status. Sample 02 uses DTOs for every route; sample 01 writes its JSON by
hand.

### `QueryParams<IFind>` or `QueryParam` one by one

With a Find DTO, the handler reads the query string through the mapper and the document lists
the same members. `QueryParam` suits a route with one or two parameters and no DTO, but nothing
keeps those names in step with what the handler reads.

### Swagger UI from the CDN

The page is small and the API needs no internet. If the people who open it have no internet
either (an isolated network), serve the document only and open it in a Swagger UI you host. The
library has no option to serve the UI's files from the executable today.

### The MCP tools come from the same document

`TMcpEndpoint` turns each documented operation into a tool for an AI client: the name is the
`OperationId`, or one derived from the method and the path; the input schema is the DTO's.
`NoMcp` keeps an operation out. Sample 01 marks its `/fail/*` routes `NoMcp`. See
[MCP](mcp.md).

## Pitfalls

- **Taking the document's limits for validation** (step 5). On Delphi with FireDAC, a value longer
  than the column was stored and then made every read of its row a 500.
- **A route registered after `Serve`**: it works, but it isn't documented.
- **`/swagger` behind the JWT middleware without being excluded**: the page can't load the
  document.
- **The authentication middleware on a path prefix** (`THorse.Use('/admin', TJwtMiddleware.New(...))`):
  `Serve` assumes it covers the whole API, and would mark every route as needing a token (from
  the code and the unit's comment; not tested).
- **`Describe` before `RegisterMapping`**, or with a property name that doesn't exist: both raise
  at startup (tested). Better than a silent gap, but the program won't start.
- **A builder without `Register`**: the route isn't registered and the builder leaks (step 1).
- **Two operations that would get the same MCP tool name**: `TMcpEndpoint.Register` raises and
  asks for an `OperationId` (from the code).
- **Counting characters with `Length`** for a `MaxLength`: bytes on FPC (step 5).

## Testing your application

**The document, without a server.** Build a `TApiDocument` with your own mapper and check its
JSON, as `PascalApi.OpenApiTests` does:

```pascal
procedure TOpenApiTests.SetUp;
begin
  FMapper := TJsonMapper.Create;
  FMapper.RegisterMapping<IPart, TPart>;
  FMapper.RegisterMapping<IKitchen, TKitchen>;
  FMapper.RegisterMapping<IFind, TFind>;
  FMapper.RenameMember(TPart, 'Label_', 'label');
  FDoc := TApiDocument.Create(FMapper);
  FDoc.Title := 'T';
  FDoc.Version := '1';
  FParsed := nil;
end;
```

(the teardown frees both and calls `TApiSchema.Clear`, so no description leaks into the next
test). Your own `Describe` calls run in `initialization`, so a test program that uses the unit
stops at startup on a typo.

**The document over HTTP.** Fetch `/swagger/doc.json` and validate it with a real OpenAPI
validator. CI does it for each sample:

```sh
python3 -m openapi_spec_validator openapi.json
```

Then check the parts a client relies on, as `tools/http_scenarios_db.sh` does: a schema, a
nullable member, the required list, a query parameter from the Find DTO, the error responses.

**The limits.** For each `Pattern`, `Minimum`, `MaxLength` you declare, send a request that
breaks it and check the 400 (step 5). The document won't do it for you.

## Reference

- `PascalApi.OpenApi`: the model, the schema inference, `TApiSchema.Describe`, the JSON (comment
  at the top).
- `PascalApi.Horse.OpenApi`: `TRouteDoc`, `TRouteDocBuilder`, `Serve`, `SWAGGER_UI_VERSION`.
- `PascalApi.Text`: `PaCharCount`.
- `PascalApi.OpenApiTests`.
- `samples/01-api` (hand-written JSON, JWT in the document), `samples/02-db` (DTOs, a Find DTO,
  no authentication), `samples/03-tenants` (DTOs, a join's route, JWT);
  `tools/http_scenarios.sh`, `tools/http_scenarios_db.sh`, `tools/http_scenarios_tenants.sh`;
  `tools/test_http_docker.sh` (the validator).
- [docs/openapi-design.md](../openapi-design.md): the four decisions and the inference rules.
