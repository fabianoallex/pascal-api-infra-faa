#!/bin/sh
# Checks samples/02-db over HTTP with curl: migrations, paging and ordering
# in SQL, the state filter, 404, validation, 409 from the database's unique
# key, NULL to JSON null, delete, OpenAPI, and MCP tools with the DTOs'
# schemas.
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
body_has 'Florianópolis' "UTF-8 example"
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

rm -rf "$T"
echo "$CHECKS checks, $FAILS failed"
[ "$FAILS" -eq 0 ]
