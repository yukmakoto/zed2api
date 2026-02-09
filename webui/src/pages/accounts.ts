import { fetchAccounts, fetchUsage, fetchBilling, switchAccount, startLogin, fetchLoginStatus, type UsageInfo } from '../api'
import { icons } from '../icons'
import { showToast } from '../toast'

function esc(s: string): string {
  const d = document.createElement('div')
  d.textContent = s
  return d.innerHTML
}

export function renderAccounts() {
  const page = document.getElementById('page-accounts')!
  page.innerHTML = `
    <div class="page-header">
      <h2>Accounts</h2>
      <p>Manage your Zed accounts and credentials.</p>
    </div>
    <div class="page-body">
      <div class="account-list" id="account-list"></div>
      <button class="add-account-btn" id="add-account-btn">
        <span class="add-icon">${icons.plus}</span>
        <span>Add account via GitHub OAuth</span>
        <span class="add-hint">Opens in private/incognito window</span>
      </button>
      <div id="login-banner" class="login-banner" style="display:none"></div>
      <div class="usage-section" id="usage-section" style="display:none"></div>
    </div>
  `
  document.getElementById('add-account-btn')!.addEventListener('click', doLogin)
  loadAccounts()
}

async function loadAccounts() {
  const list = document.getElementById('account-list')!
  try {
    const data = await fetchAccounts()
    const accs = data.accounts || []
    document.getElementById('acc-count')!.textContent = String(accs.length)
    if (accs.length === 0) {
      list.innerHTML = `<div class="empty-state">
        <div class="empty-icon">${icons.users}</div>
        <div>No accounts configured yet.</div>
      </div>`
      return
    }
    list.innerHTML = accs.map(acc => `
      <div class="account-card ${acc.current ? 'active' : ''}">
        <div class="account-avatar">${acc.name.charAt(0).toUpperCase()}</div>
        <div class="account-info">
          <div class="account-name">${esc(acc.name)}</div>
          <div class="account-meta">ID: ${esc(acc.user_id)}</div>
        </div>
        <div class="account-actions">
          ${acc.current
            ? `<span class="tag tag-active">${icons.check} Active</span>`
            : `<button class="btn switch-btn" data-name="${esc(acc.name)}">Switch</button>`}
        </div>
      </div>
    `).join('')

    list.querySelectorAll<HTMLButtonElement>('.switch-btn').forEach(btn => {
      btn.addEventListener('click', async () => {
        const name = btn.dataset.name!
        await switchAccount(name)
        showToast(`Switched to ${name}`)
        loadAccounts()
      })
    })
    if (accs.some(a => a.current)) loadUsage()
  } catch (e) {
    list.innerHTML = `<div class="error-state">
      Failed to load accounts: ${e instanceof Error ? esc(e.message) : 'unknown error'}
    </div>`
  }
}

async function loadUsage() {
  const section = document.getElementById('usage-section')!
  try {
    // Fetch JWT claims for plan info
    const usage: UsageInfo = await fetchUsage()
    // Also fetch /client/users/me for richer data
    const billing = await fetchBilling().catch(() => null) as Record<string, unknown> | null
    if (billing?.plan && typeof billing.plan === 'object') {
      const planObj = billing.plan as Record<string, unknown>
      const period = planObj.subscription_period as Record<string, string> | undefined
      if (period?.started_at && period?.ended_at) {
        usage.subscriptionPeriod = [period.started_at, period.ended_at]
      }
    }
    section.style.display = 'block'
    section.innerHTML = renderUsageCard(usage)
  } catch {
    section.style.display = 'none'
  }
}

function renderUsageCard(u: UsageInfo): string {
  const plan = u.plan || 'Unknown'
  const limitCents = u.monthly_spending_limit_in_cents ?? 2000
  const limit = (limitCents / 100).toFixed(2)

  const period = u.subscriptionPeriod
  let periodHtml = ''
  if (period && period.length === 2) {
    const end = new Date(period[1])
    const days = Math.ceil((end.getTime() - Date.now()) / 86400000)
    periodHtml = `<div class="usage-stat">
      <div class="usage-stat-label">Expires</div>
      <div class="usage-stat-value">${end.toLocaleDateString('en-US', { month: 'long', day: 'numeric', year: 'numeric' })} <small>(${days}d)</small></div>
    </div>`
  }

  return `
    <div class="usage-card">
      <div class="usage-card-header">
        <span class="usage-card-icon">${icons.activity}</span>
        <h3>Usage</h3>
      </div>
      <div class="usage-stats">
        <div class="usage-stat">
          <div class="usage-stat-label">Plan</div>
          <div class="usage-stat-value plan-value">${esc(plan)}</div>
        </div>
        ${periodHtml}
        <div class="usage-stat">
          <div class="usage-stat-label">Token Spend</div>
          <div class="usage-stat-value">
            <a href="https://zed.dev/account/billing" target="_blank" class="spend-link" title="View on zed.dev">View on zed.dev ${icons.externalLink}</a>
            <small>limit $${limit}</small>
          </div>
        </div>
      </div>
    </div>
  `
}

async function doLogin() {
  const banner = document.getElementById('login-banner')!
  const btn = document.getElementById('add-account-btn') as HTMLButtonElement
  btn.disabled = true
  banner.style.display = 'block'
  banner.innerHTML = `<span class="spinner"></span> Generating keypair and starting OAuth...`
  try {
    const data = await startLogin()
    if (data.error) {
      banner.innerHTML = `<span class="error-text">${icons.xCircle} ${esc(data.error)}</span>`
      btn.disabled = false
      return
    }
    banner.innerHTML = `
      <span class="spinner"></span>
      Waiting for GitHub login callback...
      <span class="login-hint">Complete the login in the browser window that opened. This page will update automatically.</span>
    `
    const poll = setInterval(async () => {
      try {
        const st = await fetchLoginStatus()
        if (st.status === 'success') {
          clearInterval(poll)
          banner.innerHTML = `${icons.check} <span>Login successful</span>`
          btn.disabled = false
          showToast('Account added successfully')
          loadAccounts()
          setTimeout(() => { banner.style.display = 'none' }, 3000)
        } else if (st.status === 'failed') {
          clearInterval(poll)
          banner.innerHTML = `<span class="error-text">${icons.xCircle} Login failed. Try again.</span>`
          btn.disabled = false
        }
      } catch { /* ignore */ }
    }, 1500)
  } catch (e) {
    banner.innerHTML = `<span class="error-text">${icons.xCircle} Error: ${e instanceof Error ? esc(e.message) : 'unknown'}</span>`
    btn.disabled = false
  }
}
