# Phase 4 design: OpenAPI on both compilers

Status: **approved by the user (2026-10-08), all four decisions as recommended; implemented.**
The `.QueryParams<IFind>` addition (decision 4) came right after, for 0.4.0.

## Goal

What delphi-api-infra-faa's Swagger gives a Delphi API, on Delphi and FPC 3.2.2:

- one fluent call per route registers the Horse handler **and** documents the operation;
- the schema of each DTO is derived from the type, not written by hand;
- `/swagger` serves Swagger UI, `/swagger/doc.json` the document;
- the same route model feeds the MCP server later (phase 5).

## What can't be ported as is (measured)

- `[SwagProp]`, `[SwagMin]`... are attributes. FPC 3.2.2 has no custom attributes anywhere (skill,
  `rtti-gotchas.md`, probes p11/p12). Metadata moves to code: **fluent, next to the DTO's
  `RegisterMapping`** (decided by the user, 2026-10-08).
- The origin walks the class's `Get*` methods with extended RTTI (`GetDeclaredMethods`, empty on
  FPC, probe p07). Here the source is the **published properties**, the same ones
  pascal-jsonmapper-faa maps (`GetPropList`, portable).
- SwagDoc (`Swag.*`) is Delphi only. The document is written with pascal-jsonmapper-faa's
  `TJsonWriter`.
- Route handlers can't be closures on FPC: `.Register(GetCities)` takes a named procedure (the
  origin's samples pass anonymous methods).

## API sketch

```pascal
// Route + documentation, in the controller (replaces THorse.Get/Post...)
TRouteDoc.Get('/cities')
  .Summary('List cities, paged')
  .Tag('cities')
  .QueryParam('state', 'Two-letter state', ptString)
  .QueryParam('page', '', ptInteger)
  .QueryParam('orderBy', CitiesOrderSpec.DocHint)
  .ResponsePaged<ICity>(200, 'A page of cities')
  .Register(GetCities);

TRouteDoc.Post('/cities')
  .Body<ICityInsert>
  .Response<ICity>(201, 'Created')
  .Error(400, 'Invalid data')            // body: the {"error": "..."} schema
  .Error(409, 'The code already exists')
  .Register(PostCity);

// Schema metadata, next to the mapping (unit initialization)
TJsonMapper.Shared.RegisterMapping<ICityInsert, TCityInsert>;
TApiSchema.Describe<ICityInsert>('A new city')
  .Prop('Code').Desc('IBGE code').Example('4205407').Pattern('^[0-9]{7}$')
  .Prop('Name').Desc('City name').MaxLength(100)
  .Prop('State').Enum(['AC', 'AL', 'AM', 'SP' {...}])
  .Prop('Population').Minimum(0);

// Serve, after every route is registered
TRouteDoc.Serve('/swagger', 'Cities API', '1.0.0');
```

- `Prop` takes the **Pascal property name**, checked when `Describe` runs: a typo raises at
  startup, not as a silently undocumented field. The document shows the JSON name the mapper
  uses for it.
- `Example`, `Minimum`, `Maximum`, `MinLength`, `MaxLength`, `Pattern`, `Enum`, `Format`, `Desc`
  — what the origin's five attributes carried. `Format` also covers a custom converter that
  changes a member's JSON type (e.g. a money type written as a string).
- `.Error(code, desc)` replaces the origin's `.NoContent('404', ...)` for errors: those responses
  do have a body, the error handler's `{"error": "..."}`, documented once as `Error`.
- The model (routes, parameters, schemas) is plain data in a pure unit, so the document is
  tested without a server; a thin Horse unit registers the routes and serves it.

## Inference rules (no metadata needed)

| Pascal type of the published property | Schema | Required | Nullable |
|---|---|---|---|
| `string` | `string` | yes | no |
| `Integer` / `Int64` | `integer` int32 / int64 | yes | no |
| `Double` / `Single` / `Currency` | `number` double / float / — | yes | no |
| `Boolean` | `boolean` | yes | no |
| `TDateTime` / `TDate` / `TTime` | `string` date-time / date / time | yes | no |
| enumeration | `string`, `enum` with the value names | yes | no |
| `IOptXxx` | the base type | **no** | no |
| `INullXxx` | the base type | yes | **yes** |
| `IOptNullXxx` | the base type | **no** | **yes** |
| interface registered with the mapper | `$ref` to its schema | yes | no |
| dynamic array | `array` of the element's schema | yes | no |

Types are recognized by `PTypeInfo` identity and type kind, never by type **name** (names
differ between compilers: `Integer` shows as `LongInt` on FPC; skill, `rtti-gotchas.md`). The
optional interfaces are recognized by their GUIDs from `PascalCommon.Optionals`.

## Decisions for the user

1. **OpenAPI 3.0.3, not Swagger 2.0.** The origin writes Swagger 2.0 with `nullable: true`,
   which 2.0 doesn't define (only 3.0 does); 3.0 also has `requestBody` and `components`.
   Swagger UI 5 reads both. Recommended: 3.0.3.
2. **A small addition to pascal-jsonmapper-faa (0.3.0, additive):** a public way to get the
   JSON member name of a published property (`JsonMemberName(AClass, APropertyName)`), today a
   private method. Without it, this library would repeat the naming and rename rules and could
   document a name the mapper doesn't write. Recommended: add it there.
3. **Swagger UI from a CDN** (unpkg, `swagger-ui-dist@5`, as the origin): the page needs
   internet in the browser that opens it; the API itself doesn't. The alternative is shipping
   the UI's files (~1.5 MB) in the executable as resources. Recommended: CDN now, pinned to an
   exact version.
4. **Query parameters from a Find DTO** (`.QueryParams<ICityFind>`, one parameter per published
   property): saves repeating `QueryParam` per field. Recommended: yes, as an addition after the
   core works.

## How it will be tested

- Unit (both compilers): the exact JSON of small documents and schemas (every row of the table
  above, nested DTOs, arrays, metadata, errors), and that `Prop` with an unknown name raises.
- HTTP: both samples document their routes; the scenarios fetch `/swagger/doc.json` and check
  it, and CI validates it with `openapi-spec-validator` (Python, in the Linux container).
- Delphi Win32/Win64 as always.

## Not in this phase

MCP (phase 5), security schemes in the document (Bearer/JWT: small, can come right after),
callbacks/webhooks, multiple servers.
