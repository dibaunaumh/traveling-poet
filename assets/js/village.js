// The global village: every place the poets found, by subject.
//
// A zoomable treemap, one level at a time: the 12 subjects, then a subject's
// subtopics, then their topics, each tile sized by how many places it holds;
// at a topic, the places themselves as a grid of tiles. A breadcrumb goes
// back up. A place under two topics appears under both.
//
// Data (Discover.village/0): {tree: [{slug,name,children:[...]}], places:
// [{id,ids,name,city,topics:[path],date,found_by}], finds: [{id,name,kind,
// topics,date,found_by}]}, newest first; fetched by the hook only when the
// village is first opened. Places and finds (talks, papers, recordings...)
// share the tree; each is an "item" keyed "p<id>" or "f<id>", since a place
// and a find can have the same id.
// Topic paths are "subject/subtopic/topic"; a node's path is its prefix.
//
// The Village owns only its own box. The DiscoverMap hook drives it: tells it
// where to focus, which place to highlight, and asks it for the tour's order.

// One hue per subject, far enough apart to tell neighbours apart; deeper
// tiles keep their subject's hue. A subject not listed takes the fallback.
const HUES = {
  art: 330,
  "crafts-and-design": 28,
  "music-and-performance": 275,
  "literature-and-ideas": 215,
  "history-and-heritage": 45,
  "faith-and-spirit": 250,
  "architecture-and-cityscape": 195,
  "nature-and-outdoors": 125,
  "food-and-drink": 8,
  "markets-and-shopping": 58,
  "festivals-and-community": 300,
  "science-industry-and-play": 170,
}
const hueOf = (slug) => HUES[slug] ?? 200

// Squarified treemap (Bruls, Huizing, van Wijk): lays `items` (each with a
// numeric `value`) into the rectangle {x, y, w, h}; returns [{item, x, y, w, h}].
export function squarify(items, rect) {
  const total = items.reduce((s, i) => s + i.value, 0)
  if (total <= 0 || items.length === 0) return []
  const scale = (rect.w * rect.h) / total
  const queue = items
    .filter((i) => i.value > 0)
    .map((i) => ({ item: i, area: i.value * scale }))
    .sort((a, b) => b.area - a.area)
  const out = []
  let { x, y, w, h } = rect

  const worst = (row, side) => {
    const sum = row.reduce((s, r) => s + r.area, 0)
    const max = Math.max(...row.map((r) => r.area))
    const min = Math.min(...row.map((r) => r.area))
    return Math.max((side * side * max) / (sum * sum), (sum * sum) / (side * side * min))
  }

  let row = []
  while (queue.length) {
    const side = Math.min(w, h)
    const next = queue[0]
    if (row.length === 0 || worst(row.concat(next), side) <= worst(row, side)) {
      row.push(queue.shift())
      continue
    }
    ;({ x, y, w, h } = layRow(row, { x, y, w, h }, out))
    row = []
  }
  if (row.length) layRow(row, { x, y, w, h }, out)
  return out
}

// Lays one row along the shorter side and returns the space left.
function layRow(row, { x, y, w, h }, out) {
  const sum = row.reduce((s, r) => s + r.area, 0)
  if (w >= h) {
    const rw = sum / h
    let cy = y
    row.forEach((r) => {
      const rh = r.area / rw
      out.push({ item: r.item, x, y: cy, w: rw, h: rh })
      cy += rh
    })
    return { x: x + rw, y, w: w - rw, h }
  } else {
    const rh = sum / w
    let cx = x
    row.forEach((r) => {
      const rw = r.area / rh
      out.push({ item: r.item, x: cx, y, w: rw, h: rh })
      cx += rw
    })
    return { x, y: y + rh, w, h: h - rh }
  }
}

const esc = (s) =>
  String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c])

// What a find is, in a word, as GuideComponents.humanize_category/1 says it.
const FIND_KINDS = { screen: "Film or series", outing: "Outdoors" }
const findKind = (kind) =>
  FIND_KINDS[kind] || (kind ? kind.charAt(0).toUpperCase() + kind.slice(1) : "Find")

export class Village {
  constructor(el, { onItem, onFocus }) {
    this.el = el
    this.onItem = onItem
    this.onFocus = onFocus
    this.focus = ""
    this.current = null
    this.el.innerHTML = `<nav class="village-crumbs" aria-label="Subjects"></nav><div class="village-tiles"></div>`
    this.crumbs = this.el.querySelector(".village-crumbs")
    this.tiles = this.el.querySelector(".village-tiles")

    this.el.addEventListener("click", (e) => {
      const item = e.target.closest("[data-village-item]")
      if (item) return this.onItem(item.dataset.villageItem)
      const node = e.target.closest("[data-village-node]")
      if (node) return this.setFocus(node.dataset.villageNode, { user: true })
    })
  }

  load(data) {
    this.places = (data && data.places) || []
    this.finds = (data && data.finds) || []
    this.items = this.places
      .map((p) => ({ ...p, key: `p${p.id}`, type: "place" }))
      .concat(this.finds.map((f) => ({ ...f, key: `f${f.id}`, type: "find" })))
    this.nodes = new Map()
    this.nodes.set("", { path: "", name: "All subjects", depth: 0, children: [], hue: null })
    ;((data && data.tree) || []).forEach((a) => {
      const hue = hueOf(a.slug)
      this.addNode(a.slug, a.name, "", 1, hue)
      a.children.forEach((b) => {
        this.addNode(`${a.slug}/${b.slug}`, b.name, a.slug, 2, hue)
        b.children.forEach((c) => this.addNode(`${a.slug}/${b.slug}/${c.slug}`, c.name, `${a.slug}/${b.slug}`, 3, hue))
      })
    })
    // How many places and finds sit under each node (each counts once).
    this.nodes.forEach((n) => (n.count = 0))
    this.items.forEach((p) => {
      const seen = new Set()
      p.topics.forEach((t) => {
        const parts = t.split("/")
        for (let d = 1; d <= parts.length; d++) seen.add(parts.slice(0, d).join("/"))
      })
      seen.add("")
      seen.forEach((path) => {
        const n = this.nodes.get(path)
        if (n) n.count++
      })
    })
    if (!this.nodes.has(this.focus)) this.focus = ""
    this.render()
  }

  addNode(path, name, parent, depth, hue) {
    this.nodes.set(path, { path, name, depth, children: [], hue })
    this.nodes.get(parent).children.push(path)
  }

  name(path) {
    const n = this.nodes && this.nodes.get(path)
    return n ? n.name : ""
  }

  under(place, path) {
    return path === "" || place.topics.some((t) => t === path || t.startsWith(path + "/"))
  }

  // Places only: what the world map can show.
  placesUnder(path) {
    return this.places.filter((p) => this.under(p, path))
  }

  itemsUnder(path) {
    return this.items.filter((p) => this.under(p, path))
  }

  // The tour's order under a subject, as item keys: newest first, one item
  // per child subject per round, so one busy subject cannot hold the tour.
  rotation(path = this.focus, cap = 40) {
    const node = this.nodes.get(path)
    if (!node) return []
    const groups = new Map()
    this.itemsUnder(path).forEach((p) => {
      const key = node.depth === 3 ? "" : node.children.find((c) => this.under(p, c)) || ""
      if (!groups.has(key)) groups.set(key, [])
      groups.get(key).push(p)
    })
    const lists = [...groups.values()]
    const out = []
    for (let round = 0; out.length < cap; round++) {
      const batch = lists.map((l) => l[round]).filter(Boolean)
      if (batch.length === 0) break
      batch.sort((a, b) => (a.date < b.date ? 1 : -1))
      out.push(...batch)
    }
    return out.slice(0, cap).map((p) => p.key)
  }

  setFocus(path, { user = false } = {}) {
    if (!this.nodes.has(path)) path = ""
    this.focus = path
    this.render()
    if (this.onFocus) this.onFocus(path, { user })
  }

  highlight(key) {
    this.current = key
    this.tiles.querySelectorAll(".is-current").forEach((el) => el.classList.remove("is-current"))
    if (key == null) return
    const place = this.items.find((p) => p.key === key)
    if (!place) return
    const node = this.nodes.get(this.focus)
    if (node.depth === 3) {
      const el = this.tiles.querySelector(`[data-village-item="${key}"]`)
      if (el) {
        el.classList.add("is-current")
        // Scroll the grid, never the page: scrollIntoView would move the
        // whole home page under a reader every time the tour turned.
        const box = this.tiles
        const top = el.offsetTop // .village-tiles is positioned: its offsetParent
        if (top < box.scrollTop || top + el.offsetHeight > box.scrollTop + box.clientHeight) {
          box.scrollTop = top - 8
        }
      }
      return
    }
    node.children.forEach((c) => {
      if (this.under(place, c)) {
        const el = this.tiles.querySelector(`[data-village-node="${CSS.escape(c)}"]`)
        if (el) el.classList.add("is-current")
      }
    })
  }

  render() {
    if (!this.nodes) return
    const node = this.nodes.get(this.focus)

    // Breadcrumb: every step back up, the current one last.
    const trail = []
    let path = this.focus
    while (true) {
      trail.unshift(path)
      if (path === "") break
      path = path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : ""
    }
    this.crumbs.innerHTML = trail
      .map((p, i) =>
        i === trail.length - 1
          ? `<span aria-current="page">${esc(this.name(p))} <small>${this.nodes.get(p).count}</small></span>`
          : `<button type="button" data-village-node="${esc(p)}">${esc(this.name(p))}</button>`
      )
      .join(`<span class="village-sep" aria-hidden="true">›</span>`)

    this.tiles.classList.toggle("is-grid", node.depth === 3)
    this.tiles.innerHTML = node.depth === 3 ? this.itemGrid(node) : this.treemap(node)
    if (this.current != null) this.highlight(this.current)
  }

  treemap(node) {
    const w = this.tiles.clientWidth || 600
    const h = this.tiles.clientHeight || 400
    const items = node.children
      .map((c) => this.nodes.get(c))
      .filter((c) => c.count > 0)
      .map((c) => ({ value: c.count, node: c }))
    if (items.length === 0) return `<p class="village-empty">Nothing here yet.</p>`

    return squarify(items, { x: 0, y: 0, w, h })
      .map(({ item, x, y, w: tw, h: th }) => {
        const n = item.node
        const small = tw < 90 || th < 44
        const light = n.depth === 1 ? 72 : n.depth === 2 ? 79 : 85
        return `<button type="button" class="village-tile${small ? " is-small" : ""}"
          data-village-node="${esc(n.path)}" title="${esc(n.name)}: ${n.count}"
          style="left:${x}px;top:${y}px;width:${tw}px;height:${th}px;--tile:hsl(${n.hue} 42% ${light}%)">
          <span class="village-tile-name">${esc(n.name)}</span>
          <span class="village-tile-count">${n.count}</span>
        </button>`
      })
      .join("")
  }

  // A topic's places and finds, newest first. A find says what it is (a
  // talk, an album) where a place says its city.
  itemGrid(node) {
    const items = this.itemsUnder(node.path)
    if (items.length === 0) return `<p class="village-empty">Nothing here yet.</p>`
    return items
      .map(
        (p) => `<button type="button" class="village-place${p.type === "find" ? " village-find" : ""}"
          data-village-item="${p.key}" style="--tile:hsl(${node.hue} 42% 90%)">
          <span class="village-place-name">${esc(p.name)}</span>
          <span class="village-place-where">${esc(p.type === "find" ? findKind(p.kind) : p.city || "")}</span>
          ${p.found_by > 1 ? `<span class="village-place-more">found by ${p.found_by} poets</span>` : ""}
        </button>`
      )
      .join("")
  }
}
