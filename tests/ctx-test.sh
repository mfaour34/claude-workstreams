#!/bin/bash
set -u
export LC_ALL=C

CTX="$(cd "$(dirname "$0")/../bin" && pwd)/ctx"
TAB="$(printf '\t')"
TODAY="$(date +%Y-%m-%d)"
FAILURES=0
CURRENT_TEST=""

setup() { CTX_HOME=$(mktemp -d); export CTX_HOME; }
teardown() { rm -rf "$CTX_HOME"; }

pass() { echo "ok   $CURRENT_TEST: $1"; }
fail() { echo "FAIL $CURRENT_TEST: $1"; FAILURES=$((FAILURES + 1)); }

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
    *) fail "$3"; printf '  missing: %s\n  in: %s\n' "$2" "$1" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3"; printf '  unexpected: %s\n' "$2" ;;
    *) pass "$3" ;;
  esac
}

write_workstream() {
  mkdir -p "$CTX_HOME/workstreams/$1"
  cat > "$CTX_HOME/workstreams/$1/now.md" <<EOF
---
title: $2
status: $6
repos: $4
summary: $3
updated: $5
---

## Goal
EOF
}

write_valid_workstream() {
  mkdir -p "$1/queries"
  cat > "$1/now.md" <<'EOF'
---
title: Alpha
status: active
repos: billing-api
summary: Alpha summary
updated: 2026-10-20
---

## Goal

Ship alpha.

## Now

Building.

## Next steps

1. Test.
EOF
  echo '- D2 | 2026-10-19 | active | Use a mkdir lock. Why: macOS has no flock. Sources: S1' > "$1/decisions.md"
  echo '- D1 | 2026-10-12 | replaced by D2 on 2026-10-19 | Use flock.' > "$1/history.md"
  echo '- F1 | checked 2026-10-19 | S1, S2 | active | The vendor API answers 404 for unsplit orders' > "$1/facts.md"
  printf '%s\n' '- S1 | code | checked 2026-10-19 | origin/main@1a2b3c4:src/x.ts:42' '- S2 | sql | checked 2026-10-19 | queries/S2.sql (prod db, read-only)' > "$1/sources.md"
  echo 'SELECT count(*) FROM orders;' > "$1/queries/S2.sql"
  echo '- 2026-10-20 s1: started' > "$1/log.md"
  : > "$1/traps.md"
  echo '- PR https://github.com/example/app/pull/1' > "$1/artifacts.md"
}

write_now() {
  cat > "$1/now.md" <<EOF
---
title: Alpha
status: active
repos: -
summary: Alpha
updated: $TODAY
---

## Goal

## Now

$2

## Next steps
EOF
}

lint_after_appending() {
  local dir="$CTX_HOME/fixture"
  write_valid_workstream "$dir"
  printf '%s\n' "$2" >> "$dir/$1"
  "$CTX" lint "$dir"
}

hook_start_input() {
  jq -cn --arg s "$1" --arg c "$2" --arg src "$3" '{session_id: $s, cwd: $c, source: $src, hook_event_name: "SessionStart"}'
}

hook_prompt_input() {
  jq -cn --arg s "$1" --arg c "$2" --arg p "$3" --arg t "${4:-/nonexistent/transcript.jsonl}" '{session_id: $s, cwd: $c, prompt: $p, transcript_path: $t, hook_event_name: "UserPromptSubmit"}'
}

write_transcript() {
  {
    echo '{"type":"user","message":{"content":"hi"}}'
    jq -cn --argjson tokens "$2" '{type: "assistant", isSidechain: false, message: {usage: {input_tokens: 2, cache_read_input_tokens: ($tokens - 2), cache_creation_input_tokens: 0}}}'
  } > "$1"
}

additional_context() { jq -r '.hookSpecificOutput.additionalContext // empty'; }

now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }

set_usage() {
  mkdir -p "$CTX_HOME/.usage"
  echo "$2" > "$CTX_HOME/.usage/$1"
}

age_files() { find "$1" -exec touch -t 202001010000 {} +; }

run_tests() {
  local test_name
  for test_name in $(declare -F | awk '{print $3}' | grep '^test_'); do
    CURRENT_TEST="$test_name"
    setup
    "$test_name"
    teardown
  done
  echo
  if [ "$FAILURES" -eq 0 ]; then
    echo "all passed"
  else
    echo "$FAILURES failed"
    exit 1
  fi
}

test_new_creates_workstream_draft_and_commit() {
  local out main="$CTX_HOME/workstreams/invoice-export"
  out=$("$CTX" new invoice-export "Invoice export" s1)
  assert_eq "$out" "$CTX_HOME/.drafts/s1/invoice-export" "prints the draft path"
  assert_contains "$(cat "$main/now.md")" "status: active" "status is active"
  assert_contains "$(cat "$main/now.md")" "summary: Invoice export" "summary starts as the title"
  assert_eq "$(ls "$main" | tr '\n' ' ')" "artifacts.md decisions.md facts.md history.md log.md now.md sources.md traps.md " "has every section file"
  assert_eq "$(git -C "$CTX_HOME" log -1 --format=%s)" "invoice-export: create" "commits on main"
  assert_eq "$(diff -r "$main" "$out" >/dev/null && echo same)" "same" "draft is a copy of main"
  assert_eq "$("$CTX" lint "$main")" "ok" "the template passes lint"
}

test_new_rejects_bad_duplicate_and_missing_session() {
  "$CTX" new Bad_Slug "x" s1 2>/dev/null
  assert_eq "$?" "1" "rejects an invalid slug"
  "$CTX" new none "x" s1 2>/dev/null
  assert_eq "$?" "1" "rejects the reserved slug none"
  "$CTX" new alpha "x" 2>/dev/null
  assert_eq "$?" "1" "requires a session"
  "$CTX" new dup "x" s1 >/dev/null
  "$CTX" new dup "x" s1 2>/dev/null
  assert_eq "$?" "1" "rejects a duplicate"
}

test_list_renders_active_then_paused_newest_first() {
  local out expected
  write_workstream older "Older" "older summary" "billing-api" 2026-10-01 active
  write_workstream newer "Newer" "newer summary" "web-app" 2026-10-15 active
  write_workstream parked "Parked" "parked summary" "docs-site" 2026-10-10 paused
  write_workstream finished "Finished" "done summary" "docs-site" 2026-10-12 done
  out=$("$CTX" list)
  expected="# Workstreams

Generated by ctx. Do not edit by hand.

## Active

- newer: newer summary · web-app · updated 2026-10-15 · 0 sessions
- older: older summary · billing-api · updated 2026-10-01 · 0 sessions

## Paused

- parked: parked summary · docs-site · updated 2026-10-10 · 0 sessions"
  assert_eq "$out" "$expected" "active then paused, newest first, done left out"
  assert_eq "$(cat "$CTX_HOME/state.md")" "$expected" "writes state.md"
}

test_existing_gitignore_gets_new_entries() {
  "$CTX" list >/dev/null
  printf '%s\n' state.md .sessions.tsv > "$CTX_HOME/.gitignore"
  git -C "$CTX_HOME" -c user.name=t -c user.email=t@example.com commit -qam "old gitignore"
  "$CTX" list >/dev/null
  assert_contains "$(cat "$CTX_HOME/.gitignore")" ".src/" "adds the source clone"
  assert_contains "$(cat "$CTX_HOME/.gitignore")" "bin/" "adds the installed script"
  assert_eq "$(grep -cx state.md "$CTX_HOME/.gitignore")" "1" "keeps existing lines once"
  assert_eq "$(git -C "$CTX_HOME" log -1 --format=%s)" "Update gitignore" "commits the change"
}

test_register_records_session_and_creates_draft() {
  local out
  "$CTX" new alpha "Alpha" s0 >/dev/null
  out=$("$CTX" register s1 alpha /tmp/repo)
  assert_eq "$out" "$CTX_HOME/.drafts/s1/alpha" "prints the draft path"
  assert_eq "$(tail -1 "$CTX_HOME/.sessions.tsv" | cut -f1-3)" "s1${TAB}alpha${TAB}/tmp/repo" "appends a registry line"
  assert_contains "$(cat "$CTX_HOME/state.md")" "- alpha: Alpha · - · updated $TODAY · 2 sessions" "counts both sessions"
  assert_eq "$("$CTX" current s1)" "alpha" "current returns the workstream"
  assert_eq "$([ -d "$CTX_HOME/.drafts/s1/.base/alpha" ] && echo yes)" "yes" "keeps a base copy"
}

test_register_handles_none_unknown_and_bad_ids() {
  "$CTX" register s1 none >/dev/null
  assert_eq "$("$CTX" current s1)" "" "none has no current workstream"
  "$CTX" register s2 ghost 2>/dev/null
  assert_eq "$?" "1" "rejects an unknown workstream"
  "$CTX" register "bad id" none 2>/dev/null
  assert_eq "$?" "1" "rejects a malformed session id"
}

test_current_ignores_deleted_workstream() {
  "$CTX" new alpha "Alpha" s1 >/dev/null
  rm -rf "$CTX_HOME/workstreams/alpha"
  assert_eq "$("$CTX" current s1)" "" "a missing folder means unregistered"
}

test_parallel_registers_keep_index_valid() {
  local i
  "$CTX" new alpha "Alpha" s0 >/dev/null
  for i in 1 2 3 4 5 6 7 8 9 10; do
    "$CTX" register "s$i" alpha >/dev/null &
  done
  wait
  assert_eq "$(wc -l < "$CTX_HOME/.sessions.tsv" | tr -d ' ')" "11" "eleven registry lines"
  assert_contains "$(cat "$CTX_HOME/state.md")" "· 11 sessions" "state.md counts all of them"
  assert_eq "$(ls -d "$CTX_HOME"/.drafts/s*/alpha | wc -l | tr -d ' ')" "11" "one draft per session"
  assert_eq "$(ls "$CTX_HOME" | grep -c tmp)" "0" "no temp files left"
  assert_eq "$([ -d "$CTX_HOME/.lock" ] && echo held || echo free)" "free" "lock released"
}

test_show_prints_active_entries_and_recent_log() {
  local out draft
  draft=$("$CTX" new alpha "Alpha" s1)
  printf '%s\n' '- D1 | 2026-10-12 | replaced by D2 on 2026-10-19 | old choice' '- D2 | 2026-10-19 | active | new choice' > "$draft/decisions.md"
  printf '%s\n' '- 2026-10-01 s1: one' '- 2026-10-02 s1: two' '- 2026-10-03 s1: three' '- 2026-10-04 s1: four' '- 2026-10-05 s1: five' '- 2026-10-06 s1: six' > "$draft/log.md"
  out=$("$CTX" show s1)
  assert_contains "$out" "Edit only the files in $draft" "names the draft"
  assert_contains "$out" "new choice" "shows the active decision"
  assert_not_contains "$out" "old choice" "hides the replaced decision"
  assert_contains "$out" "s1: six" "shows the newest log entry"
  assert_not_contains "$out" "s1: one" "keeps only the last five log entries"
}

test_lint_accepts_a_valid_workstream() {
  write_valid_workstream "$CTX_HOME/fixture"
  assert_eq "$("$CTX" lint "$CTX_HOME/fixture")" "ok" "valid workstream passes"
}

test_lint_names_each_broken_rule() {
  assert_contains "$(lint_after_appending facts.md '- F2 | checked 2026-10-20 |  | active | no source')" "F2: cite at least one source" "fact without a source"
  assert_contains "$(lint_after_appending facts.md '- F2 | checked 2026-10-20 | S9 | active | x')" "F2 cites missing source S9" "citation of a missing source"
  assert_contains "$(lint_after_appending decisions.md '- D3 | yesterday | active | x')" "D3: date must be YYYY-MM-DD" "undated decision"
  assert_contains "$(lint_after_appending decisions.md '- D3 | 2026-10-20 | replaced by D9 on 2026-10-20 | x')" "replaced by missing D9" "dangling replaced-by"
  assert_contains "$(lint_after_appending decisions.md '- D2 | 2026-10-20 | active | again')" "duplicate id D2" "duplicate id"
  assert_contains "$(lint_after_appending decisions.md '- D3 | 2026-10-20 | superseded | x')" "D3: status must be active or replaced by D<n> on YYYY-MM-DD" "bad status"
  assert_contains "$(lint_after_appending now.md '<<<<<<< draft')" "unresolved merge conflict marker" "conflict marker"
  assert_contains "$(lint_after_appending sources.md '- S3 | rumour | checked 2026-10-20 | x')" "S3: unknown kind rumour" "unknown source kind"
  assert_contains "$(lint_after_appending queries/S2.sql "WHERE email = 'jane.doe@example.com'")" "S2.sql:2: looks like an email address" "email in a query"
  assert_contains "$(lint_after_appending traps.md '- IBAN DE89370400440532013000 failed')" "looks like an IBAN" "IBAN"
  assert_contains "$(lint_after_appending traps.md '- refund to GB82WEST12345698765432 failed')" "looks like an IBAN" "IBAN from another country"
  assert_eq "$(lint_after_appending traps.md '- car WVWZZZ1KZAW123456 stuck')" "ok" "a VIN is not flagged"
  assert_contains "$(lint_after_appending log.md '- yesterday: x')" "log entry must be" "undated log entry"
  assert_contains "$(lint_after_appending traps.md 'no dash')" "entries start with" "free line without a dash"
  lint_after_appending now.md "$(head -c 31000 /dev/zero | tr '\0' 'x')" >/dev/null
  assert_eq "$?" "1" "over the cap fails"
  assert_contains "$(lint_after_appending now.md "$(head -c 31000 /dev/zero | tr '\0' 'x')")" "over the 30720-byte cap" "names the cap"
}

test_lint_requires_frontmatter_keys() {
  local dir="$CTX_HOME/fixture"
  write_valid_workstream "$dir"
  grep -v '^summary:' "$dir/now.md" > "$dir/now.tmp" && mv "$dir/now.tmp" "$dir/now.md"
  assert_contains "$("$CTX" lint "$dir")" "frontmatter needs summary" "missing summary"
}

test_next_id_never_repeats() {
  local draft
  draft=$("$CTX" new alpha "Alpha" s1)
  assert_eq "$("$CTX" next-id s1 F)" "F1" "first id"
  assert_eq "$("$CTX" next-id s1 F)" "F2" "reserved ids are not reused"
  echo '- F5 | checked 2026-10-20 | S1 | active | x' >> "$draft/facts.md"
  assert_eq "$("$CTX" next-id s1 F)" "F6" "above the highest id in the draft"
  assert_eq "$("$CTX" next-id s1 D)" "D1" "kinds count separately"
  "$CTX" next-id s1 X 2>/dev/null
  assert_eq "$?" "1" "rejects an unknown kind"
  "$CTX" next-id nobody F 2>/dev/null
  assert_eq "$?" "1" "rejects an unregistered session"
}

test_checkpoint_publishes_a_draft() {
  local draft out
  draft=$("$CTX" new alpha "Alpha" s1)
  write_now "$draft" "Building the script."
  out=$("$CTX" checkpoint s1 "describe the script")
  assert_contains "$out" "Checkpointed alpha at" "reports the commit"
  assert_contains "$(cat "$CTX_HOME/workstreams/alpha/now.md")" "Building the script." "main has the edit"
  assert_eq "$(git -C "$CTX_HOME" log -1 --format=%s)" "alpha: describe the script" "commit message"
  assert_eq "$(diff -r "$CTX_HOME/workstreams/alpha" "$draft" >/dev/null && echo same)" "same" "draft reset to main"
  assert_contains "$("$CTX" checkpoint s1 "again")" "Nothing new to checkpoint" "second checkpoint is a no-op"
}

test_checkpoint_merges_edits_to_different_files() {
  local draft1 draft2
  draft1=$("$CTX" new alpha "Alpha" s1)
  draft2=$("$CTX" register s2 alpha)
  write_now "$draft1" "From s1."
  echo "- $TODAY s2: from s2" >> "$draft2/log.md"
  "$CTX" checkpoint s1 "s1 edit" >/dev/null
  "$CTX" checkpoint s2 "s2 edit" >/dev/null
  assert_eq "$?" "0" "second checkpoint succeeds"
  assert_contains "$(cat "$CTX_HOME/workstreams/alpha/now.md")" "From s1." "keeps s1's edit"
  assert_contains "$(cat "$CTX_HOME/workstreams/alpha/log.md")" "from s2" "keeps s2's edit"
}

test_checkpoint_unions_appends_to_the_same_file() {
  local draft1 draft2
  draft1=$("$CTX" new alpha "Alpha" s1)
  draft2=$("$CTX" register s2 alpha)
  echo '- D1 | 2026-10-20 | active | from s1' >> "$draft1/decisions.md"
  echo '- D2 | 2026-10-20 | active | from s2' >> "$draft2/decisions.md"
  "$CTX" checkpoint s1 "s1 decision" >/dev/null
  "$CTX" checkpoint s2 "s2 decision" >/dev/null
  assert_eq "$?" "0" "no conflict on appends"
  assert_eq "$(wc -l < "$CTX_HOME/workstreams/alpha/decisions.md" | tr -d ' ')" "2" "both decisions kept"
}

test_checkpoint_stops_on_a_now_conflict_and_resumes() {
  local draft1 draft2 out
  draft1=$("$CTX" new alpha "Alpha" s1)
  draft2=$("$CTX" register s2 alpha)
  write_now "$draft1" "Now according to s1."
  write_now "$draft2" "Now according to s2."
  "$CTX" checkpoint s1 "s1 now" >/dev/null
  out=$("$CTX" checkpoint s2 "s2 now" 2>&1)
  assert_eq "$?" "1" "conflict fails"
  assert_contains "$out" "merge conflict in: now.md" "names the file"
  assert_contains "$(cat "$CTX_HOME/workstreams/alpha/now.md")" "Now according to s1." "main keeps the first"
  assert_contains "$(cat "$draft2/now.md")" "<<<<<<< draft" "markers left in the draft"
  write_now "$draft2" "Now according to both."
  out=$("$CTX" checkpoint s2 "s2 resolved")
  assert_contains "$out" "Checkpointed alpha" "succeeds after resolution"
  assert_contains "$(cat "$CTX_HOME/workstreams/alpha/now.md")" "Now according to both." "main has the resolution"
}

test_checkpoint_lint_failure_publishes_nothing() {
  local draft out before
  draft=$("$CTX" new alpha "Alpha" s1)
  before=$(git -C "$CTX_HOME" rev-parse HEAD)
  echo '- F1 | checked 2026-10-20 |  | active | no source' >> "$draft/facts.md"
  out=$("$CTX" checkpoint s1 "bad fact" 2>&1)
  assert_eq "$?" "1" "lint failure fails"
  assert_contains "$out" "cite at least one source" "shows the lint error"
  assert_eq "$(git -C "$CTX_HOME" rev-parse HEAD)" "$before" "no commit"
  assert_eq "$(cat "$CTX_HOME/workstreams/alpha/facts.md")" "" "main unchanged"
}

test_checkpoint_and_lint_ignore_finder_files() {
  local draft
  draft=$("$CTX" new alpha "Alpha" s1)
  printf 'Bud1\000\001jane.doe@example.com' > "$draft/.DS_Store"
  write_now "$draft" "Edited next to a Finder file."
  assert_eq "$("$CTX" lint "$draft")" "ok" "lint skips .DS_Store"
  assert_contains "$("$CTX" checkpoint s1 "edit")" "Checkpointed alpha" "checkpoint succeeds"
  assert_eq "$([ -e "$CTX_HOME/workstreams/alpha/.DS_Store" ] && echo copied || echo skipped)" "skipped" "main gets no .DS_Store"
  assert_contains "$(cat "$CTX_HOME/.gitignore")" ".DS_Store" "gitignore lists .DS_Store"
}

test_register_refreshes_a_clean_draft_only() {
  local draft1 draft2 draft3
  draft1=$("$CTX" new alpha "Alpha" s1)
  draft2=$("$CTX" register s2 alpha)
  draft3=$("$CTX" register s3 alpha)
  echo "- $TODAY s3: unpublished" >> "$draft3/log.md"
  write_now "$draft1" "Published by s1."
  "$CTX" checkpoint s1 "publish" >/dev/null
  "$CTX" register s2 alpha >/dev/null
  "$CTX" register s3 alpha >/dev/null
  assert_contains "$(cat "$draft2/now.md")" "Published by s1." "clean draft picks up main"
  assert_contains "$(cat "$draft3/log.md")" "unpublished" "edited draft is kept"
}

test_archive_moves_folder_and_refuses_while_edited() {
  local draft2 out
  "$CTX" new alpha "Alpha" s1 >/dev/null
  draft2=$("$CTX" register s2 alpha)
  echo "- $TODAY s2: pending" >> "$draft2/log.md"
  out=$("$CTX" archive alpha 2>&1)
  assert_eq "$?" "1" "refuses while s2 has unpublished edits"
  assert_contains "$out" "unpublished edits to alpha: s2" "names the session"
  "$CTX" drop s2 >/dev/null
  "$CTX" archive alpha s1
  assert_eq "$([ -d "$CTX_HOME/archive/alpha" ] && echo yes)" "yes" "folder is in archive"
  assert_eq "$(git -C "$CTX_HOME" log -1 --format=%s)" "alpha: archive" "commits the move"
  assert_eq "$([ -d "$CTX_HOME/.drafts/s1/alpha" ] && echo kept || echo removed)" "removed" "drafts removed"
  assert_not_contains "$(cat "$CTX_HOME/state.md")" "alpha" "state no longer lists it"
  "$CTX" new alpha "Alpha" s1 2>/dev/null
  assert_eq "$?" "1" "an archived slug cannot be recreated"
  out=$("$CTX" archive alpha s1 2>&1)
  assert_eq "$?" "1" "archiving twice fails"
  assert_contains "$out" "already archived: alpha ($CTX_HOME/archive/alpha)" "says it is already archived"
  out=$("$CTX" archive ghost s1 2>&1)
  assert_contains "$out" "no such workstream: ghost" "unknown slugs keep the old message"
}

test_archive_refuses_while_another_session_is_attached() {
  local out
  "$CTX" new alpha "Alpha" s1 >/dev/null
  "$CTX" register s2 alpha >/dev/null
  "$CTX" register s3 alpha >/dev/null
  "$CTX" register s3 none >/dev/null
  out=$("$CTX" archive alpha s1 2>&1)
  assert_eq "$?" "1" "refuses while s2 is attached with a clean draft"
  assert_contains "$out" "attached to alpha: s2" "names the attached session"
  assert_not_contains "$out" "s3" "a session that moved on is not attached"
  assert_contains "$out" "--force" "explains the override"
  assert_eq "$([ -d "$CTX_HOME/workstreams/alpha" ] && echo kept)" "kept" "nothing archived"
  "$CTX" archive alpha s1 --force
  assert_eq "$([ -d "$CTX_HOME/archive/alpha" ] && echo yes)" "yes" "force archives"
}

test_archive_force_does_not_discard_unpublished_edits() {
  local draft2 out
  "$CTX" new alpha "Alpha" s1 >/dev/null
  draft2=$("$CTX" register s2 alpha)
  echo "- $TODAY s2: pending" >> "$draft2/log.md"
  out=$("$CTX" archive alpha s1 --force 2>&1)
  assert_eq "$?" "1" "force still refuses unpublished edits"
  assert_contains "$out" "unpublished edits to alpha: s2" "names the session"
}

test_candidates_rank_by_overlap_then_recency() {
  local out
  write_workstream invoice-export "Invoice export" "csv stack merged" "billing-api" 2026-10-17 active
  write_workstream payment-retries "Payment retries" "webhook retry consumer live" "billing-api" 2026-09-28 active
  write_workstream standup "Daily standup" "post to slack" "-" 2026-10-18 active
  write_workstream web-feed "Notification feed" "web page" "web-app" 2026-10-01 active
  out=$("$CTX" candidates "why did the payment webhook retry fail" /nonexistent | cut -f1)
  assert_eq "$(echo "$out" | head -1)" "payment-retries" "best word overlap first"
  assert_eq "$(echo "$out" | wc -l | tr -d ' ')" "3" "at most three"
  out=$("$CTX" candidates "hello" /nonexistent | cut -f1 | head -1)
  assert_eq "$out" "standup" "no overlap falls back to most recent"
}

test_candidates_prefer_current_repo_and_skip_done() {
  local parent repo out
  write_workstream a-billing "Feed" "message feed" "billing-api" 2026-10-01 active
  write_workstream b-web "Feed" "message feed" "web-app" 2026-10-01 active
  write_workstream c-done "Feed" "message feed" "web-app" 2026-10-09 done
  parent=$(mktemp -d)
  repo="$parent/web-app"
  mkdir -p "$repo"
  git -C "$repo" init -q
  out=$("$CTX" candidates "message feed" "$repo" | cut -f1)
  assert_eq "$(echo "$out" | head -1)" "b-web" "repo match breaks the tie"
  assert_not_contains "$out" "c-done" "done workstreams are not offered"
  rm -rf "$parent"
}

test_hook_start_new_session_injects_version_and_index() {
  local out
  "$CTX" new alpha "Alpha" s0 >/dev/null
  out=$(hook_start_input s1 /tmp/x startup | "$CTX" hook start | additional_context)
  assert_eq "$(echo "$out" | head -1)" "ctx v1" "version line first"
  assert_contains "$out" "- alpha: Alpha" "includes the index"
  assert_contains "$out" "no workstream yet" "tells the agent to ask"
}

test_hook_start_caps_the_index() {
  local i out
  for i in $(seq 1 150); do
    write_workstream "workstream-number-$i" "Workstream $i" "a summary that is long enough to fill the line quickly $i" "billing-api" 2026-10-01 active
  done
  out=$(hook_start_input s1 /tmp/x startup | "$CTX" hook start | additional_context)
  assert_contains "$out" "index truncated" "says it was cut"
  assert_eq "$([ ${#out} -lt 10000 ] && echo under)" "under" "stays under the 10,000-character hook limit"
}

test_hook_start_offers_previous_workstream_in_folder_for_any_source() {
  local out
  "$CTX" new alpha "Alpha" old-session /tmp/x >/dev/null
  out=$(hook_start_input new-session /tmp/x startup | "$CTX" hook start | additional_context)
  assert_contains "$out" "was on \`alpha\`" "after startup (the desktop app reports /clear as startup)"
  out=$(hook_start_input cleared /tmp/x clear | "$CTX" hook start | additional_context)
  assert_contains "$out" "was on \`alpha\`" "after clear"
  out=$(hook_start_input other /tmp/elsewhere startup | "$CTX" hook start | additional_context)
  assert_not_contains "$out" "was on" "only for the same folder"
}

test_hook_prompt_puts_previous_workstream_in_folder_first() {
  local out
  write_workstream payment-retries "Payment retries" "webhook retry consumer" "billing-api" 2026-09-28 active
  write_workstream standup "Daily standup" "post to slack" "-" 2026-10-18 active
  "$CTX" new alpha "Alpha" old-session /tmp/x >/dev/null
  out=$(hook_prompt_input new-session /tmp/x "payment webhook retry failed" | "$CTX" hook prompt | additional_context)
  assert_contains "$out" "1. \`alpha\`: Alpha (last used in this folder)" "previous workstream first"
  assert_contains "$out" "2. \`payment-retries\`" "best match second"
  assert_contains "$out" "3. New workstream" "still four options"
  assert_eq "$(echo "$out" | grep -cF '`alpha`')" "1" "previous workstream listed once"
  out=$(hook_prompt_input other-session /tmp/elsewhere "payment webhook retry failed" | "$CTX" hook prompt | additional_context)
  assert_contains "$out" "1. \`payment-retries\`" "other folders rank by match"
  assert_not_contains "$out" "last used in this folder" "no folder label elsewhere"
}

test_hook_start_registered_session_rereads_and_refreshes() {
  local out draft2
  "$CTX" new alpha "Alpha" s1 >/dev/null
  draft2=$("$CTX" register s2 alpha)
  write_now "$CTX_HOME/.drafts/s1/alpha" "Published by s1."
  "$CTX" checkpoint s1 "publish" >/dev/null
  out=$(hook_start_input s2 /tmp/x compact | "$CTX" hook start | additional_context)
  assert_contains "$out" "show s2" "points at ctx show"
  assert_not_contains "$out" "no workstream yet" "does not ask again"
  assert_contains "$(cat "$draft2/now.md")" "Published by s1." "clean draft refreshed"
  echo "- $TODAY s2: pending" >> "$draft2/log.md"
  out=$(hook_start_input s2 /tmp/x resume | "$CTX" hook start | additional_context)
  assert_contains "$out" "unpublished edits" "flags its own unpublished edits"
}

test_hook_start_prunes_idle_drafts() {
  local out draft
  "$CTX" new alpha "Alpha" idle-clean >/dev/null
  draft=$("$CTX" register idle-edited alpha)
  echo "- $TODAY idle-edited: pending" >> "$draft/log.md"
  age_files "$CTX_HOME/.drafts/idle-clean"
  age_files "$CTX_HOME/.drafts/idle-edited"
  out=$(hook_start_input s9 /tmp/x startup | "$CTX" hook start | additional_context)
  assert_eq "$([ -d "$CTX_HOME/.drafts/idle-clean" ] && echo kept || echo removed)" "removed" "idle clean draft deleted"
  assert_eq "$([ -d "$CTX_HOME/.drafts/idle-edited" ] && echo kept || echo removed)" "kept" "idle edited draft kept"
  assert_contains "$out" "Session idle-edited has unpublished edits to: alpha" "reports it"
}

test_hook_start_resets_nudge_on_compact() {
  "$CTX" new alpha "Alpha" s1 >/dev/null
  set_usage s1 55
  hook_prompt_input s1 /tmp x | "$CTX" hook prompt >/dev/null
  hook_start_input s1 /tmp/x compact | "$CTX" hook start >/dev/null
  set_usage s1 42
  assert_contains "$(hook_prompt_input s1 /tmp x | "$CTX" hook prompt | additional_context)" "Context is at 42%" "nudges again after compaction"
}

test_hooks_ignore_subagents_and_garbage() {
  local out status
  "$CTX" new alpha "Alpha" s0 >/dev/null
  out=$(jq -cn '{session_id: "s1", agent_id: "a1", cwd: "/tmp", source: "startup"}' | "$CTX" hook start)
  assert_eq "$out" "" "start ignores agent_id"
  out=$(jq -cn '{session_id: "s1", cwd: "/tmp", prompt: "x", transcript_path: "/x/s1/subagents/agent-1.jsonl"}' | "$CTX" hook prompt)
  assert_eq "$out" "" "prompt ignores subagent transcripts"
  out=$(echo 'not json' | "$CTX" hook start)
  status=$?
  assert_eq "$status:$out" "0:" "start: garbage exits 0 silently"
  out=$(echo 'not json' | "$CTX" hook prompt)
  status=$?
  assert_eq "$status:$out" "0:" "prompt: garbage exits 0 silently"
  out=$(echo '{"session_id":"bad id"}' | "$CTX" hook start)
  status=$?
  assert_eq "$status:$out" "0:" "invalid session id exits 0 silently"
}

test_hook_prompt_unregistered_asks_with_shortlist() {
  local out
  write_workstream payment-retries "Payment retries" "webhook retry consumer" "billing-api" 2026-09-28 active
  write_workstream standup "Daily standup" "post to slack" "-" 2026-10-18 active
  write_workstream web-feed "Feed" "web page" "web-app" 2026-10-01 active
  out=$(hook_prompt_input s1 /nonexistent "payment webhook retry failed" | "$CTX" hook prompt | additional_context)
  assert_contains "$out" "1. \`payment-retries\`: webhook retry consumer" "best match first"
  assert_contains "$out" "2. \`standup\`" "second match by recency"
  assert_contains "$out" "3. New workstream" "new workstream after two matches"
  assert_contains "$out" "4. No context file" "opt-out last"
  assert_not_contains "$out" "web-feed" "only two matches"
  assert_contains "$out" "register s1 none" "gives the opt-out command"
}

test_hook_prompt_with_no_workstreams_offers_new_and_none() {
  local out
  out=$(hook_prompt_input s1 /nonexistent "hello" | "$CTX" hook prompt | additional_context)
  assert_contains "$out" "1. New workstream" "new workstream first"
  assert_contains "$out" "2. No context file" "opt-out second"
}

test_hook_prompt_quiet_after_registration_or_opt_out() {
  "$CTX" new alpha "Alpha" s1 >/dev/null
  "$CTX" register s2 none >/dev/null
  assert_eq "$(hook_prompt_input s1 /tmp anything | "$CTX" hook prompt)" "" "registered session gets no question"
  assert_eq "$(hook_prompt_input s2 /tmp anything | "$CTX" hook prompt)" "" "opted-out session gets no question"
}

test_hook_prompt_asks_again_when_workstream_deleted() {
  "$CTX" new alpha "Alpha" s1 >/dev/null
  rm -rf "$CTX_HOME/workstreams/alpha"
  assert_contains "$(hook_prompt_input s1 /tmp anything | "$CTX" hook prompt | additional_context)" "AskUserQuestion" "missing slug means ask again"
}

test_hook_prompt_registers_from_context_line() {
  local out
  "$CTX" new alpha "Alpha" s0 >/dev/null
  out=$(hook_prompt_input s9 /tmp "Fix the bug. Context: ~/.claude/context/workstreams/alpha" | "$CTX" hook prompt | additional_context)
  assert_eq "$("$CTX" current s9)" "alpha" "session registered"
  assert_contains "$out" "to workstream \`alpha\`" "says so"
  assert_not_contains "$out" "AskUserQuestion" "does not ask"
  assert_eq "$([ -d "$CTX_HOME/.drafts/s9/alpha" ] && echo yes)" "yes" "creates the draft"
}

test_hook_prompt_nudges_at_percentage_steps() {
  local out
  "$CTX" new alpha "Alpha" s1 >/dev/null
  set_usage s1 39
  assert_eq "$(hook_prompt_input s1 /tmp x | "$CTX" hook prompt)" "" "no nudge at 39%"
  set_usage s1 40
  out=$(hook_prompt_input s1 /tmp x | "$CTX" hook prompt | additional_context)
  assert_contains "$out" "Context is at 40%" "nudges at 40%"
  assert_contains "$out" "never mid-task" "never interrupts active work"
  assert_contains "$out" "checkpoint s1" "names the checkpoint command"
  set_usage s1 45
  assert_eq "$(hook_prompt_input s1 /tmp x | "$CTX" hook prompt)" "" "not again within the same step"
  set_usage s1 50
  assert_contains "$(hook_prompt_input s1 /tmp x | "$CTX" hook prompt | additional_context)" "Context is at 50%" "nudges again at 50%"
}

test_hook_prompt_nudges_from_transcript_without_status_line() {
  local transcript="$CTX_HOME/transcript.jsonl"
  "$CTX" new alpha "Alpha" s1 >/dev/null
  write_transcript "$transcript" 399000
  assert_eq "$(hook_prompt_input s1 /tmp x "$transcript" | "$CTX" hook prompt)" "" "no nudge at 39% of a 1M window"
  write_transcript "$transcript" 400000
  assert_contains "$(hook_prompt_input s1 /tmp x "$transcript" | "$CTX" hook prompt | additional_context)" "Context is at 40%" "nudges at 40% of a 1M window"
}

test_transcript_fallback_skips_sidechain_and_api_error_lines() {
  local transcript="$CTX_HOME/transcript.jsonl"
  "$CTX" new alpha "Alpha" s1 >/dev/null
  write_transcript "$transcript" 520000
  jq -cn '{type: "assistant", isSidechain: true, message: {usage: {input_tokens: 990000}}}' >> "$transcript"
  jq -cn '{type: "assistant", isApiErrorMessage: true, message: {usage: {input_tokens: 0}}}' >> "$transcript"
  echo 'garbage line' >> "$transcript"
  assert_contains "$(hook_prompt_input s1 /tmp x "$transcript" | "$CTX" hook prompt | additional_context)" "Context is at 52%" "uses the last main-thread usage"
}

test_status_line_percentage_wins_over_transcript() {
  local transcript="$CTX_HOME/transcript.jsonl"
  "$CTX" new alpha "Alpha" s1 >/dev/null
  write_transcript "$transcript" 900000
  set_usage s1 45
  assert_contains "$(hook_prompt_input s1 /tmp x "$transcript" | "$CTX" hook prompt | additional_context)" "Context is at 45%" "status line value is used"
}

test_context_window_can_be_overridden() {
  local transcript="$CTX_HOME/transcript.jsonl"
  "$CTX" new alpha "Alpha" s1 >/dev/null
  write_transcript "$transcript" 100000
  assert_contains "$(hook_prompt_input s1 /tmp x "$transcript" | CTX_CONTEXT_WINDOW_TOKENS=200000 "$CTX" hook prompt | additional_context)" "Context is at 50%" "200k window"
}

test_hook_prompt_is_fast() {
  local i start elapsed_ms
  for i in $(seq 1 20); do
    write_workstream "ws-$i" "Workstream $i" "summary $i" "billing-api" 2026-10-01 active
  done
  start=$(now_ms)
  hook_prompt_input s1 /tmp "some prompt words here" | "$CTX" hook prompt >/dev/null
  elapsed_ms=$(( $(now_ms) - start ))
  assert_eq "$([ "$elapsed_ms" -lt 1000 ] && echo fast || echo "slow ${elapsed_ms}ms")" "fast" "under one second with 20 workstreams"
}

test_statusline_records_percentage_and_runs_original() {
  local out
  echo 'echo wrapped' > "$CTX_HOME/.statusline-next"
  out=$(jq -cn '{session_id: "s1", context_window: {used_percentage: 42.7}}' | "$CTX" statusline)
  assert_eq "$out" "wrapped" "runs the original status line"
  assert_eq "$(cat "$CTX_HOME/.usage/s1")" "42" "records the floored percentage"
  out=$(echo 'not json' | "$CTX" statusline)
  assert_eq "$?:$out" "0:wrapped" "garbage still renders the original"
  rm "$CTX_HOME/.statusline-next"
  out=$(jq -cn '{session_id: "s1", context_window: {used_percentage: 50}}' | "$CTX" statusline)
  assert_eq "$?:$out" "0:" "no original: silent"
}

test_doctor_passes_on_full_install_and_names_gaps() {
  local settings="$CTX_HOME/settings.json" out
  "$CTX" new alpha "Alpha" s1 >/dev/null
  echo 'echo wrapped' > "$CTX_HOME/.statusline-next"
  jq -n --arg ctx "$CTX" '{hooks: {SessionStart: [{hooks: [{type: "command", command: ($ctx + " hook start")}]}], UserPromptSubmit: [{hooks: [{type: "command", command: ($ctx + " hook prompt")}]}]}, statusLine: {type: "command", command: ($ctx + " statusline")}}' > "$settings"
  out=$(CTX_SETTINGS="$settings" "$CTX" doctor)
  assert_eq "$?" "0" "full install passes"
  assert_not_contains "$out" "FAIL" "no failures"
  assert_contains "$out" "ok   lint alpha" "lints workstreams"
  jq 'del(.hooks.SessionStart)' "$settings" > "$settings.new" && mv "$settings.new" "$settings"
  out=$(CTX_SETTINGS="$settings" "$CTX" doctor)
  assert_eq "$?" "1" "missing hook fails"
  assert_contains "$out" "FAIL SessionStart hook installed" "names it"
  jq --arg ctx "$CTX" '.hooks.SessionStart = [{hooks: [{type: "command", command: ($ctx + " hook start")}]}]' "$settings" > "$settings.new" && mv "$settings.new" "$settings"
  rm "$CTX_HOME/.statusline-next"
  out=$(CTX_SETTINGS="$settings" "$CTX" doctor)
  assert_eq "$?" "0" "no original status line is not a failure"
  assert_contains "$out" "info no original status line" "says so"
}

test_status_reports_workstream_draft_checkpoint_and_nudge() {
  local out draft="$CTX_HOME/.drafts/s1/alpha"
  "$CTX" new alpha "Alpha" s1 >/dev/null
  write_workstream beta "Beta" "Beta summary" - 2026-10-01 paused
  out=$("$CTX" status s1)
  assert_eq "$(jq -r .workstream <<<"$out")" "alpha" "names the workstream"
  assert_eq "$(jq -r '.draft.changed | length' <<<"$out")" "0" "a fresh draft is clean"
  assert_eq "$(jq -r .last_checkpoint.subject <<<"$out")" "alpha: create" "last checkpoint subject"
  assert_contains "$(jq -r .show <<<"$out")" "# Workstream alpha" "carries the show view"
  assert_eq "$(jq -r '[.workstreams[] | .slug + ":" + .status] | join(" ")' <<<"$out")" "alpha:active beta:paused" "lists every workstream with its status"
  assert_eq "$(jq -r .context.next_nudge_percent <<<"$out")" "40" "first nudge at 40%"
  echo '- 2026-10-20 s1: edit' >> "$draft/log.md"
  echo 'x' > "$draft/new.md"
  assert_eq "$("$CTX" status s1 | jq -r '.draft.changed | join(" ")')" "log.md new.md" "names edited and added files"
  set_usage s1 47
  mkdir -p "$CTX_HOME/.nudges" && echo 0 > "$CTX_HOME/.nudges/s1"
  out=$("$CTX" status s1)
  assert_eq "$(jq -c .context <<<"$out")" '{"percent":47,"next_nudge_percent":50}' "context use and the next threshold"
  out=$("$CTX" status s2)
  assert_eq "$?:$(jq -c '[.workstream, .draft, .show, .last_checkpoint]' <<<"$out")" "0:[null,null,null,null]" "an unregistered session is all null"
  "$CTX" status 'bad id' >/dev/null 2>&1
  assert_eq "$?" "1" "rejects a malformed session id"
}

test_status_is_read_only() {
  "$CTX" new alpha "Alpha" s1 >/dev/null
  rm "$CTX_HOME/state.md"
  "$CTX" status s1 >/dev/null
  assert_eq "$([ -e "$CTX_HOME/state.md" ] && echo written || echo untouched)" "untouched" "does not render the index"
  assert_eq "$(git -C "$CTX_HOME" status --porcelain | grep -v state.md)" "" "leaves the repository clean"
}

run_tests
