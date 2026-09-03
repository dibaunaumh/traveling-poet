// Keeps a `fixed inset-0` overlay sized to the *visual* viewport.
//
// On iOS Safari the on-screen keyboard does not shrink the layout viewport;
// instead the page is scrolled so the focused input stays visible, which
// pushes the top of a fullscreen overlay (and its close button) off screen.
// Tracking window.visualViewport and pinning the element's top/height to it
// keeps the whole overlay, header included, within what the user can see.
//
// Only active while the element is actually position:fixed (the mobile
// layout); on desktop the same element is a static side panel and is left alone.
const MobileViewport = {
  mounted() {
    this.vv = window.visualViewport
    if (!this.vv) return
    this.apply = () => {
      const fixed = getComputedStyle(this.el).position === "fixed"
      if (fixed) {
        this.el.style.top = `${this.vv.offsetTop}px`
        this.el.style.height = `${this.vv.height}px`
      } else {
        this.el.style.top = ""
        this.el.style.height = ""
      }
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
