// "Where did I draw this?" (card-140): a drawing is a 1-2 MB PNG, and on a
// phone it can take many seconds to arrive. Until it does, the figure shows
// a pencilled placeholder instead of a blank gap that looks broken; this hook
// marks the figure loaded once the image is in (or already was, from the
// quiz card's preload). The figure is phx-update="ignore", so a LiveView
// patch never strips the mark.

const QuizDrawing = {
  mounted() {
    const img = this.el.querySelector("img")
    if (!img) return
    const done = () => this.el.classList.add("is-loaded")
    if (img.complete && img.naturalWidth > 0) done()
    else img.addEventListener("load", done, {once: true})
  },
}

export default QuizDrawing
