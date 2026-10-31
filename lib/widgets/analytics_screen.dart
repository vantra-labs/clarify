import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../core/theme/design_tokens.dart';
import '../services/analytics.dart';

/// Аналитика для владельца: три главные цифры сверху, подробности ниже.
///
/// Видна только тем, кто внесён в analytics_admins (см. миграцию
/// 20261031200000_analytics.sql). Тексты без .tr(): экран не для
/// пользователей, переводить его незачем.
class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  static const _windows = [7, 30, 90];
  int _days = 30;
  Map<String, dynamic>? _data;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final data = await Analytics.summary(days: _days);
    if (!mounted) return;
    setState(() {
      _data = data;
      _loading = false;
    });
  }

  int _int(String key) => (_data?[key] as num?)?.toInt() ?? 0;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Scaffold(
      backgroundColor: t.bg,
      appBar: AppBar(
        backgroundColor: t.bg,
        elevation: 0,
        foregroundColor: t.text,
        title: const Text('Аналитика', style: TextStyle(fontFamily: 'Golos Text', fontWeight: FontWeight.w700)),
        actions: [
          IconButton(icon: const Icon(LucideIcons.refreshCw, size: 18), onPressed: _loading ? null : _load, tooltip: 'Обновить'),
        ],
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: t.accent))
          : _data == null
              ? _message(t, 'Не удалось получить цифры. Проверь сеть или права в analytics_admins.')
              : _content(t),
    );
  }

  Widget _message(ClarifyTokens t, String text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(text, textAlign: TextAlign.center, style: TextStyle(color: t.text3)),
        ),
      );

  Widget _content(ClarifyTokens t) {
    final cohort = _int('week1_cohort');
    final returned = _int('week1_returned');
    final retention = cohort == 0 ? '—' : '${(returned * 100 / cohort).round()}%';
    final firstWeek = (_data?['first_week_tasks_avg'] as num?)?.toString() ?? '0';

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _windowSelector(t),
          const SizedBox(height: 16),
          // Три цифры, по которым через месяц решается судьба продукта.
          _bigStat(t, 'Новых людей', '${_int('users_new')}', 'за $_days дн. · всего ${_int('users_total')}'),
          const SizedBox(height: 12),
          _bigStat(t, 'Задач за первую неделю', firstWeek, 'в среднем на новичка, прожившего 7 дней'),
          const SizedBox(height: 12),
          _bigStat(t, 'Вернулись через неделю', retention, cohort == 0 ? 'ещё никому нет 7 дней' : '$returned из $cohort · активны на 8–14-й день'),
          const SizedBox(height: 24),
          _sectionLabel(t, 'Активность'),
          _row(t, 'Сегодня', _int('active_1d')),
          _row(t, 'За 7 дней', _int('active_7d')),
          _row(t, 'За 30 дней', _int('active_30d')),
          const SizedBox(height: 16),
          _sectionLabel(t, 'Задачи за $_days дн.'),
          _row(t, 'Создано', _int('tasks_created')),
          _row(t, 'Выполнено', _int('tasks_completed')),
          const SizedBox(height: 16),
          _sectionLabel(t, 'Откуда задачи (из приложения)'),
          ..._mapRows(t, _data?['sources'], const {
            'quick': 'Строка с разбором',
            'manual': 'Окно создания',
            'sheet': 'Мобильная шторка',
            'subtask': 'Подзадачи',
            'repeat': 'Повторы',
            'copy': 'Копии',
            'other': 'Прочее',
          }),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'ИИ, голос, Telegram-бот и MCP создают задачи на сервере — они есть в «Создано», но не здесь.',
              style: TextStyle(color: t.text3, fontSize: 12),
            ),
          ),
          const SizedBox(height: 16),
          _sectionLabel(t, 'Платформы (люди)'),
          ..._mapRows(t, _data?['platforms'], const {
            'pwa': 'PWA / веб',
            'windows': 'Windows',
            'android': 'Android',
            'iOS': 'iOS',
            'macOS': 'macOS',
            'linux': 'Linux',
          }),
        ],
      ),
    );
  }

  Widget _windowSelector(ClarifyTokens t) => Wrap(
        spacing: 8,
        children: [
          for (final d in _windows)
            ChoiceChip(
              label: Text('$d дн.'),
              selected: _days == d,
              selectedColor: t.accentSoft,
              onSelected: (_) {
                if (_days == d) return;
                _days = d;
                _load();
              },
            ),
        ],
      );

  Widget _bigStat(ClarifyTokens t, String label, String value, String hint) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(ClarifyRadius.md),
          border: Border.all(color: t.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(color: t.text2, fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(value, style: TextStyle(color: t.text, fontFamily: 'Unbounded', fontSize: 32, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(hint, style: TextStyle(color: t.text3, fontSize: 12)),
          ],
        ),
      );

  Widget _sectionLabel(ClarifyTokens t, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text.toUpperCase(), style: TextStyle(color: t.text3, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8)),
      );

  Widget _row(ClarifyTokens t, String label, int value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(child: Text(label, style: TextStyle(color: t.text))),
            Text('$value', style: TextStyle(color: t.text, fontWeight: FontWeight.w700)),
          ],
        ),
      );

  List<Widget> _mapRows(ClarifyTokens t, Object? raw, Map<String, String> labels) {
    final map = raw is Map ? raw : const {};
    if (map.isEmpty) {
      return [Text('Пока нет данных', style: TextStyle(color: t.text3, fontSize: 13))];
    }
    final entries = map.entries.toList()
      ..sort((a, b) => ((b.value as num?) ?? 0).compareTo((a.value as num?) ?? 0));
    return [
      for (final e in entries)
        _row(t, labels[e.key] ?? e.key.toString(), (e.value as num?)?.toInt() ?? 0),
    ];
  }
}
