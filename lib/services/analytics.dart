import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Аналитика использования: только факт события, источник ввода и платформа.
///
/// Текст задач, устройства и прочее личное сюда не попадает — см.
/// supabase/migrations/20261031200000_analytics.sql, там же ограничение на
/// размер props. Задачи сервер считает сам по таблице tasks, поэтому здесь
/// отправляются лишь две вещи: что приложение открыли и откуда пришла задача.
///
/// Любая ошибка глушится: аналитика не должна ни ронять приложение, ни
/// показывать человеку тосты, ни задерживать создание задачи.
class Analytics {
  Analytics._();

  /// Открытия чаще, чем раз в полчаса, не считаются отдельными: иначе
  /// переключение между окнами превращалось бы в десятки «заходов».
  static const Duration _openThrottle = Duration(minutes: 30);

  static DateTime? _lastOpenSent;
  static AppLifecycleListener? _lifecycle;
  static String? _appVersion;

  /// Платформа одной строкой. На вебе — `pwa`: веб-версия Clarify и есть PWA.
  static String get platform => kIsWeb ? 'pwa' : defaultTargetPlatform.name;

  /// Запускается один раз после входа: отправляет открытие и подписывается на
  /// возврат приложения из фона.
  static void start() {
    if (_lifecycle != null) return;
    _lifecycle = AppLifecycleListener(onResume: _appOpened);
    _appOpened();
  }

  static void _appOpened() {
    final now = DateTime.now();
    final last = _lastOpenSent;
    if (last != null && now.difference(last) < _openThrottle) return;
    _lastOpenSent = now;
    unawaited(track('app_open'));
  }

  /// [source] — откуда задача: `quick` (строка с разбором), `manual` (окно
  /// создания), `sheet` (мобильная шторка), `subtask`, `repeat` (следующий
  /// повтор), `copy`, `other`.
  static void taskCreated(String source) {
    unawaited(track('task_created', {'source': source}));
  }

  static Future<void> track(String event, [Map<String, dynamic>? props]) async {
    try {
      final client = Supabase.instance.client;
      if (client.auth.currentUser == null) return;
      _appVersion ??= (await PackageInfo.fromPlatform()).version;
      await client.from('analytics_events').insert({
        'event': event,
        'props': props ?? const <String, dynamic>{},
        'platform': platform,
        'app_version': _appVersion,
      });
    } on Object catch (e) {
      // Сознательно широкий перехват: нет сети, таблица ещё не создана,
      // плагин недоступен в тесте — всё это не повод что-то ломать.
      debugPrint('Analytics.$event не отправлено: $e');
    }
  }

  /// Сводка для владельца. null — если прав нет или запрос не прошёл.
  static Future<Map<String, dynamic>?> summary({int days = 30}) async {
    try {
      final res = await Supabase.instance.client.rpc('analytics_summary', params: {'p_days': days});
      return Map<String, dynamic>.from(res as Map);
    } on Object catch (e) {
      debugPrint('analytics_summary: $e');
      return null;
    }
  }

  /// Видна ли владельцу карточка аналитики. Без прав и без сети — false.
  static Future<bool> isAdmin() async {
    try {
      final res = await Supabase.instance.client.rpc('is_analytics_admin');
      return res == true;
    } on Object {
      return false;
    }
  }
}
