// The page read aloud, played by the notebook's own control instead of the
// browser's: a round ink button, the handwritten label, and a thin rule that
// fills as the reading runs. The <audio> underneath has no controls and
// preload="none", so the recording costs nothing until the reader presses
// play. Everything the control shows is derived from the element's events.

const NarrationPlayer = {
  mounted() {
    this.audio = this.el.querySelector("audio")
    this.button = this.el.querySelector(".narration-play")
    this.track = this.el.querySelector(".narration-track")
    this.fill = this.el.querySelector(".narration-fill")
    this.time = this.el.querySelector(".narration-time")

    this.button.addEventListener("click", () => this.toggle())
    this.track.addEventListener("click", e => this.seek(e))
    this.audio.addEventListener("play", () => this.state("playing"))
    this.audio.addEventListener("pause", () => this.state(this.audio.ended ? "idle" : "paused"))
    this.audio.addEventListener("ended", () => this.reset())
    this.audio.addEventListener("timeupdate", () => this.tick())
    this.audio.addEventListener("durationchange", () => this.tick())
    this.audio.addEventListener("waiting", () => this.el.setAttribute("data-waiting", ""))
    this.audio.addEventListener("playing", () => this.el.removeAttribute("data-waiting"))
    this.audio.addEventListener("error", () => this.fail())
  },

  destroyed() {
    if (this.audio && !this.audio.paused) this.audio.pause()
  },

  toggle() {
    if (this.audio.paused) {
      const p = this.audio.play()
      if (p && p.catch) p.catch(() => this.fail())
    } else {
      this.audio.pause()
    }
  },

  seek(e) {
    const d = this.audio.duration
    if (!isFinite(d) || d <= 0) return
    const r = this.track.getBoundingClientRect()
    const at = Math.min(Math.max((e.clientX - r.left) / r.width, 0), 1)
    this.audio.currentTime = at * d
    this.tick()
  },

  tick() {
    const d = this.audio.duration
    const t = this.audio.currentTime || 0
    if (isFinite(d) && d > 0) {
      this.fill.style.width = `${(t / d) * 100}%`
      this.time.textContent = `${clock(t)} of ${clock(d)}`
    }
  },

  state(s) {
    this.el.setAttribute("data-state", s)
    this.button.setAttribute("aria-label", s === "playing" ? "Pause" : "Play")
  },

  reset() {
    this.fill.style.width = "0%"
    this.time.textContent = ""
    this.state("idle")
    this.el.removeAttribute("data-waiting")
  },

  fail() {
    this.reset()
    this.el.setAttribute("data-state", "failed")
    this.time.textContent = "The recording would not play. Try again in a moment."
  },
}

function clock(seconds) {
  const s = Math.floor(seconds)
  const m = Math.floor(s / 60)
  return `${m}:${String(s % 60).padStart(2, "0")}`
}

export default NarrationPlayer
