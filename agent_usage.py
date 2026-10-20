#!/usr/bin/env python3
"""herdr tab-bar widget: Claude Code / Codex plan-limit usage. Local files only, no network.

Output: "claude █░░░ 12%/30% │ codex █░░░ 29%/24%"
        (5-hour/weekly used %; the gauge tracks the 5-hour window)
- claude: statusline capture (~/.claude/.last-statusline.json) written by statusline-wrapper.sh
- codex:  last rate_limits event in the newest ~/.codex/sessions/**/*.jsonl; only the
          file tail is read, so multi-hundred-MB session logs stay cheap
Missing or unparsable segments are omitted silently; '*' marks stale data
(claude 6h, codex 24h).
Flags: --no-claude --no-codex --no-gauge --gauge-width N --color
Test overrides: CLAUDE_STATUS_FILE, CODEX_SESSIONS_DIR, NOW_EPOCH
"""
from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

CLAUDE_STALE_SECS = 6 * 3600
CODEX_STALE_SECS = 24 * 3600
CODEX_SCAN_LIMIT = 5  # give up after this many newest session files without rate_limits
CODEX_TAIL_BLOCK = 256 * 1024
CODEX_TAIL_MAX = 8 * 1024 * 1024  # never read more than this from the end of one file
CODEX_LIMIT_IDS = (None, "codex")  # skip other limit families (e.g. "premium")

BRAND_RGB = {
    "claude": (217, 119, 87),
    "codex": (16, 163, 127),
}

gauge_cells = 4
show_gauge = True


def now() -> float:
    override = os.environ.get("NOW_EPOCH")
    return float(override) if override else time.time()


def number(value) -> float | None:
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def pct(value) -> str:
    return "-" if value is None else f"{round(min(100, max(0, value)))}%"


def gauge(value) -> str:
    """Fill N cells proportionally; any non-zero value fills at least one."""
    clamped = min(100, max(0, value or 0))
    filled = 0 if clamped <= 0 else min(gauge_cells, max(1, round(clamped / 100 * gauge_cells)))
    return "█" * filled + "░" * (gauge_cells - filled)


def segment(label: str, short, long, stale: bool) -> str | None:
    if short is None and long is None:
        return None
    tail = f"{pct(short)}/{pct(long)}{'*' if stale else ''}"
    if not show_gauge:
        return f"{label} {tail}"
    return f"{label} {gauge(short if short is not None else long)} {tail}"


# ---------- claude ----------

def claude_segment() -> str | None:
    path = Path(os.environ.get("CLAUDE_STATUS_FILE") or Path.home() / ".claude/.last-statusline.json")
    try:
        data = json.loads(path.read_text())
        mtime = path.stat().st_mtime
    except (OSError, ValueError):
        return None
    limits = data.get("rate_limits") if isinstance(data, dict) else None
    if not isinstance(limits, dict):
        return None
    five_hour = number((limits.get("five_hour") or {}).get("used_percentage"))
    seven_day = number((limits.get("seven_day") or {}).get("used_percentage"))
    return segment("claude", five_hour, seven_day, now() - mtime > CLAUDE_STALE_SECS)


# ---------- codex ----------

def find_rate_limits(node):
    """Depth-first search for a rate_limits object with a primary window."""
    if isinstance(node, dict):
        limits = node.get("rate_limits")
        if isinstance(limits, dict) and isinstance(limits.get("primary"), dict) \
                and limits.get("limit_id") in CODEX_LIMIT_IDS:
            return limits
        children = node.values()
    elif isinstance(node, list):
        children = node
    else:
        return None
    for child in children:
        found = find_rate_limits(child)
        if found is not None:
            return found
    return None


def reversed_lines(path: Path):
    """Yield complete lines from the end of the file, newest first, within CODEX_TAIL_MAX."""
    with path.open("rb") as stream:
        end = stream.seek(0, os.SEEK_END)
        pos, carry = end, b""
        while pos > 0 and end - pos < CODEX_TAIL_MAX:
            step = min(CODEX_TAIL_BLOCK, pos)
            pos -= step
            stream.seek(pos)
            lines = (stream.read(step) + carry).split(b"\n")
            carry = lines.pop(0) if pos > 0 else b""  # may be cut mid-line; finish it next round
            yield from reversed(lines)


def codex_limits(path: Path):
    for line in reversed_lines(path):
        if b'"rate_limits"' not in line:
            continue
        try:
            limits = find_rate_limits(json.loads(line))
        except (ValueError, RecursionError):
            continue
        if limits is not None:
            return limits
    return None


def codex_segment() -> str | None:
    root = Path(os.environ.get("CODEX_SESSIONS_DIR") or Path.home() / ".codex/sessions")
    try:
        files = sorted(((p.stat().st_mtime, p) for p in root.rglob("*.jsonl")), reverse=True)
    except OSError:
        return None
    for mtime, path in files[:CODEX_SCAN_LIMIT]:
        try:
            limits = codex_limits(path)
        except OSError:
            continue
        if limits is None:
            continue
        primary = number((limits.get("primary") or {}).get("used_percent"))
        secondary = number((limits.get("secondary") or {}).get("used_percent"))
        return segment("codex", primary, secondary, now() - mtime > CODEX_STALE_SECS)
    return None


def main() -> None:
    global gauge_cells, show_gauge
    argv = sys.argv[1:]
    show_gauge = "--no-gauge" not in argv
    if "--gauge-width" in argv:
        idx = argv.index("--gauge-width")
        try:
            gauge_cells = max(1, min(20, int(argv[idx + 1])))
        except (IndexError, ValueError):
            pass
    color = "--color" in argv

    named = []
    if "--no-claude" not in argv:
        named.append(("claude", claude_segment()))
    if "--no-codex" not in argv:
        named.append(("codex", codex_segment()))

    parts = []
    for name, text in named:
        if text:
            r, g, b = BRAND_RGB[name]
            parts.append(f"\x1b[38;2;{r};{g};{b}m{text}\x1b[0m" if color else text)
    print(" │ ".join(parts))


if __name__ == "__main__":
    main()
