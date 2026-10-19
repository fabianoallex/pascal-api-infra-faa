# Validation — design

Status: **built** (pascal-common-faa 1.21.0, pascal-api-infra-faa 0.20.0; F3 adopted in
pascal-agenda-faa, 333 HTTP checks on the four targets; F4 in the skill), 2026-10-19.
Four decisions taken with the user (below). The open points were settled as proposed: `Required`
by hand for plain members; the edge checks the raw value (sample 02's PATCH sends `"rn"`, not
`" rn"`, which a `MaxLength(2)` refuses); `Pattern` documented only; `error` holds the first
field's message. Found while building: the edge answers before the repository, so a request that
breaks a limit and a rule hears of the limits first.

## Why

pascal-agenda-faa, the first application on this library, ended up with three layers in every
repository (its `docs/design.md`, "Repositories: normalize, then validate, then bind"):

1. normalize inside the optionals with its `TNorm` factory (pascal-common-faa's normalizers);
2. validate with its own `Agenda.Validation`: `ValidateName`, `ValidateEmail`, `ValidatePhone`,
   each written three times (a required `string`, an `IOptString` checked when it came, an
   `IOptNullString` checked when it came with a value), plus each repository's rules
   (`ValidateDuration`, `ValidatePrice`, `ValidateRole`...);
3. bind the optionals next to their `ProcessTag`.

Layers 1 and 3 come from the libraries. Layer 2 doesn't, and every application would write it
again: the three overloads per rule, the same "at most N characters", "from A to B", "multiple
of 5", the messages, one 400 at a time. And the limits are written twice: the OpenAPI document
declares them (`TApiSchema.Describe(...).Prop('Name').MaxLength(100)`, `Minimum`, `Maximum`) and
the repository checks the same numbers by hand (sample 02 says so: "the document describes them,
only this enforces them").

## Decisions (user, 2026-10-19)

1. **The core lives in pascal-common-faa, next to the normalizers; this library maps it to HTTP.**
   The validators know nothing of HTTP: they raise a neutral error. A queue consumer
   (pascal-amqp-faa), a desktop client (pascal-agenda-faa's M6) or a pipe server validate the same
   DTO the same way; `TErrorHandlerMiddleware` turns the error into a 400.
2. **What the OpenAPI document declares is enforced.** `MinLength`, `MaxLength`, `Minimum`,
   `Maximum` and `Enum` on a `TApiSchema.Describe` are checked, not only documented: a limit
   written once is documented and enforced. The application's validators cover what the schema
   can't say (a phone, an email, a row that must exist, one member against another).
3. **Every failing field in one answer.** Validation collects the problems and raises once; the
   400 lists them. `error` and `code` stay in the body, so a client that reads only those keeps
   working.
4. **Translatable messages**, as `TApiMessages`: English by default, Portuguese ready, replaced at
   startup; each message gets the field's name (its JSON name).

## The shape (proposal)

### pascal-common-faa: `PascalCommon.Validators`

The mirror of `PascalCommon.Normalizers`: one validator interface per type and one factory class
per type, which an application inherits to add its rules (`TValid = class(TPcStringValidators)`).

```pascal
IPcStringValidator = interface
  /// '' when AValue passes; else the error code, AMessage filled (AField in it).
  function Check(const AField, AValue: string; out AMessage: string): string;
end;

TPcStringValidators = class
  class function Required: IPcStringValidator;            // something besides blanks
  class function MinLength(AChars: Integer): IPcStringValidator;
  class function MaxLength(AChars: Integer): IPcStringValidator;
  class function OneOf(const AValues: array of string): IPcStringValidator;
  class function FromFunc(AFunc: TPcStringCheckFunc): IPcStringValidator;  // the app's rule
  class function All(const AValidators: array of IPcStringValidator): IPcStringValidator;
end;
// The same for Integer, Int64, Double, Currency, TDateTime: Range(AMin, AMax), Min, Max,
// MultipleOf (integers), MaxDecimals (Currency, Double), OneOf, FromFunc, All.
```

- Lengths count **characters (Unicode code points)**, the same on both compilers, as JSON
  Schema's `maxLength`: FPC's `Length` counts UTF-8 bytes and Delphi's UTF-16 units.
  pascal-api-infra-faa's `PaCharCount` does this today; it moves to pascal-common-faa
  (`PcCharCount`) with a wrapper here.
- `All` stops at the first failing rule of a field: one error per field.
- `FromFunc` takes a plain function (FPC 3.2.2 has no closures); a rule with state (a row that
  must exist in this tenant) is a class implementing the interface, as normalizers do.

The collector, a record (no `try/finally`), with one overload per shape of member, so the
"absent: not checked; null: not checked; value: checked" rule lives once, in the library:

```pascal
var
  LCheck: TPcValidation;
begin
  LCheck := TPcValidation.Create;
  LCheck.Check('name', LName, TValid.DisplayName);       // string, IOptString, IOptNullString
  LCheck.Check('durationMinutes', APatch.DurationMinutes, TValid.Duration);
  LCheck.Check('phone', LPhone, TValid.Phone);
  if LStart >= LEnd then
    LCheck.Fail('endsAt', 'before_start', '"endsAt" must come after "startsAt".');
  LCheck.RaiseIfAny;   // EPcValidationError with every failure, or nothing
end;
```

`EPcValidationError` carries `Errors: TArray<TPcFieldError>` (`Field`, `Code`, `Message`); its
`Message` is the first error's, so a log line or an untyped handler still says something useful.

Messages: `TPcValidationMessages` (a record like `TApiMessages`: `English`, `Portuguese`,
`Current`), one entry per built-in code (`required`, `too_short`, `too_long`, `out_of_range`,
`not_multiple`, `too_many_decimals`, `not_allowed`), `Format` placeholders for the field and the
limits.

### pascal-api-infra-faa

- **The error handler** maps `EPcValidationError` to 400:
  `{"error": <first message>, "code": "invalid_fields", "requestId": ..., "fields": [{"field":
  ..., "code": ..., "message": ...}]}`. `EValidationException` stays for a single business refusal
  (`own_account`, `unknown_professional`).
- **The schema enforces its metadata**: `TApiSchema.Check(AInterface, ADto, var AValidation)`
  walks the DTO's members through the mapper (JSON names, the same list the document is built
  from) and adds what `MinLength`/`MaxLength`/`Minimum`/`Maximum`/`Enum` say. Optional members
  are checked only when they came.
- **Where it runs**: at the edge, on the DTO as it arrived, because the document is the contract
  of the wire: `THorseBody.Read<I>(AReq)` (`FromJson` + `TApiSchema.Check` + `RaiseIfAny`) for a
  body, and `THorseQueryParams.Read<I>` (0.19.0) gains the same check. The repository then
  normalizes and runs only the application's rules.
- **The document**: the 400 response's schema gains `fields`.

### What the application keeps

- Its normalizers (`TNorm`), its business validators (`TValid = class(TPcStringValidators)`:
  `Phone`, `Email`, a row that must exist), cross-field rules (`Fail`).
- The order in a repository: normalize, then `TPcValidation` with the business rules, then bind.

## Open points (to settle in F1/F2)

- **Required members.** A plain member that didn't come keeps its default (`''`, `0`): the
  mapper can't tell "absent" from "empty". The document lists non-optional members as required;
  enforcing that needs either the mapper to report absent members (a pascal-jsonmapper-faa
  change) or `MinLength(1)`/`Required` written by hand. Proposal: leave it to `Required` in F1,
  measure how often it bites.
- **Before or after normalizing.** The schema checks the raw value (`"  Ana  "` counts 7
  characters for `MaxLength`); the application's rules see the normalized one. Proposal: accept
  it (the document describes the wire), say it in the guide.
- **`Pattern`** is documented, not enforced: a regular expression engine with the same dialect on
  both compilers isn't in either RTL's common ground (FPC's `RegExpr`, Delphi's
  `System.RegularExpressions`). An application rule (`FromFunc`) covers a format meanwhile.
- **`error` when several fields fail**: the first field's message (proposed, compatible with
  clients that show `error`) or a generic "Invalid data.".
- **RFC 9457** (`application/problem+json`) stays a separate candidate (`docs/plan.md`); the
  `fields` list maps onto its extension members if it comes.

## Phases

| # | Where | What | Done when |
|---|---|---|---|
| F1 | pascal-common-faa | `PascalCommon.Validators` (validators per type, factories, `TPcValidation`, `EPcValidationError`, messages en/pt), `PcCharCount` | unit tests on FPC Windows/Linux and Delphi Win32/Win64, 0 leaks; release 1.21.0 |
| F2 | here | error handler mapping, `TApiSchema.Check`, `THorseBody.Read<I>`, the query check, the 400 schema; sample 02 validating through them (its hand-written limits removed); guides `dtos-json.md`, `errors.md`, `database.md` | HTTP scenarios on the four targets; release 0.20.0 |
| F3 | pascal-agenda-faa | `Agenda.Validation` replaced by `TValid` and the schema's limits (`Describe` already declares most of them); its scenarios assert the `fields` list | 323+ HTTP checks on the four targets |
| F4 | skill | `using-faa-libraries/references/repository-patterns.md` on the new shape; the starter template (a later decision) | — |
