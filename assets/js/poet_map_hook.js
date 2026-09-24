// Leaflet map showing a poet's journey path + current location.
// Reads data-points (JSON: {path: [{lat,lng,name}], current: {lat,lng,name},
// focus: {lat,lng,name,date}, poet, places}) -- focus is the entry being read,
// and it wins the viewport over `current` so paging back through the journal
// moves the map to the day you are looking at. `places` (same shape as the
// guide's, below) is the entry's own stops when the reader is on the Places
// spread; then the pins win the viewport, since that page is about them.
// Rendered on mount; a "map:update" push event with the same shape re-renders.
// For the trip guide, data-places (JSON: [{id,n,lat,lng,name,category,group,
// rating,blurb,url,poet}]) renders numbered pins coloured by group; clicking
// one pushes select_place back to the LiveView. Only geocoded places appear --
// the rest are still listed in the List and Itinerary views.

import L, { touchFriendly } from "./leaflet_setup"

// daisyUI's success is a teal and warning an amber, so the guide's pins match
// the rest of the app's palette in both themes without new tokens.
const GROUP_COLORS = { food: "#c0392b", events: "#8e44ad", sights: "#0f766e" }

function placeIcon(p) {
  const color = GROUP_COLORS[p.group] || GROUP_COLORS.sights
  return L.divIcon({
    className: "guide-pin",
    html:
      `<span style="background:${color}">` +
      `<b>${Number(p.n) || ""}</b></span>`,
    iconSize: [26, 26],
    iconAnchor: [13, 26],
    popupAnchor: [0, -24],
  })
}

// Built as DOM nodes, never an HTML string: names, blurbs and URLs here are
// all agent-supplied.
function placePopup(p) {
  const el = document.createElement("div")
  el.className = "poet-popup"

  const body = document.createElement("div")

  const name = document.createElement("div")
  name.className = "poet-popup-name"
  name.textContent = p.name || ""
  body.appendChild(name)

  const meta = document.createElement("div")
  meta.className = "poet-popup-place"
  const category = p.category ? p.category.charAt(0).toUpperCase() + p.category.slice(1) : ""
  // The rating is the poet's own take and has to say whose it is -- a bare
  // star next to a restaurant reads as a sourced review score.
  meta.textContent = p.rating
    ? `${category} · ${"\u2605".repeat(p.rating)} ${p.poet || "the poet"}'s pick`
    : category
  body.appendChild(meta)

  if (p.blurb) {
    const blurb = document.createElement("div")
    blurb.className = "poet-popup-blurb"
    blurb.textContent = p.blurb
    body.appendChild(blurb)
  }

  if (p.url) {
    const link = document.createElement("a")
    link.href = p.url
    link.target = "_blank"
    link.rel = "noopener noreferrer nofollow"
    link.textContent = "View details \u2197"
    body.appendChild(link)
  }

  el.appendChild(body)
  return el
}

// DOM nodes, not an HTML string: place names are agent-supplied.
function entryPopup(focus) {
  const el = document.createElement("div")
  el.className = "poet-popup"

  const body = document.createElement("div")

  const name = document.createElement("div")
  name.className = "poet-popup-name"
  name.textContent = focus.name || ""
  body.appendChild(name)

  if (focus.date) {
    const date = document.createElement("div")
    date.className = "poet-popup-place"
    date.textContent = focus.date
    body.appendChild(date)
  }

  el.appendChild(body)
  return el
}

const PoetMap = {
  mounted() {
    this.map = L.map(this.el, { scrollWheelZoom: false })
    L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
      maxZoom: 19,
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
    }).addTo(this.map)

    touchFriendly(this.map)

    this.layer = L.layerGroup().addTo(this.map)
    this.renderData()

    // The same #poet-map node is MOVED between the top of the page and the
    // Places spread's left page (LiveView matches elements by id), and the
    // column changes width when the chat opens. Leaflet keeps whatever size
    // it last measured, so a fit computed after a move lands off-centre.
    // Re-measure and re-apply the viewport whenever the box changes.
    if (typeof ResizeObserver !== "undefined") {
      this.resizeObserver = new ResizeObserver(() => this.refit())
      this.resizeObserver.observe(this.el)
    }

    // phx-update="ignore" means a changed data attribute never re-renders the
    // map, so filter changes arrive as an event instead.
    // A journey payload always has a path (possibly empty); the guide's has
    // only places.
    this.handleEvent("map:update", (data) =>
      data.path !== undefined ? this.render(data) : this.renderPlaces(data.places)
    )
  },

  // Re-measure the container and re-apply the last viewport the data asked
  // for. `this.viewport` is set by each render; nothing to do before one.
  refit() {
    if (!this.map) return
    this.map.invalidateSize()
    if (this.viewport) this.viewport()
  },

  // Every render ends by describing its viewport as a closure, run once now
  // (after a size check) and again on every resize.
  fit(viewport) {
    this.viewport = viewport
    this.map.invalidateSize()
    viewport()
  },

  renderData() {
    const points = this.el.dataset.points
    const places = this.el.dataset.places
    if (points) this.render(JSON.parse(points))
    if (places) this.renderPlaces(JSON.parse(places))
  },

  render(data) {
    this.layer.clearLayers()
    const path = (data.path || []).map((p) => [p.lat, p.lng])

    if (path.length > 1) {
      L.polyline(path, { color: "#2f5d62", weight: 3, opacity: 0.7, dashArray: "6 8" }).addTo(this.layer)
    }

    ;(data.path || []).forEach((p) => {
      L.circleMarker([p.lat, p.lng], { radius: 4, color: "#2f5d62", fillOpacity: 0.8 })
        .bindPopup(p.name || "")
        .addTo(this.layer)
    })

    // Trip Scout: planned (unvisited) stops as gray hollow markers, with a
    // dashed gray line from the current position through the route ahead
    const planned = (data.planned || []).map((p) => [p.lat, p.lng])
    if (planned.length > 0 && data.current) {
      L.polyline([[data.current.lat, data.current.lng], ...planned], {
        color: "#9ca3af",
        weight: 2,
        opacity: 0.7,
        dashArray: "2 8",
      }).addTo(this.layer)
    }
    ;(data.planned || []).forEach((p) => {
      L.circleMarker([p.lat, p.lng], {
        radius: 6,
        color: "#9ca3af",
        fillColor: "#ffffff",
        fillOpacity: 0.9,
        weight: 2,
      })
        .bindPopup(`planned: ${p.name || ""}`)
        .addTo(this.layer)
    })

    if (data.current) {
      const m = L.marker([data.current.lat, data.current.lng]).addTo(this.layer)
      m.bindPopup(`<b>${data.poet || "Your poet"}</b><br/>${data.current.name || ""}`)
    }

    // The entry being read, ringed so it is distinguishable from the path dots
    // it sits on top of.
    if (data.focus) {
      L.circleMarker([data.focus.lat, data.focus.lng], {
        radius: 9,
        color: "#c0392b",
        fillColor: "#c0392b",
        fillOpacity: 0.85,
        weight: 3,
      })
        .bindPopup(entryPopup(data.focus))
        .addTo(this.layer)
    }

    // The day's stops, numbered like the guide's pins. No select_place push
    // here: the journal has no handler for it, the popup is the whole story.
    const stops = (data.places || []).map((p) => [p.lat, p.lng])
    ;(data.places || []).forEach((p) => {
      L.marker([p.lat, p.lng], { icon: placeIcon(p) }).bindPopup(placePopup(p)).addTo(this.layer)
    })

    // Stops win the viewport (that page is about them), then focus: the
    // reader is looking at that day, not at wherever the poet happens to be.
    this.fit(() => {
      if (stops.length > 1) {
        this.map.fitBounds(stops, { padding: [40, 40], maxZoom: 15 })
      } else if (stops.length === 1) {
        this.map.setView(stops[0], 14)
      } else if (data.focus) {
        this.map.setView([data.focus.lat, data.focus.lng], 9)
      } else if (data.current && planned.length > 0) {
        this.map.fitBounds([[data.current.lat, data.current.lng], ...planned], { padding: [30, 30] })
      } else if (data.current) {
        this.map.setView([data.current.lat, data.current.lng], 9)
      } else if (path.length > 0) {
        this.map.fitBounds(path, { padding: [30, 30] })
      } else {
        this.map.setView([30, 10], 2)
      }
    })
  },

  // Trip guide pins. Colour carries the filter group so the map agrees with
  // the chips above it at a glance.
  renderPlaces(places) {
    this.layer.clearLayers()

    const coords = []
    places.forEach((p) => {
      coords.push([p.lat, p.lng])
      L.marker([p.lat, p.lng], { icon: placeIcon(p) })
        .bindPopup(placePopup(p))
        .on("click", () => this.pushEvent("select_place", { id: p.id }))
        .addTo(this.layer)
    })

    this.fit(() => {
      if (coords.length > 1) {
        this.map.fitBounds(coords, { padding: [40, 40], maxZoom: 15 })
      } else if (coords.length === 1) {
        this.map.setView(coords[0], 14)
      } else {
        this.map.setView([30, 10], 2)
      }
    })
  },

  destroyed() {
    if (this.resizeObserver) this.resizeObserver.disconnect()
    if (this.map) this.map.remove()
  },
}

export default PoetMap
