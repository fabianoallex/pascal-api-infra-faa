# Phase 6 design: observability (trace context, metrics, OpenTelemetry)

Status: **approved (2026-10-09)**. Decisions 1, 2 and 3 taken with the user; 4, 5 and 6 as
recommended (user, 2026-10-09). Nothing is implemented yet; the first step is in "Next step"
at the end.

## Goal

Give an API built on this library what is expected of a service today, on Delphi and FPC 3.2.2:

- a **trace id** that crosses process boundaries (W3C Trace Context) and ties the access log,
  the application's own logs and the error log together;
- **metrics** in the Prometheus format, scraped from the API itself;
- **spans** exported with OTLP to an OpenTelemetry collector, so a request shows up as one trace
  across this API, the MCP loopback and, later, the database, Redis and AMQP calls;
- **health** endpoints for an orchestrator (liveness, readiness).

## What exists today (read on 2026-10-09)

- `TLoggerMiddleware` makes an `X-Request-Id` (`NewRequestId`: 8 hex digits, the first 8 of an
  MD5 of a GUID), puts it on the request (for the handler) and the response, and writes one text
  line (`AccessLogLine`). An incoming `X-Request-Id` is ignored and overwritten.
- `TErrorHandlerMiddleware` gives the line of the errors worth monitoring (500, 503, 422, lock
  conflicts) to a `TLogProc`.
- `FileLog`: asynchronous, one file per category, an event id (8 hex) per call, shared by the
  categories of that call.
- The MCP executor (`PascalApi.Horse.Mcp`) forwards `Authorization` and `X-Forwarded-For` on the
  loopback, but no trace context: a tool call and the API call it makes are unrelated in the logs.
- No metrics, no spans, no structured log, no health endpoint. pascal-db-faa, pascal-redis-faa
  and pascal-amqp-faa have no instrumentation hook.

## What "modern" means here

- **OpenTelemetry** is the vendor-neutral standard: traces, metrics and logs joined by
  `trace_id`, exported with **OTLP** to a collector, which forwards to whatever backend (Jaeger,
  Tempo, Grafana, Datadog...). The application doesn't know the backend.
- **W3C Trace Context** (`traceparent`, `tracestate`) is the propagation format between
  processes: `00-<32 hex trace id>-<16 hex span id>-<2 hex flags>`.
- OTLP has an **HTTP/JSON** encoding (`POST :4318/v1/traces`, `/v1/metrics`, `/v1/logs`), so no
  protobuf is needed: pascal-jsonmapper-faa's DOM writes the payload, and the HTTP client the MCP
  executor already uses (`fphttpclient` / `THTTPClient`) sends it. The collector is usually local
  or a sidecar on plain HTTP, which avoids OpenSSL on FPC.
- **Prometheus** scrape (`GET /metrics`, text exposition format) remains the cheapest way to get
  metrics, with no collector at all.
- Names follow the OpenTelemetry **semantic conventions**: `http.server.request.duration`
  (seconds, histogram) with `http.request.method`, `http.route`, `http.response.status_code`;
  in Prometheus, `http_server_request_duration_seconds`.

## Decisions

### 1. The contracts live in pascal-common-faa (user, 2026-10-09)

The trace context and the instrumentation contracts must be usable by pascal-db-faa,
pascal-redis-faa and pascal-amqp-faa (phase D) without depending on this library, which is an
HTTP API layer. pascal-common-faa is already a dependency of all of them.

**A separate library (`pascal-otel-faa`) was considered and is not worth it now:** the contracts
are small, need only `SysUtils` and `PascalCommon.Threading`, and are the same kind of thing as
`PascalCommon.SystemContext`. A separate library would cost every application one more
submodule, version check, `.lpk` and CI, for a few hundred lines. It becomes worth it when the
**exporters** (OTLP over HTTP, which needs an HTTP client and a JSON writer, neither of which
pascal-common-faa has) are wanted by a program that is not an API on this library: then the
exporters move out of here into their own library, depending on pascal-common-faa. Until then
they live here.

Because pascal-common-faa is at 1.x, a contract that changes after release is a 2.0. So pieces
go there in order of stability:

| Piece | Stability | Goes to pascal-common-faa |
|---|---|---|
| `TraceContext`: ids, `traceparent`/`tracestate` parse and format | fixed by the W3C specification | phase A |
| Metrics primitives (counter, gauge, histogram, registry) and the Prometheus text writer | fixed by the exposition format | phase B |
| Tracer / span contracts (start, attributes, status, end, current span) | ours; shaped by the first exporter | designed and exercised here in phase C (`PascalApi.*`, documented as unstable), moved at the start of phase D |

### 2. Order: A and B first, then C, then D (user, 2026-10-09)

Trace context and metrics give most of the value without a collector; OTLP export comes after.

### 3. `X-Request-Id` becomes the trace id (user, 2026-10-09)

One id instead of two: the id in the response header, the access log line, the error log and
the exported trace are the same, and a support ticket with the response's `X-Request-Id` finds
the trace directly. The trace id exists for every request, sampled or not.

It is a **breaking change** (8 hex digits become 32): released as **0.8.0**, with a CHANGELOG
entry. Still pre-1.0, the cheapest moment to do it. `NewRequestId` is removed (or kept returning
a new trace id; decided during implementation, recorded here).

Where the trace id of a request comes from, in order:

1. a valid incoming `traceparent` (version `00`, non-zero ids): its trace id, and its span id as
   the parent of the server span;
2. otherwise, an incoming `X-Request-Id` that is exactly 32 lowercase hex digits and not all
   zeros (nginx's `$request_id` has this shape): adopted as the trace id, no parent;
3. otherwise a new random trace id.

Anything else in an incoming `X-Request-Id` is ignored (as today): free text from a client
never reaches the logs.

## Decisions taken as recommended (user, 2026-10-09)

4. **Default log format.** Keep the text line as the default and add a JSON line (opt-in), or
   switch the default to JSON in 0.8.0 together with decision 3? Decided: opt-in JSON
   now; the text line, what people read on a console, stays the default.
5. **Sampling.** Phase C needs a policy: honor the incoming `sampled` flag, plus a ratio for new
   traces (`OTEL_TRACES_SAMPLER_ARG`-like). Decided: parent-based, ratio 1.0 by default.
6. **Configuration names.** Use the standard OpenTelemetry environment variables
   (`OTEL_SERVICE_NAME`, `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_RESOURCE_ATTRIBUTES`...) through
   `TAppConfig`, instead of our own names. Decided: the standard names, so the deployment
   needs no translation.

## Phases

### A. Trace context and correlated logs

- **pascal-common-faa** `PascalCommon.TraceContext` (pure): trace id (16 bytes) and span id
  (8 bytes) as hex, generation (random, never all zeros), validation, `traceparent` and
  `tracestate` parse and format. Tests with the W3C specification's examples and invalid cases
  (wrong version, uppercase hex, zero ids, wrong lengths, extra fields).
- **Here**:
  - `TLoggerMiddleware` resolves the trace id (decision 3), sets `X-Request-Id` and `traceparent`
    on the request (as `X-Request-Id` is today, for the handler) and `X-Request-Id` on the
    response; the access line carries the 32-digit id.
  - `AccessLogJson` in `PascalApi.Http` (pure): one JSON object per request with the same fields
    plus `trace_id` and `span_id`; selected by an option (decision 4).
  - The error handler's line carries the trace id.
  - The MCP executor forwards `traceparent`: a tool call and the API call it makes share the
    trace.
  - A way for the handler to read the current ids (`TTraceContext.Current`, or reading the
    request headers) so the application's own `FileLog` lines can carry them.
- Tested: `PascalApi.HttpTests` (resolution order, JSON line); `tools/http_scenarios.sh` checks
  that an incoming `traceparent` is echoed as `X-Request-Id`, that a malformed one is replaced,
  and that the MCP loopback keeps the trace id (the sample's access log).

### B. Metrics and health

- **pascal-common-faa** `PascalCommon.Metrics` (pure): counter, up-down counter/gauge,
  histogram with fixed buckets (OpenTelemetry's defaults for durations: 5 ms to 10 s), labels,
  a registry; thread-safe with `PcAtomic*` and a lock for the label maps. The Prometheus text
  writer, tested byte by byte (`# HELP`, `# TYPE`, `_bucket{le=...}`, `_sum`, `_count`, label
  escaping).
- **Here**:
  - `http.server.request.duration` recorded by the logger middleware (or a metrics middleware;
    decided when writing it), and `http.server.active_requests`.
  - `TMetricsEndpoint.Register('/metrics')` in `src/horse`, excluded from authentication the way
    `TRouteDoc.Serve` marks its paths (the application decides; documented).
  - `THealthEndpoint`: `/health/live` (process up) and `/health/ready` (callbacks the
    application registers, e.g. a pascal-db-faa pool ping), 200 or 503 with a JSON body.
- Tested: unit tests for the writer and the registry under threads; `tools/http_scenarios.sh`
  scrapes `/metrics` after the other checks and asserts counts; CI parses the output with
  Prometheus' own `promtool check metrics`.

### C. Spans and OTLP export

- Here, unstable API (moves to pascal-common-faa in D): tracer, span (attributes, events,
  status, end), current span per thread (`threadvar`), parent-based sampling (decision 5).
- The server span is opened by the logger middleware and ended in its `finally`, with the HTTP
  semantic-convention attributes.
- `PascalApi.Otlp` (pure): spans and metrics to OTLP/HTTP JSON, with the resource attributes
  (`service.name`, `service.version`, decision 6). The HTTP sender in a separate unit; a batch
  exporter thread with a bounded queue that drops the oldest, the same design as `FileLog`
  (exporting must never block or bring down a request).
- Tested: unit tests on the JSON (fixed clock and ids); CI runs an `otel/opentelemetry-collector`
  container with the file exporter and checks the received spans (the collector as the
  reference implementation, as `openapi-spec-validator` and the MCP SDK are for phases 4 and 5).

### D. Instrumentation of the sibling libraries

Other repositories, each in its own session: hooks in pascal-db-faa (query, transaction, pool
wait), pascal-redis-faa (command) and pascal-amqp-faa (publish, consume, with `traceparent` in
the message headers), using the contracts moved to pascal-common-faa.

## Risks and things to measure before relying on them

- **Route template.** Metrics need `/orders/:id`, not `/orders/123` (cardinality). Whether
  Horse 3.3.12 exposes the matched route on both compilers is unknown; if not, `TRouteDoc`
  knows the documented templates and can resolve the path. Undocumented routes fall back to a
  fixed label (`other`), never the raw path.
- **Current span in a `threadvar`.** Horse's providers (Indy, fpWeb) run a request on one thread
  from start to end, but reuse threads: the middleware clears it in a `finally`. Across
  processes (and the MCP loopback) the header carries the context, not the thread.
- **Randomness of the ids.** `CreateGUID` is OS-backed on Windows; on FPC/Unix its source must
  be checked (`/dev/urandom` or a `Random` fallback). A GUID v4 has fixed version/variant bits,
  and `TGUID`'s first fields are little-endian in memory: build the id from bytes known to be
  random, measured on both compilers.
- **Timestamps.** OTLP wants Unix nanoseconds in UTC. On FPC/Linux `Now` is UTC (measured for
  JWT); on Delphi/Windows it is local time and must be converted. Durations with `PcTickUs`,
  never `TClock`.
- **fphttpclient in the core package.** Today only `src/horse` uses an HTTP client. If the OTLP
  sender goes into `src/`, check that the `.lpk` builds with it (fcl-web) on Windows and in the
  Linux image.
- **Overhead.** Per request: one id, one histogram observation, one span object. Measure with
  the sample under load before and after, and keep the exporter off the request thread.
- **One configuration per process.** It fits: one tracer, one registry, one exporter per
  application.

## Not in this design

- Logs over OTLP (`/v1/logs`): the JSON line on stdout, collected by the platform, covers it
  for now.
- gRPC/protobuf OTLP.
- Automatic instrumentation of outgoing HTTP calls the application makes on its own.

## Next step: phase A, part 1, in pascal-common-faa

Done in a session opened in pascal-common-faa (its CLAUDE.md, hooks and test layout apply).
A minor release (1.5.0), then this repository bumps the submodule and does part 2 (the
middleware, the JSON line, the MCP forwarding).

`PascalCommon.TraceContext`, pure (`SysUtils` + an OS random source). Ids as **lowercase hex
strings** (what every caller writes to a header or a log), not byte records. Sketch, names to
follow the library's `Pc` prefix:

    type
      TPcTraceParent = record
        TraceId: string;   // 32 lowercase hex, not all zeros
        ParentId: string;  // 16 lowercase hex, not all zeros
        Flags: Byte;
        function Sampled: Boolean;   // bit 0
      end;

    function PcNewTraceId: string;
    function PcNewSpanId: string;
    function PcIsValidTraceId(const AValue: string): Boolean;
    function PcIsValidSpanId(const AValue: string): Boolean;
    function PcTryParseTraceParent(const AHeader: string; out AValue: TPcTraceParent): Boolean;
    function PcFormatTraceParent(const ATraceId, ASpanId: string; ASampled: Boolean): string;

Rules from the W3C Trace Context specification (Level 1), to be checked against its text when
writing the tests:

- `version-traceid-parentid-flags`, lowercase hex only; version `ff` is invalid; version `00`
  is exactly 55 characters; a higher version is accepted if the first 55 characters parse and
  the 56th, if any, is `-` (forward compatibility), and is written back as `00`.
- All-zero trace id or parent id: invalid, the header is ignored (a new trace starts).
- `tracestate` is forwarded unchanged when `traceparent` is valid, dropped otherwise; no
  parsing in phase A beyond a length limit (512 characters).

To measure there before choosing the random source: what `CreateGUID` uses on FPC/Unix
(`/dev/urandom` or a `Random` fallback), and whether a direct OS source (`BCryptGenRandom` /
`RtlGenRandom` on Windows, `/dev/urandom` on Linux) is simpler than taking random bytes out of a
GUID v4 (fixed version/variant bits; `TGUID`'s first fields little-endian in memory). Add the
unit to pascal-common-faa's "Candidates" table as moved, and to the skill index
(`references/faa-libraries.md`).
