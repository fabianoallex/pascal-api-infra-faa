#!/bin/sh
# Checks samples/01-api over HTTP with curl: every middleware of
# PascalApi.Horse.Middlewares (error handler, CORS, logger's request id,
# JWT, rate limit) plus paging, ordering and DTO validation.
#
#   sh tools/http_scenarios.sh [port]      (default 9310; ApiSample must be running)
#
# Same script for every build of the sample (FPC Windows/Linux, Delphi
# Win32/Win64). Exit code 0 only if every check passed.
PORT="${1:-9310}"
BASE="http://127.0.0.1:$PORT"
T="$(mktemp -d)"
FAILS=0
CHECKS=0

# req METHOD PATH [BODY] [extra curl args...] -> $T/status, $T/headers, $T/body
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
no_header() { [ -z "$(header "$1")" ] && ok || fail "$2: unexpected header $1: $(header "$1")"; }

# --- public route, request id
req GET /health ""
status_is 200 "health"
body_is '{"status":"ok"}' "health"
echo "$(header X-Request-Id)" | grep -qE '^[0-9a-f]{8}$' && ok || fail "health: X-Request-Id '$(header X-Request-Id)'"

# --- CORS (before JWT: a preflight carries no token)
req OPTIONS /cities "" -H 'Origin: https://app.example.com' -H 'Access-Control-Request-Method: GET'
status_is 204 "preflight"
header_is Access-Control-Allow-Origin 'https://app.example.com' "preflight"
header_is Vary 'Origin' "preflight"
header_is Access-Control-Allow-Methods 'GET,POST,PUT,PATCH,DELETE,OPTIONS' "preflight"
req OPTIONS /cities "" -H 'Origin: https://evil.example'
no_header Access-Control-Allow-Origin "preflight from another origin"
req GET /health "" -H 'Origin: https://app.example.com'
header_is Access-Control-Allow-Origin 'https://app.example.com' "simple request"

# --- JWT
req GET /cities ""
status_is 401 "no token"
body_is '{"error":"Authorization token missing."}' "no token"
req GET /cities "" -H 'Authorization: Basic dXNlcjpwYXNz'
status_is 401 "basic auth"
body_has 'Bearer <token>' "basic auth"
req GET /cities "" -H 'Authorization: Bearer abc.def.ghi'
status_is 401 "bad token"
body_is '{"error":"Invalid or expired token."}' "bad token"
req POST /auth/login '{"user":"ana"}'
status_is 200 "login"
TOKEN="$(sed 's/.*"token":"\([^"]*\)".*/\1/' "$T/body")"
AUTH="Authorization: Bearer $TOKEN"
req GET /me "" -H "$AUTH"
status_is 200 "me"
body_is '{"sub":"ana"}' "me"
req POST /auth/login '{"name":"ana"}'
status_is 400 "login without user"
body_is '{"error":"\"user\" is required."}' "login without user"
req GET /auth/login-admin ""
status_is 401 "excluded prefix matches whole segments only"

# --- paging and ordering
req GET '/cities?page=1&limit=2' "" -H "$AUTH"
status_is 200 "cities page 1"
body_has '"page":1,"limit":2,"total":5,"totalPages":3,"hasNext":true,"hasPrev":false' "cities page 1"
body_has '"name":"Belém"' "cities page 1 (ordered by name, UTF-8)"
body_has '"name":"Campinas"' "cities page 1"
req GET '/cities?page=3&limit=2&orderBy=-name' "" -H "$AUTH"
body_has '"hasNext":false,"hasPrev":true' "cities page 3"
body_has '"name":"Belém"' "cities page 3, descending"
req GET '/cities?limit=1&orderBy=state' "" -H "$AUTH"
body_has '"state":"PA"' "cities by state"
req GET '/cities?limit=500' "" -H "$AUTH"
body_has '"limit":10' "limit clamped to the maximum"
req GET '/cities?orderBy=population' "" -H "$AUTH"
status_is 400 "order by a field not allowed"
body_has 'Invalid order field: \"population\"' "order by a field not allowed"

# --- not found, create, validation, body errors
req GET /cities/1 "" -H "$AUTH"
body_is '{"id":1,"name":"São Paulo","state":"SP","population":11451999}' "city 1"
req GET /cities/99 "" -H "$AUTH"
status_is 404 "city 99"
body_is '{"error":"City 99 not found."}' "city 99"
req POST /cities '{"name":"Natal","state":"rn"}' -H "$AUTH"
status_is 201 "create"
body_is '{"id":6,"name":"Natal","state":"RN","population":null}' "create"
# Non-ASCII bodies go from a file with explicit UTF-8 bytes: Git Bash on
# Windows hands curl.exe its arguments in the ANSI code page (cp1252).
printf '{"name":"Macei\303\263","state":"AL","population":957916}' > "$T/utf8"
req POST /cities "@$T/utf8" -H "$AUTH"
body_has '"name":"Maceió"' "create with non-ASCII and population"
body_has '"population":957916' "create with non-ASCII and population"
req POST /cities '{"name":"","state":"SP"}' -H "$AUTH"
status_is 400 "create without name"
body_is '{"error":"\"name\" is required."}' "create without name"
req POST /cities '{"name":' -H "$AUTH"
status_is 400 "malformed JSON"
body_has 'Invalid request body:' "malformed JSON"
req POST /cities '{"name":"X","state":"SP","population":"many"}' -H "$AUTH"
status_is 400 "wrong type"
body_has '$.population' "wrong type"
printf '{"name":"S\343o","state":"SP"}' > "$T/latin1"
curl -s -o "$T/body" -w '%{http_code}' -H 'Content-Type: application/json' -H "$AUTH" \
  --data-binary "@$T/latin1" "$BASE/cities" > "$T/status"
[ "$(cat "$T/status")" != "500" ] && ok || fail "body not in UTF-8 must not be a 500 (body: $(cat "$T/body"))"

# --- server and database errors
req GET /fail/server "" -H "$AUTH"
status_is 500 "server error"
body_is '{"error":"something broke"}' "server error"
req GET /fail/database "" -H "$AUTH"
status_is 503 "database down"
body_is '{"error":"The database is unavailable. Try again shortly."}' "database down"
body_lacks 'db.internal' "database down: no driver detail"

# --- rate limit: 3 per minute per X-Client
for N in 2 1 0; do
  req GET /limited "" -H "$AUTH" -H 'X-Client: a'
  status_is 200 "limited, remaining $N"
  header_is X-RateLimit-Remaining "$N" "limited"
  header_is X-RateLimit-Limit 3 "limited"
done
req GET /limited "" -H "$AUTH" -H 'X-Client: a'
status_is 429 "over the limit"
body_has 'Rate limit exceeded.' "over the limit"
RA="$(header Retry-After)"
[ -n "$RA" ] && [ "$RA" -ge 1 ] && [ "$RA" -le 60 ] && ok || fail "Retry-After '$RA'"
req GET /limited "" -H "$AUTH" -H 'X-Client: b'
status_is 200 "another client"
req GET /cities/1 "" -H "$AUTH" -H 'X-Client: a'
status_is 200 "rate limit only on /limited"
req GET /health "" -H 'X-Forwarded-For: 203.0.113.9, 10.0.0.1'
status_is 200 "health behind a proxy"

rm -rf "$T"
echo "$CHECKS checks, $FAILS failed"
[ "$FAILS" -eq 0 ]
