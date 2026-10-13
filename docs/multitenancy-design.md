# Design: multi-tenant APIs on this library

Status: **approved and implemented (2026-10-13)**: `samples/03-tenants` proved the design on FPC
(Windows and Linux) and Delphi 12 (Win32 and Win64), then the tenancy moved to the library
(`PascalApi.Tenancy`, `PascalApi.Horse.Tenancy`; "Promotion to the library"). All ten
decisions taken with the user; what the sample measured changed decisions 2 and 8 in detail
("Sample 03: what was done"), and decision 9's open question turned out already answered in
pascal-db-faa.

## Goal

A base on which a multi-tenant API can be built, not a specific application. One process serves
many tenants; every request, job and message runs on behalf of exactly one of them, and one
tenant's data never reaches another.

pascal-db-faa is database-agnostic, so the structure is decided **outside the database**: the
isolation is a contract the application sees, and the database-specific mechanisms (row-level
security, `search_path`, `USE`) are never what the base relies on.

## What exists today (read on 2026-10-13)

- `TJwtMiddleware.Claims(AReq)` gives the verified claims: where a tenant claim would come from.
- `TRateLimitOptions.KeyExtractor` already takes any key (`tenant:user` works today); the limit
  itself is one per process.
- `TLoggerMiddleware` marks the request with a header no client can send (`:pascalapi-logged`):
  the same trick can carry the resolved tenant through the chain.
- Horse's callbacks are plain procedures on FPC: one configuration per process (accepted
  2026-10-08), so a tenant middleware keeps its settings in its unit like the others.
- pascal-db-faa's `TDBRegistry` registers factories by name, but `RegisterFactory` raises on a
  duplicate, has no lock and no removal: fine for a fixed set at startup, **not** for tenants
  that appear at run time.
- `TConnectionPool` takes `APoolName`, which becomes the metric label
  `db.client.connection.pool.name`.
- Sample 02 keeps a global repository (`GCities`) created at startup: that shape doesn't carry
  over, since the repository must be bound to the request's tenant.

## Decisions

### 1. Opt-in: an application that doesn't use it sees no difference (user, 2026-10-13)

Two kinds of change, both optional:

- **Generic extension points**, useful without tenancy too, each with a default that is exactly
  today's behaviour: a per-key limit lookup in the rate limit, a hook for extra fields in the
  access log, a thread-safe keyed pool registry (pascal-db-faa). None of them names a tenant.
- **Tenancy units** (`PascalApi.Tenancy`, `src/horse/PascalApi.Horse.Tenancy`), used by no
  other unit of the library. The core never assumes a tenant exists.

Every extension point lands with a test that its default is today's behaviour, and the existing
HTTP scenarios (both samples) pass unchanged. Only a new sample turns tenancy on.

Opt-in doesn't mean safe by default: with a shared database, the library can offer a repository
base that adds the filter, but it can't stop a hand-written query from skipping it (decision 4,
and the cross-tenant scenarios under "How it will be tested").

### 2. The library offers the isolation modes behind one contract (user, 2026-10-13)

The application never chooses a pool itself; it asks the resolver for the request's data scope:

```pascal
TTenantDataScope = record
  Factory: IDBFactory;       // which database: its pool, and its SqlLoader
  Discriminator: string;     // the tenant_id value, always set (decision 4)
end;

ITenantDataResolver = interface
  function ScopeFor(const ATenant: ITenantContext): TTenantDataScope;
end;
```

"Which database" alone covers a database per tenant; a shared database also needs "which
filter", hence the record. (First drafted with `Pool: IDBConnectionPool`; the sample's
repository also needs the factory's `SqlLoader`, so the scope carries the factory.) Because the resolver decides per tenant (from the catalog), modes can be
**mixed**: large tenants on their own database, small ones on a shared one.

### 3. Two implementations ship; schema-per-tenant doesn't (user, 2026-10-13)

| Mode | In the library | Why |
|---|---|---|
| Database per tenant (one pool per tenant) | yes, first | fully agnostic; strongest isolation; works with SQLite (one file per tenant), so the samples and CI can prove it |
| Shared database, `tenant_id` column | yes | agnostic; one pool; isolation depends on the filter (decision 4) |
| Schema per tenant | no | `search_path` (PostgreSQL), `USE` (MySQL), nothing equivalent in SQLite: dialect-specific. An application implements it through the same interface, or a per-dialect implementation comes later |

### 4. Repositories always filter by `tenant_id` (user, 2026-10-13)

Every tenant-owned table has the column and every query filters by `Discriminator`, also in a
dedicated database, where the filter is redundant. The same repository code then serves both
modes and a mix of them, and moving a tenant from shared to dedicated is configuration plus a
data copy, not a rewrite. The cost is one column and one index per table.

The classic miss is an `UPDATE`/`DELETE` by id alone (`DELETE FROM cities WHERE id = :id`
deletes another tenant's row); how the library helps is decision 8.

### 5. Tenant sources: a configurable list, only the JWT claim in the first version (user, 2026-10-13)

| Source | For | Against |
|---|---|---|
| JWT claim | signed: the client can't forge it | exists only after login |
| `Host` subdomain | white-label apps; exists before login | wildcard DNS/TLS; the client picks the host, so alone it proves nothing |
| Header (`X-Tenant-Id`) | service-to-service calls | anyone sends any value; only usable checked against the token |
| Path prefix (`/t/acme/...`) | visible, easy to debug | changes every route and the OpenAPI document |

The middleware takes a list of sources; the first version ships the JWT claim only. Host and
header come when a real case asks for them, under the rule already set: when two sources name a
tenant they must agree (403 otherwise), and the tenant never comes from the body.

- **One token per tenant.** A user who belongs to several tenants gets a token for the one in
  use; switching tenants issues a new token. (The alternative, a token listing the tenants and a
  header picking one, saves a token issue but adds a conflict rule; not now.)
- **The login route is the application's.** It has no token yet, so it sits in the excluded
  prefixes (as it does for `TJwtMiddleware`) and resolves the tenant itself (host, or a body
  field checked against the catalog). The library never requires a tenant on every route.

### 6. Claim name: configurable, default `tenant_id` (user, 2026-10-13)

Not `tid`: Microsoft Entra ID (Azure AD) already uses `tid` for the identity provider's
tenant, not the application's. The library only issues its own HS256 tokens today, but with
an external identity provider `tid` would silently mean something else. A namespaced name
(`https://example.com/tenant`, as Auth0 asks for custom claims) stays possible through the
configuration.

### 7. The answer for an unknown or suspended tenant depends on the source (user, 2026-10-13)

| Case | Status | Why |
|---|---|---|
| Unknown, from the JWT | **401** | the token is ours, so the tenant was removed after it was issued; nobody can forge the claim to enumerate tenants, and 401 sends the client to log in again |
| Unknown, from host or path | **404**, the same for every unknown name | anyone can try `acme.api.com`, `foo.api.com`...: a different answer would list the customers |
| Suspended | **403**, error code `tenant_suspended` in the body | the caller already authenticated in that tenant, so saying so leaks nothing, and the client can show a proper message |

All answered by the middleware, before any handler.

### 8. Repository support: a filter helper, plus an optional SqlLoader convention (user, 2026-10-13)

| Option | Taken? |
|---|---|
| A helper, `TTenantFilter`: the condition for an alias and the parameter from the `TTenantDataScope`, set in one call (`Prepare`) | **yes**: small, works with any SQL |
| A class wrapping every query and injecting the filter | no: it would have to parse arbitrary SQL (joins, subqueries, CTEs), unreliable, and it would fight `SqlLoader`'s templates |
| A `TENANT` tag in `SqlLoader` files (`[TENANT {] AND tenant_id = :tenant_id [} TENANT]`) | **yes, optional**, for applications that keep SQL in files |

**One call, not two (measured in sample 03).** The first version replaced the condition and
bound the parameter in separate calls. A forgotten bind is **silent** on SQLdb/SQLite: the
unbound parameter is NULL, `TENANT_ID = NULL` matches nothing, and the route answers 404 with
nothing in the log. It fails closed (no other tenant's rows) but quietly, so `Prepare` loads the
SQL, replaces `${TENANT}` with the condition and binds `:TENANT_ID` together. A forgotten
`${TENANT}` replacement is loud (the literal stays in the SQL and the database rejects it).
FireDAC on Delphi may answer an unbound parameter differently: not measured.

The same measurement corrects what this section first said of the tag convention: a forgotten
`ProcessTag` keeps the condition (`SqlLoader`'s rule: the content stays), but the unbound
`:tenant_id` that follows is the silent case above, not an error. Safe, not loud.

Neither stops a hand-written query that skips both. The safety net is the cross-tenant HTTP
scenarios (see "How it will be tested"), so a missing filter fails CI. A possible later addition:
a script that scans `.sql` files and flags an `UPDATE`/`DELETE` without `tenant_id`.

### 9. Pool name in metrics: one name per mode (user, 2026-10-13)

With a database per tenant, every tenant has a `TConnectionPool`, and each pool's series
(histogram buckets included) multiply by the number of tenants under
`db.client.connection.pool.name`. Decided: two names, `dedicated` and `shared`; per-tenant
visibility comes from the spans (`tenant.id` attribute) and the logs, where cardinality costs
nothing.

Read in pascal-db-faa 0.14.0: the pool's metrics are up-down counters (`TPcUpDownCounterSeries`),
so pools sharing a name add up (`max` the sum of maxima, `used` the sum in use), which is the
right aggregate: **measured** in sample 03, two dedicated pools of 5 show
`db_client_connection_max{pool_name="dedicated"} 10`. A pool that is freed (evicted when idle, or a tenant deprovisioned) gives back what it added:
its destructor subtracts `idle`, `max` and `idle.min` (nothing is `used`: each connection
wrapper holds a reference to the pool), and pascal-db-faa 0.14.0 tests exactly this case
(`PoolMetricsTests`: `Destroy_GivesTheSeriesBack`, and `TwoPoolsWithTheSameName_AddUp`, where
freeing one of two pools named alike leaves the other's `max`). First listed here as "not
measured"; found answered on 2026-10-13, so idle databases can be dropped.

### 10. The library connects to tenant databases; it doesn't create them (user, 2026-10-13)

Creating a database is dialect-specific: PostgreSQL's `CREATE DATABASE` can't run in a
transaction and needs a connection to another database; Firebird creates through the client
API; SQLite creates the file on open. Users, passwords and grants depend on the
infrastructure. So:

- the operator (a script, an infrastructure tool) creates the database;
- the library offers an optional `ITenantProvisioner` hook the application implements; when it
  is set, the library's provisioning flow calls it, runs the migrations, and registers the tenant
  in the catalog;
- migrations per tenant: `migrate --all-tenants`, and one run for a single tenant just
  provisioned.

In the sample (SQLite), provisioning is opening the file.

## Proposed design

### Resolving the tenant (HTTP)

- Sources per decision 5; claim name per decision 6; answers per decision 7.
- Order: Logger → JWT → **Tenant** → RateLimit → routes. Excluded paths (`/health/*`,
  `/metrics`, `/swagger`, the application's login route) need no tenant.
- Pure decisions (extract from host or path, compare sources, map the status) in
  `PascalApi.Tenancy`, tested without a server like `PascalApi.HttpTests`; the middleware in
  `src/horse/PascalApi.Horse.Tenancy`.

### The tenant context

- `ITenantContext`: id, status, plan, and what the catalog says about its data (decision 2).
- On a request it travels on the request, marked like the logger's mark (`:pascalapi-tenant`);
  `TTenantMiddleware.Current(AReq)` returns it, as `TJwtMiddleware.Claims` does. Horse's
  `Sessions` is the alternative (to measure on both compilers before choosing).
- The mark is safe because the middleware **overwrites** it on every request it lets through,
  not because a client can't send it: HTTP forbids ':' in a header name, but fpWeb accepted a
  raw `:sample-tenant: initech` line (measured in sample 03; curl won't even send it, the
  check uses a raw socket). Routes the middleware skips never read it.
- **Passed explicitly** to services and repositories, never only through a `threadvar`: jobs,
  AMQP consumers and code outside a request have no request to read it from.

### The tenant catalog

`ITenantCatalog.Find(id)`: status, plan, limits, feature flags and a **reference** to the data
configuration (never a password in plain text). Implementations:

- from configuration (`PascalApi.Config`): tests and few tenants;
- from a control database (pascal-db-faa), separate from the tenants' databases;
- a caching decorator with a TTL (`TTicker`), invalidated through pascal-redis-faa's Pub/Sub when
  more than one instance runs.

### Pools per tenant

A keyed pool registry: created on first use under a lock (double-checked), idle pools closed
after a configurable time, removable when a tenant is deprovisioned. The registry itself is
created in `initialization` (the rule for shared defaults); only the pools are created on
demand.

### What changes in the existing pieces

- **Rate limit**: key `tenant:user` (works today); a limit per plan needs the per-key limit
  lookup (decision 1).
- **Access log**: `tenant.id` through the extra-fields hook. The logger writes after the chain
  returns, so a tenant set later in the chain should be visible to it (to verify).
- **Spans**: `tenant.id` as an attribute of the server span (spans aren't aggregated, so high
  cardinality is fine there).
- **Metrics**: never labelled by tenant id (the same reason a metric is never labelled with the
  raw path); pool names per decision 9.
- **OpenAPI/MCP**: the tenant header or claim documented; the MCP executor calls back through
  the API with the client's token, so the tenant follows.
- **Migrations**: one `TDBMigrationEngine` run per tenant database (decision 10); never on a
  tenant's first request.
- **Redis/AMQP** (sibling libraries): keys prefixed by the tenant; in AMQP the tenant in a
  message header (or a vhost per tenant), from which the consumer rebuilds `ITenantContext`.

## Where each piece lives

1. **First in a sample** (`samples/03-tenants`): database per tenant with SQLite, plus one
   shared database, tenant from the JWT, catalog from configuration. It proves the design on
   both compilers before anything becomes library API.
2. Then promoted:
   - resolution, context, middleware, catalog and resolver contracts → this repository (done);
   - the keyed pool registry → pascal-db-faa, next to `TDBRegistry` and the pool: **not done**.
     It stayed inside `TTenantDataResolver` (a dictionary, a lock and the idle sweep, ~60
     lines) because the resolver is its only user; moving it means a pascal-db-faa release for
     no second consumer. Revisit when one appears;
   - `ITenantContext` → pascal-common-faa, once pascal-redis-faa or pascal-amqp-faa need it (the
     path tracing took in phase D). For now the context is the `TTenantInfo` record.

## To measure before relying on it

- **The access log sees the tenant**: the logger runs first and writes after the chain returns,
  so a tenant set later should be visible to it; verify on both compilers.
- **Horse's `Sessions`** as the carrier of `ITenantContext`, against the request mark: does it
  behave the same on Delphi and FPC, and who frees what.

## How it will be tested

- `PascalApi.TenancyTests`: resolution rules, source conflicts, the status per source
  (decision 7), the claim name, the filter helper, the keyed registry (concurrency, eviction),
  with a fake catalog.
- `tools/http_scenarios_tenants.sh` against sample 03, on Linux in CI, including the
  **cross-tenant** checks: a token for tenant A reading, changing or deleting B's records by id
  (404, never B's data), a token naming a removed tenant (401), a suspended tenant (403,
  `tenant_suspended`), and the same in both isolation modes.
- The existing scenarios (146 + 65 checks) pass unchanged: the opt-in check of decision 1.

## Sample 03: what was done (2026-10-13)

`samples/03-tenants` (`TenantApiSample`, port 9350), one source for Delphi and FPC:

- `TenantApiSample.Tenancy`: `TTenantInfo`, `ITenantCatalog` with the configuration catalog
  (`TENANTS`, default `acme`/`globex` dedicated, `initech`/`umbrella` shared, `soylent` shared
  and suspended), `TTenantDataScope`, `TTenantDataResolver` (one `IDBFactory` per database key,
  created under a lock; pools named `dedicated`/`shared`), `TTenantFilter.Prepare`,
  `CheckTenant`. A record instead of `ITenantContext` for now.
- `TenantApiSample.Cities`: `TENANT_ID` in every row and in the primary key, the same table in
  every database; a repository per request from the scope.
- The program: login (the application's route, tenant from the body: 404 for any unknown
  name, 403 suspended), the tenant middleware after JWT (claim `tenant_id`; 401 no tenant or
  removed, 403 suspended), every database migrated at startup, Swagger and `/metrics`.
- `tools/http_scenarios_tenants.sh`: 57 checks, in `tools/test_http.sh` and in CI
  (`tools/test_http_docker.sh`, plus the OpenAPI validator and promtool). Tokens the sample
  never issues (removed tenant, no tenant, a number, `tid`, suspended) are signed in the
  script with Python's `hmac`.

Verified: FPC 3.2.2 on Windows (lazbuild) and Linux (`tools/ci-test.sh`: 146 + 65 + 57 checks,
the unit suite unchanged), and Delphi 12 Win32 and Win64 (57 checks each, FireDAC). Indy, like
fpWeb, accepts the raw `:sample-tenant` line and the tenant stays the token's.

Found while verifying on Delphi: a second instance started with `--reset` on the same
`DATA_DIR` while the first ran couldn't delete the open files on Windows, ignored that, and
served the first one's rows (the scenarios then failed with 409s). `--reset` now stops with an
error naming the file (checked on FPC; the Delphi executables were built before this change).

Mutation checks, run once by hand on FPC Windows and reverted:

- dropping the tenant condition from the by-code and delete queries: 5 checks failed (shared
  database: reading and deleting another tenant's city). The dedicated checks still passed, as
  they should: there the database isolates.
- keeping the condition but not binding it: 10 checks failed, every one a silent 404 (the
  finding under decision 8).

Not covered yet: the access log and spans with `tenant.id`, the rate limit by tenant,
eviction of idle pools (waits on decision 9's measurement), unit tests of the tenancy pieces
(they come with the promotion to the library).

## Promotion to the library: what was done (2026-10-13)

- `src/PascalApi.Tenancy.pas` (in the package): the sample's unit, plus `TenantIdFromClaims`
  and `TenantRejection` (the middleware's decisions, testable without a server), the factory
  callback as `PASCALAPI_FUNCREFS` (`reference to` on Delphi, `of object` on FPC: the sample's
  plain function became a method), the messages in `TApiMessages` (`TenantMissing`,
  `TenantUnknown`, `TenantSuspended`, English and Portuguese), and idle eviction
  (`AIdleSeconds`, default 0 = keep; checked at most once a second, on a request, through
  `TTicker`).
- `src/horse/PascalApi.Horse.Tenancy.pas`: `TTenantMiddleware.New(ACatalog[, AClaimName])`,
  `Current`/`TryCurrent`, `Configured`; the mark is `:pascalapi-tenant`.
- `PascalApi.TenancyTests`: 24 tests (catalog, claim, refusals in both languages, key and pool
  names, resolver with a manual ticker, `Prepare` against `TMockDBFactory`). 239 tests, 0 leaks,
  on FPC Windows and Linux.
- Sample 03 uses the library; `TenantApiSample.Tenancy` deleted. Its 57 checks pass unchanged
  except the raw-header check, now on `:pascalapi-tenant`.

Verified on Delphi 12 Win32 and Win64 too: 239 tests, 0 leaks, and sample 03's 57 checks. The
first Delphi build failed on `PascalApi.Horse.Tenancy`: a `finalization` with no
`initialization` before it, which FPC accepts and Delphi doesn't (fixed by the user).

## Not in this design

- Schema-per-tenant (decision 3).
- Row-level security or any other database-specific enforcement.
- Creating tenant databases (decision 10).
- Host, header and path sources, and tokens listing several tenants (decision 5: later, on a
  real case).
- Billing, tenant self-service or an admin API: an application's concern.
- Moving a tenant between modes (only made possible by decision 4, not automated).
