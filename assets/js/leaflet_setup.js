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

export default L
