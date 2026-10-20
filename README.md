# claude-workstreams

Durable, git-backed context for [Claude Code](https://code.claude.com) sessions.

Every session works from a **workstream**: a small folder of Markdown files that holds the goal, the current state, dated decisions, sourced facts, traps and a log. The chat becomes disposable. You can `/clear`, compact, or start a fresh session and pick up where you left off by reloading a few thousand tokens instead of carrying a long, degrading context.

```
you start a session ──► hook asks: which workstream? (shortlist of likely matches)
       │
       ▼
agent reads `ctx show` ──► works, editing its own draft
       │
       ▼
milestone ──► `ctx checkpoint` ──► git merge into the main copy ──► commit
       │
       ▼
context getting large ──► nudge: checkpoint, then /clear when the task is done
```

## Why

- Long sessions lose detail at compaction, and a large live context makes the model less sharp.
- New sessions start blind on ongoing work.
- Hand-written handoffs are written only when someone remembers, and nothing points the next session at them.
- Notes drift: an old decision and a new one sit side by side, and nobody knows which fact was ever checked.

## What you get

- **A shortlist at session start.** A hook asks which workstream the session belongs to, offering the workstream last used in the same folder and the best matches for your first message, plus "New workstream" and "No context file".
- **Structured, checkable notes.** Decisions are dated and never deleted; a replaced one is marked `replaced by D7 on 2026-10-20`. Every fact cites one or more sources (a query, `file:line`, a PR, a doc). `ctx lint` enforces all of it.
- **Safe parallel sessions.** Each session edits a private draft. `ctx checkpoint` three-way merges it into the main copy with `git merge-file` and commits. Appends from different sessions are both kept; conflicting rewrites stop with markers instead of overwriting.
- **A context nudge.** At 40% context used, and every 10% after, the agent is told to checkpoint and, once the current task is finished, to suggest `/clear`. It never interrupts active work.
- **Full history.** The context folder is a local git repository; every checkpoint is a commit.

## Requirements

- Claude Code (terminal CLI or the desktop app)
- macOS or Linux, `bash` 3.2 or newer, `jq`, `git` 2.28 or newer, `awk`, `perl` (tests only)

## Install

One line:

```bash
curl -fsSL https://raw.githubusercontent.com/mfaour34/claude-workstreams/main/install.sh | bash
```

Or from a clone, if you want to read the code first or contribute:

```bash
git clone https://github.com/mfaour34/claude-workstreams.git
cd claude-workstreams
./install.sh
```

To keep the context folder somewhere other than `~/.claude/context`, prefix either command with `CTX_HOME=/path/to/folder`. The installed script finds its own folder afterwards, so nothing else needs the variable.

The installer:

- copies `ctx` to `<context folder>/bin/ctx` and creates the context repository there;
- adds a `SessionStart` and a `UserPromptSubmit` hook to `~/.claude/settings.json`, and wraps your existing status line (it still renders as before);
- appends a marked rules block to `~/.claude/CLAUDE.md`;
- installs the `context` skill to `~/.claude/skills/context/`;
- records where it was installed from (the one-line install keeps a clone in `<context folder>/.src`);
- backs up a file only when it actually changes it (`*.bak-claude-workstreams-<timestamp>`), then runs `ctx doctor`.

Re-running it is safe: nothing is duplicated.

## Update

```bash
~/.claude/context/bin/ctx update
```

It pulls the latest release into the source it was installed from (fast-forward only), re-runs the installer with the same folder, and runs `ctx doctor`. It prints `Updated from <old> to <new>` or `Already up to date`. Open sessions pick up the new version on their next message; the script is swapped atomically, so a hook that is running at that moment finishes on the old version. If the source checkout has local changes, `update` stops and changes nothing.

## Daily use

1. **Start a session.** Answer the workstream question. The agent runs `ctx show <session>` and works from it.
2. **Work.** The agent checkpoints at milestones: a decision made, a finding verified, a PR opened, a plan changed. Say `checkpoint` to trigger one yourself.
3. **Clear when it is large.** When the nudge appears, finish the task, then `/clear`. The next session offers the same workstream first.
4. **Finish.** Mark it done and run `ctx archive <slug> <session>`.

To brief a spawned session, put this line in its prompt; the session is registered without being asked:

```
Context: ~/.claude/context/workstreams/<slug>
```

## Commands

`~/.claude/context/bin/ctx`:

| Command | Does |
| --- | --- |
| `list` | Print the index of active and paused workstreams |
| `show <session>` | Read view: now.md, active decisions and facts, sources, traps, artifacts, last five log lines |
| `new <slug> "<title>" <session>` | Create a workstream and the session's draft |
| `register <session> <slug\|none>` | Attach a session to a workstream (`none`: no context file) |
| `current <session>` | The session's workstream |
| `next-id <session> <D\|F\|S>` | Next free decision, fact or source id |
| `lint <dir>` | Check formats, citations, replacements, duplicate ids, conflict markers, personal data, size |
| `checkpoint <session> "<message>" [slug]` | Merge the draft into the main copy and commit |
| `archive <slug> <session> [--force]` | Move a finished workstream to `archive/`; refuses while other sessions are attached |
| `drop <session>` | Delete a session's drafts |
| `candidates "<text>" [cwd]` | Best-matching workstreams for a text |
| `doctor` | Check the installation |
| `update` | Pull the latest release and reinstall |

The session id appears in the hook messages, and `tail -3 ~/.claude/context/.sessions.tsv` shows the latest ones.

## Workstream format

```
workstreams/<slug>/
  now.md          frontmatter, Goal, Now, Next steps (rewritten)
  decisions.md    - D3 | 2026-10-19 | active | Use a mkdir lock. Why: macOS has no flock. Sources: S4
  facts.md        - F4 | checked 2026-10-19 | S1, S2 | active | The vendor API answers 404 for unsplit orders
  sources.md      - S1 | sql | checked 2026-10-19 | queries/S1.sql (prod db, read-only)
  traps.md        - <what bit us>
  artifacts.md    - <links to PRs, specs, docs>
  log.md          - 2026-10-19 <session>: <one to three lines>
  history.md      replaced decisions and facts, moved here when trimming
  queries/S1.sql  long queries cited as sources (never results)
```

A workstream stays under 30 KB, `history.md` excluded. `now.md` merges normally; the append-only files merge with `--union`, so two sessions adding entries never conflict.

## The context nudge

The prompt hook needs the session's context size:

- **Terminal CLI:** the status line wrapper records `context_window.used_percentage`.
- **Desktop app:** the status line never runs there, so the hook reads the last main-thread token usage from the transcript and divides it by a 1,000,000-token window. Set `CTX_CONTEXT_WINDOW_TOKENS` (for example `200000`) in the environment Claude Code runs in to change that.

## Privacy

Workstreams live only on your machine; the context repository has no remote. `ctx lint` rejects email addresses and IBANs, and the rules tell the agent never to store secrets, personal data or query results. Review what you add before you ever push the folder anywhere.

## Troubleshooting

Hooks fail open: an error never blocks a session, it only makes it quiet. If sessions stop asking or nudging, run:

```bash
~/.claude/context/bin/ctx doctor
```

Cloud sessions do not read `~/.claude/settings.json`, so they get no hooks.

## Uninstall

```bash
./uninstall.sh
```

It removes the hooks, restores your original status line, removes the rules block and the skill, and leaves your workstreams (and the `.src` clone of a one-line install) in the context folder.

## Tests

```bash
tests/ctx-test.sh
tests/install-test.sh
```

CI runs both on Ubuntu and macOS.

## Design

See [docs/design.md](docs/design.md) for the decisions behind the layout, the merge strategy and the nudge, and the prior art they borrow from.

## License

MIT
