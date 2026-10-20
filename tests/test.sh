#!/bin/bash
# Fixture tests for agent_usage.py and install/uninstall — no real data, no network.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/agent_usage.py"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
pass=0
ok() { pass=$((pass + 1)); }
mtime() { python3 -c 'import os, sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$1"; }

codex_line() {  # $1 primary %, $2 secondary %, $3 limit_id
  printf '{"timestamp":"2026-10-20T10:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"%s","primary":{"used_percent":%s,"window_minutes":300,"resets_at":9999999156},"secondary":{"used_percent":%s,"window_minutes":10080,"resets_at":9999999656},"plan_type":"plus"}}}\n' "${3:-codex}" "$1" "$2"
}
filler() {  # $1 = number of ~64 KiB lines without rate_limits
  python3 -c 'import sys
pad = "x" * 65536
for i in range(int(sys.argv[1])):
    print("{\"type\":\"response_item\",\"payload\":{\"output\":\"%s\"}}" % pad)' "$1"
}

cat > "$DIR/statusline.json" <<'EOF'
{"rate_limits":{"five_hour":{"used_percentage":12.4,"resets_at":9999999000},"seven_day":{"used_percentage":30.0,"resets_at":9999999100}}}
EOF
mkdir -p "$DIR/sessions/2026/10/20"
{ codex_line 10 5; codex_line 29 24; codex_line 99 99 premium; } > "$DIR/sessions/2026/10/20/rollout-a.jsonl"

T0=$(mtime "$DIR/statusline.json")
T1=$((T0 + 90000))  # +25h: past both stale thresholds
run() { env NOW_EPOCH="${NOW:-$T0}" CLAUDE_STATUS_FILE="${CSF:-$DIR/statusline.json}" CODEX_SESSIONS_DIR="${CSD:-$DIR/sessions}" "$SCRIPT" "$@"; }

# 1) both providers, 4-cell gauge, no timestamp; codex shows primary/secondary from the newest codex-limit line, ignores other limit_ids
out=$(run)
[ "$out" = "claude █░░░ 12%/30% │ codex █░░░ 29%/24%" ] || fail "default format: got '$out'"; ok

# 2) stale markers
out=$(NOW=$T1 run)
[ "$out" = "claude █░░░ 12%/30%* │ codex █░░░ 29%/24%*" ] || fail "stale: got '$out'"; ok

# 3) a provider without data is omitted; empty output when nothing is available
[ "$(CSF=$DIR/none.json run)" = "codex █░░░ 29%/24%" ] || fail "claude missing"; ok
[ "$(CSD=$DIR/none run)" = "claude █░░░ 12%/30%" ] || fail "codex missing"; ok
[ "$(CSF=$DIR/none.json CSD=$DIR/none run)" = "" ] || fail "no sources should print an empty line"; ok

# 3b) the gauge tracks only the 5-hour window; a missing 5-hour value leaves it empty
printf '%s\n' '{"rate_limits":{"seven_day":{"used_percentage":95,"resets_at":9999999999}}}' > "$DIR/no5h.json"
[ "$(CSF=$DIR/no5h.json CSD=$DIR/none run)" = "claude ░░░░ -/95%" ] || fail "missing 5h must not fill the gauge from weekly"; ok

# 3c) a window whose resets_at has passed counts as 0% (data captured before the reset)
printf '%s\n' '{"rate_limits":{"five_hour":{"used_percentage":80,"resets_at":1000},"seven_day":{"used_percentage":40,"resets_at":9999999999}}}' > "$DIR/reset.json"
[ "$(CSF=$DIR/reset.json CSD=$DIR/none run)" = "claude ░░░░ 0%/40%" ] || fail "claude expired 5h window should read 0%"; ok
mkdir -p "$DIR/s6"
printf '%s\n' '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":75.0,"window_minutes":300,"resets_at":1000},"secondary":{"used_percent":31.0,"window_minutes":10080,"resets_at":1001}}}}' > "$DIR/s6/r.jsonl"
[ "$(CSF=$DIR/none.json CSD=$DIR/s6 run)" = "codex ░░░░ 0%/0%" ] || fail "codex expired windows should read 0%"; ok

# 4) missing secondary renders as '-'
mkdir -p "$DIR/s2"
printf '%s\n' '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":40.0},"secondary":null}}}' > "$DIR/s2/r.jsonl"
[ "$(CSF=$DIR/none.json CSD=$DIR/s2 run)" = "codex ██░░ 40%/-" ] || fail "missing secondary"; ok

# 5) rate_limits several tail blocks back, plus a line straddling a block boundary
mkdir -p "$DIR/s3"
{ codex_line 55 44; filler 20; printf 'y%.0s' $(seq 1 1000); echo; } > "$DIR/s3/r.jsonl"
[ "$(CSF=$DIR/none.json CSD=$DIR/s3 run)" = "codex ██░░ 55%/44%" ] || fail "rate_limits beyond first tail block"; ok

# 6) newest file has no rate_limits in range -> falls back to an older file
mkdir -p "$DIR/s4"
codex_line 7 3 > "$DIR/s4/old.jsonl"; touch -d '1 hour ago' "$DIR/s4/old.jsonl"
filler 2 > "$DIR/s4/new.jsonl"
[ "$(CSF=$DIR/none.json CSD=$DIR/s4 run)" = "codex █░░░ 7%/3%" ] || fail "fallback to older session file"; ok

# 7) memory/time stay bounded on a huge session file (only the tail is read)
mkdir -p "$DIR/s5"
{ filler 3000; codex_line 29 24; } > "$DIR/s5/huge.jsonl"   # ~190 MiB
res=$(python3 - "$SCRIPT" "$DIR/s5" <<'PY'
import os, resource, subprocess, sys, time
env = dict(os.environ, CODEX_SESSIONS_DIR=sys.argv[2], CLAUDE_STATUS_FILE="/nonexistent")
t = time.time()
out = subprocess.run([sys.argv[1]], env=env, capture_output=True, text=True).stdout
rss_mb = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss // 1024
print(out.strip(), rss_mb < 100, time.time() - t < 1.0)
PY
)
[ "$res" = "codex █░░░ 29%/24% True True" ] || fail "huge file: got '$res' (want output, rss<100MB, <1s)"; ok

# 8) installer: adds one tab-bar entry, preserves other entries, wraps statusline; idempotent
CFG="$DIR/herdr"; mkdir -p "$CFG"
cat > "$CFG/config.toml" <<'EOF'
onboarding = false

[ui]
status_indicators = "symbols"
tab_bar_right = [
  { type = "command", command = "echo hi", interval_seconds = 10, timeout_seconds = 2 },
]

[theme]
name = "catppuccin"
EOF
cp "$CFG/config.toml" "$DIR/config.orig"
printf '{\n  "model": "x",\n  "statusLine": {"type": "command", "command": "context-mode statusline"}\n}\n' > "$DIR/settings.json"
cp "$DIR/settings.json" "$DIR/settings.orig"
inst() { env HOME="$DIR/home" HERDR_CONFIG_DIR="$CFG" CLAUDE_SETTINGS="$DIR/settings.json" HERDR_BIN_PATH=false sh "$ROOT/$1" >/dev/null; }
mkdir -p "$DIR/home"
inst install.sh; inst install.sh
[ -x "$CFG/agent-usage/agent_usage.py" ] || fail "widget not installed"; ok
n=$(grep -c 'agent-usage/agent_usage.py' "$CFG/config.toml")
[ "$n" = "1" ] || fail "expected exactly one widget entry, got $n"; ok
grep -q 'command = "echo hi"' "$CFG/config.toml" || fail "foreign entry not preserved"; ok
python3 -c 'import sys, tomllib; d = tomllib.load(open(sys.argv[1], "rb")); assert len(d["ui"]["tab_bar_right"]) == 2, d' "$CFG/config.toml" || fail "config.toml invalid"; ok
cmd=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["statusLine"]["command"])' "$DIR/settings.json")
[ "$cmd" = "$CFG/agent-usage/statusline-wrapper.sh" ] || fail "statusline not wrapped: $cmd"; ok

# 9) wrapper captures stdin privately and still runs the original command
cat > "$CFG/agent-usage/statusline-original.sh" <<'EOF'
#!/bin/sh
cat >/dev/null; echo rendered
EOF
out=$(echo '{"rate_limits":{}}' | HOME="$DIR/home" "$CFG/agent-usage/statusline-wrapper.sh")
[ "$out" = "rendered" ] || fail "wrapper did not run original: '$out'"; ok
[ "$(stat -c %a "$DIR/home/.claude/.last-statusline.json")" = "600" ] || fail "capture file should be 0600"; ok

# 10) uninstall restores both files' content and removes the install dir
inst uninstall.sh
cmp -s "$CFG/config.toml" "$DIR/config.orig" || { diff "$DIR/config.orig" "$CFG/config.toml"; fail "config.toml not restored"; }; ok
python3 -c 'import json, sys; a, b = (json.load(open(p)) for p in sys.argv[1:]); assert a == b, (a, b)' "$DIR/settings.json" "$DIR/settings.orig" || fail "settings not restored"; ok
[ ! -e "$CFG/agent-usage" ] || fail "install dir left behind"; ok

# 11) install into a config with [ui] but no tab_bar_right, then uninstall leaves no empty array
cat > "$CFG/config.toml" <<'EOF'
[ui]
status_indicators = "symbols"

[theme]
name = "catppuccin"
EOF
cp "$CFG/config.toml" "$DIR/config.orig"
inst install.sh
python3 -c 'import sys, tomllib; d = tomllib.load(open(sys.argv[1], "rb")); assert len(d["ui"]["tab_bar_right"]) == 1 and d["theme"]["name"] == "catppuccin", d' "$CFG/config.toml" || fail "insert under [ui]"; ok
inst uninstall.sh
cmp -s "$CFG/config.toml" "$DIR/config.orig" || { diff "$DIR/config.orig" "$CFG/config.toml"; fail "empty array not removed on uninstall"; }; ok

echo "PASS ($pass/$pass)"
