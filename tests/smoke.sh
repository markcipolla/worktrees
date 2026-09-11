#!/usr/bin/env bash
# End-to-end smoke test. Requires a reachable local Postgres.
# Uses an isolated state dir so it never touches the user's real state.

set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
cli="$here/worktrees"

tmp="$(mktemp -d)"
export WORKTREES_HOME="$tmp/state"
work="$tmp/worktree-a"
mkdir -p "$work"

cleanup() {
  "$cli" down "$work" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

# Minimal config: one service, one database (test only, to keep it cheap).
cat > "$work/.worktree-config.json" <<'JSON'
{
  "app": "smoke",
  "env_file": ".env.worktree",
  "services": {
    "web": { "port_env": "PORT", "port_range": [39000, 39099] }
  },
  "databases": {
    "test": {
      "name_env": "TEST_DATABASE_NAME",
      "url_env":  "TEST_DATABASE_URL",
      "name_template": "{app}_{worktree}_{key}"
    }
  }
}
JSON

echo "==> doctor"
"$cli" doctor

echo "==> up"
"$cli" up "$work" --json

echo "==> env"
"$cli" env "$work"

echo "==> status roundtrip"
name="$("$cli" status "$work" | python3 -c 'import json,sys; print(json.load(sys.stdin)["databases"]["test"]["name"])')"
echo "database name: $name"
psql -Atc "select 1 from pg_database where datname = '$name'" postgres | grep -q '^1$' \
  || { echo "database was not created"; exit 1; }

echo "==> idempotent up"
first="$("$cli" status "$work")"
"$cli" up "$work" --json >/dev/null
second="$("$cli" status "$work")"
[ "$first" = "$second" ] || { echo "up was not idempotent"; exit 1; }

echo "==> down"
"$cli" down "$work"
psql -Atc "select 1 from pg_database where datname = '$name'" postgres | grep -q '^1$' \
  && { echo "database was NOT dropped"; exit 1; } || true

echo "OK"
