// The fleet's journeys, one poet at a time, while the reader's own first
// entry is being written.
//
// Reads data-tour (JSON, the shape of Poets.Showcase.tour_payload/1):
//   {me: {lat,lng,name,poet}, poets: [{slug,name,current,path,stops,stats}],
//    anonymous: [{lat,lng}], totals: {...}}
// and a sibling container named by data-cards holding one
// [data-tour-poet=slug] card per poet (server-rendered, hidden except the
// first), with [data-tour-pick] chips, [data-tour-count] numbers and
// [data-tour-stop="slug:i"] drawings inside.
//
// Each step: fly to the poet's route, draw it point by point with a marker
// riding the head, reveal each stop's drawing as the head passes it, count
// the numbers up, hold, move on; loop. Hovering the map or the cards pauses
// it. Under prefers-reduced-motion nothing moves: full routes, final numbers,
// and the cards simply take turns.
//
// The map div is phx-update="ignore"; a "tour:update" push event carries the
// same shape and re-selects the current poet, since a LiveView re-render of
// the cards resets their `hidden` attributes.

import L from "./leaflet_setup"

const DRAW_MS = 4000
const COUNT_MS = 1500
const HOLD_MS = 4500
const FLY_S = 1.2
const REDUCED_PAGE_MS = 12_000
const ENGAGE_MS = 20_000
const FIT = { padding: [30, 30], maxZoom: 7 }
const TEAL = "#2f5d62"
const RED = "#c0392b"

const JourneyTour = {
  mounted() {
    this.map = L.map(this.el, { scrollWheelZoom: false })
    L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
      maxZoom: 19,
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
    }).addTo(this.map)

    // flyTo needs a view to fly from; without one Leaflet throws and the map
    // stays grey.
    this.map.setView([30, 10], 2)
    this.staticLayer = L.layerGroup().addTo(this.map)
    this.pathLayer = L.layerGroup().addTo(this.map)
    this.cards = this.el.dataset.cards ? document.getElementById(this.el.dataset.cards) : null
    this.reduced = !!(window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches)
    this.markers = {}
    this.timers = []
    this.raf = null
    this.current = null

    this.bindInteraction()
    this.load(JSON.parse(this.el.dataset.tour || "{}"))
    this.handleEvent("tour:update", (data) => this.load(data))
  },

  destroyed() {
    this.stop()
    if (this.onVisibility) document.removeEventListener("visibilitychange", this.onVisibility)
    if (this.map) this.map.remove()
  },

  load(data) {
    this.data = data || {}
    this.poets = this.data.poets || []
    this.stop()
    this.renderStatic()

    const keep = this.current ? this.poets.findIndex((p) => p.slug === this.current) : -1
    if (keep < 0) this.fitAll()
    if (this.poets.length > 0) this.show(keep >= 0 ? keep : 0)
  },

  // Everyone's current position, the private dots, and where the reader's own
  // poet starts. Redrawn on every update; the animated route lives elsewhere.
  renderStatic() {
    this.staticLayer.clearLayers()
    this.markers = {}
    const all = []

    ;(this.data.anonymous || []).forEach((p) => {
      all.push([p.lat, p.lng])
      L.circleMarker([p.lat, p.lng], {
        radius: 6,
        color: "#9ca3af",
        fillColor: "#9ca3af",
        fillOpacity: 0.45,
        weight: 2,
        interactive: false,
      }).addTo(this.staticLayer)
    })

    this.poets.forEach((p) => {
      if (!p.current) return
      all.push([p.current.lat, p.current.lng])
      const m = L.marker([p.current.lat, p.current.lng]).addTo(this.staticLayer)
      m.bindTooltip(p.name, { direction: "top", offset: [-14, -10] })
      m.on("click", () => this.pick(p.slug))
      this.markers[p.slug] = m
    })

    if (this.data.me) {
      const me = this.data.me
      all.push([me.lat, me.lng])
      L.circleMarker([me.lat, me.lng], {
        radius: 9,
        color: RED,
        fillColor: RED,
        fillOpacity: 0.85,
        weight: 3,
      })
        .bindTooltip(`${me.poet} starts here`, { permanent: true, direction: "right", offset: [10, 0] })
        .addTo(this.staticLayer)
    }

    this.allBounds = all.length ? L.latLngBounds(all) : null
  },

  fitAll() {
    if (this.allBounds) this.map.fitBounds(this.allBounds, { ...FIT, maxZoom: 6, animate: false })
    else this.map.setView([30, 10], 2)
  },

  // -- the step ---------------------------------------------------------

  show(i) {
    this.stop()
    const poet = this.poets[i]
    if (!poet) return
    this.index = i
    this.current = poet.slug
    this.selectCard(poet)
    this.pathLayer.clearLayers()

    const pts = this.routeOf(poet)
    const bounds = pts.length ? L.latLngBounds(pts) : this.allBounds

    if (this.reduced) {
      this.drawFull(poet, pts)
      this.revealAllStops(poet)
      this.setCounts(poet, 1)
      if (bounds) this.map.fitBounds(bounds, { ...FIT, animate: false })
      this.later(() => this.next(), REDUCED_PAGE_MS)
      return
    }

    this.resetStops(poet)
    this.setCounts(poet, 0)
    this.afterMove(() => this.animate(poet, pts))
    if (bounds && bounds.isValid()) this.map.flyToBounds(bounds, { ...FIT, duration: FLY_S })
    else this.fitAll()
  },

  // Runs `fn` once the map has settled, or after the flight would have ended,
  // since Leaflet fires no moveend when the view does not change.
  afterMove(fn) {
    let done = false
    const run = () => {
      if (done) return
      done = true
      this.map.off("moveend", run)
      fn()
    }
    this.map.once("moveend", run)
    this.later(run, FLY_S * 1000 + 300)
  },

  routeOf(poet) {
    const pts = (poet.path || []).map((p) => [p.lat, p.lng])
    const c = poet.current
    const last = pts[pts.length - 1]
    if (c && !(last && last[0] === c.lat && last[1] === c.lng)) pts.push([c.lat, c.lng])
    return pts
  },

  drawFull(poet, pts) {
    if (pts.length > 1) {
      L.polyline(pts, { color: TEAL, weight: 3, opacity: 0.8, dashArray: "6 8" }).addTo(this.pathLayer)
    }
    pts.forEach((p) => {
      L.circleMarker(p, { radius: 4, color: TEAL, fillOpacity: 0.8 }).addTo(this.pathLayer)
    })
  },

  // Draws the route at a constant pace with a marker riding the head. Each
  // stop is revealed when the head reaches the vertex nearest to it.
  animate(poet, pts) {
    if (pts.length < 2) {
      this.drawFull(poet, pts)
      this.revealAllStops(poet)
      this.countUp(poet)
      this.later(() => this.next(), HOLD_MS)
      return
    }

    const cum = [0]
    for (let i = 1; i < pts.length; i++) {
      cum.push(cum[i - 1] + this.map.distance(pts[i - 1], pts[i]))
    }
    const total = cum[cum.length - 1] || 1
    const stopAt = (poet.stops || []).map((s) => {
      let best = 0
      let bestD = Infinity
      pts.forEach((p, i) => {
        const d = this.map.distance(p, [s.lat, s.lng])
        if (d < bestD) {
          bestD = d
          best = i
        }
      })
      return cum[best] / total
    })

    const line = L.polyline([pts[0]], { color: TEAL, weight: 3, opacity: 0.8, dashArray: "6 8" }).addTo(this.pathLayer)
    const head = L.circleMarker(pts[0], { radius: 6, color: TEAL, fillColor: "#fff", fillOpacity: 1, weight: 3 }).addTo(this.pathLayer)
    L.circleMarker(pts[0], { radius: 4, color: TEAL, fillOpacity: 0.8 }).addTo(this.pathLayer)

    const revealed = new Set()
    const start = performance.now()
    let nextVertex = 1
    this.countUp(poet)

    const frame = (now) => {
      const progress = Math.min(1, (now - start) / DRAW_MS)
      const dist = progress * total
      while (nextVertex < pts.length && cum[nextVertex] <= dist) {
        L.circleMarker(pts[nextVertex], { radius: 4, color: TEAL, fillOpacity: 0.8 }).addTo(this.pathLayer)
        nextVertex++
      }
      const i = Math.max(1, nextVertex)
      const a = pts[i - 1]
      const b = pts[Math.min(i, pts.length - 1)]
      const seg = cum[Math.min(i, pts.length - 1)] - cum[i - 1] || 1
      const t = Math.min(1, Math.max(0, (dist - cum[i - 1]) / seg))
      const pos = [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t]
      line.setLatLngs(pts.slice(0, i).concat([pos]))
      head.setLatLng(pos)

      stopAt.forEach((at, j) => {
        if (!revealed.has(j) && progress >= at) {
          revealed.add(j)
          this.revealStop(poet, j)
        }
      })

      if (progress < 1) {
        this.raf = requestAnimationFrame(frame)
      } else {
        this.raf = null
        this.revealAllStops(poet)
        this.later(() => this.next(), HOLD_MS)
      }
    }
    this.raf = requestAnimationFrame(frame)
  },

  next() {
    if (this.paused || this.poets.length === 0) return
    this.show((this.index + 1) % this.poets.length)
  },

  // -- cards ------------------------------------------------------------

  selectCard(poet) {
    if (this.cards) {
      this.cards.querySelectorAll("[data-tour-poet]").forEach((el) => {
        el.hidden = el.dataset.tourPoet !== poet.slug
      })
      this.cards.querySelectorAll("[data-tour-pick]").forEach((el) => {
        el.setAttribute("aria-selected", String(el.dataset.tourPick === poet.slug))
      })
    }
    Object.entries(this.markers).forEach(([slug, m]) => {
      const el = m.getElement()
      if (!el) return
      el.classList.toggle("poet-pin-selected", slug === poet.slug)
      el.classList.toggle("poet-pin-dim", slug !== poet.slug)
    })
  },

  card(poet) {
    return this.cards ? this.cards.querySelector(`[data-tour-poet="${CSS.escape(poet.slug)}"]`) : null
  },

  stopEl(poet, j) {
    const card = this.card(poet)
    return card ? card.querySelector(`[data-tour-stop="${CSS.escape(poet.slug + ":" + j)}"]`) : null
  },

  resetStops(poet) {
    const card = this.card(poet)
    if (!card) return
    card.querySelectorAll("[data-tour-stop]").forEach((el) => {
      el.hidden = true
      el.classList.remove("is-in")
    })
  },

  revealStop(poet, j) {
    const el = this.stopEl(poet, j)
    if (!el) return
    el.hidden = false
    requestAnimationFrame(() => el.classList.add("is-in"))
  },

  revealAllStops(poet) {
    const card = this.card(poet)
    if (!card) return
    card.querySelectorAll("[data-tour-stop]").forEach((el) => {
      el.hidden = false
      el.classList.add("is-in")
    })
  },

  setCounts(poet, fraction) {
    const card = this.card(poet)
    if (!card) return
    card.querySelectorAll("[data-tour-count]").forEach((el) => {
      const n = Number(el.dataset.count) || 0
      el.textContent = String(Math.round(n * fraction))
    })
  },

  countUp(poet) {
    const start = performance.now()
    const tick = (now) => {
      const f = Math.min(1, (now - start) / COUNT_MS)
      this.setCounts(poet, 1 - Math.pow(1 - f, 3))
      if (f < 1 && !this.reduced) this.countRaf = requestAnimationFrame(tick)
    }
    this.countRaf = requestAnimationFrame(tick)
  },

  // -- interaction ------------------------------------------------------

  bindInteraction() {
    const pause = () => {
      this.hovering = true
      this.pause()
    }
    const resume = () => {
      this.hovering = false
      this.resume()
    }
    this.el.addEventListener("mouseenter", pause)
    this.el.addEventListener("mouseleave", resume)
    this.map.on("dragstart zoomstart", () => this.engage())

    // A hidden tab gets no animation frames, so a flight would freeze while
    // the timers kept turning the cards underneath it. Hold everything, and
    // start the current step over when the reader comes back.
    this.onVisibility = () => {
      if (document.hidden) {
        this.stop()
        this.paused = true
      } else if (!this.hovering && !this.engaged) {
        this.paused = false
        if (this.poets.length > 0) this.show(this.index || 0)
      }
    }
    document.addEventListener("visibilitychange", this.onVisibility)

    if (this.cards) {
      this.cards.addEventListener("mouseenter", pause)
      this.cards.addEventListener("mouseleave", resume)
      this.cards.addEventListener("click", (e) => {
        const pick = e.target.closest("[data-tour-pick]")
        if (pick) this.pick(pick.dataset.tourPick)
      })
    }
  },

  // A chip or pin click shows that poet right away and keeps it for a while.
  pick(slug) {
    const i = this.poets.findIndex((p) => p.slug === slug)
    if (i < 0) return
    this.engage()
    this.show(i)
  },

  engage() {
    this.engaged = true
    clearTimeout(this.engageTimer)
    this.engageTimer = setTimeout(() => {
      this.engaged = false
      this.resume()
    }, ENGAGE_MS)
    this.pause()
  },

  // Pausing only stops the hand-off to the next poet; a route mid-draw
  // finishes, which reads better than a frozen marker.
  pause() {
    this.paused = true
  },

  resume() {
    if (this.hovering || this.engaged || document.hidden) return
    this.paused = false
    if (this.raf == null && this.timers.length === 0 && this.poets.length > 0) {
      this.later(() => this.next(), 800)
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
    if (this.raf != null) cancelAnimationFrame(this.raf)
    this.raf = null
    if (this.countRaf != null) cancelAnimationFrame(this.countRaf)
    this.countRaf = null
  },
}

export default JourneyTour
