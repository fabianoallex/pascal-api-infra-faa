"""Asks a Prometheus that scrapes the OpenTelemetry Collector for the metrics
sample 02 pushed over OTLP (TOtlpMetricsExporter, 0.26.0): the whole path a
program without HTTP takes to a dashboard (OTLP/HTTP JSON -> collector ->
its prometheus exporter -> a scrape -> PromQL).

    python3 tools/otlp_metrics_check.py http://prometheus:9090 cities-api

Checks, for the job (the service.name): the request duration histogram
(a count above 0, the +Inf bucket, a route label), the active requests
(an up-down counter) and pascal-db-faa's pool metrics. Waits up to 30 s for
the first scrape. Exit code 0 only if every check passed. Run by
tools/test_http_docker.sh (CI).
"""
import json
import sys
import time
import urllib.parse
import urllib.request

FAILS = []


def check(cond, label):
    print(("ok   " if cond else "FAIL ") + label)
    if not cond:
        FAILS.append(label)


def query(base, promql):
    url = base + "/api/v1/query?" + urllib.parse.urlencode({"query": promql})
    with urllib.request.urlopen(url, timeout=10) as resp:
        body = json.loads(resp.read())
    if body.get("status") != "success":
        raise RuntimeError("%s: %s" % (promql, body))
    return body["data"]["result"]


def main():
    base, job = sys.argv[1].rstrip("/"), sys.argv[2]
    count = 'http_server_request_duration_seconds_count{job="%s"}' % job
    result = []
    for _ in range(60):
        try:
            result = query(base, count)
        except Exception as e:  # Prometheus still starting
            print("waiting: %s" % e)
            result = []
        if result:
            break
        time.sleep(0.5)
    if not result:
        try:
            names = query(base, 'group by (__name__) ({job="%s"})' % job)
            print("series of %s: %s" % (job, sorted(r["metric"]["__name__"] for r in names)))
        except Exception as e:
            print("no series: %s" % e)
    check(result != [], "%s: the request duration reached Prometheus" % job)
    total = sum(float(r["value"][1]) for r in result)
    check(total > 0, "%s: %d requests counted" % (job, total))
    routes = sorted({r["metric"].get("http_route", "") for r in result})
    check("/cities/:code" in routes, "%s: by route (%s)" % (job, routes))

    buckets = query(base, 'http_server_request_duration_seconds_bucket{job="%s",le="+Inf"}' % job)
    check(buckets != [], "%s: the histogram's +Inf bucket" % job)
    finite = query(base, 'http_server_request_duration_seconds_bucket{job="%s",le="0.005"}' % job)
    check(finite != [], "%s: a bucket of the explicit bounds (le=0.005)" % job)

    active = query(base, 'http_server_active_requests{job="%s"}' % job)
    check(active != [], "%s: the active requests (an up-down counter)" % job)

    pool = query(base, '{job="%s",__name__=~"db_client_connection.*"}' % job)
    names = sorted({r["metric"]["__name__"] for r in pool})
    check(len(names) >= 2, "%s: pascal-db-faa's pool metrics (%s)" % (job, names))

    print("%s: %d failed" % (sys.argv[0], len(FAILS)))
    sys.exit(1 if FAILS else 0)


if __name__ == "__main__":
    main()
