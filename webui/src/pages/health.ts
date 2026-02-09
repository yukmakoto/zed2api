import { icons } from '../icons'

interface CheckResult {
  name: string
  desc: string
  status: 'ok' | 'fail' | 'pending'
  detail: string
  latency?: number
}

const CHECKS: { name: string; desc: string; run: () => Promise<Omit<CheckResult, 'name' | 'desc'>> }[] = [
  {
    name: 'API Server',
    desc: 'Local proxy is responding',
    run: async () => {
      const t0 = performance.now()
      const r = await fetch('/v1/models')
      const latency = Math.round(performance.now() - t0)
      if (!r.ok) return { status: 'fail', detail: `HTTP ${r.status}`, latency }
      const d = await r.json()
      const count = d.data?.length ?? 0
      return { status: 'ok', detail: `${count} models available`, latency }
    },
  },
  {
    name: 'Accounts',
    desc: 'At least one account configured',
    run: async () => {
      const t0 = performance.now()
      const r = await fetch('/zed/accounts')
      const latency = Math.round(performance.now() - t0)
      if (!r.ok) return { status: 'fail', detail: `HTTP ${r.status}`, latency }
      const d = await r.json()
      const count = d.accounts?.length ?? 0
      if (count === 0) return { status: 'fail', detail: 'No accounts configured', latency }
      const current = d.accounts.find((a: { current: boolean }) => a.current)
      return { status: 'ok', detail: `${count} account(s), active: ${current?.name ?? 'none'}`, latency }
    },
  },
  {
    name: 'Token Refresh',
    desc: 'Can obtain a JWT from Zed',
    run: async () => {
      const t0 = performance.now()
      const r = await fetch('/zed/usage')
      const latency = Math.round(performance.now() - t0)
      if (!r.ok) return { status: 'fail', detail: `HTTP ${r.status} — check account credentials`, latency }
      const d = await r.json()
      const plan = d.plan ?? 'unknown'
      return { status: 'ok', detail: `Plan: ${plan}`, latency }
    },
  },
  {
    name: 'OpenAI Endpoint',
    desc: '/v1/chat/completions is reachable',
    run: async () => {
      const t0 = performance.now()
      try {
        // Send OPTIONS to check endpoint exists without triggering a real proxy call
        const r = await fetch('/v1/chat/completions', { method: 'OPTIONS' })
        const latency = Math.round(performance.now() - t0)
        return { status: r.ok ? 'ok' : 'fail', detail: `HTTP ${r.status}`, latency }
      } catch (e) {
        return { status: 'fail', detail: e instanceof Error ? e.message : 'unreachable' }
      }
    },
  },
  {
    name: 'Anthropic Endpoint',
    desc: '/v1/messages is reachable',
    run: async () => {
      const t0 = performance.now()
      try {
        const r = await fetch('/v1/messages', { method: 'OPTIONS' })
        const latency = Math.round(performance.now() - t0)
        return { status: r.ok ? 'ok' : 'fail', detail: `HTTP ${r.status}`, latency }
      } catch (e) {
        return { status: 'fail', detail: e instanceof Error ? e.message : 'unreachable' }
      }
    },
  },
]

export function renderHealth() {
  const page = document.getElementById('page-health')!
  page.innerHTML = `
    <div class="page-header" style="display:flex;align-items:flex-end;justify-content:space-between">
      <div>
        <h2>Health Check</h2>
        <p>Verify all services are operational.</p>
      </div>
      <button class="btn" id="rerun-btn">
        ${icons.refresh} Re-run
      </button>
    </div>
    <div class="page-body">
      <div class="health-summary" id="health-summary"></div>
      <div class="health-list" id="health-list"></div>
    </div>
  `

  document.getElementById('rerun-btn')!.addEventListener('click', runChecks)
  runChecks()
}

async function runChecks() {
  const list = document.getElementById('health-list')!
  const summary = document.getElementById('health-summary')!

  // Show pending state
  list.innerHTML = CHECKS.map(c => `
    <div class="health-row pending">
      <div class="health-status"><span class="spinner"></span></div>
      <div class="health-info">
        <div class="health-name">${c.name}</div>
        <div class="health-desc">${c.desc}</div>
      </div>
      <div class="health-detail">Checking...</div>
    </div>
  `).join('')

  summary.innerHTML = `<div class="health-summary-text"><span class="spinner"></span> Running checks...</div>`

  const results: CheckResult[] = []

  for (let i = 0; i < CHECKS.length; i++) {
    const c = CHECKS[i]
    let result: CheckResult
    try {
      const r = await c.run()
      result = { name: c.name, desc: c.desc, ...r }
    } catch (e) {
      result = { name: c.name, desc: c.desc, status: 'fail', detail: e instanceof Error ? e.message : 'error' }
    }
    results.push(result)

    // Update this row
    const rows = list.querySelectorAll('.health-row')
    const row = rows[i]
    if (row) {
      row.className = `health-row ${result.status}`
      row.innerHTML = `
        <div class="health-status">
          ${result.status === 'ok' ? icons.checkCircle : icons.xCircle}
        </div>
        <div class="health-info">
          <div class="health-name">${result.name}</div>
          <div class="health-desc">${result.desc}</div>
        </div>
        <div class="health-right">
          <div class="health-detail">${esc(result.detail)}</div>
          ${result.latency != null ? `<div class="health-latency">${result.latency}ms</div>` : ''}
        </div>
      `
    }
  }

  // Summary
  const passed = results.filter(r => r.status === 'ok').length
  const total = results.length
  const allOk = passed === total
  summary.innerHTML = `
    <div class="health-summary-icon ${allOk ? 'ok' : 'warn'}">
      ${allOk ? icons.checkCircle : icons.alertCircle}
    </div>
    <div>
      <div class="health-summary-title">${allOk ? 'All systems operational' : `${passed}/${total} checks passed`}</div>
      <div class="health-summary-sub">Last checked: ${new Date().toLocaleTimeString()}</div>
    </div>
  `
}

function esc(s: string): string {
  const d = document.createElement('div')
  d.textContent = s
  return d.innerHTML
}
