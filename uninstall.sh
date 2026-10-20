#!/bin/bash
set -eu
export LC_ALL=C

CTX_HOME="${CTX_HOME:-$HOME/.claude/context}"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
RULES="$CLAUDE_DIR/CLAUDE.md"
SKILL="$CLAUDE_DIR/skills/context/SKILL.md"
CTX_BIN="$CTX_HOME/bin/ctx"
STAMP="$(date +%Y%m%d%H%M%S)"
START_MARKER='<!-- claude-workstreams:start -->'
END_MARKER='<!-- claude-workstreams:end -->'

backup() {
  if [ -s "$1" ]; then
    cp "$1" "$1.bak-claude-workstreams-$STAMP"
  fi
}

uninstall_settings() {
  local original_statusline
  [ -e "$SETTINGS" ] || return 0
  backup "$SETTINGS"
  original_statusline=$(cat "$CTX_HOME/.statusline-next" 2>/dev/null || true)
  jq --arg ctx "$CTX_BIN" --arg original "$original_statusline" '
    def without_ctx: map(select(([.hooks[]?.command] | map((. // "") | startswith($ctx)) | any) | not));
    def drop_if_empty(key): if (.hooks[key] // []) == [] then del(.hooks[key]) else . end;
    (if .hooks.SessionStart then .hooks.SessionStart |= without_ctx else . end)
    | (if .hooks.UserPromptSubmit then .hooks.UserPromptSubmit |= without_ctx else . end)
    | drop_if_empty("SessionStart")
    | drop_if_empty("UserPromptSubmit")
    | (if (.hooks // {}) == {} then del(.hooks) else . end)
    | if (.statusLine.command // "") != ($ctx + " statusline") then .
      elif $original == "" then del(.statusLine)
      else .statusLine.command = $original
      end
  ' "$SETTINGS" > "$SETTINGS.new"
  mv "$SETTINGS.new" "$SETTINGS"
}

uninstall_rules() {
  [ -e "$RULES" ] || return 0
  backup "$RULES"
  awk -v start="$START_MARKER" -v end="$END_MARKER" '
    $0 == start { skip = 1; next }
    skip && $0 == end { skip = 0; next }
    !skip { lines[++count] = $0 }
    END {
      while (count > 0 && lines[count] == "") count--
      for (i = 1; i <= count; i++) print lines[i]
    }
  ' "$RULES" > "$RULES.new"
  mv "$RULES.new" "$RULES"
}

uninstall_skill() {
  rm -f "$SKILL"
  rmdir "$(dirname "$SKILL")" 2>/dev/null || true
}

uninstall_pane() {
  command -v claude >/dev/null 2>&1 || return 0
  claude plugin uninstall workstream-pane@claude-workstreams >/dev/null 2>&1 || true
  claude plugin marketplace remove claude-workstreams >/dev/null 2>&1 || true
}

main() {
  command -v jq >/dev/null 2>&1 || { echo "uninstall: jq is required" >&2; exit 1; }
  uninstall_settings
  uninstall_rules
  uninstall_skill
  uninstall_pane
  echo "Removed the hooks, status line wrapper, rules block, skill and workstream pane."
  echo "Your workstreams are still in $CTX_HOME. Delete that folder yourself if you no longer want them."
}

main "$@"
