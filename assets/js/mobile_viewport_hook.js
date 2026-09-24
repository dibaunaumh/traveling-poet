// Keeps a `fixed inset-0` overlay sized to the *visual* viewport.
//
// On iOS Safari the on-screen keyboard does not shrink the layout viewport;
// instead the page is scrolled so the focused input stays visible, which
// pushes the top of a fullscreen overlay (and its close button) off screen.
// Tracking window.visualViewport and pinning the element's top/height to it
// keeps the whole overlay, header included, within what the user can see.
//
// In the app (the shell's tab bar showing) it also keeps the overlay off the
// header and the tab bar, so the reader can still go anywhere with the chat
// open.
//
// Only active while the element is actually position:fixed (the mobile
// layout); on desktop the same element is a static side panel and is left alone.
const MobileViewport = {
  mounted() {
    this.vv = window.visualViewport
    if (!this.vv) return
    this.apply = () => {
      const fixed = getComputedStyle(this.el).position === "fixed"
      // With the keyboard up the overlay ends at the keyboard, not at the
      // home indicator, so the bottom safe-area padding would only be a
      // blank strip above the keys (.chat-overlay.keyboard-open in app.css).
      const keyboard = fixed && window.innerHeight - this.vv.height > 120
      this.el.classList.toggle("keyboard-open", keyboard)

      let top = this.vv.offsetTop
      let bottom = this.vv.offsetTop + this.vv.height
      let left = null
      let underHeader = false
      let byBar = false

      // In the app the chat opens between the header and the tab bar, never
      // over them (app.css holds the header still while the chat is open).
      // With the keyboard up the bar is under the keys, and the chat takes
      // everything that is left, as before.
      if (fixed && !keyboard) {
        const header = document.querySelector(".app-header")
        if (header && getComputedStyle(header).position === "fixed") {
          top = Math.max(top, header.getBoundingClientRect().bottom)
          underHeader = true
        }
        const bar = document.getElementById("shell-tabbar")
        if (bar && getComputedStyle(bar).display !== "none") {
          const r = bar.getBoundingClientRect()
          if (r.height <= r.width) {
            bottom = Math.min(bottom, r.top)
            byBar = true
          } else {
            // The sideways rail. A wide phone gets the chat as a drawer on
            // the right, clear of the rail already.
            this.el.style.left = ""
            if (this.el.getBoundingClientRect().left < r.right) {
              left = r.right
              byBar = true
            }
          }
        }
      }

      this.el.style.top = fixed ? `${top}px` : ""
      this.el.style.height = fixed ? `${bottom - top}px` : ""
      this.el.style.left = left != null ? `${left}px` : ""
      this.el.classList.toggle("chat-under-header", underHeader)
      this.el.classList.toggle("chat-by-bar", byBar)
    }
    this.vv.addEventListener("resize", this.apply)
    this.vv.addEventListener("scroll", this.apply)
    this.apply()
  },
  updated() {
    if (this.apply) this.apply()
  },
  destroyed() {
    if (!this.vv) return
    this.vv.removeEventListener("resize", this.apply)
    this.vv.removeEventListener("scroll", this.apply)
  },
}

export default MobileViewport
