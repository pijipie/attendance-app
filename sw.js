/* =====================================================================
   SERVICE WORKER  v1  (version 0.9, push reminders)
   It does two things only:
     1. shows a reminder that arrives from the push service;
     2. when the reminder is tapped, brings the staff page forward (or opens it).
   It caches nothing: every page still comes fresh from the website.
   The words come from the database (push_due() in SQL file 16) and never
   carry a name or a staff code.
   ===================================================================== */
self.addEventListener("push", event => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch (e) { /* not JSON: show the plain words below */ }
  const title = data.title || "Kehadiran Staf";
  event.waitUntil(self.registration.showNotification(title, {
    body: data.body || "",
    icon: "logo.png",
    badge: "logo.png",
    tag: data.kind || "reminder",      // a newer reminder of the same kind replaces the older one
    data: { url: "./" }
  }));
});

self.addEventListener("notificationclick", event => {
  event.notification.close();
  const target = new URL((event.notification.data && event.notification.data.url) || "./", self.registration.scope).href;
  event.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(windows => {
    for (const w of windows) {
      if (new URL(w.url).pathname === new URL(target).pathname && "focus" in w) return w.focus();
    }
    return self.clients.openWindow ? self.clients.openWindow(target) : undefined;
  }));
});
