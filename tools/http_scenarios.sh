#!/bin/sh
# Checks samples/01-api over HTTP with curl: every middleware of
# PascalApi.Horse.Middlewares (error handler, CORS, logger's trace id,
# JWT, rate limit) plus paging, ordering, DTO validation, OpenAPI, the
# MCP endpoint (2026-07-28), and metrics and health
# (PascalApi.Horse.Observability).
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

# --- public route, request id = W3C trace id
TRACE_ID=4bf92f3577b34da6a3ce929d0e0e4736
PARENT_ID=00f067aa0ba902b7
is_trace_id() { echo "$1" | grep -qE '^[0-9a-f]{32}$' && [ "$1" != 00000000000000000000000000000000 ]; }
req GET /health ""
status_is 200 "health"
body_is '{"status":"ok"}' "health"
is_trace_id "$(header X-Request-Id)" && ok || fail "health: X-Request-Id '$(header X-Request-Id)'"
FIRST_ID="$(header X-Request-Id)"
req GET /health ""
[ "$(header X-Request-Id)" != "$FIRST_ID" ] && ok || fail "a new trace id per request"
req GET /health "" -H "traceparent: 00-$TRACE_ID-$PARENT_ID-01"
header_is X-Request-Id "$TRACE_ID" "trace id from traceparent"
req GET /health "" -H "traceparent: 00-$(echo $TRACE_ID | tr a-f A-F)-$PARENT_ID-01"
is_trace_id "$(header X-Request-Id)" && [ "$(header X-Request-Id)" != "$TRACE_ID" ] && ok   || fail "uppercase traceparent ignored: X-Request-Id '$(header X-Request-Id)'"
req GET /health "" -H "X-Request-Id: $TRACE_ID"
header_is X-Request-Id "$TRACE_ID" "32-digit X-Request-Id adopted"
req GET /health "" -H 'X-Request-Id: 1a2b3c4d'
is_trace_id "$(header X-Request-Id)" && ok || fail "short X-Request-Id replaced: '$(header X-Request-Id)'"
req GET /health "" -H 'X-Request-Id: <script>'
is_trace_id "$(header X-Request-Id)" && ok || fail "free-text X-Request-Id replaced: '$(header X-Request-Id)'"

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
# A path no route matches (public, so it gets past JWT): Horse runs the
# global middlewares twice, and the CORS headers came twice until 0.16.0
# (measured on FPC and Delphi). A browser refuses an answer with two
# Access-Control-Allow-Origin, so the 404 became a CORS error.
header_count() { tr -d '\r' < "$T/headers" | grep -ci "^$1:"; }
req GET /swagger/missing "" -H 'Origin: https://app.example.com'
status_is 404 "no route, public path"
[ "$(header_count Access-Control-Allow-Origin)" = 1 ] && ok \
  || fail "no route: Access-Control-Allow-Origin $(header_count Access-Control-Allow-Origin) times"
[ "$(header_count Vary)" = 1 ] && ok || fail "no route: Vary $(header_count Vary) times"
[ "$(header_count X-Request-Id)" = 1 ] && ok || fail "no route: X-Request-Id $(header_count X-Request-Id) times"

# --- JWT
req GET /cities ""
status_is 401 "no token"
body_is '{"error":"Authorization token missing."}' "no token"
header_is WWW-Authenticate 'Bearer' "no token: the challenge HTTP requires on a 401"
req GET /cities "" -H 'Authorization: Basic dXNlcjpwYXNz'
status_is 401 "basic auth"
body_has 'Bearer <token>' "basic auth"
header_is WWW-Authenticate 'Bearer' "basic auth"
req GET /cities "" -H 'Authorization: Bearer abc.def.ghi'
status_is 401 "bad token"
body_is '{"error":"Invalid or expired token."}' "bad token"
header_is WWW-Authenticate 'Bearer error="invalid_token"' "bad token"
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
req GET /no/such/route "" -H "$AUTH"
status_is 404 "unknown route"
[ "$(tr -d '\r' < "$T/headers" | grep -ci '^X-Request-Id:')" = 1 ] && ok \
  || fail "unknown route: one X-Request-Id (Horse runs the middlewares twice there)"

# --- refresh tokens (PascalApi.RefreshTokens, in memory, scope ''): rotation,
# a spent token coming back, two refreshes racing, logout, logout everywhere,
# a user the check refuses, expiry. Every refusal is the same 401.
field()     { sed -n 's/.*"'"$1"'":"\([^"]*\)".*/\1/p' "$T/body"; }
num_field() { sed -n 's/.*"'"$1"'":\([0-9][0-9]*\).*/\1/p' "$T/body"; }
login()     { req POST /auth/login "{\"user\":\"$1\"}"; }
refresh()   { req POST /auth/refresh "{\"refreshToken\":\"$1\"}"; }
logout()    { req POST /auth/logout "{\"refreshToken\":\"$1\"}"; }
INVALID_REFRESH='{"error":"Invalid or expired refresh token.","code":"invalid_refresh_token"}'
refused()   { status_is 401 "$1"; body_is "$INVALID_REFRESH" "$1"; header_is WWW-Authenticate 'Bearer' "$1"; }
login rita
header_is Cache-Control 'no-store' "login: tokens are not cached"
REFRESH1="$(field refreshToken)"
REFRESH_SECONDS="$(num_field refreshExpiresIn)"
[ "$(printf %s "$REFRESH1" | wc -c | tr -d ' ')" = 43 ] && ok || fail "login: a 43-character refresh token ($REFRESH1)"
[ -n "$(num_field expiresIn)" ] && [ -n "$REFRESH_SECONDS" ] && ok || fail "login: expiresIn and refreshExpiresIn ($(cat "$T/body"))"
refresh "$REFRESH1"
status_is 200 "refresh"
header_is Cache-Control 'no-store' "refresh: tokens are not cached"
REFRESH2="$(field refreshToken)"
[ -n "$REFRESH2" ] && [ "$REFRESH2" != "$REFRESH1" ] && ok || fail "refresh: a new refresh token"
req GET /me "" -H "Authorization: Bearer $(field token)"
body_is '{"sub":"rita"}' "refresh: the new access token is the same user's"
# A spent token comes back: someone kept a copy. Its whole login ends.
refresh "$REFRESH1"
refused "a spent refresh token"
refresh "$REFRESH2"
refused "after a reuse, the newest token of the login is revoked too"
# Two refreshes of one token at once: never two winners, and the login
# ends (the loser can't tell a race from a copy). Usually one 200 and one
# 401; both 401 when the loser revoked before the winner stored its next
# token (PascalApi.RefreshTokens refuses the winner then).
login rita
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
  else
    [ "$(cat "$T/race$N")" = "$INVALID_REFRESH" ] && ok || fail "race: the loser's body $(cat "$T/race$N")"
  fi
done
# Logout: the same answer for any token.
login rita
REFRESH3="$(field refreshToken)"
logout "$REFRESH3"
status_is 204 "logout"
refresh "$REFRESH3"
refused "refresh after logout"
logout "$REFRESH3"
status_is 204 "logout again: the same answer"
logout "garbage"
status_is 204 "logout of garbage: the same answer"
req POST /auth/logout '{}'
status_is 400 "logout without a token"
# Malformed and moved tokens.
refresh "garbage"
refused "refresh: garbage"
login rita
REFRESH4="$(field refreshToken)"
refresh "acme.$REFRESH4"
refused "refresh: the secret under a scope it wasn't issued for"
refresh "$REFRESH4"
status_is 200 "refresh: the real one still works after the attempts"
req POST /auth/refresh '{}'
status_is 400 "refresh without a token"
body_is '{"error":"\"refreshToken\" is required."}' "refresh without a token"
req POST /auth/refresh '{"refreshToken":"x","user":"admin"}'
status_is 400 "refresh with an unknown member"
# A user deactivated after the login: the check refuses, the login ends.
login blocked-1
BLOCKED="$(field refreshToken)"
refresh "$BLOCKED"
refused "a user the check refuses"
# Sign out everywhere: every login of the caller, nobody else's.
login rita
RITA_A="$(field refreshToken)"
RITA_ACCESS="$(field token)"
login rita
RITA_B="$(field refreshToken)"
login bob
BOB="$(field refreshToken)"
req POST /auth/logout-all "" -H "Authorization: Bearer $RITA_ACCESS"
status_is 204 "logout-all"
refresh "$RITA_A"
refused "logout-all: the first login"
refresh "$RITA_B"
refused "logout-all: the second login"
refresh "$BOB"
status_is 200 "logout-all: another user keeps theirs"
req POST /auth/logout-all ""
status_is 401 "logout-all needs an access token (only /auth/logout is public)"
# Expiry, when the runner set a short REFRESH_TOKEN_SECONDS (tools/test_http.sh).
if [ "$REFRESH_SECONDS" -le 10 ] 2>/dev/null; then
  login rita
  EXPIRING="$(field refreshToken)"
  sleep $((REFRESH_SECONDS + 1))
  refresh "$EXPIRING"
  refused "an expired refresh token"
else
  echo "skipped: refresh token expiry (refreshExpiresIn $REFRESH_SECONDS; set REFRESH_TOKEN_SECONDS=3)"
fi
if [ -n "$SERVER_LOG" ]; then
  sleep 1
  grep -q "^SECURITY refresh token family [0-9a-f]* revoked: a used refresh token came back" \
    "$SERVER_LOG" && ok || fail "log: the reuse"
  # The race's loser logs "raced" when both read the token before either
  # marked it, and "came back" when the first had finished (often, measured
  # 2026-10-19): two reuse lines, or one of each.
  SECURITY_LINES="$(grep -c '^SECURITY .*revoked: \(a used refresh token came back\|two refreshes raced\)' "$SERVER_LOG")"
  [ "$SECURITY_LINES" -ge 2 ] && ok || fail "log: the reuse and the race ($SECURITY_LINES lines)"
  grep -q "^SECURITY refresh token family [0-9a-f]* revoked: the user is gone or inactive" \
    "$SERVER_LOG" && ok || fail "log: the user refused"
  # A logout, logout-all or an expiry is not a security event.
  grep '^SECURITY' "$SERVER_LOG" | grep -v 'came back\|raced on one token\|gone or inactive' | grep -q . \
    && fail "log: an unexpected SECURITY line" || ok
  grep -q "$REFRESH2\|$RACE" "$SERVER_LOG" && fail "log: a refresh token reached the log" || ok
fi

# --- what the handler sees: X-Request-Id and its own span in traceparent
req GET /trace "" -H "$AUTH" -H "traceparent: 00-$TRACE_ID-$PARENT_ID-01" -H 'tracestate: vendor=1'
status_is 200 "trace"
body_has "\"requestId\":\"$TRACE_ID\"" "trace: handler sees the trace id"
body_has "\"traceparent\":\"00-$TRACE_ID-" "trace: handler's traceparent keeps the trace"
body_lacks "$PARENT_ID" "trace: handler's traceparent is a new span, not the caller's"
body_has '-01"' "trace: sampled flag kept"
body_has '"tracestate":"vendor=1"' "trace: tracestate passed on"
# Its own trace id: tools/otlp_check.py checks that this one was never exported.
NOT_SAMPLED_ID=5bf92f3577b34da6a3ce929d0e0e4736
req GET /trace "" -H "$AUTH" -H "traceparent: 00-$NOT_SAMPLED_ID-$PARENT_ID-00"
body_has '-00"' "trace: not-sampled flag kept"
req GET /trace "" -H "$AUTH" -H 'traceparent: garbage' -H 'tracestate: vendor=1'
body_has '"tracestate":""' "trace: tracestate dropped with an invalid traceparent"

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
req GET '/cities?page=abc' "" -H "$AUTH"
status_is 400 "page not a number"
body_is '{"error":"\"page\" must be an integer."}' "page not a number: names the parameter"
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
# umError (the sample's setting): an unknown member is a 400 with its path.
req POST /cities '{"name":"X","state":"SP","popultion":5}' -H "$AUTH"
status_is 400 "unknown member"
body_has '$.popultion' "unknown member: its path"
# A member sent twice is refused (pascal-jsonmapper-faa 0.4.0; 0.3.0 kept
# one of them, and parsers disagree on which), also when the names differ
# only in case.
req POST /cities '{"name":"First","name":"Second","state":"SP"}' -H "$AUTH"
status_is 400 "duplicate member"
body_has '$.name: duplicate member' "duplicate member: its path"
req POST /cities '{"NAME":"First","name":"Second","state":"SP"}' -H "$AUTH"
status_is 400 "duplicate member, names differing only in case"
printf '{"name":"S\343o","state":"SP"}' > "$T/latin1"
curl -s -o "$T/body" -w '%{http_code}' -H 'Content-Type: application/json' -H "$AUTH" \
  --data-binary "@$T/latin1" "$BASE/cities" > "$T/status"
[ "$(cat "$T/status")" != "500" ] && ok || fail "body not in UTF-8 must not be a 500 (body: $(cat "$T/body"))"

# --- a Currency through the mapper, both ways
# pascal-jsonmapper-faa before 0.6.0, on FPC 3.2.2: 123456789012345.6789 came
# back as ...6768 on Win64 and High(Currency) was a 500 (their measurement).
for V in 123456789012345.6789 922337203685477.5807 -922337203685477.5808 0.0001; do
  req POST /prices "{\"item\":\"x\",\"amount\":$V}" -H "$AUTH"
  status_is 200 "price $V"
  body_is "{\"item\":\"x\",\"amount\":$V}" "price $V: exact"
done
req POST /prices '{"item":"x","amount":0.00025}' -H "$AUTH"
body_is '{"item":"x","amount":0.0002}' "price beyond 4 decimals: half to even"
req POST /prices '{"item":"x","amount":922337203685477.5808}' -H "$AUTH"
status_is 400 "price above Currency's range"
body_has '$.amount' "price above Currency's range: its path"

# --- server and database errors
# A logged error carries the request id in the body too (the one its log
# line ends with); an unexpected exception's own message reaches the log only.
req GET /fail/server "" -H "$AUTH"
status_is 500 "server error"
FAIL_ID="$(header X-Request-Id)"
body_is "{\"error\":\"An unexpected error occurred.\",\"requestId\":\"$FAIL_ID\"}" "server error: fixed message and the request id"
body_lacks 'something broke' "server error: the exception's message stays in the log"
req GET /fail/database "" -H "$AUTH"
status_is 503 "database down"
body_is "{\"error\":\"The database is unavailable. Try again shortly.\",\"requestId\":\"$(header X-Request-Id)\"}" "database down"
body_lacks 'db.internal' "database down: no driver detail"
req GET /fail/busy "" -H "$AUTH"
status_is 503 "pool timeout"
body_is "{\"error\":\"The server is busy. Try again shortly.\",\"requestId\":\"$(header X-Request-Id)\"}" "pool timeout"
body_lacks 'Pool:' "pool timeout: the pool's state stays in the log"
# A middleware's exception: on FPC, Horse passes it to fpWeb, not to
# THorse.OnError (fpWeb sent its message and stack as HTML); the logger
# answers it like the error handler.
req GET /fail/middleware "" -H "$AUTH"
status_is 500 "middleware error"
MW_ID="$(header X-Request-Id)"
body_is "{\"error\":\"An unexpected error occurred.\",\"requestId\":\"$MW_ID\"}" "middleware error: fixed message and the request id"
req GET '/fail/middleware?kind=validation' "" -H "$AUTH"
status_is 400 "middleware validation error"
body_is '{"error":"\"kind\" was rejected by a middleware."}' "middleware validation error"
# CreateFmt is Exception's: until 0.17.0 it left the status 0, and the
# answer was "HTTP/1.1 0" (curl: status 000).
req GET /fail/createfmt "" -H "$AUTH"
status_is 400 "CreateFmt keeps its class's status"
body_is '{"error":"\"name\" is required."}' "CreateFmt keeps its class's status"
req GET /fail/unauthorized "" -H "$AUTH"
status_is 401 "a handler's 401"
body_is '{"error":"Invalid email or password.","code":"invalid_credentials"}' "a handler's 401: its code"
header_is WWW-Authenticate 'Bearer' "a handler's 401: its scheme"

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

# --- OpenAPI document and Swagger UI (public)
req GET /swagger/doc.json ""
status_is 200 "OpenAPI document"
body_has '"openapi":"3.0.3"' "OpenAPI document"
body_has '"/cities/{id}":' "path parameter converted"
body_has '"requestBody"' "request body documented"
body_has '"securitySchemes":{"bearerAuth":{"type":"http","scheme":"bearer","bearerFormat":"JWT"}}' "JWT documented from the middleware"
body_has '"security":[{"bearerAuth":[]}]' "token required by default"
body_has '"/health":{"get":{"tags":["public"],"summary":"Liveness","security":[]' "a path the JWT middleware excludes needs no token"
body_lacks '"/me":{"get":{"tags":["auth"],"summary":"The token'"'"'s subject","security":[]' "a protected path keeps the requirement"
req GET /swagger ""
status_is 200 "Swagger UI"
body_has 'swagger-ui-dist@' "Swagger UI"
# OPENAPI_OUT: also save the document, for a validator (tools/test_http_docker.sh).
[ -n "$OPENAPI_OUT" ] && curl -s -o "$OPENAPI_OUT" "$BASE/swagger/doc.json"

# --- MCP (2026-07-28) on /mcp, behind JWT; each tool call goes back
# through the API with the caller's token.
META='"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}'
# mcp METHOD PARAMS [TOOL] [extra curl args...]
mcp() {
  MM="$1"; MP="$2"; MN="$3"; if [ $# -ge 3 ]; then shift 3; else shift $#; fi # dash: shift past $# is fatal
  req POST /mcp "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$MM\",\"params\":{$META$MP}}" \
    -H 'MCP-Protocol-Version: 2026-07-28' -H "Mcp-Method: $MM" ${MN:+-H "Mcp-Name: $MN"} "$@"
}
call() { mcp tools/call ",\"name\":\"$1\",\"arguments\":$2" "$1" -H "$AUTH"; }

mcp server/discover ""
status_is 401 "MCP without a token"
mcp server/discover "" "" -H "$AUTH"
status_is 200 "MCP discover"
body_is '{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","ttlMs":0,"cacheScope":"private","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}},"_meta":{"io.modelcontextprotocol/serverInfo":{"name":"pascal-api-sample-01","version":"1.0.0"}}}}' "MCP discover"
mcp tools/list "" "" -H "$AUTH"
status_is 200 "MCP tools/list"
body_has '{"name":"get_citie","description":"One city","inputSchema":{"type":"object","properties":{"id":{"type":"integer","description":"City id"}},"required":["id"],"additionalProperties":false}}' "MCP tool with a path parameter"
body_has '"name":"create_citie"' "MCP tool with a body"
body_lacks 'fail' "MCP: NoMcp routes left out"
body_lacks '"name":"create_refresh' "MCP: no refresh tool (NoMcp)"
body_lacks '"name":"create_logout' "MCP: no logout tools (NoMcp)"
body_has '"name":"create_login"' "MCP: the login is still a tool"
call list_citie '{"limit":1,"orderBy":"-name"}'
status_is 200 "MCP call, GET with a query string"
body_has '\"limit\":1,\"total\":' "MCP call: query arguments reach the route"
body_has '"isError":false' "MCP call"
call list_citie '{"orderBy":"population"}'
body_has 'Invalid order field' "MCP call: orderBy reaches the route"
body_has '"isError":true' "MCP call: orderBy reaches the route"
call get_citie '{"id":999}'
body_has '"isError":true' "MCP call, route answers 404"
body_has 'City 999 not found.' "MCP call, route answers 404"
call list_me '{}'
body_has '{\"sub\":\"ana\"}' "MCP call: the token is passed on"
printf "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{$META,\"name\":\"create_citie\",\"arguments\":{\"name\":\"S\303\243o Jos\303\251\",\"state\":\"SC\",\"population\":250000}}}" > "$T/mcp.json"
F="$T/mcp.json"; command -v cygpath >/dev/null 2>&1 && F="$(cygpath -w "$F")" # curl.exe on Windows
req POST /mcp "@$F" -H "$AUTH" -H 'MCP-Protocol-Version: 2026-07-28' -H 'Mcp-Method: tools/call' -H 'Mcp-Name: create_citie'
body_has "$(printf '\\"name\\":\\"S\303\243o Jos\303\251\\"')" "MCP call, POST body in UTF-8"
call get_citie '{}'
body_has 'Missing required argument: id' "MCP call without a required argument"
call get_citie '{"id":1,"town":"x"}'
body_has 'Unknown argument: town' "MCP call with an unknown argument"
call nope '{}'
status_is 400 "MCP unknown tool"
body_has '"code":-32602' "MCP unknown tool"
req POST /mcp "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{$META}}" -H "$AUTH"   -H 'MCP-Protocol-Version: 2026-07-28' -H 'Mcp-Method: server/discover'
status_is 400 "MCP header mismatch"
body_has '"code":-32020' "MCP header mismatch"
req POST /mcp '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"x","version":"1"}}}' -H "$AUTH"
status_is 404 "MCP initialize (legacy)"
body_has '2026-07-28' "MCP initialize names the version"
# The tool call is a request of its own, in the MCP request's trace.
mcp tools/call ',"name":"list_trace","arguments":{}' list_trace -H "$AUTH" -H "traceparent: 00-$TRACE_ID-$PARENT_ID-01"
body_has '"isError":false' "MCP call: trace route"
body_has "\\\"requestId\\\":\\\"$TRACE_ID\\\"" "MCP call: the trace id reaches the tool's request"
body_lacks "$PARENT_ID" "MCP call: the tool's request is a child of the MCP request's span"
req POST /mcp '{"jsonrpc":"2.0","method":"notifications/initialized"}' -H "$AUTH"
status_is 202 "MCP notification"
body_is '' "MCP notification"
req GET /mcp "" -H "$AUTH"
status_is 405 "MCP GET"
req POST /mcp '{}' -H "$AUTH" -H 'Origin: https://evil.example'
status_is 403 "MCP from a browser origin"
# /mcp/unreachable calls an API that isn't there (port 1): the client gets a
# fixed text, never the transport's message (it named the host and port).
req POST /mcp/unreachable "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{$META,\"name\":\"list_trace\",\"arguments\":{}}}" \
  -H "$AUTH" -H 'MCP-Protocol-Version: 2026-07-28' -H 'Mcp-Method: tools/call' -H 'Mcp-Name: list_trace'
status_is 200 "MCP call, API unreachable"
body_has '"text":"Could not call the API."}],"isError":true' "MCP call, API unreachable: a fixed text"
body_lacks '127.0.0.1:1' "MCP call, API unreachable: no address"
UNREACH_ID="$(header X-Request-Id)"

# --- health (public)
req GET /health/live ""
status_is 200 "liveness"
body_is '{"status":"ok"}' "liveness"
req GET /health/ready ""
status_is 200 "readiness"
body_is '{"status":"ok","checks":{"maintenance":"ok"}}' "readiness"
req PUT /maintenance '{"on":true}'
status_is 401 "maintenance switch needs the token"
req PUT /maintenance '{"on":1}' -H "$AUTH"
status_is 400 "maintenance switch, not a boolean"
req PUT /maintenance '{"on":true}' -H "$AUTH"
status_is 204 "maintenance on"
req GET /health/ready ""
status_is 503 "readiness in maintenance (the check raises)"
body_is '{"status":"fail","checks":{"maintenance":"fail"}}' "readiness in maintenance"
req PUT /maintenance '{"on":false}' -H "$AUTH"
req GET /health/ready ""
status_is 200 "readiness after maintenance"

# --- metrics (public), scraped after everything above
req GET /cities/1/extra "" -H "$AUTH"
status_is 404 "a partial route match"
req FOO /health ""
req GET /metrics ""
status_is 200 "metrics"
header_is Content-Type 'text/plain; version=0.0.4; charset=utf-8' "metrics"
body_has '# TYPE http_server_request_duration_seconds histogram' "metrics: duration histogram"
body_has '# HELP http_server_request_duration_seconds Duration of HTTP server requests.' "metrics: duration help"
body_has '# TYPE http_server_active_requests gauge' "metrics: active requests"
body_has 'http_server_active_requests{http_request_method="GET"} 1' "metrics: the scrape itself is active"
body_has 'http_server_request_duration_seconds_count{http_request_method="GET",http_route="/cities/:id",http_response_status_code="404"}' "metrics: route template"
body_lacks 'http_route="/cities/999"' "metrics: never the raw path"
body_lacks 'http_route="/cities",http_response_status_code="404"' "metrics: a partial match is no route"
body_has 'http_server_request_duration_seconds_count{http_request_method="GET",http_route="/health/ready",http_response_status_code="503"} 1' "metrics: exact count"
body_has 'http_server_request_duration_seconds_count{http_request_method="GET",http_route="/fail/server",http_response_status_code="500"}' "metrics: status of an exception"
body_has 'http_request_method="_OTHER"' "metrics: unknown method"
# /no/such/route, /cities/1/extra and /swagger/missing, once each (Horse runs middlewares twice there).
body_has 'http_server_request_duration_seconds_count{http_request_method="GET",http_route="",http_response_status_code="404"} 3' "metrics: unknown routes counted once"
# METRICS_OUT: also save it, for promtool (tools/test_http_docker.sh).
[ -n "$METRICS_OUT" ] && cp "$T/body" "$METRICS_OUT"

# --- the logger's internal mark, sent by hand (last: it adds a request).
# Until 0.13.0 the mark was ':pascalapi-logged', and Indy (Delphi) kept a
# raw ':pascalapi-logged: 1' line, so the logger skipped the request: no
# access line, no span. curl won't send such a line; Python's socket does.
# Checked when the runner says where the server's output goes.
if [ -n "$SERVER_LOG" ]; then
  PY=python3
  $PY -c "" >/dev/null 2>&1 || PY=python
  $PY -c '
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])))
s.sendall(b"GET /health/live?probe=hidden HTTP/1.1\r\nHost: 127.0.0.1\r\n:pascalapi-logged: 1\r\nConnection: close\r\n\r\n")
while s.recv(65536):
  pass' "$PORT"
  sleep 1
  grep -q 'probe=hidden' "$SERVER_LOG" && ok || fail "log: a raw :pascalapi-logged line hid the request"
  # The 500's detail, findable by the id the client got.
  # The message has non-ASCII on purpose: the sample turns on SafeWriteln's
  # UTF-8 (pascal-common-faa 1.10.0), so the line is UTF-8 in the file on both
  # compilers (without it: code page 850 on FPC, 1252 on Delphi, measured).
  grep -q "something broke (ação) trace_id=$FAIL_ID" "$SERVER_LOG" && ok \
    || fail "log: the 500's message with trace_id=$FAIL_ID"
  grep -q "middleware broke at db.internal:3050 trace_id=$MW_ID" "$SERVER_LOG" && ok \
    || fail "log: the middleware's 500 with trace_id=$MW_ID"
  grep -q "GET /fail/middleware 500 .*$MW_ID" "$SERVER_LOG" && ok \
    || fail "log: the access line has the middleware error's status"
  # The client's address in the access line is what can be trusted
  # (TClientAddress): this script's peer is loopback, a proxy on the same
  # machine, so the header's last address is the client; the first one is
  # whatever the client wrote and must not reach the log.
  curl -s -o /dev/null -H 'X-Forwarded-For: 203.0.113.9, 10.0.0.1' "$BASE/health?probe=xff"
  sleep 1
  grep 'probe=xff' "$SERVER_LOG" | grep -q ' 10\.0\.0\.1 ' && ok \
    || fail "log: client address from the right of X-Forwarded-For ($(grep 'probe=xff' "$SERVER_LOG"))"
  grep 'probe=xff' "$SERVER_LOG" | grep -q '203\.0\.113\.9' && fail "log: the client-written address reached the access line" || ok
  grep -q "^ERROR MCP tool call GET /trace: .*trace_id=$UNREACH_ID" "$SERVER_LOG" && ok \
    || fail "log: a failed MCP tool call, with the MCP request's id"
  # A raw ':pascalapi-metered: 1' line (Indy keeps such lines) must not hide
  # a request from the metrics.
  M0=$(curl -s "$BASE/metrics" | grep '^http_server_request_duration_seconds_count{' | grep 'http_route="/health/live"' | awk '{ s += $NF } END { printf "%d", s }')
  $PY -c '
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])))
s.sendall(b"GET /health/live HTTP/1.1\r\nHost: 127.0.0.1\r\n:pascalapi-metered: 1\r\nConnection: close\r\n\r\n")
while s.recv(65536):
  pass' "$PORT"
  M1=$(curl -s "$BASE/metrics" | grep '^http_server_request_duration_seconds_count{' | grep 'http_route="/health/live"' | awk '{ s += $NF } END { printf "%d", s }')
  [ "$M1" = "$((M0 + 1))" ] && ok || fail "metrics: a raw :pascalapi-metered line hid the request ($M0 -> $M1)"
fi

rm -rf "$T"
echo "$CHECKS checks, $FAILS failed"
[ "$FAILS" -eq 0 ]
