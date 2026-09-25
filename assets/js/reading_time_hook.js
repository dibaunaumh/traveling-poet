// How long the owner of a journal spends on each paragraph of their own
// entry, for the taste profile (TravelingPoet.Reading). Only mounted on the
// owner's journal, and only when they left reading signals on in Settings.
// The hook sits on a hidden element beside the entry (the entry's own
// element carries the Markers hook) and watches the entry by id.
//
// Each prose paragraph is known by a key the server computes the same way
// (Journal.Paragraphs.key/1): its visible text with whitespace collapsed and
// trimmed, SHA-256, the first 16 hex characters. The server keeps only keys
// that are paragraphs of this entry, so a mismatch records nothing.
//
// A second counts when the page is visible, the reader did something in the
// last IDLE_MS, and the paragraph is on screen (half of it, or half the
// screen when it is taller than that); the second is split between the
// paragraphs on screen. Sent every FLUSH_MS, when the page is hidden, and
// before LiveView navigates away.

const TICK_MS = 1000
const FLUSH_MS = 20000
const IDLE_MS = 45000
const ACTIVITY = ["scroll", "wheel", "pointermove", "pointerdown", "keydown", "touchstart"]

export async function paragraphKey(text) {
  const normalized = text.replace(/\s+/gu, " ").trim()
  const bytes = new TextEncoder().encode(normalized)
  const digest = await crypto.subtle.digest("SHA-256", bytes)
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("")
    .slice(0, 16)
}

const ReadingTime = {
  mounted() {
    if (!(window.crypto && crypto.subtle && "IntersectionObserver" in window)) return
    this.kinds = (this.el.dataset.kinds || "").split(" ").filter(Boolean)
    this.keys = new WeakMap()
    this.onScreen = new Set()
    this.pending = {}
    this.lastActive = Date.now()

    this.onActivity = () => (this.lastActive = Date.now())
    ACTIVITY.forEach((e) => window.addEventListener(e, this.onActivity, {passive: true}))
    this.onHidden = () => document.visibilityState === "hidden" && this.flush()
    document.addEventListener("visibilitychange", this.onHidden)
    this.onLeave = () => this.flush()
    window.addEventListener("phx:page-loading-start", this.onLeave)
    window.addEventListener("pagehide", this.onLeave)

    this.observer = new IntersectionObserver((entries) => this.seen(entries), {
      threshold: [0, 0.25, 0.5, 0.75, 1],
    })
    // A revision or a spread change re-renders the paragraphs.
    this.target = document.getElementById(this.el.dataset.target)
    this.rescan = debounce(() => this.scan(), 300)
    this.mutations = new MutationObserver(this.rescan)
    if (this.target) this.mutations.observe(this.target, {childList: true, subtree: true})
    this.scan()
    this.ticker = setInterval(() => this.tick(), TICK_MS)
    this.flusher = setInterval(() => this.flush(), FLUSH_MS)
  },

  destroyed() {
    if (!this.observer) return
    this.flush()
    clearInterval(this.ticker)
    clearInterval(this.flusher)
    this.observer.disconnect()
    this.mutations.disconnect()
    ACTIVITY.forEach((e) => window.removeEventListener(e, this.onActivity))
    document.removeEventListener("visibilitychange", this.onHidden)
    window.removeEventListener("phx:page-loading-start", this.onLeave)
    window.removeEventListener("pagehide", this.onLeave)
  },

  // The prose paragraphs on the page now: a revision or a re-render
  // replaces them, so they are found again after every change.
  scan() {
    this.observer.disconnect()
    this.onScreen.clear()
    const selector = this.kinds.map((k) => `[data-section-kind="${k}"] .prose > p`).join(", ")
    if (!selector || !this.target) return
    this.target.querySelectorAll(selector).forEach((p) => {
      this.observer.observe(p)
      if (!this.keys.has(p)) paragraphKey(p.textContent).then((key) => this.keys.set(p, key))
    })
  },

  seen(entries) {
    const half = window.innerHeight / 2
    entries.forEach((e) => {
      const visible = e.intersectionRatio >= 0.5 || e.intersectionRect.height >= half
      if (visible) this.onScreen.add(e.target)
      else this.onScreen.delete(e.target)
    })
  },

  tick() {
    if (document.visibilityState !== "visible") return
    if (Date.now() - this.lastActive > IDLE_MS) return
    const keyed = [...this.onScreen].map((p) => this.keys.get(p)).filter(Boolean)
    if (keyed.length === 0) return
    const share = TICK_MS / keyed.length
    keyed.forEach((key) => (this.pending[key] = (this.pending[key] || 0) + share))
  },

  flush() {
    const reads = {}
    Object.entries(this.pending).forEach(([key, ms]) => {
      if (ms >= 1) reads[key] = Math.round(ms)
    })
    this.pending = {}
    if (Object.keys(reads).length === 0) return
    this.pushEvent("paragraph_reads", {entry_id: this.el.dataset.entryId, reads})
  },
}

function debounce(fn, ms) {
  let t
  return (...args) => {
    clearTimeout(t)
    t = setTimeout(() => fn(...args), ms)
  }
}

export default ReadingTime
