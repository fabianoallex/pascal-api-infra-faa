# Authentication

Who may call which route: a token in the `Authorization` header, checked before the handler
runs. The code comes from `samples/01-api` and `samples/03-tenants`. `PascalApi.CryptoTests`
(`TJwtTests`) covers signing and verifying, `PascalApi.JwtKeysTests` and `PascalApi.JwtRotationTests` the key rings, `PascalApi.HttpTests` the header parsing and the
excluded paths, and `tools/http_scenarios.sh` the answers over HTTP. A few behaviours below were
measured for this guide (2026-10-14), and each one says where.

## What it solves

Most routes of an API need to know who is calling, and must refuse a caller who can't prove it.
Some routes must stay open: the login itself, health checks, metrics, the documentation.

The library gives you two middlewares, both reading `Authorization: Bearer <token>`:

- **`TJwtMiddleware`**: the token is a JSON Web Token signed with HS256 (HMAC-SHA256) and a
  secret your API keeps. The middleware checks the signature and the expiry; the handler reads
  the token's claims (who the user is). `TJwt` (`PascalApi.Jwt`) issues the tokens.
- **`TAuthMiddleware`**: you check the token with your own function (an opaque token looked up
  in a database, a token from another issuer).

Both answer 401 with `{"error": ...}` and leave a list of path prefixes open.

## The smallest working program

From `samples/01-api/ApiSample.dpr`, shortened:

```pascal
uses
  SysUtils, Horse, PascalJsonMapper.Json, PascalApi.Config, PascalApi.Http, PascalApi.Jwt,
  PascalApi.Horse.Middlewares;

var
  GSecret: string;

procedure PostLogin(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
// checks the user and answers {"token": TJwt.SignHS256(<claims>, GSecret)} (step 3)

procedure GetMe(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LClaims: TJsonValue;
begin
  LClaims := TJwtMiddleware.Claims(AReq);
  try
    TJsonSend.Send(ARes, JsonMember('sub', LClaims.Find('sub').AsString));
  finally
    LClaims.Free;
  end;
end;

begin
  GSecret := TAppConfig.Get('JWT_SECRET', 'development-secret-change-me');
  TErrorHandlerMiddleware.Register;
  THorse.Use(TLoggerMiddleware.New);
  THorse.Use(TJwtMiddleware.New(GSecret, ['/health', '/metrics', '/auth/login', '/swagger']));
  THorse.Post('/auth/login', PostLogin);
  THorse.Get('/me', GetMe);
  THorse.Listen(9310);
end.
```

```
GET  /me                                     401  {"error":"Authorization token missing."}
POST /auth/login {"user":"ana"}              200  {"token":"eyJhbGciOiJIUzI1NiIs..."}
GET  /me  Authorization: Bearer eyJhbGci...  200  {"sub":"ana"}
```

(each line checked by `tools/http_scenarios.sh`.)

## Step by step

### 1. The secret

The same secret signs and verifies, so it is the key to your API: whoever has it can issue a
token for any user. Read it from the configuration (see [Configuration](configuration.md)):

```pascal
GSecret := TAppConfig.Get('JWT_SECRET', 'development-secret-change-me');
```

The samples have a development default because they are samples. In production, make it
required (Configuration, "Choices") and use a long random value, at least 32 bytes (for
example, 64 hex digits). The library doesn't check the length. It does refuse an empty secret:
`TJwtMiddleware.New` raises `EArgumentException`, and `TJwt.Decode` verifies nothing against an
empty secret (tested: `Decode_EmptySecret_Refused`), since anyone can sign with an empty key.

The secret is text, used as its UTF-8 bytes; a non-ASCII secret works (tested:
`Decode_NonAsciiClaimsAndSecret`).

### 2. Protect the routes, and leave some open

`TJwtMiddleware.New` is a global middleware: it runs before every route except those under the
prefixes you list.

```pascal
THorse.Use(TLoggerMiddleware.New);                                  // first
THorse.Use(TCorsMiddleware.New('https://app.example.com'));          // before JWT
THorse.Use(TJwtMiddleware.New(GSecret, ['/health', '/metrics', '/auth/login', '/swagger']));
```

How a prefix matches (tested: `PathMatches_*`):

| Prefix | Leaves open | Doesn't |
|---|---|---|
| `/auth/login` | `/auth/login`, `/auth/login/x` | `/auth/login-admin` (also checked over HTTP: 401) |
| `/health` | `/health`, `/health/live`, `/Health` (case is ignored) | `/healthz` |
| `/public/` | `/public/x` and below | `/public` itself |
| `''` | nothing | |

The match is on whole segments: a route added later whose name merely starts like an open one
stays protected. The prefixes are compared with the path as Horse gives it, without resolving
`..`: on sample 01, `/health/../me`, `/health/%2e%2e/me`, `/auth/login/../../me` and
`/health/..%2fme` all answered 404 without a token, and `//me`, `/ME` and `/me/` answered 401
(measured on FPC and on Delphi 12 Win32, 2026-10-14). Horse doesn't route `..`, so a path can't
borrow an open prefix to reach a protected route.

Order matters:

- **CORS before JWT**: a browser's preflight (`OPTIONS`) never carries the token; CORS answers
  it with 204 before JWT would refuse it (checked over HTTP on `/cities`; measured on `/me`).
- **The logger before both**: it sets the request id and writes the access line, 401s
  included, and answers an exception a middleware after it raises
  ([Errors and validation](errors.md), step 5).

### 3. Issue a token: the login route

The login route is one of the open prefixes. It checks who the caller is (the sample doesn't:
any user name gets a token; your check of a password or of another system goes there), then
signs the claims. From `samples/01-api/ApiSample.dpr`:

```pascal
LWriter := TJsonWriter.Create;
try
  LWriter.BeginObject;
  LWriter.Name('sub');
  LWriter.WriteString(LUser.AsString);
  LWriter.Name('exp');
  LWriter.WriteInt64(TJwt.UnixNow + 3600);      // one hour
  LWriter.EndObject;
  LClaims := LWriter.ToString;
finally
  LWriter.Free;
end;
...
TJsonSend.Send(ARes, JsonMember('token', TJwt.SignHS256(LClaims, GSecret)));
```

- `sub` is the subject, the user's id. Any other claim is yours to add: sample 03 adds the
  tenant (`tenant_id`, see [Multi-tenancy](multitenancy.md), step 5).
- `exp` is the expiry, in seconds since 1970 (UTC). `TJwt.UnixNow` is the current time in those
  units, from pascal-common-faa's `TClock`.
- `nbf` ("not before") is also checked when present.
- **Write the claims with `TJsonWriter`**, never by joining strings: a user name like
  `x","admin":true` would add a claim of its own to a concatenated JSON.

The token is the standard compact form, `header.payload.signature`, with the header
`{"alg":"HS256","typ":"JWT"}` (tested against jwt.io's example: `Sign_JwtIoExample`). Tokens
from another HS256 signer with the same secret are accepted: `tools/http_scenarios_tenants.sh`
signs its tokens with Python's `hmac`.

### 4. Read the claims in a handler

```pascal
LClaims := TJwtMiddleware.Claims(AReq);
try
  LSub := LClaims.Find('sub');
  if LSub = nil then
    raise EValidationException.Create('The token has no subject.');
  ...
finally
  LClaims.Free;
end;
```

`Claims` verifies the token again with the middleware's secret and returns the payload as
pascal-jsonmapper-faa's `TJsonValue`; **the caller frees it**. It returns nil when there is no
valid token: on a route under an open prefix, or when only `TAuthMiddleware` is in use
(`TJwtMiddleware.New` never called; measured with a probe). Until 0.13.0 a token signed with
an empty key was decoded there (measured with the same probe before the fix).

`Find` returns nil for a claim the token doesn't have: check it before `.AsString`. Sample 01's
`GetMe` doesn't, because its own login always writes `sub`.

### 5. What a refused request gets

| Request | Status | Body (`TApiMessages`) | `WWW-Authenticate` |
|---|---|---|---|
| no `Authorization` | 401 | `TokenMissing`: "Authorization token missing." | `Bearer` |
| another scheme (`Basic ...`) | 401 | `TokenBadFormat`: "Invalid format. Use: Authorization: Bearer <token>" | `Bearer` |
| `Bearer` with nothing after it | 401 | `TokenInvalid`: "Invalid or expired token." | `Bearer error="invalid_token"` |
| bad signature, malformed, expired, not yet valid, another `alg` | 401 | `TokenInvalid` | `Bearer error="invalid_token"` |

The bodies and headers of the first, second and fourth rows are checked over HTTP; the header
values come from `BearerChallenge` (tested). HTTP requires the `WWW-Authenticate` header on a
401 (RFC 9110); the values are RFC 6750's. Until 0.13.0 there was none.

The scheme name ignores case and spaces around the token are trimmed (`bearer   xyz  ` is
`xyz`, tested). The body doesn't say *why* a token was refused (expired or forged): `TJwt.Decode`
does (`TJwtResult`), if you call it yourself. A 401 isn't an error to log; the access line has
its status.

### 6. Your own tokens: `TAuthMiddleware`

When the token isn't a JWT signed by your API, pass a function that decides:

```pascal
type
  TApp = class
    function CheckToken(const AToken: string): Boolean;
  end;

function TApp.CheckToken(const AToken: string): Boolean;
begin
  Result := ...;   // look it up, call the issuer, ...
end;

THorse.Use(TAuthMiddleware.Bearer(GApp.CheckToken, ['/health', '/public']));
```

The function is a method on FPC and may be a closure on Delphi (`TTokenValidator`, see
[Getting started](getting-started.md), step 8). The answers are the same as `TJwtMiddleware`'s
(step 5). No sample uses it; a probe measured it on FPC/Windows: no token 401, a token the
function accepts 200, one it refuses 401 `TokenInvalid`, a route under `/public` open. The
function runs on every request, on Horse's threads: keep it fast, and thread-safe.

### 7. Where else the token goes

- **OpenAPI**: `TRouteDoc.Serve` asks the middleware which scheme is in use and which paths it
  leaves open, and documents those as needing no token (`"security": []`). There is no second
  list to keep in step ([OpenAPI](openapi.md), step 7).
- **MCP**: a tool call goes back through the API over HTTP with the caller's token, so every
  route keeps its own check.
- **Multi-tenancy**: `TTenantMiddleware` reads the tenant from the verified token's claim, and
  refuses a token without a usable tenant with 401 and `Bearer error="invalid_token"` (checked
  by `tools/http_scenarios_tenants.sh`).

### 8. Rotate the secret: a key ring

With one secret, changing it logs every user out. A key ring (`PascalApi.JwtKeys`) names each
secret with a key id, the `kid` in the token's header: the newest key signs, the older ones
still verify until a date you give, so a rotation keeps the tokens already issued. From
`samples/03-tenants/TenantApiSample.dpr`:

```pascal
GSecret := TAppConfig.Get('JWT_SECRET', 'development-secret-change-me');
GKeys := TStaticJwtKeyRing.Parse(TAppConfig.Get('JWT_KEYS', DEFAULT_JWT_KEYS), GSecret,
  TOKEN_SECONDS);
...
THorse.Use(TJwtMiddleware.New(GKeys, ['/health', '/metrics', '/auth/login', '/swagger']));
```

And the login signs through the middleware, so it signs with the key the middleware verifies:

```pascal
LWriter.WriteString(TJwtMiddleware.Sign(LClaims));
```

`JWT_KEYS` lists the keys, separated by commas; the first one signs:

```
JWT_KEYS=k2:<new secret>,k1:<old secret>@1767225600
```

- **`kid:secret`**, and **`@notAfter`** (Unix seconds) to stop a key from verifying. A `kid` is
  1 to 128 of `A-Z a-z 0-9 . _ -`; a secret has no `,` and no `@`. Anything else stops the
  program at startup (`EJwtKeyError`, whose message never contains a secret).
- **To rotate**: put the new key first, give the old one a `notAfter` at least one token
  lifetime ahead, restart. Remove the old entry after that date.
- **The legacy secret** (the second argument of `Parse`): a token without `kid` verifies with
  it, so the tokens issued before the ring existed stay valid. Pass `''` to refuse them.
- **The third argument** is the longest lifetime `Sign` accepts, in seconds (0: no limit).
  `Sign` refuses claims without an integer `exp`, or with one later than that or than the
  signing key's `notAfter` (`EArgumentException`): such a token would stop verifying before it
  expires. `TJwtMiddleware.Sign` checks `exp` with a plain secret too.
- **Revoking a key**: remove it. Every token it signed is refused at once.

A `kid` the ring doesn't know, or one past its `notAfter`, gets the same 401 as a bad
signature: the client isn't told which keys exist. Checked over HTTP by
`tools/http_scenarios_tenants.sh` ("signing keys": a token of the previous key, an unknown
`kid`, a key past its date, a `kid` signed with another key's secret), and in
`PascalApi.JwtKeysTests`.

The keys are fixed at startup; step 9 rotates them by itself.

### 9. Rotate by itself: generated keys in a database or in Redis

`TRotatingJwtKeyRing` generates its keys (32 random bytes from the operating system) and keeps
them in a store every instance of the API shares. From `samples/03-tenants/TenantApiSample.dpr`
(`OpenKeys`, with `JWT_KEY_STORE=db`):

```pascal
LOptions := TJwtRotationOptions.Default;   // 30 days, 120 s, 3600 s, 60 s
LOptions.MaxTokenSeconds := TOKEN_SECONDS;
LOptions.LegacySecret := GSecret;           // tokens without kid, as in step 8
LOptions.RotateEverySeconds := SecondsSetting('JWT_ROTATE_SECONDS', LOptions.RotateEverySeconds);
...
LStore := TDbJwtKeyStore.Create(AControl);
LRing := TRotatingJwtKeyRing.Create(LStore, LOptions);
Result := LRing;
LRing.OnError := ALog.Error;
```

`TJwtMiddleware.New(GKeys, ...)` and `TJwtMiddleware.Sign` are the same as in step 8.

- **A key's life**: generated, it is *pending* for `PropagationSeconds` (it verifies, it doesn't
  sign yet), then it *signs*; when the next key starts signing it *verifies* for
  `MaxTokenSeconds` more, then it is *gone* and deleted. A new key comes when the newest is
  `RotateEverySeconds` old.
- **On a request, not on a timer**: every `ReloadSeconds` the first request that needs a key
  reads the store again and, when the time has come, adds the next key. No thread. An idle API
  rotates at its next request.
- **Several instances**: each reloads on its own and may try to add the same next key; the
  store keeps one (a unique key on `TENANT_ID` and `GENERATION`, or `HSETNX` in Redis), the
  others read it. `PropagationSeconds` must be at least `ReloadSeconds` (checked): every
  instance has the key before a token signed with it arrives.
- **The store down**: at startup the constructor raises (the API doesn't start without keys);
  later the loaded keys keep working and `OnError` gets the error.
- **`MaxTokenSeconds` is a setting every instance must share**: an old key's end is computed
  from it, never stored.

The database store runs your SQL by name, like the tenant catalog. Sample 03's
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

`TENANT_ID` is `''` for an API without tenants. The primary key is what settles two instances
rotating at once: without it both keys are stored and the ring refuses the store
(`EJwtKeyError`, "generation appears twice").

**Redis instead** (`JWT_KEY_STORE=redis` in sample 03): `TRedisJwtKeyStore`, in `src/redis`,
outside the package as `src/horse` is. Add `src/redis` and your pascal-redis-faa to the search
path:

```pascal
LStore := TRedisJwtKeyStore.Create(GRedis, 'cities-api:');   // your one TRedisClient
```

One hash per scope (`cities-api:jwt-keys:`), field = the generation, value = the key as JSON.

Checked over HTTP by `tools/http_scenarios_jwt_rotation.sh`, which runs sample 03 twice on one
store (the database, then Redis) with keys rotated in seconds: a login's kid changes, a token
of an older key keeps verifying, and the two instances sign with one key and verify each
other's tokens, also after racing for the next key. The life of a key second by second,
the race, a store that fails, in `PascalApi.JwtRotationTests` (a test clock).

### 10. A key per tenant

In a multi-tenant API one key for everyone means that a key that leaks signs tokens for every
tenant. `TTenantJwtKeyRing` (`PascalApi.Tenancy`) keeps one rotating ring per tenant, on one
store. From sample 03 (`OpenKeys`, `JWT_KEY_STORE=db` or `redis`):

```pascal
LRing := TTenantJwtKeyRing.Create(GCatalog, LStore, LOptions, GClaim, ALog.Error);
```

- **The tenant is in the kid**: `acme/1f0c...`. A token verifies only with its tenant's key,
  **and** only when its tenant claim (`tenant_id`, or the name you pass) names that tenant:
  acme's key on a token claiming globex is the same 401 as a bad signature.
- **Signing**: `TJwtMiddleware.Sign(LClaims)` reads the tenant from the claims and signs with
  that tenant's key; claims without a tenant, or naming one the catalog doesn't have, raise
  `EJwtKeyError` (a 500: the login must check the tenant first, as step 5 of
  [Multi-tenancy](multitenancy.md) does).
- **Which tenants have keys**: the catalog's, read when the ring is created and again every
  `ReloadSeconds` (on a request), plus a tenant that signs (its login found it in the catalog).
  A kid naming any other tenant is refused without asking the store or the catalog, so a client
  can't make the API query anything with made-up kids. A tenant provisioned after an instance
  started is known there at its next catalog read.
- **Each tenant rotates on its own requests**: a quiet tenant keeps its key until its next one.
- **The legacy secret** is one for all tenants (the tokens from before the rings carry no tenant
  to check). Remove it once those tokens have expired.

Checked over HTTP by `tools/http_scenarios_jwt_rotation.sh` (acme's key read from the store and
tried on a token claiming globex, a kid naming a tenant that doesn't exist, each tenant's own
key) and in `PascalApi.JwtRotationTests` (`TTenantJwtKeyRingTests`: no store or catalog query for
50 unknown tenants' kids, a tenant added to the catalog later).

### 11. Seal the secrets in the store

Whoever can read the keys' table (or the Redis hash, or a backup) can sign tokens. Wrap the
store in `TSealedJwtKeyStore`, and the secrets are kept sealed with AES-256-GCM under a master
key that never goes to the store. From sample 03 (`OpenKeys`):

```pascal
LMaster := TAppConfig.Get('JWT_KEYS_MASTER_KEY', DEFAULT_MASTER_KEY);
if LMaster <> '' then
  LStore := TSealedJwtKeyStore.Create(LStore, TAesGcmSecretCipher.Create(LMaster),
    TAppConfig.GetBool('JWT_KEYS_REQUIRE_SEALED', False));
```

- **The master key**: `JWT_KEYS_MASTER_KEY=m1:<base64 of 32 bytes>`; make one with
  `openssl rand -base64 32`. Put it in the environment or your platform's secret store, never
  next to the database it protects. Every instance needs the same list.
- **Rotating the master key**: put the new one first (`m2:<new>,m1:<old>`). New keys are sealed
  with m2; the ones sealed with m1 still open, and the ring's rotation replaces them. Drop m1
  after `RotateEverySeconds` + `MaxTokenSeconds`.
- **Secrets stored before sealing** (plain text) still load, and the rotation replaces them.
  Once they are gone, pass `True` as the third argument (`JWT_KEYS_REQUIRE_SEALED=true` in the
  sample) and a plain secret in the store is an error.
- **A sealed secret is bound to its row** (tenant, kid, generation): copied to another tenant's
  row it doesn't open, and the API reports it instead of using it.
- **A sealed secret takes about 110 characters**: size the column for it (`VARCHAR(255)`).
- **A wrong master key** stops the API at startup (`EJwtKeyError`, naming the master id, never a
  key); later it is reported through `OnError` and the loaded keys stay in use.

The AES is pascal-common-faa's (`PascalCommon.AesGcm`), checked against NIST's and OpenSSL's
vectors. Its S-box is a table lookup, which a process sharing the CPU could time; that is fine
here, where a secret is opened when the keys reload, not for what a client sends. Checked over
HTTP by `tools/http_scenarios_jwt_rotation.sh`: every secret in sample 03's database is sealed,
and acme's opens with OpenSSL (Python's cryptography).

## Choices

### JWT or your own tokens

A JWT is checked with no lookup: the API only needs the secret, and the token says who the user
is. The price is that it can't be taken back: it stays valid until `exp`, even after a logout or
a password change. Opaque tokens checked by `TAuthMiddleware` can be revoked at once, at the cost
of a lookup per request.

With JWT, keep `exp` short (the samples use an hour) and, if you need logout, keep a list of
revoked tokens and check it in your own middleware after `TJwtMiddleware`.

### What isn't there

- **Only HS256.** Any other `alg`, `none` included, is refused (tested). No RS256/ES256, so no
  tokens from an external identity provider that signs with a private key; use
  `TAuthMiddleware` with your own check for those.
- **No `iss` or `aud` check.** If several systems share the secret, check those claims in the
  handler or in a middleware of yours.
- **One secret, unless you use a key ring.** With `New(ASecret)`, rotating the secret
  invalidates every token issued with the old one; a key ring keeps them (steps 8 and 9).
- **Sealed secrets or not**: without `TSealedJwtKeyStore` the secrets are stored as they are,
  and whoever reads the table or the hash, or a backup of it, can sign tokens (step 11).
- **No leeway for clock differences**: a token is expired from the second `exp` says
  (`Decode_ExpBoundary`). Between an issuer and a verifier on different machines, prefer short
  lifetimes to a tolerance.
- **One configuration per process** (FPC's callbacks hold no state; see
  `PascalApi.Horse.Middlewares`): calling `New` again replaces the secret and the open prefixes
  everywhere it was used.

## Pitfalls

- **A token without `exp` never expires.** `exp` is optional in the standard, and `Decode`
  accepts a token without it (jwt.io's example has none, tested). Always write it when you sign;
  `TJwtMiddleware.Sign` refuses claims without it.
- **A Redis that forgets.** Without persistence (RDB or AOF) a restart of Redis loses the
  keys, and an eviction policy other than `noeviction` (or a `volatile-*` one) can evict them:
  either way every token is refused and new keys are made.
- **A tenant ring's legacy secret kept forever.** It signs for every tenant, which is what the
  rings are there to prevent: drop it when the old tokens have expired.
- **A memory store with several instances.** `TMemoryJwtKeyStore` is one process's: each
  instance would have its own keys and refuse the others' tokens. It is for tests.
- **Removing an old key too early.** Its tokens are refused from that moment: keep it until
  the last token it signed has expired.
- **The development secret in production.** Anyone who read the sample can sign tokens for your
  API (step 1).
- **Forgetting to free `Claims`**, or reading a claim without checking for nil (step 4).
- **A prefix that is too wide.** `/` or `/api` would leave everything below open. List the exact
  routes.
- **Expecting the route's case to matter.** The open prefixes ignore case (`/Health` is open
  when `/health` is listed).
- **The middleware order.** JWT before CORS refuses every browser preflight.

## Testing your application

Expiry depends on the time: replace pascal-common-faa's clock in the test, as `TJwtTests` does,
and put it back in the teardown:

```pascal
procedure UseClock(AUnix: Int64);
begin
  TClock.SetClock(TJwtClock.Create(AUnix));   // a test clock answering AUnix
end;

procedure TJwtTests.Decode_ExpBoundary;
begin
  UseClock(2000000000);
  TAssert.AssertTrue(DecodeResult(TJwt.SignHS256('{"exp":2000000000}', 's'), 's') = jrExpired);
  TAssert.AssertTrue(DecodeResult(TJwt.SignHS256('{"exp":2000000001}', 's'), 's') = jrValid);
end;

procedure TJwtTests.TearDown;
begin
  TClock.Reset;
end;
```

Over HTTP, check the refusals and the open routes, and log in to get a token for the rest. From
`tools/http_scenarios.sh`:

```sh
req GET /cities ""
status_is 401 "no token"
header_is WWW-Authenticate 'Bearer' "no token"
req POST /auth/login '{"user":"ana"}'
TOKEN="$(sed 's/.*"token":"\([^"]*\)".*/\1/' "$T/body")"
AUTH="Authorization: Bearer $TOKEN"
req GET /me "" -H "$AUTH"
body_is '{"sub":"ana"}' "me"
req GET /auth/login-admin ""
status_is 401 "excluded prefix matches whole segments only"
```

To test claims your login never writes (another tenant, an old token), sign the token in the
script, as `tools/http_scenarios_tenants.sh` does with Python (`sign`).

## Reference

- `PascalApi.Jwt`: `TJwt` (sign, decode, the checks and their order in the comment at the top;
  `ReadKid`).
- `PascalApi.JwtKeys`: `TStaticJwtKeyRing` (`JWT_KEYS`), `TRotatingJwtKeyRing` and
  `TJwtRotationOptions`, the stores (`IJwtKeyStore`, `TDbJwtKeyStore`, `TMemoryJwtKeyStore`),
  `TJwtKeys` (sign and decode by `kid`).
- `PascalApi.JwtKeys`: `IJwtSecretCipher`, `TAesGcmSecretCipher` (`JWT_KEYS_MASTER_KEY`),
  `TSealedJwtKeyStore`.
- `src/redis/PascalApi.Redis.JwtKeys`: `TRedisJwtKeyStore`.
- `PascalApi.Crypto`: SHA-256, HMAC, Base64url (tested against FIPS 180, RFC 4231, RFC 4648).
- `PascalApi.Http`: `ParseBearer`, `PathMatchesAny`, `BearerChallenge`.
- `PascalApi.Horse.Middlewares`: `TJwtMiddleware`, `TAuthMiddleware`.
- `samples/01-api` (login, `/me`) and `samples/03-tenants` (a tenant claim, a key ring);
  `tools/http_scenarios.sh`, `tools/http_scenarios_tenants.sh`.
- [Errors and validation](errors.md), [Multi-tenancy](multitenancy.md).
