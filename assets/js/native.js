// The page's side of the iOS app.
//
// The app (the traveling-poet-ios repo) is a web view around this site. It
// injects Capacitor's bridge into every page it loads, and since this project
// has no npm bundle to import @capacitor/core from, the bridge's two
// primitives are used directly: `nativePromise` to call a plugin method,
// `addListener` for plugin events. (`Capacitor.Plugins.*` is NOT filled in on
// a remote page; only these two are.)
//
// In a browser `window.Capacitor` does not exist and nothing here runs.

const cap = () => window.Capacitor

export const isNative = () => !!(cap() && cap().isNativePlatform && cap().isNativePlatform())

export const call = (plugin, method, options = {}) => cap().nativePromise(plugin, method, options)

export const listen = (plugin, event, callback) => cap().addListener(plugin, event, callback)

// -- links ------------------------------------------------------------------
//
// A web view has no tabs, no address bar and no downloads. Left alone,
// Capacitor throws every cross-origin link AND every same-origin
// target="_blank" out to Safari, where the reader is not signed in: the book
// opened there as a sign-in page, and the PDF went nowhere at all.

const PDF_PATH = /^\/journal\/book\/pdf\/\d+$/

// These belong to another app (Telegram pairing) or to the system; the web
// view hands them over by itself.
const SYSTEM_HOSTS = new Set(["t.me", "telegram.me"])

function openInSheet(url) {
  return call("Browser", "open", {url, presentationStyle: "popover"})
}

async function openPdf(url) {
  url.searchParams.set("format", "json")
  const response = await fetch(url, {credentials: "same-origin", headers: {accept: "application/json"}})
  if (!response.ok) throw new Error(`pdf link ${response.status}`)
  const {url: signed} = await response.json()
  return openInSheet(signed)
}

function onClick(e) {
  if (e.defaultPrevented || e.button !== 0) return
  const a = e.target.closest("a[href]")
  if (!a) return

  let url
  try {
    url = new URL(a.getAttribute("href"), window.location.href)
  } catch (_e) {
    return
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") return
  if (SYSTEM_HOSTS.has(url.hostname)) return

  if (url.origin !== window.location.origin) {
    // A source, a venue, a Drive file: read it in a sheet over the journal,
    // and come straight back.
    e.preventDefault()
    openInSheet(url.href).catch(() => (window.location.href = url.href))
  } else if (PDF_PATH.test(url.pathname)) {
    e.preventDefault()
    openPdf(url).catch(() => (window.location.href = a.href))
  } else if (a.target === "_blank") {
    // The book: same site, so it opens here, signed in. The edge swipe and
    // the book's own Journal link lead back.
    e.preventDefault()
    window.location.assign(url.href)
  }
}

// -- appearance ---------------------------------------------------------------
//
// The status bar's clock and battery are drawn light or dark to suit the
// system's appearance, not the page's. A reader who picks the dark theme on a
// light phone would get dark glyphs on a dark page, so the app's window is
// told which way the page went ("system" hands the choice back).

function syncAppearance() {
  const root = document.documentElement
  const style = root.getAttribute("data-theme-source") === "system" ? "system" : root.getAttribute("data-theme")
  call("PoetNative", "setAppearance", {style: style || "system"}).catch(() => {})
}

export function initNative() {
  if (!isNative()) return

  document.addEventListener("click", onClick)

  syncAppearance()
  new MutationObserver(syncAppearance).observe(document.documentElement, {
    attributes: true,
    attributeFilter: ["data-theme", "data-theme-source"],
  })
}
