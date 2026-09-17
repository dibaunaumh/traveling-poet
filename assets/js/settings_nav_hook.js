// The Settings side menu. Marks the section being read, so a long page says
// where you are, and keeps the menu scrolled to it on a phone.
const SettingsNav = {
  mounted() {
    const links = [...this.el.querySelectorAll("a[data-section]")]
    if (links.length === 0) return

    const byId = new Map(links.map((a) => [a.dataset.section, a]))
    const sections = links
      .map((a) => document.getElementById(a.dataset.section))
      .filter(Boolean)

    const mark = (id) => {
      links.forEach((a) => a.removeAttribute("aria-current"))
      const active = byId.get(id)
      if (!active) return
      active.setAttribute("aria-current", "true")
      // On a phone the menu is a row that scrolls sideways: keep the mark in
      // sight by moving the row itself. scrollIntoView would scroll the page
      // as well, which on load jumped past the header.
      if (this.el.scrollWidth > this.el.clientWidth) {
        const left = active.offsetLeft
        const right = left + active.offsetWidth
        if (left < this.el.scrollLeft) {
          this.el.scrollLeft = Math.max(0, left - 16)
        } else if (right > this.el.scrollLeft + this.el.clientWidth) {
          this.el.scrollLeft = right - this.el.clientWidth + 16
        }
      }
    }

    // The topmost section crossing the line below the header wins.
    this.observer = new IntersectionObserver(
      () => {
        const line = 120
        const current = sections
          .map((el) => ({id: el.id, top: el.getBoundingClientRect().top}))
          .filter(({top}) => top <= line)
          .pop()

        mark(current ? current.id : sections[0].id)
      },
      {rootMargin: "-100px 0px -70% 0px", threshold: [0, 1]},
    )

    sections.forEach((el) => this.observer.observe(el))
    mark(sections[0].id)
  },

  destroyed() {
    if (this.observer) this.observer.disconnect()
  },
}

export default SettingsNav
