#!/bin/sh
# herdr-status-bar uninstaller: reverses install.sh
set -eu

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="${HERDR_CONFIG_DIR:-$HOME/.config/herdr}"
CLAUDE_SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
DEST_DIR="$CONFIG_DIR/agent-usage"

note() { printf '%s\n' "$1"; }

python3 -I "$SRC_DIR/tabbar.py" remove "$CONFIG_DIR/config.toml"

# --- restore the statusline (only while our wrapper is active) ---
if [ -f "$CLAUDE_SETTINGS" ] && [ -f "$DEST_DIR/statusline-original.json" ]; then
    CLAUDE_SETTINGS="$CLAUDE_SETTINGS" DEST_DIR="$DEST_DIR" python3 -I - <<'PY'
import json, os

settings_path = os.environ["CLAUDE_SETTINGS"]
dest = os.environ["DEST_DIR"]

try:
    with open(settings_path) as f:
        settings = json.load(f)
except ValueError:
    print("statusline: settings.json is not valid JSON; left untouched")
    raise SystemExit(0)
with open(os.path.join(dest, "statusline-original.json")) as f:
    original = json.load(f)["command"]

status = settings.get("statusLine") or {}
if status.get("command") == os.path.join(dest, "statusline-wrapper.sh"):
    new_settings = {**settings, "statusLine": {**status, "command": original}}
    with open(settings_path, "w") as f:
        json.dump(new_settings, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print("statusline: original command restored")
else:
    print("statusline: wrapper not active; left untouched")
PY
fi

rm -f "$DEST_DIR/agent_usage.py" "$DEST_DIR/statusline-wrapper.sh" \
      "$DEST_DIR/statusline-original.sh" "$DEST_DIR/statusline-original.json"
rmdir "$DEST_DIR" 2>/dev/null && note "removed: $DEST_DIR" || note "kept: $DEST_DIR (not empty)"

HERDR="${HERDR_BIN_PATH:-herdr}"
"$HERDR" server reload-config >/dev/null 2>&1 && note "herdr: config reloaded" || note "herdr: restart to apply"
note "done. (~/.claude/.agent-usage/ captures and *.bak-agent-usage-* backups are left in place)"
