import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/ics.dart';
import '../core/log.dart';

/// Подписка на внешний календарь: хранение, загрузка по ссылке и перенос
/// событий в задачи.
///
/// Разбор .ics живёт отдельно, в `core/ics.dart`, и ничего не знает ни про
/// сеть, ни про базу. Здесь остаётся только то, что без них не работает.
///
/// Таблицы: `calendar_subscriptions` и колонки `tasks.external_uid` /
/// `tasks.external_source` — см. `backend/clarify-backend/sql/calendar_subscriptions.sql`.
class CalendarSubscriptionService {
  CalendarSubscriptionService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  SupabaseClient get _db => Supabase.instance.client;

  /// Сколько ждать ответа от чужого сервера. Расписание — не та вещь, ради
  /// которой стоит держать пользователя в ожидании полминуты.
  static const Duration _timeout = Duration(seconds: 20);

  /// Больше этого не читаем: подсунутый «календарь» на сотни мегабайт не
  /// должен съесть память приложения.
  static const int _maxBytes = 5 * 1024 * 1024;

  /// Список подписок текущего пользователя.
  Future<List<Map<String, dynamic>>> fetchSubscriptions() async {
    final user = _db.auth.currentUser;
    if (user == null) return const [];
    final rows = await _db
        .from('calendar_subscriptions')
        .select()
        .eq('user_id', user.id)
        .order('created_at');
    return List<Map<String, dynamic>>.from(rows as List);
  }

  /// Добавляет подписку. Возвращает созданную строку.
  ///
  /// Повторная подписка на тот же адрес отсекается уникальным индексом в базе,
  /// а не проверкой на клиенте: два открытых окна иначе создадут дубль.
  Future<Map<String, dynamic>?> addSubscription({
    required String url,
    String? name,
    String? folder,
    bool importNotes = true,
  }) async {
    final user = _db.auth.currentUser;
    if (user == null) return null;

    final normalized = normalizeUrl(url);
    if (normalized == null) {
      throw const FormatException('Ссылка на календарь выглядит неверной');
    }

    final row = await _db
        .from('calendar_subscriptions')
        .insert({
          'user_id': user.id,
          'url': normalized,
          'name': (name != null && name.trim().isNotEmpty) ? name.trim() : null,
          'folder': folder,
          'import_notes': importNotes,
        })
        .select()
        .single();
    return Map<String, dynamic>.from(row);
  }

  Future<void> deleteSubscription(int id) async {
    await _db.from('calendar_subscriptions').delete().eq('id', id);
  }

  Future<void> setEnabled(int id, bool enabled) async {
    await _db.from('calendar_subscriptions').update({'enabled': enabled}).eq('id', id);
  }

  /// Приводит ссылку к виду, который можно запросить.
  ///
  /// Календари часто дают адрес со схемой `webcal://` — это тот же HTTPS,
  /// просто с намёком «открой в календаре». Без подмены схемы запрос
  /// не уйдёт вовсе.
  static String? normalizeUrl(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return null;
    if (value.startsWith('webcal://')) {
      value = 'https://${value.substring('webcal://'.length)}';
    }
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasAuthority) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    return uri.toString();
  }

  /// Скачивает и разбирает календарь по ссылке.
  Future<IcsCalendar> loadCalendar(String url) async {
    final normalized = normalizeUrl(url);
    if (normalized == null) {
      throw const FormatException('Ссылка на календарь выглядит неверной');
    }

    final response = await _client
        .get(Uri.parse(normalized), headers: const {'Accept': 'text/calendar, text/plain, */*'})
        .timeout(_timeout);

    if (response.statusCode != 200) {
      throw http.ClientException(
        'Сервер календаря ответил ${response.statusCode}',
        Uri.parse(normalized),
      );
    }
    if (response.bodyBytes.length > _maxBytes) {
      throw const FormatException('Календарь слишком большой');
    }

    final text = response.body;
    if (!text.contains('BEGIN:VCALENDAR')) {
      // Самая частая причина — по ссылке отдают HTML-страницу входа, а не файл.
      throw const FormatException('По ссылке не календарь, а что-то другое');
    }
    return IcsParser.parse(text);
  }

  /// Результат одной синхронизации.
  Future<CalendarSyncResult> sync(Map<String, dynamic> subscription) async {
    final user = _db.auth.currentUser;
    final int? id = subscription['id'] as int?;
    if (user == null || id == null) {
      return const CalendarSyncResult(imported: 0, skipped: 0, error: 'Нет активной сессии');
    }

    try {
      final calendar = await loadCalendar(subscription['url'] as String);
      final folder = subscription['folder'] as String?;
      final importNotes = subscription['import_notes'] as bool? ?? true;

      var skipped = 0;
      final rows = <Map<String, dynamic>>[];
      for (final event in calendar.events) {
        // Отменённое событие и событие без даты импортировать некуда:
        // задача без дня осела бы во «Входящих» мусором.
        if (event.isCancelled || event.start == null) {
          skipped++;
          continue;
        }
        // Без UID нечем опознать событие при следующей синхронизации —
        // импорт создавал бы дубликаты при каждом обновлении.
        if (event.uid == null || event.uid!.isEmpty) {
          skipped++;
          continue;
        }
        final fields = icsEventToTaskFields(
          event,
          folder: folder,
          importNotes: importNotes,
          subscriptionId: id,
        );
        fields['user_id'] = user.id;
        rows.add(fields);
      }

      if (rows.isNotEmpty) {
        // Обновляем существующие по тройке (пользователь, подписка, UID) —
        // тот же уникальный индекс, что и в миграции. Так правка времени пары
        // в источнике правит задачу, а не добавляет вторую.
        await _db.from('tasks').upsert(
              rows,
              onConflict: 'user_id,external_source,external_uid',
            );
      }

      await _db.from('calendar_subscriptions').update({
        'last_synced_at': DateTime.now().toUtc().toIso8601String(),
        'last_error': null,
        'last_event_count': calendar.events.length,
        if (subscription['name'] == null && calendar.name != null) 'name': calendar.name,
      }).eq('id', id);

      return CalendarSyncResult(imported: rows.length, skipped: skipped);
    } catch (e) {
      final message = _humanError(e);
      logError('Синхронизация календаря не удалась: $e');
      try {
        await _db.from('calendar_subscriptions').update({
          'last_error': message,
          'last_synced_at': DateTime.now().toUtc().toIso8601String(),
        }).eq('id', id);
      } catch (_) {
        // Не смогли записать ошибку — не повод потерять её саму.
      }
      return CalendarSyncResult(imported: 0, skipped: 0, error: message);
    }
  }

  /// Синхронизирует все включённые подписки.
  Future<List<CalendarSyncResult>> syncAll() async {
    final subs = await fetchSubscriptions();
    final results = <CalendarSyncResult>[];
    for (final sub in subs) {
      if (sub['enabled'] == false) continue;
      results.add(await sync(sub));
    }
    return results;
  }

  /// Понятная формулировка вместо технического текста исключения.
  static String _humanError(Object e) {
    if (e is TimeoutException) return 'Сервер календаря не ответил вовремя';
    if (e is FormatException) return e.message;
    if (e is http.ClientException) {
      // В вебе браузер режет запрос на чужой домен без заголовков CORS, и
      // сообщение об этом выглядит как обычный сбой сети. Говорим прямо.
      return 'Не удалось загрузить календарь: ${e.message}';
    }
    if (e is PostgrestException) return 'Не удалось сохранить задачи: ${e.message}';
    return 'Не удалось загрузить календарь';
  }

  void dispose() => _client.close();
}

/// Итог одной синхронизации: сколько перенесено, сколько пропущено и почему.
class CalendarSyncResult {
  const CalendarSyncResult({
    required this.imported,
    required this.skipped,
    this.error,
  });

  final int imported;
  final int skipped;
  final String? error;

  bool get isSuccess => error == null;

  @override
  String toString() => isSuccess
      ? 'перенесено $imported, пропущено $skipped'
      : 'ошибка: $error';
}
