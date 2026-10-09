"""Checks the spans an OpenTelemetry Collector received from the samples
(tools/otelcol.yaml writes them to a file, one export request per line).

    python3 tools/otlp_check.py /otel/traces.json

Run by tools/test_http_docker.sh after tools/http_scenarios.sh and
tools/http_scenarios_db.sh, with the samples exporting to the collector.
What it checks follows those scripts' requests: the trace id they send in
traceparent (4bf92f...), the MCP tool call, a 500, the not-sampled request
and sample 02's routes. Exit code 0 only if every check passed.
"""
import json
import sys
import time

TRACE_ID = "4bf92f3577b34da6a3ce929d0e0e4736"
PARENT_ID = "00f067aa0ba902b7"
NOT_SAMPLED_ID = "5bf92f3577b34da6a3ce929d0e0e4736"

failures = 0


def check(cond, what):
    global failures
    print(("ok   " if cond else "FAIL ") + what)
    if not cond:
        failures += 1


def attrs(items):
    out = {}
    for a in items or []:
        v = a["value"]
        out[a["key"]] = next(iter(v.values())) if v else None
    return out


def load(path):
    spans = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            for rs in json.loads(line).get("resourceSpans", []):
                service = attrs(rs.get("resource", {}).get("attributes")).get("service.name")
                for ss in rs.get("scopeSpans", []):
                    for s in ss.get("spans", []):
                        s["_service"] = service
                        s["_attrs"] = attrs(s.get("attributes"))
                        spans.append(s)
    return spans


def main():
    spans = load(sys.argv[1])
    print("%d spans received" % len(spans))
    s01 = [s for s in spans if s["_service"] == "pascal-api-sample-01"]
    s02 = [s for s in spans if s["_service"] == "cities-api"]
    check(len(s01) > 50, "sample 01 spans: %d" % len(s01))
    check(len(s02) > 10, "sample 02 spans: %d" % len(s02))

    # Timestamps are UTC Unix nanoseconds: within an hour of now (a local time
    # taken for UTC would be hours off outside UTC).
    now = time.time_ns()
    starts = [int(s["startTimeUnixNano"]) for s in spans]
    check(all(abs(t - now) < 3600 * 10**9 for t in starts), "timestamps near now (UTC)")
    check(all(int(s["endTimeUnixNano"]) >= int(s["startTimeUnixNano"]) for s in spans), "end >= start")

    # A request with the scenarios' traceparent: a server span, child of the caller's.
    trace = [s for s in s01 if s["traceId"] == TRACE_ID]
    direct = [s for s in trace if s["kind"] == 2 and s.get("parentSpanId") == PARENT_ID
              and s["name"] == "GET /trace"]
    check(len(direct) >= 1, "server span GET /trace, child of the incoming traceparent")
    if direct:
        a = direct[0]["_attrs"]
        check(a.get("http.route") == "/trace", "http.route")
        check(a.get("http.request.method") == "GET", "http.request.method")
        check(str(a.get("http.response.status_code")) == "200", "http.response.status_code")
        check(a.get("url.path") == "/trace", "url.path")
        children = [s for s in trace if s.get("parentSpanId") == direct[0]["spanId"]]
        check(any(c["name"] == "build trace answer" and c["kind"] == 1 for c in children),
              "the handler's own span is a child of the server span")
        check(direct[0].get("traceState") == "vendor=1", "tracestate kept")

    # MCP: POST /mcp (server) -> GET (client) -> GET /trace (server), one trace.
    mcp = [s for s in trace if s["kind"] == 2 and s["name"] == "POST /mcp"]
    check(len(mcp) >= 1, "server span POST /mcp in the trace")
    if mcp:
        clients = [s for s in trace if s["kind"] == 3 and s.get("parentSpanId") == mcp[-1]["spanId"]]
        check(len(clients) == 1, "one client span under the MCP request")
        if clients:
            check(clients[0]["_attrs"].get("url.full", "").endswith("/trace"), "client span url.full")
            tool = [s for s in trace if s["kind"] == 2 and s.get("parentSpanId") == clients[0]["spanId"]]
            check(len(tool) == 1 and tool[0]["name"] == "GET /trace",
                  "the tool's route is a child of the client span")

    # A 500 is an error; a 404 is not (server spans).
    fail = [s for s in s01 if s["name"] == "GET /fail/server"]
    check(len(fail) >= 1 and all(s["status"].get("code") == 2 for s in fail), "5xx: status error")
    nf = [s for s in s01 if s["name"] == "GET /cities/:id" and s["_attrs"].get("http.response.status_code") == "404"]
    check(len(nf) >= 1 and all(s["status"].get("code", 0) == 0 for s in nf), "404: status unset")

    # No route: named by the method alone.
    check(any(s["name"] == "GET" and "http.route" not in s["_attrs"] for s in s01), "no route: span 'GET'")

    # Not sampled: never exported.
    check(not any(s["traceId"] == NOT_SAMPLED_ID for s in spans), "not-sampled trace not exported")

    # Sample 02: route templates.
    check(any(s["name"] == "GET /cities/:code" for s in s02), "sample 02: GET /cities/:code")
    check(not any("/cities/3550308" in s["name"] for s in spans), "never a raw path in a span name")

    print("%d failed" % failures)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
