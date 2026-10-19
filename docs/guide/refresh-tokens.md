# Refresh tokens

Short access tokens, and a refresh token that is used once to get the next pair: rotation, a
copied token that ends its login, two refreshes at once, logout, ending every login of a user.
The code comes from `samples/01-api` (no tenants, tokens in memory) and `samples/03-tenants`
(one scope per tenant, tokens in the control database). `PascalApi.RefreshTokensTests` covers
the unit with a test clock and a store that loses races on purpose; over HTTP,
`tools/http_scenarios.sh` and `tools/http_scenarios_tenants.sh` run every case below against
the samples, and `tools/http_scenarios_jwt_rotation.sh` runs two instances of sample 03 on one
database. The flow was first written and proven in pascal-agenda-faa; why its core is here:
`docs/jwt-keys-design.md` ("Not in this design", reopened 2026-10-19) and the header of
`PascalApi.RefreshTokens`.

Verifying access tokens is [Authentication](authentication.md); the keys that sign them are
[JWT signing keys](jwt-keys.md). This guide starts at the login's answer.

## What it solves

An access token (a JWT) is checked without a lookup, so it can't be withdrawn: whoever holds a
copy uses it until it expires. Keeping it short (minutes) limits a stolen one, but then the user
would log in again every few minutes. A refresh token fixes that: the login answers both, and
when the access token expires the client sends the refresh token to get the next pair.

A refresh token lives long (days), so it must be harder to abuse. `PascalApi.RefreshTokens`:

- **stores only the token's SHA-256**: a copy of the table gives nobody a usable token;
- **uses each token once**: a refresh spends it and returns the next one of the same login (its
  *family*);
- **ends the login when a spent token comes back**: someone kept a copy, and the server can't
  tell the copy from the original, so the whole family is revoked, the legitimate holder
  included, and your log hears of it;
- **settles two refreshes of one token at once** in the store (a conditional `UPDATE`): never two
  winners;
- **asks your application whether the user may still refresh** (exists, active);
- **logs out** (one login) and **ends every login of a user** (a new password, a user
  deactivated).

Login, passwords, users and the access token's claims stay in your application.

## The smallest working program

Sample 01, shortened: tokens in memory, no tenants (scope `''`).

```pascal
GRefresh := TRefreshTokens.Create(TMemoryRefreshTokenStore.Create, GRefreshSeconds,
  GRefreshHooks.Security);
THorse.Use(TJwtMiddleware.New(GSecret, ['/health', '/metrics', '/auth/login', '/auth/refresh',
  '/auth/logout', '/swagger']));
...
// the login, after checking the user
SendTokens(ARes, LName, GRefresh.Issue('', LName));
...
procedure PostRefresh(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LNext: TRotatedRefreshToken;
begin
  try
    LNext := GRefresh.Rotate(RefreshTokenOf(AReq), GRefreshHooks.UserActive);
  except
    on E: ERefreshTokenRejected do
      raise InvalidRefreshToken;
  end;
  SendTokens(ARes, LNext.UserId, LNext.Token);
end;
```

`SendTokens` signs a new access token and answers both (step 1); `InvalidRefreshToken` is one
401 for every refusal (step 3).

## Step by step

### 1. Answer a pair: a short access token and a refresh token

The login and the refresh answer the same DTO (`ApiSample.Auth`): the access token, its
lifetime, the refresh token and its lifetime.

```pascal
procedure SendTokens(ARes: THorseResponse; const AUser, ARefreshToken: string);
var
  LTokens: TTokens;
  LResult: ITokens;
begin
  LTokens := TTokens.Create;
  LResult := LTokens;
  LTokens.Token := AccessToken(AUser);
  LTokens.ExpiresIn := GAccessSeconds;
  LTokens.RefreshToken := ARefreshToken;
  LTokens.RefreshExpiresIn := GRefreshSeconds;
  // Tokens are credentials: no cache may keep them (RFC 6749, section 5.1).
  ARes.AddHeader('Cache-Control', 'no-store');
  TJsonSend.Send(ARes, TJsonMapper.Shared.ToJson<ITokens>(LResult));
end;
```

```json
{"token":"eyJ...","expiresIn":3600,"refreshToken":"q2dK...","refreshExpiresIn":2592000}
```

- The lifetimes come from the environment in both samples (`ACCESS_TOKEN_SECONDS`,
  `REFRESH_TOKEN_SECONDS`), so the scenarios can watch a refresh token expire in 3 seconds. In
  sample 03 the access token can't outlive the key ring's `MaxTokenSeconds` (it refuses to
  start otherwise; [JWT signing keys](jwt-keys.md), step 2).
- `Cache-Control: no-store` on both routes is checked by the scenarios.
- `/auth/refresh` and `/auth/logout` are open paths of `TJwtMiddleware`: the access token has
  usually expired when the client refreshes. An open path matches whole segments, so
  `/auth/logout-all` (step 7) still needs a token.

### 2. Issue one at the login

```pascal
SendTokens(ARes, LName, GRefresh.Issue('', LName));             // sample 01
SendTokens(ARes, LInfo.Id, LUser, GRefresh.Issue(LInfo.Id, LUser)); // sample 03
```

`Issue(AScope, AUserId)` starts a family (a login) and returns the token. The user id is
whatever your application uses (a row's id); the samples have no users table and use the name.

**The format**: `<scope>.<secret>`, or the secret alone when the scope is `''`. The secret is 32
random bytes from the operating system in Base64url (43 characters); a scope is 0 to 64 of
`A-Z a-z 0-9 - _`. The scope is in clear so your application can check it before any lookup
(step 6). The store gets `Hash(token)`: the SHA-256 of the whole token, scope included, so the
same secret under another scope matches nothing (checked: `refresh: acme's secret under
globex`).

### 3. Refresh: one answer for every refusal

`Rotate(AToken, ACheckUser)` checks the token and, when it is good, spends it and issues the
next one of its family (`TRotatedRefreshToken`: `Token`, `Scope`, `UserId`, `FamilyId`).
Anything wrong raises `ERefreshTokenRejected`, whose `Reason` says what:

| Reason | When | Revokes the family |
|---|---|---|
| `rrMalformed` | not `<scope>.<secret>` | no |
| `rrUnknown` | no such token in that scope | no |
| `rrRevoked` | its family was revoked (a logout, a reuse, a user refused) | already |
| `rrReused` | already spent: a copy came back | yes, and `OnSecurity` |
| `rrExpired` | past its lifetime | no |
| `rrUserGone` | your check refused the user | yes, and `OnSecurity` |
| `rrRaced` | another request spent it at the same moment | yes, and `OnSecurity` |

The client gets the same answer for all of them, so it learns nothing about which tokens exist:

```pascal
function InvalidRefreshToken: EUnauthorizedException;
begin
  Result := EUnauthorizedException.Create('Invalid or expired refresh token.',
    'invalid_refresh_token');
end;
```

```
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer
{"error":"Invalid or expired refresh token.","code":"invalid_refresh_token"}
```

The scenarios check body and header on every refusal. A missing token is a 400 (`"refreshToken"
is required.`), as any missing member.

### 4. A spent token that comes back ends the login

After a refresh, the old token is spent. If it comes back, two parties hold that login (the user
and whoever copied the token), and the server can't tell which one is honest: the family is
revoked, so the newest token stops working too, and both log in again. Your `OnSecurity` gets
one line:

```pascal
procedure TRefreshHooks.Security(const ALine: string);
begin
  SafeWriteln('SECURITY ' + ALine);
end;
```

```
SECURITY refresh token family 2bf7bc71a9c6e2c76fe8b7d4832b87c7 of scope acme revoked: a used refresh token came back (copied?)
```

The line names the family and the scope (no scope `''`: "refresh token family ... revoked:
..."), never a token. A logout, an expiry or an unknown token is not a security event and logs
nothing; the scenarios check that the log has only these lines and no token.

### 5. Two refreshes of one token at once

A client that refreshes from two tabs, or retries, sends one token twice at the same moment.
Both requests read it unspent. The store's `MarkUsed` decides: in `TDbRefreshTokenStore` it is

```sql
UPDATE REFRESH_TOKENS SET USED_AT = :USED_AT WHERE TENANT_ID = :TENANT_ID AND ID = :ID
  AND USED_AT IS NULL AND REVOKED_AT IS NULL
```

and only the request whose `UPDATE` changed one row wins. The database serializes the two
`UPDATE`s, so this holds across instances. The loser can't tell a race from a copy, so it
revokes the family (`rrRaced`).

The loser's revoke can land before the winner has stored its next token; that token would then
survive the revoke. Since 0.20.1 both stores here mark the token and store the next one in **one
transaction** (`IRefreshTokenAtomicRotation.MarkUsedAndAdd`, used by `Rotate` when the store has
it): the loser's `UPDATE` waits for the winner's row lock, matches no row once the winner
commits, and its revoke, a later statement, sees the next token. A store of your own without
that interface gets the older guard: after storing the next token the winner reads the spent
token again, and when it finds it revoked, it revokes the family again and is refused too
(`rrRaced`; `Rotate_Raced_LoserRevokedBeforeTheNextWasStored`; 0.19.0 returned that token: found
while writing sample 01). That guard holds on SQLite (one writer at a time) but not on
PostgreSQL: under `READ COMMITTED` the loser's revoke takes its snapshot when it starts, so it
can miss a next token committed while it runs and commit after the winner's re-read.
pascal-agenda-faa's race scenario saw the winner's next token survive in 4 of 7 runs on Linux
with 0.20.0. Implement `MarkUsedAndAdd` in your store if it runs on such a database. Over HTTP the scenarios send the two
requests in parallel with curl and accept one 200 and one 401, or two 401s; never two 200s, and
the winner's next token is refused. Measured on FPC Windows (2026-10-19): the second request
often arrives after the first has finished, and the log then says "came back" instead of
"raced"; the unit tests cover the race itself.

### 6. Check the user, and the tenant

The check runs before the token is spent. Answer False for a user that is gone or inactive,
and the family is revoked:

```pascal
function TRefreshHooks.UserActive(const AScope, AUserId: string): Boolean;
begin
  Result := Copy(AUserId, 1, 7) <> 'blocked';
end;
```

The samples fake it (a name starting with "blocked" stands for a user deactivated after the
login); your application looks the user up in `AScope`. It is a method: `TRefreshUserCheck` is
`reference to` on Delphi and `of object` on FPC (`PASCALAPI_FUNCREFS`), and a method fits both.

**With tenants**, the scope is the tenant (`acme.<secret>`), and sample 03 checks it against the
catalog before `Rotate`, as its login does:

```pascal
LToken := RefreshTokenOf(AReq);
// The tenant is in the token, in clear: checked against the catalog
// before any lookup. Every token here names one (no scope '').
if not TRefreshTokens.TryParse(LToken, LTenant) then
  raise InvalidRefreshToken;
case CheckTenant(GCatalog, LTenant, LInfo) of
  tcOk: ;
  tcSuspended:
    begin
      TJsonSend.Send(ARes, TenantRejection(tcSuspended, LStatus), LStatus);
      Exit;
    end;
else
  raise InvalidRefreshToken; // no tenant, or one the catalog doesn't have
end;
try
  LNext := GRefresh.Rotate(LToken, GHooks.UserActive);
except
  on E: ERefreshTokenRejected do
    raise InvalidRefreshToken;
end;
SendTokens(ARes, LInfo.Id, LNext.UserId, LNext.Token);
```

A tenant the catalog doesn't have gets the same 401 as a bad token (checked: `nowhere.<secret>`);
a suspended one gets its 403 `tenant_suspended`, which says no more than the login does. The
`TTenantMiddleware` doesn't run on these routes (they are open paths), so the handler is where
the tenant is checked.

### 7. Logout, and every login of a user

```pascal
procedure PostLogout(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
begin
  // The same answer for any token: a logout tells nothing about it.
  GRefresh.Revoke(RefreshTokenOf(AReq));
  ARes.Status(204).Send('');
end;
```

`Revoke(AToken)` revokes the token's family (any token of the login, spent ones too) and does
nothing, without an error, for anything else. Sample 03 also checks the tenant first, and lets a
suspended tenant's user log out.

`RevokeUser(AScope, AUserId)` revokes every family of a user and returns how many tokens it
revoked. Call it when the password changes, when the user is deactivated or removed, or for
"sign out everywhere", as sample 01's `/auth/logout-all` does with the caller's `sub`:

```pascal
LClaims := TJwtMiddleware.Claims(AReq);
try
  GRefresh.RevokeUser('', LClaims.Find('sub').AsString);
finally
  LClaims.Free;
end;
ARes.Status(204).Send('');
```

Neither one touches access tokens already issued: they work until they expire. That is why they
are short.

### 8. Keep them in a database

`TDbRefreshTokenStore.Create(AFactory)` runs five statements by name from the factory's
`SqlLoader` (the names are parameters of the constructor, with these defaults), each in a
transaction of its own; `TENANT_ID` is the scope (`''` without tenants). Sample 03's, on SQLite
(`TenantApiSample.Control`, in the control database: every instance on it rotates the tokens):

```sql
-- MIG.0004
CREATE TABLE REFRESH_TOKENS (ID VARCHAR(32) NOT NULL PRIMARY KEY,
  TENANT_ID VARCHAR(64) NOT NULL, TOKEN_HASH CHAR(64) NOT NULL,
  USER_ID VARCHAR(128) NOT NULL, FAMILY_ID VARCHAR(32) NOT NULL,
  CREATED_AT BIGINT NOT NULL, EXPIRES_AT BIGINT NOT NULL, USED_AT BIGINT, REVOKED_AT BIGINT,
  CONSTRAINT UQ_REFRESH_TOKENS_HASH UNIQUE (TENANT_ID, TOKEN_HASH));
CREATE INDEX IX_REFRESH_TOKENS_FAMILY ON REFRESH_TOKENS (TENANT_ID, FAMILY_ID);
CREATE INDEX IX_REFRESH_TOKENS_USER ON REFRESH_TOKENS (TENANT_ID, USER_ID);

-- REFRESH.INSERT
INSERT INTO REFRESH_TOKENS (ID, TENANT_ID, TOKEN_HASH, USER_ID, FAMILY_ID, CREATED_AT,
  EXPIRES_AT) VALUES (:ID, :TENANT_ID, :TOKEN_HASH, :USER_ID, :FAMILY_ID, :CREATED_AT,
  :EXPIRES_AT)
-- REFRESH.BY_HASH
SELECT ID, USER_ID, FAMILY_ID, EXPIRES_AT, USED_AT, REVOKED_AT FROM REFRESH_TOKENS
  WHERE TENANT_ID = :TENANT_ID AND TOKEN_HASH = :TOKEN_HASH
-- REFRESH.MARK_USED
UPDATE REFRESH_TOKENS SET USED_AT = :USED_AT WHERE TENANT_ID = :TENANT_ID AND ID = :ID
  AND USED_AT IS NULL AND REVOKED_AT IS NULL
-- REFRESH.REVOKE_FAMILY
UPDATE REFRESH_TOKENS SET REVOKED_AT = :REVOKED_AT WHERE TENANT_ID = :TENANT_ID
  AND FAMILY_ID = :FAMILY_ID AND REVOKED_AT IS NULL
-- REFRESH.REVOKE_USER
UPDATE REFRESH_TOKENS SET REVOKED_AT = :REVOKED_AT WHERE TENANT_ID = :TENANT_ID
  AND USER_ID = :USER_ID AND REVOKED_AT IS NULL
```

- The times are Unix seconds (`BIGINT`); `USED_AT` and `REVOKED_AT` are NULL until set.
- The `WHERE ... IS NULL` of `MARK_USED` is what decides a race (step 5); without it two
  refreshes both win. `REVOKE_*` return the rows they changed: only those count as revoked now.
- The hash is unique within a tenant. The ids are 32 hex digits (`TRefreshTokens.NewId`).
- **PostgreSQL**: the same statements work (unquoted names fold to lower case). The table:

  ```sql
  CREATE TABLE refresh_tokens (
    id varchar(32) PRIMARY KEY,
    tenant_id varchar(64) NOT NULL,
    token_hash char(64) NOT NULL,
    user_id varchar(128) NOT NULL,
    family_id varchar(32) NOT NULL,
    created_at bigint NOT NULL,
    expires_at bigint NOT NULL,
    used_at bigint,
    revoked_at bigint,
    CONSTRAINT uq_refresh_tokens_hash UNIQUE (tenant_id, token_hash));
  CREATE INDEX ix_refresh_tokens_family ON refresh_tokens (tenant_id, family_id);
  CREATE INDEX ix_refresh_tokens_user ON refresh_tokens (tenant_id, user_id);
  ```

  Not run by this repository (its samples use SQLite); pascal-agenda-faa runs the SQLite form.
- **The table only grows.** Nothing in the library deletes rows. Delete those whose
  `EXPIRES_AT` has passed (a job of your application, `DELETE FROM REFRESH_TOKENS WHERE
  EXPIRES_AT < :NOW`, not in the samples): an expired token can't be exchanged anyway, and you
  lose only the alarm for a copy older than the lifetime. Don't delete spent tokens before they
  expire: a copy of one would then be `rrUnknown` and end nothing.

### 9. Your own store

`IRefreshTokenStore` has five methods; implement them on Redis or anything else. The contract,
which `TMemoryRefreshTokenStore` and `TDbRefreshTokenStore` follow:

| Method | Must |
|---|---|
| `Add(AScope, AHash, ARecord, ACreatedAt)` | store the record under (scope, hash); a hash already stored in the scope is an error |
| `FindByHash(AScope, AHash, out ARecord)` | True with the record (`Used`, `Revoked` as set) when (scope, hash) is stored |
| `MarkUsed(AScope, AId, AAt)` | **atomically**: True only for the one call that finds the token neither used nor revoked and marks it |
| `RevokeFamily(AScope, AFamilyId, AAt)` | mark every token of the family not yet revoked; return how many |
| `RevokeUser(AScope, AUserId, AAt)` | the same for every token of the user |

Each method is a transaction of its own; a store shared by several instances must give every
instance the same answers. `MarkUsed` is the one that needs care: a read followed by a write is
two refreshes winning. On Redis that means one script (`EVAL`) that checks and sets, or a
`WATCH`/`MULTI` transaction, and a set per family and per user to revoke them; this repository
ships no Redis store and has not measured one. Test yours with `PascalApi.RefreshTokensTests`'
cases, and with two refreshes sent at once over HTTP (step 5).

## Choices

- **Lifetimes**: the access token as short as your clients tolerate (minutes; the samples
  default to an hour), the refresh token as long as a login may last unused (the default,
  `REFRESH_DEFAULT_LIFETIME_SECONDS`, is 30 days). Each refresh gives a new full lifetime, so an
  active user stays logged in.
- **The store**: `TMemoryRefreshTokenStore` for tests, or for one instance that accepts losing
  every login on a restart (sample 01); a database (or your own store) as soon as there are two
  instances or a restart must keep logins.
- **The scope**: `''` without tenants. With tenants, the tenant id, and check it against the
  catalog before `Rotate` (step 6). The scope is not secret: it is in the token in clear.
- **The body or a cookie**: the samples send the refresh token in the JSON body. An HTTP-only
  cookie keeps it from a browser's scripts, but then the route needs protection against
  cross-site requests (a `SameSite` cookie, an origin check). Not in the samples.

## Pitfalls

- **Different answers for different reasons.** An "expired" next to an "unknown" tells an
  attacker which tokens existed. Map every `ERefreshTokenRejected` to one 401, and keep the
  `Reason` for your log.
- **A token in the log.** The access line has no body, and `OnSecurity` names only families; a
  log line of your own must not print the token either (the scenarios grep the server's log for
  the tokens they used).
- **A client that retries a refresh.** When the answer with the new pair is lost (a timeout), a
  retry with the old token is a reuse: the login ends. That is the price of reuse detection.
  Clients should send one refresh at a time and, after a failure, log in again rather than retry.
- **The tenant check skipped.** With tenants, a token whose scope names a suspended or removed
  tenant must be refused before it is exchanged; the middleware doesn't run on open paths.
- **Long access tokens.** Logout and `RevokeUser` end refresh tokens, not access tokens.
- **Refresh routes as MCP tools.** A model has no use for a refresh token, and one kept in its
  context could be replayed: the samples mark `/auth/refresh` and `/auth/logout` `NoMcp`, and
  the scenarios check that the tool list has neither ([MCP](mcp.md)).
- **Purging spent tokens early** (step 8).

## Testing your application

Unit tests on `TMemoryRefreshTokenStore`, with the clock replaced
(`TClock.SetClock`, pascal-common-faa) to expire tokens without waiting:

```pascal
LToken := FTokens.Issue('acme', 'u1');
UseClock(T0 + 3599);
LToken := FTokens.Rotate(LToken, UserActive).Token; // valid until T0 + 3600
UseClock(T0 + 3599 + 3600);
TAssert.AssertEquals('expired', Rejection(LToken));
```

`PascalApi.RefreshTokensTests` also has a store that loses `MarkUsed` once, and one that revokes
the family just before the next token is stored: the two orders of a race. For your SQL names,
pascal-db-faa's `TMockDBFactory` (`SetRowsAffected('REFRESH.MARK_USED', 0)` plays the request
that lost).

Over HTTP, what the samples' scenarios check, to copy into your own:

- a refresh returns a new pair, `Cache-Control: no-store`, and the new access token works;
- the old token is refused afterwards, and refusing it revokes the newest one too, with one
  `SECURITY` line in the log;
- two refreshes of one token sent at once (curl in the background): never two 200s, and the
  winner's next token refused;
- logout: 204, the token refused afterwards, and 204 again for the same token or for garbage;
- a malformed token, a secret under another tenant's prefix, an unknown tenant: the same 401;
  a suspended tenant: 403;
- a user the check refuses; "sign out everywhere" ending two logins and sparing another user's;
- an expired token, with a lifetime of seconds (`REFRESH_TOKEN_SECONDS=3`, set by
  `tools/test_http.sh`);
- with two instances on one database: a token issued by one, rotated by the other, and the spent
  token shown to the first is a reuse there (`tools/http_scenarios_jwt_rotation.sh`).

## Reference

- `PascalApi.RefreshTokens`: `TRefreshTokens` (`Issue`, `Rotate`, `Revoke`, `RevokeUser`,
  `TryParse`, `Hash`, `NewToken`), `ERefreshTokenRejected` and `RefreshRejectionName`,
  `TRefreshUserCheck`, `IRefreshTokenStore`, `TDbRefreshTokenStore`, `TMemoryRefreshTokenStore`.
- `PascalApi.Http`: `EUnauthorizedException` (the 401 with its code and `WWW-Authenticate`).
- `samples/01-api` (`ApiSample.dpr`, `ApiSample.Auth`), `samples/03-tenants`
  (`TenantApiSample.dpr`, `TenantApiSample.Auth`, `TenantApiSample.Control`);
  `tools/http_scenarios.sh`, `tools/http_scenarios_tenants.sh`,
  `tools/http_scenarios_jwt_rotation.sh`.
- `docs/jwt-keys-design.md`: why refresh tokens were left out, then brought in.
- [Authentication](authentication.md), [JWT signing keys](jwt-keys.md),
  [Multi-tenancy](multitenancy.md), [Errors and validation](errors.md).
