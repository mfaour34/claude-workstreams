---
name: context
description: Use when a hook says this session has no workstream, when reading, editing, checkpointing or trimming a workstream in @CTX_HOME@, when a checkpoint reports a merge conflict or lint errors, when a hook reports the context size, when briefing a spawned session, or when backfilling workstreams.
---

# Workstream context

The chat is disposable. The workstream is the source of truth: a fresh session must be able to continue the work from it alone.

## Commands

`@CTX_HOME@/bin/ctx`:

| Command | Does |
| --- | --- |
| `show <session>` | Read view of your draft: now.md, active entries, sources, traps, artifacts, last five log lines |
| `next-id <session> <D\|F\|S>` | Next free id |
| `checkpoint <session> "<message>"` | Merge your draft into the main copy and commit |
| `lint <dir>` | Check a workstream folder |
| `new <slug> "<title>" <session>` | Create a workstream and your draft |
| `register <session> <slug\|none>` | Attach the session (`none`: no context file) |
| `list` / `candidates "<text>"` | Index / best matches |
| `archive <slug> <session> [--force]` | Move a finished workstream to `archive/`; refuses while other sessions are attached unless `--force` |
| `drop <session>` | Delete a session's drafts |
| `doctor` | Check the installation |

The session id is in the hook messages. Edit only your draft (`.drafts/<session>/<slug>/`), never the main copy, `state.md` or `.sessions.tsv`.

## Files

| File | Write mode |
| --- | --- |
| `now.md` | rewrite: frontmatter, `## Goal`, `## Now` (at most eight lines), `## Next steps` |
| `decisions.md`, `facts.md` | append; edit only the status field of an old line |
| `sources.md`, `traps.md`, `artifacts.md`, `log.md` | append |
| `history.md` | append, during Trim only |
| `queries/S<n>.sql` | create; the query text only, never results |

One entry per line, exactly these shapes:

```
decisions.md   - D3 | 2026-10-19 | active | Use a mkdir lock. Why: macOS has no flock. Sources: S4
               - D1 | 2026-10-12 | replaced by D3 on 2026-10-19 | Use flock.
facts.md       - F4 | checked 2026-10-19 | S1, S2 | active | The vendor API answers 404 for unsplit orders
sources.md     - S1 | sql | checked 2026-10-19 | queries/S1.sql (prod db, read-only)
traps.md       - <text>
artifacts.md   - <text>
log.md         - 2026-10-19 <session>: <one to three lines>
```

The file name column is for reading only; each line starts with `- `.

Frontmatter: `title`, `status` (`active`, `paused`, `done`), `repos` (comma-separated), `summary` (one line under 100 characters; shown in the index and the shortlist), `updated` (YYYY-MM-DD).

Source kinds: `sql`, `bq`, `code`, `pr`, `slack`, `datadog`, `jira`, `confluence`, `doc`, `user`. The locator must let someone re-run or re-open it: `ref:path:line`, a URL, a `queries/` file, or who said it in which session.

## Checkpoint

1. Rewrite Now and Next steps in `now.md`; set `summary` and `updated`.
2. New decision: id from `ctx next-id <session> D`, today's date, `active`, the reason after `Why:`. If it replaces one, change the old line's status to `replaced by D<new> on <today>`.
3. New fact: id from `ctx next-id <session> F`, `checked <today>`, at least one source id. Same result on re-check: keep the id, update `checked`. Different result: new id, old line `replaced by F<new> on <today>`.
4. New source: id from `ctx next-id <session> S`. A query longer than one line goes to `queries/S<n>.sql`.
5. Append traps, artifacts and one log line.
6. Run `ctx checkpoint <session> "<what changed>"`.

## When checkpoint fails

- **Merge conflict:** the draft now holds the merged result with `<<<<<<< draft` / `>>>>>>> main` markers. Keep both sides' entries; for `now.md`, write one Now that is true for both. Remove every marker, then checkpoint again.
- **Lint errors:** each names file, line and rule. Fix them in the draft and checkpoint again. Two sessions can give the same id two statuses; keep the later status.
- **Over the cap:** Trim.

## Trim

1. Move replaced D and F lines from `decisions.md` and `facts.md` to `history.md`, unchanged.
2. Keep the last ten log lines; fold anything durable from older ones into a decision or fact, then delete them.
3. Replace copied content with a link.
4. Checkpoint.

## Picking a workstream

Ask with AskUserQuestion using exactly the options the hook lists, in that order. A new slug is kebab-case and names the work, not the ticket (`invoice-export`, not `proj-123`).

## Spawning a session

Put `Context: @CTX_HOME@/workstreams/<slug>` on its own line in the brief. The prompt hook registers the new session without asking.

## Finishing

Set `status: done`, write a final Now, checkpoint, then `ctx archive <slug> <session>`. If it names other attached sessions, ask the user whether they are finished before adding `--force`; never force past a session the user is working in.

## Backfill

1. Collect candidates: notes or handoff documents the user points to, open pull requests (`gh search prs --author @me --state open`), and anything the user names.
2. Ask which are still active (AskUserQuestion, `multiSelect: true`, up to four options per question, up to four questions).
3. For each: `ctx new`, fill the draft by Checkpoint from its sources; a document you take facts from is a `doc` source with its "as of" date, linked under Artifacts, not copied. Checkpoint.
4. Show `ctx list`.
