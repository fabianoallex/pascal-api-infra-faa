# Design: JWT signing keys with rotation

Building an application with it: [the guide](guide/jwt-keys.md). This document records the
decisions and what was measured.

Status: **phases 1, 2 and 3 done (2026-10-18).** Three decisions taken with the
user (decisions 5, 6 and 8); the others are proposals that the implementation may change, and
what it measures goes back here, as in the other design records.

Phase 1 as built: `PascalApi.JwtKeys` (`TJwtKey` with `Kid`, `Secret`, `NotAfter`;
`IJwtKeyRing`; `TStaticJwtKeyRing` and `JWT_KEYS`; `TJwtKeys.Sign`/`Decode`/`CheckLifetime`),
`TJwt.SignHS256` with a kid and `TJwt.ReadKid`, `TJwtMiddleware.New(ARing, ...)` and
`TJwtMiddleware.Sign`. A static kid has no `/` (reserved for decision 8). `CreatedAt` and
`ActiveFrom` join `TJwtKey` in phase 2. Sample 01 keeps `New(ASecret)` (the opt-in check:
186 checks unchanged); sample 03 uses a ring with three keys, one past its `NotAfter`, and
JWT_SECRET as the legacy secret, so the tokens the scenario script signs without kid still
pass; its "signing keys" checks are the HTTP proof (107 checks). Verified with FPC on Windows
and Linux and Delphi 12 Win32/Win64 (304 tests, 0 leaks; samples 01, 02 and 03: 186, 93 and
107 checks).

## Goal

Rotate the HS256 secret without invalidating the tokens already issued, generate and rotate it
automatically, and keep one tenant's key from signing another tenant's tokens. Opt-in: an
application that calls `TJwtMiddleware.New(ASecret, ...)` today sees no difference.

## What exists today (read on 2026-10-18)

- `TJwt.SignHS256(AClaimsJson, ASecret)` writes the fixed header `{"alg":"HS256","typ":"JWT"}`;
  `TJwt.Decode` checks `alg`, the signature, `exp` and `nbf` with one secret, and refuses an
  empty one (`src/PascalApi.Jwt.pas`).
- `TJwtMiddleware.New` keeps one secret in the unit (`GJwtSecret`, one configuration per
  process); `Claims(AReq)` verifies again with it (`src/horse/PascalApi.Horse.Middlewares.pas`).
- The application reads the secret once (`TAppConfig.Get('JWT_SECRET', ...)`) and signs in its
  own login handler with `TJwt.SignHS256(LClaims, GSecret)` (samples 01 and 03).
- The tenant comes only from the verified token's claim (`TENANT_CLAIM`, default `tenant_id`;
  multitenancy decisions 5 and 6). `TTenantMiddleware` runs after `TJwtMiddleware`.
- Random bytes from the operating system exist in pascal-common-faa (`BCryptGenRandom`,
  `/dev/urandom`), but only as a private `FillRandom` in `PascalCommon.TraceContext`.
- `docs/guide/authentication.md`, Pitfalls: "One secret. Rotating it invalidates every token
  issued with the old one."

## Decisions

### 1. Opt-in, and today's tokens stay valid (proposal)

`TJwtMiddleware.New(ASecret, ...)` and `TJwt.SignHS256(AClaimsJson, ASecret)` keep their
behaviour. The key ring comes through new overloads. A ring may hold a **legacy secret**: a
token without `kid` is verified with it, so moving an API from one secret to a ring doesn't log
anyone out. Without a legacy secret, a token without `kid` is refused.

### 2. Keys are named by `kid` in the header (proposal)

A ring signs with `{"alg":"HS256","typ":"JWT","kid":"<kid>"}` (written with `TJsonWriter`,
never by joining strings). On verification the `kid`, read before the signature is checked,
picks the secret; it is untrusted input:

- It must be a JSON string of at most 128 bytes, or the token is malformed.
- It is looked up **only in memory**. An unknown `kid` never reaches the database: a client
  sending a new `kid` per request would otherwise cost one query each. The ring reloads on its
  own schedule (decision 4), not because a token named a key it doesn't know.
- An unknown `kid` answers the same 401 as a bad signature (`TokenInvalid`): the client isn't
  told which keys exist.

### 3. A key's life: pending, signing, verifying, gone (proposal)

```
TJwtKey = record
  Kid, Secret: string;
  CreatedAt, ActiveFrom, NotAfter: Int64;   // Unix seconds, TClock (TJwt.UnixNow)
end;
```

- **Pending** (`now < ActiveFrom`): verifies, doesn't sign yet.
- **Signing**: the newest key with `ActiveFrom <= now`. Exactly one.
- **Verifying only**: an older key, until `NotAfter`.
- **Gone**: `NotAfter <= now`; dropped from the ring (and from the store, decision 5).

When key n+1 starts signing, key n verifies until `NotAfter = ActiveFrom(n+1) + MaxTokenLifetime`.
That value is **computed when the ring loads, never stored**: a store only adds and deletes
keys, it never updates one (no second write to coordinate between instances, decision 5).
`MaxTokenLifetime` is therefore a setting every instance must share. A static ring (decision 5)
gives `NotAfter` explicitly instead.

`TJwtMiddleware.Sign` therefore **refuses claims whose `exp` is missing or later than
`now + MaxTokenLifetime`** (an `EArgumentException`, a programming error): such a token would
stop verifying before its own expiry.

Revoking a leaked key is removing it: its tokens fail at once, which is then the point.

### 4. Rotation is checked lazily, no thread (proposal)

`SigningKey` checks, with `TTicker`, whether the ring is due for a reload (`ReloadSeconds`) and
whether the signing key is older than `RotateEverySeconds`; if so it creates key n+1 as pending
with `ActiveFrom = now + PropagationSeconds`. A request pays for this at most once per reload.

`PropagationSeconds` must be at least `ReloadSeconds` (checked when the ring is created): every
instance must have loaded a key before any token signed with it reaches that instance. Settings
read by the application through `TAppConfig`, with names to fix during implementation
(`JWT_ROTATE_DAYS`, `JWT_MAX_TOKEN_SECONDS`, `JWT_PROPAGATION_SECONDS`, `JWT_RELOAD_SECONDS`).

### 5. The store: a database table, or Redis as an option (user, 2026-10-18)

First decided as the database only; revised the same day to add Redis as an option. One
contract, `IJwtKeyStore`, with three operations and no update:

- `Load(ATenant)`: the tenant's keys (`''` for an API without tenants).
- `TryAdd(ATenant, AKey, AGeneration): Boolean`: False when that generation already exists
  (another instance won the rotation); any other failure raises.
- `Delete(ATenant, AKid)`: a gone key, or a revoked one.

Several instances may decide to rotate at the same moment. Each tries to add generation n+1;
the store lets exactly one win, and the others reload and use the winner's key. No lock and no
version column.

**`TDbJwtKeyStore`** (pascal-db-faa), running the application's SQL by name like
`TDbTenantCatalog`, so the library doesn't fix a dialect. Columns:

| Column | |
|---|---|
| `TENANT_ID` | `''` for an API without tenants |
| `GENERATION` | 1, 2, 3...; **unique together with `TENANT_ID`**: the race of `TryAdd` |
| `KID` | 16 random hex digits, unique |
| `SECRET` | 32 random bytes, Base64url |
| `CREATED_AT`, `ACTIVE_FROM` | Unix seconds |

To check during implementation: that the unique violation is told apart from other errors on
every pascal-db-faa adapter (`EConstraintViolationException`, `cvUnique`, if it reports that
kind as it reports `cvCheck`).

**`TRedisJwtKeyStore`** (pascal-redis-faa), for an API that already runs Redis and has no
database of its own. One hash per tenant, `<prefix>jwt-keys:<tenant>` (the prefix is the
application's, as for any key it shares a Redis with), field = the generation, value = the key
as JSON (`kid`, `secret`, `createdAt`, `activeFrom`). `TryAdd` is `HSETNX` (the race), `Load` is
`HGETALL`, `Delete` is `HDEL` of the generation. Pitfalls the guide must state, both of which
log every user out:

- Redis without persistence (no RDB or AOF) loses the keys on a restart.
- An eviction policy other than `noeviction` (or a `volatile-*` one, the hashes having no TTL)
  can evict them under memory pressure.

pascal-redis-faa doesn't repeat a command in flight after a reconnect (`HSETNX` isn't
idempotent): a `TryAdd` that fails that way raises, and the next `SigningKey` reloads and
retries.

**Where the Redis store lives (user, 2026-10-18): `src/redis/PascalApi.Redis.JwtKeys`**,
outside the `.lpk`, as `src/horse` is for Horse; a consumer adds it and its own
pascal-redis-faa to the search path. The core (`src/`) still has no Redis code, so an API
without Redis builds as before. Its tests need pascal-redis-faa as a test-only submodule and a
Redis server in CI (a container next to the Collector). Rejected: no unit here, the guide
showing a store the application writes.

A ring may also be **static**, from `JWT_KEYS` (`kid:secret[@notAfter],...`, the first entry
signs): manual rotation for an API without a database, and the first step of the
implementation.

### 6. Secrets sealed under a master key (user, 2026-10-18, revising "plain text for now")

First decided as plain text, protected by access to the database only, since no `*-faa`
library had AES. Revised the same day, four choices by the user:

- **An interface and our own AES** (`IJwtSecretCipher`, `TAesGcmSecretCipher`): AES-256-GCM in
  pure Pascal, the same on both compilers, no dependency. The interface leaves room for a KMS
  or Vault later. Rejected: the operating system's crypto (CNG and OpenSSL: two code paths and
  OpenSSL required on Linux), and the interface alone.
- **AES-GCM lives in pascal-common-faa** (`PascalCommon.AesGcm`, 1.16.0), ahead of a second
  user, not in `PascalApi.Crypto`.
- **Master keys listed with an id** (`JWT_KEYS_MASTER_KEY=m2:<base64>,m1:<base64>`, the format
  of `JWT_KEYS`): the first seals, every one opens; a sealed secret names its master's id.
- **Plain rows still load, new keys are sealed**: the rotation replaces the plain ones;
  `ARequireSealed` refuses plain text once they are gone.

As built: `TSealedJwtKeyStore` wraps any store (database, Redis, memory), so the ring and the
stores don't change. A sealed secret is `aesgcm:v1:<master id>:<nonce>:<ciphertext+tag>`
(Base64url, about 110 characters: sample 03's `SECRET` column went from `VARCHAR(64)` to
`VARCHAR(255)`). The GCM's additional data is the secret's place,
`jwt-key|<scope>|<kid>|<generation>`: a sealed secret copied to another tenant's row doesn't
open (tested). A value that is sealed and doesn't open is `EJwtKeyError` naming the kid's place
and the master id, never a secret or a master key; at startup that stops the API, later the
ring keeps its loaded keys and reports it.

Timing: the AES S-box is a table lookup (cache timing). Accepted for this use: a secret is
opened when the keys reload, not on a request's input. Stated in `PascalCommon.AesGcm`.

Measured: `TSealedSecretTests` (10 tests, among them a value sealed by OpenSSL through Python's
cryptography and opened here); `tools/http_scenarios_jwt_rotation.sh` checks that every secret
in sample 03's `control.sqlite` is sealed and opens acme's with OpenSSL (31 checks; 25 on Redis),
on FPC Windows and Linux and Delphi 12 Win32/Win64 (SQLdb and FireDAC). AES-GCM itself:
`PascalCommon.AesGcmTests` in pascal-common-faa (NIST and OpenSSL vectors), 307 tests on the
same four.

### 7. Random bytes come from pascal-common-faa (proposal)

`FillRandom` in `PascalCommon.TraceContext` becomes public in pascal-common-faa (for example
`PcRandomBytes(ACount): TBytes` in its own unit), released there, and this library's minimum
moves to that version. No copy here (global rule: code a second library needs goes to
pascal-common-faa). It raises when the system source fails, never falls back to `Random`.

### 8. Tenants: one key ring per tenant, the tenant inside the `kid` (user, 2026-10-18)

The tenant is known only from the verified claims, but the key must be chosen before. So a
tenant's `kid` is `<tenant id>/<16 hex>`:

1. The middleware reads the `kid` and splits it at the **last** `/` (the hex part has none, a
   tenant id might).
2. It asks an `IJwtKeyResolver` for that tenant's key and verifies the signature.
3. **It requires the verified claim (`TENANT_CLAIM`) to equal the tenant of the `kid`**, or 401.
   Without this, a tenant whose key leaked could sign tokens claiming any other tenant.
4. `TTenantMiddleware` runs after it, unchanged (unknown and suspended tenants, decision 7 of
   the multitenancy design).

A key for a tenant is created the first time that tenant signs (its first login), as
generation 1 signing at once (nothing to propagate: no instance holds an older key of it).

To keep decision 1 of `docs/multitenancy-design.md`, `TJwtMiddleware` knows only
`IJwtKeyResolver` (find a key by `kid`, the signing key for a scope, an optional claim to
check). The tenant-aware resolver lives with the tenancy units; an API without tenants uses a
resolver with the single scope `''`.

Rejected: deriving each tenant's key from one master secret (HMAC of the master, the tenant and
a generation). Nothing to store, but a leaked master signs for every tenant.

## Phase 2 as built (2026-10-18)

- `TJwtKey` gained `Generation`, `CreatedAt`, `ActiveFrom`. `TJwtRotationOptions.Default`:
  rotate 30 days, propagation 120 s, token 3600 s, reload 60 s; the constructor refuses
  `PropagationSeconds < ReloadSeconds`, a `MaxTokenSeconds` of 0 and a scope with `/`.
- The constructor loads (and adds the first key, signing at once) and raises on the store's
  error; later reloads keep the loaded keys and report through `OnError` (a `TPcLogProc`). One
  thread reloads at a time, outside the lock; a failed reload waits `ReloadSeconds` too.
- The first test found a reload on the first request after startup: the constructor didn't
  record when it loaded. Fixed before the commit.
- A kid is 16 lowercase hex digits (8 random bytes), `<scope>/<hex>` with a scope; a secret is
  32 random bytes in Base64url (43 characters).
- `TDbJwtKeyStore`'s SQL names: `JWT_KEY.BY_TENANT`, `JWT_KEY.INSERT`, `JWT_KEY.DELETE`. A
  lost race is `TryAdd`'s False through the adapter's `cvUnique` (tested with the mock's
  `AddConstraintViolation`). Over HTTP, two instances rotated on one SQLite file and one Redis
  with no reload error in either log; whether they ever hit the same generation at the same
  instant isn't visible from there. So a probe (2026-10-18, FPC 3.2.2 Windows, SQLdb, sample
  03's schema) stored generation 1 twice through `TDbJwtKeyStore`: the second `TryAdd` was
  False, not an exception, and one row stayed; the same for a repeated kid (its own unique
  key). That probe became sample 03's `--check-key-store` (run by both HTTP runners); on Delphi
  12 with FireDAC (Win32 and Win64) it answered the same: False, one row.
- `TRedisJwtKeyStore` deletes by finding the kid's generation (`HGETALL`, then `HDEL`).
- Rotation happens on a request, not on a timer: the HTTP check first expected a rotation
  during an idle wait and failed; the script now keeps both instances busy.
- Measured with `tools/http_scenarios_jwt_rotation.sh` (two instances of sample 03, keys every
  3 s): 22 checks on the database and on Redis 7.2, on FPC Windows and Linux and on Delphi 12
  Win32/Win64 (FireDAC); 323 unit tests, 0 leaks, on all four.

## Phase 3 as built (2026-10-18)

The design's `IJwtKeyResolver` became no new interface: `TTenantJwtKeyRing` is an
`IJwtKeyRing`, so `TJwtMiddleware` didn't change. Two additions to the ring contract carry what
the resolver would have: `SigningKey(AClaims, ...)` (the claims pick the tenant) and
`ScopeClaim` (the claim `TJwtKeys.Decode` checks against the key's `Scope`; '' for the static
and plain rotating rings, which check nothing). Taken as consequences of the design's rules
and shown to the user, who asked for no change (2026-10-18):

- **Which tenants get a ring.** "A kid is only looked up in memory" (decision 2) ruled out
  creating a ring, or asking the catalog, for whatever tenant a kid names: a client could make
  the API query the store and the catalog with each made-up kid (`TCachedTenantCatalog` doesn't
  keep misses). So rings exist for the catalog's tenants (`All`, at creation and every
  `ReloadSeconds` on a request) and for a tenant that signs, after `Find` (the login already
  checked it). A tenant provisioned on another instance is known here at the next catalog read.
- **The first key of a tenant** is made when its ring is created (at startup for every tenant
  of the catalog), not at its first login as decision 8 said: the ring's constructor always
  ensures a key, and a tenant's tokens must verify on every instance anyway.
- **The legacy secret is one for every tenant.** A token without kid has no key scope to check
  its claim against. Documented as a pitfall: drop it once the old tokens expired.
- **A wrong claim is `jrBadSignature`**, so the 401 is the same as a bad signature's (decision 2).

Measured: `TTenantJwtKeyRingTests` (7 tests: 50 unknown tenants' kids with no store load and no
catalog query, acme's key refused on globex's claim, a tenant added to the catalog later, each
tenant rotating on its own) and `tools/http_scenarios_jwt_rotation.sh` (acme's secret read from
`control.sqlite` and tried on a token claiming globex: 401), on FPC Windows and Linux and
Delphi 12 Win32/Win64 (330 tests, 0 leaks; 29 checks on the database, 25 on Redis).

## Where each piece lives (proposal)

| Piece | Unit |
|---|---|
| `TJwt.SignHS256(AClaimsJson, ASecret, AKid)`, `TJwt.ReadKid(AToken, out AKid)` | `PascalApi.Jwt` |
| `TJwtKey`, `IJwtKeyRing`, `IJwtKeyResolver`, the static ring, `JWT_KEYS`, the life rules of decision 3 | new `PascalApi.JwtKeys` |
| `IJwtKeyStore`, `TDbJwtKeyStore`, the rotating ring | `PascalApi.JwtKeys` (the core already uses pascal-db-faa) |
| `TRedisJwtKeyStore` | `src/redis/PascalApi.Redis.JwtKeys`, outside the `.lpk` (decision 5) |
| The per-tenant resolver | `PascalApi.Tenancy` |
| `TJwtMiddleware.New(AResolver, ...)`, `TJwtMiddleware.Sign`, `Claims` with the resolver | `src/horse/PascalApi.Horse.Middlewares` |

OpenAPI and MCP don't change: the document asks the middleware only `Configured`/`Excludes`, and
the MCP executor forwards the caller's `Authorization` header as it is.

## Phases

1. **Done (2026-10-18).** `kid` in `TJwt`, the static ring, `JWT_KEYS`, the legacy secret,
   the middleware overloads and `Sign`. Unit tests; sample 01 keeps `New(secret)` and its 186
   checks pass unchanged; sample 03 uses the ring.
2. **Done (2026-10-18).** `PcRandomBytes` in pascal-common-faa 1.15.0 (`PascalCommon.Random`),
   `TRotatingJwtKeyRing`, `TDbJwtKeyStore`, `TMemoryJwtKeyStore` and `TRedisJwtKeyStore`. As
   built: see "Phase 2 as built".
3. **Done (2026-10-18).** The per-tenant ring and the claim check, in sample 03. As built:
   see "Phase 3 as built".

Then the guide: `docs/guide/authentication.md` (rotation, its settings, the pitfall above
replaced) and `docs/guide/multitenancy.md`.

## How it will be tested

- Unit, with a manual `TClock`/`TTicker`: the life of a key over a whole rotation (pending
  verifies but doesn't sign; the old key verifies until `NotAfter`, not one second more);
  unknown `kid`; a `kid` too long or not a string; the legacy secret with and without a ring;
  `Sign` refusing a missing or too late `exp`; two rings sharing one mock store and racing on
  generation n+1 (one key, both use it); `NotAfter` derived from the next key, so nothing is
  updated in the store.
- Redis store, against a real server: the same race on `HSETNX`, and a reload after the hash is
  deleted (the case of a Redis that lost its data: every token refused, new keys created).
- HTTP (`tools/http_scenarios_tenants.sh`, which signs with Python's `hmac` and so must add the
  `kid`): a token from before a rotation still accepted after it; a token signed with tenant
  A's key claiming tenant B refused (401); a `kid` naming tenant B with A's secret refused; a
  removed key's token refused.
- The existing scenarios of samples 01 and 02 pass unchanged: the opt-in check.

## Not in this design

- Asymmetric signatures (RS256, ES256) and a JWKS endpoint: they would let other systems verify
  without the secret, but need RSA or ECDSA on both compilers.
- Refresh tokens: they make short access tokens practical, which shortens `MaxTokenLifetime`,
  but they are an application's flow.
- Envelope encryption with an external KMS or Vault: possible behind `IJwtSecretCipher`, not
  shipped.
- Announcing a new key through Redis Pub/Sub: the propagation delay (decision 4) already covers
  it, without a subscriber per instance.
