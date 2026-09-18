// First-party page events for the admin funnel (see TravelingPoet.Analytics).
// No cookie and no storage: the server derives an anonymous day-scoped id
// from the request, so this only reports what happened on the page.
//
//   pageview  on load and on LiveView navigation
//   engage    when the page is hidden: visible time and deepest scroll
//   click     any element (or form submit) carrying data-track="label"

const SKIP = /^\/(admin|dev|book\/render)(\/|$)/

let path = null
let visibleMs = 0
let visibleSince = null
let maxScroll = 0
let reported = true

function send(event) {
  const body = JSON.stringify({...event, p: path, m: window.innerWidth < 768})
  try {
    if (!navigator.sendBeacon || !navigator.sendBeacon("/e", body)) {
      fetch("/e", {method: "POST", body, keepalive: true, headers: {"content-type": "text/plain"}})
    }
  } catch (_e) {}
}

function scrollPct() {
  const doc = document.documentElement
  const max = doc.scrollHeight - window.innerHeight
  if (max <= 0) return 100
  return Math.min(100, Math.round((window.scrollY / max) * 100))
}

function refHost() {
  try {
    const host = document.referrer && new URL(document.referrer).host
    return host && host !== location.host ? host : null
  } catch (_e) {
    return null
  }
}

function flush() {
  if (reported || path === null) return
  if (visibleSince !== null) visibleMs += Date.now() - visibleSince
  // Scroll events are throttled or skipped in background tabs; read it once more.
  maxScroll = Math.max(maxScroll, scrollPct())
  visibleSince = document.visibilityState === "visible" ? Date.now() : null
  send({n: "engage", d: visibleMs, s: maxScroll})
  reported = true
}

function pageview(first) {
  const next = location.pathname
  if (next === path) return
  flush()
  path = SKIP.test(next) ? null : next
  if (path === null) return

  visibleMs = 0
  visibleSince = document.visibilityState === "visible" ? Date.now() : null
  maxScroll = scrollPct()
  reported = false

  const q = new URLSearchParams(location.search)
  send({
    n: "pageview",
    r: first ? refHost() : null,
    us: q.get("utm_source") || q.get("ref"),
    uc: q.get("utm_campaign"),
  })
}

// A tracked form counts once, on submit, however it was sent (button or Enter).
function track(el, submit) {
  const label = el && el.closest("[data-track]")
  if (!label || path === null || (label.tagName === "FORM") !== submit) return
  send({n: "click", t: label.dataset.track})
}

export function initBeacon() {
  pageview(true)
  window.addEventListener("phx:navigate", () => pageview(false))
  window.addEventListener("scroll", () => (maxScroll = Math.max(maxScroll, scrollPct())), {passive: true})
  document.addEventListener("click", e => track(e.target, false), {capture: true})
  document.addEventListener("submit", e => track(e.target, true), {capture: true})
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") {
      flush()
    } else if (path !== null) {
      // Back on the page: keep counting into a fresh engage report.
      visibleSince = Date.now()
      reported = false
    }
  })
  window.addEventListener("pagehide", flush)
}
