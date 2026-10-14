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
#                                               --reset, default TENANTS and
#                                               JWT_SECRET)
#   SERVER_LOG=path/server.log sh tools/http_scenarios_tenants.sh [port]
#
# Tokens the sample would never issue (a removed tenant, no tenant, a
# suspended one) are signed here with Python's hmac, with the sample's
# default secret. Same script for every build of the sample (FPC
# Windows/Linux, Delphi Win32/Win64). Exit code 0 only if every check passed.
PORT="${1:-9350}"
BASE="http://127.0.0.1:$PORT"
SECRET="${JWT_SECRET:-development-secret-change-me}"
T="$(mktemp -d)"
FAILS=0
CHECKS=0

# Windows has a python3 that only opens the Store; take the one that runs.
PY=python3
$PY -c "" >/dev/null 2>&1 || PY=python

req() {
  M="$1"; P="$2"; B="$3"; shift 3 2>/dev/null || shift $#
  if [ -n "$B" ]; then
    curl -s -X "$M" -o "$T/body" -w '%{http_code}' -H 'Content-Type: application/json' \
      --data-binary "$B" "$@" "$BASE$P" > "$T/status"
  else
    curl -s -X "$M" -o "$T/body" -w '%{http_code}' "$@" "$BASE$P" > "$T/status"
  fi
}
ok()   { CHECKS=$((CHECKS + 1)); }
fail() { CHECKS=$((CHECKS + 1)); FAILS=$((FAILS + 1)); echo "FAIL: $1"; }
status_is() { [ "$(cat "$T/status")" = "$1" ] && ok || fail "$2: status $(cat "$T/status"), expected $1 (body: $(cat "$T/body"))"; }
body_is()   { [ "$(cat "$T/body")" = "$1" ] && ok || fail "$2: body $(cat "$T/body"), expected $1"; }
body_has()  { grep -qF -- "$1" "$T/body" && ok || fail "$2: body lacks $1 (body: $(cat "$T/body"))"; }
body_lacks(){ grep -qF -- "$1" "$T/body" && fail "$2: body has $1" || ok; }
# Sum of a metric's samples whose labels contain $2 (a Prometheus text file in $3).
metric_sum() { awk -v n="$1" -v l="$2" 'index($1, n "{") == 1 && index($1, l) > 0 { s += $NF } END { printf "%d", s }' "$3"; }

# login TENANT USER -> prints the token ('' when refused)
login() {
  req POST /auth/login "{\"tenant\":\"$1\",\"user\":\"$2\"}"
  sed -n 's/.*"token":"\([^"]*\)".*/\1/p' "$T/body"
}
# sign CLAIMS_JSON -> an HS256 token for those claims, exp one hour ahead
sign() {
  $PY -c '
import sys, hmac, hashlib, base64, json, time
b = lambda d: base64.urlsafe_b64encode(d).rstrip(b"=").decode()
claims = json.loads(sys.argv[1]); claims["exp"] = int(time.time()) + 3600
h = b(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
p = b(json.dumps(claims).encode())
s = b(hmac.new(sys.argv[2].encode(), (h + "." + p).encode(), hashlib.sha256).digest())
print(h + "." + p + "." + s)' "$1" "$SECRET"
}

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
req GET /cities/4314902/details "" -H "Authorization: Bearer $INITECH"
body_is '{"code":"4314902","name":"Porto Alegre","state":"RS","stateName":"Rio Grande do Sul"}' "join: initech's own state, once"
req POST /states '{"code":"SC","name":"Santa Catarina"}' -H "Authorization: Bearer $ACME"
status_is 201 "acme registers SC (dedicated)"
req GET /cities/4205407/details "" -H "Authorization: Bearer $ACME"
body_has '"stateName":"Santa Catarina"' "join: acme's state (dedicated)"
req GET /cities/4205407/details "" -H "Authorization: Bearer $GLOBEX"
body_has '"stateName":null' "join: globex has no SC (dedicated)"

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
