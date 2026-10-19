# Authentication

Who may call which route: a token in the `Authorization` header, checked before the handler
runs. The code comes from `samples/01-api` and `samples/03-tenants`. `PascalApi.CryptoTests`
(`TJwtTests`) covers signing and verifying, `PascalApi.HttpTests` the header parsing and the
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
POST /auth/login {"user":"ana"}              200  {"token":"eyJhbGciOiJIUzI1NiIs...", ...}
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
THorse.Use(TJwtMiddleware.New(GSecret, ['/health', '/metrics', '/auth/login', '/auth/refresh',
  '/auth/logout', '/swagger']));
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
function AccessToken(const AUser: string): string;
var
  LWriter: TJsonWriter;
begin
  LWriter := TJsonWriter.Create;
  try
    LWriter.BeginObject;
    LWriter.Name('sub');
    LWriter.WriteString(AUser);
    LWriter.Name('exp');
    LWriter.WriteInt64(TJwt.UnixNow + GAccessSeconds);  // ACCESS_TOKEN_SECONDS, 3600 by default
    LWriter.EndObject;
    Result := TJwt.SignHS256(LWriter.ToString, GSecret);
  finally
    LWriter.Free;
  end;
end;
```

The login answers it as `token`, with a refresh token beside it (`SendTokens`):

- **A short access token and a refresh token**: the client exchanges the refresh token for the
  next pair at `/auth/refresh`, each refresh token once, so the access token can live minutes:
  [Refresh tokens](refresh-tokens.md).
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

### 8. More than one secret: keys that rotate

One secret can't change without logging every user out. A key ring names each key in the
token's header (`kid`), so the newest signs while the older ones keep verifying; the keys can
be fixed in the configuration (`JWT_KEYS`) or generated and rotated by the library in a
database or Redis, one ring per tenant, sealed under a master key. The middleware takes the ring
instead of the secret, and the login signs through it:

```pascal
THorse.Use(TJwtMiddleware.New(GKeys, ['/health', '/metrics', '/auth/login', '/auth/refresh',
  '/auth/logout', '/swagger']));
...
Result := TJwtMiddleware.Sign(LWriter.ToString);   // in sample 03's AccessToken
```

All of it, with the procedures for a key that leaked or a master key to change:
[JWT signing keys and rotation](jwt-keys.md).

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
  invalidates every token issued with the old one; a key ring keeps them (step 8).
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

- `PascalApi.Jwt`: `TJwt` (sign, decode, the checks and their order in the comment at the top).
- `PascalApi.JwtKeys` and the key rings: [JWT signing keys and rotation](jwt-keys.md).
- `PascalApi.Crypto`: SHA-256, HMAC, Base64url (tested against FIPS 180, RFC 4231, RFC 4648).
- `PascalApi.Http`: `ParseBearer`, `PathMatchesAny`, `BearerChallenge`.
- `PascalApi.Horse.Middlewares`: `TJwtMiddleware`, `TAuthMiddleware`.
- `samples/01-api` (login, `/me`) and `samples/03-tenants` (a tenant claim, a key ring);
  `tools/http_scenarios.sh`, `tools/http_scenarios_tenants.sh`.
- [Errors and validation](errors.md), [Multi-tenancy](multitenancy.md).
