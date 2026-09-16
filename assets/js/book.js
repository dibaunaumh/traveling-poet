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

// Every drawing is redrawn once, before layout, into a JPEG no larger than
// it will ever print (about 300 dpi on A4). Where the page blends a drawing
// into the paper (mix-blend-mode: multiply), the blend is done here, onto
// the paper colour, so the pixels already carry it. Two reasons, both about
// the PDF the poet's sprite prints: a PDF viewer such as Preview draws
// blended images as blank boxes, and full-size PNG drawings made an 80 MB
// file. Same-origin images only (/media), so the canvas is never tainted.
const PAPER = "#fdf8ec"
const MAX_EDGE = 1600

const bakeImages = async (root) => {
  const images = [...root.querySelectorAll("img")].filter((img) => {
    const src = img.getAttribute("src") || ""
    return src.startsWith("/") && !src.startsWith("//")
  })

  await Promise.all(images.map(async (img) => {
    try {
      img.loading = "eager"
      if (!img.complete || img.naturalWidth === 0) await img.decode()
      const w = img.naturalWidth, h = img.naturalHeight
      if (!w || !h) return

      const scale = Math.min(1, MAX_EDGE / Math.max(w, h))
      const canvas = document.createElement("canvas")
      canvas.width = Math.round(w * scale)
      canvas.height = Math.round(h * scale)
      const ctx = canvas.getContext("2d")

      const blends = getComputedStyle(img).mixBlendMode === "multiply"
      ctx.fillStyle = blends ? PAPER : "#ffffff"
      ctx.fillRect(0, 0, canvas.width, canvas.height)
      ctx.globalCompositeOperation = blends ? "multiply" : "source-over"
      ctx.drawImage(img, 0, 0, canvas.width, canvas.height)

      img.src = canvas.toDataURL("image/jpeg", 0.86)
      img.dataset.baked = "true"
      await img.decode()
    } catch (e) {
      // a drawing that will not load stays as it is; the page still lays out
      console.warn("book: could not prepare a drawing for print", img.src, e)
    }
  }))
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
    await bakeImages(book)
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
