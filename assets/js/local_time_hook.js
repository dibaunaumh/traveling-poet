// Rewrites a server-rendered <time datetime="..."> (UTC) into the reader's
// own zone and words: "today around 8 PM", "tomorrow around 7 AM", or a
// weekday further out. The server text stays as the fallback.

const LocalTime = {
  mounted() { this.render() },
  updated() { this.render() },

  render() {
    const at = new Date(this.el.getAttribute("datetime"))
    if (isNaN(at)) return
    const now = new Date()
    const day = d => new Date(d.getFullYear(), d.getMonth(), d.getDate())
    const days = Math.round((day(at) - day(now)) / 86400000)
    const hour = at.toLocaleTimeString([], {hour: "numeric"})
    const when =
      days <= 0 ? "today" :
      days === 1 ? "tomorrow" :
      at.toLocaleDateString([], {weekday: "long"})
    this.el.textContent = `${when} around ${hour}`
    this.el.title = at.toLocaleString()
  },
}

export default LocalTime
