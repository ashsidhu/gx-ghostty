---
name: gx
description: Use when interacting with Ghostty terminals — listing, peeking, sending text, managing windows/tabs/splits, or controlling Claude Code teammates
---

# gx — Ghostty Terminal Control

Thinnest possible scripting layer on top of Ghostty. Exists to close the loop until Ghostty ships these primitives natively.

Version: 1.3.3
Source: `gx.swift`
Binary: Build with `swiftc -O gx.swift -o gx -framework Cocoa`, then place `gx` on your PATH.
Requires: Accessibility permission + Ghostty 1.3+

## Build

```bash
swiftc -O gx.swift -o gx -framework Cocoa
```

## it2 Shim — Claude Code Native Teammates

Claude Code's ITermBackend detects `ITERM_SESSION_ID` and calls `it2 session {list,split,run,close}`. The shim translates to `gx` commands with UUID targeting.

```bash
# Install (from repo root)
chmod +x tools/it2
ln -sf "$(pwd)/tools/it2" ~/.local/bin/it2

# ~/.zshrc (captures terminal UUID at shell startup)
if [[ "$TERM_PROGRAM" == "ghostty" ]]; then
  export ITERM_SESSION_ID="w0t0p0:$(/usr/bin/osascript -e \
    'tell application "Ghostty" to get id of focused terminal of selected tab of front window' 2>/dev/null)"
fi
```

| it2 | gx |
|---|---|
| `it2 session list` | `gx --all list` |
| `it2 session split [-v] [-s UUID]` | `gx split <UUID\|focused> [-v\|-h]` |
| `it2 session run -s UUID cmd` | `gx send UUID "cmd"` |
| `it2 session close -s UUID` | `gx close UUID` |

**Caveat:** `source ~/.zshrc` overwrites `ITERM_SESSION_ID` with whatever terminal is focused at that moment. Open a new terminal instead.

## Commands

All text delivery goes through AppleScript — zero clipboard, zero focus steal.

### Observe

| Command | Description |
|---|---|
| `gx list` | List surfaces in focused window (with UUIDs) |
| `gx --all list` | List all surfaces across all windows |
| `gx peek <id> [lines\|range]` | Read scrollback (default: last 30 lines) |
| `gx peek-all [lines]` | Scan all surfaces (default: 5 lines each) |
| `gx focused` | Print focused window index |
| `gx dump [id]` | Dump accessibility tree (debug) |

### Act

| Command | Description |
|---|---|
| `gx send <id> <text>` | Send text + Enter (AS, any target type) |
| `gx send <id> <text> --no-enter` | Send text without Enter |
| `gx key <id> <keyname>` | Send key: enter, escape, ctrl-c, tab, backspace, space |
| `gx approve <id> [1-9]` | Approve Claude Code permission prompt |
| `gx deny <id>` | Deny prompt (sends 3+Enter) |
| `gx interrupt <id>` | Escape + Ctrl-C ×2 |

### Manage

| Command | Description |
|---|---|
| `gx spawn [--cwd dir] [-e cmd]` | New window, returns UUID |
| `gx new-tab [--cwd dir]` | New tab, returns UUID |
| `gx split <id> [-v\|-h]` | Split terminal, returns UUID |
| `gx close <id>` | Close terminal |

## Targeting

All target types resolve to UUID via `resolveToUUID` before hitting the AS path.

| Method | Example | Stability |
|---|---|---|
| UUID | `gx send A1B2C3D4-... "cmd"` | Stable for terminal lifetime |
| Window ID | `gx peek w40286 10` | Stable for window lifetime |
| `focused` | `gx split focused -v` | Front window's focused terminal |
| Numeric index | `gx peek 0 10` | Reshuffles on title change |
| Title substring | `gx peek "myproject" 10` | First match wins |

**Prefer UUIDs for automation.** UUIDs and window IDs (`wNNNNN`) work cross-window without `--all`. Use `--all` for cross-window `list` and index/title targeting.

## Peek Ranges

```bash
gx peek <id>           # Last 30 lines (default)
gx peek <id> 100       # Last 100 lines
gx peek <id> +50       # First 50 from top
gx peek <id> 50-100    # Lines 50–100 from bottom
```

Full scrollback buffer via AX — not just the visible viewport.

## Agent Dispatch

```bash
UUID=$(gx spawn --cwd ~/project | awk '{print $2}')
gx send "$UUID" "claude"
sleep 8
gx send "$UUID" "/name my-agent"
gx send "$UUID" "implement the auth module"
gx peek "$UUID" 30   # monitor
```

## Ghostty AS API (1.3.1 SDEF)

What gx uses vs what's available but unused:

```applescript
-- Used by gx
input text "cmd" to terminal id "UUID"           -- send
send key "enter" to terminal id "UUID"            -- send
split terminal id "UUID" direction right          -- split
close terminal id "UUID"                          -- close
get id of every terminal of every tab of w         -- list (all tabs)

-- Available but NOT yet used
send key "c" modifiers "control" to terminal id "UUID"  -- would replace withFocus for key/approve/deny
new window with configuration cfg                        -- would replace Cmd+N postKey
new tab in window with configuration cfg                 -- would replace Cmd+T postKey
get working directory of terminal id "UUID"              -- cwd query
perform action "action_string" on terminal id "UUID"     -- any Ghostty action
```

`surface configuration` record supports: `initial working directory`, `command`, `initial input`, `environment variables`, `wait after command`, `font size`.
