#!/usr/bin/env bash
# Verify port_is_free/pick_port skip in-use ports and pick the next one.
# Runs offline — no Postgres required (config has zero databases).

set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
cli="$here/worktrees"

tmp="$(mktemp -d)"
export WORKTREES_HOME="$tmp/state"
work="$tmp/wt"
mkdir -p "$work"

cat > "$work/.worktree-config.json" <<'JSON'
{
  "app": "portcheck",
  "env_file": ".env.worktree",
  "services": {
    "web": { "port_env": "PORT", "port_range": [41000, 41003] }
  }
}
JSON

# Occupy 41000 and 41001 in the background with a real listener.
python3 -c '
import socket, time, sys
socks = []
for p in (41000, 41001):
    s = socket.socket(); s.bind(("127.0.0.1", p)); s.listen(1)
    socks.append(s)
sys.stdout.write("ready\n"); sys.stdout.flush()
time.sleep(30)
' > "$tmp/listener.out" &
listener=$!
trap 'kill $listener 2>/dev/null || true; rm -rf "$tmp"' EXIT

# Wait for the listener to report ready before we run `up`.
for _ in $(seq 1 50); do
  grep -q ready "$tmp/listener.out" 2>/dev/null && break
  sleep 0.1
done

result="$("$cli" up "$work" --json)"
port="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["ports"]["web"])' <<<"$result")"

echo "picked port: $port"
[ "$port" = "41002" ] || { echo "FAIL: expected 41002, got $port"; exit 1; }

# Now occupy 41002 too. Force re-up — it should roll onto 41003.
python3 -c '
import socket, time
s = socket.socket(); s.bind(("127.0.0.1", 41002)); s.listen(1)
time.sleep(30)
' &
listener2=$!
trap 'kill $listener $listener2 2>/dev/null || true; rm -rf "$tmp"' EXIT
sleep 0.3

result2="$("$cli" up "$work" --json --force)"
port2="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["ports"]["web"])' <<<"$result2")"
echo "picked port after re-run: $port2"
[ "$port2" = "41003" ] || { echo "FAIL: expected 41003, got $port2"; exit 1; }

# Occupy 41003 as well — the whole range is now busy, `up` must fail.
python3 -c '
import socket, time
s = socket.socket(); s.bind(("127.0.0.1", 41003)); s.listen(1)
time.sleep(30)
' &
listener3=$!
trap 'kill $listener $listener2 $listener3 2>/dev/null || true; rm -rf "$tmp"' EXIT
sleep 0.3

if "$cli" up "$work" --json --force 2> "$tmp/err"; then
  echo "FAIL: expected 'up' to error when range is exhausted"
  exit 1
fi
grep -q "no free port" "$tmp/err" || { echo "FAIL: wrong error"; cat "$tmp/err"; exit 1; }

echo "OK"
