#!/bin/sh
# Builds samples/01-api and samples/02-db with plain fpc on Linux (Docker),
# starts each one and runs its HTTP scenarios (tools/http_scenarios.sh, the
# middlewares; tools/http_scenarios_db.sh, SQLite through pascal-db-faa's
# SQLdb adapter, which loads Debian's libsqlite3.so.0).
#
# Horse is used unchanged (external/horse, 3.3.12). The image needs FPC 3.2.2 and
# curl, libsqlite3-0, openapi-spec-validator, the MCP Python SDK (mcp 2.0.0,
# for tools/mcp_client_check.py) and Prometheus' promtool (2.53.0, for the
# /metrics output); tools/ci-test.sh builds one.
#
# Spans: an OpenTelemetry Collector (OTEL_COLLECTOR_IMAGE, contrib 0.111.0)
# runs next to it on a Docker network of its own; both samples export to it
# (OTEL_EXPORTER_OTLP_ENDPOINT), it writes what it accepts to a volume, and
# tools/otlp_check.py checks that after both samples ran.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${FPC_IMAGE:-pascalapi-fpc322}"
MOUNT="$ROOT"
command -v cygpath >/dev/null 2>&1 && MOUNT="$(cygpath -w "$ROOT")"

cd "$ROOT"
for D in pascal-common-faa pascal-jsonmapper-faa pascal-db-faa horse; do
  [ -d "external/$D/src" ] || { echo "external/$D is empty: git submodule update --init"; exit 1; }
done

COLLECTOR_IMAGE="${OTEL_COLLECTOR_IMAGE:-otel/opentelemetry-collector-contrib:0.111.0}"
NAME="pascalapi-otel-$$"
cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker network rm "$NAME" >/dev/null 2>&1 || true
  docker volume rm "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker network create "$NAME" >/dev/null
docker volume create "$NAME" >/dev/null
# As root: the file exporter writes to the volume's root, which root owns.
MSYS_NO_PATHCONV=1 docker run -d --name "$NAME" --network "$NAME" --user 0   -v "$NAME:/otel" -v "$MOUNT:/src:ro" "$COLLECTOR_IMAGE" --config /src/tools/otelcol.yaml >/dev/null

MSYS_NO_PATHCONV=1 docker run --rm --network "$NAME" -v "$NAME:/otel:ro" -v "$MOUNT:/src:ro"   -e OTEL_EXPORTER_OTLP_ENDPOINT="http://$NAME:4318" -e OTEL_BSP_SCHEDULE_DELAY=200   "$IMAGE" sh -c '
  set -e
  mkdir -p /t/uApiSample /t/uDbApiSample && cp -r /src/src /src/samples /src/tools /src/external /t/
  E=/t/external
  P="-Fu/t/src -Fi/t/src -Fu/t/src/horse -Fu$E/horse/src -Fi$E/horse/src"
  P="$P -Fu$E/pascal-common-faa/src -Fi$E/pascal-common-faa/src -Fu$E/pascal-common-faa/bridges/jsonmapper"
  P="$P -Fu$E/pascal-jsonmapper-faa/src -Fi$E/pascal-jsonmapper-faa/src"
  P="$P -Fu$E/pascal-db-faa/src -Fi$E/pascal-db-faa/src"
  P="$P -Fu$E/pascal-db-faa/adapters/sqldb -Fi$E/pascal-db-faa/adapters/sqldb"
  run() {
    cd /t/samples/$1
    fpc -v0 -Mdelphi -dUseCThreads $P -FU/t/u$2 -o/t/$2 $2.dpr > /t/build-$2.log 2>&1       || { grep -iE "error|fatal" /t/build-$2.log | head -30; exit 1; }
    mkdir -p /t/run-$2 && cd /t/run-$2
    /t/$2 $3 $5 > /t/server-$2.log 2>&1 &
    PID=$!
    for I in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null http://127.0.0.1:$3/ && break; sleep 1; done
    RC=0
    OPENAPI_OUT=/t/openapi-$2.json METRICS_OUT=/t/metrics-$2.txt sh /t/tools/$4 $3 || RC=$?
    # The document each sample serves, checked against the OpenAPI 3.0 spec.
    if [ $RC -eq 0 ]; then
      python3 -m openapi_spec_validator /t/openapi-$2.json || RC=$?
    fi
    # Its /metrics, checked by Prometheus itself (a lint warning also fails).
    if [ $RC -eq 0 ]; then
      promtool check metrics < /t/metrics-$2.txt || RC=$?
    fi
    # The MCP endpoint, driven by the official Python SDK (2026-07-28).
    if [ $RC -eq 0 ]; then
      python3 /t/tools/mcp_client_check.py $6 http://127.0.0.1:$3 || RC=$?
    fi
    # The last spans: the exporter sends every 200 ms.
    sleep 1
    kill $PID 2>/dev/null || true
    if grep -q "span export failed" /t/server-$2.log; then
      grep "span export failed" /t/server-$2.log | head -3; RC=1
    fi
    [ $RC -eq 0 ] || { echo "--- server log"; tail -40 /t/server-$2.log; exit $RC; }
  }
  echo "-- samples/01-api"
  run 01-api ApiSample 9310 http_scenarios.sh "" 01
  echo "-- samples/02-db"
  run 02-db DbApiSample 9330 http_scenarios_db.sh --reset 02
  echo "-- spans received by the collector"
  sleep 1
  python3 /t/tools/otlp_check.py /otel/traces.json'
