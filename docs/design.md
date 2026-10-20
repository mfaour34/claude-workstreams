# Design

## Goal

The chat is disposable; the workstream on disk is the source of truth. A session can checkpoint, `/clear`, and reload a few thousand tokens instead of carrying a long context that compaction will cut anyway.

## Decisions

| Topic | Decision | Why |
| --- | --- | --- |
| Unit | One folder per workstream, written by many sessions | Resuming a topic should find one place |
| Index | `state.md`, generated, never hand-edited | Machine-owned state is rewritten safely; hand-edited indexes drift |
| Matching | Always ask at session start, with a shortlist | A wrong silent guess costs more than one question; subagents are never asked because they cannot |
| Shortlist | The workstream last used in the same folder first, then the best word matches, then "New" and "No context file" | AskUserQuestion takes at most four options; the desktop app reports `/clear` as a fresh `startup`, so the folder is the reliable signal |
| Facts | Each fact cites source ids; sources carry a kind, a checked date and an exact locator | A note nobody can re-check is a rumour |
| Decisions | Dated; a replaced decision stays, marked `replaced by D<n> on <date>` | The history of why something changed is the most expensive context to rebuild |
| Ids | Sequential (`D3`, `F7`, `S12`) from `ctx next-id` under a lock | Short ids are easy to cite; the reservation counter prevents two sessions minting the same id |
| Multiple writers | Each session edits a private draft; `ctx checkpoint` runs `git merge-file` against the base it started from | No session ever writes the shared copy, so nothing is overwritten before git sees it |
| Merge drivers | `--union` for append-only files, a normal merge for `now.md` | One file per section keeps appends conflict-free while a rewritten "Now" still conflicts instead of silently keeping two versions |
| Lint | Runs on the merged result before anything is published | It also catches what a union merge cannot see, such as one id given two statuses |
| Nudge | 40% context used, then every 10%; never mid-task | Fixed token counts are wrong for 1M-token windows; interrupting active work is worse than a large context |
| Context source | Status line `used_percentage` when available, else the transcript's last main-thread usage against a configurable window | The desktop app never runs the status line |
| Failure mode | Hooks fail open; `ctx doctor` and a version line make silence visible | A broken hook must never block a session |
| Archive | Refuses while another session is attached or has unpublished edits | Archiving under a live session silently detached it in testing |

## Checkpoint, step by step

For every file in the main copy, the draft or the base:

1. Draft equals base: take main. Main equals base: take the draft. Otherwise `git merge-file` draft, base, main.
2. Any conflict: publish nothing; the merged result with markers becomes the draft and main becomes the new base.
3. Lint the merged result; on failure, the same.
4. Otherwise replace the main copy, commit `<slug>: <message>`, reset the draft and base to the new main copy, re-render `state.md`.

## Prior art

- Anthropic's [effective harnesses for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents): a progress file plus git history; models overwrite free-form Markdown more readily than structured state, which is why the index is generated and entries are one structured line each.
- Anthropic's [effective context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents): keep lightweight identifiers (paths, stored queries, links) instead of copies; that is the Sources list.
- Memory-bank style setups (several prose files read at session start): their most-read file is also the most often stale; dated, replaceable entries answer that.
- [beads](https://github.com/steveyegge/beads): git-backed memory for agents and collision-free ids across agents.
- [MADR](https://adr.github.io/madr/): decision records that keep superseded entries with a pointer to their replacement.
