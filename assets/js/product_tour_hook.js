// The product tour on the wait screen (ProductTour component): one slide at
// a time, its clip loaded and played only while it shows. It moves on by
// itself, because the reader may be waiting a quarter of an hour, and stops
// moving for a while as soon as they touch it.
const STEP_MS = 12_000
const HOLD_MS = 30_000

const ProductTour = {
  mounted() {
    this.slides = Array.from(this.el.querySelectorAll(".product-tour-slide"))
    this.dots = Array.from(this.el.querySelectorAll("[data-tour-go]"))
    this.index = 0
    this.heldUntil = 0
    this.still = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches

    this.el.querySelector("[data-tour-prev]")?.addEventListener("click", () => this.step(-1, true))
    this.el.querySelector("[data-tour-next]")?.addEventListener("click", () => this.step(1, true))
    this.dots.forEach((dot) =>
      dot.addEventListener("click", () => this.show(Number(dot.dataset.tourGo), true)),
    )

    this.onKey = (e) => {
      if (!this.el.contains(document.activeElement)) return
      if (e.key === "ArrowRight") this.step(1, true)
      if (e.key === "ArrowLeft") this.step(-1, true)
    }
    document.addEventListener("keydown", this.onKey)

    this.el.addEventListener("pointerdown", (e) => (this.touchX = e.clientX))
    this.el.addEventListener("pointerup", (e) => {
      if (this.touchX == null) return
      const dx = e.clientX - this.touchX
      this.touchX = null
      if (Math.abs(dx) > 40) this.step(dx < 0 ? 1 : -1, true)
      else this.hold()
    })

    this.show(0, false)
    this.timer = setInterval(() => {
      if (document.hidden || Date.now() < this.heldUntil) return
      this.step(1, false)
    }, STEP_MS)
  },

  destroyed() {
    clearInterval(this.timer)
    document.removeEventListener("keydown", this.onKey)
  },

  hold() {
    this.heldUntil = Date.now() + HOLD_MS
  },

  step(by, byHand) {
    const n = this.slides.length
    this.show((this.index + by + n) % n, byHand)
  },

  show(i, byHand) {
    if (byHand) this.hold()
    this.slides.forEach((slide, j) => {
      const on = j === i
      slide.hidden = !on
      const video = slide.querySelector("video")
      if (!video) return
      if (on && !this.still) {
        if (!video.getAttribute("src")) video.src = video.dataset.src
        video.play().catch(() => {})
      } else {
        video.pause()
      }
    })
    this.dots.forEach((dot, j) => dot.setAttribute("aria-current", j === i ? "true" : "false"))
    this.index = i
  },
}

export default ProductTour
