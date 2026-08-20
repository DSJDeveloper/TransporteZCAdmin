/**
 * @description Tracks browser tabs via heartbeat + BroadcastChannel.
 * When the last tab is closed (pagehide), sets a flag so next initAuth
 * destroys the Supabase session. On refresh, the flag is cleared early.
 */

const TAB_ID_KEY = 'tab_id'
const HB_PREFIX = 'tab_hb_'
const LAST_TAB_CLOSED_KEY = 'last_tab_closed'
const BC_CHANNEL = 'tab-sync'
const HB_TTL = 30_000
const HB_INTERVAL = 15_000

function countHeartbeats(): number {
  const keys = new Set<string>()
  for (let i = 0; i < localStorage.length; i++) {
    const key = localStorage.key(i)
    if (key?.startsWith(HB_PREFIX)) keys.add(key)
  }
  return keys.size
}

function cleanupStaleHeartbeats() {
  const now = Date.now()
  const toRemove: string[] = []
  for (let i = 0; i < localStorage.length; i++) {
    const key = localStorage.key(i)
    if (!key?.startsWith(HB_PREFIX)) continue
    const ts = parseInt(localStorage.getItem(key) || '0')
    if (now - ts > HB_TTL) toRemove.push(key)
  }
  toRemove.forEach((k) => localStorage.removeItem(k))
}

export function useTabTracker() {
  let tabId = sessionStorage.getItem(TAB_ID_KEY)
  if (!tabId) {
    tabId = crypto.randomUUID()
    sessionStorage.setItem(TAB_ID_KEY, tabId)
  }

  let channel: BroadcastChannel | null = null
  try {
    channel = new BroadcastChannel(BC_CHANNEL)
    channel.onmessage = (ev) => {
      if (ev.data?.type === 'tab-closed') {
        localStorage.removeItem(HB_PREFIX + ev.data.tabId)
      }
    }
  } catch {
    // BroadcastChannel not supported — cross-tab sync degraded
  }

  const writeHeartbeat = () =>
    localStorage.setItem(HB_PREFIX + tabId!, Date.now().toString())

  cleanupStaleHeartbeats()
  writeHeartbeat()

  const hbTimer = setInterval(() => {
    writeHeartbeat()
    cleanupStaleHeartbeats()
  }, HB_INTERVAL)

  const handlePageHide = () => {
    localStorage.removeItem(HB_PREFIX + tabId!)
    channel?.postMessage({ type: 'tab-closed', tabId: tabId })

    if (countHeartbeats() === 0) {
      localStorage.setItem(LAST_TAB_CLOSED_KEY, Date.now().toString())
    }
  }

  const handlePageShow = () => {
    writeHeartbeat()
    localStorage.removeItem(LAST_TAB_CLOSED_KEY)
  }

  window.addEventListener('pagehide', handlePageHide)
  window.addEventListener('pageshow', handlePageShow)

  return () => {
    clearInterval(hbTimer)
    window.removeEventListener('pagehide', handlePageHide)
    window.removeEventListener('pageshow', handlePageShow)
    channel?.close()
  }
}
