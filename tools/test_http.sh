#!/bin/sh
# Builds samples/01-api with lazbuild (FPC on Windows), starts it and runs
# tools/http_scenarios.sh against it.
#
# For a Delphi build of the sample, skip the build: start
# samples\01-api\Win32\Debug\ApiSample.exe (or Win64) and run
#   sh tools/http_scenarios.sh 9310
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAZBUILD="${LAZBUILD:-lazbuild}"
command -v "$LAZBUILD" >/dev/null 2>&1 || LAZBUILD=/c/lazarus4.0/lazbuild.exe
PORT="${PORT:-9310}"

cd "$ROOT"
sh tools/prepare_horse.sh
cd samples/01-api
# Never pipe lazbuild into head: it hangs when the pipe closes. To a file.
if ! "$LAZBUILD" -B ApiSample.lpi > build.log 2>&1; then
  grep -E "Error|Fatal" build.log | head -30
  exit 1
fi
./ApiSample.exe "$PORT" > server.log 2>&1 &
PID=$!
for I in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null "http://127.0.0.1:$PORT/health" && break; sleep 1; done
RC=0
sh "$ROOT/tools/http_scenarios.sh" "$PORT" || RC=$?
kill $PID 2>/dev/null || taskkill //F //IM ApiSample.exe >/dev/null 2>&1 || true
exit $RC
