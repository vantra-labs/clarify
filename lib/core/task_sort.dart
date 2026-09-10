import 'clarify_date_format.dart';
import 'priority.dart';

/// Способ упорядочить список задач.
///
/// Набор выбран по разбору конкурентов (см. docs/COMPETITOR_RESEARCH_2026-08-16.md
/// и COMPETITOR_ANALYSIS.md): срок, приоритет, название, дата создания и ручной
/// порядок — это то, что повторяется у Todoist, TickTick, Microsoft To Do и
/// SingularityApp почти дословно. Сортировки по тегу сознательно нет: тег у
/// задачи один и уже работает как проект в меню слева, так что она показала бы
/// те же группы второй раз.
enum TaskSortMode {
  /// Дата, затем время. Значение по умолчанию — им список жил всегда.
  due,

  /// Сначала срочные. Внутри одного приоритета — по сроку.
  priority,

  /// По алфавиту. Нужен ровно для одного: найти задачу глазами в длинном списке.
  title,

  /// Сначала недавно добавленные — «что я накидал давно и так и не сделал».
  created,

  /// Порядок, который человек выставил сам перетаскиванием.
  manual,
}

/// Ключ для Hive и подпись для интерфейса.
extension TaskSortModeInfo on TaskSortMode {
  String get storageKey => name;

  /// Подпись на русском; перевод берётся обычным `.tr()` на месте показа.
  String get label => switch (this) {
        TaskSortMode.due => 'По сроку',
        TaskSortMode.priority => 'По приоритету',
        TaskSortMode.title => 'По названию',
        TaskSortMode.created => 'По дате создания',
        TaskSortMode.manual => 'Вручную',
      };

  static TaskSortMode fromStorage(String? value) => TaskSortMode.values
      .firstWhere((m) => m.name == value, orElse: () => TaskSortMode.due);
}

/// Компаратор для выбранного способа.
///
/// У каждого режима есть запасное сравнение по сроку: у половины задач нет ни
/// приоритета, ни времени создания, и без него порядок внутри таких групп
/// становился бы случайным и прыгал между перерисовками.
int Function(Map<String, dynamic>, Map<String, dynamic>) taskComparator(
  TaskSortMode mode,
) =>
    switch (mode) {
      TaskSortMode.due => compareTasksByDue,
      TaskSortMode.priority => _byPriority,
      TaskSortMode.title => _byTitle,
      TaskSortMode.created => _byCreated,
      TaskSortMode.manual => _byManualOrder,
    };

int _byPriority(Map<String, dynamic> a, Map<String, dynamic> b) {
  final rank = priorityRank(a['priority'] as String?)
      .compareTo(priorityRank(b['priority'] as String?));
  return rank != 0 ? rank : compareTasksByDue(a, b);
}

int _byTitle(Map<String, dynamic> a, Map<String, dynamic> b) {
  // Без учёта регистра: иначе «Ананас» и «арбуз» разъезжаются по разным концам
  // списка, потому что заглавные буквы в кодировке идут раньше строчных.
  final byTitle = (a['title'] as String? ?? '')
      .toLowerCase()
      .compareTo((b['title'] as String? ?? '').toLowerCase());
  return byTitle != 0 ? byTitle : compareTasksByDue(a, b);
}

int _byCreated(Map<String, dynamic> a, Map<String, dynamic> b) {
  final createdA = DateTime.tryParse(a['created_at'] as String? ?? '');
  final createdB = DateTime.tryParse(b['created_at'] as String? ?? '');
  // Без даты создания — в конец: это записи, сделанные до появления колонки,
  // и ставить их первыми значило бы соврать про «самое свежее сверху».
  if (createdA == null && createdB == null) return compareTasksByDue(a, b);
  if (createdA == null) return 1;
  if (createdB == null) return -1;
  final byCreated = createdB.compareTo(createdA);
  return byCreated != 0 ? byCreated : compareTasksByDue(a, b);
}

int _byManualOrder(Map<String, dynamic> a, Map<String, dynamic> b) {
  final orderA = (a['order_index'] as int?) ?? 0;
  final orderB = (b['order_index'] as int?) ?? 0;
  // Пока человек ничего не перетаскивал, у всех задач порядок одинаковый —
  // тогда список должен выглядеть как обычно, а не как случайная россыпь.
  return orderA != orderB ? orderA.compareTo(orderB) : compareTasksByDue(a, b);
}

/// Сравнение задач по сроку: сначала дата, потом время.
///
/// Появилось из-за живой жалобы 09.09.2026: в списках, где задачи разных дней,
/// сортировка сравнивала ТОЛЬКО `due_time`, и завтрашняя задача на 09:00
/// оказывалась выше сегодняшней на 18:00. Одинаковое сравнение было написано
/// в трёх местах независимо (список задач и командный список на мобильном,
/// общий список на десктопе), поэтому исправление вынесено в одну функцию —
/// иначе четвёртый список повторит ту же ошибку.
///
/// Даты нельзя сравнивать как строки: `due_date` хранится как «ДД.ММ.ГГГГ», и
/// посимвольно «31.08.2026» больше «05.09.2026». Разбираем через
/// [taskDueDate], который берёт настоящую колонку-дату, а строку использует
/// запасным путём (у только что созданной задачи другой ещё нет).
///
/// ВАЖНО: не применять к спискам, заведомо ограниченным одним днём — экран
/// «Сегодня», лента дня в календаре. Там дата у всех одна, сравнение по ней
/// ничего не даёт, а лишний разбор даты на каждый шаг сортировки — трата.
int compareTasksByDue(Map<String, dynamic> a, Map<String, dynamic> b) {
  final dateA = taskDueDate(a);
  final dateB = taskDueDate(b);

  // Задачи без срока — всегда в конце. Раньше они оказывались там же, но по
  // случайности: время подставлялось как «23:59», и они просто проигрывали
  // почти всему. Теперь это явное правило, а не побочный эффект заглушки.
  if (dateA == null && dateB != null) return 1;
  if (dateA != null && dateB == null) return -1;

  if (dateA != null && dateB != null) {
    final byDate = dateA.compareTo(dateB);
    if (byDate != 0) return byDate;
  }

  // Внутри одного дня — по времени. Задача без времени считается на конец дня:
  // «когда-то сегодня» логичнее показать после того, что назначено на час.
  //
  // Через taskDueTime, а не сравнением строк: время лежит в двух видах —
  // колонка `due_at_time` как «ЧЧ:ММ:СС» и строковая `due_time` как «ЧЧ:ММ».
  // Посимвольно эти два формата между собой сравнивать нельзя, а в одном
  // списке могут оказаться обе (у только что созданной задачи колонки ещё
  // не заполнены триггером).
  final timeA = taskDueTime(a) ?? const (23, 59);
  final timeB = taskDueTime(b) ?? const (23, 59);
  final byHour = timeA.$1.compareTo(timeB.$1);
  return byHour != 0 ? byHour : timeA.$2.compareTo(timeB.$2);
}
