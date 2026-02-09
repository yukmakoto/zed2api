import { icons } from '../icons'
import { showToast } from '../toast'

function copyText(text: string) {
  navigator.clipboard.writeText(text).then(() => showToast('Copied!')).catch(() => {})
}

export function renderIntegration() {
  const host = `http://127.0.0.1:${location.port || '8000'}`
  const page = document.getElementById('page-integration')!
  page.innerHTML = `
    <div class="page-header">
      <h2>Integration</h2>
      <p>Connect your tools to zed2api.</p>
    </div>
    <div class="page-body">
      <div class="config-list">
        <div class="config-card">
          <div class="config-card-header">
            <span class="config-icon">${icons.server}</span> Claude Code
          </div>
          <div class="config-card-body">
            <p>Add to <code>~/.claude.json</code>:</p>
            <div class="code-block" id="code-claude"><button class="copy-code-btn" data-target="code-claude">${icons.copy} Copy</button>{
  "apiBaseUrl": "${host}",
  "apiKey": "zed2api"
}</div>
          </div>
        </div>

        <div class="config-card">
          <div class="config-card-header">
            <span class="config-icon">${icons.code}</span> OpenAI SDK / cURL
          </div>
          <div class="config-card-body">
            <p>Use as an OpenAI-compatible endpoint:</p>
            <div class="code-block" id="code-openai"><button class="copy-code-btn" data-target="code-openai">${icons.copy} Copy</button>export OPENAI_API_BASE=${host}/v1
export OPENAI_API_KEY=zed2api

curl ${host}/v1/chat/completions \\
  -H "Content-Type: application/json" \\
  -d '{"model":"claude-sonnet-4-5","messages":[{"role":"user","content":"Hello"}]}'</div>
          </div>
        </div>

        <div class="config-card">
          <div class="config-card-header">
            <span class="config-icon">${icons.globe}</span> Anthropic SDK
          </div>
          <div class="config-card-body">
            <p>Use as an Anthropic-compatible endpoint:</p>
            <div class="code-block" id="code-anthropic"><button class="copy-code-btn" data-target="code-anthropic">${icons.copy} Copy</button>export ANTHROPIC_BASE_URL=${host}
export ANTHROPIC_API_KEY=zed2api

curl ${host}/v1/messages \\
  -H "Content-Type: application/json" \\
  -d '{"model":"claude-sonnet-4-5","max_tokens":1024,"messages":[{"role":"user","content":"Hello"}]}'</div>
          </div>
        </div>
      </div>
    </div>
  `

  page.querySelectorAll<HTMLButtonElement>('.copy-code-btn').forEach(btn => {
    btn.addEventListener('click', () => {
      const target = document.getElementById(btn.dataset.target!)!
      const clone = target.cloneNode(true) as HTMLElement
      clone.querySelector('.copy-code-btn')?.remove()
      copyText(clone.textContent?.trim() || '')
    })
  })
}
