import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { ago, ctxFromSettings, workstreamBody } from '../hooks/register'

const CTX = '/home/me/.claude/context/bin/ctx'
const SETTINGS = JSON.stringify({
  hooks: {
    SessionStart: [
      { hooks: [{ type: 'command', command: 'other-tool start' }] },
      { hooks: [{ type: 'command', command: `${CTX} hook start` }] },
    ],
  },
})
const SHOW = [
  '# Workstream alpha',
  '',
  `Edit only the files in /d. Checkpoint with: ${CTX} checkpoint s1 "<message>"`,
  '',
  '---',
  'title: Alpha',
  'status: active',
  '---',
  '',
  '## Goal',
  '',
  'Ship alpha.',
  '',
  '## Decisions (active)',
  '',
  '- D1 | 2026-10-20 | active | Use a lock.',
].join('\n')
const STATUS = {
  version: 1,
  ctx: CTX,
  home: '/home/me/.claude/context',
  session: 's1',
  workstream: 'alpha',
  registered: 'alpha',
  show: SHOW,
  draft: { dir: '/d', changed: ['log.md', 'now.md'] },
  last_checkpoint: { commit: 'abc1234', date: '2026-10-20T10:00:00Z', subject: 'alpha: create' },
  context: { percent: null, next_nudge_percent: 50 },
  workstreams: [
    { slug: 'alpha', status: 'active', updated: '2026-10-20', title: 'Alpha', summary: 'Alpha summary', repos: '-' },
    { slug: 'beta', status: 'paused', updated: '2026-10-01', title: 'Beta', summary: 'Beta summary', repos: '-' },
    { slug: 'gamma', status: 'done', updated: '2026-09-01', title: 'Gamma', summary: 'Gamma summary', repos: '-' },
  ],
}
const PANE = {
  plugin: 'workstream-pane',
  component: 'Pane',
  requestId: 'workstream',
  props: { title: 'Workstream', isFocused: false, bodyColumns: 60, placement: 'dock', scroll: { offset: 0, bodyRows: 40 }, view: {} },
} as const

function fakeHost(on: On, status: object, calls: string[][]) {
  mock.clock(on)
  mock.env(on, { HOME: '/home/me' })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('command.register', ($, e) => ({ value: { command: e.name } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('fs.read', () => ({ value: SETTINGS }))
  on('session.id', () => ({ value: 's1' }))
  on('session.usage', () => ({ value: { startedAt: 0, context: { window: 1_000_000, percent: 37 }, rateLimits: [] } }))
  on('process.run', ($, e) => {
    calls.push([...e.argv])
    if (e.argv[1] === 'status') {
      return { value: { exitCode: 0, stdout: JSON.stringify(status), stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    }
    return { value: { exitCode: 1, stdout: '', stderr: 'merge conflict in now.md', isStdoutTruncated: false, isStderrTruncated: false } }
  })
}

test('finds ctx from the SessionStart hook in settings', async () => {
  expect(ctxFromSettings(SETTINGS)).toBe(CTX)
  expect(ctxFromSettings('{"hooks":{"SessionStart":[]}}')).toBe(undefined)
})

test('drops the header and frontmatter from the show view', async () => {
  expect(workstreamBody(SHOW)).toEqual({
    now: '## Goal\n\nShip alpha.',
    details: '## Decisions (active)\n\n- D1 | 2026-10-20 | active | Use a lock.',
  })
  expect(workstreamBody('## Goal\n\nOnly now.')).toEqual({ now: '## Goal\n\nOnly now.', details: '' })
})

test('says how long ago a checkpoint was', async () => {
  const now = Date.parse('2026-10-20T12:00:00Z')
  expect(ago('2026-10-20T11:59:50Z', now)).toBe('just now')
  expect(ago('2026-10-20T11:15:00Z', now)).toBe('45 min ago')
  expect(ago('2026-10-20T09:00:00Z', now)).toBe('3 h ago')
  expect(ago('2026-10-15T12:00:00Z', now)).toBe('5 days ago')
})

test('shows the workstream, draft, context and index on every surface', async ($, on) => {
  const calls: string[][] = []
  fakeHost(on, STATUS, calls)
  await $.session.start({ cwd: '/repo', surface: 'desktop', isInteractive: true })
  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect(await ui.find({ text: 'Unpublished: log.md, now.md' })).toBeDefined()
    expect(await ui.find({ text: '37% used, next nudge at 50%' })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /ago \(abc1234\)$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^create$/ })).toBeDefined()
    expect(await ui.find({ type: 'Markdown', text: '## Goal' })).toBeDefined()
    expect(await ui.find({ type: 'Markdown', text: 'Use a lock' })).toBe(undefined)
    await ui.press({ key: 'details' })
    expect(await ui.find({ type: 'Markdown', text: 'Use a lock' })).toBeDefined()
    await ui.press({ key: 'details' })
    expect(await ui.find({ text: 'beta (paused)' })).toBeDefined()
    expect(await ui.find({ text: 'Beta summary' })).toBeDefined()
    expect(await ui.find({ text: /gamma/ })).toBe(undefined)
    await ui.unmount()
  }
  expect(calls[0]).toEqual([CTX, 'status', 's1'])
})

test('checkpoints with the typed message and shows what ctx said', async ($, on) => {
  const calls: string[][] = []
  fakeHost(on, STATUS, calls)
  await $.session.start({ cwd: '/repo', surface: 'desktop', isInteractive: true })
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  await ui.input({ key: 'checkpoint', text: '  ' })
  expect(await ui.find({ text: 'Write a checkpoint message first.' })).toBeDefined()
  await ui.input({ key: 'checkpoint', text: 'ship it' })
  expect(calls).toContainEqual([CTX, 'checkpoint', 's1', 'ship it'])
  expect(await ui.find({ text: 'merge conflict in now.md' })).toBeDefined()
  await ui.unmount()
})

test('an unregistered session says so and offers no checkpoint', async ($, on) => {
  fakeHost(on, { ...STATUS, workstream: null, registered: null, show: null, draft: null, last_checkpoint: null }, [])
  await $.session.start({ cwd: '/repo', surface: 'desktop', isInteractive: true })
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await ui.find({ text: 'No workstream yet' })).toBeDefined()
  expect(await ui.find({ key: 'checkpoint' })).toBe(undefined)
  expect(await ui.find({ text: 'Alpha summary' })).toBeDefined()
  expect(await ui.find({ text: 'Status' })).toBe(undefined)
  await ui.unmount()
})
