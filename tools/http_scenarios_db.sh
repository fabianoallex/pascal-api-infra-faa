#!/bin/sh
# Checks samples/02-db over HTTP with curl: migrations, paging and ordering
# in SQL, the state filter, 404, validation, 409 from the database's unique
# key, NULL to JSON null, delete, OpenAPI, MCP tools with the DTOs'
# schemas, and the pool metrics pascal-db-faa (0.14.0) records.
#
#   sh tools/http_scenarios_db.sh [port]   (default 9330; DbApiSample must be
#                                          running, started with --reset)
#
# Same script for every build of the sample (FPC Windows/Linux, Delphi
# Win32/Win64). Exit code 0 only if every check passed.
PORT="${1:-9330}"
BASE="http://127.0.0.1:$PORT"
T="$(mktemp -d)"
FAILS=0
CHECKS=0

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
# Sum of a metric's samples in a Prometheus text file (every label set).
metric_sum() { awk -v n="$1" '$1 == n || index($1, n "{") == 1 { s += $NF } END { printf "%d", s }' "$2"; }

# Acquires so far (the sample's startup and migrations), to compare at the end.
curl -s -o "$T/metrics0" "$BASE/metrics"
WAIT_COUNT0=$(metric_sum db_client_connection_wait_time_seconds_count "$T/metrics0")

# --- paging and ordering in SQL (6 seed rows from migration 3)
req GET '/cities?limit=2' ""
status_is 200 "page 1"
body_has '"page":1,"limit":2,"total":6,"totalPages":3,"hasNext":true,"hasPrev":false' "page 1"
body_has '"items":[{"code":"1501402","name":"Belém","state":"PA","population":1303403},{"code":"3509502","name":"Campinas"' "page 1 by name (UTF-8)"
req GET '/cities?page=3&limit=2' ""
body_has '"hasNext":false,"hasPrev":true' "page 3"
body_has '"name":"São Paulo"' "page 3 by name"
req GET '/cities?limit=1&orderBy=-population' ""
body_has '"name":"São Paulo"' "most populous first"
req GET '/cities?limit=1&orderBy=population' ""
body_has '"name":"Florianópolis","state":"SC","population":null' "NULL population sorts first in SQLite, and is JSON null"
req GET '/cities?limit=500' ""
body_has '"limit":50' "limit clamped to the maximum"
# Only digits, within Integer: anything else is a 400 naming the parameter.
# Until 0.13.0 'abc' silently became the default, '$3' was read as 3, and on
# FPC page=99999999999 wrapped around to page 1215752191 (measured).
req GET '/cities?limit=abc' ""
status_is 400 "limit not a number"
body_is '{"error":"\"limit\" must be an integer."}' "limit not a number: names the parameter"
req GET '/cities?page=99999999999' ""
status_is 400 "page past Integer (wrapped around on FPC until 0.13.0)"
req GET '/cities?limit=%243' ""
status_is 400 "limit in hex"
req GET '/cities?orderBy=bad' ""
status_is 400 "order by a field not allowed"
body_has 'Invalid order field: \"bad\"' "order by a field not allowed"

# --- filter
req GET '/cities?state=sp&orderBy=-name' ""
body_has '"total":2' "state filter"
body_has '"items":[{"code":"3550308","name":"São Paulo"' "state filter, descending"
req GET '/cities?state=AM' ""
body_has '"total":0,"totalPages":1,"hasNext":false,"hasPrev":false,"items":[]' "no city in the state"

# --- one city, create, conflict, validation, delete
req GET /cities/4314902 ""
body_is '{"code":"4314902","name":"Porto Alegre","state":"RS","population":1332845}' "city by code"
req GET /cities/9999999 ""
status_is 404 "unknown code"
body_is '{"error":"City 9999999 not found."}' "unknown code"
req POST /cities '{"code":"2408102","name":"Natal","state":"rn"}'
status_is 201 "create without population"
body_is '{"code":"2408102","name":"Natal","state":"RN","population":null}' "create without population"
# Non-ASCII from a file with explicit UTF-8 bytes (Git Bash hands curl.exe its
# arguments in the ANSI code page).
printf '{"code":"2704302","name":"Macei\303\263","state":"AL","population":957916}' > "$T/utf8"
req POST /cities "@$T/utf8"
status_is 201 "create with population"
body_is '{"code":"2704302","name":"Maceió","state":"AL","population":957916}' "create with population"
req GET '/cities?state=al' ""
body_has '"name":"Maceió"' "read back from the database"
req POST /cities '{"code":"3550308","name":"Another","state":"SP"}'
status_is 409 "duplicate code (the database's primary key)"
body_is '{"error":"A record with these values already exists."}' "duplicate code"
req POST /cities '{"code":"12","name":"X","state":"SP"}'
status_is 400 "invalid code"
req POST /cities '{"code":"1234567","name":"","state":"SP"}'
status_is 400 "missing name"
body_is '{"error":"\"name\" is required."}' "missing name"
req POST /cities '{"code":"1234567","name":"X","state":"SP","population":"many"}'
status_is 400 "wrong type"
body_has '$.population' "wrong type"
# The limits the OpenAPI document declares are enforced by the handler: until
# they were, '+123456' and -5 were stored, and a 150-character name was 201 on
# FPC and 500 on Delphi (FireDAC refuses a value longer than the column).
req POST /cities '{"code":"+123456","name":"X","state":"SP"}'
status_is 400 "code: digits only (the document's pattern)"
req POST /cities "{\"code\":\"1000001\",\"name\":\"$(printf 'x%.0s' $(seq 1 101))\",\"state\":\"SP\"}"
status_is 400 "name: at most 100 characters (the document's maxLength)"
body_is '{"error":"\"name\" must have at most 100 characters."}' "name too long"
req POST /cities '{"code":"1000001","name":"X","state":"SP","population":-5}'
status_is 400 "population: not negative (the document's minimum)"
# 100 characters of two bytes each: counted as characters on both compilers.
printf '{"code":"1000001","name":"%s","state":"SP"}' "$(printf '\303\243%.0s' $(seq 1 100))" > "$T/long"
req POST /cities "@$T/long"
status_is 201 "name: 100 two-byte characters are 100 characters"
req DELETE /cities/1000001 ""
status_is 204 "delete the 100-character city"
# umError (the sample's setting): a member the DTO doesn't have is a 400 with
# its path, not dropped in silence (a typo kept population null until then).
req POST /cities '{"code":"1000001","name":"X","state":"SP","popultion":5}'
status_is 400 "unknown member"
body_has '$.popultion' "unknown member: its path"
# A JSON escape (the file holds backslash, u, 00e3) comes back as UTF-8.
printf '{"code":"1000002","name":"Jo\\u00e3o","state":"SP"}' > "$T/escape"
req POST /cities "@$T/escape"
body_is '{"code":"1000002","name":"João","state":"SP","population":null}' "escape stored as UTF-8"
req DELETE /cities/1000002 ""

# --- PATCH: absent leaves a member, null clears population, a value sets it
req PATCH /cities/2408102 '{"population":890480}'
status_is 200 "patch a value"
body_is '{"code":"2408102","name":"Natal","state":"RN","population":890480}' "patch a value: the others stay"
req PATCH /cities/2408102 '{}'
status_is 200 "empty patch"
body_is '{"code":"2408102","name":"Natal","state":"RN","population":890480}' "empty patch changes nothing"
req PATCH /cities/2408102 '{"population":null}'
body_is '{"code":"2408102","name":"Natal","state":"RN","population":null}' "patch null clears population"
req PATCH /cities/2408102 '{"name":"  Natal RN  ","state":" rn"}'
body_is '{"code":"2408102","name":"Natal RN","state":"RN","population":null}' "patch two members, normalized (TOptionals.Trim, Upper)"
req GET /cities/2408102 ""
body_is '{"code":"2408102","name":"Natal RN","state":"RN","population":null}' "patch read back"
req PATCH /cities/2408102 '{"name":null}'
status_is 400 "patch null into a NOT NULL member"
body_has '$.name: null is not allowed here' "patch null name: the path"
req PATCH /cities/2408102 '{"population":-1}'
status_is 400 "patch: the same limits as create"
req PATCH /cities/2408102 '{"popultion":1}'
status_is 400 "patch: unknown member"
req PATCH /cities/9999999 '{"population":1}'
status_is 404 "patch an unknown city"
req PATCH /cities/9999999 '{}'
status_is 404 "empty patch of an unknown city"
req DELETE /cities/2408102 ""
status_is 204 "delete"
req DELETE /cities/2408102 ""
status_is 404 "delete again"
req GET '/cities?limit=1' ""
body_has '"total":7' "6 seeds + Maceió"

# --- OpenAPI document and Swagger UI (public)
req GET /swagger/doc.json ""
status_is 200 "OpenAPI document"
body_has '"openapi":"3.0.3"' "OpenAPI document"
body_has '"CityInsert":{"type":"object","description":"A new city"' "DTO schema with its description"
body_has '"population":{"type":"integer","format":"int32","nullable":true' "INullInteger is nullable"
body_has '"required":["code","name","state"]' "IOptInteger is not required"
body_has '"CityPatch":{"type":"object","description":"The members to change; the others stay"' "PATCH DTO schema"
body_has '"patch":{' "PATCH route documented"
body_has 'Florianópolis' "UTF-8 example"
body_lacks 'securitySchemes' "no authentication middleware, no security scheme"
body_has '"$ref":"#/components/schemas/Error"' "error responses"
body_has '{"name":"state","in":"query","description":"Only the cities of this state (two letters)","required":false,"schema":{"type":"string"}}' "query parameter from the Find DTO"
body_has '{"name":"page","in":"query","description":"Page number, from 1","required":false,"schema":{"type":"integer"}}' "inherited query parameter"

req GET /swagger ""
status_is 200 "Swagger UI"
body_has 'swagger-ui-dist@' "Swagger UI"
# OPENAPI_OUT: also save the document, for a validator (tools/test_http_docker.sh).
[ -n "$OPENAPI_OUT" ] && curl -s -o "$OPENAPI_OUT" "$BASE/swagger/doc.json"

# --- MCP (2026-07-28) on /mcp: the tools carry the DTOs' schemas, and a
# GET tool's arguments reach the route as a query string.
META='"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}'
# mcp METHOD PARAMS [TOOL] [extra curl args...]
mcp() {
  MM="$1"; MP="$2"; MN="$3"; if [ $# -ge 3 ]; then shift 3; else shift $#; fi # dash: shift past $# is fatal
  req POST /mcp "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$MM\",\"params\":{$META$MP}}" \
    -H 'MCP-Protocol-Version: 2026-07-28' -H "Mcp-Method: $MM" ${MN:+-H "Mcp-Name: $MN"} "$@"
}
call() { mcp tools/call ",\"name\":\"$1\",\"arguments\":$2" "$1"; }

mcp tools/list ""
status_is 200 "MCP tools/list"
body_has '"state":{"type":"string","description":"Only the cities of this state (two letters)"}' "MCP: query argument from the Find DTO"
body_has '"code":{"type":"string","description":"IBGE code","examples":["4205407"],"pattern":"^[0-9]{7}$"}' "MCP: body argument with its metadata"
body_has '"required":["code","name","state"],"additionalProperties":false' "MCP: body's required members"
body_has 'Returns a page (page, limit, total, totalPages, hasNext, hasPrev, items) whose items have: code (string, IBGE code)' "MCP: description with the returned fields"
call list_citie '{"state":"SP","limit":50}'
status_is 200 "MCP call with a filter"
body_has '\"total\":2,' "MCP call: the state filter reached the route"
body_lacks 'Florian' "MCP call: the state filter reached the route"
call create_citie '{"code":"123","name":"X","state":"SC"}'
body_has '"isError":true' "MCP call, invalid data"
call get_citie '{"code":"3550308"}'
body_has '\"code\":\"3550308\"' "MCP call with a path argument"
body_has '"isError":false' "MCP call with a path argument"
mcp server/discover "" "" -H 'Origin: http://localhost:6274'
status_is 200 "MCP from the allowed origin"
mcp server/discover "" "" -H 'Origin: http://localhost:9999'
status_is 403 "MCP from another origin"

# --- health and metrics
req GET /health/ready ""
status_is 200 "readiness"
body_is '{"status":"ok","checks":{"database":"ok"}}' "readiness: the database answers"
req GET /metrics ""
status_is 200 "metrics"
grep -qF 'http_route="/cities/:code"' "$T/body" && ok || fail "metrics: route template"
grep -qF 'http_route="/cities/3550308"' "$T/body" && fail "metrics: raw path" || ok
# Pool metrics (pascal-db-faa): the pool isn't named, so it is the db.system.name.
grep '^db_client_connection_count{' "$T/body" | grep 'state="idle"' | grep -qF 'pool_name="sqlite"'   && ok || fail "metrics: pool connections, state idle, pool sqlite"
grep '^db_client_connection_count{' "$T/body" | grep -qF 'state="used"'   && ok || fail "metrics: pool connections, state used"
grep '^db_client_connection_max{' "$T/body" | grep -q ' 5$'   && ok || fail "metrics: db_client_connection_max is the sample's PoolMaxConnections (5)"
WAIT_COUNT=$(metric_sum db_client_connection_wait_time_seconds_count "$T/body")
[ "$WAIT_COUNT" -gt "$WAIT_COUNT0" ] && ok   || fail "metrics: wait_time count grew with the requests ($WAIT_COUNT0 -> $WAIT_COUNT)"
[ -n "$METRICS_OUT" ] && cp "$T/body" "$METRICS_OUT"

rm -rf "$T"
echo "$CHECKS checks, $FAILS failed"
[ "$FAILS" -eq 0 ]
