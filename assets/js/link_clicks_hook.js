// Which outside links the owner of a journal follows from their own page (a
// place's map, a find's source, a hotel), so the fleet's operators can see
// that a page was used and not only opened. Only mounted on the owner's
// journal, and only when they left reading signals on in Settings, like the
// ReadingTime hook beside it.
//
// The server is told the site's host and the part of the page the link sits
// in (the section's kind, or the spread), never the link itself.

const LinkClicks = {
  mounted() {
    this.onClick = (event) => {
      const link = event.target.closest && event.target.closest("a[href]")
      if (!link || !link.closest(".spread-wrap")) return

      let url
      try {
        url = new URL(link.href, window.location.href)
      } catch (_e) {
        return
      }
      if (!/^https?:$/.test(url.protocol) || url.origin === window.location.origin) return

      const section = link.closest("[data-section-kind]")
      this.pushEvent("link_click", {
        entry_id: this.el.dataset.entryId,
        spread: this.el.dataset.spread || null,
        kind: section ? section.dataset.sectionKind : null,
        host: url.hostname,
      })
    }
    // Capture: a link that opens in the app's sheet stops the click on its way up.
    document.addEventListener("click", this.onClick, true)
  },

  destroyed() {
    document.removeEventListener("click", this.onClick, true)
  },
}

export default LinkClicks
