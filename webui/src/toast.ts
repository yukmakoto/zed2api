let timer: ReturnType<typeof setTimeout> | null = null

export function showToast(msg: string) {
  const el = document.getElementById('toast')!
  el.textContent = msg
  el.classList.add('visible')
  if (timer) clearTimeout(timer)
  timer = setTimeout(() => el.classList.remove('visible'), 2500)
}
