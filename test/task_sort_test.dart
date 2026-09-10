import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/core/task_sort.dart';

/// Задача в том виде, в каком её отдаёт база: строковые `due_date`/`due_time`
/// плюс колонки `due_on`/`due_at_time`, которые заполняет триггер.
Map<String, dynamic> task(
  String title, {
  String? date,
  String? time,
  bool withColumns = true,
}) {
  final parts = date?.split('.');
  return {
    'title': title,
    'due_date': date,
    'due_time': time,
    // Колонки-даты есть у всего, что доехало до сервера; у только что
    // созданной задачи их ещё нет — это отдельный случай ниже.
    if (withColumns && parts != null)
      'due_on': '${parts[2]}-${parts[1]}-${parts[0]}',
    if (withColumns && time != null) 'due_at_time': '$time:00',
  };
}

List<String> sortedTitles(List<Map<String, dynamic>> tasks) {
  final copy = [...tasks]..sort(compareTasksByDue);
  return copy.map((t) => t['title'] as String).toList();
}

void main() {
  group('сортировка по сроку', () {
    test('дата важнее времени — та самая жалоба 09.09.2026', () {
      // Раньше сравнивалось только время: 09:00 < 18:00, и завтрашняя задача
      // оказывалась выше сегодняшней.
      final tasks = [
        task('завтра утром', date: '10.09.2026', time: '09:00'),
        task('сегодня вечером', date: '09.09.2026', time: '18:00'),
      ];
      expect(sortedTitles(tasks), ['сегодня вечером', 'завтра утром']);
    });

    test('даты не сравниваются как строки', () {
      // «31.08.2026» посимвольно больше «05.09.2026», хотя август раньше.
      final tasks = [
        task('сентябрь', date: '05.09.2026', time: '10:00'),
        task('август', date: '31.08.2026', time: '10:00'),
      ];
      expect(sortedTitles(tasks), ['август', 'сентябрь']);
    });

    test('внутри одного дня — по времени', () {
      final tasks = [
        task('вечер', date: '09.09.2026', time: '18:00'),
        task('утро', date: '09.09.2026', time: '09:00'),
        task('день', date: '09.09.2026', time: '13:30'),
      ];
      expect(sortedTitles(tasks), ['утро', 'день', 'вечер']);
    });

    test('задача без времени — в конце своего дня, но раньше следующего', () {
      final tasks = [
        task('завтра рано', date: '10.09.2026', time: '07:00'),
        task('сегодня когда-нибудь', date: '09.09.2026'),
        task('сегодня в шесть', date: '09.09.2026', time: '18:00'),
      ];
      expect(sortedTitles(tasks), [
        'сегодня в шесть',
        'сегодня когда-нибудь',
        'завтра рано',
      ]);
    });

    test('задачи без даты — всегда последние', () {
      final tasks = [
        task('без срока'),
        task('через год', date: '09.09.2027', time: '09:00'),
      ];
      expect(sortedTitles(tasks), ['через год', 'без срока']);
    });

    test('минуты внутри часа не путаются', () {
      final tasks = [
        task('в 09:45', date: '09.09.2026', time: '09:45'),
        task('в 09:05', date: '09.09.2026', time: '09:05'),
      ];
      expect(sortedTitles(tasks), ['в 09:05', 'в 09:45']);
    });

    test('только что созданная задача (колонок ещё нет) встаёт правильно', () {
      // Триггер заполняет due_on/due_at_time после вставки, поэтому у
      // оптимистично добавленной задачи есть только строки. Она не должна
      // проваливаться в конец списка.
      final tasks = [
        task('старая, завтра', date: '10.09.2026', time: '09:00'),
        task('новая, сегодня', date: '09.09.2026', time: '12:00', withColumns: false),
      ];
      expect(sortedTitles(tasks), ['новая, сегодня', 'старая, завтра']);
    });

    test('режим «по сроку» — это тот же компаратор', () {
      final tasks = [
        task('завтра утром', date: '10.09.2026', time: '09:00'),
        task('сегодня вечером', date: '09.09.2026', time: '18:00'),
      ];
      final byMode = [...tasks]..sort(taskComparator(TaskSortMode.due));
      expect(byMode.map((t) => t['title']), ['сегодня вечером', 'завтра утром']);
    });

    test('два формата времени в одном списке сравниваются верно', () {
      // due_at_time приходит как «ЧЧ:ММ:СС», due_time — как «ЧЧ:ММ».
      // Посимвольно эти форматы сравнивать нельзя.
      final withColumn = task('с колонкой 09:30', date: '09.09.2026', time: '09:30');
      final withoutColumn =
          task('строкой 08:00', date: '09.09.2026', time: '08:00', withColumns: false);
      expect(sortedTitles([withColumn, withoutColumn]),
          ['строкой 08:00', 'с колонкой 09:30']);
    });
  });

  group('режимы сортировки', () {
    List<String> byMode(TaskSortMode mode, List<Map<String, dynamic>> tasks) =>
        ([...tasks]..sort(taskComparator(mode)))
            .map((t) => t['title'] as String)
            .toList();

    test('по приоритету: срочные выше, без приоритета — последние', () {
      final tasks = [
        {...task('обычная', date: '09.09.2026'), 'priority': 'blue'},
        {...task('без приоритета', date: '09.09.2026'), 'priority': 'none'},
        {...task('срочная', date: '09.09.2026'), 'priority': 'red'},
      ];
      expect(byMode(TaskSortMode.priority, tasks),
          ['срочная', 'обычная', 'без приоритета']);
    });

    test('по приоритету: внутри одного уровня — по сроку', () {
      final tasks = [
        {...task('срочная завтра', date: '10.09.2026'), 'priority': 'red'},
        {...task('срочная сегодня', date: '09.09.2026'), 'priority': 'red'},
      ];
      expect(byMode(TaskSortMode.priority, tasks),
          ['срочная сегодня', 'срочная завтра']);
    });

    test('по названию: регистр не разрывает алфавит', () {
      // При сравнении «как есть» все заглавные ушли бы вперёд, и «Ананас»
      // оказался бы далеко от «арбуза».
      final tasks = [
        task('арбуз', date: '09.09.2026'),
        task('Ананас', date: '09.09.2026'),
        task('Банан', date: '09.09.2026'),
      ];
      expect(byMode(TaskSortMode.title, tasks), ['Ананас', 'арбуз', 'Банан']);
    });

    test('по дате создания: свежие сверху, без даты — в конце', () {
      final tasks = [
        {...task('старая', date: '09.09.2026'), 'created_at': '2026-09-01T10:00:00Z'},
        {...task('без метки', date: '09.09.2026')},
        {...task('свежая', date: '09.09.2026'), 'created_at': '2026-09-09T10:00:00Z'},
      ];
      expect(byMode(TaskSortMode.created, tasks),
          ['свежая', 'старая', 'без метки']);
    });

    test('вручную: пока ничего не перетаскивали, порядок как по сроку', () {
      // У всех задач order_index == 0 (так лежит в базе до первого
      // перетаскивания) — список не должен превращаться в случайную россыпь.
      final tasks = [
        {...task('завтра', date: '10.09.2026', time: '09:00'), 'order_index': 0},
        {...task('сегодня', date: '09.09.2026', time: '18:00'), 'order_index': 0},
      ];
      expect(byMode(TaskSortMode.manual, tasks), ['сегодня', 'завтра']);
    });

    test('вручную: выставленный порядок важнее срока', () {
      final tasks = [
        {...task('сегодня', date: '09.09.2026', time: '09:00'), 'order_index': 2},
        {...task('завтра', date: '10.09.2026', time: '09:00'), 'order_index': 1},
      ];
      expect(byMode(TaskSortMode.manual, tasks), ['завтра', 'сегодня']);
    });

    test('выбор режима переживает перезапуск через строковый ключ', () {
      for (final mode in TaskSortMode.values) {
        expect(TaskSortModeInfo.fromStorage(mode.storageKey), mode);
      }
      // Неизвестное значение (старая версия, испорченный бокс) не должно
      // ронять приложение — откатываемся к сортировке по сроку.
      expect(TaskSortModeInfo.fromStorage('чего-то_такого_нет'), TaskSortMode.due);
      expect(TaskSortModeInfo.fromStorage(null), TaskSortMode.due);
    });
  });
}
