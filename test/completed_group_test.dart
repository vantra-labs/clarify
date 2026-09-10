import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/core/app_settings.dart';
import 'package:frontend/core/theme/design_tokens.dart';
import 'package:frontend/widgets/clarify_completed_group.dart';

import 'helpers/settings_box.dart';

void main() {
  useSettingsBox();

  final completed = [
    {'id': 1, 'title': 'Купить цемент'},
    {'id': 2, 'title': 'Сдать отчёт'},
    {'id': 3, 'title': 'Позвонить прорабу'},
  ];

  // Токены темы обязательны: блок читает их через context.tokens.
  Widget harness() => MaterialApp(
        theme: ThemeData(extensions: const [ClarifyTokens.light]),
        home: Scaffold(
          body: ClarifyCompletedGroup(
            currentLang: 'ru',
            tasks: completed,
            buildTaskCard: (task) => Text(task['title'] as String),
          ),
        ),
      );

  setUp(() => AppSettings.setCompletedExpanded(false));

  testWidgets('свёрнутый блок показывает количество, но не сами задачи',
      (tester) async {
    await tester.pumpWidget(harness());

    expect(find.text('Выполнено'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('Купить цемент'), findsNothing,
        reason: 'смысл блока в том, чтобы выполненное не занимало экран');
  });

  testWidgets('по нажатию раскрывается и показывает задачи', (tester) async {
    await tester.pumpWidget(harness());

    await tester.tap(find.text('Выполнено'));
    await tester.pumpAndSettle();

    expect(find.text('Купить цемент'), findsOneWidget);
    expect(find.text('Сдать отчёт'), findsOneWidget);
    expect(find.text('Позвонить прорабу'), findsOneWidget);
  });

  testWidgets('состояние запоминается в настройках', (tester) async {
    await tester.pumpWidget(harness());
    await tester.tap(find.text('Выполнено'));
    await tester.pumpAndSettle();

    expect(AppSettings.completedExpanded.value, isTrue);

    // Новый экран с тем же состоянием настроек: блок должен остаться раскрытым,
    // иначе его пришлось бы открывать при каждом переключении раздела.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    expect(find.text('Сдать отчёт'), findsOneWidget);
  });

  testWidgets('повторное нажатие сворачивает', (tester) async {
    await tester.pumpWidget(harness());

    await tester.tap(find.text('Выполнено'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Выполнено'));
    await tester.pumpAndSettle();

    expect(find.text('Купить цемент'), findsNothing);
    expect(AppSettings.completedExpanded.value, isFalse);
  });
}
