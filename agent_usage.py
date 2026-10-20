#!/usr/bin/env python3
"""herdr tab-bar widget: Claude Code / Codex plan-limit usage. Local files only, no network.

Output: "claude █░░░ 12%/30% │ codex █░░░ 29%/24%"
        (5-hour/weekly used %; the gauge tracks the 5-hour window)
- claude: statusline capture (~/.claude/.last-statusline.json) written by statusline-wrapper.sh
- codex:  last rate_limits event in the newest ~/.codex/sessions/**/*.jsonl; only the
          file tail is read, so multi-hundred-MB session logs stay cheap
Missing or unparsable segments are omitted silently; '*' marks stale data
(claude 6h, codex 24h).
Test overrides: CLAUDE_STATUS_FILE, CODEX_SESSIONS_DIR, NOW_EPOCH
"""
from __future__ import annotations

import json
import os
import time
from pathlib import Path

CLAUDE_STALE_SECS = 6 * 3600
CODEX_STALE_SECS = 24 * 3600
CODEX_SCAN_LIMIT = 5  # give up after this many newest session files without rate_limits
CODEX_TAIL_BLOCK = 256 * 1024
CODEX_TAIL_MAX = 8 * 1024 * 1024  # never read more than this from the end of one file
CODEX_LIMIT_IDS = (None, "codex")  # skip other limit families (e.g. "premium")
GAUGE_CELLS = 4


def now() -> float:
    override = os.environ.get("NOW_EPOCH")
    return float(override) if override else time.time()


def number(value) -> float | None:
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def pct(value) -> str:
    return "-" if value is None else f"{round(min(100, max(0, value)))}%"


def gauge(value) -> str:
    """Fill GAUGE_CELLS proportionally; any non-zero value fills at least one."""
    clamped = min(100, max(0, value or 0))
    filled = 0 if clamped <= 0 else min(GAUGE_CELLS, max(1, round(clamped / 100 * GAUGE_CELLS)))
    return "█" * filled + "░" * (GAUGE_CELLS - filled)


def used(window, key: str) -> float | None:
    """Used percent of one limit window; 0 once its resets_at has passed (captured pre-reset)."""
    if not isinstance(window, dict):
        return None
    value = number(window.get(key))
    resets_at = number(window.get("resets_at"))
    if value is not None and resets_at is not None and now() >= resets_at:
        return 0
    return value


def segment(label: str, short, long, stale: bool) -> str | None:
    """The gauge tracks only the 5-hour window, so a missing value never borrows the weekly one."""
    if short is None and long is None:
        return None
    return f"{label} {gauge(short)} {pct(short)}/{pct(long)}{'*' if stale else ''}"


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
    five_hour = used(limits.get("five_hour"), "used_percentage")
    seven_day = used(limits.get("seven_day"), "used_percentage")
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
        primary = used(limits.get("primary"), "used_percent")
        secondary = used(limits.get("secondary"), "used_percent")
        return segment("codex", primary, secondary, now() - mtime > CODEX_STALE_SECS)
    return None


def main() -> None:
    print(" │ ".join(text for text in (claude_segment(), codex_segment()) if text))


if __name__ == "__main__":
    main()
