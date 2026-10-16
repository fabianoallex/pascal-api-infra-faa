# Logging and observability

What a running API tells the people who run it: one access line per request, an error line for
what went wrong, a request id that ties them together, metrics a Prometheus server scrapes,
health endpoints for an orchestrator, and spans sent to an OpenTelemetry collector. The code
comes from the three samples, which `tools/http_scenarios*.sh` check over HTTP; CI also checks
the metrics with `promtool` and the spans with a real OpenTelemetry Collector
(`tools/otlp_check.py`). The decisions behind all of this are in
[docs/observability-design.md](../observability-design.md).

## What it solves

When a user says "it failed", you need to find that request: when, from where, how long it
took, what the server logged about it, and what it did in the database. When nobody says
anything, you need numbers: how many requests, how slow, how many errors. And whatever starts
and restarts the program needs to know whether it is up and ready.

The library gives each request one id (the W3C trace id), puts it everywhere (the response
header, the access line, the error line, the error body, every span), and offers the metrics,
health and tracing pieces as separate middlewares and endpoints you turn on.

## The smallest working program

```pascal
TErrorHandlerMiddleware.Register(GCallbacks.LogError);  // the error line
THorse.Use(TLoggerMiddleware.New);                      // first: the id, the access line, the span
THorse.Use(TMetricsMiddleware.New);                     // right after the logger
...routes...
TMetricsEndpoint.Register;                              // GET /metrics
THealthEndpoint.Register('/health');                    // GET /health/live, /health/ready
```

From sample 01 (Delphi 12 Win64, 2026-10-14):

```
[2026-10-14 16:54:44] GET /trace 200 0ms 127.0.0.1 144 "-" "curl/8.12.1" 4bf92f3577b34da6a3ce929d0e0e4736
ERROR GET /fail/server -> 500: EInvalidOpException: something broke trace_id=acc90d2604a619cf29cb723339898019
```

## Step by step

### 1. The request id

`TLoggerMiddleware` gives every request a trace id (32 hex digits) before anything else runs,
and puts it:

- in the response, as `X-Request-Id`;
- on the request, as `X-Request-Id` and `traceparent`, where a handler reads it;
- at the end of the access line, of the error line (`trace_id=`), and in the body of a logged
  error (`requestId`, [Errors and validation](errors.md), step 4);
- in every span of the request.

Where it comes from (`ResolveRequestTrace`, tested):

1. a valid `traceparent` header from the caller: its trace id, so your spans join the caller's
   trace;
2. else an `X-Request-Id` of exactly 32 lowercase hex digits (nginx's `$request_id` has that
   shape): adopted, so the proxy's log and yours share the id;
3. else a new one, from the operating system's random source.

Any other `X-Request-Id` is ignored: text a client wrote never reaches your logs as an id. The
scenarios check each case (`GET /trace` answers what the handler saw).

### 2. The access line: text or JSON

```pascal
THorse.Use(TLoggerMiddleware.New);                 // text, to the console (sample 01)
THorse.Use(TLoggerMiddleware.New(nil, alfJson));   // JSON, to the console (samples 02 and 03)
THorse.Use(TLoggerMiddleware.New(GLog.Access));    // text, to your procedure
```

Text: `[time] METHOD /path STATUS Xms CLIENT-IP BYTES "QUERY" "USER-AGENT" REQUEST-ID`, with `-`
for an empty field. JSON, one object per line, for a log collector (sample 02, Delphi 12 Win64):

```json
{"time":"2026-10-14T16:55:04.431","trace_id":"e5245ef34932974aea956d77a003cb1f","span_id":"921304867cde5d6a","parent_span_id":"36709ead3712ccec","method":"GET","path":"/cities/3550308","status":200,"duration_ms":0,"client_ip":"127.0.0.1","bytes":73,"user_agent":"Embarcadero URI Client/1.0"}
```

The line is written when the request ends, with its final status, also for an error or an
exception raised in a middleware (Errors and validation, step 5). Put the logger **first**, so
its time covers everything after it.

The time is the server's local time, without a zone (`TClock.Now`); the spans carry UTC.

**Turn on UTF-8 for the console log.** The logger writes through pascal-common-faa's
`SafeWriteln` (one line at a time, flushed). With standard output in a file or a pipe (Docker, a
service wrapper), neither compiler writes UTF-8 by itself: FPC writes in the console's code page
(850) and Delphi in the ANSI one (1252), and a character outside it becomes `?` (pascal-common-faa's
gotcha 11). Measured on sample 01: the 500's message `something broke (ação)` reached the file as
`a\x87\xc6o`. pascal-common-faa 1.10.0 adds a switch, off by default because it changes the bytes
an existing log gets:

```pascal
PcSetSafeLogUtf8(True);   // PascalCommon.SafeLog, at startup: UTF-8 to a file or a pipe,
                          // WriteConsoleW to a Windows console; every thread
```

The samples turn it on, and `tools/http_scenarios.sh` checks that line's UTF-8 bytes in the log
file, on both compilers. Only `SafeWriteln` follows the switch: write your own log lines (errors,
startup) through it too, or one log file mixes two encodings. The library doesn't turn it on: it
holds for the whole process, so it is the application's call.

### 3. The client's address

`client_ip` is what can be trusted, not what the client says: `TClientAddress.Resolve`, the same
address the rate limit uses ([Rate limiting](rate-limiting.md), step 3). The connection's
address, unless it is a proxy you declared or a loopback address; then the address that proxy put
in `X-Forwarded-For`, read from the right:

```pascal
TClientAddress.ProxyHops := 1;   // behind one load balancer; at startup
```

Checked over HTTP by sample 01's scenario: a request from the same machine with
`X-Forwarded-For: 203.0.113.9, 10.0.0.1` is logged as `10.0.0.1`, the address a proxy on this
machine would have appended. **Until 0.13.0 the log took the header's first address**, which the
client writes: the same request was logged as `203.0.113.9` (measured with the Delphi build of
that version).

Your own code that needs the client's address (a handler, a rate-limit key function, an audit
field) calls `TClientAddress.Resolve(AReq)` too, so it agrees with the log and the limit. Two
lookalikes give something else:

- **`AReq.RemoteAddr`** is `''` with Horse's console provider (fpWeb on FPC, Indy on Delphi): only
  Horse's raw providers (Epoll, IOCP, HttpSys, Daemon, LCL) fill it. Seen on FPC 3.2.2/Windows,
  where the access log showed `-` for every request, and on Delphi 12 Win32 (a probe,
  2026-10-08). `Resolve` falls back to the web request's address.
- **`ClientIp`** (`PascalApi.Http`) takes `X-Forwarded-For`'s first address, which the client
  writes. It is kept for compatibility; nothing in the library uses it since 0.13.0.

### 4. Your own fields

`AddField` adds a value read after the handler ran, to the access line and to the span. Sample 03
adds the tenant:

```pascal
TLoggerMiddleware.AddField('tenant.id', TenantIdOf);   // before Listen
THorse.Use(TLoggerMiddleware.New(nil, alfJson));
```

```json
{"time":"2026-10-14T16:55:12.336","trace_id":"fc2573ddc80bd956e6d2a0ae96bdcc9c",...,"user_agent":"curl/8.12.1","tenant.id":"acme"}
```

The function is a plain function of the request (`TRequestValueFunc`: it captures nothing). An
empty value is left out (tested), and so is a value whose function raises, since the response is
already decided by then (from the code, not tested). `tools/http_scenarios_tenants.sh` checks
the field on a tenant's request, and that a client sending its own tenant mark doesn't get one;
`tools/otlp_check.py` checks it on the spans.

### 5. Errors

The error handler's procedure gets one line per error worth looking at (500, 503, 422, lock
conflicts), ending with the request's id; client errors (400, 404, 409 from a key) aren't
logged. [Errors and validation](errors.md), step 4, has the format and the checks. Write it
where your errors go: the console, a file (step 6), your platform's logger.

### 6. Logs in files: `FileLog`

When the platform doesn't collect the console, `PascalApi.FileLog` writes to files, one per
category, without making the request wait for the disk: a call only queues the line, and a
thread writes the queue in batches.

```pascal
FileLog('errors', ALine);
FileLog(['exception', 'startup'], 'Could not connect: %s', [E.Message]);
```

- Files are `<LOG_DIR>/<category>.log`, UTF-8, rotated to `<category>_yyyymmddhhnnss.log` at
  `LOG_MAX_FILE_SIZE_MB`.
- Each line starts with `[<id> <date time>]`; one call to several categories writes the same id
  in each, so the lines can be matched.
- The queue is bounded (`LOG_QUEUE_CAPACITY`, 10000): when it is full, the **oldest** line is
  dropped, so logging never blocks a request.

All tested in `PascalApi.FileLogTests` (rotation, the shared id, a full queue, non-ASCII,
concurrency). No sample writes files. The `LOG_*` settings are read when the unit starts, before
your program's first line ([Configuration](configuration.md), step 6).

### 7. Metrics

```pascal
THorse.Use(TMetricsMiddleware.New);    // right after the logger
TMetricsEndpoint.Register;             // GET /metrics, Prometheus text format
```

| OpenTelemetry name | Prometheus | Kind | Labels |
|---|---|---|---|
| `http.server.request.duration` | `http_server_request_duration_seconds` | histogram | method, route, status |
| `http.server.active_requests` | `http_server_active_requests` | up-down counter | method |
| `db.client.connection.*` (pascal-db-faa's pool) | `db_client_connection_count`, `_max`, `_wait_time_seconds` ... | | pool, state |

- **The route label is the template** (`/cities/:code`), never the raw path, so a client can't
  create a series per id; `''` when no route matched or a middleware answered first (a 401). The
  method label is `_OTHER` for an unknown method. Both checked over HTTP.
- A request to a route that doesn't exist is counted once, though Horse runs the middlewares
  twice there (checked).
- CI runs `promtool check metrics` on samples 01 and 02's `/metrics`. One lint is accepted on
  purpose: the `_count` suffix of `db_client_connection_count`, the OpenTelemetry name.

Your own metrics go in the same registry, pascal-common-faa's `PcMetrics`
(`PascalCommon.Metrics`), and every one needs a description: `promtool` rejects a metric without
help text.

### 8. Health

```pascal
THealthEndpoint.AddCheck('database', GLog.DatabaseReady);   // a method; raises or returns False
THealthEndpoint.Register('/health', GLog.Error);
```

- `GET /health/live`: 200 `{"status":"ok"}` while the process answers. For "restart me".
- `GET /health/ready`: runs every check, 200 or 503, with `{"status":...,"checks":{"database":"ok"}}`.
  For "send me traffic".

A check that raises counts as failed; the answer has only names and `ok`/`fail`, and the reason
goes to the procedure you pass (`health check <name> failed: <reason>`), never to the client.
Sample 01's `maintenance` check and sample 02's `database` check are checked over HTTP.

`/metrics` and `/health` are ordinary routes: leave them out of the token check
([Authentication](authentication.md), step 2), since a scraper and an orchestrator have no token,
and keep them off the public internet.

### 9. Spans to an OpenTelemetry collector

```pascal
if TAppConfig.Get('OTEL_EXPORTER_OTLP_ENDPOINT', '') <> '' then
  TPcTracing.Start(TPcTracingOptions.FromEnvironment('pascal-api-sample-01', '1.0.0', ReadAppConfig),
    TOtlpHttpExporter.FromEnvironment, GCallbacks.LogError);
```

With tracing started, each request is a server span named `GET /cities/:id`, with the HTTP
attributes of the semantic conventions, `client.address` (step 3) and your fields (step 4); a 5xx
has an error status. Under it:

- a handler's own spans: `TPcTracing.StartSpan` makes a child of the request's span (sample 01's
  `GET /trace`);
- pascal-db-faa's spans, one per statement and per transaction, with no code (sample 02);
- an MCP tool call, as a client span, and the route it calls as another server span in the same
  trace.

The exporter sends OTLP over HTTP with JSON, in a background thread, in batches. The settings
are the standard `OTEL_*` variables (`OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_SERVICE_NAME`,
`OTEL_TRACES_SAMPLER_ARG` for the ratio of new traces kept, `OTEL_BSP_*` for the batches): see
[Configuration](configuration.md), step 6, and pass `ReadAppConfig` so the `.env` file counts.
A caller's `traceparent` decides for its own trace (parent-based sampling).

For a call your handler makes to another service, send the request's `traceparent`
(`AReq.Headers['traceparent']`) so that service joins the trace.

## Choices

### Text or JSON

Text for a person reading a console; JSON for anything that collects logs (Loki, Elasticsearch,
CloudWatch): each field is searchable, and the trace id links a line to its spans.

### Console or files

In a container, write to the console and let the platform collect it. On a server without a
collector, `FileLog`. The access line goes wherever your `TLogProc` sends it.

### Metrics, spans, or both

Metrics are cheap and always on: rates, latencies, saturation. Spans answer "why was *this*
request slow"; with many requests, keep a ratio (`OTEL_TRACES_SAMPLER_ARG`). The metrics
middleware and the logger are separate, so you can have either.

## Pitfalls

- **The logger not first**: the time misses the middlewares before it, those middlewares' errors
  aren't answered (Errors and validation, step 5), and there is no id until it runs.
- **`TClientAddress.ProxyHops` wrong**: too low behind a proxy, every client is logged (and
  limited) as the proxy; too high, the client's own `X-Forwarded-For` entry is logged as its
  address.
- **`AReq.RemoteAddr` or `ClientIp` in your own code**: empty with the console provider, or the
  address the client chose (step 3). Use `TClientAddress.Resolve(AReq)`.
- **The raw path in a metric label** of your own: one series per id, until the server runs out of
  memory. Use the route template.
- **A metric without a description**: `promtool` fails on it.
- **Health endpoints behind the token check**: the orchestrator gets 401 and restarts a healthy
  program.
- **Spans still queued when the program is killed** are lost: the samples never call
  `TPcTracing.Shutdown` (`Listen` doesn't return). Not measured; keep the batch interval short if
  the last seconds matter.
- **Log lines through plain `Writeln`**: not UTF-8 with output in a file or a pipe, even with
  `PcSetSafeLogUtf8(True)` (only `SafeWriteln` follows it); step 2.
- **An https collector on FPC** needs the `opensslsockets` unit in your program (comment in
  `PascalApi.Otlp`; not measured here, the samples send to http).

## Testing your application

The pieces are tested without a server: the id rules (`ResolveRequestTrace`), the access line
(`AccessLogLine`, `AccessLogJson`), the metric labels (`MetricRoute`, `MetricMethod`), the health
answer (`HealthJson`) and the OTLP body (`OtlpTracesJson`, byte for byte), in
`PascalApi.HttpTests` and `PascalApi.OtlpTests`.

Over HTTP, the scenarios read what the server wrote when the runner passes its output in
`SERVER_LOG`: the error line by the id the client got, the client's address in the access line,
`tenant.id` in sample 03's JSON lines. From `tools/http_scenarios.sh`:

```sh
grep -q "something broke trace_id=$FAIL_ID" "$SERVER_LOG" && ok \
  || fail "log: the 500's message with trace_id=$FAIL_ID"
```

For spans, CI starts an OpenTelemetry Collector that writes what it receives to a file, and
`tools/otlp_check.py` checks the parent-child links, the names and the statuses.

## Reference

- `PascalApi.Horse.Middlewares`: `TLoggerMiddleware`, `TClientAddress`, `TErrorHandlerMiddleware`.
- `PascalApi.Horse.Observability`: `TMetricsMiddleware`, `TMetricsEndpoint`, `THealthEndpoint`.
- `PascalApi.Http`: `ResolveRequestTrace`, `AccessLogLine`, `AccessLogJson`, `TrustedClientIp`,
  `MetricRoute`, `HealthJson`.
- `PascalApi.FileLog`, `PascalApi.Otlp`; pascal-common-faa's `PascalCommon.Tracing` and
  `PascalCommon.Metrics`.
- [docs/observability-design.md](../observability-design.md): the decisions and what was measured.
- `tools/http_scenarios*.sh`, `tools/otlp_check.py`, `tools/promtool_check.sh`.
