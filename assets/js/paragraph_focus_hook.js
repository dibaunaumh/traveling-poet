// "Read it again" from a quiz (card-140) opens a page at the paragraph the
// fact came from: the link carries `?p=<key>`, the paragraph key the server
// computes (Journal.Paragraphs.key/1) and reading_time_hook.js computes the
// same way. The hook sits on a hidden element beside the entry, finds the
// paragraph with that key, brings it into view and marks it for a moment.
// Without `?p`, or without a match, it does nothing.

import {paragraphKey} from "./reading_time_hook"

const ParagraphFocus = {
  mounted() {
    this.focus()
  },

  async focus() {
    const key = new URLSearchParams(window.location.search).get("p")
    if (!key || !(window.crypto && crypto.subtle)) return
    const target = document.getElementById(this.el.dataset.target)
    if (!target) return

    for (const p of target.querySelectorAll(".prose > p")) {
      if ((await paragraphKey(p.textContent)) === key) {
        const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches
        p.scrollIntoView({behavior: still ? "auto" : "smooth", block: "center"})
        p.classList.add("para-focus")
        setTimeout(() => p.classList.remove("para-focus"), 4000)
        return
      }
    }
  },
}

export default ParagraphFocus
