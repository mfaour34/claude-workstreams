export type WorkstreamRow = {
  slug: string
  status: string
  updated: string
  title: string
  summary: string
  repos: string
}

export type WorkstreamStatus = {
  version: number
  ctx: string
  home: string
  session: string
  workstream: string | null
  registered: string | null
  show: string | null
  draft: { dir: string; changed: string[] } | null
  last_checkpoint: { commit: string; date: string; subject: string } | null
  context: { percent: number | null; next_nudge_percent: number }
  workstreams: WorkstreamRow[]
}

declare module 'claude-code' {
  interface PluginState {
    'workstream-pane': {
      status: WorkstreamStatus | null
      problem: string
      note: string
      percent: number | null
      expanded: boolean
      isPaneOpen: boolean
    }
  }
}
