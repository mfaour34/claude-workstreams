#!/bin/bash
set -u
export LC_ALL=C

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FAILURES=0

pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; FAILURES=$((FAILURES + 1)); }

assert_eq() {
  if [ "$1" = "$2" ]; then
    pass "$3"
  else
    fail "$3"
    printf '  expected: %s\n  actual:   %s\n' "$2" "$1"
  fi
}

assert_contains() {
  case "$1" in
    *"$2"*) pass "$3" ;;
    *) fail "$3"; printf '  missing: %s\n' "$2" ;;
  esac
}

FAKE_HOME=$(mktemp -d)
export HOME="$FAKE_HOME"
export GIT_CONFIG_GLOBAL="$FAKE_HOME/.gitconfig"
CLAUDE_DIR="$FAKE_HOME/.claude"
CTX_HOME="$CLAUDE_DIR/context"
CTX_BIN="$CTX_HOME/bin/ctx"
mkdir -p "$CLAUDE_DIR"

jq -n '{model: "example", hooks: {SessionStart: [{hooks: [{type: "command", command: "echo existing-start"}]}], Stop: [{hooks: [{type: "command", command: "echo existing-stop"}]}]}, statusLine: {type: "command", command: "echo my-status", padding: 1}}' > "$CLAUDE_DIR/settings.json"
printf '# My rules\n\nBe brief.\n' > "$CLAUDE_DIR/CLAUDE.md"
cp "$CLAUDE_DIR/settings.json" "$FAKE_HOME/settings.original.json"
cp "$CLAUDE_DIR/CLAUDE.md" "$FAKE_HOME/CLAUDE.original.md"

out=$("$REPO_DIR/install.sh" 2>&1)
assert_eq "$?" "0" "install succeeds"
assert_contains "$out" "ok   start hook answers" "doctor runs at the end"
"$REPO_DIR/install.sh" >/dev/null 2>&1
assert_eq "$?" "0" "second install succeeds"

settings="$CLAUDE_DIR/settings.json"
assert_eq "$(jq --arg c "$CTX_BIN hook start" '[.hooks.SessionStart[].hooks[].command | select(. == $c)] | length' "$settings")" "1" "one start hook after two installs"
assert_eq "$(jq --arg c "$CTX_BIN hook prompt" '[.hooks.UserPromptSubmit[].hooks[].command | select(. == $c)] | length' "$settings")" "1" "one prompt hook after two installs"
assert_eq "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$settings")" "echo existing-start" "existing start hook kept"
assert_eq "$(jq -r '.hooks.Stop[0].hooks[0].command' "$settings")" "echo existing-stop" "other hooks kept"
assert_eq "$(jq -r '.statusLine.command' "$settings")" "$CTX_BIN statusline" "status line wrapped"
assert_eq "$(jq -r '.statusLine.padding' "$settings")" "1" "status line settings kept"
assert_eq "$(cat "$CTX_HOME/.statusline-next")" "echo my-status" "original status line saved"
assert_eq "$(echo '{"session_id":"s1","context_window":{"used_percentage":12}}' | "$CTX_BIN" statusline)" "my-status" "wrapper renders the original"

rules="$CLAUDE_DIR/CLAUDE.md"
assert_contains "$(cat "$rules")" "Be brief." "existing rules kept"
assert_eq "$(grep -c 'claude-workstreams:start' "$rules")" "1" "one rules block after two installs"
assert_contains "$(cat "$rules")" "$CTX_HOME/bin/ctx" "rules point at the installed script"
assert_contains "$(cat "$CLAUDE_DIR/skills/context/SKILL.md")" "$CTX_HOME/bin/ctx" "skill points at the installed script"

out=$(jq -cn '{session_id: "s1", cwd: "/tmp", source: "startup"}' | "$CTX_BIN" hook start | jq -r '.hookSpecificOutput.additionalContext')
assert_contains "$out" "ctx v1" "start hook answers after install"
assert_contains "$("$CTX_BIN" new demo "Demo" s1 2>&1)" "$CTX_HOME/.drafts/s1/demo" "new works without a git identity"

out=$("$REPO_DIR/uninstall.sh" 2>&1)
assert_eq "$?" "0" "uninstall succeeds"
assert_eq "$(jq -S . "$settings")" "$(jq -S . "$FAKE_HOME/settings.original.json")" "settings restored exactly"
assert_eq "$(cat "$rules")" "$(cat "$FAKE_HOME/CLAUDE.original.md")" "rules restored exactly"
assert_eq "$([ -e "$CLAUDE_DIR/skills/context/SKILL.md" ] && echo present || echo removed)" "removed" "skill removed"
assert_eq "$([ -d "$CTX_HOME/workstreams/demo" ] && echo kept)" "kept" "workstreams kept"

rm -rf "$FAKE_HOME"
FAKE_HOME=$(mktemp -d)
export HOME="$FAKE_HOME"
export GIT_CONFIG_GLOBAL="$FAKE_HOME/.gitconfig"
"$REPO_DIR/install.sh" >/dev/null 2>&1
assert_eq "$?" "0" "install into an empty home succeeds"
"$REPO_DIR/uninstall.sh" >/dev/null 2>&1
assert_eq "$(jq -c . "$FAKE_HOME/.claude/settings.json")" "{}" "uninstall leaves empty settings empty"
rm -rf "$FAKE_HOME"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "all passed"
else
  echo "$FAILURES failed"
  exit 1
fi
