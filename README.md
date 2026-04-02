# gx — Ghostty Terminal Control

Read scrollback, send input, manage windows and splits — without stealing focus or touching the clipboard.

gx is a thin scripting layer on top of [Ghostty](https://ghostty.org). When Ghostty ships these primitives natively, gx becomes redundant by design.

Requires macOS and Ghostty 1.3+.

## Install

### 1. gx binary

```bash
curl -fSL https://github.com/ashsidhu/gx-ghostty/releases/latest/download/gx -o ~/.local/bin/gx
chmod +x ~/.local/bin/gx
```

Or build from source:

```bash
git clone https://github.com/ashsidhu/gx-ghostty.git
cd gx-ghostty
swiftc -O gx.swift -o gx -framework Cocoa
cp gx ~/.local/bin/   # or anywhere on your PATH
```

### 2. Accessibility permission

**System Settings > Privacy & Security > Accessibility > Ghostty**

### 3. it2 shim — optional, for Claude Code teammates

```bash
ln -sf "$(pwd)/gx-ghostty/it2" ~/.local/bin/it2
```

Add to `~/.zshrc`:

```bash
if [[ "$TERM_PROGRAM" == "ghostty" ]]; then
  export ITERM_SESSION_ID="w0t0p0:$(/usr/bin/osascript -e \
    'tell application "Ghostty" to get id of focused terminal of selected tab of front window' 2>/dev/null)"
fi
```

## Quick Start

```bash
$ gx --all list
── window 0: ~/src/myproject [w40286] ──
0  *  ~/src/myproject                    A1B2C3D4-5678-9012-3456-7890ABCDEF01

── window 1: ~/dotfiles [w40301] ──
1  *  ~/dotfiles [left]                  F8FBC13F-CAE4-4A4D-B93D-FF486DA5FC80
2  *  ~/dotfiles [right]                 E454716B-7F2D-49D9-BC4D-CD1B64F3DC3C

$ gx peek w40286 5
ashmeet@mac ~/src/myproject % make test
PASS  tests/auth_test.go (0.12s)
ok    myproject  0.21s

$ gx send F8FBC13F-CAE4-4A4D-B93D-FF486DA5FC80 "git status"
```

## Commands

| Command | Description |
|---|---|
| `gx list` | List surfaces in focused window (with UUIDs) |
| `gx --all list` | List all surfaces across all windows |
| `gx peek <id> [lines]` | Read scrollback (default: 30 lines) |
| `gx send <id> <text>` | Send text + Enter |
| `gx send <id> <text> --no-enter` | Send text without Enter |
| `gx key <id> <name>` | Send key: `enter`, `escape`, `ctrl-c`, `tab`, `backspace`, `space` |
| `gx split <id> [-v\|-h]` | Split terminal, returns UUID |
| `gx spawn [--cwd dir] [-e cmd]` | New window, returns UUID |
| `gx new-tab [--cwd dir]` | New tab, returns UUID |
| `gx close <id>` | Close terminal |
| `gx approve <id> [1-9]` | Approve Claude Code permission prompt |
| `gx deny <id>` | Deny prompt |
| `gx interrupt <id>` | Escape + Ctrl-C ×2 |

## Targeting

| Method | Example | Notes |
|---|---|---|
| UUID | `gx send A1B2C3D4-... "cmd"` | Stable for lifetime, works cross-window |
| Window ID | `gx peek w40286 10` | Stable for window lifetime, works cross-window |
| `focused` | `gx split focused -v` | Front window's focused terminal |
| Numeric index | `gx peek 0 10` | Reshuffles on title change |
| Title substring | `gx peek "myproject" 10` | First match wins |

**Prefer UUIDs for automation.** UUIDs and window IDs work cross-window automatically. Use `--all` for cross-window index/title targeting.

## Peek Ranges

```bash
gx peek <id>           # Last 30 lines (default)
gx peek <id> 100       # Last 100 lines
gx peek <id> +50       # First 50 from top
gx peek <id> 50-100    # Lines 50–100 from bottom
```

Full scrollback buffer via Accessibility — not just the visible viewport.

## Claude Code

gx was built for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) agent orchestration.

The `it2` shim bridges Claude Code's `ITermBackend` to Ghostty — teammates appear as visible split panes instead of invisible subprocesses ([anthropics/claude-code#35351](https://github.com/anthropics/claude-code/issues/35351)). See install step 3.

```bash
UUID=$(gx spawn --cwd ~/project | awk '{print $2}')
gx send "$UUID" "claude"
sleep 8
gx send "$UUID" "/name my-agent"
gx send "$UUID" "implement the auth module"
gx peek "$UUID" 30   # monitor
```

### crabtail — session transcript viewer

Claude Code's [alternate screen buffer](https://github.com/anthropics/claude-code/issues/2479) destroys terminal scrollback. [`crabtail.sh`](tools/crabtail.sh) works around this by tailing the session JSONL in a separate tab — full history, color-coded tool results, basic markdown rendering. Requires `bash` and `jq`.

```bash
crabtail.sh                  # most recent session
crabtail.sh my-session       # by /name (partial match)
```

## Design

- **No daemon.** No background process, no socket, no state between invocations.
- **No clipboard.** All text delivery via AppleScript `input text`, addressed by UUID.
- **No focus steal.** `send`, `peek`, `list`, `split`, `close` never raise windows. Only `key`/`approve`/`deny`/`interrupt` briefly raise (and restore).
- **macOS only.** Ghostty 1.3+, AppleScript for writes, Accessibility for reads.
- **Aligned with Ghostty.** Follows Ghostty's [scripting direction](https://github.com/ghostty-org/ghostty/discussions/2353) — platform-native IPC, no sockets, no daemons.

## License

MIT
