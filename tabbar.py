#!/usr/bin/env python3
"""Add or remove the agent-usage entry in herdr config.toml's [ui].tab_bar_right.

usage: tabbar.py add|remove CONFIG_TOML

Edits text in place so comments, formatting and foreign entries survive; `remove`
undoes `add` byte-for-byte (an array left empty is deleted). The result is checked
with tomllib (Python 3.11+) and the original is backed up before writing.
"""
from __future__ import annotations

import re
import shutil
import sys
from datetime import datetime
from pathlib import Path

MARKER = "~/.config/herdr/agent-usage/agent_usage.py"
ENTRY = '{ type = "command", command = "%s", interval_seconds = 300, timeout_seconds = 5 }' % MARKER
ENTRY_LINE = re.compile(r"\n[ \t]*\{[^\n]*" + re.escape(MARKER) + r"[^\n]*\},?[ \t]*(?=\n)")
KEY = re.compile(r"^tab_bar_right\s*=\s*\[", re.M)


def array_span(text: str) -> tuple[int, int, int] | None:
    """(key_start, content_start, close_index) of tab_bar_right; strings may contain brackets."""
    match = KEY.search(text)
    if not match:
        return None
    depth, pos, quote = 1, match.end(), None
    while pos < len(text):
        ch = text[pos]
        if quote:
            if ch == "\\" and quote == '"':
                pos += 1
            elif ch == quote:
                quote = None
        elif ch in "\"'":
            quote = ch
        elif ch == "#":
            pos = text.find("\n", pos)
            if pos < 0:
                break
        elif ch == "[":
            depth += 1
        elif ch == "]":
            depth -= 1
            if depth == 0:
                return match.start(), match.end(), pos
        pos += 1
    raise SystemExit("error: tab_bar_right array is not closed; fix config.toml first")


def remove(text: str) -> str:
    span = array_span(text)
    if span is None:
        return text
    key_start, start, close = span
    content = ENTRY_LINE.sub("", text[start:close])
    if not content.strip():
        end = close + 1
        if text[end:end + 1] == "\n":
            end += 1
        return text[:key_start] + text[end:]
    return text[:start] + content + text[close:]


def add(text: str) -> str:
    text = remove(text)
    span = array_span(text)
    if span is not None:
        _, start, close = span
        content = text[start:close].rstrip()
        if content.strip() and not content.endswith(","):
            content += ","
        return text[:start] + content + f"\n  {ENTRY},\n" + text[close:]
    block = f"tab_bar_right = [\n  {ENTRY},\n]\n"
    ui = re.search(r"^\[ui\][ \t]*(\n|$)", text, re.M)
    if ui:
        insert_at = ui.end() if ui.group(1) else len(text)
        prefix = "" if ui.group(1) else "\n"
        return text[:insert_at] + prefix + block + text[insert_at:]
    return (text.rstrip("\n") + "\n\n" if text.strip() else "") + "[ui]\n" + block


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[0] not in ("add", "remove"):
        print(__doc__.splitlines()[2], file=sys.stderr)
        return 2
    path = Path(argv[1])
    text = path.read_text() if path.exists() else ""
    new = add(text) if argv[0] == "add" else remove(text)
    if new == text:
        print("config.toml: unchanged")
        return 0
    try:
        import tomllib
        tomllib.loads(new)
    except ImportError:
        pass
    except tomllib.TOMLDecodeError as exc:
        print(f"error: refusing to write invalid config.toml ({exc}); file left unchanged", file=sys.stderr)
        return 1
    if path.exists():
        shutil.copy2(path, f"{path}.bak-agent-usage-{datetime.now():%Y%m%d%H%M%S}")
    path.write_text(new)
    print(f"config.toml: tab_bar_right entry {'added' if argv[0] == 'add' else 'removed'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
