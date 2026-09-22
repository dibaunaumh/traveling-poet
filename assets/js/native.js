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

// A note on fetch(): these requests go to routes in the router's :browser
// pipeline, which only `accepts` html. An `accept: application/json` header
// would be answered 406 before the controller ever ran, so none is sent; the
// default (*/*) is accepted, and the controllers answer JSON regardless.

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
  const response = await fetch(url, {credentials: "same-origin"})
  if (!response.ok) throw new Error(`pdf link ${response.status}`)
  const {url: signed} = await response.json()
  return openInSheet(signed)
}

// -- Google, through the system sign-in sheet -------------------------------
//
// Google refuses to run its sign-in in an embedded web view, which is what
// this is. PoetNative.webAuth opens a URL in the system's sign-in sheet
// (Safari's engine and cookie jar, which Google allows) and resolves with
// the travelpoet:// URL the server finally redirects the sheet to. The
// sheet's session is not this one, so the result is carried across: see
// TravelingPoetWeb.NativeAuth for the whole handoff.

const AUTH_SCHEME = "travelpoet"

// Links that would lead the web view into Google, by path.
const SIGN_IN_PATH = "/auth/google"
const CONNECT_PATHS = {
  "/settings/calendar/connect": "calendar",
  "/journal/book/drive/connect": "drive",
}

const base64url = (bytes) =>
  btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")

const webAuth = (url) => call("PoetNative", "webAuth", {url, scheme: AUTH_SCHEME}).then((r) => new URL(r.url))

function post(path, fields) {
  const form = document.createElement("form")
  form.method = "post"
  form.action = path
  fields._csrf_token = document.querySelector("meta[name='csrf-token']").getAttribute("content")
  for (const [name, value] of Object.entries(fields)) {
    const input = document.createElement("input")
    input.type = "hidden"
    input.name = name
    input.value = value
    form.appendChild(input)
  }
  document.body.appendChild(form)
  form.submit()
}

let authInFlight = false

async function once(flow) {
  if (authInFlight) return
  authInFlight = true
  try {
    await flow()
  } catch (err) {
    // Closing the sheet is a decision, not an error worth a message.
    if (err?.code !== "cancelled") console.warn("[native] sign-in sheet", err)
  } finally {
    authInFlight = false
  }
}

async function signInWithGoogle() {
  // The verifier never leaves this page; the sheet only ever sees its hash.
  // The token that comes back is useless without it.
  const verifier = base64url(crypto.getRandomValues(new Uint8Array(32)))
  const challenge = base64url(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)))
  const start = new URL("/auth/native/start", window.location.origin)
  start.searchParams.set("challenge", challenge)

  const result = await webAuth(start.href)
  const token = result.searchParams.get("token")
  if (token) post("/auth/native/handoff", {token, verifier})
  else window.location.assign("/")
}

// Sign in with Apple is a native sheet, not a web flow, so there is no second
// cookie jar and no handoff: the token comes back over the bridge and is
// posted from here, which signs THIS session in. The nonce on the button
// belongs to this session (the server keeps the original and gave the page
// its hash); Apple copies it into the token, so the token works once, here.
async function signInWithApple(button) {
  const result = await call("PoetNative", "signInWithApple", {nonce: button.dataset.appleNonce})
  post("/auth/apple/native", {
    identity_token: result.identityToken,
    authorization_code: result.authorizationCode || "",
    given_name: result.givenName || "",
    family_name: result.familyName || "",
  })
}

async function connectGoogle(feature, link) {
  const ask = new URL("/auth/native/connect_url", window.location.origin)
  ask.searchParams.set("feature", feature)
  const pdf = link.searchParams.get("pdf")
  if (pdf) ask.searchParams.set("pdf", pdf)

  const response = await fetch(ask, {credentials: "same-origin"})
  if (!response.ok) throw new Error(`connect_url ${response.status}`)
  const {url} = await response.json()

  const result = await webAuth(url)
  // Only ever a page of this site, whatever the URL that came back says.
  const next = new URL(result.searchParams.get("to") || "/settings", window.location.origin)
  if (next.origin !== window.location.origin) return
  const connected = result.searchParams.get("connected")
  if (connected) next.searchParams.set("connected", connected)
  // A full load, not a patch: the page has to re-read what Google granted.
  window.location.assign(next.href)
}

function onClick(e) {
  if (e.defaultPrevented || e.button !== 0) return

  const apple = e.target.closest("#sign-in-with-apple")
  if (apple) {
    e.preventDefault()
    return once(() => signInWithApple(apple))
  }

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

  if (url.origin === window.location.origin && url.pathname === SIGN_IN_PATH) {
    e.preventDefault()
    // The welcome screen's own button signs in with Google. A "Sign in" link
    // anywhere else (a public journal's header) leads to the welcome screen,
    // where both ways in are offered.
    if (a.closest("#welcome-signin")) once(signInWithGoogle)
    else window.location.assign("/")
  } else if (url.origin === window.location.origin && CONNECT_PATHS[url.pathname]) {
    e.preventDefault()
    once(() => connectGoogle(CONNECT_PATHS[url.pathname], url))
  } else if (url.origin !== window.location.origin) {
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

  // A LiveView that would have redirected into Google's consent screen
  // (Settings, saving a PDF to a Drive not yet connected) asks for the sheet
  // instead.
  window.addEventListener("phx:native:connect", ({detail}) => {
    const link = new URL("/", window.location.origin)
    if (detail.pdf) link.searchParams.set("pdf", detail.pdf)
    once(() => connectGoogle(detail.feature, link))
  })

  syncAppearance()
  new MutationObserver(syncAppearance).observe(document.documentElement, {
    attributes: true,
    attributeFilter: ["data-theme", "data-theme-source"],
  })
}
