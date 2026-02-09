export interface Account {
  name: string
  user_id: string
  current: boolean
}

export interface AccountsResponse {
  accounts: Account[]
  current: string
}

export interface UsageInfo {
  plan?: string
  monthly_spend_in_cents?: number
  monthly_spending_limit_in_cents?: number
  subscriptionPeriod?: string[]
  githubUserLogin?: string
  // from /client/users/me
  user?: { github_login?: string; name?: string; avatar_url?: string }
  planInfo?: {
    plan?: string
    subscription_period?: { started_at?: string; ended_at?: string }
    usage?: { model_requests?: { used?: number; limit?: { limited?: number } } }
  }
  [key: string]: unknown
}

export async function fetchAccounts(): Promise<AccountsResponse> {
  const r = await fetch('/zed/accounts')
  if (!r.ok) throw new Error(`${r.status}`)
  return r.json()
}

export async function switchAccount(name: string): Promise<void> {
  await fetch('/zed/accounts/switch', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ account: name }),
  })
}

export async function fetchUsage(): Promise<UsageInfo> {
  const r = await fetch('/zed/usage')
  if (!r.ok) throw new Error(`${r.status}`)
  return r.json()
}

export async function fetchBilling(): Promise<Record<string, unknown>> {
  const r = await fetch('/zed/billing')
  if (!r.ok) throw new Error(`${r.status}`)
  return r.json()
}

export async function startLogin(name?: string): Promise<{ login_url?: string; error?: string }> {
  const r = await fetch('/zed/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(name ? { name } : {}),
  })
  return r.json()
}

export async function fetchLoginStatus(): Promise<{ status: string }> {
  const r = await fetch('/zed/login/status')
  return r.json()
}

export interface ChatMessage {
  role: 'user' | 'assistant' | 'system'
  content: string
}

export async function sendOpenAI(
  model: string,
  messages: ChatMessage[],
  maxTokens = 4096,
): Promise<string> {
  const r = await fetch('/v1/chat/completions', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ model, messages, max_tokens: maxTokens }),
  })
  const d = await r.json()
  return d.choices?.[0]?.message?.content ?? JSON.stringify(d, null, 2)
}

export async function sendAnthropic(
  model: string,
  messages: ChatMessage[],
  maxTokens = 4096,
): Promise<string> {
  const r = await fetch('/v1/messages', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ model, messages, max_tokens: maxTokens }),
  })
  const d = await r.json()
  return d.content?.[0]?.text ?? JSON.stringify(d, null, 2)
}
