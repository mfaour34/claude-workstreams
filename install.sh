#!/bin/bash
set -eu
export LC_ALL=C

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
CTX_HOME="${CTX_HOME:-$HOME/.claude/context}"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
RULES="$CLAUDE_DIR/CLAUDE.md"
SKILL="$CLAUDE_DIR/skills/context/SKILL.md"
CTX_BIN="$CTX_HOME/bin/ctx"
STAMP="$(date +%Y%m%d%H%M%S)"
START_MARKER='<!-- claude-workstreams:start -->'
END_MARKER='<!-- claude-workstreams:end -->'

die() { echo "install: $*" >&2; exit 1; }

require() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

render() {
  sed "s#@CTX_HOME@#$CTX_HOME#g" "$1"
}

backup() {
  if [ -s "$1" ]; then
    cp "$1" "$1.bak-claude-workstreams-$STAMP"
  fi
}

without_block() {
  awk -v start="$START_MARKER" -v end="$END_MARKER" '
    $0 == start { skip = 1; next }
    skip && $0 == end { skip = 0; next }
    !skip { lines[++count] = $0 }
    END {
      while (count > 0 && lines[count] == "") count--
      for (i = 1; i <= count; i++) print lines[i]
    }
  ' "$1"
}

install_script() {
  mkdir -p "$CTX_HOME/bin"
  cp "$REPO_DIR/bin/ctx" "$CTX_BIN"
  chmod +x "$CTX_BIN"
  CTX_HOME="$CTX_HOME" "$CTX_BIN" list >/dev/null
}

install_settings() {
  local current_statusline
  mkdir -p "$CLAUDE_DIR"
  [ -e "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  jq empty "$SETTINGS" 2>/dev/null || die "$SETTINGS is not valid JSON"
  backup "$SETTINGS"
  current_statusline=$(jq -r '.statusLine.command // empty' "$SETTINGS")
  if [ -n "$current_statusline" ] && [ "$current_statusline" != "$CTX_BIN statusline" ]; then
    printf '%s\n' "$current_statusline" > "$CTX_HOME/.statusline-next"
  fi
  jq --arg ctx "$CTX_BIN" '
    def without_ctx: map(select(([.hooks[]?.command] | map((. // "") | startswith($ctx)) | any) | not));
    .hooks.SessionStart = (((.hooks.SessionStart // []) | without_ctx) + [{hooks: [{type: "command", command: ($ctx + " hook start"), timeout: 5}]}])
    | .hooks.UserPromptSubmit = (((.hooks.UserPromptSubmit // []) | without_ctx) + [{hooks: [{type: "command", command: ($ctx + " hook prompt"), timeout: 5}]}])
    | .statusLine = ((.statusLine // {}) + {type: "command", command: ($ctx + " statusline")})
  ' "$SETTINGS" > "$SETTINGS.new"
  mv "$SETTINGS.new" "$SETTINGS"
}

install_rules() {
  local kept
  touch "$RULES"
  backup "$RULES"
  kept=$(without_block "$RULES")
  {
    if [ -n "$kept" ]; then
      printf '%s\n\n' "$kept"
    fi
    render "$REPO_DIR/claude/CLAUDE.md.snippet"
  } > "$RULES.new"
  mv "$RULES.new" "$RULES"
}

install_skill() {
  mkdir -p "$(dirname "$SKILL")"
  if [ -e "$SKILL" ] && ! render "$REPO_DIR/claude/skills/context/SKILL.md" | cmp -s - "$SKILL"; then
    backup "$SKILL"
  fi
  render "$REPO_DIR/claude/skills/context/SKILL.md" > "$SKILL"
}

main() {
  require jq
  require git
  require awk
  install_script
  install_settings
  install_rules
  install_skill
  echo "Installed claude-workstreams into $CTX_HOME."
  echo
  CTX_HOME="$CTX_HOME" CTX_SETTINGS="$SETTINGS" "$CTX_BIN" doctor
  echo
  echo "Start a new Claude Code session: it will ask which workstream it belongs to."
}

main "$@"
