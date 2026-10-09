#!/bin/sh
# Builds samples/01-api and samples/02-db with plain fpc on Linux (Docker),
# starts each one and runs its HTTP scenarios (tools/http_scenarios.sh, the
# middlewares; tools/http_scenarios_db.sh, SQLite through pascal-db-faa's
# SQLdb adapter, which loads Debian's libsqlite3.so.0).
#
# Horse is used unchanged (external/horse, 3.3.12). The image needs FPC 3.2.2 and
# curl, libsqlite3-0 and openapi-spec-validator (tools/ci-test.sh builds one).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${FPC_IMAGE:-pascalapi-fpc322}"
MOUNT="$ROOT"
command -v cygpath >/dev/null 2>&1 && MOUNT="$(cygpath -w "$ROOT")"

cd "$ROOT"
for D in pascal-common-faa pascal-jsonmapper-faa pascal-db-faa horse; do
  [ -d "external/$D/src" ] || { echo "external/$D is empty: git submodule update --init"; exit 1; }
done

MSYS_NO_PATHCONV=1 docker run --rm -v "$MOUNT:/src:ro" "$IMAGE" sh -c '
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
    OPENAPI_OUT=/t/openapi-$2.json sh /t/tools/$4 $3 || RC=$?
    # The document each sample serves, checked against the OpenAPI 3.0 spec.
    if [ $RC -eq 0 ]; then
      python3 -m openapi_spec_validator /t/openapi-$2.json || RC=$?
    fi
    kill $PID 2>/dev/null || true
    [ $RC -eq 0 ] || { echo "--- server log"; tail -40 /t/server-$2.log; exit $RC; }
  }
  echo "-- samples/01-api"
  run 01-api ApiSample 9310 http_scenarios.sh
  echo "-- samples/02-db"
  run 02-db DbApiSample 9330 http_scenarios_db.sh --reset
  RC=0
  exit $RC'
