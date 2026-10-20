import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { WorkstreamStatus } from '../types'

const PANE = 'workstream'
const TITLE = 'Workstream'
const REFRESH_MS = 10_000
const HOOK_SUFFIX = ' hook start'

const status = atom({ plugin: 'workstream-pane', key: 'status' } as const, null)
const problem = atom({ plugin: 'workstream-pane', key: 'problem' } as const, '')
const note = atom({ plugin: 'workstream-pane', key: 'note' } as const, '')
const percent = atom({ plugin: 'workstream-pane', key: 'percent' } as const, null)

type SettingsHooks = { hooks?: { SessionStart?: { hooks?: { command?: string }[] }[] } }

export function ctxFromSettings(text: string): string | undefined {
  const settings = JSON.parse(text) as SettingsHooks
  const commands = (settings.hooks?.SessionStart ?? []).flatMap(group => group.hooks ?? [])
  const command = commands
    .map(hook => hook.command ?? '')
    .find(line => line.endsWith(HOOK_SUFFIX) && /\/ctx$/.test(line.slice(0, -HOOK_SUFFIX.length)))
  return command?.slice(0, -HOOK_SUFFIX.length)
}

export function workstreamBody(show: string): string {
  const parts = show.split('\n---\n')
  return parts.length >= 3 ? parts.slice(2).join('\n---\n').trim() : show
}

export function ago(iso: string, now: number): string {
  const minutes = Math.max(0, Math.round((now - Date.parse(iso)) / 60_000))
  if (minutes < 1) return 'just now'
  if (minutes < 60) return `${minutes} min ago`
  if (minutes < 48 * 60) return `${Math.round(minutes / 60)} h ago`
  return `${Math.round(minutes / 1440)} days ago`
}

async function findCtx($: EngineInterface): Promise<string | undefined> {
  const home = await $.env.get('HOME')
  const text = await $.fs.read(`${home}/.claude/settings.json`).catch(() => '{}')
  return ctxFromSettings(typeof text === 'string' ? text : '{}')
}

function keep<T>(old: T, value: T): T {
  return JSON.stringify(old) === JSON.stringify(value) ? old : value
}

async function refresh($: EngineInterface): Promise<void> {
  const usage = await $.session.usage().catch(() => undefined)
  await update($, percent, old => keep(old, usage?.context.percent ?? null))
  const ctx = await findCtx($)
  if (!ctx) {
    await update($, problem, old => keep(old, 'No ctx hook in ~/.claude/settings.json. Run install.sh from claude-workstreams.'))
    return
  }
  const run = await $.process.run([ctx, 'status', await $.session.id()]).catch((error: Error) => ({
    exitCode: 1,
    stdout: '',
    stderr: error.message,
  }))
  if (run.exitCode !== 0) {
    await update($, problem, old => keep(old, run.stderr.trim() || `${ctx} status failed`))
    return
  }
  await update($, problem, old => keep(old, ''))
  await update($, status, old => keep(old, JSON.parse(run.stdout) as WorkstreamStatus))
}

async function checkpoint($: EngineInterface, message: string): Promise<void> {
  const current = await read($, status)
  if (!current?.workstream) return
  if (message.trim() === '') {
    await update($, note, () => 'Write a checkpoint message first.')
    return
  }
  await update($, note, () => 'Checkpointing...')
  const run = await $.process.run([current.ctx, 'checkpoint', current.session, message.trim()])
  const output = `${run.stdout}\n${run.stderr}`.trim()
  await update($, note, () => output || (run.exitCode === 0 ? 'Checkpointed.' : 'Checkpoint failed.'))
  await refresh($)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    void $.ui.open({ id: PANE, title: TITLE })
    void refresh($)
    // shortcut: polls even while the pane is closed; one `ctx status` run every 10 s is cheap.
    $.clock.every(REFRESH_MS, () => void refresh($))
    await $.command.register({ name: 'workstream', description: "Show this session's workstream in a pane" })
    return started
  })

  on('command.run', { command: 'workstream' }, async $ => {
    await $.ui.open({ id: PANE, title: TITLE })
    await refresh($)
    return { text: 'Workstream pane opened.' }
  })

  on('turn.complete', async ($, e, next) => {
    const done = await next(e)
    void refresh($)
    return done
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const ui = $.ui.resolve(e)
    const { Box, Text, Button, Markdown } = ui
    const Input = 'Input' in ui ? ui.Input : undefined
    const current = await read($, status)
    const error = await read($, problem)
    const message = await read($, note)
    const used = (await read($, percent)) ?? current?.context.percent ?? null
    const own = current?.workstreams.find(row => row.slug === current.workstream)
    const others = (current?.workstreams ?? []).filter(
      row => row.slug !== current?.workstream && (row.status === 'active' || row.status === 'paused'),
    )
    const changed = current?.draft?.changed ?? []
    const last = current?.last_checkpoint

    return (
      <Box flexDirection="column" gap={1}>
        {error !== '' && <Text color="red">{error}</Text>}
        {current === null && error === '' && <Text dimColor>Loading...</Text>}
        {current !== null && (
          <Box flexDirection="column">
            <Text bold>{current.workstream ?? 'No workstream yet'}</Text>
            {own && <Text dimColor>{own.summary}</Text>}
            {current.workstream === null && (
              <Text dimColor>
                {current.registered === 'none' ? 'This session chose no context file.' : 'The next prompt asks which workstream this session belongs to.'}
              </Text>
            )}
            {current.draft && (
              <Text color={changed.length > 0 ? 'yellow' : undefined}>
                {changed.length > 0 ? `Draft: unpublished edits in ${changed.join(', ')}` : 'Draft: clean'}
              </Text>
            )}
            {last && (
              <Text dimColor>
                Last checkpoint {last.commit}, {ago(last.date, Date.now())}: {last.subject}
              </Text>
            )}
            <Text dimColor>
              Context {used === null ? 'unknown' : `${used}%`}, next nudge at {current.context.next_nudge_percent}%
            </Text>
          </Box>
        )}
        {current?.workstream && Input && (
          <Input
            key="checkpoint"
            placeholder="Checkpoint message"
            submitLabel="Checkpoint"
            onSubmit={value => void checkpoint($, value)}
          />
        )}
        {message !== '' && <Text dimColor>{message}</Text>}
        <Button key="refresh" label="Refresh" onPress={() => void refresh($)} />
        {current?.show && <Markdown key="show" text={workstreamBody(current.show)} />}
        {others.length > 0 && (
          <Box flexDirection="column">
            <Text bold>Other workstreams</Text>
            {others.map(row => (
              <Text key={row.slug} dimColor={row.status === 'paused'}>
                {row.slug} ({row.status}, {row.updated}): {row.summary}
              </Text>
            ))}
          </Box>
        )}
      </Box>
    )
  })
}
