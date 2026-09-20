// One Leaflet import for every map hook, with the default marker icons
// pointed at our static files.
//
// Leaflet's default icon paths break under bundling: Icon.Default's
// _getIconUrl auto-detects a base path from the script/CSS location (garbage
// once esbuild inlines it) and TAKES PRECEDENCE over mergeOptions. Delete it
// so the explicit URLs below actually apply.
import * as L from "../vendor/leaflet/leaflet.js"

delete L.Icon.Default.prototype._getIconUrl
L.Icon.Default.mergeOptions({
  iconUrl: "/images/leaflet/marker-icon.png",
  iconRetinaUrl: "/images/leaflet/marker-icon-2x.png",
  shadowUrl: "/images/leaflet/marker-shadow.png",
})

// A map inside a scrolling page is a trap on a touch screen: a finger that
// lands on it pans the map, and the page underneath cannot be scrolled past
// it. So under a finger the map sleeps (one finger scrolls the page, two
// still pinch-zoom) until it is tapped, and goes back to sleep on a touch
// anywhere else. The hint is CSS (.map-asleep in app.css). A mouse never
// sees any of this.
export function touchFriendly(map) {
  if (!window.matchMedia || !window.matchMedia("(pointer: coarse)").matches) return

  const el = map.getContainer()
  const sleep = () => {
    map.dragging.disable()
    el.classList.add("map-asleep")
  }
  const wake = () => {
    map.dragging.enable()
    el.classList.remove("map-asleep")
  }
  const outside = (e) => {
    if (!el.contains(e.target)) sleep()
  }

  sleep()
  map.on("click", wake)
  document.addEventListener("pointerdown", outside)
  map.on("unload", () => document.removeEventListener("pointerdown", outside))
}

export default L
