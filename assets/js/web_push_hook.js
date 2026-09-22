// Bridges the browser's Push API to a LiveView.
//
// The server can't know whether this device supports push, has permission,
// or is already subscribed, so on mount the hook works that out and reports a
// single `push_state` event. Clicks on [data-push-action] buttons inside the
// hook element are handled *here*, not round-tripped through the server:
// Safari only honours Notification.requestPermission() inside a user gesture,
// and a websocket hop would lose that.
//
// Events to the server:
//   push_state        {state, dismissed, subscription?}  on mount / changes
//   push_subscribed   {subscription}                      after a successful subscribe
//   push_unsubscribed {endpoint}                          after unsubscribe
//
// States: unsupported | needs_install (iOS browser tab; push needs the
// home-screen app) | denied | available | subscribed
//
// Inside the iOS app there is no Web Push (it is a web view), so the same
// states and the same three events run over Apple's push service instead:
// the hook asks the Capacitor push plugin for permission and a device token,
// and reports `device: {token, environment}` where a browser reports a
// `subscription`. See nativePush below.

import {isNative, call, listen, rememberDeviceToken} from "./native"

const DISMISS_KEY = "tpoet.push.dismissed"

const WebPush = {
  mounted() {
    this.state = "unsupported"
    this.onClick = e => {
      const btn = e.target.closest("[data-push-action]")
      if (!btn || !this.el.contains(btn)) return
      e.preventDefault()
      const action = btn.dataset.pushAction
      if (action === "subscribe") this.subscribe()
      else if (action === "unsubscribe") this.unsubscribe()
      else if (action === "dismiss") this.dismiss()
    }
    this.el.addEventListener("click", this.onClick)
    this.detect()
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick)
  },

  supported() {
    return "serviceWorker" in navigator && "PushManager" in window && "Notification" in window
  },

  isIOS() {
    return /iphone|ipad|ipod/i.test(navigator.userAgent) ||
      (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1)
  },

  standalone() {
    return window.matchMedia("(display-mode: standalone)").matches || navigator.standalone === true
  },

  dismissed() {
    try { return localStorage.getItem(DISMISS_KEY) === "1" } catch (_e) { return false }
  },

  report(state, extra = {}) {
    this.state = state
    this.pushEvent("push_state", {state, dismissed: this.dismissed(), ...extra})
  },

  async registration() {
    if (!this.reg) this.reg = await navigator.serviceWorker.register("/sw.js")
    return this.reg
  },

  async detect() {
    if (isNative()) return this.detectNative()

    if (!this.supported()) {
      return this.report(this.isIOS() && !this.standalone() ? "needs_install" : "unsupported")
    }
    if (Notification.permission === "denied") return this.report("denied")
    try {
      const reg = await this.registration()
      const sub = await reg.pushManager.getSubscription()
      if (sub) {
        // Re-report so the server can heal a lost or rotated row.
        return this.report("subscribed", {subscription: sub.toJSON()})
      }
      this.report("available")
    } catch (err) {
      console.warn("[web-push] detect failed", err)
      this.report("unsupported")
    }
  },

  // -- the iOS app ---------------------------------------------------------

  async detectNative() {
    try {
      const {receive} = await call("PushNotifications", "checkPermissions")
      if (receive === "denied") return this.report("denied")
      if (receive !== "granted") return this.report("available")
      // Permission was given earlier: tokens change (a restore, a reinstall),
      // so fetch today's and let the server heal its row.
      this.report("subscribed", {device: await nativeDevice()})
    } catch (err) {
      console.warn("[push] native detect failed", err)
      this.report("unsupported")
    }
  },

  async subscribeNative() {
    try {
      const {receive} = await call("PushNotifications", "requestPermissions")
      if (receive !== "granted") return this.report(receive === "denied" ? "denied" : "available")
      const device = await nativeDevice()
      this.state = "subscribed"
      this.pushEvent("push_subscribed", {device})
    } catch (err) {
      console.warn("[push] native subscribe failed", err)
      this.report("available", {error: String(err && err.message || err)})
    }
  },

  async unsubscribeNative() {
    const token = rememberDeviceToken()
    try { await call("PushNotifications", "unregister") } catch (_e) {}
    rememberDeviceToken(null)
    this.state = "available"
    this.pushEvent("push_unsubscribed", {device_token: token})
  },

  // -- browsers ---------------------------------------------------------------

  async subscribe() {
    if (isNative()) return this.subscribeNative()
    if (!this.supported()) return
    try {
      const permission = await Notification.requestPermission()
      if (permission !== "granted") return this.report(permission === "denied" ? "denied" : "available")
      const reg = await this.registration()
      const sub = await reg.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: urlBase64ToUint8Array(this.el.dataset.vapidKey),
      })
      this.state = "subscribed"
      this.pushEvent("push_subscribed", {subscription: sub.toJSON()})
    } catch (err) {
      console.warn("[web-push] subscribe failed", err)
      this.report("available", {error: String(err && err.message || err)})
    }
  },

  async unsubscribe() {
    if (isNative()) return this.unsubscribeNative()
    try {
      const reg = await this.registration()
      const sub = await reg.pushManager.getSubscription()
      const endpoint = sub ? sub.endpoint : null
      if (sub) await sub.unsubscribe()
      this.state = "available"
      this.pushEvent("push_unsubscribed", {endpoint})
    } catch (err) {
      console.warn("[web-push] unsubscribe failed", err)
    }
  },

  dismiss() {
    try { localStorage.setItem(DISMISS_KEY, "1") } catch (_e) {}
    this.report(this.state)
  },
}

// Asks iOS for this install's APNs token. `register` answers through an
// event, not its promise, and answers nothing at all on a Simulator without
// the push entitlement, hence the timeout.
function nativeDevice() {
  return new Promise((resolve, reject) => {
    const handles = []
    const done = (finish, value) => {
      handles.forEach((h) => h.remove())
      clearTimeout(timer)
      finish(value)
    }
    const timer = setTimeout(() => done(reject, new Error("no device token")), 15000)

    handles.push(
      listen("PushNotifications", "registration", async ({value}) => {
        const info = await call("PoetNative", "info").catch(() => ({}))
        rememberDeviceToken(value)
        done(resolve, {token: value, environment: info.apnsEnvironment || "production"})
      }),
      listen("PushNotifications", "registrationError", (err) => done(reject, new Error(err?.error || "registration failed")))
    )
    call("PushNotifications", "register").catch((err) => done(reject, err))
  })
}

function urlBase64ToUint8Array(base64) {
  const padding = "=".repeat((4 - (base64.length % 4)) % 4)
  const raw = atob((base64 + padding).replace(/-/g, "+").replace(/_/g, "/"))
  return Uint8Array.from(raw, c => c.charCodeAt(0))
}

export default WebPush
