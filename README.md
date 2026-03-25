# gx — Ghostty Terminal Control

The thinnest possible scripting layer on top of [Ghostty](https://ghostty.org). Read scrollback, send input, manage windows and splits — without stealing focus or touching the clipboard.

gx exists because Ghostty doesn't yet ship these primitives natively. The moment Ghostty does, gx becomes redundant by design. Until then, it closes the loop.

## Install — point your agent here

Copy-paste this into your preferred agent:

```
Install gx following the instructions at https://github.com/ashsidhu/gx-ghostty#install
```

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

### 2. it2 shim — optional, for Claude Code teammates

```bash
git clone https://github.com/ashsidhu/gx-ghostty.git  # skip if already cloned
ln -sf "$(pwd)/gx-ghostty/it2" ~/.local/bin/it2
```

### 3. Shell hook — optional, for Claude Code teammates

Append to `~/.zshrc` (or `~/.bashrc`):

```bash
# gx: Ghostty terminal UUID for Claude Code teammate targeting
if [[ "$TERM_PROGRAM" == "ghostty" ]]; then
  export ITERM_SESSION_ID="w0t0p0:$(/usr/bin/osascript -e \
    'tell application "Ghostty" to get id of focused terminal of selected tab of front window' 2>/dev/null)"
fi
```

Then open a new terminal.

### 4. Accessibility permission

Grant to Ghostty: **System Settings > Privacy & Security > Accessibility > Ghostty**. Ghostty's AppleScript API can write to terminals (send text, split, close) but has no read API. Reading scrollback requires the macOS Accessibility framework, which needs this permission.

---

Requires macOS and Ghostty 1.3+. gx major.minor tracks the Ghostty API version it depends on; patch is gx's own.

## Alignment with Ghostty

gx follows Ghostty's [scripting direction](https://github.com/ghostty-org/ghostty/discussions/2353): platform-native IPC, not a custom protocol. On macOS, that means AppleScript for writes and Accessibility API for reads — no sockets, no daemons, no state between invocations.

As Ghostty's AppleScript surface grows (e.g. `send key` with modifiers, non-activating window creation, a read property on the terminal class), gx will drop its AX dependencies one by one. The goal is to eventually be pure AppleScript — and then to be unnecessary, because Ghostty's own CLI or API covers it all.

## Surface

Seven operations, matching the API that tools like [agentd](https://github.com/robmorgan/agentd), [cmux](https://github.com/manaflow-ai/cmux), and [pi-interactive-subagents](https://github.com/HazAT/pi-interactive-subagents) are converging on:

1. **Create** — `spawn`, `new-tab`, `split`
2. **List** — `list`, `focused`
3. **Write** — `send`, `key`, `approve`, `deny`, `interrupt`
4. **Read** — `peek`, `peek-all`
5. **Destroy** — `close`
6. **Meta** — targeting by UUID, wNNNNN, index, title, or `focused`
7. ~~Signal~~ — not yet (no structured attention events; Ghostty would need to expose notification state)

## Not gx

- **Not a daemon.** No background process, no socket, no state between invocations.
- **Not a multiplexer.** gx scripts Ghostty; it doesn't replace it.
- **Not a framework.** No plugins, no config files, no extension API.
- **Not portable.** macOS only, Ghostty 1.3+ only. Single-terminal-emulator scope.
- **Not a clipboard user.** Zero `NSPasteboard` calls. All text delivery goes through Ghostty's AppleScript `input text` API, addressed by UUID.

If Ghostty ships native scripting that covers these primitives, delete gx.

## Architecture

AppleScript for all writes (send, split, close, spawn text delivery, new-tab text delivery — zero clipboard, zero focus steal for text delivery). AX for reads (peek, list, pane discovery). Every target type resolves to a UUID via `resolveToUUID` before hitting the AS path.

```bash
$ gx --all list
── window 0: ~/src/myproject [w40286] ──
0  *  ~/src/myproject                    A1B2C3D4-5678-9012-3456-7890ABCDEF01

── window 1: ~/dotfiles [w40301] ──
1  *  ~/dotfiles [left]                  F8FBC13F-CAE4-4A4D-B93D-FF486DA5FC80
2  *  ~/dotfiles [right]                 E454716B-7F2D-49D9-BC4D-CD1B64F3DC3C

$ gx --all peek w40286 5
ashmeet@mac ~/src/myproject % make test
PASS  tests/auth_test.go (0.12s)
PASS  tests/api_test.go (0.08s)
ok    myproject  0.21s

$ gx send F8FBC13F-CAE4-4A4D-B93D-FF486DA5FC80 "git status"
```

## Commands

### Observe

| Command | Description | API |
|---|---|---|
| `gx list` | List surfaces in focused window (`*` = active tab, with UUIDs) | AX + AS |
| `gx --all list` | List surfaces across all Ghostty windows | AX + AS |
| `gx peek <id> [range]` | Read terminal scrollback (default: last 30 lines) | AX |
| `gx peek-all [lines]` | Scan all surfaces (default: 5 lines each) | AX |
| `gx focused` | Print focused window index | AX |
| `gx dump [id]` | Dump the raw accessibility tree (debug) | AX |

### Act

| Command | Description | API |
|---|---|---|
| `gx send <id> <text>` | Send text + Enter | AS |
| `gx send <id> <text> --no-enter` | Send text without Enter | AS |
| `gx key <id> <name>` | Send a key: `enter`, `escape`, `ctrl-c`, `tab`, `backspace`, `space` | AX |
| `gx approve <id> [1-9]` | Send a digit key + Enter | AX |
| `gx deny <id>` | Send `3` + Enter | AX |
| `gx interrupt <id>` | Escape, then Ctrl-C twice | AX |

### Manage

| Command | Description | API |
|---|---|---|
| `gx split <id> [-v\|-h]` | Split terminal (default: -h horizontal), returns UUID | AS |
| `gx spawn [--cwd dir] [-e cmd]` | Open a new Ghostty window, returns UUID | AS |
| `gx new-tab [--cwd dir]` | Open a new tab, returns UUID | AS |
| `gx close <id>` | Close a terminal | AS |

## Peek Ranges

```bash
gx peek <id>           # Last 30 lines (default)
gx peek <id> 100       # Last 100 lines
gx peek <id> +50       # First 50 lines from top of scrollback
gx peek <id> 50-100    # Lines 50–100 from the bottom
```

Ghostty exposes the **full scrollback buffer** via its accessibility tree — not just the visible viewport. Thousands of lines are readable.

## Targeting

Every surface gets a numeric index, a stable window ID, and a Ghostty terminal UUID:

```
── window 0: ~/src/myproject [w40286] ──
0  *  ~/src/myproject    A1B2C3D4-5678-9012-3456-7890ABCDEF01
```

| Method | Example | Stability |
|---|---|---|
| UUID | `gx send A1B2C3D4-... "cmd"` | Stable for terminal lifetime, survives any rearrangement |
| Window ID | `gx peek w40286 10` | Stable for window lifetime, survives title changes |
| `focused` | `gx split focused -v` | Resolves to focused terminal in front window |
| Numeric index | `gx peek 0 10` | Reshuffles when window titles change |
| Title substring | `gx peek "myproject" 10` | First match wins |

**Prefer UUIDs for automation** — they're immutable for the terminal's lifetime regardless of window rearrangement, pane moves, or title changes. Window IDs (`w<id>`) are second best. Numeric indices are convenient for interactive use only.

### Scoping

By default, gx only sees the focused window.

| Flag | Effect |
|---|---|
| `--all` | Operate across all Ghostty windows |
| `--window <n\|title>` | Scope to a specific window by index or title |
| `GX_WINDOW=<n\|title>` | Same as `--window`, via environment variable |

## Split Panes

Create splits with `gx split` and target them by UUID:

```bash
$ gx split focused -v
Created new pane: E454716B-7F2D-49D9-BC4D-CD1B64F3DC3C

$ gx send E454716B-7F2D-49D9-BC4D-CD1B64F3DC3C "echo hello"
sent E454716B-7F2D-49D9-BC4D-CD1B64F3DC3C

$ gx close E454716B-7F2D-49D9-BC4D-CD1B64F3DC3C
closed E454716B-7F2D-49D9-BC4D-CD1B64F3DC3C
```

Nested splits compound positions: `[top]`, `[bottom/left]`, `[bottom/right]`, etc. Each pane can be peeked, sent to, and closed independently.

## Claude Code

gx was built for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) agent orchestration. These features exist specifically for that use case.

### it2 shim — native teammates in Ghostty

Claude Code has an `ITermBackend` that splits panes, sends text, and closes terminals via an `it2` binary. The `it2` shim translates those calls into `gx split`, `gx send`, `gx close` — making Claude Code teammates appear as visible Ghostty split panes instead of invisible subprocesses.

Setup: steps 2 and 3 in [Install](#install).

**Caveat:** `source ~/.zshrc` overwrites `ITERM_SESSION_ID` with whatever terminal is focused at that moment. Always open a new terminal instead of re-sourcing.

### Permission prompt control

Claude Code pauses for user approval on tool calls. These commands answer the prompt without human intervention:

| Command | What it does | Use case |
|---|---|---|
| `gx approve <id> [1-9]` | Send digit + Enter | Accept a permission prompt (1=Yes, 2=Yes always, etc.) |
| `gx deny <id>` | Send `3` + Enter | Reject a permission prompt |
| `gx interrupt <id>` | Escape + Ctrl-C ×2 | Abort a running agent |

Currently use AX `withFocus` (briefly raises window). Migrating to pure AS in a future version.

### Agent dispatch workflow

```bash
# Spawn a new window, get its UUID
UUID=$(gx spawn --cwd ~/project | awk '{print $2}')

# Start Claude Code in it
gx send "$UUID" "claude"
sleep 8  # wait for Claude to initialize

# Name and task it
gx send "$UUID" "/name my-agent"
gx send "$UUID" "implement the auth module"

# Monitor from your own terminal (no focus steal)
gx peek "$UUID" 30
```

`spawn` returns the UUID directly — no intermediate `gx list` needed to find the new window.

### What's Claude Code-specific

| Feature | Why it exists |
|---|---|
| `it2` shim | Bridge Claude Code's ITermBackend to Ghostty |
| `approve` / `deny` | Answer Claude Code permission prompts programmatically |
| `interrupt` | Abort a running Claude Code agent |
| `spawn` returning UUID | Enable immediate `send` to a new agent window without `list` lookup |
| `peek` with ranges | Read agent scrollback for status monitoring |
| `--all` flag | Operate across all agent windows from one terminal |

Everything else (list, send, split, close, peek) is general-purpose terminal scripting.

## Internals

### What touches focus

| Command | Raises window? | Touches clipboard? |
|---|---|---|
| `list`, `peek`, `peek-all`, `focused`, `dump` | No | No |
| `send` (any target) | No | No |
| `split`, `close` | No | No |
| `key`, `approve`, `deny`, `interrupt` | Yes (restores after) | No |
| `spawn`, `new-tab` | Yes (Cmd+N/Cmd+T opens window) | No |

### AX↔AppleScript correlation

`gx list` needs both AX data (index, active state, pane positions) and AppleScript data (UUIDs). Correlated by `asAllWindowTerminals()` — one AS call enumerates every window's terminal UUIDs in order, matched to AX surfaces by ordinal window position + terminal count. No title matching (avoids spinner rotation + focused-pane title shift).

### Stable window IDs

`_AXUIElementGetWindow` (undocumented but stable macOS API used by many window managers) extracts `CGWindowID` from AX elements. Persists for window lifetime, survives title changes.

### Ghostty AS API coverage (1.3.1 SDEF)

Confirmed via `sdef /Applications/Ghostty.app`:

| AS capability | gx uses? | Notes |
|---|---|---|
| `input text` to terminal | Yes | All `send` text delivery |
| `send key` with name | Yes | `enter`, `escape`, `tab`, `space`, `backspace`, `delete`, single letters |
| `send key` with `modifiers` param | **Not yet** | `"control"`, `"shift"`, `"option"`, `"command"` — would eliminate `withFocus` for key commands |
| `new window` with `surface configuration` | **Not yet** | Sets cwd, command, env vars, returns window directly — would eliminate `Cmd+N` + UUID diff |
| `new tab` with `surface configuration` | **Not yet** | Same as above for tabs |
| `working directory` on terminal | **Not yet** | Read-only cwd property |
| `perform action` on terminal | **Not yet** | Execute any Ghostty action string |
| `name` on terminal | Read only | Title; no `set_title` via AS |

## Compatibility

Requires **Ghostty 1.3+** (AppleScript API). No fallback for older versions.

## License

MIT
