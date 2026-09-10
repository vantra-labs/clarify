import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/core/app_settings.dart';
import 'package:frontend/core/theme/design_tokens.dart';
import 'package:frontend/widgets/main_content_area.dart';

import 'helpers/settings_box.dart';

String _fmt(DateTime d) =>
    "${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}";

Widget _harness({
  required String selectedMenu,
  required List<Map<String, dynamic>> tasks,
}) {
  return MaterialApp(
    // Токены темы обязательны: виджеты раздела читают их через context.tokens,
    // и в приложении расширение есть всегда. Без него тест проверял бы
    // конфигурацию, которой не существует.
    theme: ThemeData(extensions: const [ClarifyTokens.light]),
    home: Scaffold(
      body: MainContentArea(
        selectedMenu: selectedMenu,
        currentLang: 'ru',
        filteredTasks: tasks,
        isDark: false,
        scale: 1.0,
        onReorderTasks: (_, _, _) {},
        onTaskDropped: (_, _, _) {},
        onPlusTap: (_, _) {},
        buildListTaskCard: (task) => Text(task['title'] as String),
        buildBoardTaskCardExpanded: (task) => Text(task['title'] as String),
        buildCalendarTaskCard: (task) => Text(task['title'] as String),
        buildCalendarTaskChip: (task) => Text(task['title'] as String),
        buildGlassContainer: ({required child, margin, padding, customColor}) => child,
        buildStatisticsDashboard: () => const SizedBox.shrink(),
        buildSettingsPanel: () => const SizedBox.shrink(),
          buildTrashPanel: () => const SizedBox.shrink(),
          buildArchivePanel: () => const SizedBox.shrink(),
        currentCalendarDate: DateTime.now(),
        onCalendarDateChanged: (_) {},
        getLocalKanbanStatus: (_) => 'todo',
        onSetLocalKanbanStatus: (_, _) {},
        onMenuSelected: (_) {},
        projectIconKeys: const {},
        onSetProjectIcon: (_, _) {},
        projectColorKeys: const {},
        onSetProjectColor: (_, _) {},
      ),
    ),
  );
}

void main() {
  // MainContentArea читает выбранный способ сортировки из настроек.
  useSettingsBox();

  final today = DateTime.now();
  final tomorrow = today.add(const Duration(days: 1));

  group('MainContentArea — "Мой день"', () {
    testWidgets('показывает только сегодняшние задачи без родителя', (tester) async {
      final tasks = [
        {'id': 1, 'title': 'Сегодняшняя задача', 'due_date': _fmt(today), 'parent_id': null},
        {'id': 2, 'title': 'Завтрашняя задача', 'due_date': _fmt(tomorrow), 'parent_id': null},
        {'id': 3, 'title': 'Подзадача на сегодня', 'due_date': _fmt(today), 'parent_id': 1},
      ];

      await tester.pumpWidget(_harness(selectedMenu: 'Мой день', tasks: tasks));

      expect(find.text('Сегодняшняя задача'), findsOneWidget);
      expect(find.text('Завтрашняя задача'), findsNothing);
      expect(find.text('Подзадача на сегодня'), findsNothing);
    });

    testWidgets('показывает пустое состояние, если задач на сегодня нет', (tester) async {
      await tester.pumpWidget(_harness(selectedMenu: 'Мой день', tasks: const []));

      expect(find.text('На сегодня ничего не запланировано'), findsOneWidget);
    });
  });

  group('MainContentArea — выполненные', () {
    testWidgets('убраны в свёрнутый блок, активные остаются в списке', (tester) async {
      AppSettings.setCompletedExpanded(false);
      final tasks = [
        {'id': 1, 'title': 'Активная', 'due_date': _fmt(today), 'parent_id': null, 'is_completed': false},
        {'id': 2, 'title': 'Уже сделана', 'due_date': _fmt(today), 'parent_id': null, 'is_completed': true},
      ];

      await tester.pumpWidget(_harness(selectedMenu: 'Мой день', tasks: tasks));

      expect(find.text('Активная'), findsOneWidget);
      expect(find.text('Уже сделана'), findsNothing,
          reason: 'выполненное не должно занимать экран');
      expect(find.text('Выполнено'), findsOneWidget);

      await tester.tap(find.text('Выполнено'));
      await tester.pumpAndSettle();
      expect(find.text('Уже сделана'), findsOneWidget);
    });

    testWidgets('раздел не считается пустым, если все задачи выполнены', (tester) async {
      AppSettings.setCompletedExpanded(false);
      final tasks = [
        {'id': 1, 'title': 'Всё сделано', 'due_date': _fmt(today), 'parent_id': null, 'is_completed': true},
      ];

      await tester.pumpWidget(_harness(selectedMenu: 'Мой день', tasks: tasks));

      // Иллюстрация «ничего не запланировано» здесь была бы обманом: задача на
      // сегодня есть, просто она уже закрыта.
      expect(find.text('На сегодня ничего не запланировано'), findsNothing);
      expect(find.text('Выполнено'), findsOneWidget);
    });
  });

  group('MainContentArea — "Входящие"', () {
    testWidgets('показывает только задачи без даты', (tester) async {
      final tasks = [
        {'id': 1, 'title': 'Без даты', 'due_date': null, 'parent_id': null},
        {'id': 2, 'title': 'С датой', 'due_date': _fmt(today), 'parent_id': null},
      ];

      await tester.pumpWidget(_harness(selectedMenu: 'Входящие', tasks: tasks));

      expect(find.text('Без даты'), findsOneWidget);
      expect(find.text('С датой'), findsNothing);
    });
  });
}
