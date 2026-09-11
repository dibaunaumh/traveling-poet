// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/traveling_poet"
import topbar from "../vendor/topbar"
import PoetMap, {initStaticMaps} from "./poet_map_hook"
import JourneyTour from "./journey_tour_hook"
import ScrollBottom from "./scroll_bottom_hook"
import ChatInput from "./chat_input_hook"
import ChatResizer from "./chat_resizer_hook"
import MobileViewport from "./mobile_viewport_hook"
import WebPush from "./web_push_hook"
import Markers from "./markers_hook"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, PoetMap, JourneyTour, ScrollBottom, ChatInput, ChatResizer, MobileViewport, WebPush, Markers},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#2f5d62"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}


// Initialize Leaflet maps on static (non-LiveView) pages like the landing page
window.addEventListener("DOMContentLoaded", initStaticMaps)

// Place names inside the poet's prose link to the Places spread. They are
// rendered from sanitized markdown, which strips the data-phx-link attributes
// a <.link patch> would carry, so the patch is wired here instead: a full
// page load would drop the chat and remount the map for a one-tab turn.
document.addEventListener("click", (e) => {
  const a = e.target.closest('.notebook-page .prose a[href*="spread=places"]')
  if (!a || e.metaKey || e.ctrlKey || e.shiftKey || e.button !== 0) return
  e.preventDefault()
  liveSocket.pushHistoryPatch(e, a.getAttribute("href"), "push", a)
})

// After the patch lands, light the stop the link pointed at for a moment.
// CSS :target would do this on a real navigation, but browsers do not
// re-evaluate it after pushState, which is how LiveView patches.
window.addEventListener("phx:page-loading-stop", () => {
  const hash = window.location.hash
  if (!hash.startsWith("#stop-")) return
  const stop = document.getElementById(hash.slice(1))
  if (!stop) return
  stop.classList.add("stop-lit")
  setTimeout(() => stop.classList.remove("stop-lit"), 4000)
})
