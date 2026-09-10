import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../core/localization.dart';
import '../../core/theme/design_tokens.dart';
import '../../core/app_settings.dart';
import '../../core/quick_parse.dart';
import '../../core/task_sort.dart';
import '../../widgets/clarify_sort_selector.dart';
import '../../widgets/clarify_cascade_item.dart';
import '../../widgets/clarify_completed_group.dart';
import '../../widgets/clarify_illustrations.dart';
import '../../widgets/clarify_quick_add.dart';
import 'mobile_search_screen.dart';
import 'widgets/mobile_mini_calendar.dart';
import 'widgets/swipe_to_delete_task_row.dart';

enum _TaskFilter { today, upcoming, inbox, all }

/// "Задачи" — единый фильтруемый список вместо четырёх отдельных пунктов
/// десктопного сайдбара (Мой день/Следующие 7 дней/Все задачи/Входящие).
/// На маленьком экране это один экран с переключателем сверху, а не четыре
/// таба, которые некуда физически поместить в нижней навигации.
class MobileTasksScreen extends StatefulWidget {
  final String currentLang;
  final List<Map<String, dynamic>> tasks;
  final Color Function(String? priority) getPriorityColor;
  final Map<String, int> Function(dynamic parentId) getSubtaskStats;
  final bool Function(Map<String, dynamic> task) isOverdue;
  final void Function(Map<String, dynamic> task) onToggle;
  final void Function(dynamic taskId) onDelete;
  final void Function(Map<String, dynamic> task) onTap;
  final void Function(dynamic taskId, Map<String, dynamic> updates)
  onQuickUpdateTask;
  /// Быстрое добавление строкой (C1). На телефоне его не было вовсе: задачу
  /// можно было завести только через форму с полями, хотя на ПК хватало одной
  /// строки. «Не должно быть отличий в базовых вещах» — то же правило, по
  /// которому сюда раньше добавляли выбор команды.
  final Future<void> Function(QuickParseResult parsed) onQuickCreate;

  /// Сохранить порядок после перетаскивания. Экран сам в базу не ходит —
  /// сервис задач живёт у владельца оболочки, и ходить в него из каждого
  /// экрана значило бы завести второй путь записи мимо очереди отправки.
  final void Function(List<Map<String, dynamic>> orderedTasks) onReorderSaved;

  final DateTime? initialDate;
  final Set<String> datesWithTasks;
  final Map<String, int> dateLoadMinutes;

  const MobileTasksScreen({
    super.key,
    required this.currentLang,
    required this.tasks,
    required this.getPriorityColor,
    required this.getSubtaskStats,
    required this.isOverdue,
    required this.onToggle,
    required this.onDelete,
    required this.onTap,
    required this.onQuickUpdateTask,
    required this.onQuickCreate,
    required this.onReorderSaved,
    required this.datesWithTasks,
    required this.dateLoadMinutes,
    this.initialDate,
  });

  @override
  State<MobileTasksScreen> createState() => _MobileTasksScreenState();
}

class _MobileTasksScreenState extends State<MobileTasksScreen> {
  _TaskFilter _filter = _TaskFilter.today;
  late DateTime? _calendarDate = widget.initialDate;

  String _formatDate(DateTime d) => '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

  String get _emptyStateKey {
    if (_calendarDate != null) return 'На эту дату ничего не запланировано';
    switch (_filter) {
      case _TaskFilter.today:
        return 'На сегодня ничего не запланировано';
      case _TaskFilter.upcoming:
        return 'На ближайшие 7 дней ничего не запланировано';
      case _TaskFilter.inbox:
        return 'Во входящих пока пусто';
      case _TaskFilter.all:
        return 'Задач пока нет';
    }
  }

  ClarifyIllustrationType get _emptyIllustration {
    if (_calendarDate != null) return ClarifyIllustrationType.checklistFold;
    switch (_filter) {
      case _TaskFilter.today:
        return ClarifyIllustrationType.sunHorizon;
      case _TaskFilter.upcoming:
        return ClarifyIllustrationType.checklistFold;
      case _TaskFilter.inbox:
        return ClarifyIllustrationType.inboxEmpty;
      case _TaskFilter.all:
        return ClarifyIllustrationType.checklistFold;
    }
  }

  List<Map<String, dynamic>> get _filtered {
    final base = widget.tasks.where((t) => t['parent_id'] == null).toList();
    if (_calendarDate != null) {
      final dateStr = _formatDate(_calendarDate!);
      return base.where((t) => t['due_date'] == dateStr).toList();
    }
    switch (_filter) {
      case _TaskFilter.today:
        final todayStr = _formatDate(DateTime.now());
        return base.where((t) => t['due_date'] == todayStr).toList();
      case _TaskFilter.upcoming:
        final now = DateTime.now();
        final dates = {for (var i = 0; i < 7; i++) _formatDate(now.add(Duration(days: i)))};
        return base.where((t) => t['due_date'] != null && dates.contains(t['due_date'])).toList();
      case _TaskFilter.inbox:
        return base.where((t) => t['due_date'] == null || t['due_date'] == '').toList();
      case _TaskFilter.all:
        return base;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Подписка на способ сортировки: сам выбор живёт в ClarifySortSelector в
    // шапке, но перерисовать надо список ниже, а не только подпись в меню.
    return ValueListenableBuilder<TaskSortMode>(
      valueListenable: AppSettings.taskSortMode,
      builder: (context, sortMode, _) => _buildContent(context, sortMode),
    );
  }

  Widget _buildContent(BuildContext context, TaskSortMode sortMode) {
    final t = context.tokens;
    // Способ сортировки общий с десктопом. По умолчанию — по сроку целиком:
    // в режимах «Предстоящие» и «Все» здесь лежат задачи разных дней, и
    // сравнение только по времени, стоявшее раньше, поднимало завтрашнюю
    // задачу на 09:00 выше сегодняшней на 18:00.
    final sorted = _filtered..sort(taskComparator(sortMode));
    // Выполненные — отдельным свёрнутым блоком под списком, как на ПК. Раньше
    // они лежали вперемешку с активными: способ сортировки про отметку ничего
    // не знает, поэтому сделанное утром стояло между двумя несделанными.
    final tasks = sorted.where((t) => t['is_completed'] != true).toList();
    final completedTasks = sorted.where((t) => t['is_completed'] == true).toList();

    Widget buildRow(Map<String, dynamic> task) => SwipeToDeleteTaskRow(
          task: task,
          currentLang: widget.currentLang,
          showDate: _filter != _TaskFilter.today,
          priorityColor: widget.getPriorityColor(task['priority']),
          subtaskStats: widget.getSubtaskStats(task['id']),
          overdue: widget.isOverdue(task),
          onToggle: () => widget.onToggle(task),
          onConfirmedDelete: () => widget.onDelete(task['id']),
          onTap: () => widget.onTap(task),
          onQuickUpdateTask: (updates) => widget.onQuickUpdateTask(task['id'], updates),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 12, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Задачи'.tr(widget.currentLang), style: TextStyle(fontFamily: 'Golos Text', fontSize: 22, fontWeight: FontWeight.w700, color: t.text)),
                    const SizedBox(height: 2),
                    // Невидимый плейсхолдер той же высоты, что подпись даты на "Мой
                    // день" (MobileTodayScreen) — без него календарная плашка и
                    // пустое состояние оказываются на разной высоте между вкладками.
                    Opacity(opacity: 0, child: Text('.', style: TextStyle(fontSize: 13, color: t.text3))),
                  ],
                ),
              ),
              // Только значок: в шапке рядом уже стоит поиск, и подпись
              // текущего способа вытолкнула бы его за край экрана.
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: ClarifySortSelector(
                  currentLang: widget.currentLang,
                  iconOnly: true,
                ),
              ),
              IconButton(
                icon: Icon(LucideIcons.search, color: t.text2),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => MobileSearchScreen(
                    currentLang: widget.currentLang,
                    tasks: widget.tasks,
                    getPriorityColor: widget.getPriorityColor,
                    getSubtaskStats: widget.getSubtaskStats,
                    isOverdue: widget.isOverdue,
                    onToggle: widget.onToggle,
                    onDelete: widget.onDelete,
                    onTap: widget.onTap,
                    onQuickUpdateTask: widget.onQuickUpdateTask,
                  ),
                )),
              ),
            ],
          ),
        ),
        MobileMiniCalendar(
          currentLang: widget.currentLang,
          selectedDate: _calendarDate ?? DateTime.now(),
          datesWithTasks: widget.datesWithTasks,
          dateLoadMinutes: widget.dateLoadMinutes,
          onDaySelected: (day) => setState(() => _calendarDate = day),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _FilterChip(label: 'Сегодня'.tr(widget.currentLang), active: _calendarDate == null && _filter == _TaskFilter.today, onTap: () => setState(() { _calendarDate = null; _filter = _TaskFilter.today; })),
                const SizedBox(width: 8),
                _FilterChip(label: '7 дней'.tr(widget.currentLang), active: _calendarDate == null && _filter == _TaskFilter.upcoming, onTap: () => setState(() { _calendarDate = null; _filter = _TaskFilter.upcoming; })),
                const SizedBox(width: 8),
                _FilterChip(label: 'Входящие'.tr(widget.currentLang), active: _calendarDate == null && _filter == _TaskFilter.inbox, onTap: () => setState(() { _calendarDate = null; _filter = _TaskFilter.inbox; })),
                const SizedBox(width: 8),
                _FilterChip(label: 'Все'.tr(widget.currentLang), active: _calendarDate == null && _filter == _TaskFilter.all, onTap: () => setState(() { _calendarDate = null; _filter = _TaskFilter.all; })),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Над списком, как на ПК: набрал строку — задача появилась, без
        // открытия формы. Дата раздела подставляется, если в строке её нет,
        // иначе «купить хлеб» во вкладке «Сегодня» уезжал бы во «Входящие».
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: ClarifyQuickAdd(
            currentLang: widget.currentLang,
            scale: 1.0,
            defaultDate: _calendarDate ??
                (_filter == _TaskFilter.today ? DateTime.now() : null),
            onSubmit: widget.onQuickCreate,
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: tasks.isEmpty && completedTasks.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ClarifyIllustration(type: _emptyIllustration, size: 72),
                        const SizedBox(height: 16),
                        Text(_emptyStateKey.tr(widget.currentLang), textAlign: TextAlign.center, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: t.text2)),
                        const SizedBox(height: 6),
                        Text('Нажмите «+», чтобы добавить задачу'.tr(widget.currentLang), textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: t.text3)),
                      ],
                    ),
                  ),
                )
              // Долгое нажатие прямо на строке задачи запускает переупорядочивание —
              // без отдельной ручки-хвата: она вносила визуальный шум и не
              // схлопывалась вместе со строкой при удалении/отмене (оставалась
              // висеть "осиротевшей" точкой, пока SwipeToDeleteTaskRow был уже
              // схлопнут). ReorderableDelayedDragStartListener ждёт задержку перед
              // стартом драга, поэтому не конфликтует с мгновенным горизонтальным
              // свайпом-удалением внутри SwipeToDeleteTaskRow — жесты различаются
              // по направлению и по задержке распознавания.
              : ReorderableListView.builder(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
                  // На десктопных платформах ReorderableListView рисует СВОЮ
                  // ручку перетаскивания поверх строки (две горизонтальные
                  // полосы у правого края) — она видна в веб-версии и в узком
                  // окне приложения на Windows, где включается мобильная
                  // раскладка. Своя ручка нам не нужна: перетаскивание уже
                  // запускается долгим нажатием на самой строке
                  // (ReorderableDelayedDragStartListener ниже), а лишний
                  // элемент к тому же наезжал на крестик удаления.
                  buildDefaultDragHandles: false,
                  itemCount: tasks.length,
                  // Блок выполненных — подвалом списка, а не отдельным
                  // прокручиваемым блоком под ним: иначе на экране появилось бы
                  // две независимые прокрутки.
                  footer: completedTasks.isEmpty
                      ? null
                      : ClarifyCompletedGroup(
                          currentLang: widget.currentLang,
                          tasks: completedTasks,
                          buildTaskCard: buildRow,
                        ),
                  // onReorderItem вместо устаревшего onReorder: он сам
                  // пересчитывает newIndex с учётом уже вынутого элемента,
                  // поэтому прежняя ручная поправка `if (newIndex > oldIndex)
                  // newIndex -= 1` здесь была бы двойной и сдвигала бы задачу
                  // на позицию выше нужной.
                  onReorderItem: (oldIndex, newIndex) {
                    setState(() {
                      final item = tasks.removeAt(oldIndex);
                      tasks.insert(newIndex, item);
                    });
                    // Порядок надо ещё и сохранить: до 09.09.2026 перетаскивание
                    // меняло только этот список в памяти, и всё возвращалось
                    // назад при первом же обновлении.
                    widget.onReorderSaved(tasks);
                  },
                  itemBuilder: (context, index) {
                    final task = tasks[index];
                    return ClarifyCascadeItem(
                      key: ValueKey('cascade_${task['id']}'),
                      index: index,
                      child: ReorderableDelayedDragStartListener(
                        key: ValueKey(task['id'].toString()),
                        index: index,
                        child: buildRow(task),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _FilterChip({required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(ClarifyRadius.pill),
      child: Container(
        // vertical:10, а не 8 — та же высота плашки, что у "Входящие" на
        // "Мой день" (MobileTodayScreen), иначе календарь и пустое состояние
        // между вкладками "прыгают" по высоте.
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: active ? t.accent : t.surface2,
          borderRadius: BorderRadius.circular(ClarifyRadius.pill),
          border: Border.all(color: active ? t.accent : t.border),
        ),
        child: Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: active ? t.onAccent : t.text2)),
      ),
    );
  }
}
