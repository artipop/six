// The walk's service worker: it shows a notification when asked, and a click on one opens a tab.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", event => event.waitUntil(self.clients.claim()));
self.addEventListener("message", event => {
  if (event.data && event.data.show)
    event.waitUntil(self.registration.showNotification("From the service worker", {
      body: "Click me: a tab should open on the history station.", icon: "icon.png", tag: "walk-sw" }));
});
self.addEventListener("notificationclick", event => {
  event.notification.close();
  event.waitUntil((async () => {
    const opened = await self.clients.openWindow("history.html?from=notification").catch(e => String(e));
    for (const client of await self.clients.matchAll({ type: "window" }))
      client.postMessage({ clicked: true, opened: opened && opened.url ? opened.url : String(opened) });
  })());
});
