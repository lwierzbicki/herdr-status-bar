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

capture() {  # $1 dir, $2 file, $3 rate_limits JSON
  mkdir -p "$DIR/$1"; printf '{"session_id":"%s","rate_limits":%s}\n' "$2" "$3" > "$DIR/$1/$2.json"
}
capture claude a '{"five_hour":{"used_percentage":12.4,"resets_at":9999999000},"seven_day":{"used_percentage":30.0,"resets_at":9999999100}}'
mkdir -p "$DIR/sessions/2026/10/20"
{ codex_line 10 5; codex_line 29 24; codex_line 99 99 premium; } > "$DIR/sessions/2026/10/20/rollout-a.jsonl"

T0=$(mtime "$DIR/claude/a.json")
T1=$((T0 + 90000))  # +25h: past both stale thresholds
run() { # auth, config, and quota cache point at the fixture dir so a real login cannot leak in
  env NOW_EPOCH="${NOW:-$T0}" CLAUDE_STATUS_DIR="${CSF:-$DIR/claude}" CODEX_SESSIONS_DIR="${CSD:-$DIR/sessions}" \
    AGENT_USAGE_CONFIG="${AUC:-$DIR/no-config.toml}" GROK_AUTH_FILE="${GAF:-$DIR/no-grok-auth.json}" \
    OPENCODE_AUTH_FILE="${OAF:-$DIR/no-oc-auth.json}" QUOTA_CACHE_FILE="${QCF:-$DIR/quota-cache.json}" \
    GROK_FETCH_CMD="${GFC-}" OPENCODE_GO_FETCH_CMD="${OFC-}" ZAI_FETCH_CMD="${ZFC-}" \
    GROK_BILLING_URL="${GBU-}" OPENCODE_GO_USAGE_URL="${OGU-}" ZAI_QUOTA_URL="${ZQU-}" \
    "$SCRIPT" "$@"
}

# 1) both providers, numbers only, no timestamp; codex shows primary/secondary from the newest codex-limit line, ignores other limit_ids
out=$(run)
[ "$out" = "claude 12%/30% │ codex 29%/24%" ] || fail "default format: got '$out'"; ok

# 2) stale markers
out=$(NOW=$T1 run)
[ "$out" = "claude 12%/30%* │ codex 29%/24%*" ] || fail "stale: got '$out'"; ok

# 3) a provider without data is omitted; empty output when nothing is available
[ "$(CSF=$DIR/none run)" = "codex 29%/24%" ] || fail "claude missing"; ok
[ "$(CSD=$DIR/none run)" = "claude 12%/30%" ] || fail "codex missing"; ok
[ "$(CSF=$DIR/none CSD=$DIR/none run)" = "" ] || fail "no sources should print an empty line"; ok

# 3b) a missing 5-hour value stays '-', it is not filled from the weekly window
capture no5h a '{"seven_day":{"used_percentage":95,"resets_at":9999999999}}'
[ "$(CSF=$DIR/no5h CSD=$DIR/none run)" = "claude -/95%" ] || fail "missing 5h must stay blank"; ok

# 3c) a window whose resets_at has passed counts as 0% (data captured before the reset)
capture reset a '{"five_hour":{"used_percentage":80,"resets_at":1000},"seven_day":{"used_percentage":40,"resets_at":9999999999}}'
[ "$(CSF=$DIR/reset CSD=$DIR/none run)" = "claude 0%/40%" ] || fail "claude expired 5h window should read 0%"; ok

# 3d) concurrent sessions merge per window: an idle session (old 5h window gone, lower weekly)
# and one from the previous 5h window must not hide the fresh session's numbers
capture merge fresh '{"five_hour":{"used_percentage":18,"resets_at":9999999000},"seven_day":{"used_percentage":6,"resets_at":9999999100}}'
capture merge idle '{"seven_day":{"used_percentage":3,"resets_at":9999999100}}'
capture merge old '{"five_hour":{"used_percentage":70,"resets_at":9999981000},"seven_day":{"used_percentage":2,"resets_at":9999999100}}'
[ "$(CSF=$DIR/merge CSD=$DIR/none run)" = "claude 18%/6%" ] || fail "merge: got '$(CSF=$DIR/merge CSD=$DIR/none run)'"; ok
# resets_at jitter within one window still counts as the same window: highest usage wins
capture jitter a '{"five_hour":{"used_percentage":40,"resets_at":9999999000}}'
capture jitter b '{"five_hour":{"used_percentage":35,"resets_at":9999999030}}'
[ "$(CSF=$DIR/jitter CSD=$DIR/none run)" = "claude 40%/-" ] || fail "jitter: got '$(CSF=$DIR/jitter CSD=$DIR/none run)'"; ok
mkdir -p "$DIR/s6"
printf '%s\n' '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":75.0,"window_minutes":300,"resets_at":1000},"secondary":{"used_percent":31.0,"window_minutes":10080,"resets_at":1001}}}}' > "$DIR/s6/r.jsonl"
[ "$(CSF=$DIR/none CSD=$DIR/s6 run)" = "codex 0%/0%" ] || fail "codex expired windows should read 0%"; ok

# 4) missing secondary renders as '-'
mkdir -p "$DIR/s2"
printf '%s\n' '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":40.0},"secondary":null}}}' > "$DIR/s2/r.jsonl"
[ "$(CSF=$DIR/none CSD=$DIR/s2 run)" = "codex 40%/-" ] || fail "missing secondary"; ok

# 5) rate_limits several tail blocks back, plus a line straddling a block boundary
mkdir -p "$DIR/s3"
{ codex_line 55 44; filler 20; printf 'y%.0s' $(seq 1 1000); echo; } > "$DIR/s3/r.jsonl"
[ "$(CSF=$DIR/none CSD=$DIR/s3 run)" = "codex 55%/44%" ] || fail "rate_limits beyond first tail block"; ok

# 6) newest file has no rate_limits in range -> falls back to an older file
mkdir -p "$DIR/s4"
codex_line 7 3 > "$DIR/s4/old.jsonl"; touch -d '1 hour ago' "$DIR/s4/old.jsonl"
filler 2 > "$DIR/s4/new.jsonl"
[ "$(CSF=$DIR/none CSD=$DIR/s4 run)" = "codex 7%/3%" ] || fail "fallback to older session file"; ok

# 7) memory/time stay bounded on a huge session file (only the tail is read)
mkdir -p "$DIR/s5"
{ filler 3000; codex_line 29 24; } > "$DIR/s5/huge.jsonl"   # ~190 MiB
res=$(python3 - "$SCRIPT" "$DIR/s5" <<'PY'
import os, resource, subprocess, sys, time
env = dict(os.environ, CODEX_SESSIONS_DIR=sys.argv[2], CLAUDE_STATUS_DIR="/nonexistent",
              GROK_AUTH_FILE="/nonexistent", OPENCODE_AUTH_FILE="/nonexistent",
              AGENT_USAGE_CONFIG="/nonexistent", QUOTA_CACHE_FILE="/nonexistent",
              GROK_FETCH_CMD="", OPENCODE_GO_FETCH_CMD="", ZAI_FETCH_CMD="",
              GROK_BILLING_URL="", OPENCODE_GO_USAGE_URL="", ZAI_QUOTA_URL="")
t = time.time()
out = subprocess.run([sys.argv[1]], env=env, capture_output=True, text=True).stdout
rss_mb = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss // 1024
print(out.strip(), rss_mb < 100, time.time() - t < 1.0)
PY
)
[ "$res" = "codex 29%/24% True True" ] || fail "huge file: got '$res' (want output, rss<100MB, <1s)"; ok

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
CAP="$DIR/home/.claude/.agent-usage"
out=$(echo '{"session_id":"s-1","rate_limits":{}}' | HOME="$DIR/home" "$CFG/agent-usage/statusline-wrapper.sh")
[ "$out" = "rendered" ] || fail "wrapper did not run original: '$out'"; ok
[ "$(stat -c %a "$CAP/s-1.json")" = "600" ] || fail "per-session capture file should be 0600"; ok
# each session keeps its own capture, so concurrent sessions do not overwrite each other
echo '{"session_id":"s-2","rate_limits":{}}' | HOME="$DIR/home" "$CFG/agent-usage/statusline-wrapper.sh" >/dev/null
[ -f "$CAP/s-1.json" ] && [ -f "$CAP/s-2.json" ] || fail "sessions should get separate captures"; ok
# a fresh session (/clear) renders before its first API response, without rate_limits: nothing is published
out=$(echo '{"session_id":"s-3"}' | HOME="$DIR/home" "$CFG/agent-usage/statusline-wrapper.sh")
[ "$out" = "rendered" ] || fail "wrapper did not run original without rate_limits: '$out'"; ok
[ ! -e "$CAP/s-3.json" ] || fail "capture without rate_limits should not be published"; ok
# captures untouched for over 7 days are pruned
touch -d '8 days ago' "$CAP/s-2.json"
echo '{"session_id":"s-1","rate_limits":{}}' | HOME="$DIR/home" "$CFG/agent-usage/statusline-wrapper.sh" >/dev/null
[ ! -e "$CAP/s-2.json" ] || fail "old capture not pruned"; ok
[ "$(ls -A "$CAP")" = "s-1.json" ] || fail "wrapper left extra files: $(ls -A "$CAP")"; ok

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

# 12) a provider set false in the config is omitted even when it has data
printf 'claude = false\n' > "$DIR/providers.toml"
out=$(AUC="$DIR/providers.toml" run)
[ "$out" = "codex 29%/24%" ] || fail "disabled claude: got '$out'"; ok

# 13) grok credits are the weekly window only
printf '%s\n' '{"config":{"creditUsagePercent":50,"key":"super-secret-token"}}' > "$DIR/grok.json"
out=$(CSF=$DIR/none CSD=$DIR/none GFC="cat $DIR/grok.json" QCF="$DIR/quota-cache.json" run)
[ "$out" = "grok -/50%" ] || fail "grok: got '$out'"; ok
[ "$(stat -c %a "$DIR/quota-cache.json")" = "600" ] || fail "quota cache should be 0600"; ok
grep -q super-secret-token "$DIR/quota-cache.json" && fail "quota cache stored a token"; ok
python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["grok"]; assert d["short"] is None and d["long"]==50 and "key" not in d' "$DIR/quota-cache.json" || fail "quota cache shape"; ok

# 14) a failed refresh shows the last cache; * only after 6h
python3 -c 'import json,sys; json.dump({"grok":{"short":50,"long":None,"short_resets_at":None,"long_resets_at":None,"fetched_at":float(sys.argv[1])}}, open(sys.argv[2],"w"))' "$((T0 - 7 * 3600))" "$DIR/stale-cache.json"
out=$(CSF=$DIR/none CSD=$DIR/none QCF="$DIR/stale-cache.json" GFC="" run)
[ "$out" = "grok -/50%*" ] || fail "stale grok cache: got '$out'"; ok

# 16) grok billing sends the token as a header, never in the URL or the cache
python3 - "$DIR" <<'PY' &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
root = sys.argv[1]
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def do_GET(self):
        json.dump({
            "path": self.path,
            "authorization": self.headers.get("Authorization"),
            "xai": self.headers.get("x-xai-token-auth"),
        }, open(root + "/grok-request.json", "w"))
        body = b'{"config":{"creditUsagePercent":50}}'
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()
    def log_message(self, *args):
        return
server = HTTPServer(("127.0.0.1", 0), Handler)
server.timeout = 0.2
open(root + "/grok-port", "w").write(str(server.server_address[1]))
deadline = __import__("time").time() + 8
while __import__("time").time() < deadline and not __import__("os").path.exists(root + "/grok-request.json"):
    server.handle_request()
PY
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$DIR/grok-port" ] && break; sleep 0.05; done
sleep 0.1
python3 -c 'import json,sys; json.dump({"https://auth.x.ai::cli":{"key":"super-secret-token","expires_at":9999999999}}, open(sys.argv[1],"w"))' "$DIR/grok-auth.json"
out=$(CSF=$DIR/none CSD=$DIR/none GAF="$DIR/grok-auth.json" GBU="http://127.0.0.1:$(cat "$DIR/grok-port")/v1/billing?format=credits" QCF="$DIR/grok-http-cache.json" GFC="" run)
[ "$out" = "grok -/50%" ] || fail "grok http: got '$out'"; ok
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["authorization"]=="Bearer super-secret-token", d; assert "super-secret-token" not in d["path"]; assert d["xai"]=="xai-grok-cli"' "$DIR/grok-request.json" || fail "grok request"; ok
grep -q super-secret-token "$DIR/grok-http-cache.json" && fail "http cache stored the token"; ok

# 17) opencode go shows 5-hour/weekly and ignores the monthly window
printf '%s\n' '{"usage":{"rolling":{"usedPercent":40},"weekly":{"usedPercent":75},"monthly":{"usedPercent":99},"key":"super-secret-token"}}' > "$DIR/go.json"
out=$(CSF=$DIR/none CSD=$DIR/none OFC="cat $DIR/go.json" QCF="$DIR/go-cache.json" run)
[ "$out" = "go 40%/75%" ] || fail "opencode go: got '$out'"; ok
grep -q super-secret-token "$DIR/go-cache.json" && fail "go cache stored a token"; ok
python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["opencode_go"]; assert d["short"]==40 and d["long"]==75' "$DIR/go-cache.json" || fail "go cache shape"; ok

# 18) opencode go usage call sends the key as a bearer header, not in the URL or cache
python3 - "$DIR" <<'PY' &
import json, os, time
from http.server import BaseHTTPRequestHandler, HTTPServer
root = __import__("sys").argv[1]
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def do_GET(self):
        json.dump({
            "path": self.path,
            "authorization": self.headers.get("Authorization"),
        }, open(root + "/go-request.json", "w"))
        body = b'{"usage":{"rolling":{"usedPercent":40},"weekly":{"usedPercent":75},"monthly":{"usedPercent":99}}}'
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()
    def log_message(self, *args):
        return
server = HTTPServer(("127.0.0.1", 0), Handler)
server.timeout = 0.2
open(root + "/go-port", "w").write(str(server.server_address[1]))
deadline = time.time() + 8
while time.time() < deadline and not os.path.exists(root + "/go-request.json"):
    server.handle_request()
PY
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$DIR/go-port" ] && break; sleep 0.05; done
sleep 0.1
python3 -c 'import json,sys; json.dump({"opencode-go":{"type":"api","key":"super-secret-token"}}, open(sys.argv[1],"w"))' "$DIR/go-auth.json"
out=$(CSF=$DIR/none CSD=$DIR/none OAF="$DIR/go-auth.json" OGU="http://127.0.0.1:$(cat "$DIR/go-port")/zen/go/v1/usage" QCF="$DIR/go-http-cache.json" OFC="" run)
[ "$out" = "go 40%/75%" ] || fail "go http: got '$out'"; ok
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["authorization"]=="Bearer super-secret-token", d; assert "super-secret-token" not in d["path"]' "$DIR/go-request.json" || fail "go request"; ok
grep -q super-secret-token "$DIR/go-http-cache.json" && fail "go http cache stored the token"; ok

# 22) grok falls back to the OpenCode xAI OAuth token when the Grok CLI login is absent
python3 - "$DIR" <<'PY' &
import json, os, time
from http.server import BaseHTTPRequestHandler, HTTPServer
root = __import__("sys").argv[1]
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def do_GET(self):
        json.dump({"authorization": self.headers.get("Authorization")}, open(root + "/xai-request.json", "w"))
        body = b'{"config":{"creditUsagePercent":50}}'
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()
    def log_message(self, *args):
        return
server = HTTPServer(("127.0.0.1", 0), Handler)
server.timeout = 0.2
open(root + "/xai-port", "w").write(str(server.server_address[1]))
deadline = time.time() + 8
while time.time() < deadline and not os.path.exists(root + "/xai-request.json"):
    server.handle_request()
PY
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$DIR/xai-port" ] && break; sleep 0.05; done
sleep 0.1
python3 -c 'import json,sys; json.dump({"xai":{"type":"oauth","access":"opencode-xai-token","refresh":"r","expires":9999999999000}}, open(sys.argv[1],"w"))' "$DIR/xai-auth.json"
out=$(CSF=$DIR/none CSD=$DIR/none GAF="$DIR/no-grok-auth.json" OAF="$DIR/xai-auth.json" GBU="http://127.0.0.1:$(cat "$DIR/xai-port")/v1/billing?format=credits" QCF="$DIR/xai-cache.json" GFC="" run)
[ "$out" = "grok -/50%" ] || fail "opencode xai grok: got '$out'"; ok
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["authorization"]=="Bearer opencode-xai-token", d' "$DIR/xai-request.json" || fail "opencode xai request"; ok

# 21) a disabled quota provider is not fetched
printf 'grok = false\nopencode_go = false\n' > "$DIR/off.toml"
out=$(AUC="$DIR/off.toml" GFC="touch $DIR/grok-fetched-off; echo '{\"config\":{\"creditUsagePercent\":50}}'" OFC="touch $DIR/go-fetched-off; echo '{\"usage\":{\"rolling\":{\"usedPercent\":40}}}'" run)
[ "$out" = "claude 12%/30% │ codex 29%/24%" ] || fail "disabled quota providers: got '$out'"; ok
[ ! -e "$DIR/grok-fetched-off" ] && [ ! -e "$DIR/go-fetched-off" ] || fail "disabled provider was fetched"; ok

# 19) a quota window whose reset has passed counts as 0%, same as claude and codex
printf '%s\n' '{"usage":{"rolling":{"usedPercent":40,"resetsAt":1000},"weekly":{"usedPercent":75,"resetsAt":9999999999}}}' > "$DIR/go-reset.json"
out=$(CSF=$DIR/none CSD=$DIR/none OFC="cat $DIR/go-reset.json" QCF="$DIR/go-reset-cache.json" run)
[ "$out" = "go 0%/75%" ] || fail "go expired window: got '$out'"; ok

# 20) grok, opencode go, and z.ai refresh together, so three slow calls stay inside the 5s widget timeout
printf '%s\n' '{"config":{"creditUsagePercent":50}}' > "$DIR/slow-grok.json"
printf '%s\n' '{"usage":{"rolling":{"usedPercent":40},"weekly":{"usedPercent":75}}}' > "$DIR/slow-go.json"
printf '%s\n' '{"success":true,"data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":12},{"type":"CREDIT_LIMIT","unit":6,"number":1,"percentage":40}]}}' > "$DIR/slow-zai.json"
start=$(date +%s.%N)
out=$(CSF=$DIR/none CSD=$DIR/none QCF="$DIR/slow-cache.json" \
  GFC="sleep 1.5; cat $DIR/slow-grok.json" OFC="sleep 1.5; cat $DIR/slow-go.json" \
  ZFC="sleep 1.5; cat $DIR/slow-zai.json" run)
took=$(python3 -c 'import sys; print(float(sys.argv[2]) - float(sys.argv[1]))' "$start" "$(date +%s.%N)")
[ "$out" = "grok -/50% │ go 40%/75% │ zai 12%/40%" ] || fail "parallel output: got '$out'"; ok
python3 -c 'import sys; assert float(sys.argv[1]) < 2.5, sys.argv[1]' "$took" || fail "parallel took ${took}s"; ok

# 15) a cache younger than 5 minutes is shown and not refetched
python3 -c 'import json,sys; json.dump({"grok":{"short":25,"long":None,"short_resets_at":None,"long_resets_at":None,"fetched_at":float(sys.argv[1])}}, open(sys.argv[2],"w"))' "$((T0 - 60))" "$DIR/fresh-cache.json"
printf '%s\n' '{"config":{"creditUsagePercent":90}}' > "$DIR/grok-new.json"
out=$(CSF=$DIR/none CSD=$DIR/none QCF="$DIR/fresh-cache.json" GFC="touch $DIR/grok-fetched; cat $DIR/grok-new.json" run)
[ "$out" = "grok -/25%" ] || fail "fresh grok cache: got '$out'"; ok
[ ! -e "$DIR/grok-fetched" ] || fail "fresh cache must not refetch"; ok

# 23) z.ai coding plan: 5-hour/weekly from CREDIT_LIMIT windows; counts beat percentage; MCP time limit ignored
printf '%s\n' '{"success":true,"code":200,"data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":99,"usage":100,"currentValue":12,"remaining":88,"nextResetTime":null,"key":"super-secret-token"},{"type":"CREDIT_LIMIT","unit":6,"number":1,"percentage":1,"usage":100,"currentValue":40,"remaining":60,"nextResetTime":9999999999000},{"type":"TIME_LIMIT","unit":5,"number":1,"percentage":90,"usage":100,"currentValue":90}]}}' > "$DIR/zai.json"
out=$(CSF=$DIR/none CSD=$DIR/none ZFC="cat $DIR/zai.json" QCF="$DIR/zai-cache.json" run)
[ "$out" = "zai 12%/40%" ] || fail "zai: got '$out'"; ok
grep -q super-secret-token "$DIR/zai-cache.json" && fail "zai cache stored a token"; ok
python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["zai"]; assert d["short"]==12 and d["long"]==40 and d["short_resets_at"] is None and d["long_resets_at"]==9999999999' "$DIR/zai-cache.json" || fail "zai cache shape"; ok

# 24b) a few credits used on a large plan must not round away to 0%; z.ai reports that as 1%
printf '%s\n' '{"success":true,"data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":1,"usage":28000,"currentValue":3,"remaining":27997,"nextResetTime":null},{"type":"CREDIT_LIMIT","unit":6,"number":1,"percentage":1,"usage":140000,"currentValue":3,"remaining":139997,"nextResetTime":9999999999000}]}}' > "$DIR/zai-tiny.json"
out=$(CSF=$DIR/none CSD=$DIR/none ZFC="cat $DIR/zai-tiny.json" QCF="$DIR/zai-tiny-cache.json" run)
[ "$out" = "zai 1%/1%" ] || fail "zai tiny usage: got '$out'"; ok

# 24) percentage is the fallback when usage is missing or not positive; a null reset is not expired
printf '%s\n' '{"success":true,"data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":25,"usage":0,"currentValue":9,"nextResetTime":null},{"type":"CREDIT_LIMIT","unit":6,"number":1,"percentage":80}]}}' > "$DIR/zai-pct.json"
out=$(CSF=$DIR/none CSD=$DIR/none ZFC="cat $DIR/zai-pct.json" QCF="$DIR/zai-pct-cache.json" run)
[ "$out" = "zai 25%/80%" ] || fail "zai percentage fallback: got '$out'"; ok

# 25) a nextResetTime in epoch ms that has passed counts as 0%; leaving it in ms would look future
printf '%s\n' '{"success":true,"data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":12,"usage":100,"currentValue":12,"nextResetTime":null},{"type":"CREDIT_LIMIT","unit":6,"number":1,"percentage":40,"usage":100,"currentValue":40,"nextResetTime":1600000000000}]}}' > "$DIR/zai-reset.json"
out=$(CSF=$DIR/none CSD=$DIR/none ZFC="cat $DIR/zai-reset.json" QCF="$DIR/zai-reset-cache.json" run)
[ "$out" = "zai 12%/0%" ] || fail "zai expired ms reset: got '$out'"; ok

# 26) TOKENS_LIMIT uses the same 5-hour/weekly windows
printf '%s\n' '{"success":true,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":50},{"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":10}]}}' > "$DIR/zai-tokens.json"
out=$(CSF=$DIR/none CSD=$DIR/none ZFC="cat $DIR/zai-tokens.json" QCF="$DIR/zai-tokens-cache.json" run)
[ "$out" = "zai 50%/10%" ] || fail "zai tokens limit: got '$out'"; ok

# 27) a failed or non-plan payload is omitted, not shown as 0%
printf '%s\n' '{"success":false,"code":500,"msg":"no plan"}' > "$DIR/zai-bad.json"
out=$(CSF=$DIR/none CSD=$DIR/none ZFC="cat $DIR/zai-bad.json" QCF="$DIR/zai-bad-cache.json" run)
[ "$out" = "" ] || fail "zai bad payload: got '$out'"; ok

# 28) z.ai quota call sends the coding-plan key as a bearer header, not in the URL or cache
python3 - "$DIR" <<'PY' &
import json, os, time
from http.server import BaseHTTPRequestHandler, HTTPServer
root = __import__("sys").argv[1]
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def do_GET(self):
        json.dump({
            "path": self.path,
            "authorization": self.headers.get("Authorization"),
        }, open(root + "/zai-request.json", "w"))
        body = b'{"success":true,"code":200,"data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":12,"usage":100,"currentValue":12,"nextResetTime":null},{"type":"CREDIT_LIMIT","unit":6,"number":1,"percentage":40,"usage":100,"currentValue":40,"nextResetTime":9999999999000}]}}'
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()
    def log_message(self, *args):
        return
server = HTTPServer(("127.0.0.1", 0), Handler)
server.timeout = 0.2
open(root + "/zai-port", "w").write(str(server.server_address[1]))
deadline = time.time() + 8
while time.time() < deadline and not os.path.exists(root + "/zai-request.json"):
    server.handle_request()
PY
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$DIR/zai-port" ] && break; sleep 0.05; done
sleep 0.1
python3 -c 'import json,sys; json.dump({"zai-coding-plan":{"type":"api","key":"super-secret-token"}}, open(sys.argv[1],"w"))' "$DIR/zai-auth.json"
out=$(CSF=$DIR/none CSD=$DIR/none OAF="$DIR/zai-auth.json" ZQU="http://127.0.0.1:$(cat "$DIR/zai-port")/api/monitor/usage/quota/limit" QCF="$DIR/zai-http-cache.json" ZFC="" run)
[ "$out" = "zai 12%/40%" ] || fail "zai http: got '$out'"; ok
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["authorization"]=="Bearer super-secret-token", d; assert "super-secret-token" not in d["path"]' "$DIR/zai-request.json" || fail "zai request"; ok
grep -q super-secret-token "$DIR/zai-http-cache.json" && fail "zai http cache stored the token"; ok

# 29) a disabled z.ai provider is not fetched
printf 'zai = false\n' > "$DIR/zai-off.toml"
out=$(AUC="$DIR/zai-off.toml" CSF=$DIR/none CSD=$DIR/none QCF="$DIR/zai-off-cache.json" ZFC="touch $DIR/zai-fetched-off; echo '{\"success\":true,\"data\":{\"limits\":[{\"type\":\"CREDIT_LIMIT\",\"unit\":3,\"number\":5,\"percentage\":12}]}}'" run)
[ "$out" = "" ] || fail "disabled zai: got '$out'"; ok
[ ! -e "$DIR/zai-fetched-off" ] || fail "disabled zai was fetched"; ok

echo "PASS ($pass/$pass)"
