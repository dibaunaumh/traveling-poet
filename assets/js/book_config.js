// Read by paged.polyfill.js the moment it loads, so this module must be
// imported ahead of it (module evaluation follows import order). The
// polyfill would otherwise paginate on its own, sweeping up every stylesheet
// on the page (browser extensions inject theirs too) and hiding any error
// behind a blank page. book.js drives the run itself instead.
window.PagedConfig = {auto: false}
