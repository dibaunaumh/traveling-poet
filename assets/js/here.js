// Away from home (card-78): where the reader is, from their own device.
//
// Runs only for a reader who switched "Notice when I am away" on in Settings
// (the root layout marks <html data-here="on">), and only while a page is
// open: there is no background location. At most once an hour per device,
// the page asks for a coarse position and posts it to /here; the server
// decides whether the reader is away and whether the poet should look around
// them (TravelingPoet.NearHome.Away).
//
// In the iOS app the position comes from the app (PoetNative.locate, coarse,
// "While Using"); an app build from before that answers UNIMPLEMENTED and
// the reader is asked to update.

import {isNative, call} from "./native"
import {t} from "./strings"

const KEY = "tp-here-at"
const EVERY_MS = 60 * 60 * 1000

let inFlight = false

const on = () => document.documentElement.dataset.here === "on"

function lastAt() {
  try {
    return Number(localStorage.getItem(KEY)) || 0
  } catch (_e) {
    return 0
  }
}

function remember(at) {
  try {
    if (at) localStorage.setItem(KEY, String(at))
    else localStorage.removeItem(KEY)
  } catch (_e) {
    // private window or blocked storage: report on every page, no harm
  }
}

function locateInApp() {
  return call("PoetNative", "locate", {}).then(
    ({lat, lng}) => ({lat, lng}),
    (err) => {
      const unimplemented = err?.code === "UNIMPLEMENTED" || /not implemented/i.test(err?.message || "")
      throw {reason: err?.code === "denied" ? "denied" : unimplemented ? "update" : "failed"}
    },
  )
}

function locateInBrowser() {
  return new Promise((resolve, reject) => {
    if (!navigator.geolocation) return reject({reason: "unsupported"})

    navigator.geolocation.getCurrentPosition(
      (pos) => resolve({lat: pos.coords.latitude, lng: pos.coords.longitude}),
      (err) => reject({reason: err.code === 1 ? "denied" : "failed"}),
      // a town is all it needs: no GPS, a recent fix is fine
      {enableHighAccuracy: false, maximumAge: 30 * 60 * 1000, timeout: 20000},
    )
  })
}

const locate = () => (isNative() ? locateInApp() : locateInBrowser())

// Settings has a line for the outcome; other pages say nothing.
function show(status) {
  const el = document.getElementById("away-status")
  if (!el) return

  let text
  if (status.error === "denied") {
    text = t("here_denied", "Location is blocked. Allow it for this site in your browser or phone settings.")
  } else if (status.error === "update") {
    text = t("here_update", "Update the app to use this.")
  } else if (status.error) {
    text = t("here_failed", "Could not tell where you are just now. It tries again next time.")
  } else if (status.away && status.looking) {
    text = t("here_away_looking", "You are in {place}. Your poet is looking for things to do around you.", {
      place: status.place,
    })
  } else if (status.away) {
    text = t("here_away", "You are in {place}. Near you looks around you there.", {place: status.place})
  } else {
    text = t("here_home", "You are near home.")
  }

  el.textContent = text
  el.hidden = false
}

async function report(force) {
  if (inFlight || !on()) return
  if (!force && Date.now() - lastAt() < EVERY_MS) return
  inFlight = true

  try {
    const {lat, lng} = await locate()
    const body = new FormData()
    body.append("lat", lat)
    body.append("lng", lng)
    const csrf = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
    // No accept header: /here is in the :browser pipeline (see native.js).
    const res = await fetch("/here", {
      method: "POST",
      body,
      headers: {"x-csrf-token": csrf},
      credentials: "same-origin",
    })
    if (res.ok) {
      remember(Date.now())
      show(await res.json())
    }
  } catch (err) {
    show({error: err?.reason || "failed"})
  } finally {
    inFlight = false
  }
}

export function initHere() {
  // Settings switched it on (the permission prompt follows) or off.
  window.addEventListener("phx:here:now", () => {
    document.documentElement.dataset.here = "on"
    report(true)
  })
  window.addEventListener("phx:here:off", () => {
    delete document.documentElement.dataset.here
    remember(0)
  })

  report(false)
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") report(false)
  })
}
