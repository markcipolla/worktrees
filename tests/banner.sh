#!/usr/bin/env bash
# The banner is what a shell prints when you land in a worktree, so it has to
# be informative when there is an allocation, quiet when there isn't, and
# never able to break the shell it runs in.
# Runs offline — no Postgres required (config has zero databases).

set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
cli="$here/worktrees"

tmp="$(mktemp -d)"
export WORKTREES_HOME="$tmp/state"
work="$tmp/wt"
mkdir -p "$work/app/models"
trap 'rm -rf "$tmp"' EXIT

cat > "$work/.worktree-config.json" <<'JSON'
{
  "app": "bannercheck",
  "env_file": ".env.worktree",
  "services": {
    "web": { "port_env": "PORT", "port_range": [42000, 42099] }
  },
  "commands": {
    "serve": "bin/dev"
  }
}
JSON

echo "==> silent outside any configured directory"
out="$(cd "$tmp" && "$cli" banner)"
[ -z "$out" ] || { echo "FAIL: expected no output, got: $out"; exit 1; }

echo "==> says so when configured but not allocated"
out="$("$cli" banner "$work")"
grep -q "not allocated" <<<"$out" || { echo "FAIL: expected 'not allocated', got: $out"; exit 1; }

"$cli" up "$work" >/dev/null 2>&1
port="$("$cli" status "$work" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ports"]["web"])')"

echo "==> reports ports, commands and env file"
out="$(cd "$work/app/models" && "$cli" banner)"   # found by walking up from a subdir
grep -q "http://localhost:$port" <<<"$out" || { echo "FAIL: missing port; got: $out"; exit 1; }
grep -q '\$PORT'                  <<<"$out" || { echo "FAIL: missing env var name; got: $out"; exit 1; }
grep -q 'bin/dev'                 <<<"$out" || { echo "FAIL: missing serve command; got: $out"; exit 1; }
grep -q '\.env\.worktree'         <<<"$out" || { echo "FAIL: missing env file; got: $out"; exit 1; }

echo "==> a broken config degrades instead of erroring"
broken="$tmp/broken"
mkdir -p "$broken"
echo 'not json at all' > "$broken/.worktree-config.json"
"$cli" banner "$broken" >/dev/null 2>&1 \
  || { echo "FAIL: banner exited non-zero on a malformed config"; exit 1; }

echo "==> shell hook announces a worktree once per visit"
transcript="$(PATH="$here:$PATH" bash --noprofile --norc -c '
  eval "$(worktrees shell-init --shell bash)"
  cd "$1"; echo MARK-enter;  _worktrees_banner
  cd app;  echo MARK-deeper; _worktrees_banner
  cd /tmp; echo MARK-left;   _worktrees_banner
  cd "$1"; echo MARK-return; _worktrees_banner
' bash "$work")"

count_between() {  # lines matching $3 between marker $1 and marker $2
  awk -v start="$1" -v end="$2" -v pat="$3" '
    $0 ~ start { on = 1; next }
    $0 ~ end   { on = 0 }
    on && $0 ~ pat { n++ }
    END { print n + 0 }
  ' <<<"$transcript"
}

[ "$(count_between MARK-enter  MARK-deeper bannercheck)" = "1" ] \
  || { echo "FAIL: no banner on entering the worktree"; echo "$transcript"; exit 1; }
[ "$(count_between MARK-deeper MARK-left   bannercheck)" = "0" ] \
  || { echo "FAIL: banner repeated while moving within the worktree"; echo "$transcript"; exit 1; }
[ "$(count_between MARK-return ENDOFINPUT  bannercheck)" = "1" ] \
  || { echo "FAIL: no banner on returning to the worktree"; echo "$transcript"; exit 1; }

echo "==> WORKTREES_BANNER=0 silences the hook"
quiet="$(PATH="$here:$PATH" WORKTREES_BANNER=0 bash --noprofile --norc -c '
  eval "$(worktrees shell-init --shell bash)"
  cd "$1"; _worktrees_banner
' bash "$work")"
[ -z "$quiet" ] || { echo "FAIL: expected silence, got: $quiet"; exit 1; }

"$cli" down "$work" >/dev/null 2>&1

echo "OK"
