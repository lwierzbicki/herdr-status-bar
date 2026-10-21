# herdr-status-bar

Claude Code and Codex plan-limit usage in the [herdr](https://herdr.dev) tab bar. Reads local files only; makes no network requests.

```
claude █░░░ 31%/94% │ codex ██░░ 47%/27%
```

**All numbers are percent used, not percent left.** `31%/94%` means 31% of the 5-hour limit and 94% of the weekly limit are already used; a full gauge means you are near the limit. Codex's `/status` reports the opposite (percent left): "23% left" there shows here as 77%.

Each segment is 5-hour / weekly; the gauge tracks only the 5-hour window. A window whose reset time has passed shows 0%, even before the agent reports fresh numbers. `*` after a value means stale data (Claude older than 6 h, Codex older than 24 h). A provider with no data is omitted.

## Data sources

- **Claude:** Claude Code passes `rate_limits` to the statusline command on stdin. `install.sh` wraps your existing `statusLine.command` with `statusline-wrapper.sh`, which saves that stdin per session to `~/.claude/.agent-usage/<session_id>.json` and then runs your original command unchanged. Concurrent sessions are merged per window: the newest window wins, and within one window the highest usage wins, so an idle session's stale numbers never hide a fresh one's. A render without `rate_limits` (a new session after `/clear`, before its first API response) is not saved, and captures untouched for 7 days are pruned. Without a configured statusline the Claude segment is omitted.
- **Codex:** the last `rate_limits` event (`limit_id` `codex`) in the newest of `~/.codex/sessions/**/*.jsonl`, `primary` / `secondary` windows. Only the file tail is read (up to 8 MiB, newest 5 files), so very large session logs stay cheap.

## Install

Requires herdr >= 0.8.0 and python3 >= 3.9.

```sh
./install.sh
./uninstall.sh
```

`install.sh` copies `agent_usage.py` to `~/.config/herdr/agent-usage/`, adds one entry to `[ui].tab_bar_right` in `~/.config/herdr/config.toml` (60 s interval, 5 s timeout), wraps the Claude statusline, and reloads herdr. Both `config.toml` and `settings.json` are backed up as `*.bak-agent-usage-<timestamp>` before changes. `uninstall.sh` removes the entry and restores the original statusline command.

## Tests

```sh
bash tests/test.sh
```

Fixture-only: widget formatting, staleness, tail reading across block boundaries, bounded memory on a ~190 MiB session file, and install/uninstall round-trips on temporary configs.

## Origin and license

herdr-status-bar is derived from [speardragon/herdr-status-ui-bar](https://github.com/speardragon/herdr-status-ui-bar) (MIT, Copyright (c) 2026 speardragon), forked from upstream v0.8.0 at commit `34b509d`. It remains under the MIT License; see [LICENSE](LICENSE), which keeps the upstream copyright notice alongside ours.

Changes from upstream:

- Removed the Grok, Cursor, Droid and Antigravity providers (and with them all network access and credential reads), the weather and focused-pane widgets, the customize popup and the `layout.toml` layout system.
- Codex reads only the tail of each session file instead of the whole file (on a 531 MB session log: 13 MB / 0.03 s instead of 4.8 GB / 5.5 s) and shows both the primary (5-hour) and secondary (weekly) windows; only the `codex` rate-limit family is used.
- The installer manages a single `tab_bar_right` entry through `tabbar.py`; uninstall restores `config.toml` byte-for-byte.
- The Claude statusline capture file and wrapper scripts are private to the user (0600/0700).
- Output is shorter: 4-cell gauge, no timestamp. The upstream display flags (per-provider toggles, gauge width, color, 12-hour clock) are removed; the widget takes no options.
