import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Регистрация Web Push-подписки (SOCIAL_PLAN.md §4.5) — Service Worker
/// (web/push_sw.js) + PushManager + сохранение подписки в Supabase
/// `push_subscriptions` (сама таблица применяется вручную,
/// backend/clarify-backend/sql/push_subscriptions.sql).
///
/// PushManager.subscribe() вызывается через dart:js_interop
/// (dart:js_util в этой версии Dart SDK удалён), а не через Map-based
/// dart:html API: dart:html конвертирует Map в JS-объект через
/// structured-clone сериализацию, которая не сохраняет applicationServerKey
/// как настоящий Uint8Array — браузер получал не-BufferSource и падал с
/// "applicationServerKey is not properly base64url-encoded".
///
/// НЕПРОВЕРЕННОЕ: код не запускался в браузере вживую после этого фикса —
/// нет инструмента для этого в среде выполнения, где написан.
class PushRegistrationWeb {
  static Future<String?> register(String vapidPublicKeyBase64Url) async {
    try {
      final serviceWorkerContainer = html.window.navigator.serviceWorker;
      if (serviceWorkerContainer == null) {
        return 'Service Worker не поддерживается браузером';
      }

      // Путь ОТНОСИТЕЛЬНЫЙ, а не от корня домена. С 08.09.2026 веб-версия
      // живёт не в корне (vantra-labs.github.io/app/), и '/push_sw.js' указывал
      // бы на корень сайта, где этого файла нет — регистрация падала бы с 404,
      // а вместе с ней и вся подписка на уведомления. Относительный путь
      // одинаково верен и в корне, и в подпапке, и заодно задаёт область
      // видимости воркера по месту приложения, а не на весь сайт.
      final registration = await serviceWorkerContainer.register('push_sw.js');

      final permission = await html.Notification.requestPermission();
      if (permission != 'granted') {
        return 'Разрешение на уведомления не выдано';
      }

      final pushManager = registration.pushManager;
      if (pushManager == null) {
        return 'Push API не поддерживается этим браузером';
      }

      final applicationServerKey = _urlBase64ToUint8List(
        vapidPublicKeyBase64Url,
      );
      final options = JSObject();
      options.setProperty('userVisibleOnly'.toJS, true.toJS);
      options.setProperty(
        'applicationServerKey'.toJS,
        applicationServerKey.toJS,
      );

      final subscriptionPromise = (pushManager as JSObject)
          .callMethod<JSPromise<JSObject>>('subscribe'.toJS, options);
      final subscription = await subscriptionPromise.toDart;

      final endpoint = subscription
          .getProperty<JSString?>('endpoint'.toJS)
          ?.toDart;
      final p256dhBuffer = subscription
          .callMethod<JSArrayBuffer?>('getKey'.toJS, 'p256dh'.toJS)
          ?.toDart;
      final authBuffer = subscription
          .callMethod<JSArrayBuffer?>('getKey'.toJS, 'auth'.toJS)
          ?.toDart;
      if (endpoint == null || p256dhBuffer == null || authBuffer == null) {
        return 'Не удалось получить ключи подписки';
      }

      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return 'Не авторизован';

      await Supabase.instance.client.from('push_subscriptions').upsert({
        'user_id': user.id,
        'endpoint': endpoint,
        'p256dh': _base64UrlEncode(Uint8List.view(p256dhBuffer)),
        'auth_key': _base64UrlEncode(Uint8List.view(authBuffer)),
      }, onConflict: 'endpoint');

      return null; // успех
    } catch (e) {
      return 'Ошибка: $e';
    }
  }

  /// Отписка от Web Push — снимает подписку в браузере и удаляет её запись
  /// в `push_subscriptions`, чтобы backend (`/internal/check-due-tasks`)
  /// перестал слать push на это устройство.
  static Future<String?> unregister() async {
    try {
      final serviceWorkerContainer = html.window.navigator.serviceWorker;
      if (serviceWorkerContainer == null) return null;

      // Тот же относительный путь, что и при регистрации выше — иначе отписка
      // искала бы воркера не там, где он на самом деле зарегистрирован.
      final registration = await serviceWorkerContainer.getRegistration('push_sw.js');

      final pushManager = registration.pushManager;
      if (pushManager == null) return null;

      final subscriptionPromise = (pushManager as JSObject)
          .callMethod<JSPromise<JSObject?>>('getSubscription'.toJS);
      final subscription = await subscriptionPromise.toDart;
      if (subscription == null) return null;

      final endpoint = subscription
          .getProperty<JSString?>('endpoint'.toJS)
          ?.toDart;

      final unsubscribePromise = subscription
          .callMethod<JSPromise<JSBoolean>>('unsubscribe'.toJS);
      await unsubscribePromise.toDart;

      if (endpoint != null) {
        final user = Supabase.instance.client.auth.currentUser;
        if (user != null) {
          await Supabase.instance.client
              .from('push_subscriptions')
              .delete()
              .eq('endpoint', endpoint);
        }
      }

      return null; // успех
    } catch (e) {
      return 'Ошибка: $e';
    }
  }

  static Uint8List _urlBase64ToUint8List(String base64String) {
    final padding = '=' * ((4 - base64String.length % 4) % 4);
    final normalized = (base64String + padding)
        .replaceAll('-', '+')
        .replaceAll('_', '/');
    return base64Decode(normalized);
  }

  static String _base64UrlEncode(Uint8List bytes) {
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}
