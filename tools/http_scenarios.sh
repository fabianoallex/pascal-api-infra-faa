#!/bin/sh
# Checks samples/01-api over HTTP with curl: every middleware of
# PascalApi.Horse.Middlewares (error handler, CORS, logger's request id,
# JWT, rate limit) plus paging, ordering, DTO validation, OpenAPI and the
# MCP endpoint (2026-07-28).
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
req POST /mcp '{"jsonrpc":"2.0","method":"notifications/initialized"}' -H "$AUTH"
status_is 202 "MCP notification"
body_is '' "MCP notification"
req GET /mcp "" -H "$AUTH"
status_is 405 "MCP GET"
req POST /mcp '{}' -H "$AUTH" -H 'Origin: https://evil.example'
status_is 403 "MCP from a browser origin"

rm -rf "$T"
echo "$CHECKS checks, $FAILS failed"
[ "$FAILS" -eq 0 ]
