#!/usr/bin/env python3
"""herdr tab-bar widget: Claude Code / Codex / Grok / OpenCode Go / z.ai plan-limit usage.

Output: "claude 12%/30% │ codex 29%/24% │ grok 50%/- │ go 40%/75% │ zai 12%/40%"
        (5-hour/weekly used %; grok credits are one window)
- claude: per-session statusline captures (~/.claude/.agent-usage/<session>.json) written by
          statusline-wrapper.sh, merged per window across concurrent sessions
- codex:  last rate_limits event in the newest ~/.codex/sessions/**/*.jsonl; only the
          file tail is read, so multi-hundred-MB session logs stay cheap
- grok:   CLI billing call. Token from ~/.grok/auth.json, else OpenCode's xai OAuth entry
- go:     OpenCode Go usage call with the opencode-go key; 5-hour/weekly
- zai:    z.ai Coding Plan quota call with the zai-coding-plan key; 5-hour/weekly
Quota calls are cached 5 minutes (percents only, 0600) and refresh in parallel.
Missing or unparsable segments are omitted silently; '*' marks stale data
(claude 6h, codex 24h, quota cache 6h).
Providers are toggled in ~/.config/herdr/agent-usage.toml (missing key = on).
Test overrides: CLAUDE_STATUS_DIR, CODEX_SESSIONS_DIR, NOW_EPOCH, AGENT_USAGE_CONFIG,
                GROK_AUTH_FILE, OPENCODE_AUTH_FILE, QUOTA_CACHE_FILE,
                GROK_FETCH_CMD, OPENCODE_GO_FETCH_CMD, ZAI_FETCH_CMD,
                GROK_BILLING_URL, OPENCODE_GO_USAGE_URL, ZAI_QUOTA_URL
"""
from __future__ import annotations

import http.client
import json
import os
import subprocess
import threading
import time
import urllib.parse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

CLAUDE_STALE_SECS = 6 * 3600
CLAUDE_SAME_WINDOW_SECS = 3600  # resets_at values this close belong to the same limit window
CODEX_STALE_SECS = 24 * 3600
CODEX_SCAN_LIMIT = 5  # give up after this many newest session files without rate_limits
CODEX_TAIL_BLOCK = 256 * 1024
CODEX_TAIL_MAX = 8 * 1024 * 1024  # never read more than this from the end of one file
CODEX_LIMIT_IDS = (None, "codex")  # skip other limit families (e.g. "premium")
PROVIDERS = ("claude", "codex", "grok", "opencode_go", "zai")
QUOTA_FRESH_SECS = 5 * 60
QUOTA_STALE_SECS = 6 * 3600
QUOTA_TIMEOUT_SECS = 2
QUOTA_MAX_BYTES = 64 * 1024
_CACHE_LOCK = threading.Lock()
GROK_BILLING_URL = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
OPENCODE_GO_USAGE_URL = "https://opencode.ai/zen/go/v1/usage"
ZAI_QUOTA_URL = "https://api.z.ai/api/monitor/usage/quota/limit"


def now() -> float:
    override = os.environ.get("NOW_EPOCH")
    return float(override) if override else time.time()


def number(value) -> float | None:
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def pct(value) -> str:
    return "-" if value is None else f"{round(min(100, max(0, value)))}%"


def used(window, key: str) -> float | None:
    """Used percent of one limit window; 0 once its resets_at has passed (captured pre-reset)."""
    if not isinstance(window, dict):
        return None
    value = number(window.get(key))
    resets_at = number(window.get("resets_at"))
    if value is not None and resets_at is not None and now() >= resets_at:
        return 0
    return value


def enabled() -> dict[str, bool]:
    """Missing file or key means on. Only an explicit false hides a provider."""
    flags = {name: True for name in PROVIDERS}
    path = Path(os.environ.get("AGENT_USAGE_CONFIG") or Path.home() / ".config/herdr/agent-usage.toml")
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return flags
    for raw in lines:
        line = raw.split("#", 1)[0].strip()
        if "=" not in line:
            continue
        key, value = (part.strip() for part in line.split("=", 1))
        if key in flags and value in ("true", "false"):
            flags[key] = value == "true"
    return flags


def segment(label: str, short, long, stale: bool) -> str | None:
    """Numbers only. A 4-cell gauge made five providers longer than the tab row, and herdr cuts the end."""
    if short is None and long is None:
        return None
    return f"{label} {pct(short)}/{pct(long)}{'*' if stale else ''}"


# ---------- claude ----------

def latest_window(windows) -> dict | None:
    """Merge one window across sessions: the newest window wins; within one window
    (resets_at within CLAUDE_SAME_WINDOW_SECS) the highest usage wins, since usage only grows."""
    best = None
    for window in windows:
        if not isinstance(window, dict):
            continue
        value, resets_at = number(window.get("used_percentage")), number(window.get("resets_at"))
        if value is None or resets_at is None:
            continue
        if best is None or resets_at > best[1] + CLAUDE_SAME_WINDOW_SECS \
                or (abs(resets_at - best[1]) <= CLAUDE_SAME_WINDOW_SECS and value > best[0]):
            best = (value, resets_at)
    return None if best is None else {"used_percentage": best[0], "resets_at": best[1]}


def claude_segment() -> str | None:
    """Every Claude session writes its own capture; an idle session's numbers lag, so merge them all."""
    root = Path(os.environ.get("CLAUDE_STATUS_DIR") or Path.home() / ".claude/.agent-usage")
    captures, newest = [], 0.0
    for path in root.glob("*.json"):
        try:
            data = json.loads(path.read_text())
            mtime = path.stat().st_mtime
        except (OSError, ValueError):
            continue
        limits = data.get("rate_limits") if isinstance(data, dict) else None
        if isinstance(limits, dict):
            captures.append(limits)
            newest = max(newest, mtime)
    if not captures:
        return None
    five_hour = used(latest_window(c.get("five_hour") for c in captures), "used_percentage")
    seven_day = used(latest_window(c.get("seven_day") for c in captures), "used_percentage")
    return segment("claude", five_hour, seven_day, now() - newest > CLAUDE_STALE_SECS)


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


# ---------- grok ----------

def fetch_cmd(name: str):
    override = os.environ.get(name)
    if not override:
        return None
    try:
        proc = subprocess.run(["bash", "-c", override], capture_output=True, text=True, timeout=2)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0 or not proc.stdout.strip():
        return None
    try:
        data = json.loads(proc.stdout)
    except ValueError:
        return None
    return data if isinstance(data, dict) else None


def grok_percent(billing) -> float | None:
    if not isinstance(billing, dict):
        return None
    for scope in (billing.get("config"), billing):
        if not isinstance(scope, dict):
            continue
        used_pct = number(scope.get("creditUsagePercent"))
        if used_pct is not None:
            return used_pct
        demand = scope.get("onDemandUsed") if isinstance(scope.get("onDemandUsed"), dict) else {}
        cap = scope.get("onDemandCap") if isinstance(scope.get("onDemandCap"), dict) else {}
        used_val, cap_val = number(demand.get("val")), number(cap.get("val"))
        if used_val is not None and cap_val is not None and cap_val > 0:
            return used_val / cap_val * 100
    return None


def quota_cache_path() -> Path:
    return Path(os.environ.get("QUOTA_CACHE_FILE") or Path.home() / ".config/herdr/agent-usage/quota-cache.json")


def write_quota(name: str, short, long, short_resets_at=None, long_resets_at=None) -> None:
    """Percents and reset times only. Never the token or the raw response."""
    path = quota_cache_path()
    with _CACHE_LOCK:
        try:
            current = json.loads(path.read_text())
        except (OSError, ValueError):
            current = {}
        if not isinstance(current, dict):
            current = {}
        current[name] = {
            "short": short,
            "long": long,
            "short_resets_at": short_resets_at,
            "long_resets_at": long_resets_at,
            "fetched_at": now(),
        }
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(path.name + ".tmp")
        tmp.write_text(json.dumps(current))
        os.chmod(tmp, 0o600)
        tmp.replace(path)
        os.chmod(path, 0o600)


def read_quota(name: str) -> dict | None:
    path = quota_cache_path()
    with _CACHE_LOCK:
        try:
            data = json.loads(path.read_text())
        except (OSError, ValueError):
            return None
    entry = data.get(name) if isinstance(data, dict) else None
    return entry if isinstance(entry, dict) else None


def parse_time(value) -> float | None:
    epoch = number(value)
    if epoch is not None:
        return epoch
    if not isinstance(value, str) or not value:
        return None
    text = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.timestamp()


def window_resets_at(window) -> float | None:
    if not isinstance(window, dict):
        return None
    for key in ("resetsAt", "resetAt", "resets_at", "reset_at", "nextReset", "next_reset"):
        parsed = parse_time(window.get(key))
        if parsed is not None:
            return parsed
    return None


def cached_segment(label: str, entry: dict | None) -> str | None:
    if entry is None:
        return None
    fetched = number(entry.get("fetched_at"))
    stale = fetched is None or now() - fetched > QUOTA_STALE_SECS
    short = used({"used_percentage": entry.get("short"), "resets_at": entry.get("short_resets_at")}, "used_percentage")
    long = used({"used_percentage": entry.get("long"), "resets_at": entry.get("long_resets_at")}, "used_percentage")
    return segment(label, short, long, stale)


def fresh_quota(name: str) -> dict | None:
    entry = read_quota(name)
    fetched = number(entry.get("fetched_at")) if entry else None
    if fetched is None or now() - fetched >= QUOTA_FRESH_SECS:
        return None
    return entry


def http_get(url: str, headers: dict) -> dict | None:
    parsed = urllib.parse.urlsplit(url)
    host = parsed.hostname
    if parsed.scheme == "https" and host:
        connection = http.client.HTTPSConnection(host, parsed.port or 443, timeout=QUOTA_TIMEOUT_SECS)
    elif parsed.scheme == "http" and host in ("127.0.0.1", "localhost"):
        connection = http.client.HTTPConnection(host, parsed.port or 80, timeout=QUOTA_TIMEOUT_SECS)
    else:
        return None
    path = parsed.path or "/"
    if parsed.query:
        path += "?" + parsed.query
    try:
        connection.request("GET", path, headers=headers)
        response = connection.getresponse()
        if response.status != 200:
            response.read(QUOTA_MAX_BYTES)
            return None
        raw = response.read(QUOTA_MAX_BYTES + 1)
        if len(raw) > QUOTA_MAX_BYTES:
            return None
        data = json.loads(raw)
        return data if isinstance(data, dict) else None
    except (OSError, ValueError, http.client.HTTPException):
        return None
    finally:
        connection.close()


def token_expired(expires) -> bool:
    value = number(expires)
    if value is None:
        return False
    if value > 10**12:  # OpenCode stores xAI expiry in milliseconds
        value /= 1000
    return now() >= value


def grok_cli_token() -> str | None:
    path = Path(os.environ.get("GROK_AUTH_FILE") or Path.home() / ".grok/auth.json")
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    preferred = [data[key] for key in data if isinstance(key, str) and key.startswith("https://auth.x.ai::")]
    for entry in preferred or data.values():
        if not isinstance(entry, dict):
            continue
        token = entry.get("key")
        if isinstance(token, str) and token and not token_expired(entry.get("expires_at")):
            return token
    return None


def opencode_auth() -> dict | None:
    default = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local/share") / "opencode/auth.json"
    path = Path(os.environ.get("OPENCODE_AUTH_FILE") or default)
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def opencode_xai_token() -> str | None:
    """xAI subscription used through OpenCode, not the Grok CLI login."""
    entry = (opencode_auth() or {}).get("xai")
    if not isinstance(entry, dict) or token_expired(entry.get("expires")):
        return None
    token = entry.get("access") or entry.get("key")
    return token if isinstance(token, str) and token else None


def grok_token() -> str | None:
    return grok_cli_token() or opencode_xai_token()


def grok_fetch():
    if os.environ.get("GROK_FETCH_CMD"):
        return fetch_cmd("GROK_FETCH_CMD")
    token = grok_token()
    if not token:
        return None
    return http_get(os.environ.get("GROK_BILLING_URL") or GROK_BILLING_URL, {
        "Authorization": f"Bearer {token}",
        "x-xai-token-auth": "xai-grok-cli",
        "Accept": "application/json",
    })


def grok_segment() -> str | None:
    cached = fresh_quota("grok")
    if cached is not None:
        return cached_segment("grok", cached)
    percent = grok_percent(grok_fetch())
    if percent is None:
        return cached_segment("grok", read_quota("grok"))
    write_quota("grok", percent, None)
    return segment("grok", percent, None, False)


# ---------- opencode go ----------

PERCENT_KEYS = (
    "usagePercent", "usedPercent", "percentUsed", "percent",
    "usage_percent", "used_percent", "utilization", "utilizationPercent", "utilization_percent",
)
USED_KEYS = ("used", "usage", "consumed", "count", "usedTokens")
LIMIT_KEYS = ("limit", "total", "quota", "max", "cap", "tokenLimit")


def window_percent(window) -> float | None:
    if not isinstance(window, dict):
        return None
    for key in PERCENT_KEYS:
        value = number(window.get(key))
        if value is not None:
            return value
    used = next((number(window.get(key)) for key in USED_KEYS if number(window.get(key)) is not None), None)
    limit = next((number(window.get(key)) for key in LIMIT_KEYS if number(window.get(key)) is not None), None)
    if used is not None and limit is not None and limit > 0:
        return used / limit * 100
    return None


def opencode_go_token() -> str | None:
    entry = (opencode_auth() or {}).get("opencode-go")
    token = entry.get("key") if isinstance(entry, dict) else None
    return token if isinstance(token, str) and token else None


def opencode_go_fetch():
    if os.environ.get("OPENCODE_GO_FETCH_CMD"):
        return fetch_cmd("OPENCODE_GO_FETCH_CMD")
    token = opencode_go_token()
    if not token:
        return None
    return http_get(os.environ.get("OPENCODE_GO_USAGE_URL") or OPENCODE_GO_USAGE_URL, {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
    })


def opencode_go_segment() -> str | None:
    cached = fresh_quota("opencode_go")
    if cached is not None:
        return cached_segment("go", cached)
    payload = opencode_go_fetch()
    usage = payload.get("usage") if isinstance(payload, dict) else None
    rolling = usage.get("rolling") if isinstance(usage, dict) else None
    weekly = usage.get("weekly") if isinstance(usage, dict) else None
    short = window_percent(rolling)
    long = window_percent(weekly)
    short_resets, long_resets = window_resets_at(rolling), window_resets_at(weekly)
    if short is None and long is None:
        return cached_segment("go", read_quota("opencode_go"))
    write_quota("opencode_go", short, long, short_resets, long_resets)
    shown_short = used({"used_percentage": short, "resets_at": short_resets}, "used_percentage")
    shown_long = used({"used_percentage": long, "resets_at": long_resets}, "used_percentage")
    return segment("go", shown_short, shown_long, False)


# ---------- z.ai ----------

def zai_token() -> str | None:
    entry = (opencode_auth() or {}).get("zai-coding-plan")
    token = entry.get("key") if isinstance(entry, dict) else None
    return token if isinstance(token, str) and token else None


def zai_percent(limit) -> float | None:
    usage = number(limit.get("usage"))
    current = number(limit.get("currentValue"))
    reported = number(limit.get("percentage"))
    if usage is not None and usage > 0 and current is not None:
        computed = current / usage * 100
        if computed > 0 and round(min(100, computed)) == 0:
            return reported if reported is not None and reported > 0 else 1
        return computed
    return reported


def zai_reset(limit) -> float | None:
    value = number(limit.get("nextResetTime"))
    if value is None:
        return None
    if value > 10**12:
        value /= 1000
    return value


def zai_windows(payload):
    if not isinstance(payload, dict) or payload.get("success") is not True:
        return None
    data = payload.get("data")
    limits = data.get("limits") if isinstance(data, dict) else None
    if not isinstance(limits, list):
        return None
    short = long = short_resets = long_resets = None
    for raw in limits:
        if not isinstance(raw, dict) or raw.get("type") not in ("CREDIT_LIMIT", "TOKENS_LIMIT"):
            continue
        slot = {(3, 5): "short", (6, 1): "long"}.get((raw.get("unit"), raw.get("number")))
        percent = zai_percent(raw)
        if slot == "short" and short is None and percent is not None:
            short, short_resets = percent, zai_reset(raw)
        elif slot == "long" and long is None and percent is not None:
            long, long_resets = percent, zai_reset(raw)
    if short is None and long is None:
        return None
    return short, long, short_resets, long_resets


def zai_fetch():
    if os.environ.get("ZAI_FETCH_CMD"):
        return fetch_cmd("ZAI_FETCH_CMD")
    token = zai_token()
    if not token:
        return None
    return http_get(os.environ.get("ZAI_QUOTA_URL") or ZAI_QUOTA_URL, {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
    })


def zai_segment() -> str | None:
    cached = fresh_quota("zai")
    if cached is not None:
        return cached_segment("zai", cached)
    parsed = zai_windows(zai_fetch())
    if parsed is None:
        return cached_segment("zai", read_quota("zai"))
    short, long, short_resets, long_resets = parsed
    write_quota("zai", short, long, short_resets, long_resets)
    shown_short = used({"used_percentage": short, "resets_at": short_resets}, "used_percentage")
    shown_long = used({"used_percentage": long, "resets_at": long_resets}, "used_percentage")
    return segment("zai", shown_short, shown_long, False)


def main() -> None:
    flags = enabled()
    parts = []
    if flags["claude"]:
        parts.append(claude_segment())
    if flags["codex"]:
        parts.append(codex_segment())
    quota = []
    if flags["grok"]:
        quota.append(grok_segment)
    if flags["opencode_go"]:
        quota.append(opencode_go_segment)
    if flags["zai"]:
        quota.append(zai_segment)
    if len(quota) > 1:
        with ThreadPoolExecutor(max_workers=len(quota)) as pool:
            parts.extend(pool.map(lambda fn: fn(), quota))
    else:
        parts.extend(fn() for fn in quota)
    print(" │ ".join(text for text in parts if text))


if __name__ == "__main__":
    main()
