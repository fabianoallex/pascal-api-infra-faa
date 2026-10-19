#!/bin/sh
# Checks samples/03-tenants over HTTP with curl: the tenant from the token's
# claim, the answers for a missing, removed or suspended tenant, and above
# all the cross-tenant attempts (a token of one tenant reading, creating over
# or deleting another's rows), on dedicated databases and on the shared one,
# and a JOIN of two tenant tables (GET /cities/:code/details).
# Also the pool metrics named by mode (decision 9 of
# docs/multitenancy-design.md), the rate limit by plan, and, when SERVER_LOG
# names the server's output file, tenant.id in the access log.
#
#   sh tools/http_scenarios_tenants.sh [port]   (default 9350; TenantApiSample
#                                               must be running, started with
#                                               --reset, default TENANTS,
#                                               JWT_SECRET and JWT_KEYS)
#   SERVER_LOG=path/server.log sh tools/http_scenarios_tenants.sh [port]
#
# Tokens the sample would never issue (a removed tenant, no tenant, a
# suspended one) are signed here with Python's hmac, with the sample's
# default secret (no kid: the key ring's legacy secret) or one of its
# default keys (JWT_KEYS, phase 1 of docs/jwt-keys-design.md). Same script for every build of the sample (FPC
# Windows/Linux, Delphi Win32/Win64). Exit code 0 only if every check passed.
PORT="${1:-9350}"
BASE="http://127.0.0.1:$PORT"
SECRET="${JWT_SECRET:-development-secret-change-me}"
# The sample's DEFAULT_JWT_KEYS: k2 signs, k1 verifies, k0 is past its NotAfter.
KEY2=development-key-2-change-me
KEY1=development-key-1-change-me
KEY0=development-key-0-change-me
T="$(mktemp -d)"
FAILS=0
CHECKS=0

# Windows has a python3 that only opens the Store; take the one that runs.
PY=python3
$PY -c "" >/dev/null 2>&1 || PY=python

req() {
  M="$1"; P="$2"; B="$3"; shift 3 2>/dev/null || shift $#
  if [ -n "$B" ]; then
    curl -s -X "$M" -o "$T/body" -D "$T/headers" -w '%{http_code}' -H 'Content-Type: application/json' \
      --data-binary "$B" "$@" "$BASE$P" > "$T/status"
  else
    curl -s -X "$M" -o "$T/body" -D "$T/headers" -w '%{http_code}' "$@" "$BASE$P" > "$T/status"
  fi
}
ok()   { CHECKS=$((CHECKS + 1)); }
fail() { CHECKS=$((CHECKS + 1)); FAILS=$((FAILS + 1)); echo "FAIL: $1"; }
status_is() { [ "$(cat "$T/status")" = "$1" ] && ok || fail "$2: status $(cat "$T/status"), expected $1 (body: $(cat "$T/body"))"; }
body_is()   { [ "$(cat "$T/body")" = "$1" ] && ok || fail "$2: body $(cat "$T/body"), expected $1"; }
body_has()  { grep -qF -- "$1" "$T/body" && ok || fail "$2: body lacks $1 (body: $(cat "$T/body"))"; }
body_lacks(){ grep -qF -- "$1" "$T/body" && fail "$2: body has $1" || ok; }
header()    { tr -d '\r' < "$T/headers" | grep -i "^$1:" | head -1 | sed 's/^[^:]*: *//'; }
header_is() { [ "$(header "$1")" = "$2" ] && ok || fail "$3: header $1 = '$(header "$1")', expected '$2'"; }
# Sum of a metric's samples whose labels contain $2 (a Prometheus text file in $3).
metric_sum() { awk -v n="$1" -v l="$2" 'index($1, n "{") == 1 && index($1, l) > 0 { s += $NF } END { printf "%d", s }' "$3"; }

# login TENANT USER -> prints the token ('' when refused)
login() {
  req POST /auth/login "{\"tenant\":\"$1\",\"user\":\"$2\"}"
  sed -n 's/.*"token":"\([^"]*\)".*/\1/p' "$T/body"
}
# sign_header HEADER_JSON CLAIMS_JSON SECRET -> an HS256 token, exp one hour ahead
sign_header() {
  $PY -c '
import sys, hmac, hashlib, base64, json, time
b = lambda d: base64.urlsafe_b64encode(d).rstrip(b"=").decode()
claims = json.loads(sys.argv[2]); claims["exp"] = int(time.time()) + 3600
h = b(sys.argv[1].encode())
p = b(json.dumps(claims).encode())
s = b(hmac.new(sys.argv[3].encode(), (h + "." + p).encode(), hashlib.sha256).digest())
print(h + "." + p + "." + s)' "$1" "$2" "$3"
}
# sign CLAIMS_JSON -> a token without kid, with the legacy secret
sign() { sign_header '{"alg":"HS256","typ":"JWT"}' "$1" "$SECRET"; }
# sign_kid KID SECRET CLAIMS_JSON -> a token with that kid in the header
sign_kid() { sign_header "{\"alg\":\"HS256\",\"typ\":\"JWT\",\"kid\":\"$1\"}" "$3" "$2"; }

# raw METHOD PATH TOKEN LINE -> the whole response in $T/body; LINE is one
# more header line, sent as it is (curl won't send a name starting with ':').
# MSYS2_ARG_CONV_EXCL: Git Bash would rewrite ':name: value' as a path list
# on its way to a Windows python (the request then never left); no effect
# elsewhere.
raw() {
  MSYS2_ARG_CONV_EXCL='*' $PY -c '
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])))
auth = ("Authorization: Bearer " + sys.argv[4] + "\r\n") if sys.argv[4] else ""
s.sendall((sys.argv[2] + " " + sys.argv[3] + " HTTP/1.1\r\nHost: 127.0.0.1\r\n" + auth +
  sys.argv[5] + "\r\nConnection: close\r\n\r\n").encode())
d = b""
while True:
  c = s.recv(65536)
  if not c: break
  d += c
sys.stdout.write(d.decode("utf-8", "replace"))' "$PORT" "$1" "$2" "$3" "$4" > "$T/body"
}

# --- login: the application's route, resolving the tenant from the body
ACME="$(login acme ana)"
[ -n "$ACME" ] && ok || fail "login acme (dedicated): $(cat "$T/body")"
GLOBEX="$(login globex bob)"
[ -n "$GLOBEX" ] && ok || fail "login globex (dedicated): $(cat "$T/body")"
INITECH="$(login initech carla)"
[ -n "$INITECH" ] && ok || fail "login initech (shared): $(cat "$T/body")"
UMBRELLA="$(login umbrella davi)"
[ -n "$UMBRELLA" ] && ok || fail "login umbrella (shared): $(cat "$T/body")"
login nope ana >/dev/null
status_is 404 "login, unknown tenant"
body_is '{"error":"Tenant not found."}' "login, unknown tenant"
login soylent ana >/dev/null
status_is 403 "login, suspended tenant"
body_is '{"error":"This tenant is suspended.","code":"tenant_suspended"}' "login, suspended tenant"
req POST /auth/login '{"user":"ana"}'
status_is 400 "login without a tenant"
body_is '{"error":"\"tenant\" is required."}' "login without a tenant"

# --- the tenant comes from the token, and only from it
req GET /tenant "" -H "Authorization: Bearer $ACME"
body_is '{"tenant":"acme","mode":"dedicated"}' "tenant of acme's token"
req GET /tenant "" -H "Authorization: Bearer $INITECH"
body_is '{"tenant":"initech","mode":"shared"}' "tenant of initech's token"
req GET /tenant "" -H "Authorization: Bearer $UMBRELLA" -H "X-Tenant-Id: initech"
body_is '{"tenant":"umbrella","mode":"shared"}' "a header naming another tenant is ignored"
# The middleware's internal mark, sent by hand: curl drops a header line that
# starts with ':', so a raw request. Whatever the server makes of the line
# (fpWeb cuts the name at the first ':'; Indy kept such a line, which let a
# client hide from the access log until the marks got a line feed in their
# names), it must not become the tenant.
raw GET /tenant "$UMBRELLA" ":pascalapi-tenant: initech"
body_has 'HTTP/1.1 ' "the internal mark sent by hand: an answer"
body_lacks '"tenant":"initech"' "the internal mark can't be sent"
req GET /cities ""
status_is 401 "no token"

# --- tokens the sample never issues
TOKEN="$(sign '{"sub":"ana","tenant_id":"wayne"}')"
req GET /cities "" -H "Authorization: Bearer $TOKEN"
status_is 401 "token of a removed tenant"
body_is '{"error":"The token'"'"'s tenant no longer exists."}' "token of a removed tenant"
TOKEN="$(sign '{"sub":"ana"}')"
req GET /cities "" -H "Authorization: Bearer $TOKEN"
status_is 401 "token without a tenant"
body_is '{"error":"The token names no tenant."}' "token without a tenant"
header_is WWW-Authenticate 'Bearer error="invalid_token"' "token without a tenant"
TOKEN="$(sign '{"sub":"ana","tenant_id":7}')"
req GET /cities "" -H "Authorization: Bearer $TOKEN"
status_is 401 "token with a non-string tenant"
TOKEN="$(sign '{"sub":"ana","tid":"acme"}')"
req GET /cities "" -H "Authorization: Bearer $TOKEN"
status_is 401 "the claim is tenant_id, not tid"
TOKEN="$(sign '{"sub":"ana","tenant_id":"soylent"}')"
req GET /cities "" -H "Authorization: Bearer $TOKEN"
status_is 403 "token of a suspended tenant"
body_is '{"error":"This tenant is suspended.","code":"tenant_suspended"}' "token of a suspended tenant"

# --- signing keys (JWT_KEYS): the login signs with k2, k1 still verifies
# (a rotation), k0 is past its NotAfter; tokens without kid verify with the
# legacy secret (every token sign() makes, above)
case "$ACME" in
  eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6ImsyIn0.*) ok ;;
  *) fail "the login's token names kid k2 (token: $ACME)" ;;
esac
TOKEN="$(sign_kid k1 "$KEY1" '{"sub":"ana","tenant_id":"acme"}')"
req GET /tenant "" -H "Authorization: Bearer $TOKEN"
status_is 200 "a token of the previous key (k1) still verifies"
body_is '{"tenant":"acme","mode":"dedicated"}' "a token of the previous key (k1)"
TOKEN="$(sign_kid k2 "$KEY2" '{"sub":"ana","tenant_id":"acme"}')"
req GET /tenant "" -H "Authorization: Bearer $TOKEN"
status_is 200 "a token of the signing key (k2), from another signer"
TOKEN="$(sign_kid k0 "$KEY0" '{"sub":"ana","tenant_id":"acme"}')"
req GET /tenant "" -H "Authorization: Bearer $TOKEN"
status_is 401 "a key past its NotAfter (k0) verifies nothing"
body_is '{"error":"Invalid or expired token."}' "a key past its NotAfter (k0)"
header_is WWW-Authenticate 'Bearer error="invalid_token"' "a key past its NotAfter (k0)"
TOKEN="$(sign_kid k9 "$KEY1" '{"sub":"ana","tenant_id":"acme"}')"
req GET /tenant "" -H "Authorization: Bearer $TOKEN"
status_is 401 "an unknown kid"
body_is '{"error":"Invalid or expired token."}' "an unknown kid: the same answer as a bad signature"
TOKEN="$(sign_kid k1 "$KEY2" '{"sub":"ana","tenant_id":"acme"}')"
req GET /tenant "" -H "Authorization: Bearer $TOKEN"
status_is 401 "kid k1 signed with k2's secret"
TOKEN="$(sign_kid k1 "$SECRET" '{"sub":"ana","tenant_id":"acme"}')"
req GET /tenant "" -H "Authorization: Bearer $TOKEN"
status_is 401 "kid k1 signed with the legacy secret"
TOKEN="$(sign_header '{"alg":"HS256","typ":"JWT"}' '{"sub":"ana","tenant_id":"acme"}' "$KEY2")"
req GET /tenant "" -H "Authorization: Bearer $TOKEN"
status_is 401 "no kid, signed with a key's secret (only the legacy secret has no kid)"
TOKEN="$(sign_header '{"alg":"HS256","typ":"JWT","kid":7}' '{"sub":"ana","tenant_id":"acme"}' "$KEY1")"
req GET /tenant "" -H "Authorization: Bearer $TOKEN"
status_is 401 "a kid that is not a string"

# --- each tenant's rows; the same code in every tenant, no conflict
# (dedicated: other databases; shared: TENANT_ID in the primary key).
# Non-ASCII bodies from a file with explicit UTF-8 bytes (Git Bash hands
# curl.exe its arguments in the ANSI code page).
printf '{"code":"4205407","name":"Florian\303\263polis","state":"sc"}' > "$T/floripa"
for TK in "$ACME" "$GLOBEX" "$INITECH" "$UMBRELLA"; do
  req POST /cities "@$T/floripa" -H "Authorization: Bearer $TK"
  status_is 201 "the same code in each tenant"
done
printf '{"code":"3550308","name":"S\303\243o Paulo","state":"SP","population":11451999}' > "$T/utf8"
req POST /cities "@$T/utf8" -H "Authorization: Bearer $ACME"
status_is 201 "a city only acme has"
req POST /cities '{"code":"4314902","name":"Porto Alegre","state":"RS"}' -H "Authorization: Bearer $INITECH"
status_is 201 "a city only initech has"
req POST /cities '{"code":"4205407","name":"Again","state":"SC"}' -H "Authorization: Bearer $INITECH"
status_is 409 "the same code twice in one shared tenant"
req POST /cities '{"code":"4205407","name":"Again","state":"SC"}' -H "Authorization: Bearer $ACME"
status_is 409 "the same code twice in one dedicated tenant"
req POST /cities '{"code":"4205407","name":"Again","state":"SC","tenantId":"initech"}' -H "Authorization: Bearer $ACME"
status_is 400 "a tenantId member in the body is refused (umError), never taken as the tenant"
body_has '$.tenantId' "unknown member tenantId: its path"
# The limits the OpenAPI document declares (sample 02 has the same checks).
req POST /cities '{"code":"+123456","name":"X","state":"SP"}' -H "Authorization: Bearer $ACME"
status_is 400 "code: digits only"
req POST /cities "{\"code\":\"1000001\",\"name\":\"$(printf 'x%.0s' $(seq 1 101))\",\"state\":\"SP\"}" -H "Authorization: Bearer $ACME"
status_is 400 "city name: at most 100 characters"
req POST /cities '{"code":"1000001","name":"X","state":"SP","population":-5}' -H "Authorization: Bearer $ACME"
status_is 400 "population: not negative"

# --- lists: only the caller's rows
req GET /cities "" -H "Authorization: Bearer $ACME"
body_is '[{"code":"4205407","name":"Florianópolis","state":"SC","population":null},{"code":"3550308","name":"São Paulo","state":"SP","population":11451999}]' "acme's list"
req GET /cities "" -H "Authorization: Bearer $GLOBEX"
body_is '[{"code":"4205407","name":"Florianópolis","state":"SC","population":null}]' "globex's list (dedicated)"
req GET /cities "" -H "Authorization: Bearer $UMBRELLA"
body_is '[{"code":"4205407","name":"Florianópolis","state":"SC","population":null}]' "umbrella's list (shared: initech's rows filtered out)"
req GET /cities "" -H "Authorization: Bearer $INITECH"
body_lacks '3550308' "initech's list lacks acme's city"

# --- reading another tenant's row by its code
req GET /cities/3550308 "" -H "Authorization: Bearer $GLOBEX"
status_is 404 "globex reads acme's city (dedicated)"
req GET /cities/4314902 "" -H "Authorization: Bearer $UMBRELLA"
status_is 404 "umbrella reads initech's city (shared database)"
body_lacks 'Porto Alegre' "umbrella reads initech's city (shared database)"
req GET /cities/4314902 "" -H "Authorization: Bearer $ACME"
status_is 404 "acme (dedicated) reads initech's city (shared)"

# --- deleting another tenant's row
req DELETE /cities/4314902 "" -H "Authorization: Bearer $UMBRELLA"
status_is 404 "umbrella deletes initech's city (shared database)"
req GET /cities/4314902 "" -H "Authorization: Bearer $INITECH"
status_is 200 "initech's city survived"
req DELETE /cities/3550308 "" -H "Authorization: Bearer $GLOBEX"
status_is 404 "globex deletes acme's city (dedicated)"
req GET /cities/3550308 "" -H "Authorization: Bearer $ACME"
body_has '"name":"São Paulo"' "acme's city survived"
# A code both have: each deletes only its own.
req DELETE /cities/4205407 "" -H "Authorization: Bearer $UMBRELLA"
status_is 204 "umbrella deletes its own city"
req GET /cities/4205407 "" -H "Authorization: Bearer $INITECH"
status_is 200 "initech's city with the same code is still there"
req GET /cities/4205407 "" -H "Authorization: Bearer $UMBRELLA"
status_is 404 "umbrella's is gone"

# --- a JOIN of two tables that both have TENANT_ID (CITY.DETAILS: one
# ${TENANT.alias} tag per table, the state's in the LEFT JOIN's ON). On the
# shared database, umbrella registers RS first: with the tenant missing from
# ON, initech's Porto Alegre would show umbrella's state (measured on SQLite).
req POST /states '{"code":"RS","name":"Umbrella RS"}' -H "Authorization: Bearer $UMBRELLA"
status_is 201 "umbrella registers RS"
req GET /cities/4314902/details "" -H "Authorization: Bearer $INITECH"
status_is 200 "join: initech's city without its state is still found (LEFT JOIN)"
body_is '{"code":"4314902","name":"Porto Alegre","state":"RS","stateName":null}' "join: another tenant's state is not joined (shared database)"
req GET /cities/4314902/details "" -H "Authorization: Bearer $UMBRELLA"
status_is 404 "join: umbrella reads initech's city (shared database)"
req POST /states '{"code":"RS","name":"Rio Grande do Sul"}' -H "Authorization: Bearer $INITECH"
status_is 201 "initech registers RS too (same code, another tenant)"
req POST /states '{"code":"rs","name":"Again"}' -H "Authorization: Bearer $INITECH"
status_is 409 "the same state twice in one tenant"
req POST /states "{\"code\":\"PR\",\"name\":\"$(printf 'x%.0s' $(seq 1 101))\"}" -H "Authorization: Bearer $INITECH"
status_is 400 "state name: at most 100 characters"
req GET /cities/4314902/details "" -H "Authorization: Bearer $INITECH"
body_is '{"code":"4314902","name":"Porto Alegre","state":"RS","stateName":"Rio Grande do Sul"}' "join: initech's own state, once"
req POST /states '{"code":"SC","name":"Santa Catarina"}' -H "Authorization: Bearer $ACME"
status_is 201 "acme registers SC (dedicated)"
req GET /cities/4205407/details "" -H "Authorization: Bearer $ACME"
body_has '"stateName":"Santa Catarina"' "join: acme's state (dedicated)"
req GET /cities/4205407/details "" -H "Authorization: Bearer $GLOBEX"
body_has '"stateName":null' "join: globex has no SC (dedicated)"

# --- refresh tokens (PascalApi.RefreshTokens in the control database, the
# tenant as the scope): rotation, a spent token coming back, two refreshes
# racing, logout, a token moved to another tenant, an unknown or suspended
# tenant, a user the check refuses, expiry. Every refusal is the same 401.
field()     { sed -n 's/.*"'"$1"'":"\([^"]*\)".*/\1/p' "$T/body"; }
num_field() { sed -n 's/.*"'"$1"'":\([0-9][0-9]*\).*/\1/p' "$T/body"; }
refresh()   { req POST /auth/refresh "{\"refreshToken\":\"$1\"}"; }
logout()    { req POST /auth/logout "{\"refreshToken\":\"$1\"}"; }
INVALID_REFRESH='{"error":"Invalid or expired refresh token.","code":"invalid_refresh_token"}'
refused()   { status_is 401 "$1"; body_is "$INVALID_REFRESH" "$1"; header_is WWW-Authenticate 'Bearer' "$1"; }
login acme ana > /dev/null
header_is Cache-Control 'no-store' "login: tokens are not cached"
REFRESH1="$(field refreshToken)"
REFRESH_SECONDS="$(num_field refreshExpiresIn)"
case "$REFRESH1" in acme.*) ok ;; *) fail "login: the refresh token names its tenant ($REFRESH1)" ;; esac
SECRET1="${REFRESH1#acme.}"
refresh "$REFRESH1"
status_is 200 "refresh"
header_is Cache-Control 'no-store' "refresh: tokens are not cached"
REFRESH2="$(field refreshToken)"
case "$REFRESH2" in acme.*) [ "$REFRESH2" != "$REFRESH1" ] && ok || fail "refresh: a new token" ;; *) fail "refresh: acme's next token ($REFRESH2)" ;; esac
req GET /tenant "" -H "Authorization: Bearer $(field token)"
body_is '{"tenant":"acme","mode":"dedicated"}' "refresh: the new access token is acme's"
# A spent token comes back: its whole login ends.
refresh "$REFRESH1"
refused "a spent refresh token"
refresh "$REFRESH2"
refused "after a reuse, the newest token of the login is revoked too"
# Two refreshes of one token at once (a shared tenant): never two winners,
# and the login ends.
login initech ana > /dev/null
RACE="$(field refreshToken)"
for N in 1 2; do
  curl -s -o "$T/race$N" -w '%{http_code}' -H 'Content-Type: application/json' \
    --data-binary "{\"refreshToken\":\"$RACE\"}" "$BASE/auth/refresh" > "$T/race$N.status" &
done
wait
STATUSES="$(cat "$T/race1.status") $(cat "$T/race2.status")"
case "$STATUSES" in "200 401"|"401 200"|"401 401") ok ;; *) fail "race: statuses $STATUSES, expected one 200 at most and a 401" ;; esac
for N in 1 2; do
  if [ "$(cat "$T/race$N.status")" = 200 ]; then
    refresh "$(sed -n 's/.*"refreshToken":"\([^"]*\)".*/\1/p' "$T/race$N")"
    refused "race: the winner's next token is revoked with its login"
  fi
done
# Another tenant's prefix on a real secret: the hash is acme's, not theirs.
login acme bia > /dev/null
REFRESH3="$(field refreshToken)"
refresh "globex.${REFRESH3#acme.}"
refused "refresh: acme's secret under globex"
refresh "initech.${REFRESH3#acme.}"
refused "refresh: acme's secret under a shared tenant"
refresh "nowhere.${REFRESH3#acme.}"
refused "refresh: a tenant the catalog doesn't have, the same answer"
refresh "${REFRESH3#acme.}"
refused "refresh: the secret without its tenant"
refresh "soylent.${REFRESH3#acme.}"
status_is 403 "refresh: a suspended tenant"
body_has '"code":"tenant_suspended"' "refresh: a suspended tenant"
refresh "garbage"
refused "refresh: garbage"
refresh "$REFRESH3"
status_is 200 "refresh: the real one still works after the attempts"
REFRESH3="$(field refreshToken)"
req POST /auth/refresh '{}'
status_is 400 "refresh without a token"
# Logout: the same answer for any token.
logout "$REFRESH3"
status_is 204 "logout"
refresh "$REFRESH3"
refused "refresh after logout"
logout "$REFRESH3"
status_is 204 "logout again: the same answer"
logout "nowhere.$SECRET1"
status_is 204 "logout under an unknown tenant: the same answer"
logout "garbage"
status_is 204 "logout of garbage: the same answer"
# A user deactivated after the login: the check refuses, the login ends.
login umbrella blocked-1 > /dev/null
refresh "$(field refreshToken)"
refused "a user the check refuses"
# Expiry, when the runner set a short REFRESH_TOKEN_SECONDS (tools/test_http.sh).
if [ "$REFRESH_SECONDS" -le 10 ] 2>/dev/null; then
  login globex ana > /dev/null
  EXPIRING="$(field refreshToken)"
  sleep $((REFRESH_SECONDS + 1))
  refresh "$EXPIRING"
  refused "an expired refresh token"
else
  echo "skipped: refresh token expiry (refreshExpiresIn $REFRESH_SECONDS; set REFRESH_TOKEN_SECONDS=3)"
fi
if [ -n "$SERVER_LOG" ]; then
  sleep 1
  grep -q "^SECURITY refresh token family [0-9a-f]* of scope acme revoked: a used refresh token came back" \
    "$SERVER_LOG" && ok || fail "log: acme's reuse"
  # The race's loser logs "raced", or "came back" when the first had finished.
  grep -q "^SECURITY refresh token family [0-9a-f]* of scope initech revoked: \(a used refresh token came back\|two refreshes raced\)" \
    "$SERVER_LOG" && ok || fail "log: initech's race"
  grep -q "^SECURITY refresh token family [0-9a-f]* of scope umbrella revoked: the user is gone or inactive" \
    "$SERVER_LOG" && ok || fail "log: the user refused"
  grep '^SECURITY' "$SERVER_LOG" | grep -v 'came back\|raced on one token\|gone or inactive' | grep -q . \
    && fail "log: an unexpected SECURITY line" || ok
  grep -q "$SECRET1" "$SERVER_LOG" && fail "log: a refresh token reached the log" || ok
fi

# --- rate limit: one window per tenant, its limit by the tenant's plan
# (TRateLimitOptions.KeyExtractor and LimitFor)
curl -s -D "$T/headers" -o /dev/null -H "Authorization: Bearer $ACME" "$BASE/tenant"
grep -qi '^X-RateLimit-Limit: 1000' "$T/headers" && ok || fail "acme: the default limit, 1000 (headers: $(cat "$T/headers"))"
HOOLI="$(login hooli eva)"
[ -n "$HOOLI" ] && ok || fail "login hooli (plan free): $(cat "$T/body")"
for N in 1 2 3 4 5; do
  req GET /tenant "" -H "Authorization: Bearer $HOOLI"
  status_is 200 "hooli (plan free), request $N of 5"
done
curl -s -D "$T/headers" -o "$T/body" -w '%{http_code}' -H "Authorization: Bearer $HOOLI" "$BASE/tenant" > "$T/status"
status_is 429 "hooli, a 6th request within the minute"
grep -qi '^X-RateLimit-Limit: 5' "$T/headers" && ok || fail "hooli: the plan's limit, 5 (headers: $(cat "$T/headers"))"
req GET /tenant "" -H "Authorization: Bearer $INITECH"
status_is 200 "initech, on the same shared database, has its own window"
# A route that doesn't exist: Horse runs the global middlewares twice, and
# the limit counted it twice (with its headers twice) until it marked the
# request.
req GET /no/such/route "" -H "Authorization: Bearer $ACME"
R1="$(header X-RateLimit-Remaining)"
req GET /no/such/route "" -H "Authorization: Bearer $ACME"
status_is 404 "unknown route, rate limited"
R2="$(header X-RateLimit-Remaining)"
[ -n "$R1" ] && [ "$R2" = "$((R1 - 1))" ] && ok \
  || fail "unknown route: one slot per request (remaining $R1, then $R2)"
[ "$(tr -d '\r' < "$T/headers" | grep -ci '^X-RateLimit-Remaining:')" = 1 ] && ok \
  || fail "unknown route: X-RateLimit-Remaining once"

# --- tenant.id in the access log (TLoggerMiddleware.AddField), when the
# runner says where the server's output goes
if [ -n "$SERVER_LOG" ]; then
  req GET "/tenant?probe=acme" "" -H "Authorization: Bearer $ACME"
  # No token: the JWT middleware answers 401 before the tenant middleware
  # runs, with a client's line under the tenant mark's name.
  raw GET "/cities?probe=spoof" "" ":pascalapi-tenant: acme"
  body_has ' 401 ' "a request without a token, with a raw tenant mark line"
  # The logger's own mark, sent by hand: it must not hide the request.
  raw GET "/health/live?probe=hidden" "" ":pascalapi-logged: 1"
  sleep 1
  grep 'probe=acme' "$SERVER_LOG" | grep -qF '"tenant.id":"acme"' && ok \
    || fail "log: tenant.id of acme's request ($(grep 'probe=acme' "$SERVER_LOG"))"
  grep -q 'probe=spoof' "$SERVER_LOG" && ok || fail "log: the 401 is logged"
  grep 'probe=spoof' "$SERVER_LOG" | grep -qF 'tenant.id' && fail "log: a client's tenant mark reached the log" || ok
  grep -q 'probe=hidden' "$SERVER_LOG" && ok || fail "log: a raw :pascalapi-logged line hid the request"
fi

# --- the routes that need no tenant
req GET /health/live ""
status_is 200 "health needs no tenant"
req GET /swagger/doc.json ""
status_is 200 "OpenAPI document"
body_has '"/cities/{code}"' "OpenAPI: path template"
body_has '"/cities/{code}/details"' "OpenAPI: the join's route"
body_has '"/auth/login":{"post":{"tags":["public"],"summary":"Get a token for one tenant (1 hour)","security":[]' "OpenAPI: login needs no token"
[ -n "$OPENAPI_OUT" ] && cp "$T/body" "$OPENAPI_OUT"

# --- pools named by mode, never by tenant (pascal-db-faa's metrics)
req GET /metrics ""
status_is 200 "metrics"
grep -q 'pool_name="dedicated"' "$T/body" && ok || fail "metrics: a pool named dedicated"
grep -q 'pool_name="shared"' "$T/body" && ok || fail "metrics: a pool named shared"
grep -qE 'pool_name="(acme|globex|initech|umbrella|soylent|hooli|tenant_)' "$T/body" && fail "metrics: a pool named by tenant" || ok
grep -q 'pool_name="control"' "$T/body" && ok || fail "metrics: the control database's pool (the catalog)"
# Two dedicated pools of 5 under one name: their series add up.
MAX_DEDICATED=$(metric_sum db_client_connection_max 'pool_name="dedicated"' "$T/body")
[ "$MAX_DEDICATED" = "10" ] && ok || fail "metrics: db_client_connection_max of the dedicated pools is 2 x 5 (got $MAX_DEDICATED)"
MAX_SHARED=$(metric_sum db_client_connection_max 'pool_name="shared"' "$T/body")
[ "$MAX_SHARED" = "5" ] && ok || fail "metrics: db_client_connection_max of the shared pool is 5 (got $MAX_SHARED)"
[ -n "$METRICS_OUT" ] && cp "$T/body" "$METRICS_OUT"

rm -rf "$T"
echo "$CHECKS checks, $FAILS failed"
[ "$FAILS" -eq 0 ]
