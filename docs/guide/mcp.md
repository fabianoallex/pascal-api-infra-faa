# MCP

How to offer the API's routes as tools to an AI client over the Model Context Protocol: the
client lists the tools, and calls them as the model decides. The code comes from samples 01
and 02. `PascalApi.McpTests` checks the catalog and the protocol with a fake executor.
`tools/http_scenarios.sh` and `tools/http_scenarios_db.sh` drive both samples' `/mcp` with curl,
and CI drives them with the official MCP Python SDK (`mcp` 2.0.0, `tools/mcp_client_check.py`).
One behaviour below was measured with a probe program on FPC 3.2.2/Windows for this guide
(2026-10-14), and it says so. The decisions behind the design are in
[docs/mcp-design.md](../mcp-design.md).

## What it solves

An AI assistant that can call your API needs a description of each operation it may use, in a
form its client understands, and an endpoint to send the calls to. Writing that by hand means a
second description of the API to keep in step with the first.

`TMcpEndpoint` builds the tools from the routes you already documented for
[OpenAPI](openapi.md): one tool per operation, with its input schema taken from the same DTOs.
A tool call is sent back to the API itself over HTTP, so it goes through every middleware
(authentication, rate limit, logging, errors) exactly as a direct call does.

## The smallest working program

```pascal
uses
  Horse, PascalApi.Horse.OpenApi, PascalApi.Horse.Mcp;

TRouteDoc.Get('/cities').Summary('List cities').Register(GetCities);
// ...every route first...
TMcpEndpoint.Register('/mcp', 'http://127.0.0.1:9000', 'cities-api', '1.0.0');
THorse.Listen(9000);
```

`Register` adds `POST /mcp` (the protocol's messages) and `GET`/`DELETE /mcp` (405). The second
argument is where the API listens, for the tool calls.

## Step by step

### 1. Document the routes, then register the endpoint

The tools are the operations in `TRouteDoc.Document` **when `Register` runs**, so it goes after
every route (from the code: the catalog is built once, in `Register`). From
`samples/02-db/DbApiSample.dpr`:

```pascal
TRouteDoc.Get('/cities')
  .Summary('List cities, a page at a time').Tag('cities')
  .QueryParams<ICityFind>
  .ResponsePaged<ICity>(200, 'A page of cities')
  .Error(400, 'An order field that is not allowed')
  .Register(GetCities);
...
TRouteDoc.Serve('/swagger', 'Cities API (pascal-api-infra-faa sample 02)', '1.0.0');
TMcpEndpoint.Register('/mcp', 'http://127.0.0.1:' + IntToStr(GPort), 'cities-api', '1.0.0',
  [], ['http://localhost:6274']);
```

The last two arguments are the tag filter (step 4) and the browser origins allowed (step 7).

### 2. What a tool looks like

Each operation becomes a tool:

- **The name** is the `OperationId`, or one derived from the method and the path: `GET /cities` is
  `list_citie`, `GET /cities/{id}` is `get_citie`, `POST /cities` is `create_citie`,
  `PUT`/`PATCH` are `update_...`, `DELETE` is `delete_...`. The rule is the origin's, ported with
  its tests (`DeriveName_OriginCases`). It drops a final `s`, so English plurals come out odd.
  Give a route an `OperationId` when the name matters (step 3).
- **The input schema** is one object: the path parameters (required), the query parameters, and
  the body DTO's members, with the same types and metadata as the OpenAPI schemas, nested DTOs
  inline, and `"additionalProperties": false`. From sample 02's `tools/list` (checked):

  ```json
  "code":{"type":"string","description":"IBGE code","examples":["4205407"],"pattern":"^[0-9]{7}$"}
  "required":["code","name","state"],"additionalProperties":false
  ```

- **The description** is the summary, the description, and the fields it returns (checked:
  `Returns a page (page, limit, total, totalPages, hasNext, hasPrev, items) whose items have:
  code (string, IBGE code)...`).

A name used twice in one endpoint (two tools, or a path parameter and a body member with the
same name) raises `EMcpError` in `Register` (tested), so the program stops at startup.

### 3. Leave routes out, or name them: `NoMcp`, `OperationId`

```pascal
TRouteDoc.Get('/fail/server').Summary('Always 500').Tag('errors').NoMcp
  .Error(500).Register(FailServer);
```

`NoMcp` keeps an operation documented in OpenAPI but out of the tools (checked: sample 01's
`tools/list` has no `fail`, and none of its refresh and logout routes: a refresh token has no
place in a model's context, [Refresh tokens](refresh-tokens.md)). Leave out what a model should never call. `OperationId('find_cities')`
names the tool, and the operation in the OpenAPI document too.

### 4. One endpoint per group of tools: tags

```pascal
TMcpEndpoint.Register('/mcp/cities', 'http://127.0.0.1:9000', 'cities', '1.0.0', ['cities']);
```

With tags, the endpoint offers only the operations with one of them (tested:
`Catalog_NamesNoMcpAndTags`). Several endpoints can serve different subsets of the same API: one
for reading, one with the writing tools for a trusted client.

### 5. A tool call goes back through the API

The client sends `tools/call` with the arguments; the endpoint builds the request and sends it to
the base URL:

| Argument | Goes into |
|---|---|
| a path parameter | the URL (`/cities/3550308`) |
| a query parameter | the query string (`?state=SC&limit=50`) |
| a header parameter the route opts in (`McpHeader`, step 6) | that header (`If-Match: "3"`) |
| a body member | a JSON body |

The origin put every non-path argument into a body, also for `GET`, so a filter never reached the
API; here it does (checked: "MCP call: the state filter reached the route"). The call carries the
caller's `Authorization` header, its address (as `X-Forwarded-For`, as a proxy sends it) and the
trace context (`traceparent`).

So a tool call is authorized like a direct call with the same token (checked: `list_me` answers
the caller's `sub`), it counts against the caller's rate limit (unit-tested; not checked over
HTTP), and it appears in the logs as a request of its own, in the MCP request's trace (checked:
the trace id reaches the tool's request).

What the client gets back:

| What happened | MCP result |
|---|---|
| the API answered below 400 | `isError: false`, the API's body as text |
| the API answered 400 or more | `isError: true`, the API's error body as text, which the model can act on (checked: `City 999 not found.`) |
| a required argument is missing, or an argument is unknown | `isError: true`, `Missing required argument: id` / `Unknown argument: town`, without calling the API (checked) |
| a header argument that isn't a string of printable ASCII | `isError: true`, `Argument ifMatch: a header value must be printable ASCII (no accents, no control characters)`, without calling the API (checked: a CR LF over HTTP, an accent with the Python SDK) |
| the API couldn't be reached (down, wrong base URL, timeout) | `isError: true`, `Could not call the API.` |

**Until 0.13.0 the last row sent the transport's message**: measured with the probe,
`Could not call the API: Connection to 127.0.0.1:1 timed out.` and `Host name resolution for
"no-such-host.invalid" failed.`, which name the API's host and port, and nothing was logged. The
message now goes to the error handler's log only (the callback given to
`TErrorHandlerMiddleware.Register`; sample 01's writes `ERROR ` before each line). On FPC:

```
ERROR MCP tool call GET /trace: ESocketError: Connection to 127.0.0.1:1 timed out. trace_id=...
```

and on Delphi (the class and the message are each compiler's HTTP client's; the message is in
the language of Windows, here Portuguese):

```
ERROR MCP tool call GET /trace: ENetHTTPClientException: Error sending data: (12029) Uma conexão com o servidor não pôde ser estabelecida trace_id=...
```

without the query string, which carries the model's arguments. Sample 01's `/mcp/unreachable`
points at port 1 so that `tools/http_scenarios.sh` can check the fixed text and the log line.

The base URL should be a loopback address (`http://127.0.0.1:<port>`): the call then arrives from
a peer the library trusts as a proxy, so the rate limit and the access log see the caller's
address, not the API's own ([Rate limiting](rate-limiting.md), step 3). A call waits up to 30 s
(`MCP_HTTP_TIMEOUT_MS`; `Register` has no setting for it).

### 6. Headers a tool sends: `McpHeader` (0.25.0)

A route that requires `If-Match` answers 428 without it, so a tool for it needs the header. A
header parameter becomes an argument only when the route says so. From
`samples/02-db/DbApiSample.dpr`:

```pascal
TRouteDoc.Put('/cities/:code')
  .Summary('Replace a city''s members, from the version read').Tag('cities')
  .OperationId('replace_city')
  .PathParam('code', 'IBGE code (7 digits)')
  .HeaderParam('If-Match', 'The version read, in quotes: "3" for version 3', True)
  .McpHeader('If-Match')
  .Body<ICityReplace>
  ...
  .Register(PutCity);
TRouteDoc.Post('/cities')
  .HeaderParam('Idempotency-Key', 'Optional, 1 to 255 visible ASCII characters (a UUID): ...')
  .McpHeader('Idempotency-Key') // the tool's "idempotencyKey"
  ...
```

`tools/list` then has (checked):

```json
"ifMatch":{"type":"string","description":"The version read, in quotes: \"3\" for version 3 (sent as the If-Match header)"}
"required":["code","ifMatch","name", ...
```

- **The name** is the header's words, the first in lower case: `If-Match` is `ifMatch`,
  `Idempotency-Key` is `idempotencyKey` (`McpHeaderArgName`, tested). `McpHeader('If-Match',
  'version')` names it yourself.
- **Required** when the header is (`HeaderParam`'s third argument); a missing one is an
  `isError` without a call, as for the others.
- **The description** is `HeaderParam`'s, plus the header it becomes. Write there what to
  pass: the model reads nothing else.
- **`Register` raises `EMcpError`** (tested) for a header the route doesn't declare with
  `HeaderParam`, for a name another argument has, and for a header the transport or the server
  sets: `Authorization`, `X-Forwarded-*`, `Forwarded`, `X-Real-IP`, `traceparent`,
  `tracestate`, `Host`, `Content-Type`, `Content-Length`, `Accept`, `Expect`, `Cookie`,
  `MCP-Protocol-Version`, `Mcp-*`, `Proxy-*` and the hop-by-hop headers
  (`McpHeaderReserved`). A model's argument can never set who the caller is.
- **A value** must be a string of printable ASCII (`#32` to `#126`): a line break, which would
  start another header, or an accent is an `isError` without a call (checked). An empty value
  is no value.

**The model sees only the response's body**, never its headers. An `ETag` header alone is
invisible to it: sample 02's city carries its `version` in the body too (0.25.0), and the
scenarios read it from `get_citie`, call `replace_city` with that version in quotes
(`"ifMatch": "\"6\""`), and get the API's 412 as an `isError` result when they use it twice
(checked). With `idempotencyKey`, a model that repeats `create_citie` gets the first answer
again instead of a 409 (checked).

### 7. Who may call the endpoint

- **Authentication.** `/mcp` is a route like any other: behind `TJwtMiddleware` unless you exclude
  it. Sample 01 keeps it protected (checked: 401 without a token), and the token reaches each tool
  call. Sample 02 has no authentication at all.
- **Browser origins.** A request with an `Origin` header not in the allow-list gets 403, as the
  protocol requires against DNS rebinding (checked: 403 from `https://evil.example`, 200 from
  sample 02's `http://localhost:6274`). The default, an empty list, refuses every browser origin
  and accepts clients that send none (SDKs, command-line agents). `http://localhost:6274` is the
  MCP Inspector's address; list only the origins you use.

### 8. The protocol revision

The endpoint speaks revision **2026-07-28 only**, without sessions (decided with the user; see the
design document):

- every request carries its version in `params._meta` and in the `MCP-Protocol-Version` header,
  and `Mcp-Method` (and `Mcp-Name` for a call) must match the body: else 400 (checked);
- `server/discover`, `tools/list` and `tools/call` are the methods. The first two answer
  `"ttlMs": 0, "cacheScope": "private"`, since the endpoint is usually behind authentication;
- `initialize`, the handshake of the older revisions, is an unknown method: 404, naming the
  supported version (checked). **A client that speaks only an older revision can't use it.**

The official Python SDK 2.0.0 connects, lists and calls the tools of both samples in CI. No other
client was tried.

## Choices

### Which routes to offer

Everything documented is offered unless marked `NoMcp`. A model calls tools on its own judgment,
so treat each tool as something it will call: reading routes are the safe start; a writing or
deleting route is a tool that changes data when the model decides to. The caller's token still
limits what any call may do, since each call goes through your authentication.

### One endpoint or several

One endpoint with every tool is simplest. Separate endpoints by tag (step 4) give a client only
what it needs; a smaller list of tools is also easier for a model to choose from.

### The executor goes through HTTP

The alternative, calling the handlers inside the process, would skip the middlewares. The price
is one more HTTP request per call. The provider must serve requests concurrently, because the MCP
request stays open while its call is served (Horse's providers are threaded; from the unit's
comment).

## Pitfalls

- **Registering the endpoint before a route**: that route isn't a tool (step 1).
- **A wrong base URL**: every call answers `Could not call the API.`; the reason is in the error
  log (step 5). Without `TErrorHandlerMiddleware.Register(...)` with a callback, it is nowhere.
- **Two routes with the same derived name** (`/cities` and `/v2/cities`): `Register` raises. Give
  one an `OperationId`.
- **Excluding `/mcp` from authentication** "to make the client work": anyone can then list the
  tools, and a call without a token reaches every route that doesn't check one itself (the
  protected ones answer it 401, as `isError`).
- **An `Origin` you didn't list**: a browser-based client gets 403.
- **A client on an older revision**: 404 on `initialize` (step 8).
- **A version only in the `ETag` header**: a tool's result is the body, so the model can't
  fill `ifMatch` (step 6). Put the version in the body.
- **`McpHeader` on a header the route doesn't declare**, or on `Authorization`: `Register`
  raises (step 6).
- **The provider**: one that serves a request at a time would wait for itself (from the unit's
  comment; Horse's providers are threaded).

## Testing your application

**The catalog and the protocol, without a server.** `TMcpServer` takes a `TApiDocument` and an
`IMcpToolExecutor`. A fake executor records what it was asked and answers what you set, as
`PascalApi.McpTests` does: check the tool names, the input schemas, and the request each call
would make (method, path with its query string, body, forwarded headers and the header
arguments in `TMcpForward.Headers`), without HTTP.

**Over HTTP.** Send the protocol's messages with curl, as `tools/http_scenarios.sh` does:

```sh
META='"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}'
curl -s -X POST http://127.0.0.1:9310/mcp -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -H 'MCP-Protocol-Version: 2026-07-28' -H 'Mcp-Method: tools/list' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{$META}}"
```

Then call a tool with a filter and check that the filter reached the route, call one the route
refuses and check `isError`, and call without a token.

**With a real client.** `tools/mcp_client_check.py` connects with the official Python SDK, lists
the tools and calls some, as an AI client would (`pip install mcp==2.0.0`):

```sh
python3 tools/mcp_client_check.py 02 http://127.0.0.1:9330
```

## Reference

- `PascalApi.Mcp`: the catalog, the names, the input schemas, the dispatcher (comment at the
  top); `MCP_PROTOCOL_VERSION`, `MCP_CALL_FAILED`, `McpHeaderArgName`, `McpHeaderReserved`.
- `PascalApi.Horse.OpenApi`: `TRouteDocBuilder.McpHeader`.
- `PascalApi.Horse.Mcp`: `TMcpEndpoint`, `TMcpHttpExecutor`, `MCP_HTTP_TIMEOUT_MS`.
- `PascalApi.McpTests`.
- `samples/01-api` (`/mcp` behind JWT, `/mcp/unreachable`), `samples/02-db` (`/mcp` without
  authentication, an allowed origin, `If-Match` and `Idempotency-Key` as arguments); `tools/http_scenarios.sh`, `tools/http_scenarios_db.sh`,
  `tools/mcp_client_check.py`.
- [docs/mcp-design.md](../mcp-design.md): the protocol as measured, and the four decisions.
