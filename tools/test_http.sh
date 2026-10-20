#!/bin/sh
# Builds the samples with lazbuild (FPC on Windows), starts each one and runs
# its HTTP scenarios against it:
#   samples/01-api  -> tools/http_scenarios.sh     (middlewares)
#   samples/02-db   -> tools/http_scenarios_db.sh  (SQLite through pascal-db-faa;
#                      then PostgreSQL: a throwaway postgres:17 container on
#                      port 55434 (PG_PORT) when Docker is there, and the
#                      64-bit libpq.dll of the newest install under
#                      C:\Program Files\PostgreSQL (PG_CLIENT to choose another))
#   samples/03-tenants -> tools/http_scenarios_tenants.sh (multi-tenant, SQLite)
#   samples/03-tenants with JWT_KEY_STORE=db, then redis, two instances each
#                      -> tools/http_scenarios_jwt_rotation.sh (generated signing
#                         keys, rotated in seconds). Redis: REDIS_HOST/REDIS_PORT,
#                         or a throwaway redis:7.2-alpine container when Docker
#                         is there; neither: the redis run is skipped.
#
# samples/02-db and 03-tenants on FPC load sqlite3.dll, and it must be sqlite.org's build
# (pascal-db-faa's gotcha 23: Python's lacks the column metadata functions).
# The script copies SQLITE_DLL, or .deps/sqlite3.dll (git-ignored), next to
# the executable; without either, it skips samples 02 and 03.
#
# For a Delphi build, skip the build: start the .exe from samples\0N-*\Win32
# (or Win64)\Debug and run the matching scenarios script with its port, with
# REFRESH_TOKEN_SECONDS=3 in the server's environment (the scenarios check a
# refresh token's expiry only when it is that short).
set -e
# The refresh tokens of samples 01 and 03 expire in seconds, so the
# scenarios see one expire without a long wait.
export REFRESH_TOKEN_SECONDS=3
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAZBUILD="${LAZBUILD:-lazbuild}"
command -v "$LAZBUILD" >/dev/null 2>&1 || LAZBUILD=/c/lazarus4.0/lazbuild.exe

cd "$ROOT"

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
  SERVER_LOG="$ROOT/$1/server.log" sh "$ROOT/tools/$4" "$3" || RC=$?
  taskkill //F //IM "$2" >/dev/null 2>&1 || pkill -f "$2" 2>/dev/null || true
  [ $RC -eq 0 ] || { echo "--- $1/server.log"; tail -20 "$1/server.log"; exit $RC; }
}

echo "== samples/01-api"
build samples/01-api ApiSample.lpi
run samples/01-api ApiSample.exe 9310 http_scenarios.sh

echo "== samples/02-db"
DLL="${SQLITE_DLL:-.deps/sqlite3.dll}"
if [ ! -f "$DLL" ]; then
  echo "skipped (02 and 03): no sqlite.org sqlite3.dll (set SQLITE_DLL or put one in .deps/sqlite3.dll)"
  exit 0
fi
build samples/02-db DbApiSample.lpi
cp "$DLL" samples/02-db/sqlite3.dll
run samples/02-db DbApiSample.exe 9330 http_scenarios_db.sh --reset

echo "== samples/02-db on PostgreSQL"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  if [ -z "$PG_CLIENT" ]; then
    PG_CLIENT="$(ls -d "/c/Program Files/PostgreSQL/"*/bin/libpq.dll 2>/dev/null | sort -V | tail -1)"
    [ -n "$PG_CLIENT" ] && PG_CLIENT="$(cygpath -w "$PG_CLIENT")"
  fi
  if [ -n "$PG_CLIENT" ]; then
    PG_CONTAINER="pascalapi-pg-$$"
    docker run -d --rm --name "$PG_CONTAINER" -p "${PG_PORT:-55434}:5432" -e POSTGRES_PASSWORD=postgres \
      -e POSTGRES_DB=dbapi_sample "${PG_IMAGE:-postgres:17}" >/dev/null
    # pg_isready over TCP: during its first start the image's server listens
    # on the socket only, then restarts.
    for I in $(seq 1 60); do
      docker exec "$PG_CONTAINER" pg_isready -q -h 127.0.0.1 -U postgres -d dbapi_sample && break
      sleep 1
    done
    export DB_ENGINE=postgresql DB_HOST=127.0.0.1 DB_PORT="${PG_PORT:-55434}" DB_NAME=dbapi_sample
    export DB_USER=postgres DB_PASSWORD=postgres PG_CLIENT
    RC=0
    ( run samples/02-db DbApiSample.exe 9332 http_scenarios_db.sh --reset ) || RC=$?
    unset DB_ENGINE DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD
    docker rm -f "$PG_CONTAINER" >/dev/null 2>&1
    [ $RC -eq 0 ] || exit $RC
  else
    echo "skipped: no libpq.dll under C:/Program Files/PostgreSQL (set PG_CLIENT)"
  fi
else
  echo "skipped: no Docker"
fi

echo "== samples/03-tenants"
build samples/03-tenants TenantApiSample.lpi
cp "$DLL" samples/03-tenants/sqlite3.dll
run samples/03-tenants TenantApiSample.exe 9350 http_scenarios_tenants.sh --reset

# rotation MODE: sample 03 twice on one key store (the second without
# --reset, so it shares the first's databases), keys rotated in seconds.
rotation() {
  export JWT_KEY_STORE=$1 JWT_ROTATE_SECONDS=3 JWT_PROPAGATION_SECONDS=2 JWT_RELOAD_SECONDS=1
  export JWT_REDIS_PREFIX="pascalapi-test-$$-"
  (cd samples/03-tenants && ./TenantApiSample.exe 9351 --reset > server.log 2>&1 &)
  for I in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null "http://127.0.0.1:9351/" && break; sleep 1; done
  (cd samples/03-tenants && ./TenantApiSample.exe 9352 > server2.log 2>&1 &)
  for I in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null "http://127.0.0.1:9352/" && break; sleep 1; done
  RC=0
  CONTROL_DB=""
  [ "$1" = db ] && CONTROL_DB="samples/03-tenants/control.sqlite"
  CONTROL_DB="$CONTROL_DB" sh tools/http_scenarios_jwt_rotation.sh 9351 9352 || RC=$?
  taskkill //F //IM TenantApiSample.exe >/dev/null 2>&1 || pkill -f TenantApiSample 2>/dev/null || true
  unset JWT_KEY_STORE JWT_ROTATE_SECONDS JWT_PROPAGATION_SECONDS JWT_RELOAD_SECONDS JWT_REDIS_PREFIX
  [ $RC -eq 0 ] || { echo "--- server.log"; tail -20 samples/03-tenants/server.log;
    echo "--- server2.log"; tail -20 samples/03-tenants/server2.log; exit $RC; }
}

echo "== samples/03-tenants, generated JWT keys in the database"
# The race two instances run into, as the database adapter sees it.
(cd samples/03-tenants && ./TenantApiSample.exe --check-key-store > check.log 2>&1) ||
  { cat samples/03-tenants/check.log; exit 1; }
tail -1 samples/03-tenants/check.log
rotation db

echo "== samples/03-tenants, generated JWT keys in Redis"
REDIS_CONTAINER=""
if [ -z "$REDIS_HOST" ] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  REDIS_CONTAINER="pascalapi-redis-$$"
  docker run -d --rm --name "$REDIS_CONTAINER" -p 6391:6379 redis:7.2-alpine >/dev/null
  export REDIS_HOST=127.0.0.1 REDIS_PORT=6391
  for I in 1 2 3 4 5 6 7 8 9 10; do
    docker exec "$REDIS_CONTAINER" redis-cli ping >/dev/null 2>&1 && break; sleep 1
  done
fi
if [ -n "$REDIS_HOST" ]; then
  rotation redis
else
  echo "skipped: no REDIS_HOST and no Docker"
fi
[ -n "$REDIS_CONTAINER" ] && docker rm -f "$REDIS_CONTAINER" >/dev/null 2>&1
true
