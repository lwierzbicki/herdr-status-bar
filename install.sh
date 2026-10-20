#!/bin/sh
# herdr-status-bar installer
# 1) copy agent_usage.py to ~/.config/herdr/agent-usage/
# 2) add one entry to [ui].tab_bar_right in config.toml (idempotent, backed up)
# 3) wrap the Claude Code statusline so its stdin (incl. rate_limits) is captured
# 4) herdr server reload-config
# Overrides: HERDR_CONFIG_DIR, CLAUDE_SETTINGS, HERDR_BIN_PATH
set -eu

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="${HERDR_CONFIG_DIR:-$HOME/.config/herdr}"
CLAUDE_SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
DEST_DIR="$CONFIG_DIR/agent-usage"
STAMP="$(date +%Y%m%d%H%M%S)"

err() { printf 'error: %s\n' "$1" >&2; exit 1; }
note() { printf '%s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || err "python3 not found (>= 3.9 required)"
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' || err "python3 >= 3.9 required"
[ -d "$CONFIG_DIR" ] || err "herdr config dir not found: $CONFIG_DIR (is herdr installed?)"

mkdir -p "$DEST_DIR"
cp "$SRC_DIR/agent_usage.py" "$DEST_DIR/agent_usage.py"
chmod +x "$DEST_DIR/agent_usage.py"
note "installed: $DEST_DIR/agent_usage.py"

python3 -I "$SRC_DIR/tabbar.py" add "$CONFIG_DIR/config.toml"

# --- Claude statusline capture wrapper (only when a statusline is configured) ---
if [ ! -f "$CLAUDE_SETTINGS" ]; then
    note "claude capture: $CLAUDE_SETTINGS not found; the claude segment will be omitted"
else
    CLAUDE_SETTINGS="$CLAUDE_SETTINGS" DEST_DIR="$DEST_DIR" STAMP="$STAMP" python3 -I - <<'PY'
import json, os, shlex, shutil

settings_path = os.environ["CLAUDE_SETTINGS"]
dest = os.environ["DEST_DIR"]

try:
    with open(settings_path) as f:
        settings = json.load(f)
except ValueError:
    print("claude capture: settings.json is not valid JSON; skipped (fix it and re-run install.sh)")
    raise SystemExit(0)

status = settings.get("statusLine") or {}
original = status.get("command")
wrapper = os.path.join(dest, "statusline-wrapper.sh")

if isinstance(original, str) and original == wrapper:
    print("claude capture: wrapper already installed; skipped")
elif not original:
    print("claude capture: no statusLine configured; the claude segment will be omitted")
    print("  (configure any Claude Code statusline first, then re-run install.sh)")
else:
    with open(os.path.join(dest, "statusline-original.json"), "w") as f:
        json.dump({"command": original}, f, ensure_ascii=False)

    orig_sh = os.path.join(dest, "statusline-original.sh")
    with open(orig_sh, "w") as f:
        f.write("#!/bin/sh\n" + original + "\n")
    os.chmod(orig_sh, 0o700)

    with open(wrapper, "w") as f:
        f.write(
            "#!/bin/sh\n"
            "# agent-usage: capture statusline stdin (private per-process tmp, publish after render)\n"
            "umask 077\n"
            'mkdir -p "$HOME/.claude"\n'
            't="$HOME/.claude/.last-statusline.json"\n'
            'tmp="$t.$$"\n'
            'cat > "$tmp"\n'
            f'{shlex.quote(orig_sh)} < "$tmp"\n'
            'mv -f "$tmp" "$t"\n'
        )
    os.chmod(wrapper, 0o700)

    shutil.copy2(settings_path, f"{settings_path}.bak-agent-usage-{os.environ['STAMP']}")
    new_settings = {**settings, "statusLine": {**status, "command": wrapper}}
    with open(settings_path, "w") as f:
        json.dump(new_settings, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print("claude capture: statusline wrapped (original preserved as sidecar)")
PY
fi

HERDR="${HERDR_BIN_PATH:-herdr}"
if "$HERDR" server reload-config >/dev/null 2>&1; then
    note "herdr: config reloaded"
else
    note "herdr: reload skipped (server not running?); restart herdr to apply"
fi
note "done."
