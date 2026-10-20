#!/bin/bash
set -eu
export LC_ALL=C

CTX_HOME="${CTX_HOME:-$HOME/.claude/context}"
CTX_REPO_URL="${CTX_REPO_URL:-https://github.com/mfaour34/claude-workstreams.git}"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
RULES="$CLAUDE_DIR/CLAUDE.md"
SKILL="$CLAUDE_DIR/skills/context/SKILL.md"
CTX_BIN="$CTX_HOME/bin/ctx"
STAMP="$(date +%Y%m%d%H%M%S)"
START_MARKER='<!-- claude-workstreams:start -->'
END_MARKER='<!-- claude-workstreams:end -->'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

die() { echo "install: $*" >&2; exit 1; }

require() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

is_checkout() {
  [ -f "$1/install.sh" ] && [ -f "$1/bin/ctx" ] && [ -f "$1/claude/CLAUDE.md.snippet" ]
}

fetch_source() {
  local source="$CTX_HOME/.src"
  if [ -d "$source/.git" ]; then
    git -C "$source" pull -q --ff-only || die "cannot update $source"
  else
    mkdir -p "$CTX_HOME"
    git clone -q "$CTX_REPO_URL" "$source" || die "cannot clone $CTX_REPO_URL"
  fi
  echo "$source"
}

render() {
  sed "s#@CTX_HOME@#$CTX_HOME#g" "$1"
}

backup() {
  if [ -s "$1" ]; then
    cp "$1" "$1.bak-claude-workstreams-$STAMP"
  fi
}

replace_if_changed() {
  if [ -e "$1" ] && cmp -s "$1" "$2"; then
    rm -f "$2"
    return 0
  fi
  backup "$1"
  mv "$2" "$1"
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
  local staged="$CTX_BIN.new.$$"
  mkdir -p "$CTX_HOME/bin"
  cp "$REPO_DIR/bin/ctx" "$staged"
  chmod +x "$staged"
  if [ -e "$CTX_BIN" ] && cmp -s "$CTX_BIN" "$staged"; then
    rm -f "$staged"
  else
    mv "$staged" "$CTX_BIN"
  fi
  CTX_HOME="$CTX_HOME" "$CTX_BIN" list >/dev/null
  printf '%s\n' "$REPO_DIR" > "$CTX_HOME/.source"
}

install_settings() {
  local current_statusline
  mkdir -p "$CLAUDE_DIR"
  [ -e "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  jq empty "$SETTINGS" 2>/dev/null || die "$SETTINGS is not valid JSON"
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
  replace_if_changed "$SETTINGS" "$SETTINGS.new"
}

install_rules() {
  local kept
  touch "$RULES"
  kept=$(without_block "$RULES")
  {
    if [ -n "$kept" ]; then
      printf '%s\n\n' "$kept"
    fi
    render "$REPO_DIR/claude/CLAUDE.md.snippet"
  } > "$RULES.new"
  replace_if_changed "$RULES" "$RULES.new"
}

install_skill() {
  mkdir -p "$(dirname "$SKILL")"
  render "$REPO_DIR/claude/skills/context/SKILL.md" > "$SKILL.new"
  replace_if_changed "$SKILL" "$SKILL.new"
}

setup_remote() {
  mkdir -p "$CTX_HOME"
  [ -d "$CTX_HOME/.git" ] || git -C "$CTX_HOME" init -q -b main || die "cannot init git in $CTX_HOME"
  if git -C "$CTX_HOME" remote get-url origin >/dev/null 2>&1; then
    git -C "$CTX_HOME" remote set-url origin "$1"
  else
    git -C "$CTX_HOME" remote add origin "$1"
  fi
  git -C "$CTX_HOME" fetch -q origin || die "cannot fetch $1"
  if ! git -C "$CTX_HOME" rev-parse -q --verify HEAD >/dev/null && git -C "$CTX_HOME" rev-parse -q --verify refs/remotes/origin/main >/dev/null; then
    git -C "$CTX_HOME" checkout -q -B main origin/main || die "cannot check out origin/main in $CTX_HOME"
    echo "Took the workstreams from $1."
  elif git -C "$CTX_HOME" rev-parse -q --verify refs/remotes/origin/main >/dev/null && ! git -C "$CTX_HOME" merge-base --is-ancestor origin/main HEAD 2>/dev/null; then
    echo "$1 has commits this folder lacks; run $CTX_BIN pull after the install."
  fi
  git -C "$CTX_HOME" config ctx.dailypush true
  echo "Daily push to $1 is on: the first session start of each day pushes new commits."
}

install_pane() {
  command -v claude >/dev/null 2>&1 || die "--with-pane needs the claude CLI on PATH"
  claude plugin marketplace add "$REPO_DIR" >/dev/null 2>&1 || claude plugin marketplace update claude-workstreams >/dev/null 2>&1 || true
  claude plugin install workstream-pane@claude-workstreams >/dev/null || die "could not install the workstream pane; run: claude plugin install workstream-pane@claude-workstreams"
  echo "Installed the workstream pane (plugin workstream-pane@claude-workstreams, read from $REPO_DIR/pane)."
}

main() {
  local source with_pane=0 remote="" args=("$@")
  while [ $# -gt 0 ]; do
    case "$1" in
      --with-pane) with_pane=1 ;;
      --remote)
        [ $# -ge 2 ] && [ -n "$2" ] || die "--remote needs a git URL"
        remote="$2"
        shift
        ;;
      --remote=*) remote="${1#--remote=}" ;;
      *) die "unknown option: $1 (options: --with-pane, --remote <git url>)" ;;
    esac
    shift
  done
  require jq
  require git
  require awk
  if ! is_checkout "$SCRIPT_DIR"; then
    source=$(fetch_source)
    exec env CTX_HOME="$CTX_HOME" CTX_REPO_URL="$CTX_REPO_URL" CLAUDE_DIR="$CLAUDE_DIR" bash "$source/install.sh" ${args[@]+"${args[@]}"}
  fi
  REPO_DIR="$SCRIPT_DIR"
  if [ -n "$remote" ]; then
    setup_remote "$remote"
  fi
  install_script
  install_settings
  install_rules
  install_skill
  if [ "$with_pane" -eq 1 ]; then
    install_pane
  fi
  echo "Installed claude-workstreams into $CTX_HOME from $REPO_DIR."
  echo
  CTX_HOME="$CTX_HOME" CTX_SETTINGS="$SETTINGS" "$CTX_BIN" doctor
  echo
  echo "Start a new Claude Code session: it will ask which workstream it belongs to."
  echo "Update later with: $CTX_BIN update"
}

main "$@"
