// The page read aloud, played by the notebook's own control instead of the
// browser's: a round ink button, the handwritten label, and a thin rule that
// fills as the reading runs. The hook owns the <audio> (phx-update="ignore")
// and takes the recording's URL from data-src on the wrapper, so a LiveView
// patch never fights it over the element. preload="none": the recording
// costs nothing until the reader presses play.
//
// Without a recording (no data-src) the press reads the page on request:
// the hook plays a moment of silence inside the tap (that is what lets
// Safari and the iOS app start audio later without another gesture), pushes
// `narration_request`, and when the server patches data-src in it loads the
// recording and plays. data-state "generating" comes from the server while
// the page is read; a failure resets it to "idle".

const SILENCE =
  "data:audio/wav;base64,UklGRnQAAABXQVZFZm10IBAAAAABAAEAQB8AAEAfAAABAAgAZGF0YVAAAACAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgA=="

const NarrationPlayer = {
  mounted() {
    this.audio = this.el.querySelector("audio")
    this.button = this.el.querySelector(".narration-play")
    this.track = this.el.querySelector(".narration-track")
    this.fill = this.el.querySelector(".narration-fill")
    this.time = this.el.querySelector(".narration-time")
    this.label = this.el.querySelector(".narration-label")
    this.src = null
    this.playWhenReady = false
    this.syncSrc()

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

  // The server patched the wrapper: a recording arrived, or the request failed.
  updated() {
    this.syncSrc()
    const state = this.el.getAttribute("data-state")
    if (state === "idle" && this.playWhenReady && !this.src) {
      this.playWhenReady = false
      this.label.textContent = this.el.getAttribute("data-label") || "Listen"
    }
  },

  destroyed() {
    if (this.audio && !this.audio.paused) this.audio.pause()
  },

  syncSrc() {
    const src = this.el.getAttribute("data-src")
    if (src && src !== this.src) {
      this.src = src
      this.audio.src = src
      this.audio.load()
      if (this.playWhenReady) {
        this.playWhenReady = false
        this.play()
      }
    }
  },

  toggle() {
    if (!this.src) return this.request()
    if (this.audio.paused) this.play()
    else this.audio.pause()
  },

  // No recording yet: ask for one, and spend this tap unlocking the element.
  request() {
    const state = this.el.getAttribute("data-state")
    if (state === "generating" || this.playWhenReady) return
    this.playWhenReady = true
    this.el.setAttribute("data-state", "generating")
    this.label.textContent = "Reading this page, a few seconds"
    this.audio.src = SILENCE
    const p = this.audio.play()
    if (p && p.catch) p.catch(() => {})
    this.pushEvent("narration_request", {})
  },

  play() {
    const p = this.audio.play()
    if (p && p.catch) p.catch(() => this.fail())
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
    if (!this.src) return
    const d = this.audio.duration
    const t = this.audio.currentTime || 0
    if (isFinite(d) && d > 0) {
      this.fill.style.width = `${(t / d) * 100}%`
      this.time.textContent = `${clock(t)} of ${clock(d)}`
    }
  },

  state(s) {
    if (!this.src) return
    this.el.setAttribute("data-state", s)
    this.button.setAttribute("aria-label", s === "playing" ? "Pause" : "Play")
  },

  reset() {
    this.fill.style.width = "0%"
    this.time.textContent = ""
    this.el.setAttribute("data-state", "idle")
    this.button.setAttribute("aria-label", "Play")
    this.el.removeAttribute("data-waiting")
  },

  fail() {
    this.playWhenReady = false
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
