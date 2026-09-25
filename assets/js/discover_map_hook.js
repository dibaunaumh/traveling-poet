// Discover: every poet, page and place, two ways. The WORLD view is a map of
// where they are; the VILLAGE view (village.js) is the same places by
// subject. One tour turns through them in either view.
//
// Asks the LiveView for its data once connected: pushEvent("load") replies
// with Discover.client_payload/1:
//   {poets: [{slug,name,lat,lng}], entries: [{id,lat,lng,title}],
//    places: [{id,lat,lng,name,group}], rotation: [entry_id], anonymous: [{lat,lng}],
//    me: {lat,lng,name,poet} | null}
// and pushEvent("load_village") replies with Discover.village/0, asked for
// only when the village is opened or a subject filters the map. Neither
// rides in a page attribute (escaped, and sent twice).
// `me` is the reader's own poet before it sets out (the waiting journal): a
// red dot with its name, and where the map looks while nothing else is.
// data-panel names the overview beside the stage (its [data-discover-prev]
// and [data-discover-next] buttons turn the tour), data-layers the row of
// [data-layer] toggles, data-views the World | Village switch. data-url
// (the full /discover page only) keeps ?view= and ?topic= in the address
// bar, so a subject can be shared.
//
// The LiveView renders the overview. This hook only says what is shown:
// pushEvent("select", {kind, id, from: "map"}). It listens for
// "discover:update" (a poet published; same shape as data-discover),
// "discover:focus" ({kind, id}: a link in the overview picked something) and
// "discover:village" ({topic}: open the village at a subject).
//
// The tour. World view: the newest pages; if the village left a subject in
// focus, that subject's places instead, and the map shows only them. Village
// view: the places under the subject in focus, one per child subject per
// round, newest first; it outlines where the place sits and never zooms on
// its own. Any sign of a reader holds it for a while, never for good. Under
// prefers-reduced-motion the map jumps instead of flying and pages turn slower.

import L, { touchFriendly } from "./leaflet_setup"
import { Village } from "./village"

// A village item key ("p12", "f7") as the overview's select event.
const villageSelect = (key) => ({
  kind: key[0] === "f" ? "find" : "place",
  id: Number(key.slice(1)),
  from: "map",
})

const STEP_MS = 9000
const REDUCED_STEP_MS = 15_000
const FIRST_STEP_MS = 2500
const HOLD_INTERACT_MS = 25_000
const FLY_S = 1.4
const PAGE_ZOOM = 6
const POET_ZOOM = 5
const PLACE_ZOOM = 9

const TEAL = "#2f5d62"
const RED = "#c0392b"
const GREY = "#9ca3af"
// Keep in step with .discover-swatch-* in app.css.
const PLACE_COLOURS = { food: "#d97706", sights: "#3f7d4f", events: "#7c3aed" }

const DiscoverMap = {
  mounted() {
    // Two boxes in one stage; only one shows at a time.
    this.mapEl = document.createElement("div")
    this.mapEl.className = "discover-world"
    this.villageEl = document.createElement("div")
    this.villageEl.className = "discover-village"
    this.villageEl.hidden = true
    this.el.append(this.mapEl, this.villageEl)

    this.map = L.map(this.mapEl, { scrollWheelZoom: false, worldCopyJump: true })
    L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
      maxZoom: 19,
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
    }).addTo(this.map)
    this.map.setView([25, 10], 2)
    touchFriendly(this.map)

    // The subject filter, shown on the map while the village has one.
    this.filterEl = document.createElement("div")
    this.filterEl.className = "discover-filter"
    this.filterEl.hidden = true
    this.mapEl.append(this.filterEl)

    if (typeof ResizeObserver !== "undefined") {
      this.resizeObserver = new ResizeObserver(() => {
        if (this.map) this.map.invalidateSize()
        if (this.view === "village") this.village.render()
      })
      this.resizeObserver.observe(this.el)
    }

    // Almost a thousand places: drawn on one canvas, not as DOM nodes.
    this.canvas = L.canvas({ padding: 0.5 })
    this.layers = {
      places: L.layerGroup().addTo(this.map),
      entries: L.layerGroup().addTo(this.map),
      poets: L.layerGroup().addTo(this.map),
    }
    this.anonymousLayer = L.layerGroup().addTo(this.map)
    this.ringLayer = L.layerGroup().addTo(this.map)

    this.village = new Village(this.villageEl, {
      // an item key: "p<id>" a place, "f<id>" a find
      onItem: (key) => this.pick(key[0] === "f" ? "vfind" : "vplace", key),
      onFocus: (path, { user }) => {
        this.subject = path
        this.syncUrl()
        if (user) {
          this.hold()
          this.restartTour({ show: false })
        }
      },
    })

    this.panel = this.el.dataset.panel ? document.getElementById(this.el.dataset.panel) : null
    this.layerToggles = this.el.dataset.layers ? document.getElementById(this.el.dataset.layers) : null
    this.viewToggles = this.el.dataset.views ? document.getElementById(this.el.dataset.views) : null
    this.reduced = !!(window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches)
    this.timers = []
    this.index = 0
    this.view = "world"
    this.subject = ""
    this.subjectIds = new Set()
    this.villageLoaded = false

    this.bindInteraction()
    this.load({})
    this.map.on("zoomend", () => this.sizePlaces())
    this.handleEvent("discover:update", (data) => {
      this.load(data)
      // The village list is stale too; fetch it again only if it is in use.
      this.villageLoaded = false
      if (this.view === "village" || this.subject) this.ensureVillage(() => this.refresh())
    })
    this.handleEvent("discover:focus", ({ kind, id }) => this.focus(kind, id))
    this.handleEvent("discover:village", ({ topic }) => {
      this.hold()
      this.setView("village", { subject: topic || "" })
    })

    this.pushEvent("load", {}, (data) => {
      this.load(data)
      this.start()
    })
  },

  start() {
    // A shared link can open the village, or the map filtered, at a subject.
    const params = this.el.dataset.url ? new URLSearchParams(window.location.search) : null
    if (params && (params.get("view") === "village" || params.get("topic"))) {
      const view = params.get("view") === "village" ? "village" : "world"
      this.setView(view, { subject: params.get("topic") || "", first: true })
      return
    }

    // The server already shows the first page; the tour starts from it.
    this.queue = this.tourQueue()
    if (this.queue.length === 0 && this.data.me) {
      this.map.setView([this.data.me.lat, this.data.me.lng], PAGE_ZOOM, { animate: false })
    } else if (this.queue.length > 0) {
      this.show(this.queue[0], { push: false })
      this.later(() => this.next(), FIRST_STEP_MS + this.stepMs())
    }
  },

  destroyed() {
    this.stop()
    clearTimeout(this.holdTimer)
    if (this.onVisibility) document.removeEventListener("visibilitychange", this.onVisibility)
    if (this.resizeObserver) this.resizeObserver.disconnect()
    if (this.map) this.map.remove()
  },

  load(data) {
    const current = this.queue && this.queue[this.index]
    this.data = data || {}
    this.entries = new Map((this.data.entries || []).map((e) => [String(e.id), e]))
    this.places = new Map((this.data.places || []).map((p) => [String(p.id), p]))
    this.poets = new Map((this.data.poets || []).map((p) => [p.slug, p]))
    this.render()
    this.queue = this.tourQueue()
    const keep = current ? this.queue.findIndex((q) => q.kind === current.kind && q.id === current.id) : -1
    this.index = keep >= 0 ? keep : 0
  },

  render() {
    Object.values(this.layers).forEach((l) => l.clearLayers())
    this.anonymousLayer.clearLayers()
    this.placeMarkers = []
    const filtering = this.view === "world" && this.subject !== ""

    if (this.data.me) {
      const me = this.data.me
      L.circleMarker([me.lat, me.lng], {
        radius: 9,
        color: RED,
        fillColor: RED,
        fillOpacity: 0.85,
        weight: 3,
        interactive: false,
      })
        .bindTooltip(`${me.poet} starts here`, { permanent: true, direction: "right", offset: [10, 0] })
        .addTo(this.anonymousLayer)
    }

    ;(this.data.anonymous || []).forEach((p) => {
      L.circleMarker([p.lat, p.lng], {
        radius: 6,
        color: GREY,
        fillColor: GREY,
        fillOpacity: 0.45,
        weight: 2,
        interactive: false,
      }).addTo(this.anonymousLayer)
    })

    this.places.forEach((p) => {
      if (filtering && !this.placeInSubject(p)) return
      const colour = PLACE_COLOURS[p.group] || PLACE_COLOURS.sights
      const m = L.circleMarker([p.lat, p.lng], {
        renderer: this.canvas,
        radius: filtering ? 6 : this.placeRadius(),
        color: "#fff",
        weight: 1,
        fillColor: colour,
        fillOpacity: 0.9,
      })
      m.bindTooltip(p.name, { direction: "top" })
      m.on("click", () => this.pick("place", p.id))
      m.addTo(this.layers.places)
      if (!filtering) this.placeMarkers.push(m)
    })

    // Filtered to a subject, the map is about its places alone.
    if (!filtering) {
      this.entries.forEach((e) => {
        L.circleMarker([e.lat, e.lng], {
          radius: 6,
          color: "#fff",
          weight: 2,
          fillColor: TEAL,
          fillOpacity: 0.95,
        })
          .bindTooltip(e.title || e.place || "", { direction: "top" })
          .on("click", () => this.pick("entry", e.id))
          .addTo(this.layers.entries)
      })

      this.poets.forEach((p) => {
        if (typeof p.lat !== "number") return
        L.marker([p.lat, p.lng], { title: p.name })
          .bindTooltip(p.name, { direction: "top", offset: [-14, -10] })
          .on("click", () => this.pick("poet", p.slug))
          .addTo(this.layers.poets)
      })
    }

    this.filterEl.hidden = !filtering
    if (filtering) {
      const n = this.layers.places.getLayers().length
      this.filterEl.innerHTML = ""
      const label = document.createElement("span")
      label.textContent = `${this.village.name(this.subject)}: ${n} on the map`
      const clear = document.createElement("button")
      clear.type = "button"
      clear.textContent = "Show everything"
      clear.dataset.discoverClear = ""
      this.filterEl.append(label, clear)
    }
  },

  placeInSubject(p) {
    return this.subjectIds.has(p.id)
  },

  // The village list, fetched the first time it is needed, then `fn`.
  ensureVillage(fn) {
    if (this.villageLoaded) return fn()
    this.pushEvent("load_village", {}, (village) => {
      this.villageLoaded = true
      this.village.load(village)
      fn()
    })
  },

  // Redraw whatever is showing after the data under it changed.
  refresh() {
    if (this.view === "village") this.village.setFocus(this.subject)
    this.subjectIds = this.idsUnder(this.subject)
    this.render()
    this.queue = this.tourQueue()
  },

  // Every place row (world map ids) under a subject, from the village list.
  idsUnder(subject) {
    if (!subject || !this.villageLoaded) return new Set()
    return new Set(this.village.placesUnder(subject).flatMap((p) => p.ids || [p.id]))
  },

  // Small dots across the world, bigger ones once the map is on a region.
  placeRadius() {
    const z = this.map.getZoom()
    return z < 4 ? 2.5 : z < 7 ? 4 : 6
  },

  sizePlaces() {
    const r = this.placeRadius()
    ;(this.placeMarkers || []).forEach((m) => m.setRadius(r))
  },

  // -- views ------------------------------------------------------------

  setView(view, { subject = this.subject, first = false } = {}) {
    view = view === "village" ? "village" : "world"
    // The village, and a map filtered by subject, need the village list.
    if ((view === "village" || subject) && !this.villageLoaded) {
      return this.ensureVillage(() => this.setView(view, { subject, first }))
    }
    this.view = view
    this.mapEl.hidden = this.view !== "world"
    this.villageEl.hidden = this.view !== "village"
    if (this.layerToggles) this.layerToggles.hidden = this.view !== "world"
    if (this.viewToggles) {
      this.viewToggles.querySelectorAll("[data-view]").forEach((b) => {
        b.setAttribute("aria-pressed", String(b.dataset.view === this.view))
      })
    }

    if (this.view === "village") {
      this.village.setFocus(subject)
    } else {
      this.subject = subject
      this.subjectIds = this.idsUnder(subject)
      this.map.invalidateSize()
      this.render()
      const bounds = this.layers.places.getLayers().map((m) => m.getLatLng())
      if (this.subject && bounds.length) this.map.fitBounds(bounds, { padding: [30, 30], maxZoom: 6 })
    }
    this.syncUrl()
    // On a filtered map, let the reader see where the subject's places are
    // before the tour flies to the first of them.
    const settle = this.view === "world" && this.subject ? FIRST_STEP_MS : 0
    this.restartTour({ show: true, delay: first ? FIRST_STEP_MS : settle })
  },

  syncUrl() {
    if (!this.el.dataset.url) return
    const params = new URLSearchParams(window.location.search)
    if (this.view === "village") params.set("view", "village")
    else params.delete("view")
    if (this.subject) params.set("topic", this.subject)
    else params.delete("topic")
    const q = params.toString()
    window.history.replaceState(window.history.state, "", window.location.pathname + (q ? `?${q}` : ""))
  },

  // -- the tour ---------------------------------------------------------

  // What the tour turns through, as [{kind, id}], for the view and subject.
  tourQueue() {
    if (this.view === "village") {
      return this.village
        .rotation(this.subject)
        .map((key) => ({ kind: key[0] === "f" ? "vfind" : "vplace", id: key }))
    }
    if (this.subject) {
      // A village place stands for every row merged into it; the map shows
      // whichever of them it has.
      // The world map has places only; the village's finds stay in the village.
      const byId = new Map(this.village.places.map((p) => [p.id, p]))
      return this.village
        .rotation(this.subject)
        .filter((key) => key[0] === "p")
        .map((key) => Number(key.slice(1)))
        .map((vid) => ((byId.get(vid) || {}).ids || [vid]).find((id) => this.places.has(String(id))))
        .filter((id) => id != null)
        .map((id) => ({ kind: "place", id }))
    }
    return (this.data.rotation || []).map((id) => ({ kind: "entry", id }))
  },

  restartTour({ show = true, delay = 0 } = {}) {
    this.stop()
    this.queue = this.tourQueue()
    this.index = 0
    if (this.queue.length === 0) return
    if (show) this.later(() => this.show(this.queue[0]), delay)
    this.later(() => this.next(), delay + this.stepMs())
  },

  show(item, { push = true } = {}) {
    if (!item) return
    if (item.kind === "entry") {
      const e = this.point("entry", item.id)
      if (!e) return
      this.ring(e)
      this.flyTo(e, PAGE_ZOOM)
    } else if (item.kind === "place") {
      const p = this.point("place", item.id)
      if (!p) return
      this.ring(p, PLACE_COLOURS[p.group] || RED)
      this.flyTo(p, PLACE_ZOOM)
    } else if (item.kind === "vplace" || item.kind === "vfind") {
      this.village.highlight(item.id)
      if (push) this.pushEvent("select", villageSelect(item.id))
      return
    }
    if (push) this.pushEvent("select", { kind: item.kind, id: item.id, from: "map" })
  },

  stepMs() {
    return this.reduced ? REDUCED_STEP_MS : STEP_MS
  },

  step(delta) {
    if (!this.queue || this.queue.length === 0) return
    this.stop()
    this.index = (this.index + delta + this.queue.length) % this.queue.length
    this.show(this.queue[this.index])
    this.later(() => this.next(), this.stepMs())
  },

  next() {
    if (this.paused) return
    this.step(1)
  },

  // Turning by hand shows the item now but does not restart the clock; the
  // hold decides when the tour goes on.
  stepByHand(delta) {
    if (!this.queue || this.queue.length === 0) return
    this.index = (this.index + delta + this.queue.length) % this.queue.length
    this.show(this.queue[this.index])
  },

  // -- showing one thing ------------------------------------------------

  point(kind, id) {
    if (kind === "entry") return this.entries.get(String(id))
    if (kind === "place") return this.places.get(String(id))
    if (kind === "poet") return this.poets.get(String(id))
    return null
  },

  ring(item, colour = RED) {
    this.ringLayer.clearLayers()
    if (!item) return
    L.circleMarker([item.lat, item.lng], {
      radius: 13,
      color: colour,
      weight: 3,
      fill: false,
      interactive: false,
    }).addTo(this.ringLayer)
  },

  flyTo(item, zoom) {
    if (!item) return
    const target = [item.lat, item.lng]
    const z = Math.max(this.map.getZoom(), zoom)
    this.flying = true
    const done = () => {
      this.flying = false
    }
    if (this.reduced) {
      this.map.setView(target, z, { animate: false })
      done()
    } else {
      this.map.once("moveend", done)
      this.map.flyTo(target, z, { duration: FLY_S })
    }
  },

  // A reader's click: show it, keep it a while.
  pick(kind, id) {
    this.hold()
    const i = this.queue ? this.queue.findIndex((q) => q.kind === kind && String(q.id) === String(id)) : -1
    if (i >= 0) this.index = i

    if (kind === "vplace" || kind === "vfind") {
      this.village.highlight(id)
      this.pushEvent("select", villageSelect(id))
      return
    }
    const item = this.point(kind, id)
    if (!item) return
    this.ring(item, kind === "place" ? PLACE_COLOURS[item.group] || RED : RED)
    if (kind === "poet") this.flyTo(item, POET_ZOOM)
    this.pushEvent("select", { kind, id: kind === "poet" ? item.slug : item.id, from: "map" })
  },

  // The overview picked something (a poet's name under a page).
  focus(kind, id) {
    this.hold()
    if (this.view !== "world") this.setView("world", { subject: "" })
    const item = this.point(kind, id)
    if (!item) return
    this.ring(item)
    this.flyTo(item, kind === "poet" ? POET_ZOOM : PAGE_ZOOM)
  },

  // -- interaction ------------------------------------------------------

  bindInteraction() {
    const hold = () => this.hold()
    const release = () => this.release()

    for (const el of [this.el, this.panel].filter(Boolean)) {
      el.addEventListener("mouseenter", hold)
      el.addEventListener("mousemove", hold)
      el.addEventListener("mouseleave", release)
      el.addEventListener("pointerdown", hold)
    }
    this.map.on("dragstart", hold)
    this.map.on("zoomstart", () => {
      if (!this.flying) this.hold()
    })

    this.filterEl.addEventListener("click", (e) => {
      if (e.target.closest("[data-discover-clear]")) {
        this.hold()
        this.setView("world", { subject: "" })
      }
    })

    if (this.panel) {
      this.panel.addEventListener("click", (e) => {
        if (e.target.closest("[data-discover-prev]")) {
          this.hold()
          this.stepByHand(-1)
        } else if (e.target.closest("[data-discover-next]")) {
          this.hold()
          this.stepByHand(1)
        }
      })
    }

    if (this.viewToggles) {
      this.viewToggles.addEventListener("click", (e) => {
        const btn = e.target.closest("[data-view]")
        if (!btn || btn.dataset.view === this.view) return
        this.hold()
        this.setView(btn.dataset.view)
      })
    }

    if (this.layerToggles) {
      this.layerToggles.addEventListener("click", (e) => {
        const btn = e.target.closest("[data-layer]")
        if (!btn) return
        const layer = this.layers[btn.dataset.layer]
        if (!layer) return
        const on = btn.getAttribute("aria-pressed") !== "true"
        btn.setAttribute("aria-pressed", String(on))
        if (on) layer.addTo(this.map)
        else layer.remove()
      })
    }

    // A hidden tab gets no animation frames; hold the tour until it is back.
    this.onVisibility = () => {
      if (document.hidden) {
        this.stop()
        this.paused = true
      } else {
        clearTimeout(this.holdTimer)
        this.paused = false
        this.later(() => this.next(), this.stepMs())
      }
    }
    document.addEventListener("visibilitychange", this.onVisibility)
  },

  hold() {
    this.paused = true
    clearTimeout(this.holdTimer)
    this.holdTimer = setTimeout(() => this.release(), HOLD_INTERACT_MS)
  },

  release() {
    clearTimeout(this.holdTimer)
    this.holdTimer = null
    if (document.hidden) return
    this.paused = false
    if (this.timers.length === 0 && this.queue && this.queue.length > 0) {
      this.later(() => this.next(), 1500)
    }
  },

  later(fn, ms) {
    const id = setTimeout(() => {
      this.timers = this.timers.filter((t) => t !== id)
      fn()
    }, ms)
    this.timers.push(id)
  },

  stop() {
    this.timers.forEach((id) => clearTimeout(id))
    this.timers = []
  },
}

export default DiscoverMap
