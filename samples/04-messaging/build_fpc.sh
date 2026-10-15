#!/bin/sh
# Builds sample 04 with plain fpc (FPC 3.2.2): MessagingSample (Redis and
# AMQP) and, when pascal-pipes-faa is there, PipesJsonSample. The sibling
# libraries aren't dependencies of this repository: point at your clones
# with REDIS_FAA, AMQP_FAA and PIPES_FAA (default: next to this repository).
# Run from anywhere.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
REDIS_FAA="${REDIS_FAA:-$ROOT/../pascal-redis-faa}"
AMQP_FAA="${AMQP_FAA:-$ROOT/../pascal-amqp-faa}"
PIPES_FAA="${PIPES_FAA:-$ROOT/../pascal-pipes-faa}"
HAS_PIPES=0
[ -d "$PIPES_FAA/src" ] && HAS_PIPES=1
# A Windows fpc run from Git Bash needs C:/... paths, not /c/..., and Git
# Bash must not rewrite the -Fu arguments (it did: "Can't find unit Horse").
if command -v cygpath > /dev/null 2>&1; then
  export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
  ROOT="$(cygpath -m "$ROOT")"; REDIS_FAA="$(cygpath -m "$REDIS_FAA")"; AMQP_FAA="$(cygpath -m "$AMQP_FAA")"
  PIPES_FAA="$(cygpath -m "$PIPES_FAA")"
fi
EXT="$ROOT/external"
cd "$HERE"
mkdir -p lib
COMMON="-MDelphi -O1 -vewn -FUlib -FE. -Fi$ROOT/src -Fu$ROOT/src \
  -Fu$EXT/pascal-common-faa/src -Fi$EXT/pascal-common-faa/src \
  -Fu$EXT/pascal-common-faa/bridges/jsonmapper -Fu$EXT/pascal-jsonmapper-faa/src \
  -Fi$EXT/pascal-jsonmapper-faa/src -Fu$EXT/pascal-db-faa/src"
fpc $COMMON -Fu"$ROOT/src/horse" -Fu"$EXT/horse/src" \
  -Fi"$REDIS_FAA/src" -Fu"$REDIS_FAA/src" -Fi"$AMQP_FAA/src" -Fu"$AMQP_FAA/src" \
  MessagingSample.lpr > build.log 2>&1 || { tail -20 build.log; exit 1; }
echo "built $HERE/MessagingSample"
if [ "$HAS_PIPES" = 1 ]; then
  fpc $COMMON -Fi"$PIPES_FAA/src" -Fu"$PIPES_FAA/src" \
    PipesJsonSample.lpr > build_pipes.log 2>&1 || { tail -20 build_pipes.log; exit 1; }
  echo "built $HERE/PipesJsonSample"
else
  echo "skipped PipesJsonSample: no pascal-pipes-faa in $PIPES_FAA (set PIPES_FAA)"
fi
