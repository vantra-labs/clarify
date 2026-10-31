import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/localization.dart';
import '../core/log.dart';
import '../core/theme/design_tokens.dart';
import '../services/calendar_subscription_service.dart';
import 'clarify_button.dart';
import 'clarify_settings_card.dart';
import 'clarify_toast.dart';

/// Подписка на внешний календарь по ссылке .ics.
///
/// Расписание — вузовское, рабочее, спортивное — почти всегда уже существует в
/// чужой системе и меняется без нашего участия. Переносить его руками значит
/// делать двойную работу, которая устаревает на следующей же правке. Поэтому
/// приложение тянет расписание К СЕБЕ по ссылке: один раз добавил, дальше
/// изменения приезжают сами.
///
/// Сама загрузка и разбор — в [CalendarSubscriptionService] и `core/ics.dart`.
/// Здесь только экран.
class ClarifyCalendarCard extends StatefulWidget {
  final String currentLang;

  /// Позвать после успешной синхронизации: список задач на экране нужно
  /// перечитать, иначе импортированные пары появятся только после перезапуска.
  final Future<void> Function()? onImported;

  const ClarifyCalendarCard({
    super.key,
    required this.currentLang,
    this.onImported,
  });

  @override
  State<ClarifyCalendarCard> createState() => _ClarifyCalendarCardState();
}

class _ClarifyCalendarCardState extends State<ClarifyCalendarCard> {
  final CalendarSubscriptionService _service = CalendarSubscriptionService();
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();

  bool _expanded = false;
  bool _loading = false;
  bool _adding = false;
  /// id подписки, которая прямо сейчас синхронизируется.
  int? _syncingId;
  List<Map<String, dynamic>>? _subs;

  @override
  void dispose() {
    _urlController.dispose();
    _nameController.dispose();
    _service.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final rows = await _service.fetchSubscriptions();
      if (mounted) setState(() => _subs = rows);
    } catch (e) {
      logError('Не удалось загрузить подписки на календари: $e');
      if (mounted) setState(() => _subs = const []);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _add() async {
    final lang = widget.currentLang;
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    setState(() => _adding = true);
    try {
      final created = await _service.addSubscription(
        url: url,
        name: _nameController.text.trim(),
      );
      _urlController.clear();
      _nameController.clear();
      await _load();

      // Сразу синхронизируем: иначе человек добавил ссылку и не понимает,
      // сработало или нет — задач-то не появилось.
      if (created != null && mounted) {
        await _sync(created);
      }
    } catch (e) {
      logError('Не удалось добавить подписку: $e');
      if (!mounted) return;
      final message = e is FormatException
          ? e.message
          : 'Не удалось добавить календарь. Возможно, он уже добавлен.'.tr(lang);
      ClarifyToast.show(context, message, variant: ClarifyToastVariant.warning);
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _sync(Map<String, dynamic> sub) async {
    final lang = widget.currentLang;
    setState(() => _syncingId = sub['id'] as int?);
    try {
      final result = await _service.sync(sub);
      if (!mounted) return;
      if (result.isSuccess) {
        ClarifyToast.show(
          context,
          '${'Перенесено событий: '.tr(lang)}${result.imported}',
          variant: ClarifyToastVariant.success,
        );
        await widget.onImported?.call();
      } else {
        ClarifyToast.show(context, result.error!, variant: ClarifyToastVariant.warning);
      }
      await _load();
    } finally {
      if (mounted) setState(() => _syncingId = null);
    }
  }

  Future<void> _delete(Map<String, dynamic> sub) async {
    final lang = widget.currentLang;
    final id = sub['id'] as int?;
    if (id == null) return;
    try {
      await _service.deleteSubscription(id);
      await _load();
      if (!mounted) return;
      // Говорим прямо, что задачи остаются: иначе человек ждёт, что удаление
      // подписки заодно вычистит расписание, и удивляется.
      ClarifyToast.show(
        context,
        'Подписка удалена. Уже созданные задачи остались.'.tr(lang),
        variant: ClarifyToastVariant.info,
      );
    } catch (e) {
      logError('Не удалось удалить подписку: $e');
    }
  }

  String _formatMoment(String? raw, String lang) {
    if (raw == null) return 'ни разу'.tr(lang);
    final moment = DateTime.tryParse(raw)?.toLocal();
    if (moment == null) return 'ни разу'.tr(lang);
    final d = moment.day.toString().padLeft(2, '0');
    final m = moment.month.toString().padLeft(2, '0');
    final h = moment.hour.toString().padLeft(2, '0');
    final min = moment.minute.toString().padLeft(2, '0');
    return '$d.$m.${moment.year}, $h:$min';
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final lang = widget.currentLang;
    final subs = _subs;

    return ClarifySettingsCard(
      icon: LucideIcons.calendarSync,
      title: 'Внешний календарь'.tr(lang),
      isExpanded: _expanded,
      trailing: Icon(
        _expanded ? LucideIcons.chevronUp : LucideIcons.chevronDown,
        color: t.text2,
        size: 18,
      ),
      onTap: () {
        setState(() => _expanded = !_expanded);
        if (_expanded && _subs == null) _load();
      },
      expandedChild: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(color: t.border, height: 17),
          Text(
            'Добавьте ссылку на расписание — вуза, работы, Google или Apple календаря. События станут задачами, а изменения будут приезжать сами.'
                .tr(lang),
            style: TextStyle(color: t.text2, fontSize: 12.5),
          ),
          const SizedBox(height: 12),

          if (_loading && subs == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: t.accent),
              ),
            )
          else if (subs != null && subs.isNotEmpty) ...[
            for (final sub in subs) _subscriptionRow(sub, t, lang),
            const SizedBox(height: 4),
          ],

          _addForm(t, lang),

          const SizedBox(height: 10),
          Text(
            'Ссылка обычно называется «экспорт календаря», «iCal» или «webcal».'
                .tr(lang),
            style: TextStyle(color: t.text3, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _subscriptionRow(Map<String, dynamic> sub, ClarifyTokens t, String lang) {
    final id = sub['id'] as int?;
    final error = sub['last_error'] as String?;
    final name = (sub['name'] as String?)?.trim();
    final url = (sub['url'] as String?) ?? '';
    final busy = _syncingId != null && _syncingId == id;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            error == null ? LucideIcons.calendarCheck : LucideIcons.calendarX,
            size: 15,
            color: error == null ? t.text3 : t.danger,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (name != null && name.isNotEmpty) ? name : 'Календарь'.tr(lang),
                  style: TextStyle(color: t.text, fontSize: 13.5),
                ),
                Text(
                  url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.text3, fontSize: 11.5),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      error,
                      style: TextStyle(color: t.danger, fontSize: 11.5),
                    ),
                  )
                else
                  Text(
                    '${'Обновлено: '.tr(lang)}${_formatMoment(sub['last_synced_at'] as String?, lang)}',
                    style: TextStyle(color: t.text3, fontSize: 11.5),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (busy)
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: t.accent),
            )
          else ...[
            ClarifyIconButton(
              icon: LucideIcons.refreshCw,
              tooltip: 'Обновить'.tr(lang),
              onPressed: () => _sync(sub),
            ),
            ClarifyIconButton(
              icon: LucideIcons.trash2,
              tooltip: 'Удалить'.tr(lang),
              color: t.danger,
              onPressed: () => _delete(sub),
            ),
          ],
        ],
      ),
    );
  }

  Widget _addForm(ClarifyTokens t, String lang) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _urlController,
          style: TextStyle(color: t.text, fontSize: 13),
          decoration: InputDecoration(
            hintText: 'https://… или webcal://…',
            hintStyle: TextStyle(color: t.text3, fontSize: 13),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(ClarifyRadius.sm),
              borderSide: BorderSide(color: t.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(ClarifyRadius.sm),
              borderSide: BorderSide(color: t.border),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _nameController,
                style: TextStyle(color: t.text, fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Название, необязательно'.tr(lang),
                  hintStyle: TextStyle(color: t.text3, fontSize: 13),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(ClarifyRadius.sm),
                    borderSide: BorderSide(color: t.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(ClarifyRadius.sm),
                    borderSide: BorderSide(color: t.border),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            ClarifyButton(
              label: 'Добавить'.tr(lang),
              icon: LucideIcons.plus,
              variant: ClarifyButtonVariant.filled,
              loading: _adding,
              onPressed: _adding ? null : _add,
            ),
          ],
        ),
      ],
    );
  }
}
