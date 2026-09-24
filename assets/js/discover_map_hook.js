// Discover: every poet, every page and every place on one map, and a tour
// that turns through the newest pages.
//
// Reads data-discover (JSON, the shape of Discover.build/0):
//   {poets: [{slug,name,avatar,lat,lng,place}], entries: [{id,poet,lat,lng,place,date,title}],
//    places: [{id,poet,lat,lng,name,group}], rotation: [entry_id], anonymous: [{lat,lng}],
//    me: {lat,lng,name,poet} | null}
// `me` is the reader's own poet before it sets out (the waiting journal): a
// red ring with its name, and where the map looks while nothing else is.
// data-panel names the overview beside the map (its [data-discover-prev] and
// [data-discover-next] buttons turn the tour), data-layers the row of
// [data-layer] toggles.
//
// The LiveView renders the overview. This hook only says what is shown:
// pushEvent("select", {kind, id, from: "map"}). It listens for
// "discover:update" (a poet published; same shape as data-discover) and
// "discover:focus" ({kind, id}: a link in the overview picked something, fly
// to it).
//
// The tour: fly to a page, ring it, show its overview, hold, move on; loop.
// Any sign of a reader (pointer over the map or the overview, a click, a
// drag, a zoom) holds it for a while, never for good. Under
// prefers-reduced-motion the map jumps instead of flying and pages turn
// slower.

import L, { touchFriendly } from "./leaflet_setup"

const STEP_MS = 9000
const REDUCED_STEP_MS = 15_000
const FIRST_STEP_MS = 2500
const HOLD_INTERACT_MS = 25_000
const FLY_S = 1.4
const PAGE_ZOOM = 6
const POET_ZOOM = 5

const TEAL = "#2f5d62"
const RED = "#c0392b"
const GREY = "#9ca3af"
// Keep in step with .discover-swatch-* in app.css.
const PLACE_COLOURS = { food: "#d97706", sights: "#3f7d4f", events: "#7c3aed" }

const DiscoverMap = {
  mounted() {
    this.map = L.map(this.el, { scrollWheelZoom: false, worldCopyJump: true })
    L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
      maxZoom: 19,
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
    }).addTo(this.map)
    this.map.setView([25, 10], 2)
    touchFriendly(this.map)

    if (typeof ResizeObserver !== "undefined") {
      this.resizeObserver = new ResizeObserver(() => this.map && this.map.invalidateSize())
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

    this.panel = this.el.dataset.panel ? document.getElementById(this.el.dataset.panel) : null
    this.layerToggles = this.el.dataset.layers ? document.getElementById(this.el.dataset.layers) : null
    this.reduced = !!(window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches)
    this.timers = []
    this.index = 0

    this.bindInteraction()
    this.load(JSON.parse(this.el.dataset.discover || "{}"))
    this.map.on("zoomend", () => this.sizePlaces())
    this.handleEvent("discover:update", (data) => this.load(data))
    this.handleEvent("discover:focus", ({ kind, id }) => this.focus(kind, id))

    // The server already shows the first page; the tour starts from it.
    if (this.rotation.length === 0 && this.data.me) {
      this.map.setView([this.data.me.lat, this.data.me.lng], PAGE_ZOOM, { animate: false })
    } else if (this.rotation.length > 0) {
      this.showEntry(this.rotation[0], { push: false })
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
    const current = this.rotation && this.rotation[this.index]
    this.data = data || {}
    this.rotation = this.data.rotation || []
    this.entries = new Map((this.data.entries || []).map((e) => [String(e.id), e]))
    this.places = new Map((this.data.places || []).map((p) => [String(p.id), p]))
    this.poets = new Map((this.data.poets || []).map((p) => [p.slug, p]))
    const keep = current == null ? -1 : this.rotation.indexOf(current)
    this.index = keep >= 0 ? keep : 0
    this.render()
  },

  render() {
    Object.values(this.layers).forEach((l) => l.clearLayers())
    this.anonymousLayer.clearLayers()
    this.placeMarkers = []

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
      const colour = PLACE_COLOURS[p.group] || PLACE_COLOURS.sights
      const m = L.circleMarker([p.lat, p.lng], {
        renderer: this.canvas,
        radius: this.placeRadius(),
        color: "#fff",
        weight: 1,
        fillColor: colour,
        fillOpacity: 0.9,
      })
      m.bindTooltip(p.name, { direction: "top" })
      m.on("click", () => this.pick("place", p.id))
      m.addTo(this.layers.places)
      this.placeMarkers.push(m)
    })

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

  showEntry(id, { push = true } = {}) {
    const e = this.point("entry", id)
    if (!e) return
    this.ring(e)
    this.flyTo(e, PAGE_ZOOM)
    if (push) this.pushEvent("select", { kind: "entry", id: e.id, from: "map" })
  },

  // A reader's click: show it, keep it a while.
  pick(kind, id) {
    this.hold()
    const item = this.point(kind, id)
    if (!item) return
    if (kind === "entry") {
      const i = this.rotation.indexOf(item.id)
      if (i >= 0) this.index = i
    }
    this.ring(item, kind === "place" ? PLACE_COLOURS[item.group] || RED : RED)
    if (kind === "poet") this.flyTo(item, POET_ZOOM)
    this.pushEvent("select", { kind, id: kind === "poet" ? item.slug : item.id, from: "map" })
  },

  // The overview picked something (a poet's name under a page).
  focus(kind, id) {
    this.hold()
    const item = this.point(kind, id)
    if (!item) return
    this.ring(item)
    this.flyTo(item, kind === "poet" ? POET_ZOOM : PAGE_ZOOM)
  },

  // -- the tour ---------------------------------------------------------

  stepMs() {
    return this.reduced ? REDUCED_STEP_MS : STEP_MS
  },

  step(delta) {
    if (this.rotation.length === 0) return
    this.stop()
    this.index = (this.index + delta + this.rotation.length) % this.rotation.length
    this.showEntry(this.rotation[this.index])
    this.later(() => this.next(), this.stepMs())
  },

  next() {
    if (this.paused) return
    this.step(1)
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

  // Turning by hand shows the page now but does not restart the clock; the
  // hold decides when the tour goes on.
  stepByHand(delta) {
    if (this.rotation.length === 0) return
    this.index = (this.index + delta + this.rotation.length) % this.rotation.length
    this.showEntry(this.rotation[this.index])
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
    if (this.timers.length === 0 && this.rotation.length > 0) {
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
