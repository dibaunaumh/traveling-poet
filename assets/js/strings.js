// Interface words the page's scripts write themselves (card-101). The server
// puts them on the page in the reader's language (TravelingPoetWeb.I18n
// .js_strings/0, in the root and book layouts); `{name}` placeholders are
// filled here. The English fallback keeps a page without them working.
// A value that is not a sentence (a list of month names, a map of kinds), as
// the server sent it, or the fallback.
export function tv(key, fallback) {
  const strings = window.tpStrings || {}
  return key in strings ? strings[key] : fallback
}

export function t(key, fallback, vars = {}) {
  const strings = window.tpStrings || {}
  const s = strings[key] || fallback
  return s.replace(/\{(\w+)\}/g, (whole, name) => (name in vars ? String(vars[name]) : whole))
}
