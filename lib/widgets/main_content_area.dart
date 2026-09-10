import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../core/app_settings.dart';
import '../core/clarify_date_format.dart';
import '../core/config.dart';
import '../core/localization.dart';
import '../core/quick_parse.dart';
import '../core/tags.dart';
import '../core/task_sort.dart';
import '../core/theme/design_tokens.dart';
import 'calendar_day_timeline.dart';
import 'clarify_cascade_item.dart';
import 'clarify_completed_group.dart';
import 'clarify_day_load_warning.dart' show ClarifyDayCapacity, dayLoadMinutes;
import 'clarify_sort_selector.dart';
import 'about_screen.dart';
import 'clarify_illustrations.dart';
import 'clarify_task_skeleton.dart';
import 'clarify_glass.dart';
import 'clarify_list_entrance.dart';
import 'clarify_press_glow.dart';
import 'clarify_quick_add.dart';
import 'clarify_reorder_flow.dart';
import 'clarify_surface.dart';
import 'friends_screen.dart';
import 'messenger_shell.dart';
import 'project_kanban_board.dart';
import 'projects_screen.dart';
import 'task_cards.dart' show TaskCardBuilders;

const List<String> _kWeekdaysRu = ['понедельник', 'вторник', 'среда', 'четверг', 'пятница', 'суббота', 'воскресенье'];

String _formatDate(DateTime date) {
  // Возвращаем правильный формат ДД.ММ.ГГГГ, чтобы он совпадал с БД
  return "${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}";
}

String _capitalize(String s) {
  if (s.isEmpty) return s;
  return s[0].toUpperCase() + s.substring(1).toLowerCase();
}

/// id задачи числом. Оптимистично созданная задача до ответа сервера носит
/// временный ОТРИЦАТЕЛЬНЫЙ id (см. TaskService.addTask), поэтому сравнивать
/// нужно как числа, а не как строки: '-17…' и '42' лексикографически
/// сравниваются не в том порядке, в каком задачи реально создавались.
int _taskIdOf(Map<String, dynamic> task) {
  final raw = task['id'];
  if (raw is int) return raw;
  return int.tryParse(raw?.toString() ?? '') ?? 0;
}

DateTime? _completedAtOf(Map<String, dynamic> task) {
  final raw = task['completed_at'];
  if (raw == null) return null;
  return DateTime.tryParse(raw.toString());
}

/// Порядок для колонок "7 дней" и ячеек календаря: по времени, а при равном
/// времени (у большинства задач его нет вовсе) — по id. Порядок сам по себе
/// не меняется, но перестаёт зависеть от того, в каком порядке задачи пришли
/// с сервера: List.sort в Dart не стабильна, и без второго ключа задачи с
/// одинаковым временем меняли места после каждого фетча.
int _byTimeThenId(Map<String, dynamic> a, Map<String, dynamic> b) {
  final timeCompare = (a['due_time'] ?? '23:59').compareTo(b['due_time'] ?? '23:59');
  if (timeCompare != 0) return timeCompare;
  return _taskIdOf(a).compareTo(_taskIdOf(b));
}

class MainContentArea extends StatelessWidget {
  final String selectedMenu;
  final String currentLang;
  final List<Map<String, dynamic>> filteredTasks;
  final bool isDark;
  final double scale;
  
  // Коллбеки для действий, чтобы виджет мог общаться с главным экраном
  final Function(int, int, List<Map<String, dynamic>>) onReorderTasks;
  final Function(Map<String, dynamic>, String, int) onTaskDropped;
  final Function(DateTime, int) onPlusTap;
  final Widget Function(Map<String, dynamic>) buildListTaskCard;
  final Widget Function(Map<String, dynamic>) buildBoardTaskCardExpanded;
  final Widget Function(Map<String, dynamic>) buildCalendarTaskCard;
  final Widget Function(Map<String, dynamic>) buildCalendarTaskChip;
  final Widget Function({required Widget child, EdgeInsetsGeometry? margin, EdgeInsetsGeometry? padding, Color? customColor}) buildGlassContainer;
  final Widget Function() buildStatisticsDashboard;
  final Widget Function() buildSettingsPanel;

  /// Раздел «Корзина» (C6) — строится родителем, как и настройки со
  /// статистикой: ему доступен TaskService, а этому виджету нет.
  final Widget Function() buildTrashPanel;

  /// Раздел «История» (B3) — выполненные задачи старше окна загрузки. Строится
  /// родителем по той же причине, что и корзина.
  final Widget Function() buildArchivePanel;
  final String Function(dynamic taskId) getLocalKanbanStatus;
  final void Function(dynamic taskId, String status) onSetLocalKanbanStatus;

  // Дата календаря передается как состояние
  final DateTime currentCalendarDate;
  final Function(DateTime) onCalendarDateChanged;

  // Экран "Проекты" — список авто-папок по тегам (см. projects_screen.dart).
  final Function(String) onMenuSelected;
  final Map<String, String> projectIconKeys;
  final void Function(String tag, String iconKey) onSetProjectIcon;
  final Map<String, int> projectColorKeys;
  final void Function(String tag, int colorIndex) onSetProjectColor;

  // Сортировка плоских списков — по времени (дефолт) или по приоритету
  // (MISSING_FEATURES P1.3). Не применяется во "Входящих" — там порядок
  // задаётся вручную перетаскиванием (см. комментарий у ReorderableListView ниже).
  // Способ сортировки больше не прокидывается сюда параметром: он один на всё
  // приложение и живёт в AppSettings.taskSortMode, откуда его читают и
  // десктопный список, и мобильный. Раньше здесь был флаг sortByPriority на
  // два состояния — прокидывать пять значений и колбэк смены через все экраны
  // означало бы то же самое, только длиннее.

  /// Первая загрузка с сервера ещё идёт (D3) — вместо пустого состояния
  /// показываем силуэты строк. «Задач нет» и «задачи ещё едут» выглядели
  /// одинаково, и новому человеку первым делом сообщалось, что у него пусто.
  final bool loading;

  /// Создание задачи из разобранной строки быстрого ввода (C1).
  /// null — строка не показывается (например, на экранах без списка задач).
  final Future<void> Function(QuickParseResult parsed)? onQuickCreate;

  /// id задач, у которых на время анимации выполнения порядок «заморожен» на
  /// прежнем значении is_completed — см. _toggleTask в DesktopPlannerScreen.
  /// Пусто в обычном состоянии.
  final Map<dynamic, int> frozenCompletedRanks;

  // Открыть личный чат в мессенджере (из карточки друга/профиля) — вместо
  // Navigator.push поверх всего шелла (тогда пропадали бы сайдбар и список
  // чатов, ломая 3-колоночный макет). Родитель переключает selectedMenu на
  // 'Сообщения' и прокидывает выбранного партнёра сюда же.
  final String? pendingChatPartnerId;
  final String? pendingChatPartnerName;
  final void Function(String partnerId, String partnerName)? onOpenDirectChat;

  const MainContentArea({
    super.key,
    required this.selectedMenu,
    required this.currentLang,
    required this.filteredTasks,
    required this.isDark,
    required this.scale,
    required this.onReorderTasks,
    required this.onTaskDropped,
    required this.onPlusTap,
    required this.buildListTaskCard,
    required this.buildBoardTaskCardExpanded,
    required this.buildCalendarTaskCard,
    required this.buildCalendarTaskChip,
    required this.buildGlassContainer,
    required this.buildStatisticsDashboard,
    required this.buildSettingsPanel,
    required this.buildTrashPanel,
    required this.buildArchivePanel,
    required this.getLocalKanbanStatus,
    required this.onSetLocalKanbanStatus,
    required this.currentCalendarDate,
    required this.onCalendarDateChanged,
    required this.onMenuSelected,
    required this.projectIconKeys,
    required this.onSetProjectIcon,
    required this.projectColorKeys,
    required this.onSetProjectColor,
    this.onQuickCreate,
    this.loading = false,
    this.frozenCompletedRanks = const {},
    this.pendingChatPartnerId,
    this.pendingChatPartnerName,
    this.onOpenDirectChat,
  });

  @override
  Widget build(BuildContext context) {
    // Подписка на выбранный способ сортировки — здесь, снаружи всего
    // содержимого: список задач собирается глубоко внутри, и без перерисовки
    // всей области смена режима в меню не доехала бы до него.
    return ValueListenableBuilder<TaskSortMode>(
      valueListenable: AppSettings.taskSortMode,
      builder: (context, sortMode, _) => _buildContent(context, sortMode),
    );
  }

  Widget _buildContent(BuildContext context, TaskSortMode sortMode) {
    final t = isDark ? ClarifyTokens.dark : ClarifyTokens.light;
    final textColor = t.text;
    final textMuted = t.text2;
    final glassBorderColor = t.border;
    final highlightColor = t.accentSoft;
    final emptyCellColor = t.surfaceSunken.withValues(alpha: isDark ? 0.5 : 0.6);

    final List<String> weekdaysRu = _kWeekdaysRu;

    const reservedMenuKeys = {'Мой день', 'Следующие 7 дней', 'Все задачи', 'Календарь', 'Входящие', 'Проекты', 'Друзья', 'Сообщения', 'Статистика', 'Настройки', 'История', 'Корзина', 'О приложении'};
    final isTagProject = !reservedMenuKeys.contains(selectedMenu) && !selectedMenu.startsWith('ws_');

    if (isTagProject) {
      // Проект — авто-папка по тегу, доска (Не начато/В работе/Готово), а не
      // плоский список. См. REDESIGN_V2_PLAN.md §3.5, REDESIGN_V3_PLAN.md §3.17/5.16.
      final storedColorIndex = projectColorKeys[selectedMenu];
      final projectColor = storedColorIndex != null && storedColorIndex < t.tagPalette.length
          ? t.tagPalette[storedColorIndex]
          : t.tagPalette[selectedMenu.hashCode.abs() % t.tagPalette.length];
      final projectTasks = filteredTasks.where((task) {
        final tags = parseTagsString(task['tags']);
        return tags.contains(selectedMenu) && task['parent_id'] == null;
      }).toList();
      return ProjectKanbanBoard(
        projectName: selectedMenu,
        projectColor: projectColor,
        currentLang: currentLang,
        scale: scale,
        tasks: projectTasks,
        getLocalStatus: getLocalKanbanStatus,
        onSetLocalStatus: onSetLocalKanbanStatus,
        buildBoardTaskCardExpanded: buildBoardTaskCardExpanded,
        buildGlassContainer: buildGlassContainer,
      );
    }
    else if (selectedMenu == 'Все задачи' || selectedMenu == 'Мой день' || selectedMenu == 'Входящие' || selectedMenu.startsWith('ws_')) {
      List<Map<String, dynamic>> targetTasks = filteredTasks;

      if (selectedMenu == 'Мой день') {
        final todayStr = _formatDate(DateTime.now());
        targetTasks = filteredTasks.where((t) => t['due_date'] == todayStr && t['parent_id'] == null).toList();
      } else if (selectedMenu == 'Входящие') {
        targetTasks = filteredTasks.where((t) => (t['due_date'] == null || t['due_date'] == '') && t['parent_id'] == null).toList();
      } else if (selectedMenu.startsWith('ws_')) {
        int wsId = int.parse(selectedMenu.substring(3));
        targetTasks = filteredTasks.where((t) => t['workspace_id'] == wsId && t['parent_id'] == null).toList();
      } else {
        targetTasks = filteredTasks.where((t) => t['parent_id'] == null).toList();
      }

      // Одинаковое время (чаще всего — у обеих задач его вообще нет) раньше
      // ничем не разрешалось, порядок был случайным (как пришло с сервера) —
      // разнородные по смыслу задачи оказывались вперемешку. Группировка по
      // первому тегу для таких "ничьих" снижает стоимость переключения
      // контекста между разными по смыслу задачами, не трогая порядок для
      // задач, у которых время реально задано и различается.
      int sameTimeTiebreak(Map<String, dynamic> a, Map<String, dynamic> b) {
        final tagsA = parseTagsString(a['tags']);
        final tagsB = parseTagsString(b['tags']);
        final tagCompare = (tagsA.isEmpty ? '' : tagsA.first).compareTo(tagsB.isEmpty ? '' : tagsB.first);
        if (tagCompare != 0) return tagCompare;
        // Последний рубеж — id. Без него у задач с одинаковыми временем и
        // тегом (а чаще всего у обеих нет ни того, ни другого) ключи
        // сортировки совпадают полностью, а List.sort в Dart НЕ стабильна:
        // порядок таких задач определялся тем, в каком порядке их отдал
        // сервер, и менялся при каждом повторном запросе — в том числе при
        // realtime-фетче сразу после отметки "выполнено". Это и выглядело
        // как "задача прыгает по списку, ища своё место".
        return _taskIdOf(a).compareTo(_taskIdOf(b));
      }

      // Выполненные — отдельным блоком в самом низу (фидбек 2026-09-03).
      // Раньше отметка вообще не влияла на позицию: задача оставалась среди
      // активных, а её место в списке пересчитывалось на каждом фетче.
      // Пока идёт анимация выполнения, ранг заморожен на прежнем значении:
      // иначе перестановка стартует одновременно с зачёркиванием, два разных
      // движения накладываются друг на друга и вместе читаются как рывок.
      // Отпускаем ранг после ClarifyMotion.completion — тогда переезд строки
      // становится отдельным, различимым движением (ClarifyReorderFlow).
      int completedRank(Map<String, dynamic> t) {
        final frozen = frozenCompletedRanks[t['id']];
        if (frozen != null) return frozen;
        return t['is_completed'] == true ? 1 : 0;
      }

      // Внутри блока выполненных — свежие сверху, по моменту отметки.
      // completed_at появился позже самой отметки задач, поэтому у старых
      // записей его нет: для них фолбэк — дата задачи, затем id.
      int completedBlockCompare(Map<String, dynamic> a, Map<String, dynamic> b) {
        final completedA = _completedAtOf(a);
        final completedB = _completedAtOf(b);
        if (completedA != null && completedB != null && completedA != completedB) {
          return completedB.compareTo(completedA);
        }
        if (completedA != null && completedB == null) return -1;
        if (completedA == null && completedB != null) return 1;
        final dateA = parseClarifyDate(a['due_date'] as String?);
        final dateB = parseClarifyDate(b['due_date'] as String?);
        if (dateA != null && dateB != null && dateA != dateB) return dateB.compareTo(dateA);
        return _taskIdOf(b).compareTo(_taskIdOf(a));
      }

      // Во «Входящих» лежат задачи без срока и, как правило, без приоритета —
      // любой способ, кроме ручного, дал бы там один и тот же список.
      final effectiveMode =
          selectedMenu == 'Входящие' && sortMode != TaskSortMode.manual
              ? TaskSortMode.due
              : sortMode;
      final compare = taskComparator(effectiveMode);

      targetTasks.sort((a, b) {
        // Выполненные — всегда отдельным блоком внизу, независимо от способа
        // сортировки: это не «ещё один порядок», а разделение на «делать» и
        // «сделано». Внутри блока свой порядок — по моменту отметки.
        final doneCompare = completedRank(a).compareTo(completedRank(b));
        if (doneCompare != 0) return doneCompare;
        if (completedRank(a) == 1) return completedBlockCompare(a, b);

        // Раньше здесь сравнивалось ТОЛЬКО время, из-за чего в списках с
        // задачами разных дней («Все задачи», проект по тегу) завтрашняя задача
        // на 09:00 вставала выше сегодняшней на 18:00. У блока выполненных выше
        // дата в сравнении была, у активных её забыли — жалоба владельца
        // 09.09.2026.
        final byMode = compare(a, b);
        if (byMode != 0) return byMode;
        return sameTimeTiebreak(a, b);
      });
      // Быстрое добавление строкой (C1). Показывается в плоских списках задач,
      // где «добавить ещё одну» — самое частое действие. В календаре и на доске
      // проекта своя логика добавления (плюс в ячейке дня, колонка статуса),
      // туда эта строка не лезет.
      //
      // Объявлено ДО ветки пустого списка: именно на пустом экране строка нужна
      // больше всего — иначе новому человеку предлагается любоваться
      // иллюстрацией и искать, куда нажать.
      final quickAdd = onQuickCreate == null
          ? null
          : ClarifyQuickAdd(
              currentLang: currentLang,
              scale: scale,
              // Раздел подставляет своё только если человек ничего не сказал:
              // в «Моём дне» задача без даты — почти наверняка на сегодня, а в
              // проекте — почти наверняка с его тегом.
              defaultDate: selectedMenu == 'Мой день' ? DateTime.now() : null,
              defaultTag: isTagProject ? selectedMenu : null,
              onSubmit: onQuickCreate!,
            );

      // Силуэты вместо пустого состояния, пока данные ещё не пришли.
      if (targetTasks.isEmpty && loading) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ?quickAdd,
            Expanded(child: ClarifyTaskSkeleton(scale: scale)),
          ],
        );
      }

      if (targetTasks.isEmpty) {
        final String emptyKey;
        final String hintKey;
        final ClarifyIllustrationType illustration;
        if (selectedMenu == 'Мой день') {
          emptyKey = 'На сегодня ничего не запланировано';
          hintKey = 'Хороший момент, чтобы решить, чем займётесь';
          illustration = ClarifyIllustrationType.sunHorizon;
        } else if (selectedMenu == 'Входящие') {
          emptyKey = 'Во входящих пока пусто';
          hintKey = 'Сюда попадают задачи без даты';
          illustration = ClarifyIllustrationType.inboxEmpty;
        } else if (selectedMenu.startsWith('ws_')) {
          emptyKey = 'В этой команде пока нет задач';
          hintKey = 'Создайте первую и назначьте ответственного';
          illustration = ClarifyIllustrationType.teamOrbit;
        } else {
          emptyKey = 'Задач пока нет';
          hintKey = 'Нажмите «Создать задачу», чтобы начать';
          illustration = ClarifyIllustrationType.checklistFold;
        }
        // Было: одна серая строка по центру пустого экрана — она читалась как
        // сбой загрузки, а видит её первым делом как раз новый человек.
        // Иллюстрации и подсказки уже были на мобильном (mobile_tasks_screen),
        // на десктопе их просто не довели.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ?quickAdd,
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ClarifyIllustration(type: illustration, size: 84),
                    const SizedBox(height: 18),
                    Text(
                      emptyKey.tr(currentLang),
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: t.text2),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      hintKey.tr(currentLang),
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, color: t.text3),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      }

      // Полоса ёмкости дня — только в «Моём дне»: в «Всех задачах» или в
      // команде сумма длительностей за все даты сразу не значит ничего.
      final dayCapacity = selectedMenu == 'Мой день'
          ? ClarifyDayCapacity(
              plannedMinutes: dayLoadMinutes(filteredTasks, _formatDate(DateTime.now())),
              capacityMinutes: AppConfig.dailyLoadWarningMinutes,
              taskCount: targetTasks.where((t) => t['is_completed'] != true).length,
              currentLang: currentLang,
            )
          : null;

      // Во «Входящих» выбор не показываем: там задачи без срока и приоритета,
      // и любой способ дал бы тот же список (см. effectiveMode выше).
      final sortToggle = selectedMenu == 'Входящие'
          ? null
          : Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: ClarifySortSelector(currentLang: currentLang, scale: scale),
              ),
            );

      if (selectedMenu == 'Входящие') {
        // Единственное место, где остаётся drag — здесь у задач нет даты,
        // поэтому порядок в списке ничем, кроме самого пользователя, не
        // задан; перетаскивание — единственный способ его выставить вручную.
        //
        // buildDefaultDragHandles:false + свой ReorderableDragStartListener —
        // дефолтная ручка Flutter на десктопе накладывается Positioned'ом
        // поверх карточки по правому краю, центрированная по ВСЕЙ высоте
        // плитки, а не по верху, как крестик удаления внутри самой карточки —
        // отсюда ручка и крестик были на разных высотах.
        //
        // proxyDecorator переопределён — дефолтный оборачивает перетаскиваемый
        // элемент в `Material(elevation: ...)` БЕЗ borderRadius/shape; поверх
        // скруглённой стеклянной карточки (ClipRRect + BackdropFilter внутри
        // buildGlassContainer) это давало несовпадающие границы тени/клипа —
        // отсюда "режется криво" при зажатой ручке. Лёгкий scale вместо
        // elevation не конфликтует со скруглением/блюром карточки.
        return ClarifyListEntrance(
          child: ReorderableListView(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            buildDefaultDragHandles: false,
            proxyDecorator: (child, index, animation) {
              return AnimatedBuilder(
                animation: animation,
                builder: (context, _) {
                  final t = ClarifyMotion.spring.transform(animation.value);
                  return Transform.scale(scale: 1.0 + 0.02 * t, child: child);
                },
                child: child,
              );
            },
            // onReorderItem вместо устаревшего onReorder: newIndex здесь уже
            // пересчитан с учётом вынутого элемента, поэтому обработчик НЕ
            // должен вычитать единицу сам (см. onReorderTasks в
            // desktop_planner_screen.dart).
            onReorderItem: (int oldIndex, int newIndex) {
              onReorderTasks(oldIndex, newIndex, targetTasks);
            },
            children: targetTasks.asMap().entries.map((entry) {
              final index = entry.key;
              final task = entry.value;
              // Отдельной ручки-хвата больше нет (2026-09-04): перетаскивание
              // запускается долгим нажатием на самой строке, как и на
              // мобильном. Ручка была лишним элементом в каждой строке и
              // ломала выравнивание — на узком окне наезжала на крестик
              // удаления.
              return ClarifyCascadeItem(
                key: ValueKey('cascade_${task['id']}'),
                index: index,
                child: ReorderableDelayedDragStartListener(
                  key: ValueKey(task['id'].toString()),
                  index: index,
                  child: buildListTaskCard(task),
                ),
              );
            }).toList(),
          ),
        );
      } else {
        // Выполненные отделяются от активных по тому же ранжированию, что и
        // сортировка выше, — значит на время анимации отметки строка ещё
        // считается активной и уезжает в блок выполненных уже после неё, а не
        // исчезает из-под пальца.
        final activeTasks = targetTasks.where((t) => completedRank(t) == 0).toList();
        final completedTasks = targetTasks.where((t) => completedRank(t) == 1).toList();

        return ClarifyListEntrance(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ?dayCapacity,
              ?quickAdd,
              ?sortToggle,
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  children: [
                    // Порядок здесь меняется не только при загрузке, но и прямо
                    // под пальцем — при отметке "выполнено" задача уезжает из
                    // активных вниз. ClarifyReorderFlow превращает эту смену
                    // мест в видимое движение: соседи синхронно поднимаются на
                    // освободившееся место.
                    ClarifyReorderFlow(
                      children: activeTasks.asMap().entries.map((entry) {
                        return ClarifyCascadeItem(
                          key: ValueKey('cascade_${entry.value['id']}'),
                          index: entry.key,
                          child: buildListTaskCard(entry.value),
                        );
                      }).toList(),
                    ),
                    if (completedTasks.isNotEmpty)
                      ClarifyCompletedGroup(
                        currentLang: currentLang,
                        tasks: completedTasks,
                        buildTaskCard: buildListTaskCard,
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      }
    }
    else if (selectedMenu == 'Следующие 7 дней') {
      // Содержимое колонки без внешней обёртки (Expanded/SizedBox) — она отличается
      // между брейкпоинтами, сама колонка — нет.
      Widget dayColumn(int index) {
        final targetDate = DateTime.now().add(Duration(days: index));
        final dateStr = _formatDate(targetDate);
        final dayTasks = filteredTasks.where((t) => t['due_date'] == dateStr && t['parent_id'] == null).toList();
        dayTasks.sort(_byTimeThenId);

        final weekdayName = _capitalize(weekdaysRu[targetDate.weekday - 1]);
        String title = index == 0 ? 'Сегодня'.tr(currentLang) : (index == 1 ? 'Завтра'.tr(currentLang) : weekdayName);
        String subtitle = index < 2 ? weekdayName : "${targetDate.day.toString().padLeft(2, '0')}.${targetDate.month.toString().padLeft(2, '0')}";

        final bool isToday = index == 0;

        return DragTarget<Map<String, dynamic>>(
          onAcceptWithDetails: (details) => onTaskDropped(details.data, dateStr, dayTasks.length),
          builder: (context, candidateData, rejectedData) {
            return buildGlassContainer(
              margin: EdgeInsets.only(right: index == 6 ? 0 : 12 * scale),
              customColor: candidateData.isNotEmpty ? highlightColor : null,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Акцент "Сегодня" — полоса слева у заголовка, тот же приём,
                  // что уже используется в MobileTaskRow/аккаунт-блоке сайдбара,
                  // а не постоянная заливка фона (она уже занята drag-hover'ом).
                  Container(
                    padding: EdgeInsets.fromLTRB((isToday ? 13 : 16) * scale, 20 * scale, 16 * scale, 12 * scale),
                    decoration: isToday ? BoxDecoration(border: Border(left: BorderSide(color: t.accent, width: 3 * scale))) : null,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title.tr(currentLang), style: TextStyle(fontSize: 16 * scale, fontWeight: FontWeight.bold, color: isToday ? t.accent : textColor), maxLines: 1, overflow: TextOverflow.ellipsis), SizedBox(height: 4 * scale), Text(subtitle.tr(currentLang), style: TextStyle(fontSize: 13 * scale, color: textMuted, fontWeight: FontWeight.w600))]),
                  ),
                  Padding(padding: EdgeInsets.fromLTRB(12 * scale, 0, 12 * scale, 16 * scale), child: InkWell(borderRadius: BorderRadius.circular(12 * scale), onTap: () => onPlusTap(targetDate, dayTasks.length), child: Container(width: double.infinity, padding: EdgeInsets.symmetric(vertical: 6 * scale), decoration: BoxDecoration(color: Colors.transparent, borderRadius: BorderRadius.circular(12 * scale), border: Border.all(color: glassBorderColor, width: 1.0)), child: Icon(LucideIcons.plus, size: 16 * scale, color: textMuted)), ), ),
                  // Компактная карточка (та же, что в ячейках Календаря) вместо
                  // buildBoardTaskCardExpanded — единый визуальный язык; сама
                  // buildCalendarTaskCard уже оборачивает в LongPressDraggable.
                  Expanded(child: ListView.builder(padding: EdgeInsets.symmetric(horizontal: 12 * scale), itemCount: dayTasks.length, itemBuilder: (context, taskIndex) => buildCalendarTaskCard(dayTasks[taskIndex]))),
                ],
              ),
            );
          },
        );
      }

      return LayoutBuilder(builder: (context, constraints) {
        // Компакт: колонки не сжимаются ниже читаемой ширины — вместо этого
        // весь ряд скроллится горизонтально. Раньше все 7 колонок делили
        // ширину поровну и на узких окнах превращались в нечитаемые полоски.
        if (ClarifyBreakpoints.of(constraints.maxWidth) == ClarifyBreakpoint.compact) {
          return Padding(
            padding: EdgeInsets.symmetric(vertical: 8 * scale),
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: 24 * scale),
              itemCount: 7,
              itemBuilder: (context, index) => SizedBox(width: 240 * scale, child: dayColumn(index)),
            ),
          );
        }
        return Padding(
          padding: EdgeInsets.symmetric(horizontal: 24 * scale, vertical: 8 * scale),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: List.generate(7, (index) => Expanded(child: dayColumn(index))),
          ),
        );
      });
    }
    else if (selectedMenu == 'Календарь') {
      return _CalendarSection(
        currentLang: currentLang,
        scale: scale,
        isDark: isDark,
        t: t,
        textColor: textColor,
        textMuted: textMuted,
        highlightColor: highlightColor,
        emptyCellColor: emptyCellColor,
        filteredTasks: filteredTasks,
        buildGlassContainer: buildGlassContainer,
        buildCalendarTaskCard: buildCalendarTaskCard,
        buildCalendarTaskChip: buildCalendarTaskChip,
        buildListTaskCard: buildListTaskCard,
        onTaskDropped: onTaskDropped,
        onPlusTap: onPlusTap,
        currentCalendarDate: currentCalendarDate,
        onCalendarDateChanged: onCalendarDateChanged,
      );
    }
    else if (selectedMenu == 'Друзья') {
      return FriendsScreen(
        currentLang: currentLang,
        scale: scale,
        onOpenConversation: (partnerId, name) => onOpenDirectChat?.call(partnerId, name),
      );
    }
    else if (selectedMenu == 'Сообщения') {
      return MessengerShell(
        currentLang: currentLang,
        scale: scale,
        buildGlassContainer: buildGlassContainer,
        initialPartnerId: pendingChatPartnerId,
        initialPartnerName: pendingChatPartnerName,
      );
    }
    else if (selectedMenu == 'Статистика') {
      return buildStatisticsDashboard();
    }
    else if (selectedMenu == 'Настройки') {
      return buildSettingsPanel();
    }
    else if (selectedMenu == 'О приложении') {
      return AboutScreen(currentLang: currentLang, scale: scale);
    }
    else if (selectedMenu == 'История') {
      return buildArchivePanel();
    }
    else if (selectedMenu == 'Корзина') {
      return buildTrashPanel();
    }
    else if (selectedMenu == 'Проекты') {
      return ProjectsScreen(
        isDark: isDark,
        currentLang: currentLang,
        scale: scale,
        tasks: filteredTasks,
        projectIconKeys: projectIconKeys,
        onSetProjectIcon: onSetProjectIcon,
        projectColorKeys: projectColorKeys,
        onSetProjectColor: onSetProjectColor,
        onOpenProject: onMenuSelected,
      );
    }
    return const SizedBox.shrink();
  }
}

/// Попап выбора месяца/года по клику на заголовок "Июль 2026" — без него
/// смена года требовала пролистать стрелками до 12 раз (REDESIGN_V3_PLAN.md
/// §5.10). Год листается стрелками, месяц — сеткой 3×4, тот же стеклянный
/// стиль, что и у showClarifyDatePicker.
Future<DateTime?> _showMonthYearPicker(BuildContext context, bool isDark, DateTime current) {
  return showClarifySurface<DateTime>(
    context: context,
    builder: (context) => _MonthYearPickerDialog(isDark: isDark, initial: current),
  );
}

class _MonthYearPickerDialog extends StatefulWidget {
  final bool isDark;
  final DateTime initial;

  const _MonthYearPickerDialog({required this.isDark, required this.initial});

  @override
  State<_MonthYearPickerDialog> createState() => _MonthYearPickerDialogState();
}

class _MonthYearPickerDialogState extends State<_MonthYearPickerDialog> {
  late int _year;
  static const _monthsRu = ['Янв', 'Фев', 'Мар', 'Апр', 'Май', 'Июн', 'Июл', 'Авг', 'Сен', 'Окт', 'Ноя', 'Дек'];

  @override
  void initState() {
    super.initState();
    _year = widget.initial.year;
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.isDark ? ClarifyTokens.dark : ClarifyTokens.light;

    return Center(
      child: Material(
        color: Colors.transparent,
        child: ClarifyGlass(
          borderRadius: BorderRadius.circular(ClarifyRadius.lg),
          padding: const EdgeInsets.all(20),
          child: SizedBox(
            width: 300,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(icon: Icon(LucideIcons.chevronLeft, color: t.text), onPressed: () => setState(() => _year--)),
                    Text('$_year', style: TextStyle(color: t.text, fontWeight: FontWeight.bold, fontSize: 18)),
                    IconButton(icon: Icon(LucideIcons.chevronRight, color: t.text), onPressed: () => setState(() => _year++)),
                  ],
                ),
                const SizedBox(height: 8),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, childAspectRatio: 1.6, crossAxisSpacing: 8, mainAxisSpacing: 8),
                  itemCount: 12,
                  itemBuilder: (context, index) {
                    final monthNum = index + 1;
                    final isSelected = _year == widget.initial.year && monthNum == widget.initial.month;
                    return Material(
                      color: isSelected ? t.accent : t.surfaceSunken,
                      borderRadius: BorderRadius.circular(ClarifyRadius.sm),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(ClarifyRadius.sm),
                        onTap: () => Navigator.of(context).pop(DateTime(_year, monthNum)),
                        child: Center(
                          child: Text(_monthsRu[index], style: TextStyle(color: isSelected ? t.onAccent : t.text, fontWeight: FontWeight.w600)),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Обёртка "Календаря" (REDESIGN_V4_PLAN.md §6.5): таймлайн дня — основной
/// вид на десктопе, месячная сетка — вторичный режим "обзор", переключаемый
/// явно кнопками в шапке. Выбранный день таймлайна хранится отдельно от
/// курсора месяца (currentCalendarDate/onCalendarDateChanged, приходит из
/// родителя) — переключение вида не должно сбрасывать позицию в другом.
class _CalendarSection extends StatefulWidget {
  final String currentLang;
  final double scale;
  final bool isDark;
  final ClarifyTokens t;
  final Color textColor;
  final Color textMuted;
  final Color highlightColor;
  final Color emptyCellColor;
  final List<Map<String, dynamic>> filteredTasks;
  final Widget Function({required Widget child, EdgeInsetsGeometry? margin, EdgeInsetsGeometry? padding, Color? customColor}) buildGlassContainer;
  final Widget Function(Map<String, dynamic>) buildCalendarTaskCard;
  final Widget Function(Map<String, dynamic>) buildCalendarTaskChip;
  final Widget Function(Map<String, dynamic>) buildListTaskCard;
  final Function(Map<String, dynamic>, String, int) onTaskDropped;
  final Function(DateTime, int) onPlusTap;
  final DateTime currentCalendarDate;
  final Function(DateTime) onCalendarDateChanged;

  const _CalendarSection({
    required this.currentLang,
    required this.scale,
    required this.isDark,
    required this.t,
    required this.textColor,
    required this.textMuted,
    required this.highlightColor,
    required this.emptyCellColor,
    required this.filteredTasks,
    required this.buildGlassContainer,
    required this.buildCalendarTaskCard,
    required this.buildCalendarTaskChip,
    required this.buildListTaskCard,
    required this.onTaskDropped,
    required this.onPlusTap,
    required this.currentCalendarDate,
    required this.onCalendarDateChanged,
  });

  @override
  State<_CalendarSection> createState() => _CalendarSectionState();
}

class _CalendarSectionState extends State<_CalendarSection> {
  // По умолчанию — "Месяц" (фидбек пользователя 2026-08-01), не "Таймлайн".
  bool _timelineMode = false;
  late DateTime _selectedDay;

  static const List<String> _monthsRu = ['', 'Январь', 'Февраль', 'Март', 'Апрель', 'Май', 'Июнь', 'Июль', 'Август', 'Сентябрь', 'Октябрь', 'Ноябрь', 'Декабрь'];

  @override
  void initState() {
    super.initState();
    _selectedDay = DateTime.now();
  }

  Widget _modeToggleButton(IconData icon, bool selected, VoidCallback onTap, String tooltip) {
    final t = widget.t;
    final s = widget.scale;
    return Tooltip(
      message: tooltip,
      child: ClarifyPressGlow(
        color: t.accent,
        spread: 10 * s,
        child: InkWell(
          borderRadius: BorderRadius.circular(ClarifyRadius.sm),
          onTap: onTap,
          child: Container(
            padding: EdgeInsets.all(6 * s),
            decoration: BoxDecoration(
              color: selected ? t.accent.withValues(alpha: 0.15) : Colors.transparent,
              borderRadius: BorderRadius.circular(ClarifyRadius.sm),
            ),
            child: Icon(icon, size: 18 * s, color: selected ? t.accent : widget.textMuted),
          ),
        ),
      ),
    );
  }

  Widget _dayHeaderLabel() {
    final s = widget.scale;
    final isToday = _formatDate(_selectedDay) == _formatDate(DateTime.now());
    final weekday = _capitalize(_kWeekdaysRu[_selectedDay.weekday - 1]);
    return Text(
      isToday
          ? "Сегодня".tr(widget.currentLang)
          : "$weekday, ${_selectedDay.day.toString().padLeft(2, '0')}.${_selectedDay.month.toString().padLeft(2, '0')}",
      style: TextStyle(fontSize: 24 * s, fontWeight: FontWeight.bold, color: widget.textColor),
    );
  }

  Widget _monthHeaderLabel(BuildContext context) {
    final s = widget.scale;
    final year = widget.currentCalendarDate.year;
    final month = widget.currentCalendarDate.month;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(ClarifyRadius.sm),
        onTap: () async {
          final picked = await _showMonthYearPicker(context, widget.isDark, widget.currentCalendarDate);
          if (picked != null) widget.onCalendarDateChanged(picked);
        },
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 8 * s, vertical: 4 * s),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text("${_monthsRu[month].tr(widget.currentLang)} $year", style: TextStyle(fontSize: 24 * s, fontWeight: FontWeight.bold, color: widget.textColor)),
            SizedBox(width: 6 * s),
            Icon(LucideIcons.chevronDown, size: 18 * s, color: widget.textMuted),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.scale;
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 24 * s, vertical: 12 * s),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _timelineMode ? _dayHeaderLabel() : _monthHeaderLabel(context),
              Row(children: [
                if (_timelineMode) ...[
                  IconButton(icon: Icon(LucideIcons.chevronLeft, color: widget.textColor, size: 28 * s), onPressed: () => setState(() => _selectedDay = _selectedDay.subtract(const Duration(days: 1)))),
                  IconButton(icon: Icon(LucideIcons.chevronRight, color: widget.textColor, size: 28 * s), onPressed: () => setState(() => _selectedDay = _selectedDay.add(const Duration(days: 1)))),
                ] else ...[
                  IconButton(icon: Icon(LucideIcons.chevronLeft, color: widget.textColor, size: 28 * s), onPressed: () => widget.onCalendarDateChanged(DateTime(widget.currentCalendarDate.year, widget.currentCalendarDate.month - 1))),
                  IconButton(icon: Icon(LucideIcons.chevronRight, color: widget.textColor, size: 28 * s), onPressed: () => widget.onCalendarDateChanged(DateTime(widget.currentCalendarDate.year, widget.currentCalendarDate.month + 1))),
                ],
                SizedBox(width: 12 * s),
                _modeToggleButton(LucideIcons.clock, _timelineMode, () => setState(() => _timelineMode = true), "Таймлайн".tr(widget.currentLang)),
                SizedBox(width: 4 * s),
                _modeToggleButton(LucideIcons.grid3x3, !_timelineMode, () => setState(() => _timelineMode = false), "Месяц".tr(widget.currentLang)),
              ]),
            ],
          ),
        ),
        Expanded(
          child: _timelineMode ? _buildTimeline() : _buildMonthGrid(context),
        ),
      ],
    );
  }

  Widget _buildTimeline() {
    final dateStr = _formatDate(_selectedDay);
    final dayTasks = widget.filteredTasks.where((t) => t['due_date'] == dateStr && t['parent_id'] == null).toList();
    return CalendarDayTimeline(
      date: _selectedDay,
      tasks: dayTasks,
      buildCalendarTaskCard: widget.buildCalendarTaskCard,
      scale: widget.scale,
      t: widget.t,
      currentLang: widget.currentLang,
      onTaskDropped: (task, droppedDateStr) => widget.onTaskDropped(task, droppedDateStr, dayTasks.length),
    );
  }

  Widget _buildMonthGrid(BuildContext context) {
    final t = widget.t;
    final s = widget.scale;
    final year = widget.currentCalendarDate.year;
    final month = widget.currentCalendarDate.month;
    final firstDayOfMonth = DateTime(year, month, 1);
    final lastDayOfMonth = DateTime(year, month + 1, 0);
    final int startOffset = firstDayOfMonth.weekday - 1;
    final int totalDaysInMonth = lastDayOfMonth.day;
    final int totalCells = startOffset + totalDaysInMonth;

    return LayoutBuilder(builder: (context, outerConstraints) {
      final bool isCompactHeader = ClarifyBreakpoints.of(outerConstraints.maxWidth) == ClarifyBreakpoint.compact;
      final double headerCellWidth = isCompactHeader
          ? 150 * s
          : (outerConstraints.maxWidth - (48 * s) - (16 * s * 6)) / 7;

      // Только для компакт-режима (ListView.horizontal ниже) — Expanded здесь был бы
      // ошибкой: он валиден лишь прямым потомком Flex, а не SizedBox внутри ListView.
      final weekdayLabels = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'].map((day) => SizedBox(
            width: headerCellWidth,
            child: Center(child: Text(day.tr(widget.currentLang), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16 * s, color: widget.textMuted))),
          )).toList();

      return Column(
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 24 * s),
            child: isCompactHeader
                ? SizedBox(height: 24 * s, child: ListView(scrollDirection: Axis.horizontal, physics: const NeverScrollableScrollPhysics(), children: weekdayLabels))
                : Row(children: ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'].map((day) => Expanded(child: Center(child: Text(day.tr(widget.currentLang), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16 * s, color: widget.textMuted))))).toList()),
          ),
          SizedBox(height: 12 * s),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final int rows = (totalCells / 7).ceil();
                final bool isCompact = ClarifyBreakpoints.of(constraints.maxWidth) == ClarifyBreakpoint.compact;
                // Компакт: ячейка не сжимается ниже читаемой ширины — сетка целиком
                // скроллится по горизонтали, а не расплющивает 7 колонок в полоски
                // (как было раньше — childAspectRatio считался от всей доступной
                // ширины без нижней границы).
                final double cellWidth = isCompact
                    ? 150 * s
                    : (constraints.maxWidth - (48 * s) - (16 * s * 6)) / 7;
                // Вертикальные отступы сетки уменьшены (было 24*s/16*s, как у
                // горизонтальных) — при 5-6 строках в месяце они забирали
                // существенную долю высоты у КАЖДОЙ ячейки одновременно, не
                // оставляя места для 3 задач превью (живой фидбог 2026-08-01).
                // Горизонтальные не трогаю — там про ширину жалоб не было.
                const double gridVerticalPadding = 6;
                const double gridMainAxisSpacing = 4;
                final double cellHeight = (constraints.maxHeight - (gridVerticalPadding * 2 * s) - (gridMainAxisSpacing * s * (rows - 1))) / rows;
                final double childAspectRatio = (cellWidth > 0 && cellHeight > 0) ? (cellWidth / cellHeight) : 1.0;

                final grid = GridView.builder(
                  physics: const NeverScrollableScrollPhysics(),
                  padding: EdgeInsets.symmetric(horizontal: 24 * s, vertical: gridVerticalPadding * s),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 7,
                    crossAxisSpacing: 16 * s,
                    mainAxisSpacing: gridMainAxisSpacing * s,
                    childAspectRatio: childAspectRatio,
                  ),
                  itemCount: totalCells,
                  itemBuilder: (context, index) {
                    if (index < startOffset) return const SizedBox.shrink();
                    final dayNumber = index - startOffset + 1;
                    final cellDate = DateTime(year, month, dayNumber);
                    final cellDateStr = _formatDate(cellDate);
                    final dayTasks = widget.filteredTasks.where((t) => t['due_date'] == cellDateStr && t['parent_id'] == null).toList();
                    dayTasks.sort(_byTimeThenId);
                    final taskCount = dayTasks.length;
                    final dayTitle = "${_capitalize(_kWeekdaysRu[cellDate.weekday - 1])}, ${dayNumber.toString().padLeft(2, '0')}.${month.toString().padLeft(2, '0')}";
                    return DragTarget<Map<String, dynamic>>(
                      onAcceptWithDetails: (details) => widget.onTaskDropped(details.data, cellDateStr, taskCount),
                      builder: (context, candidateData, rejectedData) {
                        return _CalendarCellHover(
                          builder: (hovered) => widget.buildGlassContainer(
                          // Пустая ячейка — surfaceSunken, заполненная — обычная surface: два разных,
                          // но согласованных состояния вместо одинаковых голых прямоугольников
                          // (§9.3/DESIGN_IDEAS.md P1.4). Подпись "Свободно" убрана (фидбек
                          // 2026-09-04): повторённая в 25 пустых ячейках сразу, она читалась
                          // как шум и спорила с задачами за внимание — фона surfaceSunken
                          // достаточно, чтобы отличить пустой день от занятого.
                          customColor: candidateData.isNotEmpty ? widget.highlightColor : (taskCount == 0 ? widget.emptyCellColor : null),
                          padding: EdgeInsets.symmetric(horizontal: 8 * s, vertical: 4 * s),
                          // Кнопка "+" раньше была отдельной строкой в Column — вместе с
                          // заголовком числа она съедала почти всю высоту ячейки, не
                          // оставляя места для 3 задач превью (живой фидбог 2026-08-01:
                          // "помещается всего одна задача, даже без переполнения"). Теперь
                          // она наложена поверх контента (Stack/Positioned), а не занимает
                          // свою строку в раскладке — число и превью получают всю высоту
                          // ячейки целиком. И показывается только под курсором: 35 плюсиков
                          // разом — это сетка кнопок, а не календарь. На узкой раскладке
                          // (тач, где наведения нет) остаётся видимой всегда.
                          child: Stack(
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Padding(
                                    padding: EdgeInsets.only(left: 4 * s),
                                    child: Text("$dayNumber", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12 * s, color: cellDateStr == _formatDate(DateTime.now()) ? t.accent : widget.textColor)),
                                  ),
                                  Expanded(
                                    // width: infinity, а не SizedBox.shrink() — иначе Column
                                    // (не-Positioned ребёнок Stack) сжимается по ширине до
                                    // числа дня, Stack вслед за ним, и "+" с right: 0
                                    // оказывается у левого края ячейки.
                                    child: taskCount == 0
                                        ? const SizedBox(width: double.infinity)
                                        : _CalendarDayTasksPreview(dayTitle: dayTitle, tasks: dayTasks, buildCalendarTaskChip: widget.buildCalendarTaskChip, buildListTaskCard: widget.buildListTaskCard, scale: s, t: t, currentLang: widget.currentLang),
                                  ),
                                ],
                              ),
                              Positioned(
                                right: 0,
                                bottom: 0,
                                child: IgnorePointer(
                                  ignoring: !(hovered || isCompact),
                                  child: AnimatedOpacity(
                                    opacity: (hovered || isCompact) ? 1 : 0,
                                    duration: ClarifyMotion.fast,
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(999),
                                      onTap: () => widget.onPlusTap(cellDate, taskCount),
                                      child: Padding(
                                        padding: EdgeInsets.all(2 * s),
                                        child: Icon(LucideIcons.plus, color: widget.textMuted, size: 14 * s),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          ),
                        );
                      },
                    );
                  },
                );

                if (!isCompact) return grid;

                final totalGridWidth = (48 * s) + (7 * cellWidth) + (6 * 16 * s);
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(width: totalGridWidth, height: constraints.maxHeight, child: grid),
                );
              },
            ),
          ),
        ],
      );
    });
  }
}

/// Наведение на ячейку месяца — чтобы показывать "+" только под курсором.
/// Отдельный маленький виджет, а не setState всего календаря: перестраивается
/// одна ячейка, а не сетка из 35.
class _CalendarCellHover extends StatefulWidget {
  final Widget Function(bool hovered) builder;

  const _CalendarCellHover({required this.builder});

  @override
  State<_CalendarCellHover> createState() => _CalendarCellHoverState();
}

class _CalendarCellHoverState extends State<_CalendarCellHover> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: widget.builder(_hovered),
    );
  }
}

/// До 3 задач прямо в ячейке + пилюля "+N ещё", открывающая полный список дня
/// попапом (REDESIGN_V3_PLAN.md §5.9: пейджер с точками/стрелками было
/// "криво" при 5+ задачах — заменено на google/apple-calendar паттерн, без
/// внутреннего свайпа и скачков раскладки сетки).
///
/// Количество видимых задач раньше было жёстко зашито в 3 — когда строки
/// превью стали двухстрочными (приоритет/бейджи, живой фидбек 2026-08-01),
/// это перестало гарантированно помещаться в ячейку: пилюля "+1" накладывалась
/// на текст 3-й задачи (живой баг 2026-08-02). Первая попытка фикса считала
/// количество от фиксированной ОЦЕНКИ высоты строки
/// (TaskCardBuilders.calendarChipHeight, подобранной по замеру в
/// виджет-тесте) — но `flutter test` рендерит текст ДРУГИМ (тестовым)
/// шрифтом, не настоящим Golos Text, так что "измеренная" в тесте высота не
/// совпала с реальной высотой в собранном приложении: оценка вышла
/// избыточно консервативной, и вместо 3 задач показывались только 2 с явно
/// пустующим местом под ними (тот же день, следующий живой фидбек).
///
/// Правильный фикс — не гадать высоту строки константой, а ИЗМЕРИТЬ её по-
/// настоящему в реальном дереве виджетов: первый рендер кладёт одну "строку-
/// зонд" офскрин (Offstage — layout выполняется, но не рисуется и не
/// занимает места у остальных детей), берёт её реальный RenderBox.size.height
/// после первого кадра и пересчитывает от него — той же самой высоты, что и
/// у видимых строк, независимо от платформы/шрифта/DPI. До первого измерения
/// (один кадр) используется консервативная оценка, чтобы не мигать
/// "слишком многими" задачами, которые тут же пришлось бы убрать.
class _CalendarDayTasksPreview extends StatefulWidget {
  final String dayTitle;
  final List<Map<String, dynamic>> tasks;
  final Widget Function(Map<String, dynamic>) buildCalendarTaskChip;
  final Widget Function(Map<String, dynamic>) buildListTaskCard;
  final double scale;
  final ClarifyTokens t;
  final String currentLang;

  const _CalendarDayTasksPreview({
    required this.dayTitle,
    required this.tasks,
    required this.buildCalendarTaskChip,
    required this.buildListTaskCard,
    required this.scale,
    required this.t,
    required this.currentLang,
  });

  @override
  State<_CalendarDayTasksPreview> createState() => _CalendarDayTasksPreviewState();
}

class _CalendarDayTasksPreviewState extends State<_CalendarDayTasksPreview> {
  static const double _pillHeight = 16;

  final GlobalKey _probeKey = GlobalKey();
  double? _measuredChipHeight;

  void _measureProbe() {
    final renderBox = _probeKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) return;
    final height = renderBox.size.height;
    if (!mounted || height <= 0) return;
    if (_measuredChipHeight == null || (_measuredChipHeight! - height).abs() > 0.5) {
      setState(() => _measuredChipHeight = height);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double availableHeight = constraints.maxHeight.isFinite ? constraints.maxHeight : 0;
        // Консервативная оценка ТОЛЬКО для первого кадра, пока реальная
        // высота ещё не измерена — сознательно занижена (лучше на миг
        // показать на 1 задачу меньше, чем на кадр показать больше, чем
        // реально влезает, и тут же обрезать/наложить).
        final double chipHeight = _measuredChipHeight ?? TaskCardBuilders.calendarChipHeight(widget.scale);
        final double pillHeight = _pillHeight * widget.scale;

        final int maxWithoutPill = chipHeight > 0 ? (availableHeight / chipHeight).floor() : 0;
        int visibleCount;
        if (widget.tasks.length <= maxWithoutPill) {
          visibleCount = widget.tasks.length;
        } else {
          final int maxWithPill = chipHeight > 0 ? ((availableHeight - pillHeight) / chipHeight).floor() : 0;
          visibleCount = maxWithPill.clamp(0, widget.tasks.length);
        }
        final int overflow = widget.tasks.length - visibleCount;
        final previewTasks = widget.tasks.sublist(0, visibleCount);

        // НЕ гасим повторные измерения после первого успеха: на web шрифт
        // (Golos Text) грузится асинхронно ПОСЛЕ первого кадра — если зонд
        // измеряется один-единственный раз до того, как шрифт догрузился,
        // результат навсегда фиксирует высоту ЗАПАСНОГО системного шрифта
        // (другие метрики строки), а не реальную. Зонд остаётся
        // смонтированным и перемеряется на каждом кадре — дёшево (просто
        // сравнение), но подхватывает досрочно ошибочный замер, когда шрифт
        // догрузится и вызовет реальный релейаут текста.
        WidgetsBinding.instance.addPostFrameCallback((_) => _measureProbe());

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Offstage(
              offstage: true,
              child: KeyedSubtree(key: _probeKey, child: widget.buildCalendarTaskChip(widget.tasks.first)),
            ),
            for (final task in previewTasks) widget.buildCalendarTaskChip(task),
            if (overflow > 0)
              Padding(
                padding: EdgeInsets.only(top: 2 * widget.scale),
                child: InkWell(
                  borderRadius: BorderRadius.circular(ClarifyRadius.sm),
                  onTap: () => showClarifySurface<void>(
                    context: context,
                    builder: (context) => _DayAgendaDialog(
                      dayTitle: widget.dayTitle,
                      tasks: widget.tasks,
                      buildListTaskCard: widget.buildListTaskCard,
                      t: widget.t,
                    ),
                  ),
                  child: Text(
                    "+$overflow",
                    style: TextStyle(fontSize: 11 * widget.scale, fontWeight: FontWeight.w600, color: widget.t.text2),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Полный список задач дня — открывается по клику на пилюлю "+N ещё" в ячейке
/// календаря. Тот же стеклянный шаблон, что и у `_MonthYearPickerDialog`;
/// анимация вылета из точки клика уже даёт `showClarifySurface`.
class _DayAgendaDialog extends StatelessWidget {
  final String dayTitle;
  final List<Map<String, dynamic>> tasks;
  final Widget Function(Map<String, dynamic>) buildListTaskCard;
  final ClarifyTokens t;

  const _DayAgendaDialog({
    required this.dayTitle,
    required this.tasks,
    required this.buildListTaskCard,
    required this.t,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Material(
        color: Colors.transparent,
        child: ClarifyGlass(
          borderRadius: BorderRadius.circular(ClarifyRadius.lg),
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
            child: SizedBox(
              width: 340,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(dayTitle, style: TextStyle(color: t.text, fontWeight: FontWeight.bold, fontSize: 18)),
                      IconButton(icon: Icon(LucideIcons.x, color: t.text2), onPressed: () => Navigator.of(context).pop()),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: tasks.map(buildListTaskCard).toList(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
