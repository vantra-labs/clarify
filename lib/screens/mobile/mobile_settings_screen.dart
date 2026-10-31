import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/app_settings.dart';
import '../../core/config.dart';
import '../../core/features.dart';
import '../../core/localization.dart';
import '../../core/theme/design_tokens.dart';
import '../../dialogs/privacy_policy_dialog.dart';
import '../../services/push_registration.dart';
import '../../widgets/clarify_button.dart';
import '../../widgets/clarify_priority_lever.dart';
import '../../widgets/clarify_settings_card.dart';
import '../../widgets/clarify_pressable.dart';
import '../../widgets/clarify_toast.dart';
import '../../widgets/analytics_screen.dart';
import '../../services/analytics.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// "Настройки" — по образцу Structured: сгруппированный список, а не
/// свалка "Ещё". Статистика — внутри, отдельным пунктом, не в нижней
/// навигации (там ей не хватило бы места среди 4 основных назначений).
///
/// Единственный экран общих настроек приложения на мобильном — раньше часть
/// этих же настроек (уведомления, акцент, "меньше анимаций", быстрое
/// добавление, кэш, экспорт, поддержка) дублировалась в мобильной версии
/// showAccountSettingsDialog; та страница теперь на мобильном — только
/// профиль (аватар/имя/код друга/email/пароль/выход), см. onOpenAccountSettings.
class MobileSettingsScreen extends StatefulWidget {
  final String currentLang;
  final String userInitial;
  final String userFullName;
  final bool isDark;
  final VoidCallback onOpenAccountSettings;
  final VoidCallback onOpenStatistics;
  final VoidCallback onOpenFriends;
  final VoidCallback onOpenMessages;

  /// Корзина (C6). На ПК это отдельный пункт сайдбара, здесь — пункт в
  /// «Обзоре»: в нижнюю навигацию из четырёх мест её не поставить, а без неё
  /// удаление с телефона выглядело безвозвратным, хотя таковым не было.
  final VoidCallback onOpenTrash;

  /// «О приложении» — версия сборки и единственное во всём интерфейсе
  /// упоминание бренда студии (BRAND.md §4).
  final VoidCallback onOpenAbout;

  final VoidCallback toggleTheme;
  final Function(String lang) changeLang;

  /// true — экран встроен во вкладку с собственной шапкой (десктоп), поэтому
  /// свой заголовок "Настройки" рисовать не нужно.
  final bool embedded;

  const MobileSettingsScreen({
    super.key,
    required this.currentLang,
    required this.userInitial,
    required this.userFullName,
    required this.isDark,
    required this.onOpenAccountSettings,
    required this.onOpenStatistics,
    required this.onOpenFriends,
    required this.onOpenMessages,
    required this.onOpenTrash,
    required this.onOpenAbout,
    required this.toggleTheme,
    required this.changeLang,
    this.embedded = false,
  });

  @override
  State<MobileSettingsScreen> createState() => _MobileSettingsScreenState();
}

class _MobileSettingsScreenState extends State<MobileSettingsScreen> {
  bool showAccentPicker = false;
  bool showQuickAddDefaults = false;
  bool showCacheDetails = false;
  int _unreadMessagesCount = 0;
  // Карточка «Аналитика» — только для владельца (analytics_admins).
  bool _isAnalyticsAdmin = false;
  RealtimeChannel? _messagesChannel;

  String get currentLang => widget.currentLang;

  @override
  void initState() {
    super.initState();
    Analytics.isAdmin().then((v) {
      if (mounted && v) setState(() => _isAnalyticsAdmin = true);
    });
    // Мессенджер скрыт (core/features.dart) — бейдж непрочитанных не нужен,
    // и лишняя realtime-подписка тоже.
    if (!Features.social) return;
    _loadUnreadMessagesCount();
    // Обновляем бейдж, пока пользователь на экране настроек — не только при
    // заходе, чтобы не выглядело так, будто новое сообщение не заметилось.
    _messagesChannel = Supabase.instance.client.channel('settings_messages_badge')
      ..onPostgresChanges(event: PostgresChangeEvent.all, schema: 'public', table: 'messages', callback: (_) => _loadUnreadMessagesCount())
      ..subscribe();
  }

  @override
  void dispose() {
    _messagesChannel?.unsubscribe();
    super.dispose();
  }

  Future<void> _loadUnreadMessagesCount() async {
    try {
      final data = await Supabase.instance.client.rpc('list_conversations');
      final total = List<Map<String, dynamic>>.from(data)
          .fold<int>(0, (sum, c) => sum + ((c['unread_count'] as num?)?.toInt() ?? 0));
      if (mounted) setState(() => _unreadMessagesCount = total);
    } catch (_) {
      // Бейдж — не критичная информация, молча оставляем прежнее значение.
    }
  }

  String _cacheSizeLabel() {
    final raw = Hive.box('tasks_cache').get('all_tasks') as String?;
    final bytes = raw == null ? 0 : utf8.encode(raw).length;
    if (bytes < 1024) return '$bytes Б';
    return '${(bytes / 1024).toStringAsFixed(1)} КБ';
  }

  void _clearCache() {
    Hive.box('tasks_cache').delete('all_tasks');
    setState(() {});
    ClarifyToast.show(context, 'Кэш очищен'.tr(currentLang), variant: ClarifyToastVariant.success);
  }

  Future<void> _exportTasksCsv() async {
    final raw = Hive.box('tasks_cache').get('all_tasks') as String?;
    final tasks = raw == null ? const [] : (json.decode(raw) as List);
    if (tasks.isEmpty) {
      ClarifyToast.show(context, 'Задач нет — нечего экспортировать'.tr(currentLang), variant: ClarifyToastVariant.info);
      return;
    }

    String esc(dynamic value) {
      final s = (value ?? '').toString();
      if (s.contains(',') || s.contains('"') || s.contains('\n')) {
        return '"${s.replaceAll('"', '""')}"';
      }
      return s;
    }

    final buffer = StringBuffer('﻿');
    buffer.writeln('title,due_date,due_time,priority,recurrence,is_completed,folder,note');
    for (final item in tasks) {
      final task = Map<String, dynamic>.from(item as Map);
      buffer.writeln([
        esc(task['title']),
        esc(task['due_date']),
        esc(task['due_time']),
        esc(task['priority']),
        esc(task['recurrence']),
        esc(task['is_completed']),
        esc(task['folder']),
        esc(task['note']),
      ].join(','));
    }

    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Экспорт задач в CSV'.tr(currentLang),
      fileName: 'clarify_tasks_${DateTime.now().millisecondsSinceEpoch}.csv',
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );
    if (path == null) return;
    await File(path).writeAsBytes(utf8.encode(buffer.toString()));
    if (mounted) ClarifyToast.show(context, 'Файл сохранён'.tr(currentLang), variant: ClarifyToastVariant.success);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final email = Supabase.instance.client.auth.currentUser?.email ?? '';

    return _constrained(ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
      children: [
        // На десктопной вкладке заголовок уже есть в шапке — второй такой же
        // прямо под ним читался как ошибка вёрстки.
        if (!widget.embedded) ...[
          Text('Настройки'.tr(currentLang), style: TextStyle(fontFamily: 'Golos Text', fontSize: 22, fontWeight: FontWeight.w700, color: t.text)),
          const SizedBox(height: 16),
        ],

        Material(
          color: t.surface,
          borderRadius: BorderRadius.circular(ClarifyRadius.md),
          child: InkWell(
            borderRadius: BorderRadius.circular(ClarifyRadius.md),
            onTap: widget.onOpenAccountSettings,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  CircleAvatar(radius: 24, backgroundColor: t.accentSoft, child: Text(widget.userInitial, style: TextStyle(color: t.accent, fontWeight: FontWeight.bold, fontSize: 18))),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.userFullName.isNotEmpty ? widget.userFullName : 'Без имени'.tr(currentLang), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: t.text)),
                        if (email.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(email, style: TextStyle(fontSize: 12.5, color: t.text3)),
                        ],
                      ],
                    ),
                  ),
                  Icon(LucideIcons.chevronRight, color: t.text3),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),

        _SectionLabel(text: 'Обзор'.tr(currentLang)),
        // Соцчасть скрыта флагом, см. core/features.dart.
        if (Features.social) ...[
        ClarifySettingsCard(
          icon: LucideIcons.userRound,
          title: 'Друзья'.tr(currentLang),
          onTap: widget.onOpenFriends,
          trailing: Icon(LucideIcons.chevronRight, size: 18, color: t.text3),
        ),
        const SizedBox(height: 12),
        ClarifySettingsCard(
          icon: LucideIcons.messageCircle,
          title: 'Мессенджер'.tr(currentLang),
          onTap: widget.onOpenMessages,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_unreadMessagesCount > 0) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: t.accent, borderRadius: BorderRadius.circular(ClarifyRadius.pill)),
                  child: Text('$_unreadMessagesCount', style: TextStyle(color: t.onAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 8),
              ],
              Icon(LucideIcons.chevronRight, size: 18, color: t.text3),
            ],
          ),
        ),
        const SizedBox(height: 12),
        ],
        ClarifySettingsCard(
          icon: LucideIcons.chartBar,
          title: 'Статистика'.tr(currentLang),
          onTap: widget.onOpenStatistics,
          trailing: Icon(LucideIcons.chevronRight, size: 18, color: t.text3),
        ),
        if (_isAnalyticsAdmin) ...[
          const SizedBox(height: 12),
          ClarifySettingsCard(
            icon: LucideIcons.chartLine,
            title: 'Аналитика',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AnalyticsScreen())),
            trailing: Icon(LucideIcons.chevronRight, size: 18, color: t.text3),
          ),
        ],
        const SizedBox(height: 12),
        ClarifySettingsCard(
          icon: LucideIcons.trash2,
          title: 'Корзина'.tr(currentLang),
          onTap: widget.onOpenTrash,
          trailing: Icon(LucideIcons.chevronRight, size: 18, color: t.text3),
        ),

        const SizedBox(height: 20),
        _SectionLabel(text: 'Уведомления'.tr(currentLang)),
        ClarifySettingsCard(
          icon: LucideIcons.bell,
          title: 'Уведомления'.tr(currentLang),
          trailing: Switch(
            value: AppSettings.pushSubscribed,
            activeThumbColor: t.accent,
            onChanged: (val) async {
              if (kIsWeb) {
                final error = val
                    ? await PushRegistrationWeb.register(AppConfig.vapidPublicKey)
                    : await PushRegistrationWeb.unregister();
                if (val && error != null) {
                  if (context.mounted) {
                    ClarifyToast.show(context, error, variant: ClarifyToastVariant.warning);
                  }
                  setState(() {});
                  return;
                }
              }
              setState(() {
                AppSettings.notificationsEnabled = val;
                AppSettings.pushSubscribed = val;
              });
            },
          ),
        ),
        const SizedBox(height: 12),
        ClarifySettingsCard(
          icon: LucideIcons.calendarCheck,
          title: 'Ежедневный обзор'.tr(currentLang),
          trailing: Switch(
            value: AppSettings.dailyReviewEnabled,
            activeThumbColor: t.accent,
            onChanged: (val) => setState(() => AppSettings.dailyReviewEnabled = val),
          ),
        ),

        const SizedBox(height: 20),
        _SectionLabel(text: 'Фокус-режим'.tr(currentLang)),
        ClarifySettingsCard(
          icon: LucideIcons.timer,
          title: 'Длительность фокус-режима'.tr(currentLang),
          trailing: DropdownButton<int>(
            value: AppSettings.zenDurationMinutes,
            dropdownColor: t.surface2,
            underline: const SizedBox(),
            style: TextStyle(fontSize: 14, color: t.text),
            items: [15, 25, 45, 60, 90]
                .map((m) => DropdownMenuItem(value: m, child: Text('$m ${"мин".tr(currentLang)}', style: TextStyle(color: t.text))))
                .toList(),
            onChanged: (val) => setState(() => AppSettings.zenDurationMinutes = val!),
          ),
        ),

        const SizedBox(height: 20),
        _SectionLabel(text: 'Тариф'.tr(currentLang)),
        ClarifySettingsCard(
          icon: LucideIcons.crown,
          title: 'Управление подпиской'.tr(currentLang),
          trailing: Icon(LucideIcons.chevronRight, size: 18, color: t.text3),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => _PlanPage(currentLang: currentLang))),
        ),

        const SizedBox(height: 20),
        _SectionLabel(text: 'Интеграции'.tr(currentLang)),
        ClarifySettingsCard(
          icon: LucideIcons.calendarSync,
          title: 'Календари'.tr(currentLang),
          trailing: Icon(LucideIcons.chevronRight, size: 18, color: t.text3),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => _CalendarsPage(currentLang: currentLang))),
        ),

        const SizedBox(height: 20),
        _SectionLabel(text: 'Оформление'.tr(currentLang)),
        // Три состояния вместо тумблера (D3): раньше выбор был только
        // «светлая/тёмная», и приложение не умело следовать системе — на
        // телефоне, где тема переключается по расписанию, это выглядело как
        // единственное приложение, которое ночью остаётся белым.
        ValueListenableBuilder<ThemeMode>(
          valueListenable: AppSettings.themeMode,
          builder: (context, mode, _) => ClarifySettingsCard(
            icon: switch (mode) {
              ThemeMode.system => LucideIcons.smartphone,
              ThemeMode.dark => LucideIcons.moon,
              ThemeMode.light => LucideIcons.sun,
            },
            title: 'Тема'.tr(currentLang),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final option in const [
                  (ThemeMode.system, 'Система'),
                  (ThemeMode.light, 'Светлая'),
                  (ThemeMode.dark, 'Тёмная'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: ClarifyPressable(
                      onTap: () => AppSettings.setThemeMode(option.$1),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                        decoration: BoxDecoration(
                          color: mode == option.$1 ? t.accent : Colors.transparent,
                          borderRadius: BorderRadius.circular(ClarifyRadius.pill),
                          border: Border.all(
                            color: mode == option.$1 ? t.accent : t.border,
                          ),
                        ),
                        child: Text(
                          option.$2.tr(currentLang),
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: mode == option.$1 ? t.onAccent : t.text2,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        // Обзорность против читаемости — вкус, а не истина (D3). Раньше
        // выбирали за человека; теперь выбирает он.
        const SizedBox(height: 8),
        ValueListenableBuilder<bool>(
          valueListenable: AppSettings.compactDensity,
          builder: (context, compact, _) => ClarifySettingsCard(
            icon: LucideIcons.rows3,
            title: 'Плотность'.tr(currentLang),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final option in const [(false, 'Обычно'), (true, 'Плотно')])
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: ClarifyPressable(
                      onTap: () => AppSettings.setCompactDensity(option.$1),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                        decoration: BoxDecoration(
                          color: compact == option.$1 ? t.accent : Colors.transparent,
                          borderRadius: BorderRadius.circular(ClarifyRadius.pill),
                          border: Border.all(
                            color: compact == option.$1 ? t.accent : t.border,
                          ),
                        ),
                        child: Text(
                          option.$2.tr(currentLang),
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: compact == option.$1 ? t.onAccent : t.text2,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        ClarifySettingsCard(
          icon: LucideIcons.palette,
          title: 'Акцентный цвет'.tr(currentLang),
          onTap: () => setState(() => showAccentPicker = !showAccentPicker),
          isExpanded: showAccentPicker,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 18, height: 18, decoration: BoxDecoration(color: ClarifyAccentPresets.values[AppSettings.accentPresetIndex.value], shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Icon(showAccentPicker ? LucideIcons.chevronUp : LucideIcons.chevronDown, color: t.text3, size: 18),
            ],
          ),
          expandedChild: Column(
            children: [
              Divider(color: t.border, height: 17),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: List.generate(ClarifyAccentPresets.values.length, (i) {
                  final color = ClarifyAccentPresets.values[i];
                  final isSelected = AppSettings.accentPresetIndex.value == i;
                  return GestureDetector(
                    onTap: () => setState(() => AppSettings.setAccentPresetIndex(i)),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(color: color, shape: BoxShape.circle, border: isSelected ? Border.all(color: t.text, width: 2) : null),
                      child: isSelected ? const Icon(LucideIcons.check, size: 16, color: Colors.white) : null,
                    ),
                  );
                }),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        ClarifySettingsCard(
          icon: LucideIcons.zapOff,
          title: 'Меньше анимаций'.tr(currentLang),
          trailing: Switch(
            value: AppSettings.reducedMotionOverride.value,
            activeThumbColor: t.accent,
            onChanged: (val) => setState(() => AppSettings.setReducedMotionOverride(val)),
          ),
        ),
        const SizedBox(height: 8),
        ClarifySettingsCard(
          icon: LucideIcons.globe,
          title: 'Язык'.tr(currentLang),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _LangButton(label: 'RU', active: currentLang == 'ru', onTap: () => widget.changeLang('ru')),
              const SizedBox(width: 6),
              _LangButton(label: 'EN', active: currentLang == 'en', onTap: () => widget.changeLang('en')),
            ],
          ),
        ),

        const SizedBox(height: 20),
        _SectionLabel(text: 'Быстрое добавление'.tr(currentLang)),
        ClarifySettingsCard(
          icon: LucideIcons.listPlus,
          title: 'Быстрое добавление'.tr(currentLang),
          onTap: () => setState(() => showQuickAddDefaults = !showQuickAddDefaults),
          isExpanded: showQuickAddDefaults,
          trailing: Icon(showQuickAddDefaults ? LucideIcons.chevronUp : LucideIcons.chevronDown, color: t.text3, size: 18),
          expandedChild: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Divider(color: t.border, height: 17),
              Text('Приоритет по умолчанию'.tr(currentLang), style: TextStyle(color: t.text3, fontSize: 12.5)),
              const SizedBox(height: 8),
              ClarifyPriorityLever(
                value: AppSettings.quickAddDefaultPriority,
                onChanged: (val) => setState(() => AppSettings.quickAddDefaultPriority = val),
                getPriorityColor: (pVal) {
                  switch (pVal) {
                    case 'red':
                      return t.danger;
                    case 'orange':
                      return t.warning;
                    case 'blue':
                      return t.accent;
                    case 'gray':
                      return t.text3;
                    default:
                      return Colors.transparent;
                  }
                },
                textMuted: t.text3,
              ),
              const SizedBox(height: 16),
              Text('Повтор по умолчанию'.tr(currentLang), style: TextStyle(color: t.text3, fontSize: 12.5)),
              const SizedBox(height: 8),
              DropdownButton<String>(
                value: AppSettings.quickAddDefaultRecurrence,
                dropdownColor: t.surface2,
                underline: const SizedBox(),
                style: TextStyle(fontSize: 14, color: t.text),
                items: [
                  DropdownMenuItem(value: 'none', child: Text('Без повтора'.tr(currentLang), style: TextStyle(color: t.text))),
                  DropdownMenuItem(value: 'daily', child: Text('Каждый день'.tr(currentLang), style: TextStyle(color: t.text))),
                  DropdownMenuItem(value: 'weekdays', child: Text('По будням'.tr(currentLang), style: TextStyle(color: t.text))),
                  DropdownMenuItem(value: 'weekly', child: Text('Каждую неделю'.tr(currentLang), style: TextStyle(color: t.text))),
                  DropdownMenuItem(value: 'monthly', child: Text('Каждый месяц'.tr(currentLang), style: TextStyle(color: t.text))),
                ],
                onChanged: (val) => setState(() => AppSettings.quickAddDefaultRecurrence = val!),
              ),
            ],
          ),
        ),

        const SizedBox(height: 20),
        _SectionLabel(text: 'Данные'.tr(currentLang)),
        ClarifySettingsCard(
          icon: LucideIcons.database,
          title: 'Локальный кэш'.tr(currentLang),
          onTap: () => setState(() => showCacheDetails = !showCacheDetails),
          isExpanded: showCacheDetails,
          trailing: Icon(showCacheDetails ? LucideIcons.chevronUp : LucideIcons.chevronDown, color: t.text3, size: 18),
          expandedChild: Column(
            children: [
              Divider(color: t.border, height: 17),
              Row(
                children: [
                  Icon(LucideIcons.hardDrive, color: t.text, size: 18),
                  const SizedBox(width: 8),
                  Expanded(child: Text('Размер кэша'.tr(currentLang), style: TextStyle(color: t.text, fontSize: 13))),
                  Text(_cacheSizeLabel(), style: TextStyle(color: t.text3, fontSize: 13)),
                ],
              ),
              const SizedBox(height: 10),
              ClarifyButton(
                label: 'Очистить кэш'.tr(currentLang),
                variant: ClarifyButtonVariant.danger,
                fullWidth: true,
                onPressed: _clearCache,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        ClarifySettingsCard(
          icon: LucideIcons.fileDown,
          title: 'Экспорт задач в CSV'.tr(currentLang),
          trailing: ClarifyButton(
            label: 'Экспортировать'.tr(currentLang),
            variant: ClarifyButtonVariant.outline,
            scale: 0.85,
            onPressed: _exportTasksCsv,
          ),
        ),

        const SizedBox(height: 20),
        _SectionLabel(text: 'Поддержка'.tr(currentLang)),
        // «О приложении» — единственное место во всём интерфейсе, где по
        // фирменному гайду показывается бренд студии. Заодно здесь же видна
        // версия сборки: до этого узнать её из приложения было нельзя вообще.
        ClarifySettingsCard(
          icon: LucideIcons.info,
          title: 'О приложении'.tr(currentLang),
          onTap: widget.onOpenAbout,
          trailing: Icon(LucideIcons.chevronRight, size: 18, color: t.text3),
        ),
        const SizedBox(height: 12),
        ClarifyButton(
          label: 'Поддержка'.tr(currentLang),
          icon: LucideIcons.send,
          variant: ClarifyButtonVariant.outline,
          fullWidth: true,
          onPressed: () async {
            final url = Uri.parse(AppConfig.telegramSupportUrl);
            if (await canLaunchUrl(url)) {
              await launchUrl(url, mode: LaunchMode.externalApplication);
            } else if (context.mounted) {
              ClarifyToast.show(context, 'Не удалось открыть Telegram'.tr(currentLang), variant: ClarifyToastVariant.danger);
            }
          },
        ),
        const SizedBox(height: 12),
        ClarifyButton(
          label: 'Политика конфиденциальности'.tr(currentLang),
          icon: LucideIcons.fileText,
          variant: ClarifyButtonVariant.outline,
          fullWidth: true,
          onPressed: () => showPrivacyPolicyDialog(context: context, isDark: widget.isDark, currentLang: currentLang),
        ),
      ],
    ));
  }

  /// Тот же экран, что и на мобильном (по прямому требованию пользователя от
  /// 2026-08-01 — набор и группировка разделов совпадают), но на широком окне
  /// он не растягивается на всю ширину: иначе переключатель уезжает от своей
  /// подписи на полтора метра экрана и строку невозможно прочитать одним
  /// взглядом. Ограничение по ширине, а не переверстка — содержимое то же.
  Widget _constrained(Widget child) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth <= 760) return child;
        // Слева, а не по центру: все остальные разделы начинаются от левого
        // края области контента, и колонка настроек посреди экрана выпадала бы
        // из этого ряда. 760 = 720 содержимого + собственные отступы ListView.
        return Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: child),
        );
      },
    );
  }
}

class _PlanPage extends StatelessWidget {
  final String currentLang;
  const _PlanPage({required this.currentLang});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Scaffold(
      backgroundColor: t.bg,
      appBar: AppBar(backgroundColor: t.bg, elevation: 0, foregroundColor: t.text, title: Text('Тариф'.tr(currentLang), style: const TextStyle(fontFamily: 'Golos Text', fontWeight: FontWeight.w700))),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(color: t.accentSoft, borderRadius: BorderRadius.circular(999)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(LucideIcons.crown, size: 14, color: t.accent),
              const SizedBox(width: 6),
              Text('Текущий тариф: Free'.tr(currentLang), style: TextStyle(color: t.accent, fontSize: 12.5, fontWeight: FontWeight.w700)),
            ]),
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(ClarifyRadius.md)),
            child: Column(children: [
              Row(children: [
                const Expanded(flex: 3, child: SizedBox()),
                Expanded(flex: 2, child: Center(child: Text('Free', style: TextStyle(color: t.text3, fontWeight: FontWeight.w700, fontSize: 12.5)))),
                Expanded(flex: 2, child: Center(child: Text('Pro', style: TextStyle(color: t.accent, fontWeight: FontWeight.w700, fontSize: 12.5)))),
              ]),
              const Divider(height: 20),
              _PlanCompareRow(t: t, label: 'AI-запросы в месяц'.tr(currentLang), free: '50', pro: '∞'),
              _PlanCompareRow(t: t, label: 'Участников в команде'.tr(currentLang), free: '3', pro: '∞'),
              _PlanCompareRow(t: t, label: 'Яндекс.Календарь'.tr(currentLang), free: null, pro: null),
              _PlanCompareRow(t: t, label: 'Расширенная статистика'.tr(currentLang), free: null, pro: null),
            ]),
          ),
          const SizedBox(height: 20),
          ClarifyButton(
            label: 'Оформить Pro — 199 ₽/мес'.tr(currentLang),
            variant: ClarifyButtonVariant.filled,
            fullWidth: true,
            onPressed: () => ClarifyToast.show(context, 'Оплата Pro скоро будет доступна'.tr(currentLang), variant: ClarifyToastVariant.info),
          ),
        ],
      ),
    );
  }
}

class _PlanCompareRow extends StatelessWidget {
  final ClarifyTokens t;
  final String label;
  final String? free;
  final String? pro;
  const _PlanCompareRow({required this.t, required this.label, this.free, this.pro});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Expanded(flex: 3, child: Text(label, style: TextStyle(color: t.text, fontSize: 13))),
        Expanded(flex: 2, child: Center(child: free != null ? Text(free!, style: TextStyle(color: t.text3, fontWeight: FontWeight.w600, fontSize: 13)) : Icon(LucideIcons.x, size: 15, color: t.danger))),
        Expanded(flex: 2, child: Center(child: pro != null ? Text(pro!, style: TextStyle(color: t.accent, fontWeight: FontWeight.w700, fontSize: 13)) : Icon(LucideIcons.check, size: 15, color: t.accent))),
      ]),
    );
  }
}

class _CalendarsPage extends StatelessWidget {
  final String currentLang;
  const _CalendarsPage({required this.currentLang});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Scaffold(
      backgroundColor: t.bg,
      appBar: AppBar(backgroundColor: t.bg, elevation: 0, foregroundColor: t.text, title: Text('Календари'.tr(currentLang), style: const TextStyle(fontFamily: 'Golos Text', fontWeight: FontWeight.w700))),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Material(
            color: t.surface,
            borderRadius: BorderRadius.circular(ClarifyRadius.md),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                Icon(LucideIcons.calendarDays, color: t.text2, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Яндекс.Календарь'.tr(currentLang), style: TextStyle(color: t.text, fontWeight: FontWeight.w600, fontSize: 14.5)),
                    const SizedBox(height: 2),
                    Text('Требует Pro'.tr(currentLang), style: TextStyle(color: t.text3, fontSize: 12)),
                  ]),
                ),
                ClarifyButton(
                  label: 'Подключить'.tr(currentLang),
                  variant: ClarifyButtonVariant.outline,
                  scale: 0.85,
                  onPressed: () => ClarifyToast.show(context, 'Интеграция скоро будет доступна'.tr(currentLang), variant: ClarifyToastVariant.info),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel({required this.text});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: Text(text.toUpperCase(), style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: t.text3, letterSpacing: 0.6)),
    );
  }
}

class _LangButton extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _LangButton({required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(ClarifyRadius.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: active ? t.accentSoft : Colors.transparent, borderRadius: BorderRadius.circular(ClarifyRadius.sm)),
        child: Text(label, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: active ? t.accent : t.text3)),
      ),
    );
  }
}
