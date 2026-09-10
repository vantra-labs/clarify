import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:animations/animations.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../core/localization.dart';
import '../../core/quick_parse.dart';
import '../../core/theme/design_tokens.dart';
import '../../widgets/clarify_pressable.dart';
import '../../widgets/friends_screen.dart';
import '../../widgets/conversations_screen.dart';
import '../../widgets/workspace_conversations_screen.dart';
import '../../widgets/mobile_quick_add_sheet.dart';
import 'mobile_today_screen.dart';
import 'mobile_tasks_screen.dart';
import 'mobile_teams_screen.dart';
import 'mobile_settings_screen.dart';
import 'mobile_ai_screen.dart';
import '../../widgets/about_screen.dart';

enum MobileTab { today, tasks, teams, settings }

/// Мобильная/PWA-оболочка Clarify — отдельно спроектированная навигация
/// (нижний таб-бар + FAB), а не десктопный сайдбар, сжатый в узкий экран.
/// Бизнес-логика (загрузка задач, CRUD, воркспейсы) остаётся в
/// DesktopPlannerScreen — сюда прокидываются только данные и колбэки,
/// как и в остальные вынесенные виджеты приложения.
class MobilePlannerShell extends StatefulWidget {
  final String currentLang;
  final String userInitial;
  final String userFullName;
  final List<Map<String, dynamic>> tasks;
  final List<Map<String, dynamic>> workspaces;
  final Map<int, List<Map<String, dynamic>>> workspaceMembers;
  final String Function(DateTime date) formatDate;
  final Color Function(String? priority) getPriorityColor;
  final Map<String, int> Function(dynamic parentId) getSubtaskStats;
  final bool Function(Map<String, dynamic> task) isOverdue;
  final void Function(Map<String, dynamic> task) onToggleTask;
  final void Function(dynamic taskId) onDeleteTask;
  final void Function(Map<String, dynamic> task) onTaskTap;
  final void Function(dynamic taskId, Map<String, dynamic> updates)
  onQuickUpdateTask;

  /// Сохранение порядка после перетаскивания — обработчик тот же, что и на
  /// десктопе: сервис задач один, и очередь отправки при отсутствии сети тоже.
  final void Function(List<Map<String, dynamic>> orderedTasks) onReorderSaved;
  final void Function({DateTime? preselectedDate}) onAddTask;
  final Future<int?> Function(Map<String, dynamic> taskData) createTaskManually;
  final Future<String> Function(String text, List<Map<String, String>> history) onAiParseText;
  final Future<String> Function(Uint8List audioBytes, String filename, String contentType) onTranscribeVoice;
  final void Function(String dateStr) checkBurnoutWarning;
  final void Function(int workspaceId) onOpenWorkspaceMembers;
  final void Function(int workspaceId) onInviteToWorkspace;
  final void Function(int workspaceId) onShowTeamPulse;
  final void Function(int workspaceId) onLeaveOrDeleteWorkspace;
  final VoidCallback onAddWorkspace;
  final VoidCallback onOpenAccountSettings;
  final Widget Function() buildStatisticsDashboard;

  /// Корзина (C6) — тот же виджет, что на ПК: он собирается в
  /// DesktopPlannerScreen, где живёт TaskService, и сюда приходит готовым.
  final Widget Function() buildTrashPanel;
  final bool isDark;
  final VoidCallback toggleTheme;
  final Function(String lang) changeLang;

  const MobilePlannerShell({
    super.key,
    required this.currentLang,
    required this.userInitial,
    required this.userFullName,
    required this.tasks,
    required this.workspaces,
    required this.workspaceMembers,
    required this.formatDate,
    required this.getPriorityColor,
    required this.getSubtaskStats,
    required this.isOverdue,
    required this.onToggleTask,
    required this.onDeleteTask,
    required this.onTaskTap,
    required this.onQuickUpdateTask,
    required this.onReorderSaved,
    required this.onAddTask,
    required this.createTaskManually,
    required this.onAiParseText,
    required this.onTranscribeVoice,
    required this.checkBurnoutWarning,
    required this.onOpenWorkspaceMembers,
    required this.onInviteToWorkspace,
    required this.onShowTeamPulse,
    required this.onLeaveOrDeleteWorkspace,
    required this.onAddWorkspace,
    required this.onOpenAccountSettings,
    required this.buildStatisticsDashboard,
    required this.buildTrashPanel,
    required this.isDark,
    required this.toggleTheme,
    required this.changeLang,
  });

  @override
  State<MobilePlannerShell> createState() => _MobilePlannerShellState();
}

class _MobilePlannerShellState extends State<MobilePlannerShell> {
  MobileTab _tab = MobileTab.today;
  // Заданная через мини-календарь «Мой день» дата, на которую нужно открыть
  // «Задачи» — одноразовый «билет», сбрасывается сразу после применения,
  // чтобы повторный визит на вкладку не запирал фильтр на старой дате.
  DateTime? _pendingCalendarDate;

  List<Map<String, dynamic>> get _todayTasks {
    final todayStr = widget.formatDate(DateTime.now());
    final list = widget.tasks.where((t) => t['due_date'] == todayStr && t['parent_id'] == null).toList();
    list.sort((a, b) => (a['due_time'] ?? '23:59').compareTo(b['due_time'] ?? '23:59'));
    return list;
  }

  int get _inboxCount => widget.tasks.where((t) => (t['due_date'] == null || t['due_date'] == '') && t['parent_id'] == null).length;

  // Даты с задачами (точки в мини-календаре) и суммарная длительность по
  // каждой дате (насколько день тяжёлый) — ОДНИМ проходом и с кэшем.
  //
  // Было: два геттера, причём второй для каждой даты заново пробегал весь
  // список задач через dayLoadMinutes. Сто задач на полусотне дат — пять тысяч
  // проходов вместо ста, и всё это заново при КАЖДОЙ перерисовке оболочки,
  // включая вызванную приходом задачи по realtime. На телефоне это заметно.
  //
  // Порог «тяжёлого» дня остаётся общим с предупреждением в диалоге создания
  // задачи (AppConfig.dailyLoadWarningMinutes), чтобы сигнал не расходился по
  // смыслу; условия суммирования те же, что в dayLoadMinutes.
  List<Map<String, dynamic>>? _calendarSource;
  Set<String> _datesWithTasksCache = const {};
  Map<String, int> _dateLoadMinutesCache = const {};

  void _ensureCalendarIndex() {
    // Сравнение по ссылке: TaskCache всегда отдаёт новый список, поэтому
    // «тот же список» надёжно означает «ничего не менялось».
    if (identical(_calendarSource, widget.tasks)) return;

    final dates = <String>{};
    final load = <String, int>{};
    for (final task in widget.tasks) {
      if (task['parent_id'] != null) continue;
      final raw = task['due_date'];
      if (raw == null || raw == '') continue;
      final date = raw as String;
      dates.add(date);
      if (task['is_completed'] == true) continue;
      final minutes = task['duration_minutes'];
      if (minutes is int) load[date] = (load[date] ?? 0) + minutes;
    }

    _calendarSource = widget.tasks;
    _datesWithTasksCache = dates;
    _dateLoadMinutesCache = load;
  }

  Set<String> get _datesWithTasks {
    _ensureCalendarIndex();
    return _datesWithTasksCache;
  }

  Map<String, int> get _dateLoadMinutes {
    _ensureCalendarIndex();
    return _dateLoadMinutesCache;
  }

  /// Быстрое добавление строкой (C1) — та же раскладка полей, что на ПК
  /// (desktop_planner_screen.dart, onQuickCreate). Разбор строки живёт в
  /// core/quick_parse.dart и общий для обеих версий, так что расходиться им
  /// негде: отличалось только то, что на телефоне этого ввода не было вовсе.
  Future<void> _quickCreate(QuickParseResult parsed) async {
    await widget.createTaskManually({
      "title": parsed.title,
      "due_date": parsed.date == null ? null : widget.formatDate(parsed.date!),
      "due_time": parsed.time,
      "priority": parsed.priority ?? 'none',
      "tags": parsed.tag,
      "recurrence": null,
      "is_completed": false,
      "parent_id": null,
    });
  }

  Widget _buildTab(MobileTab tab) {
    switch (tab) {
      case MobileTab.today:
        return MobileTodayScreen(
          currentLang: widget.currentLang,
          todayTasks: _todayTasks,
          inboxCount: _inboxCount,
          datesWithTasks: _datesWithTasks,
          dateLoadMinutes: _dateLoadMinutes,
          getPriorityColor: widget.getPriorityColor,
          getSubtaskStats: widget.getSubtaskStats,
          isOverdue: widget.isOverdue,
          onToggle: widget.onToggleTask,
          onDelete: widget.onDeleteTask,
          onTap: widget.onTaskTap,
          onQuickUpdateTask: widget.onQuickUpdateTask,
          onOpenInbox: () => setState(() => _tab = MobileTab.tasks),
          onOpenDate: (date) => setState(() {
            _pendingCalendarDate = date;
            _tab = MobileTab.tasks;
          }),
        );
      case MobileTab.tasks:
        final initialDate = _pendingCalendarDate;
        _pendingCalendarDate = null;
        return MobileTasksScreen(
          currentLang: widget.currentLang,
          tasks: widget.tasks,
          initialDate: initialDate,
          datesWithTasks: _datesWithTasks,
          dateLoadMinutes: _dateLoadMinutes,
          getPriorityColor: widget.getPriorityColor,
          getSubtaskStats: widget.getSubtaskStats,
          isOverdue: widget.isOverdue,
          onToggle: widget.onToggleTask,
          onDelete: widget.onDeleteTask,
          onTap: widget.onTaskTap,
          onQuickUpdateTask: widget.onQuickUpdateTask,
          onQuickCreate: _quickCreate,
          onReorderSaved: widget.onReorderSaved,
        );
      case MobileTab.teams:
        return MobileTeamsScreen(
          currentLang: widget.currentLang,
          workspaces: widget.workspaces,
          workspaceMembers: widget.workspaceMembers,
          tasks: widget.tasks,
          onAddWorkspace: widget.onAddWorkspace,
          onOpenMembers: widget.onOpenWorkspaceMembers,
          onInvite: widget.onInviteToWorkspace,
          onShowPulse: widget.onShowTeamPulse,
          onLeaveOrDeleteWorkspace: widget.onLeaveOrDeleteWorkspace,
          getPriorityColor: widget.getPriorityColor,
          getSubtaskStats: widget.getSubtaskStats,
          isOverdue: widget.isOverdue,
          onToggleTask: widget.onToggleTask,
          onDeleteTask: widget.onDeleteTask,
          onTaskTap: widget.onTaskTap,
          onQuickUpdateTask: widget.onQuickUpdateTask,
        );
      case MobileTab.settings:
        return MobileSettingsScreen(
          currentLang: widget.currentLang,
          userInitial: widget.userInitial,
          userFullName: widget.userFullName,
          isDark: widget.isDark,
          onOpenAccountSettings: widget.onOpenAccountSettings,
          onOpenStatistics: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => _StatisticsPage(currentLang: widget.currentLang, builder: widget.buildStatisticsDashboard),
          )),
          onOpenFriends: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => _FriendsPage(currentLang: widget.currentLang),
          )),
          onOpenMessages: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => _MessagesPage(currentLang: widget.currentLang),
          )),
          onOpenTrash: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => _TrashPage(
              currentLang: widget.currentLang,
              builder: widget.buildTrashPanel,
            ),
          )),
          onOpenAbout: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => Scaffold(
              backgroundColor: context.tokens.bg,
              appBar: AppBar(
                backgroundColor: context.tokens.bg,
                elevation: 0,
                foregroundColor: context.tokens.text,
                title: Text('О приложении'.tr(widget.currentLang),
                    style: const TextStyle(fontFamily: 'Golos Text', fontWeight: FontWeight.w700)),
              ),
              body: AboutScreen(currentLang: widget.currentLang),
            ),
          )),
          toggleTheme: widget.toggleTheme,
          changeLang: widget.changeLang,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Scaffold(
      backgroundColor: t.bg,
      body: SafeArea(
        bottom: false,
        // FadeThroughTransition вместо мгновенного IndexedStack-переключения —
        // сдержанный переход между вкладками нижней навигации (REDESIGN_V3_PLAN.md
        // §3.6/5.6, эталон движения — Structured).
        child: PageTransitionSwitcher(
          duration: MediaQuery.of(context).disableAnimations ? Duration.zero : ClarifyMotion.slow,
          transitionBuilder: (child, primaryAnimation, secondaryAnimation) => FadeThroughTransition(
            animation: primaryAnimation,
            secondaryAnimation: secondaryAnimation,
            child: child,
          ),
          child: KeyedSubtree(
            key: ValueKey(_tab),
            child: _buildTab(_tab),
          ),
        ),
      ),
      bottomNavigationBar: _MobileBottomNav(
        current: _tab,
        currentLang: widget.currentLang,
        onSelect: (tab) => setState(() => _tab = tab),
        onAdd: () => showMobileQuickAddSheet(
          context: context,
          currentLang: widget.currentLang,
          tasks: widget.tasks,
          workspaces: widget.workspaces,
          workspaceMembers: widget.workspaceMembers,
          createTaskManually: widget.createTaskManually,
          checkBurnoutWarning: widget.checkBurnoutWarning,
          getPriorityColor: widget.getPriorityColor,
          formatDate: widget.formatDate,
          onOpenAi: () => Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
            builder: (_) => MobileAiScreen(currentLang: widget.currentLang, onParseText: widget.onAiParseText, onTranscribeVoice: widget.onTranscribeVoice),
          )),
        ),
      ),
    );
  }
}

class _MobileBottomNav extends StatelessWidget {
  final MobileTab current;
  final String currentLang;
  final void Function(MobileTab tab) onSelect;
  final VoidCallback onAdd;

  const _MobileBottomNav({required this.current, required this.currentLang, required this.onSelect, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // Статичный полупрозрачный фон вместо ClarifyGlass/BackdropFilter —
    // блюр этой панели тикает на каждый кадр скролла списков над ней и
    // заметно проседает на слабых телефонах; тут это не критично для
    // дизайна (узкая панель у самого низа экрана), а не только на десктопном
    // сайдбаре/панелях, где блюр остаётся.
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      decoration: BoxDecoration(
        color: t.surface.withValues(alpha: 0.92),
        border: Border(top: BorderSide(color: t.border, width: 1)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _NavItem(icon: LucideIcons.sun, label: 'День'.tr(currentLang), active: current == MobileTab.today, onTap: () => onSelect(MobileTab.today)),
            _NavItem(icon: LucideIcons.listChecks, label: 'Задачи'.tr(currentLang), active: current == MobileTab.tasks, onTap: () => onSelect(MobileTab.tasks)),
            _FabItem(onTap: onAdd),
            _NavItem(icon: LucideIcons.usersRound, label: 'Команды'.tr(currentLang), active: current == MobileTab.teams, onTap: () => onSelect(MobileTab.teams)),
            _NavItem(icon: LucideIcons.settings, label: 'Настройки'.tr(currentLang), active: current == MobileTab.settings, onTap: () => onSelect(MobileTab.settings)),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _NavItem({required this.icon, required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final color = active ? t.accent : t.text3;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(ClarifyRadius.md),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: color)),
          ],
        ),
      ),
    );
  }
}

class _FabItem extends StatelessWidget {
  final VoidCallback onTap;
  const _FabItem({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ClarifyPressable(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        margin: const EdgeInsets.only(bottom: 18),
        decoration: BoxDecoration(color: t.accent, shape: BoxShape.circle, boxShadow: [BoxShadow(color: t.accent.withValues(alpha: 0.35), blurRadius: 16, offset: const Offset(0, 6))]),
        child: Icon(LucideIcons.plus, color: t.onAccent, size: 24),
      ),
    );
  }
}

class _FriendsPage extends StatelessWidget {
  final String currentLang;
  const _FriendsPage({required this.currentLang});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Scaffold(
      backgroundColor: t.bg,
      appBar: AppBar(
        backgroundColor: t.bg,
        elevation: 0,
        foregroundColor: t.text,
        title: Text('Друзья'.tr(currentLang), style: TextStyle(fontFamily: 'Golos Text', fontWeight: FontWeight.w700)),
      ),
      body: FriendsScreen(
        currentLang: currentLang,
        showHeader: false,
        // Единственное действие на строке друга — кнопка "написать", без
        // промежуточного перехода в профиль (убран по прямому запросу).
        onOpenConversation: (partnerId, name) => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ConversationScreen(currentLang: currentLang, partnerId: partnerId, partnerName: name),
        )),
      ),
    );
  }
}

class _MessagesPage extends StatelessWidget {
  final String currentLang;
  const _MessagesPage({required this.currentLang});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // Личные/Команда — те же две вкладки, что и в десктопном MessengerShell
    // (widgets/messenger_shell.dart). Раньше на мобильном был только список
    // личных сообщений — командный групповой чат с телефона был вообще
    // недостижим (фидбек пользователя 2026-08-01).
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: t.bg,
        appBar: AppBar(
          backgroundColor: t.bg,
          elevation: 0,
          foregroundColor: t.text,
          title: Text('Мессенджер'.tr(currentLang), style: TextStyle(fontFamily: 'Golos Text', fontWeight: FontWeight.w700)),
          bottom: TabBar(
            labelColor: t.accent,
            unselectedLabelColor: t.text3,
            indicatorColor: t.accent,
            tabs: [
              Tab(text: 'Личные'.tr(currentLang)),
              Tab(text: 'Команды'.tr(currentLang)),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            ConversationsListScreen(
              currentLang: currentLang,
            ),
            WorkspaceConversationsListScreen(currentLang: currentLang),
          ],
        ),
      ),
    );
  }
}

/// Корзина отдельной страницей, а не вкладкой: в нижней навигации четыре
/// места, и все заняты основными назначениями. Виджет тот же, что на ПК.
class _TrashPage extends StatelessWidget {
  final String currentLang;
  final Widget Function() builder;
  const _TrashPage({required this.currentLang, required this.builder});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Scaffold(
      backgroundColor: t.bg,
      appBar: AppBar(
        backgroundColor: t.bg,
        elevation: 0,
        foregroundColor: t.text,
        title: Text('Корзина'.tr(currentLang), style: TextStyle(fontFamily: 'Golos Text', fontWeight: FontWeight.w700)),
      ),
      body: builder(),
    );
  }
}

class _StatisticsPage extends StatelessWidget {
  final String currentLang;
  final Widget Function() builder;
  const _StatisticsPage({required this.currentLang, required this.builder});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Scaffold(
      backgroundColor: t.bg,
      appBar: AppBar(
        backgroundColor: t.bg,
        elevation: 0,
        foregroundColor: t.text,
        title: Text('Статистика'.tr(currentLang), style: TextStyle(fontFamily: 'Golos Text', fontWeight: FontWeight.w700)),
      ),
      body: builder(),
    );
  }
}
