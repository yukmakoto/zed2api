import './style.css'
import { icons } from './icons'
import { renderAccounts } from './pages/accounts'
import { renderHealth } from './pages/health'
import { renderEndpoints } from './pages/endpoints'
import { renderIntegration } from './pages/integration'

const app = document.getElementById('app')!

app.innerHTML = `
<div class="app">
  <aside class="sidebar">
    <div class="sidebar-header">
      <h1><span class="logo-icon">${icons.zap}</span> zed2api</h1>
      <p>Zed LLM API Proxy</p>
    </div>
    <nav class="sidebar-nav">
      <div class="nav-group">
        <div class="nav-group-label">Manage</div>
        <button class="nav-btn active" data-page="accounts">
          <span class="icon">${icons.users}</span> Accounts
          <span class="badge" id="acc-count">0</span>
        </button>
        <button class="nav-btn" data-page="health">
          <span class="icon">${icons.activity}</span> Health
        </button>
      </div>
      <div class="nav-group">
        <div class="nav-group-label">Reference</div>
        <button class="nav-btn" data-page="endpoints">
          <span class="icon">${icons.globe}</span> Endpoints
        </button>
        <button class="nav-btn" data-page="integration">
          <span class="icon">${icons.code}</span> Integration
        </button>
      </div>
    </nav>
    <div class="sidebar-footer">
      <span class="status-dot"></span> Running on :${location.port || '8000'}
    </div>
  </aside>
  <main class="main-content">
    <div class="page active" id="page-accounts"></div>
    <div class="page" id="page-health"></div>
    <div class="page" id="page-endpoints"></div>
    <div class="page" id="page-integration"></div>
  </main>
</div>
<div class="toast" id="toast"></div>
`

// Navigation
document.querySelectorAll<HTMLButtonElement>('.nav-btn[data-page]').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.nav-btn').forEach(b => b.classList.remove('active'))
    document.querySelectorAll('.page').forEach(p => p.classList.remove('active'))
    btn.classList.add('active')
    const pageId = btn.dataset.page!
    document.getElementById(`page-${pageId}`)!.classList.add('active')
  })
})

// Render pages
renderAccounts()
renderHealth()
renderEndpoints()
renderIntegration()
