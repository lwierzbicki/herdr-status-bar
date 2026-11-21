# herdr-status-bar

Claude Code, Codex, Grok, OpenCode Go, and z.ai plan-limit usage in the [herdr](https://herdr.dev) tab bar. Claude and Codex are read from local files. Grok, OpenCode Go, and z.ai make one cached quota call each.

```
claude 31%/94% │ codex 47%/27% │ grok -/8% │ go 12%/40% │ zai 12%/40%
```

**All numbers are percent used, not percent left.** `31%/94%` means 31% of the 5-hour limit and 94% of the weekly limit are already used. Codex's `/status` reports the opposite (percent left): "23% left" there shows here as 77%.

Each segment is 5-hour / weekly, except Grok, which is a single weekly credits window (`-/8%`). There is no gauge: five providers with one did not fit the tab row, and herdr cuts the end of the status area, which hid the last segment. A window whose reset time has passed shows 0%, even before the agent reports fresh numbers. `*` after a value means stale data (Claude or a quota cache older than 6 h, Codex older than 24 h). A provider with no data, or set to `false` in the config, is omitted.

## Data sources

- **Claude:** Claude Code passes `rate_limits` to the statusline command on stdin. `install.sh` wraps your existing `statusLine.command` with `statusline-wrapper.sh`, which saves that stdin per session to `~/.claude/.agent-usage/<session_id>.json` and then runs your original command unchanged. Concurrent sessions are merged per window: the newest window wins, and within one window the highest usage wins, so an idle session's stale numbers never hide a fresh one's. A render without `rate_limits` (a new session after `/clear`, before its first API response) is not saved, and captures untouched for 7 days are pruned. Without a configured statusline the Claude segment is omitted.
- **Codex:** the last `rate_limits` event (`limit_id` `codex`) in the newest of `~/.codex/sessions/**/*.jsonl`, `primary` / `secondary` windows. Only the file tail is read (up to 8 MiB, newest 5 files), so very large session logs stay cheap.
- **Grok:** one GET to the Grok CLI billing endpoint. The token comes from `~/.grok/auth.json` when the Grok CLI is logged in, otherwise from the `xai` OAuth entry in `~/.local/share/opencode/auth.json` (the xAI subscription used through OpenCode). The segment is the weekly credits percent (`-/8%`). No token means the segment is omitted.
- **OpenCode Go** (`go`): one GET to `https://opencode.ai/zen/go/v1/usage`, using the `opencode-go` key in `~/.local/share/opencode/auth.json` (`XDG_DATA_HOME` is honored). The segment is the 5-hour / weekly windows; the monthly window is not shown.
- **z.ai** (`zai`): one GET to `https://api.z.ai/api/monitor/usage/quota/limit`, using the `zai-coding-plan` key in the same OpenCode auth file. The segment is the Coding Plan 5-hour / weekly windows. No key means the segment is omitted.

Quota responses are cached for 5 minutes in `~/.config/herdr/agent-usage/quota-cache.json` (mode 0600, percents and reset times only — never the token). A failed refresh keeps the last cache. The quota calls run in parallel and time out at 2 seconds, so a tick stays inside herdr's 5 second limit. The token is sent as a header, not as a command argument.

## How consumption is taken

Every number is percent already used of that window's plan limit. The widget does not sum tokens or dollars itself, except the OpenCode Go fallback below. `-` means that window was not reported.

- **Claude** reads `rate_limits.five_hour.used_percentage` and `rate_limits.seven_day.used_percentage` from each session capture. Across sessions, the newest `resets_at` wins; inside one window the highest percent wins. A `resets_at` already in the past is shown as 0%.
- **Codex** reads the newest `rate_limits` object whose `limit_id` is `codex` (other families, such as `premium`, are ignored). `primary.used_percent` is the 5-hour window and `secondary.used_percent` is the weekly window. A passed `resets_at` is shown as 0%.
- **Grok** GETs `https://cli-chat-proxy.grok.com/v1/billing?format=credits` with the login token in the `Authorization` header and `x-xai-token-auth: xai-grok-cli`. Consumption is `config.creditUsagePercent`. If that field is missing, it is `onDemandUsed.val / onDemandCap.val * 100`. There is no 5-hour window, so that slot is `-`. The token is `key` from `~/.grok/auth.json`, or, if that file is absent, `access` from the `xai` entry in OpenCode's `auth.json`. An `expires` value above 1e12 is treated as milliseconds.
- **OpenCode Go** GETs `https://opencode.ai/zen/go/v1/usage` with `Authorization: Bearer` and the `opencode-go` key. `usage.rolling` is the 5-hour window and `usage.weekly` is the weekly window. `usage.monthly` is ignored. A window's percent is the first of `usedPercent`, `usagePercent`, `percentUsed`, `percent`, or `utilization`; if none of those is set, it is `used / limit * 100`. A passed `resetsAt` is shown as 0%.
- **z.ai** GETs `https://api.z.ai/api/monitor/usage/quota/limit` with `Authorization: Bearer` and the `zai-coding-plan` key. A response that is not `success: true` is ignored. `data.limits[]` entries of type `CREDIT_LIMIT` or `TOKENS_LIMIT` are kept; `TIME_LIMIT` is ignored. `unit` 3 and `number` 5 is the 5-hour window; `unit` 6 and `number` 1 is the weekly window. When `usage` is positive, the percent is `currentValue / usage * 100`; otherwise it is `percentage`. A positive amount that would round to 0% keeps the reported `percentage`, or 1% if that field is missing, so a few credits on a large plan still show as used. `nextResetTime` is epoch milliseconds and is stored as seconds; a null reset is left as reported, and a passed reset is shown as 0%.

## Install

Requires herdr >= 0.8.0 and python3 >= 3.9.

```sh
./install.sh
./uninstall.sh
```

`install.sh` copies `agent_usage.py` to `~/.config/herdr/agent-usage/`, adds one entry to `[ui].tab_bar_right` in `~/.config/herdr/config.toml` (60 s interval, 5 s timeout), wraps the Claude statusline, and reloads herdr. Both `config.toml` and `settings.json` are backed up as `*.bak-agent-usage-<timestamp>` before changes. `uninstall.sh` removes the entry and restores the original statusline command.

## Which providers are shown

Create `~/.config/herdr/agent-usage.toml`. A missing file, or a missing key, shows that provider. `false` hides it and skips its read or quota call. Install and uninstall do not touch this file.

```toml
claude = true
codex = true
grok = true
opencode_go = false
zai = true
```

## Tests

```sh
bash tests/test.sh
```

Fixture-only: widget formatting, staleness, tail reading across block boundaries, bounded memory on a ~190 MiB session file, provider toggles, quota parsing, and install/uninstall round-trips on temporary configs. Quota calls are stubbed; the suite makes no external network requests.

## Origin and license

herdr-status-bar is derived from [speardragon/herdr-status-ui-bar](https://github.com/speardragon/herdr-status-ui-bar) (MIT, Copyright (c) 2026 speardragon), forked from upstream v0.8.0 at commit `34b509d`. It remains under the MIT License; see [LICENSE](LICENSE), which keeps the upstream copyright notice alongside ours.

Changes from upstream:

- Removed the Cursor, Droid and Antigravity providers, the weather and focused-pane widgets, the customize popup and the `layout.toml` layout system. Grok is a cached billing call, not the upstream curl-and-popup path. OpenCode Go and z.ai are cached usage calls. All four are toggled, with Claude and Codex, in `agent-usage.toml`.
- Codex reads only the tail of each session file instead of the whole file (on a 531 MB session log: 13 MB / 0.03 s instead of 4.8 GB / 5.5 s) and shows both the primary (5-hour) and secondary (weekly) windows; only the `codex` rate-limit family is used.
- The installer manages a single `tab_bar_right` entry through `tabbar.py`; uninstall restores `config.toml` byte-for-byte.
- The Claude statusline capture file and wrapper scripts are private to the user (0600/0700).
- Output is numbers only, no gauge and no timestamp, so five providers fit the tab row. Gauge width, color, and the 12-hour clock are not options. Providers are toggled in `agent-usage.toml`, not by command-line flags.
