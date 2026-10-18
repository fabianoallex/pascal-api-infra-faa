# Multi-tenancy

One API serving several customers (tenants), each of them seeing only its own data. This guide
builds such an API step by step. The code comes from `samples/03-tenants`, which compiles on
Delphi and FPC and is checked over HTTP by `tools/http_scenarios_tenants.sh` (94 checks, most of
them one tenant trying to reach another's rows).

Why it works this way, and what was measured on the way: [the design](../multitenancy-design.md).

## What it solves

Every request has to answer two questions before it touches data: *which tenant is calling?*
and *where is that tenant's data?* Getting either one wrong shows one customer's data to
another.

The library answers them like this:

- **Which tenant:** the tenant comes from a claim in the request's JWT (`tenant_id`). Your
  login route puts it there, and the signature keeps clients from changing it. A header, the
  host name or a body field can't name a tenant: the claim is the only source.
- **Where its data is:** each tenant has a mode. A *dedicated* tenant has a database of its own.
  A *shared* tenant shares one database with others, and its rows have its id in a `TENANT_ID`
  column. Both modes can be used in the same application.
- **The guard:** every query filters by `TENANT_ID`, in both modes, through one call that sets
  the condition and its value together.

It is opt-in. An application that doesn't use the two tenancy units sees no change.

What stays with your application: creating the tenants' databases and running their migrations,
the login route, and managing the list of tenants (an admin API, a back office, a script).

## The pieces

| Piece | Unit | What it does |
|---|---|---|
| `ITenantCatalog` | `PascalApi.Tenancy` | which tenants exist: id, mode, suspended, plan |
| `TTenantMiddleware` | `PascalApi.Horse.Tenancy` | reads the claim, checks it against the catalog, answers 401/403 or lets the request through |
| `ITenantDataResolver` | `PascalApi.Tenancy` | from a tenant to a `TTenantDataScope`: the database (an `IDBFactory`) and the `TENANT_ID` value |
| `TTenantFilter.Prepare` | `PascalApi.Tenancy` | loads a named SQL, puts in the `TENANT_ID` condition and binds its value, in one call |

A request goes through them in this order:

```
JWT middleware      the token is valid             (401 otherwise)
Tenant middleware   its tenant_id is in the catalog  (401 unknown, 403 suspended)
handler             TTenantMiddleware.Current(Req)  -> TTenantInfo
                    Resolver.ScopeFor(Info)         -> TTenantDataScope
repository          TTenantFilter.Prepare(Query, Scope, 'CITY.LIST')
```

## The smallest working program

Two tenants in the configuration, both sharing one database (a sketch: the steps below fill in
`NewFactory`, the login route and the handlers):

```pascal
uses
  Horse, PascalDb.Interfaces, PascalApi.Horse.Middlewares,
  PascalApi.Tenancy, PascalApi.Horse.Tenancy;

var
  GCatalog: ITenantCatalog;
  GResolver: ITenantDataResolver;
  GHooks: TAppHooks;   // your class: NewFactory (step 3)

begin
  GHooks := TAppHooks.Create;
  GCatalog := TConfigTenantCatalog.Create('acme=shared;initech=shared');
  GResolver := TTenantDataResolver.Create(GHooks.NewFactory);

  THorse.Use(TJwtMiddleware.New(Secret, ['/health', '/auth/login']));
  THorse.Use(TTenantMiddleware.New(GCatalog));    // after the JWT middleware
  THorse.Get('/cities', GetCities);               // uses TTenantMiddleware.Current
  THorse.Listen(9000);
end.
```

## Step by step

### 1. Design the tables

Every table that holds a tenant's data has a `TENANT_ID` column, and it is part of the primary
key and of the unique keys. That way two tenants can both have a city with code `4205407` in the
shared database, and a duplicate is still caught within one tenant.

```sql
CREATE TABLE CITIES (
  TENANT_ID VARCHAR(40) NOT NULL,
  CODE      VARCHAR(7)  NOT NULL,
  NAME      VARCHAR(100) NOT NULL,
  STATE     VARCHAR(2)  NOT NULL,
  POPULATION INTEGER,
  CONSTRAINT PK_CITIES PRIMARY KEY (TENANT_ID, CODE));
```

Put the column in a dedicated tenant's database too, even though there it always has the same
value. The same tables and the same SQL then serve both modes, and moving a tenant between modes
is a data copy, not a rewrite. If your tenants will only ever be dedicated, see
[Choices](#a-tenant_id-column-in-dedicated-databases-too).

A table that isn't tenant data (a list of countries every tenant reads) doesn't need the column.

### 2. Write the SQL with the `${TENANT}` tag

In the SQL that reads, changes or deletes a tenant's rows, write `${TENANT}` where the condition
goes. In an `INSERT`, write the `:TENANT_ID` parameter yourself:

```pascal
LSource
  .Add('SQLITE', 'CITY.LIST',
    'SELECT CODE, NAME, STATE, POPULATION FROM CITIES WHERE ${TENANT} ORDER BY NAME, CODE')
  .Add('SQLITE', 'CITY.BY_CODE',
    'SELECT CODE, NAME, STATE, POPULATION FROM CITIES WHERE CODE = :CODE AND ${TENANT}')
  .Add('SQLITE', 'CITY.INSERT',
    'INSERT INTO CITIES (TENANT_ID, CODE, NAME, STATE[POPULATION {], POPULATION[} POPULATION]) ' +
    'VALUES (:TENANT_ID, :CODE, :NAME, :STATE[POPULATION {], :POPULATION[} POPULATION])')
  .Add('SQLITE', 'CITY.DELETE', 'DELETE FROM CITIES WHERE CODE = :CODE AND ${TENANT}');
```

`TTenantFilter.Prepare` replaces `${TENANT}` with `TENANT_ID = :TENANT_ID` and binds
`:TENANT_ID` whenever the SQL has it, whether it came from the tag or was written by hand. When
the SQL has blocks to keep or drop first (a column per optional member, as `CITY.INSERT`'s
population), pass the processed SQL instead of its name; the tenant's condition and parameter
still come in the same call:

```pascal
TTenantFilter.Prepare(LQuery, FScope, FScope.Factory.SqlLoader['CITY.INSERT']
  .ProcessTag('POPULATION', ACity.GetPopulation.HasValue));
...
LQuery.Params.OptIntegers['POPULATION'] := ACity.GetPopulation;   // absent: column gone, NULL
```

Take that SQL from the scope's own factory (`FScope.Factory.SqlLoader`): another factory's may be
another database's dialect. Tested in `PascalApi.TenancyTests` (`Filter_PrepareProcessedSql_*`).

**In a JOIN, give every table that has the column its own tag, with its alias:**
`${TENANT.c}` becomes `c.TENANT_ID = :TENANT_ID`. The joined table's tag goes in its `ON`:

```pascal
  .Add('SQLITE', 'CITY.DETAILS',
    'SELECT c.CODE, c.NAME, c.STATE, s.NAME AS STATE_NAME FROM CITIES c ' +
    'LEFT JOIN STATES s ON s.CODE = c.STATE AND ${TENANT.s} ' +
    'WHERE c.CODE = :CODE AND ${TENANT.c}')
```

Both conditions use the same `:TENANT_ID`, bound once. Measured on SQLite with two tenants that
both have the state `RS`:

| SQL | Result |
|---|---|
| plain `${TENANT}` | rejected: `ambiguous column name: TENANT_ID` |
| `${TENANT.c}` only | the city **twice**: once with its tenant's state, once with the other tenant's |
| `${TENANT.c}` and `${TENANT.s}` in `ON` | the city once, with its tenant's state |

The second line is the dangerous one: the query runs and the tenant's own rows are filtered, but
the joined columns come from every tenant. In a `LEFT JOIN`, `${TENANT.s}` must be in `ON`: in
`WHERE` it would drop the rows without a match. A tag whose alias isn't an identifier
(`${TENANT.c d}`) is left as it is, so the database rejects the SQL.

The SQL above is the sample's `GET /cities/:code/details`. Its checks in
`tools/http_scenarios_tenants.sh` register a state in one tenant and read a city of another on
the shared database: without `${TENANT.s}` in `ON`, the city came with the other tenant's state
(2 checks failed); with it in `WHERE`, the city without a state answered 404 (3 failed).

If you write your SQL in a Pascal comment, use `(* ... *)`: the `}` of `${TENANT}` closes a
`{ ... }` comment.

### 3. Create a database for each tenant: `NewFactory`

The resolver needs to know how to open a database. You give it a function that returns an
`IDBFactory` (pascal-db-faa) for a database key: `'tenant_<id>'` for a dedicated tenant,
`'shared'` for the shared one. The resolver calls it the first time a database is needed, and
keeps the factory and its pool.

```pascal
type
  // On FPC the library's callbacks are methods ("of object"); on Delphi they are
  // "reference to". A method of a class works on both.
  TAppHooks = class
  public
    function NewFactory(const ADatabaseKey, APoolName: string): IDBFactory;
  end;

function TAppHooks.NewFactory(const ADatabaseKey, APoolName: string): IDBFactory;
begin
  // The sample: one SQLite file per database, in DATA_DIR.
  Result := NewSqliteFactory(GDataDir + ADatabaseKey + '.sqlite', APoolName, CitySqlSource);
end;
```

`NewSqliteFactory` (in the sample) fills an `IDatabaseConfig` and creates the adapter's factory.
Two things matter for tenancy:

- `LConfig.PoolName := APoolName;`: pools are named `dedicated` or `shared`, never after the
  tenant, so the pool metrics don't grow a series per customer.
- The SQL source is the same for every database, so a repository works in either mode.

For a database server (PostgreSQL, Firebird...), map the key to a database name, or to a
connection string you look up.

Then create the resolver once, at startup:

```pascal
GResolver := TTenantDataResolver.Create(GHooks.NewFactory, 600);
```

The second argument closes a database that no request has used for 600 seconds, and opens it
again when it's needed. Use it when many tenants have their own database, so that idle ones
don't keep connections open. `0` (the default) keeps every database open until the resolver is
freed.

### 4. Choose where the tenants are listed: the catalog

**In the configuration**, for a few tenants that rarely change:

```pascal
GCatalog := TConfigTenantCatalog.Create(TAppConfig.Get('TENANTS',
  'acme=dedicated,plan:gold;initech=shared;soylent=shared,suspended'));
```

Entries are separated by `;`, and each entry is `id=mode`, followed by `,suspended` and/or
`,plan:<name>` if needed. Ids and plans use `a-z`, `0-9` and `-`, with at most 40 characters
(an id names a database). Anything else stops the program at startup with
`ETenantCatalogError`. Changing the list means restarting the program.

**In a control database**, when tenants are added, suspended or removed while the API runs. The
control database is a database of its own, not a tenant's. You write two SQL statements with
these names and columns:

```pascal
.Add('SQLITE', 'TENANT.BY_ID', 'SELECT ID, MODE, SUSPENDED, PLAN FROM TENANTS WHERE ID = :ID')
.Add('SQLITE', 'TENANT.ALL',   'SELECT ID, MODE, SUSPENDED, PLAN FROM TENANTS ORDER BY ID')
```

`MODE` is `'dedicated'` or `'shared'`, `SUSPENDED` is 0 or 1, and `PLAN` is NULL when there is
none. Then wrap the catalog in a cache, because otherwise every request would read the control
database:

```pascal
LControl := NewSqliteFactory(GDataDir + 'control.sqlite', 'control', ControlSqlSource);
GCatalog := TCachedTenantCatalog.Create(TDbTenantCatalog.Create(LControl), 30);  // seconds
```

The cache keeps tenants it found for 30 seconds. An id it didn't find is asked again every time,
so a tenant you just created works at once. A change to a known tenant (suspended, removed, a
new plan) shows **after the TTL**. To apply it at once, call `Invalidate(Id)` or
`InvalidateAll` on the `TCachedTenantCatalog` instance from the code that changes the tenant. If
several instances of the API are running, each one must hear about the change, for example
through a pascal-redis-faa Pub/Sub message.

You can also write your own `ITenantCatalog` (`Find` and `All`), for example one that calls
another service.

### 5. Issue tokens with the tenant: the login route

The login route is yours. It must be excluded from the JWT middleware, so it runs without a
token. It decides who the user is and which tenant they belong to, checks the tenant against the
catalog, and signs a token with the `tenant_id` claim:

```pascal
case CheckTenant(GCatalog, LTenant, LInfo) of
  tcSuspended:
    begin
      TJsonSend.Send(ARes, TenantRejection(tcSuspended, LStatus), LStatus);  // 403
      Exit;
    end;
  tcOk: ;
else
  // The same answer for every unknown name, so the answers don't list your customers.
  raise ENotFoundException.Create('Tenant not found.');
end;
// ... claims: {"sub": user, "tenant_id": LInfo.Id, "exp": now + 3600}
TJwtMiddleware.Sign(LClaims)   // signed as the JWT middleware verifies
```

**A signing key per tenant** (optional): with `TTenantJwtKeyRing` each tenant has its own
rotating keys, and a token verifies only when its `tenant_id` names the tenant whose key signed
it, so a key that leaks signs for one tenant, not for all. The login above doesn't change:
`TJwtMiddleware.Sign` picks the key from the claim. See
[JWT signing keys and rotation](jwt-keys.md), step 5.

The sample has no password check (it's a sample). Yours will, and will usually find the tenant
from the user rather than from the request body.

The claim's name can be changed (`TTenantMiddleware.New(GCatalog, 'org')`), for example to
match tokens from an identity provider. Don't use `tid`: Microsoft Entra ID uses it for its own
tenant.

### 6. Register the middlewares

```pascal
TLoggerMiddleware.AddField('tenant.id', TenantIdOf);   // step 8
THorse.Use(TLoggerMiddleware.New(nil, alfJson));
THorse.Use(TMetricsMiddleware.New);
THorse.Use(TJwtMiddleware.New(GSecret, ['/health', '/metrics', '/auth/login', '/swagger']));
THorse.Use(TTenantMiddleware.New(GCatalog));
THorse.Use(TRateLimitMiddleware.New(GRateLimit));     // step 8
```

The order matters:

- **JWT before the tenant.** The tenant middleware reads the claims the JWT middleware verified.
  Paths the JWT middleware excludes need no tenant either: the tenant middleware skips them.
- **The rate limit after the tenant**, if it limits by tenant (step 8).

What a client gets:

| Request | Answer |
|---|---|
| no token, or an invalid one | 401 (JWT middleware) |
| a token without `tenant_id` | 401 |
| a tenant that isn't in the catalog (removed after the token was issued) | 401: the client should log in again |
| a suspended tenant | 403, `{"error": "...", "code": "tenant_suspended"}` |

The messages come from `TApiMessages` (English by default, `TApiMessages.Portuguese` available).

### 7. Use the tenant in handlers and repositories

A handler asks for the request's tenant and builds a repository with that tenant's scope:

```pascal
function CitiesOf(AReq: THorseRequest): TCityRepository;
begin
  Result := TCityRepository.Create(GResolver.ScopeFor(TTenantMiddleware.Current(AReq)));
end;

procedure GetCities(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LCities: TCityRepository;
begin
  LCities := CitiesOf(AReq);
  try
    TJsonSend.Send(ARes, TJsonMapper.Shared.Serialize<TCityArray>(LCities.List));
  finally
    LCities.Free;
  end;
end;
```

Every query in the repository starts with `TTenantFilter.Prepare`, and binds its own parameters
after it:

```pascal
function TCityRepository.FindByCode(const ACode: string): ICity;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
  LResult: IQueryResult;
begin
  Result := nil;
  LScope := FScope.Factory.GetPool.AcquireQuery(LQuery);
  LScope.StartTransaction;
  try
    TTenantFilter.Prepare(LQuery, FScope, 'CITY.BY_CODE');  // SQL + condition + :TENANT_ID
    LQuery.Params.Strings['CODE'] := ACode;                 // after Prepare
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
end;
```

Another tenant's row looks exactly like a row that doesn't exist: a 404, never a 403. That way
a client can't find out which codes other tenants use.

`TTenantMiddleware.Current` raises `ETenantContextError` (a 500) on a route without a tenant
(one the JWT middleware excludes). Use `TryCurrent` where a tenant is optional.

### 8. Logs, metrics and limits per tenant

**`tenant.id` in the access log and on the spans:**

```pascal
TLoggerMiddleware.AddField('tenant.id', TenantIdOf);
```

Each access line (text or JSON) and each server span then carries the tenant. Requests the
tenant middleware refused have no `tenant.id`.

**A rate limit per tenant, set by its plan:**

```pascal
function TAppHooks.RateKey(AReq: THorseRequest): string;
var
  LInfo: TTenantInfo;
begin
  if TTenantMiddleware.TryCurrent(AReq, LInfo) then
    Result := 'tenant:' + LInfo.Id      // one window per tenant
  else
    Result := 'anonymous';              // login, health: one window together
end;

function TAppHooks.PlanLimit(AReq: THorseRequest): Integer;
var
  LInfo: TTenantInfo;
begin
  Result := 0;                          // 0: the options' Limit
  if TTenantMiddleware.TryCurrent(AReq, LInfo) and (LInfo.Plan = 'free') then
    Result := 5;
end;

GRateLimit := TRateLimitOptions.Default;
GRateLimit.Limit := 1000;
GRateLimit.WindowSeconds := 60;
GRateLimit.KeyExtractor := GHooks.RateKey;
GRateLimit.LimitFor := GHooks.PlanLimit;
THorse.Use(TRateLimitMiddleware.New(GRateLimit));
```

`X-RateLimit-Limit` shows each request's own limit.

**Metrics:** the database pools show up in `/metrics` as `dedicated` and `shared`. The
connections of every dedicated database add up under `dedicated`.

### 9. Migrations and new tenants

The library never creates a database. Your application:

- **At startup** runs the migrations on every database the catalog names: each dedicated
  tenant's, and the shared one once. The sample does it before `THorse.Listen`, so a tenant's
  first request never waits for a migration:

  ```pascal
  LTenants := GCatalog.All;
  for I := 0 to High(LTenants) do
  begin
    LKey := DatabaseKeyOf(LTenants[I]);     // 'tenant_acme' or 'shared'
    if <LKey already done> then Continue;
    LEngine := TDBMigrationEngine.Create(GResolver.ScopeFor(LTenants[I]).Factory, OnMigration);
    try
      LEngine.Execute(CityMigrations);
    finally
      LEngine.Free;
    end;
  end;
  ```

- **When it provisions a tenant** while the API runs: a dedicated tenant needs its database
  created (on a database server) and migrated before the tenant goes into the catalog. A shared
  tenant only needs its catalog row.

With SQLite, opening a file that doesn't exist creates it. A database server won't do that.

## Choices

### Dedicated or shared

| | Dedicated | Shared |
|---|---|---|
| Isolation | a database per tenant: a missing filter can't reach another tenant | depends on every query filtering by `TENANT_ID` |
| Cost | one database and one pool per tenant | one database, one pool |
| Backup, restore, deleting a customer | per tenant | rows inside a shared database |
| Good for | large customers, or a contract that demands it | many small customers |

The two modes can be mixed: the big customers dedicated, the small ones shared.

### A `TENANT_ID` column in dedicated databases too

The library doesn't require it: in SQL without the tag and without `:TENANT_ID`, `Prepare` only
loads the SQL. This guide (and the design, decision 4) recommends the column anyway:

- The same code serves both modes.
- Moving a tenant between modes is a data copy, not a rewrite of every SQL and table.
- If a bug resolves the wrong database (configuration, cache), the filter still stops the read.

The cost is a column, its index, and the tag in each SQL. Leave it out only if dedicated
databases are a decision that will never change, and write that decision down in your project,
so nobody adds a shared mode later believing the queries filter.

### Catalog in configuration or in a database

Configuration: a few tenants, changed with a deploy. Database: tenants change while the API
runs. In that case, choose the cache's TTL: it is how long a suspension or a removal takes to
apply when you don't call `Invalidate`.

## Pitfalls

- **A query without `Prepare`.** Writing `LQuery.Sql := ...SqlLoader['CITY.LIST'].SQL` directly
  leaves `${TENANT}` in the SQL (the database rejects it) or, in SQL you wrote without the tag, no filter at all.
  In the shared database that reads every tenant's rows. Every query on tenant data goes through
  `Prepare`.
- **Binding `:TENANT_ID` yourself, apart from the condition.** A parameter that is never set is
  NULL on SQLdb/SQLite: the condition matches nothing and the route answers 404, with nothing in
  the log (measured in the sample). `Prepare` sets both at once so that this can't happen.
- **Parameters set before `Prepare`.** Setting the SQL resets them: bind your own parameters
  after `Prepare`.
- **A JOIN with one tag.** Plain `${TENANT}` is ambiguous when two joined tables have the
  column, and a tag on the main table only returns the other tenants' joined rows. Each table
  gets its own `${TENANT.alias}`, the joined ones in `ON` (step 2).
- **A suspension takes effect only after the cache's TTL** (step 4), unless you call
  `Invalidate`.
- **Tokens outlive the catalog.** A token keeps its tenant until it expires. Removing or
  suspending a tenant is caught by the catalog check on each request, but changing a user's
  tenant needs a new token. Keep token lifetimes short.
- **One configuration per process.** On FPC, Horse's middlewares are plain procedures, so each
  one keeps a single configuration (the catalog, the claim name) for the whole program.
- **Login answers.** Answer every unknown tenant name the same way (the sample: 404), so the
  login route can't be used to list your customers.

## Testing your application

Unit tests can check your repositories with pascal-db-faa's `TMockDBFactory`. The checks that
matter most, though, are over HTTP, with two tenants in the shared database and one dedicated
tenant. Write each one as one tenant trying to reach another tenant's data:

- the same code created in two tenants: no conflict, and each one reads back its own row;
- a list shows only the caller's rows;
- reading, changing or deleting another tenant's row by its key: 404, and the row is still
  there for its owner;
- a header or a body field naming another tenant changes nothing;
- a token without the claim, or with a removed tenant: 401; a suspended tenant: 403.

Then remove the `${TENANT}` tag from one query and check that some of these checks fail. In the
sample, dropping the condition from two queries failed 5 checks: that is how you know the
checks can catch a missing filter.

`tools/http_scenarios_tenants.sh` is a complete example (curl, plus Python to sign tokens the
login route would never issue).

## Reference

- `PascalApi.Tenancy` and `PascalApi.Horse.Tenancy`: the comment at the top of each unit, and
  each declaration's comment.
- `samples/03-tenants`: `TenantApiSample.dpr` (the program), `TenantApiSample.Cities.pas` (the
  repository and its SQL), `TenantApiSample.Control.pas` (the control database).
- `tools/http_scenarios_tenants.sh`: the checks above, against the sample.
- [docs/multitenancy-design.md](../multitenancy-design.md): the ten decisions and what was
  measured.
- [CHANGELOG](../../CHANGELOG.md): 0.12.0 (multi-tenancy) and 0.13.0 (catalog in a database,
  `tenant.id`, limits by plan).
