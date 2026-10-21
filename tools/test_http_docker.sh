#!/bin/sh
# Builds samples/01-api, samples/02-db and samples/03-tenants with plain fpc
# on Linux (Docker), starts each one and runs its HTTP scenarios
# (tools/http_scenarios.sh, the middlewares; tools/http_scenarios_db.sh,
# SQLite through pascal-db-faa's SQLdb adapter, which loads Debian's
# libsqlite3.so.0; tools/http_scenarios_tenants.sh, multi-tenant). Sample 03
# has no MCP endpoint; its spans (tenant.id) are checked with the others.
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
#
# JWT keys: sample 03 runs twice more, its signing keys generated and
# rotated in seconds (tools/http_scenarios_jwt_rotation.sh, two instances
# on one store): in the control database, then in a Redis
# (REDIS_IMAGE, redis:7.2-alpine) on the same network.
#
# PostgreSQL: samples 02 and 03 run again on a PostgreSQL (PG_IMAGE,
# postgres:17) on the same network (DB_ENGINE=postgresql; the image needs
# libpq5): their scenarios, sample 03's --check-key-store and its rotation
# in the database (two instances on one control database). SQLite took statements PostgreSQL refuses (pascal-db-faa's
# gotcha 54) and hid a race (0.20.1): a run on SQLite alone doesn't show
# them. pg_isready over TCP: during its first start the image's server
# listens on the socket only, then restarts.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${FPC_IMAGE:-pascalapi-fpc322}"
MOUNT="$ROOT"
command -v cygpath >/dev/null 2>&1 && MOUNT="$(cygpath -w "$ROOT")"

cd "$ROOT"
for D in pascal-common-faa pascal-jsonmapper-faa pascal-db-faa pascal-redis-faa horse; do
  [ -d "external/$D/src" ] || { echo "external/$D is empty: git submodule update --init"; exit 1; }
done

COLLECTOR_IMAGE="${OTEL_COLLECTOR_IMAGE:-otel/opentelemetry-collector-contrib:0.111.0}"
REDIS_IMAGE="${REDIS_IMAGE:-redis:7.2-alpine}"
PG_IMAGE="${PG_IMAGE:-postgres:17}"
NAME="pascalapi-otel-$$"
cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker rm -f "$NAME-redis" >/dev/null 2>&1 || true
  docker rm -f "$NAME-pg" >/dev/null 2>&1 || true
  docker network rm "$NAME" >/dev/null 2>&1 || true
  docker volume rm "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker network create "$NAME" >/dev/null
docker volume create "$NAME" >/dev/null
# As root: the file exporter writes to the volume's root, which root owns.
MSYS_NO_PATHCONV=1 docker run -d --name "$NAME" --network "$NAME" --user 0   -v "$NAME:/otel" -v "$MOUNT:/src:ro" "$COLLECTOR_IMAGE" --config /src/tools/otelcol.yaml >/dev/null
docker run -d --name "$NAME-redis" --network "$NAME" "$REDIS_IMAGE" >/dev/null
docker run -d --name "$NAME-pg" --network "$NAME" -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=dbapi_sample "$PG_IMAGE" >/dev/null
PG_READY=""
for I in $(seq 1 60); do
  docker exec "$NAME-pg" pg_isready -q -h 127.0.0.1 -U postgres -d dbapi_sample && { PG_READY=1; break; }
  sleep 1
done
[ -n "$PG_READY" ] || { echo "PostgreSQL didn't start"; docker logs "$NAME-pg" | tail -20; exit 1; }
# Sample 03's databases (the sample creates the tables, not the databases).
for D in control shared tenant_acme tenant_globex; do
  docker exec "$NAME-pg" psql -q -U postgres -c "CREATE DATABASE $D" >/dev/null
done

MSYS_NO_PATHCONV=1 docker run --rm --network "$NAME" -v "$NAME:/otel:ro" -v "$MOUNT:/src:ro"   -e OTEL_EXPORTER_OTLP_ENDPOINT="http://$NAME:4318" -e OTEL_BSP_SCHEDULE_DELAY=200 -e REDIS_HOST="$NAME-redis" -e PG_HOST="$NAME-pg" -e REFRESH_TOKEN_SECONDS=3   "$IMAGE" sh -c '
  set -e
  mkdir -p /t/uApiSample /t/uDbApiSample /t/uTenantApiSample && cp -r /src/src /src/samples /src/tools /src/external /t/
  E=/t/external
  P="-Fu/t/src -Fi/t/src -Fu/t/src/horse -Fu$E/horse/src -Fi$E/horse/src"
  P="$P -Fu$E/pascal-common-faa/src -Fi$E/pascal-common-faa/src -Fu$E/pascal-common-faa/bridges/jsonmapper"
  P="$P -Fu$E/pascal-jsonmapper-faa/src -Fi$E/pascal-jsonmapper-faa/src"
  P="$P -Fu$E/pascal-db-faa/src -Fi$E/pascal-db-faa/src"
  P="$P -Fu$E/pascal-db-faa/adapters/sqldb -Fi$E/pascal-db-faa/adapters/sqldb"
  P="$P -Fu/t/src/redis -Fu$E/pascal-redis-faa/src -Fi$E/pascal-redis-faa/src"
  run() {
    cd /t/samples/$1
    fpc -v0 -Mdelphi -dUseCThreads $P -FU/t/u$2 -o/t/$2 $2.dpr > /t/build-$2.log 2>&1       || { grep -iE "error|fatal" /t/build-$2.log | head -30; exit 1; }
    mkdir -p /t/run-$2 && cd /t/run-$2
    /t/$2 $3 $5 > /t/server-$2.log 2>&1 &
    PID=$!
    for I in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null http://127.0.0.1:$3/ && break; sleep 1; done
    RC=0
    OPENAPI_OUT=/t/openapi-$2.json METRICS_OUT=/t/metrics-$2.txt SERVER_LOG=/t/server-$2.log \
      sh /t/tools/$4 $3 || RC=$?
    # The document each sample serves, checked against the OpenAPI 3.0 spec.
    # No key twice in one object (Swagger UI refuses it; the validator
    # reads JSON with the last key winning), then the spec.
    if [ $RC -eq 0 ]; then
      python3 /t/tools/json_no_duplicate_keys.py /t/openapi-$2.json || RC=$?
    fi
    if [ $RC -eq 0 ]; then
      python3 -m openapi_spec_validator /t/openapi-$2.json || RC=$?
    fi
    # Its /metrics, checked by Prometheus itself (a lint warning also fails,
    # but one: see tools/promtool_check.sh).
    if [ $RC -eq 0 ]; then
      sh /t/tools/promtool_check.sh /t/metrics-$2.txt || RC=$?
    fi
    # The MCP endpoint, driven by the official Python SDK (2026-07-28).
    if [ $RC -eq 0 ] && [ -n "$6" ]; then
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
  echo "-- samples/03-tenants"
  run 03-tenants TenantApiSample 9350 http_scenarios_tenants.sh --reset ""
  # Sample 03 twice more on one key store, keys rotated in seconds (built by
  # the run above; no OpenAPI or metrics checks: same document). The second
  # instance has no --reset: it shares the databases of the first.
  rotation() {
    export JWT_KEY_STORE=$1 JWT_ROTATE_SECONDS=3 JWT_PROPAGATION_SECONDS=2 JWT_RELOAD_SECONDS=1
    mkdir -p /t/run-rotation && cd /t/run-rotation
    /t/TenantApiSample 9351 --reset > /t/server-rotation-$1.log 2>&1 &
    PID1=$!
    for I in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null http://127.0.0.1:9351/ && break; sleep 1; done
    /t/TenantApiSample 9352 > /t/server-rotation2-$1.log 2>&1 &
    PID2=$!
    for I in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null http://127.0.0.1:9352/ && break; sleep 1; done
    RC=0
    CONTROL_DB=""
    # The checks that read the stored secrets open the SQLite file.
    [ "$1" = db ] && [ "${DB_ENGINE:-sqlite}" = sqlite ] && CONTROL_DB=/t/control.sqlite
    CONTROL_DB="$CONTROL_DB" sh /t/tools/http_scenarios_jwt_rotation.sh 9351 9352 || RC=$?
    sleep 1
    kill $PID1 $PID2 2>/dev/null || true
    unset JWT_KEY_STORE JWT_ROTATE_SECONDS JWT_PROPAGATION_SECONDS JWT_RELOAD_SECONDS
    [ $RC -eq 0 ] || { echo "--- server logs"; tail -20 /t/server-rotation-$1.log;
      tail -20 /t/server-rotation2-$1.log; exit $RC; }
  }
  echo "-- samples/03-tenants, generated JWT keys in the database"
  /t/TenantApiSample --check-key-store > /t/check-key-store.log 2>&1 ||
    { cat /t/check-key-store.log; exit 1; }
  tail -1 /t/check-key-store.log
  rotation db
  echo "-- samples/03-tenants, generated JWT keys in Redis"
  rotation redis
  export DB_ENGINE=postgresql DB_HOST=$PG_HOST DB_NAME=dbapi_sample DB_USER=postgres DB_PASSWORD=postgres
  echo "-- samples/02-db on PostgreSQL"
  run 02-db DbApiSample 9332 http_scenarios_db.sh --reset 02
  echo "-- samples/03-tenants on PostgreSQL"
  run 03-tenants TenantApiSample 9353 http_scenarios_tenants.sh --reset ""
  echo "-- samples/03-tenants on PostgreSQL, generated JWT keys in the database"
  /t/TenantApiSample --check-key-store > /t/check-key-store-pg.log 2>&1 ||
    { cat /t/check-key-store-pg.log; exit 1; }
  tail -1 /t/check-key-store-pg.log
  rotation db
  unset DB_ENGINE DB_HOST DB_NAME DB_USER DB_PASSWORD
  echo "-- spans received by the collector"
  sleep 1
  python3 /t/tools/otlp_check.py /otel/traces.json'
