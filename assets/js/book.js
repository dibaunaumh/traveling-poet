// The book page: the journal laid out for paper.
//
// A separate bundle from app.js on purpose: paged.js is ~900 KB unminified
// and only this page needs it. It turns the flowing document into fixed
// pages with running heads and page numbers, and resolves the TOC and index
// page references (target-counter), which Chrome alone does not.
//
// The run is driven from here rather than by the polyfill's auto mode:
// - the notebook hands are web fonts, and paged.js measures text to place
//   breaks, so it must not start before document.fonts.ready;
// - only this app's stylesheet and the inline @page size are handed to it,
//   never whatever a browser extension injected;
// - a failure leaves the flowing document readable and says so in the
//   toolbar, instead of a blank page.
import "./book_config.js"
import "../vendor/pagedjs/paged.polyfill.js"

const ready = (fn) =>
  document.readyState === "loading" ? document.addEventListener("DOMContentLoaded", fn) : fn()

// paged.js takes the stylesheets over (fetches, rewrites and re-injects
// them), so the originals come out of the document; they are kept so the
// flowing page can have them back if pagination fails.
const takeStylesheets = () => {
  const sheets = []
  const removed = []
  document.querySelectorAll('link[rel="stylesheet"][href*="/assets/css/"]').forEach((link) => {
    sheets.push(link.href)
    removed.push(link)
    link.remove()
  })
  document.querySelectorAll("style[data-book-page]").forEach((style, i) => {
    sheets.push({[`book-inline-${i}`]: style.textContent})
    removed.push(style)
    style.remove()
  })
  return {sheets, restore: () => removed.forEach((el) => document.head.appendChild(el))}
}

const layOut = async () => {
  const book = document.getElementById("book")
  const status = document.getElementById("book-status")
  const printButton = document.getElementById("book-print")
  if (!book || !window.Paged) return

  const done = (text) => {
    if (status) {
      status.textContent = text
      status.classList.remove("book-status-busy")
    }
    if (printButton) printButton.disabled = false
  }

  let styles = null

  try {
    if (document.fonts && document.fonts.ready) await document.fonts.ready
    const previewer = new window.Paged.Previewer()
    styles = takeStylesheets()
    // The source leaves the document (as the polyfill's own auto mode does
    // with the body): paged.js clones from it into the pages it renders.
    const source = document.createElement("template")
    source.content.appendChild(book)
    const flow = await previewer.preview(source.content, styles.sheets, document.body)
    document.body.dataset.bookRendered = "true"
    document.body.dataset.bookPages = String(flow.total)
    done(`${flow.total} pages`)
  } catch (e) {
    console.error("book: pagination failed, printing the flowing page instead", e)
    if (styles) styles.restore()
    if (!document.getElementById("book")) document.body.prepend(book)
    document.body.dataset.bookRendered = "failed"
    done("Page numbers unavailable")
  }
}

ready(() => {
  const printButton = document.getElementById("book-print")
  if (printButton) printButton.addEventListener("click", () => window.print())
  // ?paged=0 leaves the flowing page as it is (debugging a layout rule)
  if (new URLSearchParams(location.search).get("paged") !== "0") layOut()
})
