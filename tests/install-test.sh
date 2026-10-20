#!/bin/bash
set -u
export LC_ALL=C

unset CTX_HOME CLAUDE_DIR CTX_SETTINGS CTX_REPO_URL
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
assert_eq "$(cat "$CTX_HOME/.source")" "$REPO_DIR" "records the checkout it was installed from"
backups_after_first=$(find "$CLAUDE_DIR" -name '*.bak-claude-workstreams-*' | wc -l | tr -d ' ')
"$REPO_DIR/install.sh" >/dev/null 2>&1
assert_eq "$?" "0" "second install succeeds"
assert_eq "$(find "$CLAUDE_DIR" -name '*.bak-claude-workstreams-*' | wc -l | tr -d ' ')" "$backups_after_first" "an unchanged reinstall makes no new backups"

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

FAKE_HOME=$(mktemp -d)
export HOME="$FAKE_HOME"
export GIT_CONFIG_GLOBAL="$FAKE_HOME/.gitconfig"
CUSTOM_HOME="$FAKE_HOME/notes/context"
CTX_HOME="$CUSTOM_HOME" "$REPO_DIR/install.sh" >/dev/null 2>&1
assert_eq "$?" "0" "install into a custom CTX_HOME succeeds"
CUSTOM_BIN="$CUSTOM_HOME/bin/ctx"
assert_eq "$(jq -r '.hooks.UserPromptSubmit[-1].hooks[0].command' "$FAKE_HOME/.claude/settings.json")" "$CUSTOM_BIN hook prompt" "hook points at the custom install"
assert_eq "$(env -u CTX_HOME "$CUSTOM_BIN" new demo "Demo" s1)" "$CUSTOM_HOME/.drafts/s1/demo" "without CTX_HOME the script uses the folder it is installed in"
out=$(jq -cn '{session_id: "s1", cwd: "/tmp", source: "compact"}' | env -u CTX_HOME "$CUSTOM_BIN" hook start | jq -r '.hookSpecificOutput.additionalContext')
assert_contains "$out" "is on workstream \`demo\`" "hooks find the session's workstream in the custom folder"
assert_eq "$([ -e "$FAKE_HOME/.claude/context" ] && echo created || echo absent)" "absent" "the default folder is not created"
env -u CTX_HOME "$REPO_DIR/bin/ctx" list >/dev/null
assert_eq "$([ -e "$REPO_DIR/workstreams" ] && echo polluted || echo clean)" "clean" "running the repo copy does not turn the checkout into a context folder"
assert_eq "$([ -d "$FAKE_HOME/.claude/context/workstreams" ] && echo default)" "default" "the repo copy falls back to ~/.claude/context"
rm -rf "$FAKE_HOME"

commit_as_tester() { git -C "$1" -c user.name=tester -c user.email=tester@example.com commit -q -am "$2"; }

WORK=$(mktemp -d)
mkdir -p "$WORK/snapshot"
(cd "$REPO_DIR" && git ls-files -co --exclude-standard | tar cf - -T -) | (cd "$WORK/snapshot" && tar xf -)
git -C "$WORK/snapshot" init -q -b main
git -C "$WORK/snapshot" add -A
commit_as_tester "$WORK/snapshot" "snapshot"
git clone -q --bare "$WORK/snapshot" "$WORK/upstream.git"
git clone -q "$WORK/upstream.git" "$WORK/checkout"

FAKE_HOME="$WORK/home-a"
mkdir -p "$FAKE_HOME"
export HOME="$FAKE_HOME"
export GIT_CONFIG_GLOBAL="$FAKE_HOME/.gitconfig"
"$WORK/checkout/install.sh" >/dev/null 2>&1
assert_eq "$?" "0" "install from a clone succeeds"
UPDATE_BIN="$FAKE_HOME/.claude/context/bin/ctx"
before_inode=$(ls -i "$UPDATE_BIN" | awk '{print $1}')
out=$("$UPDATE_BIN" update 2>&1)
assert_eq "$?" "0" "update with nothing new succeeds"
assert_contains "$out" "Already up to date" "says it is up to date"

git clone -q "$WORK/upstream.git" "$WORK/dev"
perl -pi -e 's/^CTX_VERSION=1$/CTX_VERSION=2/' "$WORK/dev/bin/ctx"
commit_as_tester "$WORK/dev" "release v2"
git -C "$WORK/dev" push -q origin main
out=$("$UPDATE_BIN" update 2>&1)
assert_eq "$?" "0" "update to a new release succeeds"
assert_contains "$out" "Updated from" "reports the old and new commit"
assert_contains "$out" "ok   start hook answers" "runs the doctor"
out=$(jq -cn '{session_id: "s1", cwd: "/tmp", source: "startup"}' | "$UPDATE_BIN" hook start | jq -r '.hookSpecificOutput.additionalContext' | head -1)
assert_eq "$out" "ctx v2" "the installed script is the new release"
assert_eq "$([ "$(ls -i "$UPDATE_BIN" | awk '{print $1}')" != "$before_inode" ] && echo replaced)" "replaced" "the script is replaced by a new file, not rewritten in place"
assert_eq "$(jq --arg c "$UPDATE_BIN hook start" '[.hooks.SessionStart[].hooks[].command | select(. == $c)] | length' "$FAKE_HOME/.claude/settings.json")" "1" "update keeps one start hook"

echo "local edit" >> "$WORK/checkout/README.md"
out=$("$UPDATE_BIN" update 2>&1)
assert_eq "$?" "1" "update refuses a source with local changes"
assert_contains "$out" "uncommitted changes" "says why"

FAKE_HOME="$WORK/home-b"
mkdir -p "$FAKE_HOME"
export HOME="$FAKE_HOME"
export GIT_CONFIG_GLOBAL="$FAKE_HOME/.gitconfig"
out=$(cd "$WORK" && CTX_REPO_URL="$WORK/upstream.git" bash < "$REPO_DIR/install.sh" 2>&1)
assert_eq "$?" "0" "one-line install without a checkout succeeds"
ONE_LINE_HOME="$FAKE_HOME/.claude/context"
assert_eq "$(cat "$ONE_LINE_HOME/.source")" "$ONE_LINE_HOME/.src" "clones its source into the context folder"
assert_eq "$(jq -cn '{session_id: "s1", cwd: "/tmp", source: "startup"}' | "$ONE_LINE_HOME/bin/ctx" hook start | jq -r '.hookSpecificOutput.additionalContext' | head -1)" "ctx v2" "installs the latest release"
assert_contains "$("$ONE_LINE_HOME/bin/ctx" update 2>&1)" "Already up to date" "update works after a one-line install"
assert_eq "$(git -C "$ONE_LINE_HOME" status --short)" "" "the context repository ignores the source clone and the script"
rm -rf "$WORK"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "all passed"
else
  echo "$FAILURES failed"
  exit 1
fi
