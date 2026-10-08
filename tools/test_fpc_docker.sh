#!/bin/sh
# Builds and runs the unit suite on Linux FPC inside a Docker container, with
# heaptrc. Acceptance criterion: 0 errors, 0 failures, 0 unfreed blocks.
#
# The repository is mounted read-only and copied inside the container, so
# nothing is written to the working tree. No Lazarus needed: the FPCUnit
# runner only pulls in the LCL GUI on Windows, and plain fpc gets the search
# paths of the dependencies (external/*) directly.
#
# FPC_IMAGE: any image with FPC 3.2.2 on the PATH (default: fpc322-bookworm).
# heaptrc on Linux only writes its summary when given a log file
# (HEAPTRC=log=...), hence the log below.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${FPC_IMAGE:-fpc322-bookworm}"
MOUNT="$ROOT"
command -v cygpath >/dev/null 2>&1 && MOUNT="$(cygpath -w "$ROOT")"

cd "$ROOT"
for D in pascal-common-faa pascal-jsonmapper-faa pascal-db-faa; do
  [ -d "external/$D/src" ] || { echo "external/$D is empty: git submodule update --init"; exit 1; }
done
python tools/gen_fpc_mirror.py --check

MSYS_NO_PATHCONV=1 docker run --rm -v "$MOUNT:/src:ro" "$IMAGE" sh -c '
  set -e
  mkdir -p /t/u && cp -r /src/src /src/tests /src/external /t/
  E=/t/external
  P="-Fu/t/src -Fi/t/src"
  P="$P -Fu$E/pascal-common-faa/src -Fi$E/pascal-common-faa/src -Fu$E/pascal-common-faa/bridges/jsonmapper"
  P="$P -Fu$E/pascal-jsonmapper-faa/src -Fi$E/pascal-jsonmapper-faa/src"
  P="$P -Fu$E/pascal-db-faa/src -Fi$E/pascal-db-faa/src"
  cd /t/tests/Unit/fpc
  fpc -v0 -Mdelphi $P -FU/t/u -gh -gl -o/t/runner PascalApiUnitTestsFpc.lpr > /t/build.log 2>&1 \
    || { grep -iE "error|fatal" /t/build.log | head -30; exit 1; }
  cd /t
  HEAPTRC="log=/t/heap.txt" ./runner --all --format=plain > /t/run.log 2>&1 || true
  grep -E "^Number of" /t/run.log
  grep "unfreed" /t/heap.txt
  grep -A4 "Message:" /t/run.log | head -40 || true
  grep -qE "^Number of errors: +0$" /t/run.log && grep -qE "^Number of failures: +0$" /t/run.log \
    && grep -qE "^0 unfreed memory blocks" /t/heap.txt'
