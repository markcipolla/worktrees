#!/usr/bin/env bash
# A worktree name long enough to blow past Postgres's 63-byte identifier limit
# must still get one database per environment. Before fit_identifier() the
# truncated names collided and both environments shared a single database.
# Requires a reachable local Postgres.

set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
cli="$here/worktrees"

tmp="$(mktemp -d)"
export WORKTREES_HOME="$tmp/state"
# 120+ characters, the kind of directory name a task-titled worktree gets.
work="$tmp/a-very-long-worktree-name-that-goes-well-past-the-postgres-identifier-limit-and-then-keeps-going-for-good-measure-indeed"
mkdir -p "$work"

cleanup() {
  "$cli" teardown "$work" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

cat > "$work/.worktree-config.json" <<'JSON'
{
  "app": "lname",
  "env_file": ".env.worktree",
  "databases": {
    "development": {
      "name_env": "DATABASE_NAME",
      "name_template": "{app}_{worktree}_{key}"
    },
    "test": {
      "name_env": "TEST_DATABASE_NAME",
      "name_template": "{app}_{worktree}_{key}"
    }
  }
}
JSON

echo "==> setup"
"$cli" setup "$work" --json >/dev/null

names="$("$cli" status "$work" | python3 -c \
  'import json,sys; d=json.load(sys.stdin)["databases"]; print(d["development"]["name"]); print(d["test"]["name"])')"
dev_name="$(echo "$names" | sed -n 1p)"
test_name="$(echo "$names" | sed -n 2p)"

echo "development: $dev_name"
echo "test:        $test_name"

[ -n "$dev_name" ] && [ -n "$test_name" ] || { echo "missing database names"; exit 1; }

[ "$dev_name" != "$test_name" ] \
  || { echo "development and test share one database name"; exit 1; }

for name in "$dev_name" "$test_name"; do
  [ "${#name}" -le 63 ] || { echo "name exceeds 63 bytes: $name"; exit 1; }
done

echo "==> both databases exist separately"
for name in "$dev_name" "$test_name"; do
  psql -Atc "select 1 from pg_database where datname = '$name'" postgres | grep -q '^1$' \
    || { echo "database was not created: $name"; exit 1; }
done

count="$(psql -Atc "select count(*) from pg_database where datname in ('$dev_name', '$test_name')" postgres)"
[ "$count" = "2" ] || { echo "expected 2 databases, found $count"; exit 1; }

echo "==> teardown"
"$cli" teardown "$work" >/dev/null

for name in "$dev_name" "$test_name"; do
  psql -Atc "select 1 from pg_database where datname = '$name'" postgres | grep -q '^1$' \
    && { echo "database survived teardown: $name"; exit 1; }
done

echo "OK"
