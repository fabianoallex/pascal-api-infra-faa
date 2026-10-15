# Database access

A handler that reads and writes a real database: the connection, the SQL, paging and ordering in
the query, filters, transactions, migrations and what each database error becomes. The database
layer is [pascal-db-faa](https://github.com/fabianoallex/pascal-db-faa), which has its own guides
(`external/pascal-db-faa/docs/`); this one covers using it from an API. The code comes from
`samples/02-db` (SQLite: SQLdb on FPC, FireDAC on Delphi), which `tools/http_scenarios_db.sh`
checks over HTTP. A few behaviours below were measured on that sample for this guide (FPC
3.2.2/Windows, 2026-10-14), and each one says so; the two answers under the smallest program
were measured the same way.

## What it solves

An API's handlers run on many threads at once, each needing a connection for a moment. The SQL
must be written once per database, filled from the client's input without ever letting that
input become SQL, and run inside a transaction that is undone when something fails. The schema
must reach every environment in the same order. And when the database refuses something (a
duplicate key, a lost connection), the client needs an answer it can act on, without the
driver's text.

pascal-db-faa gives you the pool, the SQL by key with templates, the migrations and the
classification of the drivers' errors; this library turns those errors into HTTP answers and
the client's paging and ordering into the query.

## The smallest working program

A repository with one query, from `samples/02-db/DbApiSample.Cities.pas`, shortened:

```pascal
function TCityRepository.FindByCode(const ACode: string): ICity;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LResult: IQueryResult;
begin
  Result := nil;
  LScope := FFactory.GetPool.AcquireQuery(LQuery);   // a pooled connection and its transaction
  LScope.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader['CITY.BY_CODE'].SQL;
    LQuery.Params.Strings['CODE'] := ACode;
    LResult := LQuery.Open;
    if not LResult.Eof then
      Result := ReadCity(LResult);
    LScope.Commit;
  except
    LScope.Rollback;
    raise;
  end;
  if Result = nil then
    raise ENotFoundException.Create(Format('City %s not found.', [ACode]));
end;   // LQuery and LScope released: the connection goes back to the pool
```

and the handler:

```pascal
procedure GetCity(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  TJsonSend.Send(ARes, TJsonMapper.Shared.ToJson<ICity>(GCities.FindByCode(AReq.Params['code'])));
end;
```

```
GET /cities/3550308   200  {"code":"3550308","name":"São Paulo","state":"SP","population":11451999}
GET /cities/0000000   404  {"error":"City 0000000 not found."}
```

## Step by step

### 1. The factory: one per database, created at startup

```pascal
function NewFactory(const ADatabaseFile: string): IDBFactory;
var
  LConfig: IDatabaseConfig; // an interface variable, never a class one (pascal-db-faa's rule)
begin
  LConfig := TDatabaseConfig.Create;
  {$IFDEF FPC}
  LConfig.ConnectionParams.Values['ConnectorType'] := 'SQLite3';
  LConfig.ConnectionParams.Values['DatabaseName'] := ADatabaseFile;
  LConfig.ConnectionParams.Values['ClientLibrary'] := TAppConfig.Get('SQLITE_CLIENT', '');
  {$ELSE}
  LConfig.ConnectionParams.Values['DriverID'] := 'SQLite';
  LConfig.ConnectionParams.Values['Database'] := ADatabaseFile;
  {$ENDIF}
  LConfig.SQLDialect := 'SQLite';
  LConfig.SQLDirectory := 'SQLITE';
  LConfig.SqlSource := CitySqlSource;
  LConfig.PoolIniConnections := 1;
  LConfig.PoolMaxConnections := 5;
  LConfig.PoolWaitMaxAttemps := 50;
  LConfig.PoolWaitMilliseconds := 100;
  {$IFDEF FPC}
  Result := TSQLdbFactory.Create(LConfig);
  {$ELSE}
  Result := TFDFactory.Create(LConfig);
  {$ENDIF}
end;
```

The factory (`IDBFactory`) holds the pool and the SQL loader, and is shared by every thread; a
connection, a query and a scope belong to one request. Create the factory once, at startup, read
its settings from the configuration ([Configuration](configuration.md)), and keep it for the
life of the program. The `{$IFDEF FPC}` is the adapter: SQLdb on FPC and FireDAC on Delphi here;
Zeos works on both (pascal-db-faa's `docs/adapters.md`).

Size `PoolMaxConnections` to what the database accepts from this program, not to Horse's
threads: a request that waits a little for a connection is normal (pascal-db-faa's
`docs/pool.md`). How long it may wait is `PoolWaitMaxAttemps` × `PoolWaitMilliseconds`, 5 s here
(step 7 says what happens after that).

### 2. Run the migrations before listening

```pascal
GFactory := NewFactory(GFile);
GEngine := TDBMigrationEngine.Create(GFactory, GLog.Migration);
try
  GEngine.Execute(CityMigrations);
  Writeln('database ', GFile, ' at version ', GEngine.CurrentVersion);
finally
  GEngine.Free;
end;
GCities := TCityRepository.Create(GFactory);
...
THorse.Listen(GPort);
```

Each migration is a numbered script; the engine records the applied ones in
`SCHEMA_MIGRATIONS` and runs only the new ones, in order. Measured on sample 02: the first start
printed `migration 1`, `2` and `3`, a second start (without `--reset`) printed none and the same
`at version 3`. DDL and data go in separate migrations (`IsDDL`, pascal-db-faa's
`docs/migrations.md`):

```pascal
Result[0] := Item(1, 'MIG.0001', True);    // SCHEMA_MIGRATIONS (DDL)
Result[1] := Item(2, 'MIG.0002', True);    // CITIES (DDL)
Result[2] := Item(3, 'MIG.0003', False);   // seed rows (data)
```

A migration that fails raises out of `Execute`, so the program stops before `Listen` and no
request reaches a half-migrated schema (from the code; not measured with a failing script).

### 3. SQL by key

The SQL lives outside the Pascal code, under a key. Sample 02 registers it in code to stay in two
files:

```pascal
LSource := TMemorySqlSource.Create;
LSource
  .Add(DIR, 'CITY.BY_CODE', 'SELECT CODE, NAME, STATE, POPULATION FROM CITIES WHERE CODE = :CODE')
  .Add(DIR, 'CITY.INSERT',
    'INSERT INTO CITIES (CODE, NAME, STATE [POPULATION {], POPULATION [} POPULATION]) ' +
    'VALUES (:CODE, :NAME, :STATE [POPULATION {], :POPULATION [} POPULATION])')
  ...
```

An application usually keeps one `.sql` file per key and embeds them in the executable as
resources (`python tools/build_sql_res.py sql/ sql/app.res` in pascal-db-faa, then
`{$R 'sql\app.res'}`), so the SQL can't drift from the code in production. See pascal-db-faa's
`docs/sql.md`.

**Every value from the client is a parameter** (`:CODE`), never text joined into the SQL.
Measured on sample 02: `GET /cities?state=' OR 1=1 --` answered 200 with `"total":0`, since the
state is a parameter and no city has that state.

### 4. Paging and ordering in the query

From `samples/02-db`, the handler turns the query string into a page request, and the repository
runs a `COUNT` and the page in one transaction:

```pascal
procedure GetCities(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LFind: ICityFind;
  LPage: TPage<ICity>;
begin
  LFind := TCityFind.Create;
  LFind.Page := ParseQueryInt('page', AReq.Query['page']);    // 400 unless digits
  LFind.Limit := ParseQueryInt('limit', AReq.Query['limit']);
  LFind.OrderBy := ParseQueryStr(AReq.Query['orderBy']);
  LFind.SetState(ParseQueryStr(AReq.Query['state']));
  LPage := GCities.FindPage(LFind.GetState, LFind.OrderBy.Value,
    PageRequestFrom(LFind.Page, LFind.Limit, 2, 50));          // default 2, at most 50
  TJsonSend.Send(ARes, PageEnvelopeJson(LPage.Meta,
    TJsonMapper.Shared.Serialize<TCityArray>(LPage.Items)));
end;
```

```sql
-- CITY.COUNT
SELECT COUNT(*) AS TOTAL FROM CITIES WHERE 1 = 1 [STATE {] AND STATE = :STATE [} STATE]
-- CITY.PAGE
SELECT CODE, NAME, STATE, POPULATION FROM CITIES WHERE 1 = 1
  [STATE {] AND STATE = :STATE [} STATE] ORDER BY ${ORDER} ${PAGE}
```

```pascal
LOrder := CityOrderSpec.Build(AOrderBy); // before touching the database: 400 if invalid
LScope := FFactory.GetPool.AcquireQuery(LQuery);
LScope.StartTransaction;
try
  LQuery.Sql := FFactory.SqlLoader['CITY.COUNT'].ProcessTag('STATE', AState.HasValue).SQL;
  if AState.HasValue then
    LQuery.Params.Strings['STATE'] := UpperCase(AState.Value);
  Result.Meta := TPageMeta.Create(APage, LQuery.Open.Int64s['TOTAL']);

  LQuery.Sql := FFactory.SqlLoader['CITY.PAGE'].ProcessTag('STATE', AState.HasValue)
    .ReplaceLiteral('ORDER', LOrder).ReplaceLiteral('PAGE', PdbPagingClause(LScope, APage)).SQL;
  ...
```

- **`${ORDER}`** comes from `TOrderBySpec` (`PascalApi.OrderBy`), an allow-list from the client's
  names to columns, never the client's text:

  ```pascal
  Result := TOrderBySpec.New
    .Allow('name', 'NAME').Allow('state', 'STATE').Allow('population', 'POPULATION')
    .Default('name')
    .AlwaysLast('CODE');      // a unique tiebreaker, so pages don't overlap
  ```

  Measured on sample 02: `orderBy=name;DROP TABLE CITIES` answered 400 `Invalid order field:
  "name;DROP TABLE CITIES". Available: name, state, population`; `orderBy=-name,population` was
  accepted. Build it before acquiring a connection: an invalid order then costs no database
  work.
- **`${PAGE}`** is the dialect's clause (`LIMIT/OFFSET`, `OFFSET/FETCH`, `ROWS`), from
  `PdbPagingClause`, with the numbers as integer literals.
- **`[STATE {] ... [} STATE]`** is a block kept only when the filter came
  (`ProcessTag('STATE', HasValue)`); set its parameter under the same condition.
- **One transaction for both queries**, so the total and the page see the same data.

What the client may send (`PageRequestFrom`, checked by `tools/http_scenarios_db.sh` and measured
on sample 02):

| Query string | Becomes |
|---|---|
| none | page 1, limit 2 (the sample's default) |
| `limit=500` | limit 50, the maximum (checked) |
| `page=0`, `page=-1`, `page=abc` | page 1 (measured) |
| `limit=0`, `limit=-5` | the default limit (measured) |
| `page=99` (past the end) | 200, no items, `"hasNext":false,"hasPrev":true` (measured) |

The answer is the same envelope as in [Getting started](getting-started.md), step 6:
`{"page":1,"limit":2,"total":6,"totalPages":3,"hasNext":true,"hasPrev":false,"items":[...]}`.

### 5. Writing: validate, then let the database decide

From `TCityRepository.Insert`:

```pascal
if Trim(ACity.GetName) = '' then
  raise EValidationException.Create('"name" is required.');
...
LScope := FFactory.GetPool.AcquireQuery(LQuery);
LScope.StartTransaction;
try
  LQuery.Sql := FFactory.SqlLoader['CITY.INSERT']
    .ProcessTag('POPULATION', ACity.GetPopulation.HasValue).SQL;
  LQuery.Params.Strings['CODE'] := LCode;
  ...
  // No if: absent, the column and its parameter are gone (the database
  // writes NULL); present, the value is bound.
  LQuery.Params.OptIntegers['POPULATION'] := ACity.GetPopulation;
  LQuery.ExecSql; // EConstraintViolationException (cvUnique) -> 409
  LScope.Commit;
except
  LScope.Rollback;
  raise;
end;
```

- Check what a request can get wrong before acquiring a connection (`EValidationException`, 400).
- **Don't check for a duplicate with a `SELECT` first**: two requests can pass that check at the
  same time. The primary key decides, and its `EConstraintViolationException` is a 409 (checked:
  "duplicate code").
- **Bind every parameter in the SQL.** An unbound one doesn't raise everywhere: on SQLdb/SQLite
  an unbound `:TENANT_ID` silently matched nothing (measured for [Multi-tenancy](multitenancy.md)).
  The `OptNullIntegers` above binds NULL on purpose.
- `ExecSql` returns the rows affected; `Delete` answers 404 when it is 0:

  ```pascal
  LRows := LQuery.ExecSql;
  ...
  if LRows = 0 then
    raise ENotFoundException.Create(Format('City %s not found.', [ACode]));
  ```

### 6. Transactions

Every repository method in the sample has the same shape: acquire, `StartTransaction`, work,
`Commit`, and in the `except`, `Rollback` and `raise`. The re-raise is what lets the error
handler answer (step 7); the rollback is what keeps a half-done change out of the database
(pascal-db-faa's `docs/errors.md`: a batch whose second insert fails leaves none of it).

Raise `ENotFoundException` *after* the `try` block, as `FindByCode` does: finding nothing isn't
a failure of the transaction, so it commits, and only then does the request fail.

The scope is released when the method ends, and the connection with it. Don't keep a query or a
scope in a field, and don't pass them to another thread.

### 7. What the database's errors become

The error handler maps pascal-db-faa's exceptions ([Errors and validation](errors.md), step 3,
has the whole table):

| pascal-db-faa raises | Status | Logged |
|---|---|---|
| `EConstraintViolationException`: unique, foreign key | 409 | no |
| `EConstraintViolationException`: NOT NULL, CHECK | 422 | yes |
| `ELockConflictException` | 409 | yes |
| `EDatabaseUnavailableException` (also `EDatabaseConnectException`) | 503 | yes |
| `EPoolTimeoutException` (every connection busy for the whole wait) | 503 `ServerBusy` | yes |

None sends the driver's or the pool's text to the client; the log line has it. **Until 0.13.0 a
pool timeout was a 500**; it is now a 503 with "The server is busy. Try again shortly." (tested,
and checked over HTTP by sample 01's `/fail/busy`). Frequent ones in the log mean the pool or the
database is too small for the load.

pascal-db-faa doesn't retry. If an operation is safe to repeat, repeat the whole unit of work
(acquire, transaction, commit), bounded by time (pascal-db-faa's `docs/errors.md`, "Trying again
after an outage").

### 8. Health, metrics and spans

- **Readiness**: a check that runs a query through the pool. From sample 02:

  ```pascal
  function TSampleLog.DatabaseReady: Boolean;
  var
    LQuery: IQuery;
    LScope: IScopeTransaction;
  begin
    LScope := GFactory.GetPool.AcquireQuery(LQuery);
    LQuery.Sql := 'SELECT 1 AS ONE';
    Result := LQuery.Open.RecordCount = 1;
  end;

  THealthEndpoint.AddCheck('database', GLog.DatabaseReady);
  THealthEndpoint.Register('/health', GLog.Error);
  ```

  `GET /health/ready` answers `{"status":"ok","checks":{"database":"ok"}}` (checked); a check that
  returns False or raises makes it 503.
- **Metrics**: the pool publishes `db.client.connection.*` (count by state, max, wait time) on the
  same `/metrics` as the HTTP metrics; the scenario checks them.
- **Spans**: with tracing on, each statement is a span under the request's span (CI checks
  sample 02's database spans with a real OpenTelemetry Collector). [Logging and observability](observability.md)
  covers all three.

## Choices

### Which adapter

SQLdb (FPC only), FireDAC (Delphi only) or Zeos (both). Sample 02 uses SQLdb and FireDAC behind
an `{$IFDEF}`; with Zeos the same code needs no `{$IFDEF}`. pascal-db-faa's `docs/adapters.md`
lists what each one was tested on (Firebird, PostgreSQL, SQLite, MySQL, MariaDB, SQL Server).

### SQL in resources or in a folder

Resources (the default `TResourceSqlSource`) for production: one executable. A folder
(`TDirectorySqlSource`) while developing, to edit SQL without rebuilding;
`TCompositeSqlSource` combines them (folder first, then resources).

### SQLite

Fine for a sample, a small internal API or tests. It has one writer at a time: the adapters set
a busy timeout (5 s), so a second writer waits instead of failing at once. Use a file, never
`:memory:` (each pooled connection would get its own empty database). SQLite doesn't enforce a
column's length: a 150-character name went into `VARCHAR(100)` through SQLdb and FireDAC alike.
Before pascal-db-faa 0.14.1, FireDAC then refused to *read* the row (`[FireDAC][DatS]-32 ...
overflow`), a 500 for every request that touched it (measured, sample 02, Delphi 12 Win32); 0.14.1
reads it whole, as SQLdb does. Check lengths before writing ([OpenAPI](openapi.md), step 5), and
to have the database refuse such a value, declare `CHECK (length(NAME) <= 100)` in the
migration: the insert then raises `EConstraintViolationException` with `cvCheck` (measured by
pascal-db-faa on its three adapters, gotcha 50), which this library answers 422 and logs
([Errors and validation](errors.md)). SQLite's `STRICT` tables don't help: they refuse
`VARCHAR(n)` itself (pascal-db-faa's measurement). Before pascal-db-faa 0.14.2, FireDAC on SQLite
also dropped trailing spaces, on write and on read: a stored `'Spaces  '` came back as `"Spaces"`
on Delphi and whole on FPC (measured, sample 02); 0.14.2 keeps them on both. On FPC for Windows, the
`sqlite3.dll` must be sqlite.org's build (pascal-db-faa's gotcha 23): `tools/test_http.sh` takes
it from `SQLITE_DLL` or `.deps/`.

## Pitfalls

- **Text from the client in the SQL**: a filter, a column name, an `ORDER BY` direction. Use a
  parameter, a tag block or `TOrderBySpec` (steps 3 and 4).
- **A parameter left unbound** (step 5).
- **Forgetting `Rollback; raise;`**: without the `raise`, the client gets a success for work that
  was undone; without the `Rollback`, the transaction stays open on a pooled connection.
- **A `SELECT` to check for duplicates** instead of the key (step 5).
- **A value longer than its column** on SQLite with FireDAC: stored, then unreadable (SQLite,
  under Choices).
- **`PoolMaxConnections` sized to the threads**, or a pool wait so long that requests pile up;
  a pool timeout is now a 503 (step 7).
- **`IDatabaseConfig` in a class variable**: it is reference-counted; mixing the two frees it
  early (pascal-db-faa's rule; the samples use an interface variable).
- **FPC without `SetMultiByteConversionCodePage(CP_UTF8)`**: non-ASCII text from the database
  comes out wrong ([Getting started](getting-started.md), step 2); the sample's `Belém` and
  `São Paulo` are checked over HTTP.

## Testing your application

**Without a database**: pascal-db-faa's `TMockDBFactory` records what was executed and returns
the results you give it. From `PascalApi.TenancyTests`:

```pascal
LMock := TMockDBFactory.Create;
LCatalog := TDbTenantCatalog.Create(LMock);
LMock.AddResult('TENANT.BY_ID', TMockQueryResult.SingleRow(['ID', 'MODE', 'SUSPENDED', 'PLAN'],
  [AId, AMode, 0, Null]));
...
TAssert.AssertEquals('initech', LMock.LastExecution(EXPECTED).AsString('TENANT_ID'));
```

pascal-db-faa's `docs/testing-with-the-mock.md` covers canned results, simulated errors and rows
affected. It checks your SQL keys and parameters, not the SQL itself.

**With the database**: start the program on a fresh database and check over HTTP, as
`tools/test_http.sh` does with `DbApiSample.exe 9330 --reset` and `tools/http_scenarios_db.sh`:
paging, ordering, the filter, the 409 from the key, the 400s, readiness and the pool metrics.

## Reference

- `samples/02-db`: `DbApiSample.dpr` (factory, migrations, handlers, health) and
  `DbApiSample.Cities.pas` (DTOs, SQL, migrations, repository); `tools/http_scenarios_db.sh`.
- `PascalApi.Pagination` (`ParseQueryInt`, `PageRequestFrom`, `PageEnvelopeJson`),
  `PascalApi.OrderBy` (`TOrderBySpec`), `PascalApi.Http` (`MapException`).
- pascal-db-faa's guides, `external/pascal-db-faa/docs/`: getting started, SQL by key, the pool,
  errors, migrations, optionals, adapters, the mock, gotchas.
- [Multi-tenancy](multitenancy.md): the same repositories with a tenant filter.
