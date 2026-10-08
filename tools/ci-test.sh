#!/bin/sh
# Everything CI runs (.github/workflows/ci.yml), also runnable locally with
# Docker: the unit suite on Linux FPC 3.2.2, then samples/01-api over HTTP
# (tools/test_http_docker.sh). Delphi Community Edition can't
# build headless, so the Delphi side is validated in the IDE (see CLAUDE.md,
# "Tests").
#
# FPC image: built here from Debian bookworm's fpc package (3.2.2) and tagged
# pascalapi-fpc322, unless FPC_IMAGE names an existing one.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ -z "${FPC_IMAGE:-}" ]; then
  FPC_IMAGE=pascalapi-fpc322
  docker build -q -t "$FPC_IMAGE" - <<'DOCKERFILE' >/dev/null
FROM debian:bookworm
RUN apt-get update && apt-get install -y --no-install-recommends fpc curl ca-certificates && rm -rf /var/lib/apt/lists/*
DOCKERFILE
fi
export FPC_IMAGE

echo "== unit suite"
sh tools/test_fpc_docker.sh
echo "== HTTP scenarios (samples/01-api)"
sh tools/test_http_docker.sh
