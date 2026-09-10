// SOCIAL_PLAN.md §4.5 — обработка Web Push на стороне Service Worker.
// Регистрируется отдельно от автогенерируемого Flutter flutter_service_worker.js
// (см. lib/services/push_registration_web.dart) — два independent Service
// Worker с разными путями/scope не конфликтуют в браузере.
//
// НЕПРОВЕРЕННОЕ: не запускался в браузере (нет инструмента для этого в среде,
// где написан) — API push/notificationclick стандартные и документированы,
// но живого прогона не было.

self.addEventListener('push', (event) => {
  let payload = { title: 'Clarify', body: 'У вас новое уведомление' };
  if (event.data) {
    try {
      payload = event.data.json();
    } catch (e) {
      payload.body = event.data.text();
    }
  }

  // Пути ОТНОСИТЕЛЬНЫЕ, а не от корня домена: с 08.09.2026 веб-версия живёт в
  // подпапке (vantra-labs.github.io/app/), и '/icons/...' указывал бы в корень
  // сайта, где иконок нет — уведомление приходило бы без картинки. В Service
  // Worker относительный путь считается от места самого воркера, то есть от
  // папки приложения, и одинаково верен и в корне, и в подпапке.
  event.waitUntil(
    self.registration.showNotification(payload.title || 'Clarify', {
      body: payload.body || '',
      icon: 'icons/Icon-192.png',
      badge: 'icons/Icon-192.png',
    })
  );
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then((windowClients) => {
      for (const client of windowClients) {
        if ('focus' in client) return client.focus();
      }
      // './' — папка приложения, а не корень домена: по клику на уведомление
      // должно открываться приложение, а не сайт-витрина вокруг него.
      if (clients.openWindow) return clients.openWindow('./');
    })
  );
});
