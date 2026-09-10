import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/config.dart';
import '../core/localization.dart';
import '../core/log.dart';
import '../core/theme/design_tokens.dart';
import 'clarify_button.dart';
import 'clarify_settings_card.dart';
import 'clarify_toast.dart';

/// Подключение сторонних нейросетей к задачам (MCP).
///
/// Clarify выступает MCP-сервером: человек подключает Claude, Cursor или другой
/// клиент и говорит уже им — «что у меня на завтра», «создай задачу». Здесь он
/// заводит и отзывает ключи подключения.
///
/// Ключ придумывает САМО приложение, а в базу уходит только его отпечаток
/// (sha256). Поэтому показать ключ второй раз невозможно даже нам, и утечка
/// базы не открывает чужие задачи.
class ClarifyMcpCard extends StatefulWidget {
  final String currentLang;

  const ClarifyMcpCard({super.key, required this.currentLang});

  @override
  State<ClarifyMcpCard> createState() => _ClarifyMcpCardState();
}

class _ClarifyMcpCardState extends State<ClarifyMcpCard> {
  bool _expanded = false;
  bool _loading = false;
  bool _creating = false;
  List<Map<String, dynamic>>? _keys;

  String get _serverUrl => '${AppConfig.backendBaseUrl}/mcp';

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final rows = await Supabase.instance.client
          .from('mcp_tokens')
          .select('id, name, created_at, last_used_at')
          .order('created_at', ascending: false);
      if (mounted) {
        setState(() => _keys = List<Map<String, dynamic>>.from(rows));
      }
    } catch (e) {
      logError('Не удалось загрузить ключи подключения: $e');
      if (mounted) setState(() => _keys = const []);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Новый ключ. 24 случайных байта — этого достаточно, чтобы перебор был
  /// бессмысленным, а строка оставалась такой, что её можно скопировать целиком.
  ///
  /// Random.secure(), а не обычный Random: обычный предсказуем по предыдущим
  /// значениям, и ключи стали бы угадываемыми.
  String _generateKey() {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return 'clarify_${base64Url.encode(bytes).replaceAll('=', '')}';
  }

  Future<void> _create() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;

    setState(() => _creating = true);
    final key = _generateKey();
    try {
      await Supabase.instance.client.from('mcp_tokens').insert({
        'user_id': user.id,
        'token_hash': sha256.convert(utf8.encode(key)).toString(),
        'name': 'Нейросеть'.tr(widget.currentLang),
      });
      if (!mounted) return;
      await _showKeyOnce(key);
      await _load();
    } catch (e) {
      logError('Не удалось создать ключ подключения: $e');
      if (mounted) {
        ClarifyToast.show(
          context,
          'Не удалось создать ключ'.tr(widget.currentLang),
          variant: ClarifyToastVariant.danger,
        );
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _revoke(Map<String, dynamic> key) async {
    try {
      await Supabase.instance.client.from('mcp_tokens').delete().eq('id', key['id']);
      await _load();
    } catch (e) {
      logError('Не удалось отозвать ключ: $e');
      if (mounted) {
        ClarifyToast.show(
          context,
          'Не удалось отозвать ключ'.tr(widget.currentLang),
          variant: ClarifyToastVariant.danger,
        );
      }
    }
  }

  /// Показ ключа — единственный раз за его жизнь.
  Future<void> _showKeyOnce(String key) {
    final lang = widget.currentLang;
    return showDialog<void>(
      context: context,
      builder: (context) {
        final t = context.tokens;
        return AlertDialog(
          backgroundColor: t.surface2,
          title: Text('Ключ подключения'.tr(lang), style: TextStyle(color: t.text)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Ключ показывается один раз. Скопируйте его сейчас — второй раз посмотреть будет негде.'
                      .tr(lang),
                  style: TextStyle(color: t.text2, fontSize: 13),
                ),
                const SizedBox(height: 14),
                _CopyBox(label: 'Ключ'.tr(lang), value: key, currentLang: lang),
                const SizedBox(height: 10),
                _CopyBox(label: 'Адрес сервера'.tr(lang), value: _serverUrl, currentLang: lang),
                const SizedBox(height: 14),
                Text(
                  'В настройках нейросети укажите адрес сервера и заголовок Authorization: Bearer с этим ключом.'
                      .tr(lang),
                  style: TextStyle(color: t.text2, fontSize: 13),
                ),
                const SizedBox(height: 10),
                Text(
                  'Если клиент не умеет заголовки — вставьте адрес вместе с ключом:'.tr(lang),
                  style: TextStyle(color: t.text3, fontSize: 12.5),
                ),
                const SizedBox(height: 8),
                _CopyBox(
                  label: 'Адрес с ключом'.tr(lang),
                  value: '$_serverUrl/$key',
                  currentLang: lang,
                ),
                const SizedBox(height: 8),
                Text(
                  'Этот способ проще, но ключ попадает в журналы запросов — он менее безопасен.'
                      .tr(lang),
                  style: TextStyle(color: t.text3, fontSize: 12),
                ),
              ],
            ),
          ),
          actions: [
            ClarifyButton(
              label: 'Готово'.tr(lang),
              variant: ClarifyButtonVariant.filled,
              onPressed: () => Navigator.pop(context),
            ),
          ],
        );
      },
    );
  }

  String _formatMoment(String? raw, String lang) {
    if (raw == null) return 'ни разу'.tr(lang);
    final moment = DateTime.tryParse(raw)?.toLocal();
    if (moment == null) return 'ни разу'.tr(lang);
    final d = moment.day.toString().padLeft(2, '0');
    final m = moment.month.toString().padLeft(2, '0');
    return '$d.$m.${moment.year}';
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final lang = widget.currentLang;
    final keys = _keys;

    return ClarifySettingsCard(
      icon: LucideIcons.plug,
      title: 'Подключение нейросетей'.tr(lang),
      isExpanded: _expanded,
      trailing: Icon(
        _expanded ? LucideIcons.chevronUp : LucideIcons.chevronDown,
        color: t.text2,
        size: 18,
      ),
      onTap: () {
        setState(() => _expanded = !_expanded);
        if (_expanded && _keys == null) _load();
      },
      expandedChild: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(color: t.border, height: 17),
          Text(
            'Подключите Claude, Cursor или другой ИИ к своим задачам — и спрашивайте у него «что у меня на завтра», просите создать или закрыть задачу.'
                .tr(lang),
            style: TextStyle(color: t.text2, fontSize: 12.5),
          ),
          const SizedBox(height: 12),
          if (_loading && keys == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: t.accent),
              ),
            )
          else if (keys != null && keys.isNotEmpty) ...[
            for (final key in keys)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Icon(LucideIcons.key, size: 15, color: t.text3),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            (key['name'] as String?) ?? 'Нейросеть'.tr(lang),
                            style: TextStyle(color: t.text, fontSize: 13.5),
                          ),
                          Text(
                            '${'Последний раз: '.tr(lang)}${_formatMoment(key['last_used_at'] as String?, lang)}',
                            style: TextStyle(color: t.text3, fontSize: 11.5),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: Icon(LucideIcons.trash2, size: 16, color: t.danger),
                      tooltip: 'Отозвать'.tr(lang),
                      onPressed: () => _revoke(key),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 4),
          ],
          ClarifyButton(
            label: 'Создать ключ'.tr(lang),
            icon: LucideIcons.plus,
            variant: ClarifyButtonVariant.outline,
            loading: _creating,
            onPressed: _creating ? null : _create,
          ),
        ],
      ),
    );
  }
}

/// Строка со значением и кнопкой «скопировать».
///
/// Значения тут длинные (ключ, адрес) и выделять их мышью в диалоге неудобно —
/// особенно на телефоне, где выделения нет вовсе.
class _CopyBox extends StatelessWidget {
  final String label;
  final String value;
  final String currentLang;

  const _CopyBox({
    required this.label,
    required this.value,
    required this.currentLang,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: t.text3, fontSize: 11.5)),
        const SizedBox(height: 4),
        InkWell(
          borderRadius: BorderRadius.circular(ClarifyRadius.sm),
          onTap: () {
            Clipboard.setData(ClipboardData(text: value));
            ClarifyToast.show(
              context,
              'Скопировано'.tr(currentLang),
              variant: ClarifyToastVariant.success,
            );
          },
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: t.surfaceSunken,
              borderRadius: BorderRadius.circular(ClarifyRadius.sm),
              border: Border.all(color: t.border),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    value,
                    style: TextStyle(color: t.text, fontSize: 12, fontFamily: 'monospace'),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(LucideIcons.copy, size: 14, color: t.accent),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
