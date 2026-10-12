#!/bin/sh
# Checks a /metrics file with Prometheus' promtool (2.53.0), called by
# tools/test_http_docker.sh for each sample.
#
#   sh tools/promtool_check.sh metrics.txt
#
# promtool exits 1 for a format error and 3 for lint problems. Every lint
# problem fails, except one accepted on purpose (decided with the user,
# 2026-10-12): pascal-db-faa 0.14.0 names its pool metric with
# OpenTelemetry's db.client.connection.count, which becomes
# db_client_connection_count, and promtool's naming lint rejects "_count" on a
# metric that isn't a histogram or a summary. The format is right and the
# name is the standard one; promtool 2.53 can't turn that one lint off.
ALLOWED='db_client_connection_count non-histogram and non-summary metrics should not have "_count" suffix'
OUT="$(promtool check metrics < "$1" 2>&1)"
RC=$?
[ -n "$OUT" ] && echo "$OUT"
[ $RC -eq 0 ] && exit 0
[ $RC -ne 3 ] && exit $RC
# Lint only: pass if every line is the accepted one.
if echo "$OUT" | grep -v '^[[:space:]]*$' | grep -qvxF "$ALLOWED"; then
  exit 3
fi
echo "(accepted: the OpenTelemetry name db_client_connection_count)"
exit 0
