#!/bin/sh
# Builds the samples with lazbuild (FPC on Windows), starts each one and runs
# its HTTP scenarios against it:
#   samples/01-api  -> tools/http_scenarios.sh     (middlewares)
#   samples/02-db   -> tools/http_scenarios_db.sh  (SQLite through pascal-db-faa)
#
# samples/02-db on FPC loads sqlite3.dll, and it must be sqlite.org's build
# (pascal-db-faa's gotcha 23: Python's lacks the column metadata functions).
# The script copies SQLITE_DLL, or .deps/sqlite3.dll (git-ignored), next to
# the executable; without either, it skips sample 02.
#
# For a Delphi build, skip the build: start the .exe from samples\0N-*\Win32
# (or Win64)\Debug and run the matching scenarios script with its port.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAZBUILD="${LAZBUILD:-lazbuild}"
command -v "$LAZBUILD" >/dev/null 2>&1 || LAZBUILD=/c/lazarus4.0/lazbuild.exe

cd "$ROOT"
sh tools/prepare_horse.sh

# build DIR LPI: lazbuild to DIR/build.log; never pipe lazbuild into head
# (it hangs when the pipe closes).
build() {
  if ! (cd "$1" && "$LAZBUILD" -B "$2" > build.log 2>&1); then
    grep -E "Error|Fatal" "$1/build.log" | head -30
    exit 1
  fi
}

# run DIR EXE PORT SCENARIOS [ARGS]
run() {
  (cd "$1" && "./$2" "$3" $5 > server.log 2>&1 &)
  for I in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null "http://127.0.0.1:$3/" && break; sleep 1; done
  RC=0
  sh "$ROOT/tools/$4" "$3" || RC=$?
  taskkill //F //IM "$2" >/dev/null 2>&1 || pkill -f "$2" 2>/dev/null || true
  [ $RC -eq 0 ] || { echo "--- $1/server.log"; tail -20 "$1/server.log"; exit $RC; }
}

echo "== samples/01-api"
build samples/01-api ApiSample.lpi
run samples/01-api ApiSample.exe 9310 http_scenarios.sh

echo "== samples/02-db"
DLL="${SQLITE_DLL:-.deps/sqlite3.dll}"
if [ ! -f "$DLL" ]; then
  echo "skipped: no sqlite.org sqlite3.dll (set SQLITE_DLL or put one in .deps/sqlite3.dll)"
  exit 0
fi
build samples/02-db DbApiSample.lpi
cp "$DLL" samples/02-db/sqlite3.dll
run samples/02-db DbApiSample.exe 9330 http_scenarios_db.sh --reset
