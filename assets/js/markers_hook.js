// Feedback markers on a journal entry. One hook on the <article>.
//
// The server owns the state: which marker is "in hand" (data-active-marker)
// and the markers on this entry (data-markers, JSON). This hook turns a text
// selection or a tap into a `marker_add` event, and paints the markers back
// onto the page: text markers as <mark> wraps re-found by their quoted text,
// section and illustration markers (and text markers whose quote is gone) as
// pins in the left margin. Everything it adds is stripped and redrawn on every
// update, so a revised entry never keeps stale marks.

const MAX_QUOTE = 500
const CONTEXT = 64
const CLICK_AFTER_SELECT_MS = 500

const Markers = {
  mounted() {
    this.icons = parse(this.el.dataset.markerIcons, {})
    this.busy = false
    this.selectedAt = 0
    this.popover = null
    this.onPointerUp = () => this.captureSelection()
    this.onClick = (e) => this.handleClick(e)
    this.onSelectionChange = debounce(() => this.captureSelection(), 350)
    // Tapping anywhere else, or Escape, puts the options popover away.
    this.onDocClick = (e) => {
      // The click that ends a drag-select lands right after the editor opens;
      // it is not a tap away.
      if (Date.now() - this.popoverOpenedAt < CLICK_AFTER_SELECT_MS) return
      if (this.popover && !e.target.closest(".marker-popover, mark.marker, .marker-pin")) {
        if (this.popover.dataset.editor) this.finishEditor()
        else this.closePopover()
      }
    }
    this.onKey = (e) => {
      if (e.key !== "Escape" || !this.popover) return
      if (this.popover.dataset.editor) this.cancelEditor()
      else this.closePopover()
    }
    this.pendingNote = null
    this.popoverOpenedAt = 0
    this.el.addEventListener("pointerup", this.onPointerUp)
    this.el.addEventListener("click", this.onClick)
    document.addEventListener("selectionchange", this.onSelectionChange)
    document.addEventListener("click", this.onDocClick)
    document.addEventListener("keydown", this.onKey)
    this.render()
  },

  updated() {
    this.render()
  },

  destroyed() {
    document.removeEventListener("selectionchange", this.onSelectionChange)
    document.removeEventListener("click", this.onDocClick)
    document.removeEventListener("keydown", this.onKey)
  },

  render() {
    this.closePopover()
    this.markers = parse(this.el.dataset.markers, [])
    this.active = this.el.dataset.activeMarker || null
    this.el.classList.toggle("marking", !!this.active)

    this.el.querySelectorAll(".marker-target").forEach((wrapper) => {
      strip(wrapper)
      const prose = wrapper.querySelector(".prose")
      const pins = []
      this.markers.filter((m) => belongs(m, wrapper)).forEach((m) => {
        if (m.target === "text" && prose) {
          if (!highlight(prose, m)) pins.push({...m, orphan: true})
        } else {
          pins.push(m)
        }
      })
      renderPins(wrapper, pins, this.icons)
    })
    this.tryOpenPendingNote()
  },

  // A non-collapsed selection inside one section's prose, with a marker in
  // hand, becomes a text marker.
  captureSelection() {
    if (!this.active || this.busy) return
    const sel = window.getSelection()
    if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return

    const range = sel.getRangeAt(0)
    const node = range.commonAncestorContainer
    const el = node.nodeType === 1 ? node : node.parentElement
    const prose = el && el.closest(".prose")
    if (!prose || !this.el.contains(prose)) return
    const wrapper = prose.closest(".marker-target")
    if (!wrapper) return

    // Offset of the selection start within the section's text. Range.toString
    // and textContent concatenate the same text nodes, so they agree.
    const pre = range.cloneRange()
    pre.selectNodeContents(prose)
    pre.setEnd(range.startContainer, range.startOffset)
    let start = pre.toString().length
    let quote = range.toString()
    start += quote.length - quote.trimStart().length
    quote = quote.trim()
    if (!quote) return
    if (quote.length > MAX_QUOTE) quote = quote.slice(0, MAX_QUOTE)

    const text = prose.textContent
    const end = start + quote.length
    const payload = {
      kind: this.active,
      target: "text",
      quote,
      prefix: text.slice(Math.max(0, start - CONTEXT), start),
      suffix: text.slice(end, end + CONTEXT),
      section_kind: wrapper.dataset.sectionKind,
      section_position: wrapper.dataset.sectionPosition,
    }

    this.busy = true
    this.selectedAt = Date.now()
    const release = () => { this.busy = false }
    this.pushEvent("marker_add", payload, (reply) => {
      release()
      this.afterAdd(payload, reply)
    })
    setTimeout(release, 2000)
    sel.removeAllRanges()
  },

  handleClick(e) {
    // Inside the options popover: only its Remove button does anything.
    const inPopover = e.target.closest(".marker-popover")
    if (inPopover) {
      if (e.target.closest(".marker-note-save")) {
        this.saveNote()
      } else if (e.target.closest(".marker-note-cancel")) {
        this.cancelEditor()
      } else if (e.target.closest(".marker-popover-edit")) {
        const id = inPopover.dataset.markerId
        const m = this.markers.find((x) => String(x.id) === String(id))
        const target = this.findMark(id)
        if (m && target) this.openNoteEditor(target, m)
      } else if (e.target.closest(".marker-popover-remove")) {
        this.pushEvent("marker_remove", {id: inPopover.dataset.markerId})
        this.closePopover()
      }
      return
    }

    // Tapping a highlight or pin shows its options; it never removes outright.
    const existing = e.target.closest("mark.marker, .marker-pin")
    if (existing && this.el.contains(existing)) {
      e.preventDefault()
      this.openPopover(existing)
      return
    }
    if (!this.active) return
    if (Date.now() - this.selectedAt < CLICK_AFTER_SELECT_MS) return
    const sel = window.getSelection()
    if (sel && !sel.isCollapsed) return
    if (e.target.closest("a, button, .marker-tray")) return

    const wrapper = e.target.closest(".marker-target")
    if (!wrapper || !this.el.contains(wrapper)) return

    const payload = {
      kind: this.active,
      section_kind: wrapper.dataset.sectionKind,
      section_position: wrapper.dataset.sectionPosition,
    }
    const onFigure = !!e.target.closest("figure")
    if (wrapper.dataset.mediaId && (wrapper.dataset.sectionKind === "illustration" || onFigure)) {
      payload.target = "illustration"
      payload.media_id = wrapper.dataset.mediaId
    } else {
      payload.target = "section"
    }
    this.pushEvent("marker_add", payload, (reply) => this.afterAdd(payload, reply))
  },

  // An "Other feedback" marker asks for its note as soon as it is placed. The
  // server replies with the id; the mark itself arrives with the next render,
  // so the editor opens from whichever of the two comes last.
  afterAdd(payload, reply) {
    if (payload.kind === "other" && reply && reply.id) {
      this.pendingNote = reply.id
      this.tryOpenPendingNote()
    }
  },

  tryOpenPendingNote() {
    if (!this.pendingNote) return
    const id = this.pendingNote
    const target = this.findMark(id)
    const m = this.markers.find((x) => String(x.id) === String(id))
    if (!target || !m) return
    this.pendingNote = null
    this.openNoteEditor(target, m)
  },

  findMark(id) {
    return this.el.querySelector(
      'mark.marker[data-marker-id="' + id + '"], .marker-pin[data-marker-id="' + id + '"]'
    )
  },

  // A small card under the tapped mark: which marker it is, whether the poet
  // has it yet, the note if it has one, and a Remove button.
  openPopover(target) {
    this.closePopover()
    const id = target.dataset.markerId
    const m = this.markers.find((x) => String(x.id) === String(id))
    if (!m) return

    const pop = this.newPopover(m)
    const label = document.createElement("span")
    label.className = "marker-popover-label"
    label.textContent = m.label
    const status = document.createElement("span")
    status.className = "marker-popover-note"
    status.textContent = m.sent ? "sent to your poet" : "waiting to be sent"
    pop.append(label, status)

    if (m.kind === "other") {
      const text = document.createElement("span")
      text.className = "marker-popover-note-text"
      text.textContent = m.note ? "“" + m.note + "”" : "no note yet"
      const edit = document.createElement("button")
      edit.type = "button"
      edit.className = "marker-popover-edit"
      edit.textContent = m.note ? "Edit" : "Write it"
      pop.append(text, edit)
    }

    const remove = document.createElement("button")
    remove.type = "button"
    remove.className = "marker-popover-remove"
    remove.textContent = "Remove"
    pop.append(remove)
    this.showPopover(pop, target)
  },

  // Text box for the note on an "Other feedback" marker.
  openNoteEditor(target, m) {
    this.closePopover()
    const pop = this.newPopover(m)
    pop.dataset.editor = "1"

    const label = document.createElement("span")
    label.className = "marker-popover-label"
    label.textContent = "Tell your poet"
    const input = document.createElement("input")
    input.type = "text"
    input.className = "marker-note-input"
    input.maxLength = 500
    input.placeholder = "What would you change, or want more of?"
    input.value = m.note || ""
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") { e.preventDefault(); this.saveNote() }
    })
    const save = document.createElement("button")
    save.type = "button"
    save.className = "marker-note-save"
    save.textContent = "Save"
    const cancel = document.createElement("button")
    cancel.type = "button"
    cancel.className = "marker-popover-remove marker-note-cancel"
    cancel.textContent = "Cancel"
    pop.append(label, input, save, cancel)
    this.showPopover(pop, target)
    input.focus()
  },

  saveNote() {
    const pop = this.popover
    if (!pop || !pop.dataset.editor) return
    const note = pop.querySelector(".marker-note-input").value.trim()
    if (!note) return this.cancelEditor()
    this.pushEvent("marker_note", {id: pop.dataset.markerId, note})
    this.closePopover()
  },

  // Backing out of a note that was never written removes the marker: an
  // "Other feedback" mark with nothing to say is not feedback.
  cancelEditor() {
    const pop = this.popover
    if (!pop || !pop.dataset.editor) return
    const m = this.markers.find((x) => String(x.id) === String(pop.dataset.markerId))
    if (m && !m.note) this.pushEvent("marker_remove", {id: pop.dataset.markerId})
    this.closePopover()
  },

  // Tapping away from the editor keeps what was typed.
  finishEditor() {
    const pop = this.popover
    if (!pop || !pop.dataset.editor) return
    if (pop.querySelector(".marker-note-input").value.trim()) this.saveNote()
    else this.cancelEditor()
  },

  newPopover(m) {
    const pop = document.createElement("div")
    pop.className = "marker-popover marker-" + m.kind
    pop.dataset.markerId = m.id
    return pop
  },

  showPopover(pop, target) {
    this.el.appendChild(pop)
    const art = this.el.getBoundingClientRect()
    const box = target.getBoundingClientRect()
    const left = Math.max(0, Math.min(box.left - art.left, art.width - pop.offsetWidth - 8))
    pop.style.top = (box.bottom - art.top + 6) + "px"
    pop.style.left = left + "px"
    this.popover = pop
    this.popoverOpenedAt = Date.now()
  },

  closePopover() {
    if (this.popover) {
      this.popover.remove()
      this.popover = null
    }
  },
}

// -- matching markers to wrappers --

function belongs(m, wrapper) {
  const d = wrapper.dataset
  if (m.target === "illustration") return d.mediaId != null && d.mediaId === String(m.media_id)
  if (d.sectionPosition == null) return false
  return d.sectionKind === m.section_kind && d.sectionPosition === String(m.section_position)
}

// -- painting --

function strip(wrapper) {
  wrapper.querySelectorAll("mark.marker").forEach((mark) => {
    mark.replaceWith(...mark.childNodes)
  })
  wrapper.querySelectorAll(".marker-pins").forEach((pins) => pins.remove())
  wrapper.normalize()
}

// Wraps the marker's quote in <mark>s. Returns false when the quote is no
// longer in the text (the poet revised it away).
function highlight(prose, m) {
  if (!m.quote) return false
  const text = prose.textContent
  const start = locate(text, m)
  if (start < 0) return false
  const end = start + m.quote.length

  segmentsFor(prose, start, end).reverse().forEach(({node, a, b}) => {
    if (b < node.length) node.splitText(b)
    let target = node
    if (a > 0) target = node.splitText(a)
    const mark = document.createElement("mark")
    mark.className = "marker marker-" + m.kind + (m.sent ? " marker-sent" : "")
    mark.dataset.markerId = m.id
    mark.title = m.label + " (tap for options)"
    target.parentNode.insertBefore(mark, target)
    mark.appendChild(target)
  })
  return true
}

// Where the quote sits in the text. Several hits are told apart by how much of
// the remembered context around them still matches.
function locate(text, m) {
  const hits = []
  let i = text.indexOf(m.quote)
  while (i >= 0) {
    hits.push(i)
    i = text.indexOf(m.quote, i + 1)
  }
  if (hits.length === 0) return -1
  if (hits.length === 1) return hits[0]
  let best = hits[0]
  let bestScore = -1
  hits.forEach((h) => {
    const score =
      commonSuffix(text.slice(0, h), m.prefix || "") +
      commonPrefix(text.slice(h + m.quote.length), m.suffix || "")
    if (score > bestScore) { best = h; bestScore = score }
  })
  return best
}

function commonPrefix(a, b) {
  let n = 0
  while (n < a.length && n < b.length && a[n] === b[n]) n++
  return n
}

function commonSuffix(a, b) {
  let n = 0
  while (n < a.length && n < b.length && a[a.length - 1 - n] === b[b.length - 1 - n]) n++
  return n
}

// The text nodes overlapping [start, end) with local slice bounds.
function segmentsFor(root, start, end) {
  const out = []
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT)
  let pos = 0
  let node
  while ((node = walker.nextNode())) {
    const len = node.length
    const nStart = pos
    const nEnd = pos + len
    if (nEnd > start && nStart < end) {
      out.push({node, a: Math.max(0, start - nStart), b: Math.min(len, end - nStart)})
    }
    pos = nEnd
  }
  return out
}

function renderPins(wrapper, pins, icons) {
  if (pins.length === 0) return
  const box = document.createElement("span")
  box.className = "marker-pins"
  pins.forEach((m) => {
    const pin = document.createElement("button")
    pin.type = "button"
    pin.className =
      "marker-pin marker-" + m.kind +
      (m.sent ? " marker-sent" : "") +
      (m.orphan ? " marker-orphan" : "")
    pin.dataset.markerId = m.id
    pin.title = m.label + (m.orphan ? " (this passage has since changed)" : "") + ". Tap for options."
    const icon = document.createElement("span")
    icon.className = (icons[m.kind] || "hero-bookmark-mini") + " marker-pin-icon"
    pin.appendChild(icon)
    box.appendChild(pin)
  })
  wrapper.appendChild(box)
}

// -- utils --

function parse(json, fallback) {
  try {
    return json ? JSON.parse(json) : fallback
  } catch (_e) {
    return fallback
  }
}

function debounce(fn, ms) {
  let t
  return () => {
    clearTimeout(t)
    t = setTimeout(fn, ms)
  }
}

export default Markers
