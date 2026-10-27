# Phase 5 design: MCP server on both compilers

Status: **approved and implemented (2026-10-09, 0.5.0)**: modern protocol only (decision 1
changed by the user); decisions 2, 3 and 4 as recommended.

Found while implementing, with the official Python SDK (`mcp` 2.0.0) as the client:
`server/discover` and `tools/list` results must carry `ttlMs` and `cacheScope` (2026-07-28's
cacheable results). The server sends `0` and `"private"`: the endpoint usually sits behind the
API's authentication, so nothing may go to a shared cache.

## Goal

What delphi-api-infra-faa's `MCP.Server` gives a Delphi API, on Delphi and FPC 3.2.2: the routes
documented with `TRouteDoc` (phase 4) become MCP tools, served on an HTTP endpoint of the same
API, so an AI client can list and call them.

## What the origin does (read in `MCP.Server.pas`)

- JSON-RPC 2.0 on `POST /mcp`; answers `initialize` with protocol version `2024-11-05`,
  `tools/list` and `tools/call`; notifications get 202.
- One tool per documented operation (except `.NoMcp`), named by `operationId` or derived from
  method + path (`MCP.Utils.McpDeriveName`: `GET /cities` -> `list_citie`... it drops a final
  `s`); optional tag filter; several endpoints with different subsets.
- The input schema flattens path parameters, query parameters and the body DTO's properties into
  one object; the description is summary + description + "Returns: field (type, description)".
- A call is executed as an HTTP request back to the API itself (`THTTPClient`, Delphi only),
  so it goes through the middlewares.
- **Defect:** every argument that is not a path parameter goes into a JSON body, also for GET;
  `THTTPClient.Get` sends no body, so query parameters of GET tools (filters, page, orderBy)
  never reach the API. The incoming `Authorization` header is not forwarded either, so a
  JWT-protected API can't be called through it.

## What the protocol is now (measured on modelcontextprotocol.io, 2026-10-08)

The current revision is **2026-07-28**. It is a different model from the origin's:

- **No handshake, no session.** Every request carries its version in
  `params._meta["io.modelcontextprotocol/protocolVersion"]` (plus `clientInfo`,
  `clientCapabilities`); on HTTP also in headers `MCP-Protocol-Version`, `Mcp-Method` and, for
  `tools/call`, `Mcp-Name`, which the server **must** check against the body (400 + `-32020`
  `HeaderMismatch`).
- **`server/discover` is mandatory**: supported versions, capabilities, server info.
- Unsupported version: 400 + `-32022` with `data.supported`. Unknown method: 404 + `-32601`.
- `tools/list` / `tools/call` results carry `"resultType": "complete"`; tool errors are results
  with `isError: true`; unknown tool is a protocol error (`-32602`).
- GET/DELETE on the endpoint: 405. `Mcp-Session-Id`: ignored.
- Security: the server **must** validate the `Origin` header (403 when present and not allowed).
- **Legacy** revisions (`2025-11-25` and earlier) use the `initialize` handshake. A
  **dual-era** server may serve both on one endpoint: a request with modern `_meta` is served
  statelessly; an `initialize` selects legacy semantics.

## Proposed design

- `PascalApi.Mcp` (pure, no Horse): the tool catalog built from `TRouteDoc.Document`
  (`TApiDocument`, phase 4) and the JSON-RPC dispatcher. Tool execution goes through an
  interface, `IMcpToolExecutor`, so the dispatcher is tested with a fake.
- `src/horse/PascalApi.Horse.Mcp`: registers the endpoint and the real executor (HTTP to the
  API itself: `fphttpclient` on FPC, `THTTPClient` on Delphi, as pascal-dfe-broker's
  `DFe.Transmissor.Http.Cliente`).

```pascal
TRouteDoc.Get('/cities').QueryParams<ICityFind>.ResponsePaged<ICity>(200).Register(GetCities);
...
TRouteDoc.Serve('/swagger', 'Cities API', '1.0.0');
TMcpEndpoint.Register('/mcp', 'http://127.0.0.1:9330', 'cities-api', '1.0.0');   // all tools
TMcpEndpoint.Register('/mcp/cities', 'http://127.0.0.1:9330', 'cities', '1.0.0', ['cities']); // by tag
```

- Tool name: `operationId`, else derived from method + path (ported `McpDeriveName`, same
  results as the origin's tests). Names checked unique per endpoint at registration.
- Input schema: inline JSON Schema (a tool's schema can't point at `components`): path
  parameters (required), query parameters (from `QueryParam`/`QueryParams<I>`), body DTO
  properties with the same inference and metadata as the OpenAPI schemas (nested DTOs inline);
  `additionalProperties: false`. A name used twice (e.g. a path parameter and a body property)
  raises at registration.
- Description: summary, description and the returned fields, as the origin.
- Call: path arguments into the URL, query arguments into the **query string**, the rest into a
  JSON body; the HTTP status `>= 400` gives `isError: true` with the error body as text.

## Decisions for the user

1. **Protocol: `2026-07-28` only** (decided by the user). `initialize` and every legacy
   request get the modern errors (404 `-32601` naming the supported version for `initialize`;
   400 for missing headers/`_meta`), as the specification says a modern-only server should.
   Legacy-only clients can't use it.
2. **Execution through HTTP to the API itself**, so every middleware applies (JWT, rate limit,
   logging, error handler) exactly as for a direct call; the incoming `Authorization` header and
   the client's address (as `X-Forwarded-For`) are passed on, so authentication and per-client
   rate limits keep working (since the fix after 0.13.0, the address goes as a proxy sends it,
   the incoming `X-Forwarded-For` plus the peer, and the call arrives from a loopback address
   that the rate limit treats as a proxy: `TrustedClientIp`). Recommended. The alternative, calling handlers in-process, would
   skip the middlewares or need Horse internals.
3. **Fix the origin's argument mapping**: query parameters into the query string, so GET tools
   with filters work. Recommended (the origin's behavior is a defect, not a contract).
4. **Results as text** (the API's JSON body in a text item) plus `isError`, as the origin.
   `structuredContent`/`outputSchema` (the DTO schema of the response) can come after.
   Recommended: text now.

Also, not a choice but worth stating: the endpoint answers 403 to a request whose `Origin`
header is present and not in an allow-list given at registration (empty list: any `Origin`
refused, no `Origin` accepted), as the protocol requires; and the MCP endpoint sits behind the
same JWT middleware as the API unless the application excludes it.

## How it will be tested

- Unit (both compilers): catalog (names, schemas, descriptions, NoMcp, tags), dispatcher with a
  fake executor (`server/discover`, `initialize` refused, `tools/list` exact text,
  `tools/call` building URL/query/body, errors and HTTP status codes, header validation).
- HTTP: both samples expose `/mcp`; a new scenario script drives it with curl, including a JWT-protected call and a filtered GET (the origin's defect).
- An official MCP client in CI: the Python SDK v2 (its release notes state support for
  `2026-07-28`), in the Linux container, listing and calling the tools.
- Delphi Win32/Win64 as always.

## Header arguments (0.25.0)

Asked by pascal-agenda-faa (its `docs/design.md`, "M5: design", decision 1, 2026-10-27): moving
and cancelling an appointment require `If-Match` (428 without), and booking takes an
`Idempotency-Key`, but the tools left header parameters out and the executor sent only
`Authorization`, `X-Forwarded-For` and the trace context. Decisions taken with the user
(2026-10-27):

1. **Opt-in per parameter, `McpHeader(AHeader)` after `HeaderParam`** (not a fourth parameter of
   `HeaderParam`): `HeaderParam`'s signature doesn't change, and a header documented for
   OpenAPI stays out of the tools unless named. Stored in `TApiOperation.McpHeaders` and
   resolved when the catalog is built, so the checks are in `PascalApi.Mcp` and tested with the
   fake executor.
2. **The argument's name is derived**: the header's hyphen-separated words, the first in lower
   case (`If-Match` -> `ifMatch`, `Idempotency-Key` -> `idempotencyKey`); `McpHeader(AHeader,
   AArgument)` names it. A name another argument has raises `EMcpError`, as before.
3. **Reserved headers raise `EMcpError` at `Register`** (a programming error): the ones the
   executor or the HTTP client set (`Authorization`, `X-Forwarded-For`, `traceparent`,
   `tracestate`, `Host`, `Content-Type`, `Content-Length`, `Accept`, `Expect`), MCP's own
   (`MCP-Protocol-Version`, `Mcp-*`), the ones that say who the caller is (`Cookie`,
   `Forwarded`, `X-Forwarded-*`, `X-Real-IP`, `Proxy-*`) and the hop-by-hop ones. The executor
   skips a reserved name again before sending, in case a `TMcpForward` is built by hand.
4. **A value is a string of printable ASCII (`#32`..`#126`)**, else an `isError` result
   without a call: no accent (the same refusal on FPC's UTF-8 and Delphi's UTF-16 strings,
   and ETags and keys are ASCII), no CR or LF (they would start another header). An empty value
   is no value; required follows `HeaderParam`'s `ARequired`.
5. **The version goes in the body**: a tool's result is the response's body only, so an `ETag`
   header is invisible to the model. Sample 02's `ICity` gained `version` (the agenda's
   responses had it already). Not taken: returning response headers in the tool's result (more
   library surface for a case the body solves).

The values reach the executor in `TMcpForward.Headers`, which leaves `IMcpToolExecutor`'s
signature unchanged.

## Not in this phase

stdio transport, SSE responses, resources, prompts, `subscriptions/listen`, MRTR,
`structuredContent`/`outputSchema` (decision 4), OAuth authorization (the API's own JWT is used).
