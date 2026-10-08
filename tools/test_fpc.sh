#!/bin/sh
# Regenerates the FPCUnit mirrors from the DUnitX masters, then builds and
# runs the unit suite on FPC (Windows, through lazbuild). Acceptance
# criterion: 0 errors, 0 failures and "0 unfreed memory blocks" (heaptrc).
#
# The Delphi side has no command-line equivalent: Delphi Community Edition
# doesn't compile outside the IDE. Run tests\Unit\PascalApi.UnitTests.dproj
# from the IDE (PascalApi.groupproj).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAZBUILD="${LAZBUILD:-lazbuild}"
command -v "$LAZBUILD" >/dev/null 2>&1 || LAZBUILD=/c/lazarus4.0/lazbuild.exe

cd "$ROOT"
python tools/gen_fpc_mirror.py
cd tests/Unit/fpc
# Never pipe lazbuild into head/Select-Object: when the pipe closes early the
# compiler hangs (seen in pascal-dfe-broker). Always redirect to a file.
if ! "$LAZBUILD" -B PascalApiUnitTestsFpc.lpi > build.log 2>&1; then
  grep -E "Error|Fatal" build.log | head -30
  exit 1
fi
./PascalApiUnitTestsFpc.exe --all --format=plain > run.log 2>&1 || true
grep -E "^Number of|unfreed" run.log
grep -A4 "Message:" run.log | head -40 || true
grep -qE "^Number of errors: +0$" run.log && grep -qE "^Number of failures: +0$" run.log && grep -qE "^0 unfreed memory blocks" run.log
