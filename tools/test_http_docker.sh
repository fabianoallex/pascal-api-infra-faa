#!/bin/sh
# Builds samples/01-api with plain fpc on Linux (Docker), starts it and runs
# tools/http_scenarios.sh against it: the middlewares over real HTTP.
#
# Horse is used unchanged on Linux (the FPC/Windows workaround of
# tools/prepare_horse.sh isn't needed there). The image needs FPC 3.2.2 and
# curl (tools/ci-test.sh builds one).
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
  mkdir -p /t/u && cp -r /src/src /src/samples /src/tools /src/external /t/
  E=/t/external
  P="-Fu/t/src -Fi/t/src -Fu/t/src/horse -Fu$E/horse/src -Fi$E/horse/src"
  P="$P -Fu$E/pascal-common-faa/src -Fi$E/pascal-common-faa/src -Fu$E/pascal-common-faa/bridges/jsonmapper"
  P="$P -Fu$E/pascal-jsonmapper-faa/src -Fi$E/pascal-jsonmapper-faa/src"
  P="$P -Fu$E/pascal-db-faa/src -Fi$E/pascal-db-faa/src"
  cd /t/samples/01-api
  fpc -v0 -Mdelphi -dUseCThreads $P -FU/t/u -o/t/ApiSample ApiSample.dpr > /t/build.log 2>&1 \
    || { grep -iE "error|fatal" /t/build.log | head -30; exit 1; }
  /t/ApiSample 9310 > /t/server.log 2>&1 &
  for I in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null http://127.0.0.1:9310/health && break; sleep 1; done
  RC=0
  sh /t/tools/http_scenarios.sh 9310 || RC=$?
  kill %1 2>/dev/null || true
  [ $RC -eq 0 ] || { echo "--- server log"; tail -40 /t/server.log; }
  exit $RC'
