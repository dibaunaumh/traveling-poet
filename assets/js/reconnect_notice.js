// The quiet "Reconnecting…" line (card-99).
//
// LiveView fires phx-disconnected the instant the socket drops, and the
// stock flash says "We can't find the internet" in red. On this app a drop
// is almost never the reader's internet: the one server restarts on every
// deploy (about twenty seconds offline), and a phone waking its browser
// reconnects in under a second. So the notice waits, and most drops end
// before it is shown; one that lasts is said quietly, and after a while
// says that nothing is lost. The element dispatches tpoet:disconnected and
// tpoet:connected from its phx-disconnected / phx-connected bindings, so
// the lifecycle is still LiveView's (a crashed view rejoining counts too).
export function initReconnectNotice({after = 5000, longAfter = 25000} = {}) {
  let timers = []

  const stop = () => {
    timers.forEach(clearTimeout)
    timers = []
  }

  window.addEventListener("tpoet:disconnected", e => {
    const el = e.target
    if (timers.length) return

    timers = [
      setTimeout(() => {
        el.dataset.state = "short"
        el.removeAttribute("hidden")
      }, after),
      setTimeout(() => {
        el.dataset.state = "long"
      }, longAfter),
    ]
  })

  window.addEventListener("tpoet:connected", e => {
    stop()
    e.target.setAttribute("hidden", "")
    delete e.target.dataset.state
  })
}
