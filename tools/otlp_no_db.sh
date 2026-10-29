#!/bin/sh
# Builds and runs tests/Deps/OtlpNoDb.dpr with plain fpc and a search path
# that has no pascal-db-faa (only src, pascal-common-faa and
# pascal-jsonmapper-faa): PascalApi.Otlp must stay usable by a program
# without a database (0.28.0, asked by pascal-agenda-faa). Acceptance: the
# build passes, the program's checks pass and heaptrc reports 0 unfreed
# blocks.
#
# Usage: sh tools/otlp_no_db.sh [OUT_DIR]   (relative to the repository; .ci/otlpnodb)
# Called by tools/test_fpc.sh (Windows) and tools/test_fpc_docker.sh
# (Linux, CI). FPC: the fpc on the PATH, else Lazarus 4.0's on Windows.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-.ci/otlpnodb}"
FPC="${FPC:-fpc}"
command -v "$FPC" >/dev/null 2>&1 || FPC=/c/lazarus4.0/fpc/3.2.2/bin/x86_64-win64/fpc.exe

cd "$ROOT"
rm -rf "$OUT" && mkdir -p "$OUT"
E=external
P="-Fusrc -Fisrc"
P="$P -Fu$E/pascal-common-faa/src -Fi$E/pascal-common-faa/src"
P="$P -Fu$E/pascal-jsonmapper-faa/src -Fi$E/pascal-jsonmapper-faa/src"
if ! "$FPC" -v0 -Mdelphi $P -FU"$OUT" -gh -gl -o"$OUT/OtlpNoDb" tests/Deps/OtlpNoDb.dpr > "$OUT/build.log" 2>&1; then
  echo "PascalApi.Otlp doesn't build without pascal-db-faa:"
  grep -iE "error|fatal" "$OUT/build.log" | head -20
  exit 1
fi
# heaptrc writes its summary to stderr on Windows and only to a file on Linux.
HEAPTRC="log=$OUT/heap.txt" "$OUT/OtlpNoDb" > "$OUT/run.log" 2>&1 || { cat "$OUT/run.log"; exit 1; }
grep "without pascal-db-faa" "$OUT/run.log"
grep -h "unfreed" "$OUT/run.log" "$OUT/heap.txt" 2>/dev/null | head -1
grep -qhE "^0 unfreed memory blocks" "$OUT/run.log" "$OUT/heap.txt" 2>/dev/null
