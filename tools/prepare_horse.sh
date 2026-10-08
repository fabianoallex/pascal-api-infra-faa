#!/bin/sh
# Copies external/horse/src to .horse-src, which is what the FPC builds of
# this repository use (samples/01-api/ApiSample.lpi, tools/test_http*.sh).
#
# On Windows it also applies a one-line workaround to Horse.FPC.inc: Horse
# 3.3.2 (72cc45f) picks "const" for its generic comparer when CPU64 and
# WINDOWS, but FPC 3.2.2's rtl-generics declares IEqualityComparer<T> with
# "constref" everywhere, so Horse.Core.Param.Header fails with "No matching
# implementation for interface method Equals(constref ...)". Measured in
# pascal-dfe-broker (simulador/spike-horse/LEIAME.md, 2026-09-20). The
# submodule is never touched; on Linux the copy is unchanged. Delphi uses
# external/horse/src directly. Idempotent.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[ -f external/horse/src/Horse.pas ] || { echo "external/horse is empty: git submodule update --init"; exit 1; }
rm -rf .horse-src && mkdir -p .horse-src && cp -r external/horse/src/. .horse-src/
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    sed -i 's/{\$ELSEIF DEFINED(CPU64) AND DEFINED(WINDOWS)}/{$ELSEIF FALSE}/' .horse-src/Horse.FPC.inc
    grep -q '{$ELSEIF FALSE}' .horse-src/Horse.FPC.inc || { echo "workaround not applied: Horse.FPC.inc changed?"; exit 1; }
    echo "Horse prepared in .horse-src (Windows: Horse.FPC.inc workaround applied)" ;;
  *) echo "Horse prepared in .horse-src (unchanged copy)" ;;
esac
