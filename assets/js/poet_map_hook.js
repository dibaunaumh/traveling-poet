// Leaflet map showing a poet's journey path + current location.
// Reads data-points (JSON: {path: [{lat,lng,name}], current: {lat,lng,name}, poet})
// on mount; a "map:update" push event with the same shape re-renders.
// For the landing page, data-poets (JSON: [{lat,lng,name,place,slug,avatar,
// entry_url}]) renders clickable markers for all public poets instead, and
// cycles their popups one at a time (see startTour).

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

    this.handleEvent("map:update", (data) => this.render(data))
  },

  renderData() {
    const points = this.el.dataset.points
    const poets = this.el.dataset.poets
    if (points) this.render(JSON.parse(points))
    if (poets) this.renderPoets(JSON.parse(poets))
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

  renderPoets(poets) {
    this.stopTour()
    this.layer.clearLayers()

    this.markers = poets.map((p) => {
      const m = L.marker([p.lat, p.lng]).addTo(this.layer)
      m.bindPopup(poetPopup(p), { minWidth: 200, maxWidth: 240, autoPanPadding: [50, 40] })
      // A click means the visitor is driving; back off for a while.
      m.on("click", () => this.engage())
      return m
    })

    if (poets.length > 0) {
      this.homeBounds = L.latLngBounds(poets.map((p) => [p.lat, p.lng]))
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
