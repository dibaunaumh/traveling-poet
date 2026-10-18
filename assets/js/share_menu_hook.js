// The share menu beside a page's heading (ShareComponents.share_menu). The
// phone's share sheet is offered where the browser has one; "Copy link"
// writes the page's address to the clipboard and says so for a moment.
// Everything else in the menu is a plain link.
const COPIED_MS = 1500

const ShareMenu = {
  mounted() {
    const el = this.el
    const data = () => ({title: el.dataset.title, text: el.dataset.text, url: el.dataset.url})
    const close = () => el.removeAttribute("open")

    const native = el.querySelector("[data-share-native]")
    if (native && typeof navigator.share === "function") native.hidden = false

    el.querySelector("[data-share]")?.addEventListener("click", () => {
      close()
      navigator.share(data()).catch(() => {})
    })

    el.querySelector("[data-copy]")?.addEventListener("click", async () => {
      const label = el.querySelector("[data-copy-label]")
      try {
        await copy(data().url)
        if (label) label.textContent = "Copied"
      } catch (_e) {
        if (label) label.textContent = "Could not copy"
      }
      setTimeout(() => {
        if (label) label.textContent = "Copy link"
        close()
      }, COPIED_MS)
    })
  },
}

async function copy(text) {
  if (navigator.clipboard?.writeText) return navigator.clipboard.writeText(text)
  // An old WebView: a selection and the editing command.
  const input = document.createElement("textarea")
  input.value = text
  input.setAttribute("readonly", "")
  input.style.position = "fixed"
  input.style.opacity = "0"
  document.body.appendChild(input)
  input.select()
  const ok = document.execCommand("copy")
  input.remove()
  if (!ok) throw new Error("copy failed")
}

export default ShareMenu
