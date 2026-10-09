#!/bin/bash
# Build a throw-away database with every SQL file installed, for the database tests.
# Never point this at the real Supabase project.
#
#   bash tests/db/setup.sh        install 01 .. newest
#   bash tests/db/setup.sh 12     install 01 .. 12 only (to test an upgrade)
#
# Needs PostgreSQL 16 on Linux or WSL (Ubuntu: sudo apt install postgresql-16), run as root.
# Fake Supabase parts (the roles anon / authenticated and auth.uid()) come from supabase_stub.sql.
set -e
UPTO=${1:-99}
PG_BIN=${PG_BIN:-/usr/lib/postgresql/16/bin}
D=${PGTEST_DIR:-/var/tmp/pgtest}
HERE="$(cd "$(dirname "$0")" && pwd)"
SQL_DIR="$HERE/../../database"
P="runuser -u postgres -- $PG_BIN/psql -h $D -p 54329 -X"

if [ ! -d "$D/data" ]; then                     # first run: make and start the scratch server
  mkdir -p "$D"; chown postgres "$D"
  runuser -u postgres -- "$PG_BIN/initdb" -D "$D/data" -A trust >/dev/null
fi
runuser -u postgres -- "$PG_BIN/pg_ctl" -D "$D/data" status >/dev/null 2>&1 || \
  runuser -u postgres -- "$PG_BIN/pg_ctl" -D "$D/data" -o "-p 54329 -k $D -c listen_addresses=''" -l "$D/log" start >/dev/null
sleep 1

$P -q -c "drop database if exists t" -c "create database t" >/dev/null
$P -d t -q -v ON_ERROR_STOP=1 < "$HERE/supabase_stub.sql"
for f in "$SQL_DIR"/[0-9][0-9]_*.sql; do
  n=$(basename "$f"); n=${n%%_*}
  [ $((10#$n)) -gt "$UPTO" ] && break
  out=$($P -d t -q -v ON_ERROR_STOP=1 < "$f" 2>&1 >/dev/null | grep -E "ERROR|FATAL" || true)
  [ -n "$out" ] && { echo "FAILED in $(basename "$f"): $out"; exit 1; }
done
echo "scratch database ready (files up to $UPTO)"
