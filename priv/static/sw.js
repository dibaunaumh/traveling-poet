// Traveling Poet service worker.
//
// Exists only to receive Web Push messages while the app is closed and turn
// them into a notification; there is no offline caching here. Registered
// lazily by the WebPush LiveView hook the first time a page that offers
// notifications loads.

self.addEventListener("install", () => self.skipWaiting())
self.addEventListener("activate", event => event.waitUntil(self.clients.claim()))

self.addEventListener("push", event => {
  let data = {}
  try {
    data = event.data ? event.data.json() : {}
  } catch (_e) {
    data = {body: event.data ? event.data.text() : ""}
  }

  const title = data.title || "Traveling Poet"
  const options = {
    body: data.body || "",
    icon: data.icon || "/images/icon-192.png",
    badge: "/images/icon-192.png",
    tag: data.tag || undefined,
    data: {url: data.url || "/journal"},
  }

  event.waitUntil(self.registration.showNotification(title, options))
})

self.addEventListener("notificationclick", event => {
  event.notification.close()
  const url = new URL((event.notification.data && event.notification.data.url) || "/journal", self.location.origin).href

  event.waitUntil(
    self.clients.matchAll({type: "window", includeUncontrolled: true}).then(clients => {
      // Reuse an open window of the app (the installed PWA, typically)
      // rather than spawning a second one.
      for (const client of clients) {
        if (new URL(client.url).origin === self.location.origin && "focus" in client) {
          if ("navigate" in client) client.navigate(url)
          return client.focus()
        }
      }
      return self.clients.openWindow(url)
    })
  )
})
