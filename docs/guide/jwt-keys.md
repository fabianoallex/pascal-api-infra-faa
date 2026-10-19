# JWT signing keys and rotation

The keys that sign your API's tokens: naming them so they can change without logging anyone
out, letting them rotate by themselves, one per tenant, sealed in their store, and what to do
when one leaks. The code comes from `samples/03-tenants`, which runs every mode
(`JWT_KEY_STORE=static`, `db`, `redis`). `PascalApi.JwtKeysTests` and
`PascalApi.JwtRotationTests` cover the rings and the stores (a test clock, second by second),
`tools/http_scenarios_tenants.sh` the static keys over HTTP, and
`tools/http_scenarios_jwt_rotation.sh` the generated ones, with two instances of the sample on
one store. The decisions behind it: `docs/jwt-keys-design.md`.

Verifying tokens, the open routes and the login are in [Authentication](authentication.md);
this guide starts where one secret is no longer enough. Short access tokens with refresh tokens,
which keep `MaxTokenSeconds` small: [Refresh tokens](refresh-tokens.md).

## What it solves

With `TJwtMiddleware.New(ASecret)` one secret signs and verifies everything. Changing it
invalidates every token at once, so it is rarely changed; if it leaks, whoever has it signs
tokens for any user (and, in a multi-tenant API, any tenant) until it changes; and wherever it
is stored, whoever reads it has the same power.

The library's answer, in layers you take as far as you need:

- **Named keys**: each token says which key signed it (`kid` in its header). The newest key
  signs, older ones keep verifying until their tokens expire: a change logs nobody out.
- **Rotation by itself**: the keys are generated and replaced on a schedule, in a database or
  Redis that every instance of the API shares.
- **A key per tenant**: a tenant's key signs only that tenant's tokens.
- **Sealed secrets**: the store keeps them encrypted under a master key that never goes there.

All of it is opt-in: `New(ASecret)` keeps working as before.

## The smallest working program

Two keys from the configuration; the first signs. Shortened from sample 03 and sample 01's
login:

```pascal
GKeys := TStaticJwtKeyRing.Parse(TAppConfig.Get('JWT_KEYS'), TAppConfig.Get('JWT_SECRET'), 3600);
THorse.Use(TJwtMiddleware.New(GKeys, ['/health', '/auth/login']));
...
// the login's access token: sign as the middleware verifies
Result := TJwtMiddleware.Sign(LWriter.ToString);
```

```
JWT_KEYS=k2:<new secret>,k1:<old secret>@1767225600
JWT_SECRET=<the secret you used before>
```

Tokens signed with k2 or k1 verify (k1 until its date); tokens from before, without `kid`,
verify with `JWT_SECRET`.

## Step by step

### 1. Name the keys: a static ring

`TStaticJwtKeyRing` (`PascalApi.JwtKeys`) holds keys fixed at startup. From sample 03:

```pascal
GSecret := TAppConfig.Get('JWT_SECRET', 'development-secret-change-me');
...
Exit(TStaticJwtKeyRing.Parse(TAppConfig.Get('JWT_KEYS', DEFAULT_JWT_KEYS), GSecret,
  TOKEN_SECONDS));
```

- **`JWT_KEYS`** lists `kid:secret` or `kid:secret@notAfter` (Unix seconds), separated by
  commas; the first entry signs, every one verifies until its `notAfter`. A `kid` is 1 to 128 of
  `A-Z a-z 0-9 . _ -`; a secret has no `,` and no `@`. Anything else stops the program at startup
  (`EJwtKeyError`, whose message never contains a secret).
- **The legacy secret** (second argument): a token without `kid` verifies with it, so the
  tokens issued before the ring stay valid. `''` refuses them.
- **The longest lifetime** (third argument, seconds; 0: no limit): `Sign` refuses claims whose
  `exp` is later.
- A `kid` the ring doesn't know, or one past its `notAfter`, gets the same 401 as a bad
  signature: the client isn't told which keys exist. The `kid` is read before the signature is
  checked and only looked up in memory.

Checked over HTTP by `tools/http_scenarios_tenants.sh` ("signing keys": a token of the
previous key, an unknown `kid`, a key past its date, a `kid` signed with another key's secret).

### 2. Sign through the middleware

```pascal
THorse.Use(TJwtMiddleware.New(GKeys, ['/health', '/metrics', '/auth/login', '/auth/refresh',
  '/auth/logout', '/swagger']));
...
Result := TJwtMiddleware.Sign(LWriter.ToString);   // AccessToken, for the login and the refresh
```

`TJwtMiddleware.Sign` signs with whatever the middleware verifies with (the ring's signing key,
its `kid` in the header). It refuses claims without an integer `exp`, or with one later than the
ring's longest lifetime or than the signing key's end (`EArgumentException`): such a token
would stop verifying before it expires. `TJwtMiddleware.Claims(AReq)` reads a request's claims
with the ring too.

### 3. Let the ring rotate: generated keys

`TRotatingJwtKeyRing` makes its keys (32 random bytes from the operating system) and keeps them
in an `IJwtKeyStore` every instance shares. From sample 03 (`OpenKeys`, `JWT_KEY_STORE=db`):

```pascal
LOptions := TJwtRotationOptions.Default;   // 30 days, 120 s, 3600 s, 60 s
LOptions.MaxTokenSeconds := TOKEN_SECONDS;
LOptions.LegacySecret := GSecret;           // tokens without kid, as in step 1
LOptions.RotateEverySeconds := SecondsSetting('JWT_ROTATE_SECONDS', LOptions.RotateEverySeconds);
...
LStore := TDbJwtKeyStore.Create(AControl);
```

and then the ring (step 5 shows the per-tenant one sample 03 uses; without tenants it is
`TRotatingJwtKeyRing.Create(LStore, LOptions)`, with `OnError` set to your log).

A key's life:

| State | From | Until | Signs | Verifies |
|---|---|---|---|---|
| pending | stored | `ActiveFrom` (stored + `PropagationSeconds`) | no | yes |
| signing | `ActiveFrom` | the next key's `ActiveFrom` | yes | yes |
| verifying | the next key's `ActiveFrom` | that + `MaxTokenSeconds` | no | yes |
| gone | | | no | no (deleted) |

- **When**: a new key comes when the newest is `RotateEverySeconds` old.
- **On a request, not on a timer**: every `ReloadSeconds` the first request that needs a key
  reads the store again and, when the time has come, adds the next key. No thread; an idle API
  rotates at its next request.
- **Several instances**: each may try to add the same next key; the store keeps one, the others
  read it. `PropagationSeconds` must be at least `ReloadSeconds` (checked when the ring is
  created): every instance has a key before a token signed with it arrives.
- **The store down**: at startup the constructor raises (no keys, no API); later the loaded keys
  keep working, `OnError` hears about it, and the reload is tried again after `ReloadSeconds`.

### 4. The store: a table or Redis

**A table** (`TDbJwtKeyStore`, pascal-db-faa), through your SQL by name. Sample 03's
(`TenantApiSample.Control`):

```sql
CREATE TABLE JWT_KEYS (TENANT_ID VARCHAR(40) NOT NULL, GENERATION INTEGER NOT NULL,
  KID VARCHAR(128) NOT NULL, SECRET VARCHAR(255) NOT NULL, CREATED_AT BIGINT NOT NULL,
  ACTIVE_FROM BIGINT NOT NULL, CONSTRAINT PK_JWT_KEYS PRIMARY KEY (TENANT_ID, GENERATION),
  CONSTRAINT UQ_JWT_KEYS_KID UNIQUE (KID));
-- JWT_KEY.BY_TENANT
SELECT KID, SECRET, GENERATION, CREATED_AT, ACTIVE_FROM FROM JWT_KEYS WHERE TENANT_ID = :TENANT_ID
-- JWT_KEY.INSERT
INSERT INTO JWT_KEYS (TENANT_ID, GENERATION, KID, SECRET, CREATED_AT, ACTIVE_FROM)
  VALUES (:TENANT_ID, :GENERATION, :KID, :SECRET, :CREATED_AT, :ACTIVE_FROM)
-- JWT_KEY.DELETE
DELETE FROM JWT_KEYS WHERE TENANT_ID = :TENANT_ID AND KID = :KID
```

`TENANT_ID` is `''` without tenants. The primary key settles two instances rotating at once: the
second insert of a generation is a unique violation, which `TryAdd` turns into "someone else
won". Sample 03's `--check-key-store` checks it on the adapter it was built with: on SQLite,
SQLdb (FPC) and FireDAC (Delphi) both answered False and kept one row. A row is only ever added or deleted, never
updated.

**Redis** (`TRedisJwtKeyStore`, `src/redis/PascalApi.Redis.JwtKeys`, outside the package as
`src/horse` is; add `src/redis` and your pascal-redis-faa to the search path). From sample 03
(`JWT_KEY_STORE=redis`):

```pascal
LStore := TRedisJwtKeyStore.Create(TRedisClient.Create(LParams),
  TAppConfig.Get('JWT_REDIS_PREFIX', 'tenants-api:'), True);
```

The sample's store owns its client (the third argument) because it uses Redis for nothing else;
an API that does passes its one `TRedisClient`. One hash per scope (`tenants-api:jwt-keys:acme`),
field = the generation, value = the key as JSON; `HSETNX` settles the race.

Checked by `tools/http_scenarios_jwt_rotation.sh` on both stores: sample 03 twice on one store,
keys every 3 seconds; a login's `kid` changes, a token of an older key keeps verifying, and the
two instances sign with one key and verify each other's tokens, also after racing.

### 5. A key per tenant

`TTenantJwtKeyRing` (`PascalApi.Tenancy`) keeps one rotating ring per tenant on one store. From
sample 03:

```pascal
LRing := TTenantJwtKeyRing.Create(GCatalog, LStore, LOptions, GClaim, ALog.Error);
```

- **The tenant is in the `kid`** (`acme/1f0c...`). A token verifies only with its tenant's key
  **and** only when its tenant claim names that tenant: acme's key on a token claiming globex
  is the same 401 as a bad signature.
- **Signing** reads the tenant from the claims; claims without one, or naming one the catalog
  doesn't have, raise `EJwtKeyError` (a 500: the login checks the tenant first, step 5 of
  [Multi-tenancy](multitenancy.md)).
- **Which tenants have keys**: the catalog's (read when the ring is created and every
  `ReloadSeconds`, on a request) and a tenant that signs. A `kid` naming any other tenant is
  refused without asking the store or the catalog.
- **Each tenant rotates on its own requests.**
- **The legacy secret is one for every tenant**: tokens without `kid` carry no tenant to check.

Checked over HTTP: acme's secret read from the store and tried on a token claiming globex (401),
a `kid` naming a tenant that doesn't exist, each tenant its own key; in `TTenantJwtKeyRingTests`,
50 unknown tenants' kids with no store or catalog query, and a tenant added to the catalog later.

### 6. Seal the secrets

Wrap the store, and the secrets are kept sealed with AES-256-GCM. From sample 03:

```pascal
LMaster := TAppConfig.Get('JWT_KEYS_MASTER_KEY', DEFAULT_MASTER_KEY);
if LMaster <> '' then
  LStore := TSealedJwtKeyStore.Create(LStore, TAesGcmSecretCipher.Create(LMaster),
    TAppConfig.GetBool('JWT_KEYS_REQUIRE_SEALED', False));
```

- **`JWT_KEYS_MASTER_KEY`**: `id:<base64 of 32 bytes>` entries separated by commas; the first
  seals, every one opens. Make a key with `openssl rand -base64 32`.
- **A sealed secret** is `aesgcm:v1:<master id>:<nonce>:<ciphertext and tag>`, about 110
  characters, bound to its place (tenant, `kid`, generation): copied to another row it doesn't
  open.
- **Plain secrets stored before** still load (third argument `False`); new keys are sealed.
- **Errors** (`EJwtKeyError`) name the master id and the key's place, never a secret or a master
  key. At startup they stop the API; later the loaded keys stay in use and `OnError` hears.
- `IJwtSecretCipher` is the contract: a KMS or Vault can implement it instead.

The AES is pascal-common-faa's `PascalCommon.AesGcm`, checked against NIST's and OpenSSL's
vectors. Its S-box is a table lookup, which a process sharing the CPU could time: fine here,
where a secret is opened when the keys reload, never from what a client sends. Checked over
HTTP: every secret in sample 03's database is sealed, and acme's opens with OpenSSL (Python's
cryptography); in `TSealedSecretTests`, a value sealed by OpenSSL opens here.

## Choices

| You need | Use |
|---|---|
| to change the secret once in a while, by hand, without logging users out | `TStaticJwtKeyRing` (step 1) |
| keys that change by themselves, one or more instances | `TRotatingJwtKeyRing` on `TDbJwtKeyStore` or `TRedisJwtKeyStore` (steps 3, 4) |
| a multi-tenant API where one tenant's key can't sign for another | `TTenantJwtKeyRing` (step 5) |
| a store whose readers (or backups) mustn't be able to sign | `TSealedJwtKeyStore` (step 6) |

**A table or Redis**: the table when the API has a database (it is durable and backed up, and
the race is settled by a primary key); Redis when it already runs one and has no database of its
own, configured to keep the keys (see Pitfalls).

**The timings** (`TJwtRotationOptions`):

- `MaxTokenSeconds`: your tokens' lifetime (the sample's is an hour). An old key lives this
  long after the next one signs, so it is also how long a stolen token keeps working.
- `RotateEverySeconds` (30 days): how long one key signs. Shorter limits what a leaked key
  signs; it costs a store write per rotation and scope, nothing more.
- `ReloadSeconds` (60): how soon an instance sees a new key or a deletion (a revocation).
- `PropagationSeconds` (120, at least `ReloadSeconds`): how long a new key waits before signing.

**Static and generated keys don't mix**: a rotating ring doesn't know the kids of `JWT_KEYS`,
and the legacy secret only covers tokens without `kid`. Moving from static to generated keys
logs out the users whose tokens carry a static `kid`: do it at a moment you can afford.

## Procedures

Things to do with the keys of a running API. The settings named here are sample 03's; the
library reads none of them itself (the application does, with `TAppConfig`).

### From one secret to a key ring

1. Deploy the ring with the old secret as the legacy secret (`JWT_SECRET` in the sample): the
   tokens already issued verify, new ones carry a `kid`.
2. After the longest token lifetime, remove the legacy secret (`''`): a token without `kid` is
   then refused. In a multi-tenant API this matters more: the legacy secret signs for every
   tenant.

### Rotate a static key by hand

1. Put the new key first and give the old one a `notAfter` at least one token lifetime ahead:
   `JWT_KEYS=k3:<new>,k2:<old>@<now + 3600>`. Restart every instance.
2. After that date, remove the old entry.

### Revoke a key that leaked

- **Static**: remove its entry from `JWT_KEYS` and restart every instance. Its tokens are refused
  at once.
- **Generated**: delete **every** key of the scope from the store (`DELETE FROM JWT_KEYS WHERE
  TENANT_ID = ''`, or the tenant's id; in Redis, `DEL <prefix>jwt-keys:<scope>`). At each
  instance's next reload (within `ReloadSeconds`) the old keys stop verifying, and the first
  request makes a new key that signs at once (tested: `Revoke_WipeTheScope`). Every user of that
  scope logs in again.
  - Within `ReloadSeconds`, an instance that hasn't reloaded still accepts the old keys, and
    refuses tokens signed with the new one; restart them all to close that window.
  - **Don't delete only the signing key**: the key before it becomes the newest again and signs
    (tested: `Revoke_OnlyTheSigningKey_ThePreviousSignsAgain`). If that one is safe and you want
    to keep its users, delete the signing key and accept it; otherwise wipe the scope.
- **One tenant's**: wipe that tenant's scope only; the others are untouched.

### Rotate the master key

In two steps, so that no instance meets a secret it can't open:

1. Add the new master key **second** everywhere: `JWT_KEYS_MASTER_KEY=m1:<old>,m2:<new>`, and
   restart every instance. They seal with m1 still, and can all open m2.
2. Move it first: `m2:<new>,m1:<old>`, restart every instance. New keys are sealed with m2.
3. After `RotateEverySeconds` + `PropagationSeconds` + `MaxTokenSeconds`, every key sealed with
   m1 is gone; remove m1.

An instance that meets a secret sealed with a master id it doesn't have can't load that key: it
keeps the keys it had and reports it (`OnError`), and refuses tokens signed with the key it
couldn't load.

### Turn sealing on for an existing store

1. Set the master key. Keys already stored stay plain and load; every new key is sealed.
2. After `RotateEverySeconds` + `PropagationSeconds` + `MaxTokenSeconds` (and a reload) the
   plain ones are gone
   (check: `SELECT COUNT(*) FROM JWT_KEYS WHERE SECRET NOT LIKE 'aesgcm:v1:%'` is 0).
3. Require it (`JWT_KEYS_REQUIRE_SEALED=true`): a plain secret in the store is then an error, so
   a row someone writes by hand isn't trusted.

### The store lost its keys

Redis restarted without persistence, or someone emptied the table: at the next reload every
instance finds no key, one of them makes a new one, and every token is refused (users log in
again). The window and the cure are the revocation's above. Prevent it on Redis (Pitfalls).

## Pitfalls

- **A Redis that forgets.** Without persistence (RDB or AOF) a restart loses the keys, and an
  eviction policy other than `noeviction` (or a `volatile-*` one, since the hashes have no TTL)
  can evict them under memory pressure.
- **Instances with different `MaxTokenSeconds`.** An old key's end is computed from it, never
  stored: two instances would disagree on when a key stops verifying.
- **The master key next to the data it protects** (in the same database, in a `.env` copied
  with the backups). Keep it in the environment or your platform's secret store.
- **Sealed secrets that don't fit**: about 110 characters. Size the column for them
  (`VARCHAR(255)`); what a smaller one does depends on the database (SQLite stores them anyway;
  the others weren't tried here).
- **Deleting only the signing key** to revoke it (Procedures).
- **A legacy secret kept forever**: it signs tokens without `kid`, for every tenant.
- **`TMemoryJwtKeyStore` in production**: each process has its own keys and refuses the others'
  tokens, and a restart logs everyone out. It is for tests.
- **Removing a static key too early**: its tokens are refused from that moment.
- **Expecting a rotation while idle**: rotation happens on a request. Nothing is wrong with an
  idle API keeping its key; a check that waits without requests won't see one (the HTTP script
  keeps the instances busy).
- **The sample's development keys in production** (`DEFAULT_JWT_KEYS`, `DEFAULT_MASTER_KEY`,
  `JWT_SECRET`'s default): anyone who read the sample has them.

## Testing your application

Rotation depends on two clocks: the wall clock (`TClock`, the keys' dates) and the monotonic one
(`TTicker`, the reload interval). Replace both and move them together, as
`PascalApi.JwtRotationTests` does:

```pascal
procedure Advance(ASeconds: Int64);
begin
  Inc(GNow, ASeconds);                          // what TRotationClock answers
  Inc(GTickMs, UInt64(ASeconds) * 1000);        // what TRotationTicker answers
end;
...
TClock.SetClock(TRotationClock.Create);
TTicker.SetTicker(TRotationTicker.Create);
```

Then `TMemoryJwtKeyStore` as the store, two rings on one store for two instances, and
`TMockDBFactory` for your `TDbJwtKeyStore` SQL names (`AddConstraintViolation` plays the
instance that lost the race).

Over HTTP, run your API with seconds instead of days (sample 03: `JWT_ROTATE_SECONDS=3
JWT_PROPAGATION_SECONDS=2 JWT_RELOAD_SECONDS=1`) and log in until the `kid` changes; see
`tools/http_scenarios_jwt_rotation.sh`, which also reads a sealed secret from the database and
opens it with Python's cryptography to forge a token the API must refuse.

## Reference

- `PascalApi.JwtKeys`: `TStaticJwtKeyRing`, `TRotatingJwtKeyRing`, `TJwtRotationOptions`,
  `IJwtKeyStore` with `TDbJwtKeyStore` and `TMemoryJwtKeyStore`, `IJwtSecretCipher`,
  `TAesGcmSecretCipher`, `TSealedJwtKeyStore`, `TJwtKeys` (sign and decode by `kid`).
- `PascalApi.Tenancy`: `TTenantJwtKeyRing`.
- `src/redis/PascalApi.Redis.JwtKeys`: `TRedisJwtKeyStore`.
- `PascalApi.Jwt`: `TJwt.SignHS256` with a `kid`, `TJwt.ReadKid`.
- `src/horse/PascalApi.Horse.Middlewares`: `TJwtMiddleware.New(ARing, ...)`, `Sign`, `Claims`.
- pascal-common-faa: `PascalCommon.Random` (the keys' bytes), `PascalCommon.AesGcm` (the seal).
- `samples/03-tenants` (`OpenKeys`, `TenantApiSample.Control`); `tools/http_scenarios_tenants.sh`,
  `tools/http_scenarios_jwt_rotation.sh`.
- `docs/jwt-keys-design.md`: the decisions and what was measured.
- [Authentication](authentication.md), [Multi-tenancy](multitenancy.md),
  [Configuration](configuration.md).
