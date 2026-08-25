// Leaflet map showing a poet's journey path + current location.
// Reads data-points (JSON: {path: [{lat,lng,name}], current: {lat,lng,name}, poet})
// on mount; a "map:update" push event with the same shape re-renders.
// For the landing page, data-poets (JSON: [{lat,lng,name,slug}]) renders
// clickable markers for all public poets instead.

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

    if (data.current) {
      const m = L.marker([data.current.lat, data.current.lng]).addTo(this.layer)
      m.bindPopup(`<b>${data.poet || "Your poet"}</b><br/>${data.current.name || ""}`)
      this.map.setView([data.current.lat, data.current.lng], 9)
    } else if (path.length > 0) {
      this.map.fitBounds(path, { padding: [30, 30] })
    } else {
      this.map.setView([30, 10], 2)
    }
  },

  renderPoets(poets) {
    this.layer.clearLayers()

    poets.forEach((p) => {
      const m = L.marker([p.lat, p.lng]).addTo(this.layer)
      m.bindPopup(
        `<b>${p.name}</b><br/>${p.place || ""}<br/><a href="/p/${p.slug}">Read the journal →</a>`
      )
    })

    if (poets.length > 0) {
      this.map.fitBounds(poets.map((p) => [p.lat, p.lng]), { padding: [40, 40], maxZoom: 6 })
    } else {
      this.map.setView([30, 10], 2)
    }
  },

  destroyed() {
    if (this.map) this.map.remove()
  },
}

export default PoetMap
