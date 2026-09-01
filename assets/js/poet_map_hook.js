// Leaflet map showing a poet's journey path + current location.
// Reads data-points (JSON: {path: [{lat,lng,name}], current: {lat,lng,name}, poet})
// on mount; a "map:update" push event with the same shape re-renders.
// For the landing page, data-poets (JSON: [{lat,lng,name,place,slug,avatar,
// entry_url}]) renders clickable markers for all public poets instead, and
// cycles their popups one at a time (see startTour). data-anonymous-poets
// (JSON: [{lat,lng}]) adds the private ones as unnamed grey dots -- they are
// never clickable and never join the tour, since there is nothing to show.
// For the trip guide, data-places (JSON: [{id,n,lat,lng,name,category,group,
// rating,blurb,url,poet}]) renders numbered pins coloured by group; clicking
// one pushes select_place back to the LiveView. Only geocoded places appear --
// the rest are still listed in the List and Itinerary views.

import * as L from "../vendor/leaflet/leaflet.js"

// Leaflet's default icon paths break under bundling: Icon.Default's
// _getIconUrl auto-detects a base path from the script/CSS location (garbage
// once esbuild inlines it) and TAKES PRECEDENCE over mergeOptions. Delete it
// so the explicit URLs below actually apply.
delete L.Icon.Default.prototype._getIconUrl
L.Icon.Default.mergeOptions({
  iconUrl: "/images/leaflet/marker-icon.png",
  iconRetinaUrl: "/images/leaflet/marker-icon-2x.png",
  shadowUrl: "/images/leaflet/marker-shadow.png",
})

// Static (non-LiveView) pages: initialize any [data-static-map] element on load.
export function initStaticMaps() {
  document.querySelectorAll("[data-static-map]").forEach((el) => {
    const fake = Object.create(PoetMap)
    fake.el = el
    fake.handleEvent = () => {}
    fake.mounted()
  })
}

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
// all agent-supplied (same reason as poetPopup below).
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

const TOUR_SHOW_MS = 4500
const TOUR_GAP_MS = 1300
const TOUR_RESUME_MS = 20000
const HOME_VIEW = { padding: [40, 40], maxZoom: 6, animate: false }

// Built as DOM nodes rather than an HTML string: poet names and places are
// user-supplied.
function poetPopup(p) {
  const el = document.createElement("div")
  el.className = "poet-popup"

  const avatar = document.createElement(p.avatar ? "img" : "div")
  avatar.className = "poet-popup-avatar"
  if (p.avatar) {
    avatar.src = p.avatar
    avatar.alt = p.name
  } else {
    avatar.textContent = (p.name || "?").trim().charAt(0).toUpperCase()
  }
  el.appendChild(avatar)

  const body = document.createElement("div")

  const name = document.createElement("div")
  name.className = "poet-popup-name"
  name.textContent = p.name || ""
  body.appendChild(name)

  if (p.place) {
    const place = document.createElement("div")
    place.className = "poet-popup-place"
    place.textContent = p.place
    body.appendChild(place)
  }

  const link = document.createElement("a")
  link.className = "poet-popup-link"
  link.href = p.entry_url || `/p/${p.slug}`
  link.textContent = "Read the latest journal entry →"
  body.appendChild(link)

  // The poet has moved since they last wrote: name the place the entry is
  // actually about, so the link doesn't promise today's location.
  if (p.entry_place) {
    const from = document.createElement("div")
    from.className = "poet-popup-entry-place"
    from.textContent = `latest entry from ${p.entry_place}`
    body.appendChild(from)
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

    this.layer = L.layerGroup().addTo(this.map)
    this.renderData()

    // phx-update="ignore" means a changed data attribute never re-renders the
    // map, so filter changes arrive as an event instead.
    this.handleEvent("map:update", (data) =>
      data.places ? this.renderPlaces(data.places) : this.render(data)
    )
  },

  renderData() {
    const points = this.el.dataset.points
    const poets = this.el.dataset.poets
    const anonymous = this.el.dataset.anonymousPoets
    const places = this.el.dataset.places
    if (points) this.render(JSON.parse(points))
    if (poets) this.renderPoets(JSON.parse(poets), anonymous ? JSON.parse(anonymous) : [])
    if (places) this.renderPlaces(JSON.parse(places))
  },

  render(data) {
    this.layer.clearLayers()
    const path = (data.path || []).map((p) => [p.lat, p.lng])

    if (path.length > 1) {
      L.polyline(path, { color: "#7c3aed", weight: 3, opacity: 0.7, dashArray: "6 8" }).addTo(this.layer)
    }

    ;(data.path || []).forEach((p) => {
      L.circleMarker([p.lat, p.lng], { radius: 4, color: "#7c3aed", fillOpacity: 0.8 })
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
      if (planned.length > 0) {
        this.map.fitBounds([[data.current.lat, data.current.lng], ...planned], { padding: [30, 30] })
      } else {
        this.map.setView([data.current.lat, data.current.lng], 9)
      }
    } else if (path.length > 0) {
      this.map.fitBounds(path, { padding: [30, 30] })
    } else {
      this.map.setView([30, 10], 2)
    }
  },

  // Trip guide pins. Colour carries the filter group so the map agrees with
  // the chips above it at a glance.
  renderPlaces(places) {
    this.stopTour()
    this.layer.clearLayers()

    const coords = []
    places.forEach((p) => {
      coords.push([p.lat, p.lng])
      L.marker([p.lat, p.lng], { icon: placeIcon(p) })
        .bindPopup(placePopup(p))
        .on("click", () => this.pushEvent("select_place", { id: p.id }))
        .addTo(this.layer)
    })

    if (coords.length > 1) {
      this.map.fitBounds(coords, { padding: [40, 40], maxZoom: 15 })
    } else if (coords.length === 1) {
      this.map.setView(coords[0], 14)
    } else {
      this.map.setView([30, 10], 2)
    }
  },

  renderPoets(poets, anonymous = []) {
    this.stopTour()
    this.layer.clearLayers()

    this.markers = poets.map((p) => {
      const m = L.marker([p.lat, p.lng]).addTo(this.layer)
      m.bindPopup(poetPopup(p), { minWidth: 200, maxWidth: 240, autoPanPadding: [50, 40] })
      // A click means the visitor is driving; back off for a while.
      m.on("click", () => this.engage())
      return m
    })

    anonymous.forEach((p) => {
      L.circleMarker([p.lat, p.lng], {
        radius: 6,
        color: "#9ca3af",
        fillColor: "#9ca3af",
        fillOpacity: 0.45,
        weight: 2,
        interactive: false,
      }).addTo(this.layer)
    })

    const all = [...poets, ...anonymous]

    if (all.length > 0) {
      this.homeBounds = L.latLngBounds(all.map((p) => [p.lat, p.lng]))
      this.map.fitBounds(this.homeBounds, HOME_VIEW)
    } else {
      this.homeBounds = null
      this.map.setView([30, 10], 2)
    }

    if (!this.tourBound) {
      this.tourBound = true
      this.map.on("dragstart zoomstart", () => this.engage())
      this.el.addEventListener("mouseenter", () => {
        this.hovering = true
        this.clearTourTimer()
      })
      this.el.addEventListener("mouseleave", () => {
        this.hovering = false
        this.resumeTour()
      })
    }

    this.startTour()
  },

  // Opens each poet's popup in turn -- show, close, brief pause, next one --
  // looping back to the first. Paused while the visitor hovers or interacts.
  startTour() {
    this.clearTourTimer()
    if (!this.markers || this.markers.length === 0) return
    if (window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches) return

    if (this.markers.length === 1) {
      this.tourTimer = setTimeout(() => this.markers[0].openPopup(), TOUR_GAP_MS)
      return
    }

    this.tourIndex = -1
    this.scheduleTour(TOUR_GAP_MS)
  },

  scheduleTour(delay) {
    this.clearTourTimer()
    this.tourTimer = setTimeout(() => this.tourStep(), delay)
  },

  tourStep() {
    this.tourIndex = (this.tourIndex + 1) % this.markers.length
    this.markers[this.tourIndex].openPopup()

    this.tourTimer = setTimeout(() => {
      this.map.closePopup()
      // Each popup nudges the map to fit itself (Leaflet's autoPan); snap back
      // during the gap so the drift doesn't accumulate across the loop.
      if (this.homeBounds) this.map.fitBounds(this.homeBounds, HOME_VIEW)
      this.scheduleTour(TOUR_GAP_MS)
    }, TOUR_SHOW_MS)
  },

  resumeTour() {
    if (this.hovering || this.userEngaged) return
    if (!this.markers || this.markers.length < 2) return
    this.scheduleTour(TOUR_GAP_MS)
  },

  engage() {
    this.userEngaged = true
    this.clearTourTimer()
    clearTimeout(this.engageTimer)
    this.engageTimer = setTimeout(() => {
      this.userEngaged = false
      this.resumeTour()
    }, TOUR_RESUME_MS)
  },

  clearTourTimer() {
    clearTimeout(this.tourTimer)
    this.tourTimer = null
  },

  stopTour() {
    this.clearTourTimer()
    clearTimeout(this.engageTimer)
  },

  destroyed() {
    this.stopTour()
    if (this.map) this.map.remove()
  },
}

export default PoetMap
