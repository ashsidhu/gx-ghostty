#!/usr/bin/env bash
# crabtail.sh — tail a Claude Code session transcript with color + markdown rendering
# Usage: crabtail.sh [--verbose] [name|session-id|path]
# Requires: bash, jq
# Context: workaround for https://github.com/anthropics/claude-code/issues/2479
#
# Resolution: named session → session ID prefix → direct .jsonl path → most recent

# Auto-detect project dir from cwd
CWD="${CRABTAIL_CWD:-$(pwd)}"
PROJECT_SLUG=$(echo "$CWD" | sed 's|^/||; s|/|-|g')
PROJECT_DIR="$HOME/.claude/projects/-${PROJECT_SLUG}"

if [[ ! -d "$PROJECT_DIR" ]]; then
  PROJECT_DIR=$(ls -dt "$HOME"/.claude/projects/*/ 2>/dev/null | head -1)
  PROJECT_DIR="${PROJECT_DIR%/}"
fi

if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "error: no Claude Code project directory found" >&2
  echo "hint: run from your project root, or set CRABTAIL_CWD=/your/project/path" >&2
  exit 1
fi

VERBOSE=false

while [[ "$1" == --* ]]; do
  case "$1" in
    --verbose) VERBOSE=true; shift ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

resolve_jsonl() {
  local arg="$1"

  if [[ -z "$arg" ]]; then
    ls -t "$PROJECT_DIR"/*.jsonl 2>/dev/null | head -1
    return
  fi

  if [[ "$arg" == *.jsonl && -f "$arg" ]]; then
    echo "$arg"
    return
  fi

  local match
  match=$(ls "$PROJECT_DIR"/"${arg}"*.jsonl 2>/dev/null | head -1)
  if [[ -n "$match" ]]; then
    echo "$match"
    return
  fi

  local file
  for file in $(ls -t "$PROJECT_DIR"/*.jsonl 2>/dev/null); do
    if grep -q '"custom-title"' "$file" 2>/dev/null; then
      local title
      title=$(grep '"custom-title"' "$file" | tail -1 | jq -r '.customTitle // empty' 2>/dev/null)
      if [[ -n "$title" && "${title,,}" == *"${arg,,}"* ]]; then
        echo "$file"
        return
      fi
    fi
  done

  echo "error: no session matching '$arg'" >&2
  return 1
}

JSONL=$(resolve_jsonl "$1") || exit 1

if [[ -z "$JSONL" ]]; then
  echo "error: no sessions found in $PROJECT_DIR" >&2
  exit 1
fi

SESSION_ID=$(basename "$JSONL" .jsonl)
TITLE=$(grep '"custom-title"' "$JSONL" 2>/dev/null | tail -1 | jq -r '.customTitle // empty' 2>/dev/null)
if [[ -n "$TITLE" ]]; then
  echo "▶ $TITLE ($SESSION_ID)"
else
  echo "▶ $SESSION_ID"
fi
echo ""

COLS=$(tput cols 2>/dev/null || echo 80)
(( COLS > 80 )) && COLS=80
HR=$(printf '%*s' "$COLS" '' | tr ' ' '─')

RST=$'\033[0m'
WHITE=$'\033[1;37m'
GREEN=$'\033[32m'
RED=$'\033[31m'
DIM=$'\033[2m'
CYAN=$'\033[36m'
BOLD=$'\033[1m'
ULINE=$'\033[4m'

tail -n +1 -f "$JSONL" | jq -r \
  --arg hr "$HR" \
  --arg rst "$RST" \
  --arg white "$WHITE" \
  --arg green "$GREEN" \
  --arg red "$RED" \
  --arg dim "$DIM" \
  --arg cyan "$CYAN" \
  --arg bold "$BOLD" \
  --arg uline "$ULINE" \
  --argjson verbose "$VERBOSE" '

  def render_md:
    gsub("(?m)^# (?<h>.+)$"; $bold + $uline + .h + $rst) |
    gsub("(?m)^#{2,4} (?<h>.+)$"; $bold + .h + $rst) |
    gsub("\\*\\*(?<b>[^*]+)\\*\\*"; $bold + .b + $rst) |
    gsub("`(?<c>[^`]+)`"; $cyan + .c + $rst) |
    gsub("\\*\\*\\*(?<b>[^*]+)\\*\\*\\*"; $bold + .b + $rst);

  select(.type == "assistant" or .type == "user") |
  if .type == "user" then
    [
      (.message.content // [] |
        if type == "array" then
          .[] | select(.type == "tool_result") |
          if .is_error == true then
            "  " + $red + "✗ " + (
              .content // "" |
              if type == "string" then .[0:200]
              elif type == "array" then map(select(.type == "text") | .text) | join(" ") | .[0:200]
              else ""
              end
            ) + $rst
          elif $verbose then
            "  " + $green + "✓ " + $dim + (
              .content // "" |
              if type == "string" then .[0:200]
              elif type == "array" then map(select(.type == "text") | .text) | join(" ") | .[0:200]
              else ""
              end
            ) + $rst
          else
            "  " + $green + "✓" + $rst
          end
        else empty
        end
      ),
      (.message.content // "" |
        if type == "array" then
          [ .[] | select(.type == "text") | .text ] | join("\n") |
          if length > 0 then "\n" + $hr + "\n" + $cyan + "❯ " + $rst + . + "\n" + $hr else empty end
        elif type == "string" then
          if length > 0 then "\n" + $hr + "\n" + $cyan + "❯ " + $rst + . + "\n" + $hr else empty end
        else empty
        end
      )
    ] | join("\n")
  elif .type == "assistant" then
    [ .message.content[]? |
      if .type == "text" and (.text | length > 0) then
        "\n" + $white + "⏺ " + $rst + (.text | render_md)
      elif .type == "tool_use" then
        "\n  " + $dim + "⏺ " + .name + (
          if .name == "Bash" then " → " + (.input.command // "")
          elif .name == "Read" then " → " + (.input.file_path // "")
          elif .name == "Write" then " → " + (.input.file_path // "")
          elif .name == "Edit" then " → " + (.input.file_path // "")
          elif .name == "Grep" then " → " + (.input.pattern // "")
          elif .name == "Glob" then " → " + (.input.pattern // "")
          elif .name == "Agent" then " → " + (.input.description // "")
          elif .name == "Skill" then " → " + (.input.skill // "")
          else ""
          end
        ) + $rst
      else empty
      end
    ] | join("\n")
  else empty
  end
'
