import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'task_sort.dart';

/// Плоский доступ к пользовательским настройкам (Hive-бокс `settings`,
/// открыт в main.dart до runApp). [accentPresetIndex]/[reducedMotionOverride]
/// — ValueNotifier, а не просто значения в боксе: диалог настроек аккаунта
/// не имеет доступа к состоянию _SmartPlannerAppState и не может вызвать его
/// setState напрямую, поэтому MaterialApp в main.dart сам подписывается на
/// эти нотифаеры через ValueListenableBuilder.
class AppSettings {
  AppSettings._();

  static Box get _box => Hive.box('settings');

  static bool get notificationsEnabled => _box.get('notifications_enabled', defaultValue: true) as bool;
  static set notificationsEnabled(bool value) => _box.put('notifications_enabled', value);

  /// Реальная push-подписка (web Notification/PushManager) — отдельно от
  /// [notificationsEnabled] (общий гейт локальных алармов, default true).
  /// Default false: подписки не существует, пока пользователь явно не
  /// включит её (PushRegistrationWeb.register) и браузер не выдаст
  /// разрешение — в отличие от notificationsEnabled, тут "включено по
  /// умолчанию" было бы неверно и приводило к тому, что первый тап по
  /// объединённому переключателю в настройках выключал его вместо запроса
  /// разрешения (см. mobile_settings_screen.dart).
  static bool get pushSubscribed => _box.get('push_subscribed', defaultValue: false) as bool;
  static set pushSubscribed(bool value) => _box.put('push_subscribed', value);

  static int get zenDurationMinutes => _box.get('zen_duration_minutes', defaultValue: 45) as int;
  static set zenDurationMinutes(int value) => _box.put('zen_duration_minutes', value);

  static bool get dailyReviewEnabled => _box.get('daily_review_enabled', defaultValue: true) as bool;
  static set dailyReviewEnabled(bool value) => _box.put('daily_review_enabled', value);

  /// Дата (YYYY-MM-DD), для которой уже показывался "ежедневный обзор" —
  /// раньше хранилась только в памяти (поле State), поэтому на мобильном
  /// PWA, где браузер/ОС часто убивает вкладку в фоне и пересоздаёт State
  /// заново, обзор фактически показывался при КАЖДОМ заходе в приложение
  /// вместо одного раза в день. Персист в Hive переживает пересоздание
  /// процесса.
  static String? get lastDailyReviewDate => _box.get('last_daily_review_date') as String?;
  static set lastDailyReviewDate(String? value) => _box.put('last_daily_review_date', value);

  static String get quickAddDefaultPriority => _box.get('quick_add_default_priority', defaultValue: 'none') as String;
  static set quickAddDefaultPriority(String value) => _box.put('quick_add_default_priority', value);

  static String get quickAddDefaultRecurrence => _box.get('quick_add_default_recurrence', defaultValue: 'none') as String;
  static set quickAddDefaultRecurrence(String value) => _box.put('quick_add_default_recurrence', value);

  static bool get closeToTray => _box.get('close_to_tray', defaultValue: true) as bool;
  static set closeToTray(bool value) => _box.put('close_to_tray', value);

  static bool get aiOnboardingSeen => _box.get('ai_onboarding_seen', defaultValue: false) as bool;
  static set aiOnboardingSeen(bool value) => _box.put('ai_onboarding_seen', value);

  static final ValueNotifier<int> accentPresetIndex = ValueNotifier<int>(
    Hive.box('settings').get('accent_preset', defaultValue: 0) as int,
  );
  static void setAccentPresetIndex(int value) {
    accentPresetIndex.value = value;
    _box.put('accent_preset', value);
  }

  static final ValueNotifier<bool> reducedMotionOverride = ValueNotifier<bool>(
    Hive.box('settings').get('reduced_motion_override', defaultValue: false) as bool,
  );
  static void setReducedMotionOverride(bool value) {
    reducedMotionOverride.value = value;
    _box.put('reduced_motion_override', value);
  }

  /// Режим темы: следовать системе или держать свою (D3).
  ///
  /// Нотифаером по той же причине, что акцент и «меньше анимаций»: экран
  /// настроек не имеет доступа к состоянию главного виджета, а тянуть
  /// setThemeMode параметром через пять виджетов ради одной настройки хуже,
  /// чем подписка, которая здесь уже заведена.
  static final ValueNotifier<ThemeMode> themeMode = ValueNotifier<ThemeMode>(
    _readThemeMode(),
  );

  static ThemeMode _readThemeMode() {
    final raw = Hive.box('settings').get('theme_mode');
    if (raw == 'light') return ThemeMode.light;
    if (raw == 'dark') return ThemeMode.dark;
    if (raw == 'system') return ThemeMode.system;
    // Ключа нет — настройку ещё не трогали в новой версии. Если тему когда-то
    // выбирали руками, уважаем этот выбор: молча переключить человека на
    // системную значит поменять ему внешний вид без спроса. «Как в системе»
    // по умолчанию получают только те, кто не выбирал ничего.
    final legacy = Hive.box('settings').get('is_dark_theme');
    if (legacy is bool) return legacy ? ThemeMode.dark : ThemeMode.light;
    return ThemeMode.system;
  }

  static void setThemeMode(ThemeMode value) {
    themeMode.value = value;
    _box.put('theme_mode', value.name);
  }

  /// Плотная строка задачи вместо обычной (D3).
  ///
  /// Обзорность против читаемости — вкус, а не истина: одному нужно видеть
  /// больше задач разом, другому — чтобы глаза не уставали. Переключатель
  /// снимает спор вместо того, чтобы выбирать за человека.
  static final ValueNotifier<bool> compactDensity = ValueNotifier<bool>(
    Hive.box('settings').get('compact_density', defaultValue: false) as bool,
  );
  static void setCompactDensity(bool value) {
    compactDensity.value = value;
    _box.put('compact_density', value);
  }

  /// Способ сортировки списка задач.
  ///
  /// Один на всё приложение, а не свой в каждом разделе: разделы у Clarify —
  /// это фильтры над одним списком задач, и «в проекте по названию, а во
  /// входящих по сроку» человеку пришлось бы держать в голове. Через
  /// ValueNotifier по той же причине, что и настройки выше: список задач
  /// рисуется из нескольких мест, и прокидывать колбэк в каждое незачем.
  static final ValueNotifier<TaskSortMode> taskSortMode =
      ValueNotifier<TaskSortMode>(
    TaskSortModeInfo.fromStorage(
      Hive.box('settings').get('task_sort_mode') as String?,
    ),
  );
  static void setTaskSortMode(TaskSortMode value) {
    taskSortMode.value = value;
    _box.put('task_sort_mode', value.storageKey);
  }

  /// Раскрыт ли блок выполненных задач в списках.
  ///
  /// По умолчанию свёрнут: выполненные лежали отдельным блоком внизу, но на
  /// длинной истории это десятки строк, через которые надо прокручивать, чтобы
  /// дойти до конца активных. Свёрнутый блок оставляет их на месте и на виду
  /// («Выполнено: 14»), но убирает из-под ног.
  ///
  /// Состояние запоминается: кто работает с открытым блоком, не должен
  /// открывать его заново при каждом переключении раздела.
  static final ValueNotifier<bool> completedExpanded = ValueNotifier<bool>(
    Hive.box('settings').get('completed_expanded', defaultValue: false) as bool,
  );
  static void setCompletedExpanded(bool value) {
    completedExpanded.value = value;
    _box.put('completed_expanded', value);
  }
}
