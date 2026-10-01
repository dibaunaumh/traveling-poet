// A flash message closes itself after a few seconds (data-autohide-ms), the
// same way a tap on it does: by running its own phx-click, which clears the
// flash on the server and hides it. A new message in the same element
// restarts the clock. On a phone a lingering banner sat over the status bar
// and was hard to read or close.

const AutoDismiss = {
  mounted() { this.schedule() },
  updated() { this.schedule() },
  destroyed() { clearTimeout(this.timer) },

  schedule() {
    clearTimeout(this.timer)
    const ms = parseInt(this.el.dataset.autohideMs, 10)
    if (!ms) return
    this.timer = setTimeout(() => {
      const js = this.el.getAttribute("phx-click")
      if (js) this.liveSocket.execJS(this.el, js)
    }, ms)
  },
}

export default AutoDismiss
