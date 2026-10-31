import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../widgets/clarify_pressable.dart';
import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:local_notifier/local_notifier.dart';

import '../core/app_settings.dart';
import '../core/clarify_date_format.dart';
import '../core/config.dart';
import '../core/features.dart';
import '../core/localization.dart';
import '../core/tags.dart';
import '../core/priority.dart';
import '../core/recurrence.dart';
import '../core/theme/design_tokens.dart';
import '../services/analytics.dart';
import '../services/task_service.dart';
import '../services/update_service.dart';
import '../widgets/clarify_button.dart';
import '../widgets/clarify_glass.dart';
import '../widgets/clarify_surface.dart';
import 'package:animations/animations.dart';
import '../widgets/ambient_background.dart';
import '../widgets/clarify_toast.dart';
import '../widgets/main_content_area.dart';
import '../widgets/user_profile_modal.dart';
import '../widgets/sidebar_menu.dart';
import '../widgets/window_buttons.dart';
import 'mobile/mobile_planner_shell.dart';
import 'mobile/mobile_settings_screen.dart';
import '../widgets/task_cards.dart';
import '../widgets/statistics_dashboard.dart';
import '../widgets/archive_screen.dart';
import '../widgets/trash_screen.dart';
import '../widgets/ai_chat_panel.dart';
import '../dialogs/workspace_dialogs.dart';
import '../dialogs/team_pulse_dialog.dart';
import '../dialogs/search_dialog.dart';
import '../widgets/command_palette.dart';
import '../dialogs/manual_add_dialog.dart';
import '../dialogs/edit_task_dialog.dart';
import '../dialogs/task_details_dialog.dart';
import '../dialogs/account_settings_dialog.dart';
import '../core/log.dart';

/// Бросается _sendToAiAssistant, когда /tasks/parse отвечает не-200 —
/// отдельный тип нужен, чтобы отличать "сервер ответил ошибкой" от
/// "нет связи" в UI (десктоп и мобильный AI-экран).
class AiParseHttpException implements Exception {
  final int statusCode;
  // Тело ответа (обычно {"detail": "..."} от FastAPI) — раньше отбрасывалось
  // полностью, показывался только код. При живой диагностике 500-х это
  // ровно та строка, где FastAPI пишет реальную причину (например
  // "SUPABASE_URL/SUPABASE_ANON_KEY не настроены") — без неё код 500 сам по
  // себе не говорит, что именно сломалось на сервере.
  final String body;
  const AiParseHttpException(this.statusCode, this.body);

  // Без переопределения toString() дефолтный вывод — бесполезное
  // "Instance of 'AiParseHttpException'"; при диагностике по e.toString()
  // (см. MobileAiScreen._send) нужен реальный код ответа и тело.
  @override
  String toString() => 'HTTP $statusCode: $body';
}

/// Отметка "выполнено", сделанная локально и ещё не подтверждённая сервером.
///
/// Нужна из-за давней гонки: realtime-событие на НАШЕ ЖЕ изменение прилетает
/// раньше, чем этот UPDATE становится виден обычному SELECT, поэтому
/// перезагрузка списка может принести снимок базы, сделанный ДО коммита нашей
/// отметки, и снять галочку обратно. Прежняя защита действовала только пока
/// запрос летит на сервер (_pendingActionIds), а опоздавший снимок приходит
/// уже после ответа — то есть мимо неё. Раньше это выражалось в едва заметном
/// подмигивании чекбокса; с тех пор как выполненная задача уезжает вниз, та же
/// гонка читается как "отметка не сработала, задача вернулась".
class _PinnedCompletion {
  final bool isCompleted;
  final String? completedAt;
  final DateTime pinnedAt;

  _PinnedCompletion({required this.isCompleted, required this.completedAt})
      : pinnedAt = DateTime.now();

  /// Сервер догнал: в снимке уже наше значение — закрепление можно снимать.
  bool agreesWith(Map<String, dynamic> fetched) =>
      (fetched['is_completed'] == true) == isCompleted;

  /// Страховка от вечного закрепления, если подтверждение так и не пришло
  /// (например, изменение легло в офлайн-очередь и ждёт сети).
  bool get isExpired => DateTime.now().difference(pinnedAt) > const Duration(seconds: 30);
}

class DesktopPlannerScreen extends StatefulWidget {
  final bool isDark;
  final VoidCallback toggleTheme;
  final String currentLang;
  final Function(String) changeLang;

  const DesktopPlannerScreen({
    super.key,
    required this.isDark,
    required this.toggleTheme,
    required this.currentLang,
    required this.changeLang,
  });

  @override
  State<DesktopPlannerScreen> createState() => _DesktopPlannerScreenState();
}

class _DesktopPlannerScreenState extends State<DesktopPlannerScreen> {
  final TextEditingController _aiChatController = TextEditingController();
  final TaskService _taskService = TaskService();
  double _s = 1.0;

  // 3. КОЛЛЕКЦИЯ ДЛЯ УМНЫХ ТАЙМЕРОВ (БЕЗ НАГРУЗКИ НА CPU)
  final Map<String, Timer> _activeAlarms = {};

  // Guard от гонки при повторном действии до ответа сети — id мутирующего
  // действия (не самой задачи, одна задача может участвовать в разных
  // одновременных действиях) добавляется сюда на время запроса и снимается
  // в finally, второй вызов с тем же id, пока первый не завершился, игнорируется.
  final Set<String> _pendingActionIds = {};

  // Порядок в списке, «замороженный» на время анимации отметки выполненной:
  // id задачи → ранг (0 активная / 1 выполненная), который используется при
  // сортировке вместо фактического is_completed. См. _toggleTask и
  // MainContentArea.frozenCompletedRanks.
  final Map<dynamic, int> _frozenCompletedRanks = {};
  final Map<dynamic, Timer> _reorderReleaseTimers = {};

  /// Локальные отметки, которые сервер ещё не подтвердил, — см. [_PinnedCompletion].
  final Map<dynamic, _PinnedCompletion> _pinnedCompletions = {};

  Future<void> _guardedAction(String actionId, Future<void> Function() action) async {
    if (_pendingActionIds.contains(actionId)) return;
    _pendingActionIds.add(actionId);
    try {
      await action();
    } finally {
      _pendingActionIds.remove(actionId);
    }
  }

  List<Map<String, dynamic>> tasks = [];

  /// Доступное обновление приложения, если оно есть.
  ///
  /// Проверяется один раз при запуске: чаще незачем — человек не сидит в
  /// приложении месяцами без перезапуска, а лишний запрос на каждом экране
  /// ничего не добавляет.
  UpdateInfo? _availableUpdate;

  /// Первая загрузка с сервера ещё не завершилась (D3).
  ///
  /// Нужно, чтобы отличить «задач нет» от «задачи ещё едут». Раньше при
  /// холодном старте с пустым кэшем экран уверенно показывал пустое состояние
  /// («Задач пока нет» с иллюстрацией) и через мгновение сменялся списком —
  /// то есть первое, что видел новый человек, было утверждение, которое тут же
  /// опровергалось.
  bool _initialLoadPending = true;

  /// Сколько задач в базе всего — спрашивается у сервера (B3). null, пока не
  /// спросили или пока нет связи; панель статистики в этом случае честно
  /// подписывает число как «загружено», а не как «в базе».
  int? _totalTasksInBase;
  Map<String, dynamic>? _taskToDuplicate;
  bool _isDuplicating = false;

  String selectedMenu = 'Мой день';
  // Переход "написать" из карточки друга — открывает Сообщения сразу с этим
  // диалогом (см. MainContentArea.onOpenDirectChat/MessengerShell).
  String? _pendingChatPartnerId;
  String? _pendingChatPartnerName;
  final String baseUrl = AppConfig.backendBaseUrl;
  bool isAiTyping = false;
  bool _isOffline = false;
  // Сводку о пропущенных дедлайнах показываем один раз за запуск приложения,
  // при первой успешной загрузке задач — не при каждом _fetchTasks().
  bool _hasCheckedMissedDeadlinesOnStartup = false;
  // Сколько изменений ждут отправки на сервер (см. TaskService.pendingOpsCount) —
  // отражается в шапке, чтобы пользователь не думал, будто изменение просто исчезло.
  int _pendingOpsCount = 0;
  String rightPanelState = 'none';
  DateTime _currentCalendarDate = DateTime.now();

  String? activeTagFilter;
  String? activePriorityFilter;
  // Способ сортировки переехал в AppSettings.taskSortMode: он общий с
  // мобильным и переживает перезапуск, а прежний флаг жил только в памяти
  // этого экрана и сбрасывался при каждом запуске.

  late Box _settingsBox;

  List<Map<String, dynamic>> workspaces = [];
  // Канал для живой синхронизации задач


// --- АВАТАРКИ КОМАНДЫ ---
  // Словарь: Ключ - ID команды, Значение - список участников
  Map<int, List<Map<String, dynamic>>> workspaceMembers = {};
  // --- ФАЗА 3: ФОКУСИРОВАНИЕ (ZEN MODE) ---
  Map<String, bool> zenStatuses = {}; // Храним статусы коллег
  bool _isMyZenActive = false; // Мой личный статус

  // Скачиваем актуальные статусы из базы
  Future<void> _fetchZenStatuses() async {
    try {
      final data = await Supabase.instance.client.from('user_status').select('user_id, is_in_zen');
      if (mounted) {
        setState(() {
          zenStatuses.clear();
          for (var row in data) {
            zenStatuses[row['user_id'].toString()] = row['is_in_zen'] == true;
            // Проверяем свой собственный статус
            if (row['user_id'].toString() == Supabase.instance.client.auth.currentUser?.id) {
              _isMyZenActive = row['is_in_zen'] == true;
            }
          }
        });
      }
    } catch (e) { logError("Ошибка загрузки статусов Zen: $e"); }
  }

  // Включаем/Выключаем режим
  Future<void> _toggleZenMode() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;
    
    final newState = !_isMyZenActive;
    
    try {
      // Отправляем в БД: если включили, ставим таймер на 45 минут
      await Supabase.instance.client.from('user_status')
          .update({
            'is_in_zen': newState, 
            'zen_until': newState ? DateTime.now().add(Duration(minutes: AppSettings.zenDurationMinutes)).toIso8601String() : null
          })
          .eq('user_id', user.id);
          
      setState(() => _isMyZenActive = newState);
      
      if (mounted) {
        ClarifyToast.show(
          context,
          (newState ? "Фокусирование включено! Уведомления заглушены" : "Фокусирование выключено!").tr(widget.currentLang),
          variant: ClarifyToastVariant.info,
        );
      }
    } catch (e) { logError("Ошибка активации Zen: $e"); }
  }

  // Функция скачивает имена и профили участников из базы
  Future<void> _fetchWorkspaceMembers(int wsId) async {
    try {
      final response = await Supabase.instance.client.rpc(
        'get_workspace_members',
        params: {'ws_id': wsId},
      );
      
      if (mounted) {
        setState(() {
          workspaceMembers[wsId] = List<Map<String, dynamic>>.from(response);
        });
      }
    } catch (e) {
      logError("Ошибка загрузки профилей: $e");
    }
  }

  // Пустой список + отдельная плашка-онбординг вместо постоянного
  // приветственного сообщения первым элементом — по прямому запросу
  // пользователя "должно совпадать с мобильной версией" (2026-08-01):
  // MobileAiScreen показывает иллюстрацию с подсказкой только при первом
  // использовании (AppSettings.aiOnboardingSeen), затем просто короткую
  // подсказку на пустом чате — то же самое воспроизведено в AiChatPanel.
  List<Map<String, String>> chatMessages = [];
  late final bool _showAiOnboardingTip = !AppSettings.aiOnboardingSeen;
  final List<String> menuItems = ['Мой день', 'Следующие 7 дней', 'Все задачи', 'Календарь', 'Входящие', 'Проекты', if (Features.social) 'Друзья', if (Features.social) 'Сообщения', 'Статистика', 'История', 'Корзина'];
  final List<String> weekdaysRu = ['понедельник', 'вторник', 'среда', 'четверг', 'пятница', 'суббота', 'воскресенье'];

  bool get isDark => widget.isDark;
  Color get bgColor => Colors.transparent;
  ClarifyTokens get _tokens => isDark ? ClarifyTokens.dark : ClarifyTokens.light;
  Color get glassColor => _tokens.surface.withValues(alpha: isDark ? 0.55 : 0.7);
  Color get glassBorderColor => _tokens.border;
  Color get panelColor => glassColor;
  Color get cardColor => glassColor;
  Color get doneCardColor => _tokens.surfaceSunken.withValues(alpha: isDark ? 0.7 : 0.85);
  Color get borderColor => glassBorderColor;
  Color get borderStrong => _tokens.borderStrong;
  Color get textColor => _tokens.text;
  Color get textMuted => _tokens.text2;
  Color get highlightColor => _tokens.accentSoft;
  Color get chatBubbleAi => _tokens.surface2.withValues(alpha: isDark ? 0.6 : 0.8);
  Color get chatInput => _tokens.surfaceSunken.withValues(alpha: isDark ? 0.7 : 0.85);

  String get _userFullName => Supabase.instance.client.auth.currentUser?.userMetadata?['full_name']?.toString() ?? '';
  String get _userInitial => _userFullName.isNotEmpty ? _userFullName[0].toUpperCase() : '?';

  Widget _buildStatisticsDashboardWidget() => StatisticsDashboard(
        tasks: tasks,
        totalInBase: _totalTasksInBase,
        workspaces: workspaces,
        currentLang: widget.currentLang,
        textColor: textColor,
        textMuted: textMuted,
        isOverdue: _isOverdue,
        parseDate: _parseDate,
        getPriorityColor: _getPriorityColor,
        buildGlassContainer: _buildGlassContainer,
      );

  /// Общее число задач в базе для панели статистики (B3).
  ///
  /// Не удалось — оставляем null, а не ноль: панель должна отличать «в базе
  /// столько-то» от «сервер не ответил» и во втором случае честно подписывать
  /// цифру как «загружено».
  Future<void> _refreshTotalTaskCount() async {
    final total = await _taskService.fetchTotalTaskCount();
    if (!mounted || total == null) return;
    setState(() => _totalTasksInBase = total);
  }

  /// История (B3) — выполненные задачи старше окна загрузки.
  ///
  /// Отдельный экран и отдельный запрос: держать их в общем кэше значило бы
  /// вернуть ровно то, ради чего окно и вводилось.
  Widget _buildArchivePanelWidget() => ArchiveScreen(
        currentLang: widget.currentLang,
        scale: _s,
        windowDays: AppConfig.completedTasksWindowDays,
        cutoff: TaskService.archiveCutoff,
        loadPage: (before) => _taskService.fetchArchive(before: before),
      );

  /// Корзина (C6) — один и тот же экран для ПК и телефона. Раньше он
  /// собирался прямо в разметке десктопа, из-за чего на мобильной версии его
  /// просто не было: удалить с телефона можно было, а восстановить нет.
  Widget _buildTrashPanelWidget() => TrashScreen(
        currentLang: widget.currentLang,
        scale: _s,
        loadTrash: _taskService.fetchTrash,
        onRestore: (id) async {
          await _taskService.restoreTask(id);
          await _fetchTasks();
        },
        onDeleteForever: (id) async {
          await _taskService.deleteTaskForever(id);
        },
      );

  Widget _buildGlassContainer({required Widget child, BorderRadius? borderRadius, EdgeInsetsGeometry? padding, EdgeInsetsGeometry? margin, Color? customColor}) {
    return ClarifyGlass(borderRadius: borderRadius, padding: padding, margin: margin, customColor: customColor, child: child);
  }

  // Свёрнутый вариант — только аватар (по решению из этого же диалога:
  // "только аватар, имя/Настройки скрыты").
  Widget _buildUserAccountBlockCollapsed() {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return const SizedBox.shrink();

    final metadata = user.userMetadata ?? {};
    final fullName = metadata['full_name']?.toString() ?? 'Без имени';
    final avatarUrl = metadata['avatar_url']?.toString();
    final initial = fullName.isNotEmpty ? fullName[0].toUpperCase() : '?';

    return Padding(
      // Вертикальный отступ сверху — как у прежней буквы "C", раньше стоявшей
      // на этом месте (аватар переехал наверх рейла, фидбек 2026-08-01).
      padding: EdgeInsets.only(top: 24 * _s, bottom: 8 * _s),
      child: Center(
        child: Tooltip(
          message: "$fullName — ${"Профиль".tr(widget.currentLang)}",
          child: Material(
            color: Colors.transparent,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              // Раньше на широком окне (isMobileContext считается по ширине)
              // сюда попадал ПОЛНЫЙ диалог настроек — то же самое содержимое,
              // что и в новой вкладке "Настройки". Аватар должен открывать
              // ТОЛЬКО профиль, как на мобильной версии, независимо от
              // ширины окна (фидбек пользователя 2026-08-01: "блок профиля
              // всё ещё вмещает в себя настройки").
              onTap: _openProfilePageFromSettingsTab,
              hoverColor: _tokens.accent.withValues(alpha: 0.06),
              child: Padding(
                padding: EdgeInsets.all(4 * _s),
                child: CircleAvatar(
                  radius: 20 * _s,
                  backgroundColor: isDark ? Colors.black45 : Colors.white54,
                  backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl) : null,
                  child: avatarUrl == null
                      ? Text(initial, style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 18 * _s))
                      : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Даты, для которых уже показали предупреждение о перегрузке — чтобы не спамить
  // диалогом на каждой 11-й, 12-й и т.д. задаче после смены `== 10` на `>= 10`.
  final Set<String> _burnoutWarnedDates = {};

  @override
  void initState() {
    super.initState();
    _settingsBox = Hive.box('settings');

    _loadLocalData();
    _fetchTasks();    
    _fetchWorkspaces(); 
    _fetchZenStatuses(); // <--- Добавили запуск загрузки статусов
    _initRealtime(); // <--- ВОТ ЭТА НОВАЯ СТРОЧКА
    
    _initGlobalHotkeys();
    Analytics.start();
    // На вебе обновляться нечему: PWA получает новую версию сама, через
    // service worker. Спрашивать сервер о версии установщика там незачем.
    if (!kIsWeb) unawaited(_checkForUpdate());
    if (_showAiOnboardingTip) AppSettings.aiOnboardingSeen = true;
  }

  /// Проверка обновлений — тихая. Не смогли проверить, сервер спит (Render на
  /// бесплатном тарифе засыпает) — молчим: собственные неудачи проверки не
  /// повод беспокоить человека.
  Future<void> _checkForUpdate() async {
    final update = await UpdateService.check();
    if (!mounted || update == null) return;
    setState(() => _availableUpdate = update);
  }

  Future<void> _openUpdateUrl() async {
    final update = _availableUpdate;
    if (update == null) return;
    // Пока — ссылка в браузере. Когда появится обновлятор, он будет качать по
    // этому же адресу и подменять файлы сам; здесь поменяется одна строка.
    final target = update.url.isNotEmpty ? update.url : AppConfig.siteUrl;
    final uri = Uri.tryParse(target);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  void _loadLocalData() {
    final cachedTasks = _taskService.getCachedTasks();
    if (cachedTasks.isNotEmpty) {
      setState(() {
        tasks = cachedTasks;
        _rebuildAllAlarms();
      });
    }
  }

  void _initGlobalHotkeys() async {
    HotKey hotKey = HotKey(key: PhysicalKeyboardKey.space, modifiers: [HotKeyModifier.control], scope: HotKeyScope.system);
    await hotKeyManager.register(hotKey, keyDownHandler: (hotKey) { appWindow.show(); appWindow.restore(); _showManualAddDialog(); });

    HotKey searchKey = HotKey(key: PhysicalKeyboardKey.keyF, modifiers: [HotKeyModifier.control], scope: HotKeyScope.inapp);
    await hotKeyManager.register(searchKey, keyDownHandler: (hotKey) => _showSearchDialog());

    HotKey commandPaletteKey = HotKey(key: PhysicalKeyboardKey.keyK, modifiers: [HotKeyModifier.control], scope: HotKeyScope.inapp);
    await hotKeyManager.register(commandPaletteKey, keyDownHandler: (hotKey) => _showCommandPalette());
  }

  // Раньше поиск был доступен ТОЛЬКО по Ctrl+F — невидимая функция для того,
  // кто не знает про горячую клавишу (на мобильном есть заметная иконка в
  // шапке "Задач"). Вынесено в отдельный метод, чтобы использовать и тут, и
  // в новой кнопке "Поиск" на рейле сайдбара (2026-08-01).
  void _showSearchDialog() {
    showSearchDialog(
      context: context,
      currentLang: widget.currentLang,
      textColor: textColor,
      textMuted: textMuted,
      tasks: tasks,
      onTaskSelected: _showTaskDetailsDialog,
      buildGlassContainer: _buildGlassContainer,
    );
  }

  void _showCommandPalette() {
    showCommandPalette(
      context: context,
      currentLang: widget.currentLang,
      textColor: textColor,
      textMuted: textMuted,
      isDark: isDark,
      tasks: tasks,
      menuItems: menuItems,
      onNavigate: (menu) => setState(() => selectedMenu = menu),
      onCreateTask: () => _showManualAddDialog(),
      onToggleTheme: widget.toggleTheme,
      // Раньше открывался диалог настроек — теперь это полноценная вкладка
      // (см. "Настройки" в sidebar_menu.dart), палитра должна вести туда же.
      onOpenSettings: () => setState(() => selectedMenu = 'Настройки'),
      onAskAi: (query) => setState(() {
        rightPanelState = 'ai';
        _aiChatController.text = query;
      }),
      onTaskSelected: _showTaskDetailsDialog,
      buildGlassContainer: _buildGlassContainer,
    );
  }

  // Локальный статус доски проекта (Не начато/В работе) — нет поля в БД под это,
  // поэтому не синхронизируется между устройствами; "Готово" считается отдельно
  // по реальному is_completed. См. lib/widgets/project_kanban_board.dart.
  Map<String, String> _readKanbanStatusMap() {
    final raw = _settingsBox.get('kanban_status');
    if (raw == null) return {};
    return Map<String, String>.from(json.decode(raw));
  }

  String _getLocalKanbanStatus(dynamic taskId) => _readKanbanStatusMap()[taskId.toString()] ?? 'todo';

  void _setLocalKanbanStatus(dynamic taskId, String status) {
    setState(() {
      final map = _readKanbanStatusMap();
      map[taskId.toString()] = status;
      _settingsBox.put('kanban_status', json.encode(map));
    });
  }

  // Иконки авто-папок проектов (тег → ключ из kPickableProjectIcons) —
  // локально, не через Supabase: у тегов нет своей строки в базе, это личные
  // ярлыки одного пользователя (см. REDESIGN_V3_PLAN.md §5.11).
  Map<String, String> _readProjectIconKeys() {
    final raw = _settingsBox.get('project_icons');
    if (raw == null) return {};
    return Map<String, String>.from(json.decode(raw));
  }

  void _setProjectIcon(String tag, String iconKey) {
    setState(() {
      final map = _readProjectIconKeys();
      map[tag] = iconKey;
      _settingsBox.put('project_icons', json.encode(map));
    });
  }

  // Цвет авто-папок проектов (тег → индекс в ClarifyTokens.tagPalette) —
  // тем же способом, что и иконки: локально в Hive, без Supabase.
  Map<String, int> _readProjectColorKeys() {
    final raw = _settingsBox.get('project_colors');
    if (raw == null) return {};
    return Map<String, int>.from(json.decode(raw));
  }

  void _setProjectColor(String tag, int colorIndex) {
    setState(() {
      final map = _readProjectColorKeys();
      map[tag] = colorIndex;
      _settingsBox.put('project_colors', json.encode(map));
    });
  }

  Future<void> _setWorkspaceIcon(int workspaceId, String iconKey) async {
    setState(() {
      final idx = workspaces.indexWhere((w) => w['id'] == workspaceId);
      if (idx != -1) workspaces[idx]['icon'] = iconKey;
    });
    try {
      await Supabase.instance.client.from('workspaces').update({'icon': iconKey}).eq('id', workspaceId);
    } catch (e) {
      logError("Не удалось сохранить иконку команды: $e");
    }
  }

  @override
  void dispose() {
    // Отметка «пользователь видел задачи вот до этого момента» — иначе после
    // долгой сессии дедлайны, прошедшие уже на глазах у человека (о них
    // сработали обычные будильники), при следующем запуске приехали бы ещё раз
    // как «пропущенные». См. _checkMissedDeadlinesOnStartup.
    _rememberSeenNow();
    _taskService.dispose(); // <--- ЗАКРЫВАЕМ СОКЕТ ЧЕРЕЗ СЕРВИС
    _aiChatController.dispose();
    for (var timer in _activeAlarms.values) {
      timer.cancel();
    }
    for (final timer in _reorderReleaseTimers.values) {
      timer.cancel();
    }
    super.dispose();
  }

// --- НОВЫЙ МЕТОД ЗАГРУЗКИ КОМАНД ---
  Future<void> _fetchWorkspaces() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;

    try {
      // Ищем команды, где юзер является создателем ИЛИ участником
      final memberResponse = await Supabase.instance.client
          .from('workspace_members')
          .select('workspace_id')
          .eq('user_id', user.id);

      final List<int> workspaceIds = memberResponse.map<int>((m) => m['workspace_id'] as int).toList();

      if (workspaceIds.isNotEmpty) {
        final data = await Supabase.instance.client
            .from('workspaces')
            .select()
            .inFilter('id', workspaceIds)
            .order('created_at', ascending: true);

        if (mounted) {
          setState(() {
            workspaces = List<Map<String, dynamic>>.from(data);
          });
          // Переподписываемся уже зная команды — см. _initRealtime.
          _initRealtime();
        }
      } else {
        if (mounted) setState(() => workspaces = []);
      }
    } catch (e) {
      logError("Ошибка загрузки команд: $e");
    }
  }

  // "Ежедневный обзор" — утренняя сводка (сколько задач сегодня, сколько
  // просрочено), не поздравление с закрытием всех задач (как было раньше) —
  // та версия срабатывала только в узком случае "все задачи на сегодня
  // выполнены", из-за чего выглядела как "не работает" для большинства
  // пользователей. Показывается один раз за день — не привязана к конкретному
  // времени суток (у бэкенда нет таймзоны пользователя, чтобы слать это
  // именно утром через push). Дата последнего показа — в Hive
  // (AppSettings.lastDailyReviewDate), не в поле State: на мобильном PWA
  // браузер/ОС часто убивает вкладку в фоне и пересоздаёт State при каждом
  // возврате в приложение, из-за чего обзор с чисто in-memory отметкой
  // показывался практически при каждом заходе вместо одного раза в день.
  void _checkDailyReviewTrigger() {
    if (!AppSettings.dailyReviewEnabled) return;
    final todayStr = _formatDate(DateTime.now());
    if (AppSettings.lastDailyReviewDate == todayStr) return; // Уже показывали сегодня
    AppSettings.lastDailyReviewDate = todayStr;

    final todayPending = tasks.where((t) => t['due_date'] == todayStr && t['parent_id'] == null && t['is_completed'] != true).length;
    final overdueCount = tasks.where((t) => _isOverdue(t)).length;

    _showDailyReviewOverlay(todayCount: todayPending, overdueCount: overdueCount);
  }
  // 4. ЛОГИКА УМНЫХ БУДИЛЬНИКОВ
  void _rebuildAllAlarms() {
    for (var timer in _activeAlarms.values) {
      timer.cancel();
    }
    _activeAlarms.clear();

    for (var task in tasks) {
      _scheduleTaskAlarms(task);
    }
  }

  void _scheduleTaskAlarms(Map<String, dynamic> task) {
    if (task['is_completed'] == true || task['due_date'] == null || task['due_time'] == null) return;
    final int taskId = task['id'];

    final taskDate = _parseDate(task['due_date']);
    if (taskDate == null) return;
    final timeParts = task['due_time'].toString().split(':');
    if (timeParts.length != 2) return;

    final taskTime = DateTime(taskDate.year, taskDate.month, taskDate.day, int.parse(timeParts[0]), int.parse(timeParts[1]));
    final now = DateTime.now();

    void setTimer(DateTime alarmTime, int offset, String title, String body) {
      if (alarmTime.isAfter(now)) {
        final delay = alarmTime.difference(now);
        final alarmId = '${taskId}_$offset';
        _activeAlarms[alarmId] = Timer(delay, () {
          _triggerPushNotification(title, body);
          _activeAlarms.remove(alarmId);
        });
      }
    }

    // Ровно 3 невидимых "будильника" + 1 в момент дедлайна
    setTimer(taskTime.subtract(const Duration(days: 3)), 1, "Бро, скоро дедлайн!", "Задача '${task['title']}' через 3 дня.");
    setTimer(taskTime.subtract(const Duration(days: 1)), 2, "Завтра сдавать!", "Задача '${task['title']}' завтра в ${task['due_time']}.");
    setTimer(taskTime.subtract(const Duration(hours: 1)), 3, "Время пришло!", "Задача '${task['title']}' через 1 час.");
    setTimer(taskTime, 4, "Дедлайн!", "Задача '${task['title']}' прямо сейчас!");
  }

  Future<void> _triggerPushNotification(String title, String body) async {
    // 🚀 ЕСЛИ МЫ В ФОКУСЕ - БЛОКИРУЕМ ЛЮБЫЕ ПУШИ ОТ ЗАДАЧ
    if (_isMyZenActive) return;
    if (!AppSettings.notificationsEnabled) return;

    if (kIsWeb) {
      // На web/мобильном PWA эти таймеры — обычные Dart Timer внутри
      // страницы: ОС усыпляет вкладку в фоне (особенно iOS Safari), поэтому
      // раньше уведомление реально показывалось только при следующем заходе
      // в приложение, и сразу пачкой по всем накопленным дедлайнам (живой
      // фидбек пользователя 2026-08-01). Настоящая доставка "в любой момент"
      // для веба/мобильного теперь идёт через Telegram-бота (см.
      // backend/clarify-backend/main.py:check_due_tasks) — здесь сознательно
      // ничего не показываем, чтобы не дублировать неработающий механизм.
      return;
    }

    try {
      LocalNotification notification = LocalNotification(
        title: title,
        body: body,
      );
      
      // Магия: если юзер кликнет по пушу в Windows, приложение развернется из трея!
      notification.onClick = () {
        appWindow.show();
        appWindow.restore();
      };

      await notification.show();
    } catch (e) {
      logError("Ошибка отправки пуша: $e");
      // Если пуш не сработал, показываем внутриигровой снекбар
      if (mounted) {
        ClarifyToast.show(context, "$title: $body", variant: ClarifyToastVariant.info);
      }
    }
  }

  String _formatDate(DateTime d) => "${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}";
  DateTime? _parseDate(String dateStr) { try { final parts = dateStr.split('.'); if (parts.length == 3) return DateTime(int.parse(parts[2]), int.parse(parts[1]), int.parse(parts[0])); } catch (e) { return null; } return null; }

  // 'red'/'orange'/'blue'/'gray' — исторические имена цвета в БД, семантически urgent/important/normal/low.
  Color _getPriorityColor(String? priority) { switch (priority) { case 'red': return _tokens.danger; case 'orange': return _tokens.warning; case 'blue': return _tokens.accent; case 'gray': return textMuted; default: return borderStrong; } }

  List<Map<String, dynamic>> get filteredTasks {
    var result = tasks;
    if (activeTagFilter != null) {
      result = result.where((t) => parseTagsString(t['tags']).contains(activeTagFilter)).toList();
    }
    if (activePriorityFilter != null) {
      result = result.where((t) => t['priority'] == activePriorityFilter).toList();
    }
    return result;
  }
  Map<String, int> _getSubtaskStats(dynamic parentId) { final subtasks = tasks.where((t) => t['parent_id'] == parentId).toList(); if (subtasks.isEmpty) return {'total': 0, 'done': 0}; return {'total': subtasks.length, 'done': subtasks.where((t) => t['is_completed'] == true).length}; }

  /// Закрепление оптимистичной отметки поверх пришедших с сервера строк.
  ///
  /// Пока сервер не подтвердил наш собственный toggle, локальное значение
  /// сильнее любого приходящего снимка: снимок мог быть сделан ДО того, как наш
  /// UPDATE закоммитился. Именно это когда-то давало «мигание» чекбокса
  /// (отметился / откатился / отметился снова).
  ///
  /// Вынесено из _fetchTasks отдельно, потому что теперь тот же разбор нужен и
  /// для точечного применения realtime-события (B2): если применить событие в
  /// обход этой логики, мигание вернётся ровно в том же виде.
  void _applyPinnedCompletions(Iterable<Map<String, dynamic>> rows) {
    for (final row in rows) {
      final pinned = _pinnedCompletions[row['id']];
      if (pinned == null) continue;
      if (pinned.agreesWith(row) || pinned.isExpired) {
        _pinnedCompletions.remove(row['id']);
        continue;
      }
      row['is_completed'] = pinned.isCompleted;
      row['completed_at'] = pinned.completedAt;
    }
  }

  /// Точечное применение realtime-события вместо перечитывания всей таблицы
  /// (вторая половина B2).
  ///
  /// Раньше любое событие вызывало полный select() всех задач: отметил одну
  /// задачу — выкачали весь список, чтобы узнать про одну изменившуюся строку.
  ///
  /// Если событие применить не удалось (пришло без id, неизвестный тип) —
  /// честно откатываемся на полный фетч: «применить неправильно» здесь хуже,
  /// чем «перечитать лишний раз».
  void _applyRealtimeTaskEvent(PostgresChangePayload payload) {
    if (!_taskService.applyRealtimeChange(payload)) {
      _fetchTasks();
      return;
    }
    if (!mounted) return;
    setState(() {
      final updated = _taskService.getCachedTasks();
      _applyPinnedCompletions(updated);
      tasks = updated;
      _isOffline = false;
      _pendingOpsCount = _taskService.pendingOpsCount;
      _applyFilters();
      _rebuildAllAlarms();
    });
  }

  Future<void> _fetchTasks() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;

    try {
      final fetchedTasks = await _taskService.fetchTasks();
      if (mounted) {
        setState(() {
          // Пока для задачи есть незавершённое собственное действие (toggle
          // ещё летит на сервер, см. _pendingActionIds/_guardedAction) — не
          // даём этому fetchTasks() (например, случайно триггернутому чужим
          // realtime-событием, пришедшим прямо во время нашего же клика)
          // откатить локальное оптимистичное состояние снимком с сервера,
          // который мог быть сделан ДО того, как наш собственный запрос
          // закоммитился. Именно это было причиной периодического "мигания"
          // чекбокса (отметился/откатился/отметился).
          // Пока сервер не подтвердил нашу отметку, локальное значение сильнее
          // любого приходящего снимка: он мог быть сделан до коммита нашего
          // UPDATE (см. _PinnedCompletion). Подтвердил — закрепление снимаем и
          // дальше живём по серверу, включая его completed_at (у него своя
          // точность, спорить с ней незачем).
          _applyPinnedCompletions(fetchedTasks);
          tasks = fetchedTasks;
          _initialLoadPending = false;
          _isOffline = false;
          _pendingOpsCount = _taskService.pendingOpsCount;
          _applyFilters();
          _rebuildAllAlarms();
        });
        _checkMissedDeadlinesOnStartup();
        _checkDailyReviewTrigger();
        // Отдельным запросом и НЕ блокируя список: это одно число для панели
        // статистики, и ждать его ради отрисовки задач незачем.
        unawaited(_refreshTotalTaskCount());
      }
    } catch (e) {
      logError("!!! РЕАЛЬНАЯ ОШИБКА БАЗЫ ДАННЫХ: $e");
      if (mounted) {
        setState(() {
          // Скелетон снимаем и здесь: «нет сети» — это тоже ответ, и висеть
          // силуэтами до бесконечности хуже, чем показать то, что есть в кэше.
          _initialLoadPending = false;
          _isOffline = true;
          _pendingOpsCount = _taskService.pendingOpsCount;
        });
        ClarifyToast.show(context, "Нет сети. Работаем локально!".tr(widget.currentLang), variant: ClarifyToastVariant.warning);
      }
    }
  }

  // Уведомления о дедлайнах (см. _scheduleTaskAlarms) работают только пока
  // приложение запущено — это Dart Timer, не системный планировщик ОС.
  // Настоящие OS-level scheduled-уведомления через flutter_local_notifications
  // технически возможны на Windows (zonedSchedule), но их cancel() официально
  // не работает для приложений, не упакованных в MSIX (см. README пакета
  // flutter_local_notifications_windows) — а Clarify сейчас распространяется
  // как обычный .exe. Использовать их означало бы получить уведомления,
  // которые нельзя отменить при переносе/выполнении/удалении задачи — то есть
  // риск показать уведомление с устаревшим содержимым, что хуже отсутствия
  // уведомления вовсе. Поэтому вместо этого — сводка при следующем запуске:
  // честный, проверяемый компромисс, не требующий MSIX-упаковки.
  void _checkMissedDeadlinesOnStartup() {
    if (_hasCheckedMissedDeadlinesOnStartup) return;
    _hasCheckedMissedDeadlinesOnStartup = true;

    // Костыль ниже — компромисс именно под Windows-.exe без MSIX (см.
    // комментарий выше). На web/PWA он не нужен и мешает: там уже есть
    // настоящий фоновый push через /internal/check-due-tasks, и без этой
    // проверки пользователь получал системное уведомление о просроченных
    // задачах при КАЖДОМ открытии приложения, а не только когда реально
    // пропустил дедлайн, пока оно было закрыто.
    if (kIsWeb) return;

    // Сообщаем только о тех дедлайнах, которые прошли ИМЕННО ПОКА ПРИЛОЖЕНИЕ
    // БЫЛО ЗАКРЫТО. Раньше условием было просто "есть просроченные", и
    // уведомление «Пока вас не было» прилетало при КАЖДОМ запуске — в том числе
    // про задачи, просроченные месяц назад, которые человек и так видит в
    // списке каждый день. Такое уведомление перестают читать за пару дней, и
    // вместе с ним перестают читать все остальные.
    final DateTime? lastSeen = _lastSeenAt();
    _rememberSeenNow();
    // Первый запуск (или после очистки кэша): точки отсчёта нет, и всё
    // просроченное формально «пропущено». Молчим — это не новость.
    if (lastSeen == null) return;

    final missed = tasks.where((task) {
      if (task['is_completed'] == true) return false;
      final deadline = _taskDeadline(task);
      if (deadline == null) return false;
      return deadline.isAfter(lastSeen) && deadline.isBefore(DateTime.now());
    }).toList();
    if (missed.isEmpty) return;

    final firstTitle = missed.first['title'] ?? '';
    final body = missed.length == 1
        ? 'Задача "$firstTitle" просрочена.'
        : 'Просрочено задач: ${missed.length}. Например: "$firstTitle".';

    _triggerPushNotification('Пока вас не было', body);
  }

  /// Когда приложение в последний раз показывало пользователю его задачи.
  DateTime? _lastSeenAt() {
    final raw = _settingsBox.get('last_seen_at');
    if (raw is! String) return null;
    return DateTime.tryParse(raw);
  }

  void _rememberSeenNow() {
    _settingsBox.put('last_seen_at', DateTime.now().toIso8601String());
  }

  // --- МАГИЯ REALTIME ---
  void _initRealtime() {
    // Команды известны не сразу — _fetchWorkspaces отрабатывает уже после
    // старта, поэтому он вызывает этот метод повторно с готовым списком.
    // Без командных id правки коллег в общих задачах до нас не долетают:
    // подписка на свои задачи фильтруется по user_id, а владелец командной
    // задачи — тот, кто её создал.
    _taskService.initRealtime(
      onTaskEvent: _applyRealtimeTaskEvent,
      onZenChanged: () => _fetchZenStatuses(),
      workspaceIds: workspaces
          .map((w) => w['id'])
          .whereType<int>()
          .toList(),
    );
  }

  // Общая логика для десктопной AI-панели и мобильного AI-экрана — POST
  // /tasks/parse + подтягивание созданных/изменённых задач. Раньше эндпоинт
  // только создавал задачи и возвращал их список, теперь ассистент видит
  // существующие задачи пользователя, может их изменять (перенос/отметка
  // выполненной) и отвечать на вопросы — поэтому возвращает не счётчик, а
  // естественно-языковой ответ ("reply"), который и показываем в чате.
  // История — последние сообщения ДО этого текста, для контекста
  // многоходовой переписки (например правка предыдущего запроса). Бросает
  // AiParseHttpException на не-200 ответ, чтобы вызывающий код мог показать
  // разные сообщения для "сервер ответил ошибкой" и "нет связи".
  Future<String> _sendToAiAssistant(String text, List<Map<String, String>> history) async {
    final accessToken = Supabase.instance.client.auth.currentSession?.accessToken;
    final response = await http.post(
      Uri.parse('$baseUrl/tasks/parse'),
      headers: {
        'Content-Type': 'application/json',
        if (accessToken != null) 'Authorization': 'Bearer $accessToken',
      },
      body: json.encode({'text': text, 'history': history}),
    );
    if (response.statusCode != 200) {
      throw AiParseHttpException(response.statusCode, response.body);
    }
    final Map<String, dynamic> decoded = json.decode(response.body);
    await _fetchTasks();
    return decoded['reply'] as String;
  }

  // displayText — для голосовых сообщений: в чате показываем "🎤 <текст>",
  // но ассистенту (и истории, которую он видит в следующих сообщениях)
  // отправляем чистый текст без эмодзи-префикса.
  Future<void> _sendTaskToAI(String text, {String? displayText}) async {
    if (text.trim().isEmpty) return;
    // История — последние сообщения ДО добавления текущего в chatMessages,
    // с ограничением: чат ничем не подрезается сам по себе, и без лимита
    // очень длинная переписка раздувала бы промпт с каждым новым сообщением.
    const historyLimit = 8;
    final history = chatMessages.length > historyLimit
        ? chatMessages.sublist(chatMessages.length - historyLimit)
        : List<Map<String, String>>.from(chatMessages);
    setState(() { chatMessages.add({'role': 'user', 'text': (displayText ?? text).trim()}); isAiTyping = true; }); _aiChatController.clear();
    try {
      final reply = await _sendToAiAssistant(text, history);
      setState(() { chatMessages.add({'role': 'ai', 'text': reply}); isAiTyping = false; });
    } on AiParseHttpException catch (e) {
      final body = e.body.substring(0, e.body.length > 120 ? 120 : e.body.length);
      setState(() { chatMessages.add({'role': 'ai', 'text': '${'Ошибка: сервер вернул '.tr(widget.currentLang)}${e.statusCode} ($body)'}); isAiTyping = false; });
    } catch (e) {
      // Раньше здесь был только общий текст "Ошибка связи с ИИ." без деталей —
      // при живой отладке по скриншотам от пользователя не видно, что за
      // исключение (таймаут/CORS/обрыв сети/невалидный JSON), приходится
      // гадать. Короткий e.toString() в самом сообщении делает следующий
      // скриншот сразу диагностируемым.
      setState(() { chatMessages.add({'role': 'ai', 'text': '${'Ошибка связи с ИИ.'.tr(widget.currentLang)} (${e.toString().substring(0, e.toString().length > 120 ? 120 : e.toString().length)})'}); isAiTyping = false; });
    }
  }

  // Расшифровка голосового сообщения — по аналогии с Telegram-ботом этого же
  // приложения: запись целиком загружается на /ai/transcribe-voice (та же
  // Groq Whisper обёртка, что и у бота), а не расшифровывается вживую по
  // ходу речи, как раньше делал speech_to_text. Общая для десктопной
  // AI-панели и мобильного AI-экрана (MobileAiScreen.onTranscribeVoice) —
  // бросает AiParseHttpException на не-200 ответ, как и _sendToAiAssistant,
  // чтобы вызывающий код мог показать разные сообщения для "сервер ответил
  // ошибкой" и "нет связи".
  Future<String> _transcribeVoiceMessage(Uint8List bytes, String filename, String contentType) async {
    final accessToken = Supabase.instance.client.auth.currentSession?.accessToken;
    final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/ai/transcribe-voice'));
    if (accessToken != null) request.headers['Authorization'] = 'Bearer $accessToken';
    request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename, contentType: MediaType.parse(contentType)));
    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);
    if (response.statusCode != 200) {
      throw AiParseHttpException(response.statusCode, response.body);
    }
    return (json.decode(response.body)['text'] as String).trim();
  }

  // Голосовое сообщение десктопной AI-панели — isAiTyping используется на
  // весь конвейер (расшифровка + ответ ассистента): с точки зрения
  // пользователя это один процесс "ИИ думает".
  Future<void> _sendVoiceMessageToAI(Uint8List bytes, String filename, String contentType) async {
    setState(() => isAiTyping = true);
    String transcribedText;
    try {
      transcribedText = await _transcribeVoiceMessage(bytes, filename, contentType);
    } on AiParseHttpException catch (e) {
      setState(() => isAiTyping = false);
      final body = e.body.substring(0, e.body.length > 120 ? 120 : e.body.length);
      if (mounted) ClarifyToast.show(context, '${'Ошибка: сервер вернул '.tr(widget.currentLang)}${e.statusCode} ($body)', variant: ClarifyToastVariant.danger);
      return;
    } catch (e) {
      setState(() => isAiTyping = false);
      if (mounted) ClarifyToast.show(context, '${'Ошибка расшифровки голосового.'.tr(widget.currentLang)} (${e.toString()})', variant: ClarifyToastVariant.danger);
      return;
    }
    if (transcribedText.isEmpty) {
      setState(() => isAiTyping = false);
      if (mounted) ClarifyToast.show(context, 'Не удалось распознать речь.'.tr(widget.currentLang), variant: ClarifyToastVariant.warning);
      return;
    }
    await _sendTaskToAI(transcribedText, displayText: '🎤 $transcribedText');
  }

  // Вставь этот блок вместо старой функции _createTaskManually

  // --- ЗАМЕНИ ФУНКЦИЮ _createTaskManually ПОЛНОСТЬЮ НА ЭТОТ КУСОК ---
  Future<int?> _createTaskManually(Map<String, dynamic> taskData) async {
    // '_source' — служебная пометка для аналитики, в базу её не отправляем.
    final source = taskData.remove('_source') as String? ?? 'other';
    Analytics.taskCreated(source);
    try {
      final taskFuture = _taskService.addTask(taskData); 
      
      // СИНХРОННОЕ ОБНОВЛЕНИЕ ЭКРАНА
      setState(() {
        // Оборачиваем в List.from для 100% гарантии смены ссылки
        tasks = List<Map<String, dynamic>>.from(_taskService.getCachedTasks()); 
        
        // Вызов _applyFilters() можешь смело удалить, раз он пустой!
      });
      
      final newTaskId = await taskFuture;
      await _fetchTasks();
      return newTaskId;
    } catch (e) {
      // addTask уже поставил создание в очередь на повтор (TaskService.flushPendingOps) —
      // сообщаем об этом пользователю, а не просто теряем ошибку молча (см. print ниже).
      // Без .tr(): это запись в журнал, а не текст человеку. Перевод ей не
      // нужен, да и не работал — ключ с уже подставленной ошибкой в словаре не
      // найдётся никогда.
      logError("Ошибка создания задачи: $e");
      if (mounted) {
        setState(() {
          _pendingOpsCount = _taskService.pendingOpsCount;
          // Сервис уже убрал из кэша задачу, которую сервер отклонил (B7) —
          // забираем актуальный список, иначе отклонённая задача осталась бы
          // висеть на экране до следующего полного перечитывания и исчезла бы
          // потом молча. При сетевой ошибке она в кэше остаётся: уйдёт из
          // очереди отложенных операций, когда сеть вернётся.
          tasks = List<Map<String, dynamic>>.from(_taskService.getCachedTasks());
          _applyFilters();
        });
        final message = e is PostgrestException
            ? "Не удалось сохранить: ".tr(widget.currentLang) + e.message
            : "Не удалось сохранить задачу на сервере. Отправим, когда сеть восстановится.".tr(widget.currentLang);
        ClarifyToast.show(context, message, variant: ClarifyToastVariant.warning);
      }
      return null;
    }
  }
// --- КОНЕЦ ЗАМЕНЫ ---

// Ниже идет следующий метод твоего класса...

  Future<void> _updateTaskData(dynamic taskId, Map<String, dynamic> taskData) async {
    try {
      await _taskService.updateTask(taskId, taskData); // <--- ИСПОЛЬЗУЕМ СЕРВИС

      await _fetchTasks();
    } catch (e) {
      // updateTask уже поставил изменение в очередь на повтор (TaskService.flushPendingOps) —
      // сообщаем об этом пользователю, а не просто теряем изменение молча.
      logError("Ошибка обновления задачи: $e");
      if (mounted) {
        setState(() => _pendingOpsCount = _taskService.pendingOpsCount);
        final message = e is PostgrestException
            ? "Не удалось сохранить: ".tr(widget.currentLang) + e.message
            : "Нет сети. Изменение отправим, когда сеть восстановится.".tr(widget.currentLang);
        ClarifyToast.show(context, message, variant: ClarifyToastVariant.warning);
      }
    }
  }

  Future<void> _spawnNextRecurringTask(Map<String, dynamic> task) async {
    DateTime? oldDate = _parseDate(task['due_date']); if (oldDate == null) return;

    // Порождает следующий экземпляр только самый свежий из существующих.
    // Раньше это делала ЛЮБАЯ отмеченная копия — отсюда лавина: на момент
    // аудита 04.09.2026 в базе лежало 44 копии одной задачи с датами,
    // марширующими по месяцам на год вперёд, и 55 клонов её подзадач.
    // Сами правила — в core/recurrence.dart, там же тесты на них.
    if (!isLatestRecurringInstance(
      tasks: tasks,
      task: task,
      date: oldDate,
      parseDate: _parseDate,
    )) {
      return;
    }

    // Точка отсчёта: плановая дата или момент фактической отметки — см. C3.
    final DateTime anchor = recurrenceAnchor(
      dueDate: oldDate,
      fromCompletion: task['recurrence_from_completion'] == true,
      completedAt: DateTime.tryParse(task['completed_at']?.toString() ?? ''),
    );

    final DateTime? newDate = nextRecurrenceDate(
      from: anchor,
      recurrence: task['recurrence'] as String?,
      interval: task['recurrence_interval'] as int?,
    );
    if (newDate == null) return;
    final String newDateStr = _formatDate(newDate);

    // Такой экземпляр уже есть — второй не нужен. Страхует от повторной отметки
    // (снял галочку, поставил обратно) и от гонки двух устройств.
    if (recurringInstanceExists(tasks: tasks, task: task, dateStr: newDateStr)) return;

    int? newTaskId = await _createTaskManually({"_source": "repeat", "title": task['title'], "due_date": newDateStr, "due_time": task['due_time'], "note": task['note'], "priority": task['priority'], "tags": task['tags'], "recurrence": task['recurrence'], "recurrence_interval": task['recurrence_interval'], "recurrence_from_completion": task['recurrence_from_completion'] == true, "parent_id": task['parent_id'], "is_completed": false});
    // Подзадачи клонируются только вместе с РЕАЛЬНО созданным родителем: если
    // создание не прошло (offline/ошибка), клоны подзадач осиротели бы.
    if (newTaskId != null && task['parent_id'] == null) { final subtasks = tasks.where((t) => t['parent_id'] == task['id']).toList(); for (var sub in subtasks) { await _createTaskManually({"_source": "subtask", "title": sub['title'], "parent_id": newTaskId, "is_completed": false}); } }
  }

  /// Отпускает «замороженный» порядок задачи — то есть разрешает ей переехать
  /// в блок выполненных (или обратно наверх).
  ///
  /// Ждём не только конца анимации отметки, но и ответа сервера на наш же
  /// UPDATE. Иначе получается ДВЕ перестановки на один клик: первая — по
  /// таймеру, вторая — когда realtime-фетч приносит снимок, сделанный до
  /// коммита нашего запроса. Именно это выглядело как «спустилась на строку и
  /// снова всё замельтешило».
  void _releaseFrozenRank(dynamic taskId, {int attempt = 0}) {
    if (!mounted) return;
    // Ждём не только ответа сервера, но и подтверждения нашей отметки в
    // прилетевшем снимке: пока значение не устоялось, перестановка может
    // случиться дважды — сначала вниз, потом обратно. Ожидание ограничено ~2
    // секундами, иначе при офлайн-очереди задача осталась бы висеть на старом
    // месте вообще навсегда.
    final unsettled = _pendingActionIds.contains('toggle_$taskId') ||
        _pinnedCompletions.containsKey(taskId);
    if (unsettled && attempt < 16) {
      _reorderReleaseTimers[taskId] = Timer(
        // Пауза перед повторной проверкой, а не анимация.
        const Duration(milliseconds: 120),
        () => _releaseFrozenRank(taskId, attempt: attempt + 1),
      );
      return;
    }
    setState(() {
      _frozenCompletedRanks.remove(taskId);
      _reorderReleaseTimers.remove(taskId);
    });
  }

  /// Сохраняет порядок, выставленный перетаскиванием.
  ///
  /// Отдельным методом, а не прямо в колбэке: перетаскивание — жест, после
  /// которого список уже перерисован, и ждать ответа сервера, держа палец,
  /// незачем. Ошибку показываем тостом, но порядок на экране не откатываем:
  /// сеть вернётся, очередь в TaskService дошлёт правку, а дёрганый откат
  /// прямо под рукой раздражает сильнее, чем задержка синхронизации.
  void _persistManualOrder(List<Map<String, dynamic>> orderedTasks) {
    unawaited(
      _taskService.saveManualOrder(orderedTasks).catchError((Object e) {
        logError('Не удалось сохранить порядок задач: $e');
        if (mounted) {
          ClarifyToast.show(
            context,
            "Порядок сохранится, когда появится сеть".tr(widget.currentLang),
            variant: ClarifyToastVariant.warning,
          );
        }
      }),
    );
  }

  Future<void> _toggleTask(Map<String, dynamic> task) async {
    final actionId = 'toggle_${task['id']}';
    if (_pendingActionIds.contains(actionId)) return; // Уже в процессе — игнорируем повторный тап

    final bool currentStatus = task['is_completed'] == true;
    final bool newStatus = !currentStatus;
    final currentCompletedAt = task['completed_at'];
    final String? newCompletedAt = newStatus ? DateTime.now().toIso8601String() : null;

    setState(() {
      task['is_completed'] = newStatus;
      task['completed_at'] = newCompletedAt;
      // Порядок в списке пока держим прежний: сперва целиком отыгрывается сама
      // отметка (чекбокс + зачёркивание, ClarifyMotion.completion), и только
      // потом строка едет в блок выполненных. Раньше оба движения стартовали
      // одновременно и мешали друг другу — визуально это и был "рывок".
      _frozenCompletedRanks[task['id']] = currentStatus ? 1 : 0;
      _pinnedCompletions[task['id']] = _PinnedCompletion(
        isCompleted: newStatus,
        completedAt: newCompletedAt,
      );
      _applyFilters();
    });

    _reorderReleaseTimers[task['id']]?.cancel();
    _reorderReleaseTimers[task['id']] =
        Timer(ClarifyMotion.completion, () => _releaseFrozenRank(task['id']));

    await _guardedAction(actionId, () async {
      try {
        await _taskService.updateTask(task['id'], {'is_completed': newStatus, 'completed_at': newCompletedAt}); // <--- ИСПОЛЬЗУЕМ СЕРВИС

        if (newStatus == true && task['recurrence'] != null && task['recurrence'] != 'none') {
          _spawnNextRecurringTask(task);
        }

        // Раньше здесь был ещё и явный _fetchTasks() — но initRealtime уже
        // подписан на изменения таблицы tasks и сам вызывает _fetchTasks()
        // при коммите этого же UPDATE (onTasksChanged, см. ниже). Два
        // параллельных fetchTasks() на одно действие гонялись друг с другом
        // и оба целиком перезаписывали tasks новыми объектами — из-за этого
        // чекбокс визуально "отмечался, откатывался, отмечался снова" за
        // один клик. Оптимистичное обновление выше уже отражает верное
        // состояние — второй, серверный, придёт сам через realtime.

      } catch (e) {
        setState(() {
          task['is_completed'] = currentStatus;
          task['completed_at'] = currentCompletedAt;
          // Откат — задача остаётся там же, где была: держать порядок
          // замороженным и закреплять непрошедшую отметку больше незачем.
          _reorderReleaseTimers.remove(task['id'])?.cancel();
          _frozenCompletedRanks.remove(task['id']);
          _pinnedCompletions.remove(task['id']);
          _applyFilters();
        });
        logError("Ошибка обновления статуса: $e");
      }
    });
  }

  // Приветствие зависит от текущего часа — раньше всегда было "Доброе утро!"
  // независимо от времени суток, потому что показ этого оверлея не привязан
  // к конкретному часу (см. комментарий у _checkDailyReviewTrigger — у
  // бэкенда нет таймзоны пользователя для push именно утром).
  String _greetingForNow() {
    final hour = DateTime.now().hour;
    if (hour >= 5 && hour < 12) return "Доброе утро!";
    if (hour >= 12 && hour < 18) return "Добрый день!";
    if (hour >= 18 && hour < 23) return "Добрый вечер!";
    return "Доброй ночи!";
  }

  void _showDailyReviewOverlay({required int todayCount, required int overdueCount}) {
    final greeting = _greetingForNow();

    showClarifyResponsiveSurface(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      builder: (context) {
        final mobile = isClarifyDialogMobile(context);
        final iconSize = mobile ? 36.0 : 44.0 * _s;
        final titleSize = mobile ? 20.0 : 24.0 * _s;
        final bodySize = mobile ? 15.0 : 16.0 * _s;
        final overdueSize = mobile ? 14.0 : 15.0 * _s;

        final content = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.sunrise, size: iconSize, color: _tokens.accent),
            SizedBox(height: mobile ? 14 : 20 * _s),
            Text(greeting.tr(widget.currentLang), style: TextStyle(color: textColor, fontSize: titleSize, fontWeight: FontWeight.w800)),
            SizedBox(height: mobile ? 8 : 12 * _s),
            Text(
              todayCount == 0
                  ? "На сегодня задач не запланировано.".tr(widget.currentLang)
                  : "${'Сегодня у вас'.tr(widget.currentLang)} $todayCount ${'задач'.tr(widget.currentLang)}.",
              textAlign: TextAlign.center,
              style: TextStyle(color: textMuted, fontSize: bodySize, height: 1.4),
            ),
            if (overdueCount > 0) ...[
              SizedBox(height: mobile ? 8 : 10 * _s),
              Text(
                "${'Просрочено:'.tr(widget.currentLang)} $overdueCount",
                style: TextStyle(color: _tokens.danger, fontSize: overdueSize, fontWeight: FontWeight.w700),
              ),
            ],
            SizedBox(height: mobile ? 20 : 28 * _s),
            ClarifyButton(
              label: "Понятно".tr(widget.currentLang),
              variant: ClarifyButtonVariant.filled,
              scale: mobile ? 1.0 : _s,
              onPressed: () => Navigator.pop(context),
            ),
          ],
        );

        // Мобильный — bottom sheet (showClarifyResponsiveSurface уже даёт
        // форму/ширину/drag-to-dismiss через showClarifyBottomSheet), десктоп
        // — прежняя плавающая карточка по центру. Раньше этот диалог был
        // одинаковым на обеих платформах — "плавающая карточка" на мобильном
        // выглядела как урезанный десктоп, а не как остальные мобильные шторки.
        if (mobile) {
          return Padding(
            padding: EdgeInsets.fromLTRB(20, 4, 20, MediaQuery.of(context).padding.bottom + 20),
            child: content,
          );
        }
        return Center(
          child: Material(
            color: Colors.transparent,
            child: _buildGlassContainer(
              borderRadius: BorderRadius.circular(28 * _s),
              padding: EdgeInsets.all(32 * _s),
              child: SizedBox(
                width: (MediaQuery.sizeOf(context).width - 96).clamp(280.0, 420.0),
                child: content,
              ),
            ),
          ),
        );
      },
    );
  }

void _checkBurnoutWarning(String dateStr) {
    if (_burnoutWarnedDates.contains(dateStr)) return; // Уже предупреждали про этот день

    final dayTasks = tasks.where((t) => t['due_date'] == dateStr && t['parent_id'] == null).toList();

    if (dayTasks.length >= AppConfig.burnoutTaskThreshold) {
      _burnoutWarnedDates.add(dateStr);
      showClarifySurface(
        context: context,
        builder: (context) {
          return Center(
            child: Material(
              color: Colors.transparent,
              child: Container(
                width: 380 * _s,
                padding: EdgeInsets.all(32 * _s),
                decoration: BoxDecoration(
                  color: _tokens.surface2,
                  borderRadius: BorderRadius.circular(24 * _s),
                  border: Border.all(color: _tokens.accent.withValues(alpha: 0.3), width: 2),
                  boxShadow: [
                    BoxShadow(color: _tokens.accent.withValues(alpha: 0.1), blurRadius: 20, spreadRadius: 5)
                  ]
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(LucideIcons.flower, size: 60 * _s, color: _tokens.accent),
                    SizedBox(height: 20 * _s),
                    Text("Эй, притормози! 🛑".tr(widget.currentLang), style: TextStyle(color: textColor, fontSize: 24 * _s, fontWeight: FontWeight.w900)),
                    SizedBox(height: 12 * _s),
                    Text(
                      "Это уже 10-я задача на этот день.\n\nПродуктивность — это прекрасно, но выгорание нам ни к чему. Постарайся не перегружать расписание и обязательно оставляй окна для отдыха.\nТы не робот! 🤖", // <-- Текст тоже обновили
                      textAlign: TextAlign.center,
                      style: TextStyle(color: textMuted, fontSize: 14 * _s, height: 1.5)
                    ),
                    SizedBox(height: 28 * _s),
                    ClarifyButton(
                      label: "Понял, спасибо".tr(widget.currentLang),
                      variant: ClarifyButtonVariant.filled,
                      scale: _s,
                      onPressed: () => Navigator.pop(context),
                    )
                  ],
                ),
              ),
            ),
          );
        },
      );
    }
  }

  Future<void> _deleteTask(dynamic taskId) async {
    // Удаляем локально сразу (как и при создании задачи) — теперь это безопасно:
    // если сеть недоступна, TaskService поставит удаление в очередь и повторит
    // его сам при следующей успешной синхронизации.
    setState(() {
      tasks.removeWhere((t) => t['id'] == taskId);
      _applyFilters();
      _rebuildAllAlarms();
    });

    try {
      await _taskService.deleteTask(taskId); // <--- ИСПОЛЬЗУЕМ СЕРВИС
    } catch (e) {
      logError("Ошибка удаления: $e");
      if (mounted) {
        setState(() => _pendingOpsCount = _taskService.pendingOpsCount);
        final message = e is PostgrestException
            ? "Не удалось удалить: ".tr(widget.currentLang) + e.message
            : "Нет сети. Удаление отправим, когда сеть восстановится.".tr(widget.currentLang);
        ClarifyToast.show(context, message, variant: ClarifyToastVariant.warning);
      }
    }
  }
  
  void _applyFilters() {}

  void shiftDate(int days, int months, StateSetter setStateDialog, DateTime? currentDate) { DateTime baseDate = currentDate ?? DateTime.now(); setStateDialog(() => currentDate = DateTime(baseDate.year, baseDate.month + months, baseDate.day + days)); }

  void _showManualAddDialog({DateTime? preselectedDate, Map<String, dynamic>? sourceTaskForDuplicate, Offset? originOffset}) {
    showManualAddDialog(
      context: context,
      originOffset: originOffset,
      isDark: isDark,
      scale: _s,
      textColor: textColor,
      textMuted: textMuted,
      glassBorderColor: glassBorderColor,
      doneCardColor: doneCardColor,
      highlightColor: highlightColor,
      currentLang: widget.currentLang,
      selectedMenu: selectedMenu,
      activeTagFilter: activeTagFilter,
      tasks: tasks,
      workspaceMembers: workspaceMembers,
      isDuplicating: _isDuplicating,
      onDuplicateHandled: () => setState(() { _isDuplicating = false; _taskToDuplicate = null; }),
      createTaskManually: _createTaskManually,
      onAiParseText: _sendToAiAssistant,
      onTranscribeVoice: _transcribeVoiceMessage,
      checkBurnoutWarning: _checkBurnoutWarning,
      parseSmartInput: _parseSmartInput,
      getPriorityColor: _getPriorityColor,
      formatDate: _formatDate,
      shiftDate: shiftDate,
      buildGlassContainer: _buildGlassContainer,
      preselectedDate: preselectedDate,
      sourceTaskForDuplicate: sourceTaskForDuplicate,
    );
  }

  void _showEditTaskDialog(Map<String, dynamic> task) {
    showEditTaskDialog(
      context: context,
      task: task,
      isDark: isDark,
      textColor: textColor,
      textMuted: textMuted,
      glassBorderColor: glassBorderColor,
      currentLang: widget.currentLang,
      tasks: tasks,
      workspaceMembers: workspaceMembers,
      updateTaskData: _updateTaskData,
      getPriorityColor: _getPriorityColor,
      formatDate: _formatDate,
      parseDate: _parseDate,
      buildGlassContainer: _buildGlassContainer,
    );
  }

  void _showTaskDetailsDialog(Map<String, dynamic> task) {
    showTaskDetailsDialog(
      context: context,
      task: task,
      isDark: isDark,
      textColor: textColor,
      textMuted: textMuted,
      glassColor: glassColor,
      glassBorderColor: glassBorderColor,
      cardColor: cardColor,
      doneCardColor: doneCardColor,
      highlightColor: highlightColor,
      currentLang: widget.currentLang,
      tasks: tasks,
      workspaceMembers: workspaceMembers,
      getPriorityColor: _getPriorityColor,
      onToggleTask: _toggleTask,
      onDeleteTask: _deleteTask,
      onTagTap: (tag) => setState(() => activeTagFilter = tag),
      onDuplicate: (task) {
        // На мобильном — сразу открываем окно добавления с предзаполненными
        // данными, без промежуточного "нажми на плюсик любого дня" (см. кнопку
        // "Дублировать" в task_details_dialog.dart). Десктоп — как раньше,
        // выбор конкретного дня кликом по его "+".
        if (isClarifyDialogMobile(context)) {
          _showManualAddDialog(sourceTaskForDuplicate: task, preselectedDate: DateTime.now());
        } else {
          setState(() { _taskToDuplicate = task; _isDuplicating = true; });
        }
      },
      onEdit: _showEditTaskDialog,
      buildGlassContainer: _buildGlassContainer,
    );
  }

  void _handlePlusTap(DateTime date, int currentDayTaskCount) {
    if (currentDayTaskCount >= AppConfig.dailyTaskLimit) { ClarifyToast.show(context, "Лимит задач (100) исчерпан!".tr(widget.currentLang), variant: ClarifyToastVariant.danger); return; }
    if (_isDuplicating && _taskToDuplicate != null) { _showManualAddDialog(preselectedDate: date, sourceTaskForDuplicate: _taskToDuplicate); } 
    else { _showManualAddDialog(preselectedDate: date); }
  }

  void _handleTaskTap(Map<String, dynamic> task) { _showTaskDetailsDialog(task); }

  void _handleTaskDropped({required Map<String, dynamic> task, required String targetDateStr, required int currentTargetTaskCount}) async {
    final actionId = 'drop_${task['id']}';
    if (_pendingActionIds.contains(actionId)) return; // Уже переносится — игнорируем повторный дроп

    await _guardedAction(actionId, () async {
      await _fetchTasks();
      _checkBurnoutWarning(targetDateStr);
      // mounted после await: экран мог закрыться, пока шёл _fetchTasks.
      if (currentTargetTaskCount >= AppConfig.dailyTaskLimit) { if (mounted) ClarifyToast.show(context, "Лимит 100 задач!".tr(widget.currentLang), variant: ClarifyToastVariant.danger); return; }
      if (HardwareKeyboard.instance.isControlPressed) {
        int? newTaskId = await _createTaskManually({"_source": "copy", "title": task['title'], "due_date": targetDateStr, "due_time": task['due_time'], "note": task['note'], "priority": task['priority'], "tags": task['tags'], "recurrence": task['recurrence'], "recurrence_interval": task['recurrence_interval'], "parent_id": task['parent_id'], "is_completed": false});
        if (newTaskId != null && task['parent_id'] == null) {
          final subtasksToCopy = tasks.where((t) => t['parent_id'] == task['id']).toList();
          for (var sub in subtasksToCopy) { await _createTaskManually({"_source": "subtask", "title": sub['title'], "parent_id": newTaskId, "is_completed": false}); }
        }
        if (mounted) ClarifyToast.show(context, "Скопировано!".tr(widget.currentLang), variant: ClarifyToastVariant.success);
      } else {
        // Перенос вперёд перетаскиванием на невыполненной задаче тоже считается переносом (см. AppConfig.rescheduleWarningCount) — это самый "невидимый" случай, задачу двигают одним жестом не задумываясь.
        if (task['due_date'] != targetDateStr) {
          int newRescheduleCount = (task['reschedule_count'] as int?) ?? 0;
          if (task['is_completed'] != true && task['due_date'] != null) {
            final oldDate = _parseDate(task['due_date']);
            final newDate = _parseDate(targetDateStr);
            if (oldDate != null && newDate != null && newDate.isAfter(oldDate)) { newRescheduleCount += 1; }
          }
          // await обязателен: _guardedAction держит actionId "занятым" до
          // завершения этого колбэка (см. _guardedAction выше) — раньше здесь
          // не было await, поэтому колбэк резолвился сразу же, не дожидаясь
          // реального обновления+рефетча, и повторный дроп той же задачи
          // почти сразу успевал прочитать ЕЩЁ старое reschedule_count из
          // локального `task` — несколько быстрых переносов подряд считались
          // как один и тот же +1 вместо накопления.
          await _updateTaskData(task['id'], {"title": task['title'], "due_date": targetDateStr, "due_time": task['due_time'], "note": task['note'], "priority": task['priority'], "tags": task['tags'], "recurrence": task['recurrence'], "recurrence_interval": task['recurrence_interval'], "parent_id": task['parent_id'], "is_completed": task['is_completed'] ?? false, "reschedule_count": newRescheduleCount});
        }
      }
    });
  }

Map<String, dynamic> _parseSmartInput(String text) {
    String title = text;
    String? time;
    List<String> tags = [];

    final timeReg = RegExp(r'\b(?:в\s)?([0-1]?[0-9]|2[0-3]):([0-5][0-9])\b', caseSensitive: false);
    final timeMatch = timeReg.firstMatch(title);
    if (timeMatch != null) {
      time = "${timeMatch.group(1)?.padLeft(2, '0')}:${timeMatch.group(2)}";
      title = title.replaceAll(timeMatch.group(0)!, '').trim(); 
    }

    final tagReg = RegExp(r'#([a-zA-Zа-яА-Я0-9_]+)');
    final tagMatches = tagReg.allMatches(title);
    for (var match in tagMatches) {
      tags.add(match.group(1)!);
      title = title.replaceAll(match.group(0)!, '').trim(); 
    }

    title = title.replaceAll(RegExp(r'\s+'), ' ').trim();

    return {
      'title': title,
      'time': time,
      'tags': tags.isNotEmpty ? tags.join(', ') : null
    };
  }

  @override
  Widget build(BuildContext context) {
    // 🚀 ВОТ ОНА - МАТЕМАТИКА АДАПТИВНОСТИ
    final double screenWidth = MediaQuery.of(context).size.width;
    _s = (screenWidth / 1920).clamp(0.4, 1.5); // Защищаем от сжатия в пыль и гигантизма

    // Мобильная/PWA-раскладка — отдельно спроектированная навигация, не десктопный
    // сайдбар, сжатый в узкий экран (см. docs/DESIGN_SYSTEM.md, "один проход стройки").
    if (screenWidth < 700) {
      return MobilePlannerShell(
        currentLang: widget.currentLang,
        userInitial: _userInitial,
        userFullName: _userFullName,
        tasks: tasks,
        workspaces: workspaces,
        workspaceMembers: workspaceMembers,
        formatDate: _formatDate,
        getPriorityColor: _getPriorityColor,
        getSubtaskStats: _getSubtaskStats,
        isOverdue: _isOverdue,
        onToggleTask: _toggleTask,
        onDeleteTask: _deleteTask,
        onTaskTap: _handleTaskTap,
        onQuickUpdateTask: _updateTaskData,
        onReorderSaved: _persistManualOrder,
        onAddTask: ({DateTime? preselectedDate}) => _showManualAddDialog(preselectedDate: preselectedDate),
        createTaskManually: _createTaskManually,
        onAiParseText: _sendToAiAssistant,
        onTranscribeVoice: _transcribeVoiceMessage,
        checkBurnoutWarning: _checkBurnoutWarning,
        onOpenWorkspaceMembers: _fetchWorkspaceMembers,
        onInviteToWorkspace: (wsId) => showInviteMemberDialog(
          context: context,
          workspaceId: wsId,
          isDark: isDark,
          scale: 1.0,
          textColor: textColor,
          textMuted: textMuted,
          glassBorderColor: glassBorderColor,
          currentLang: widget.currentLang,
        ),
        onLeaveOrDeleteWorkspace: _showLeaveOrDeleteWorkspace,
        onShowTeamPulse: (wsId) => showTeamPulseDialog(
          context: context,
          wsId: wsId,
          scale: 1.0,
          currentLang: widget.currentLang,
          textColor: textColor,
          textMuted: textMuted,
          tasks: tasks,
          workspaceMembers: workspaceMembers,
          formatDate: _formatDate,
          buildGlassContainer: _buildGlassContainer,
        ),
        onAddWorkspace: () => showCreateWorkspaceDialog(
          context: context,
          isDark: isDark,
          scale: 1.0,
          textColor: textColor,
          textMuted: textMuted,
          glassBorderColor: glassBorderColor,
          currentLang: widget.currentLang,
          onWorkspaceCreated: _fetchWorkspaces,
        ),
        onOpenAccountSettings: _showAccountSettingsDialog,
        buildStatisticsDashboard: _buildStatisticsDashboardWidget,
        buildTrashPanel: _buildTrashPanelWidget,
        isDark: isDark,
        toggleTheme: widget.toggleTheme,
        changeLang: widget.changeLang,
      );
    }

    return AmbientBackground(
      isDark: isDark,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: WindowBorder(
          color: Colors.transparent,
          width: 0,
          child: Column(
            children: [
              SizedBox(
                height: 32,
                child: WindowTitleBarBox(
                  child: Row(
                    children: [
                      Expanded(child: MoveWindow()),
                      WindowButtons(isDark: isDark)
                    ],
                  )
                )
              ),
              
              // 🚀 БОЛЬШЕ НИКАКОГО FITTEDBOX! РЕНДЕРИМ НАТИВНО И РЕЗКО
              Expanded(
                child: Row(
                  children: [
                    // Левое боковое меню (вынесено в виджет)
                    SidebarMenu(
                      isDark: widget.isDark,
                      scale: _s,
                      currentLang: widget.currentLang,
                      selectedMenu: selectedMenu,
                      menuItems: menuItems,
                      workspaces: workspaces,
                      onSetWorkspaceIcon: _setWorkspaceIcon,
                      onMenuSelected: (menu) => setState(() => selectedMenu = menu),
                      onSearchTap: _showSearchDialog,
                      onAddWorkspace: () => showCreateWorkspaceDialog(
                        context: context,
                        isDark: isDark,
                        scale: _s,
                        textColor: textColor,
                        textMuted: textMuted,
                        glassBorderColor: glassBorderColor,
                        currentLang: widget.currentLang,
                        onWorkspaceCreated: _fetchWorkspaces,
                      ),
                      onWorkspaceSelected: (id, menuKey) {
                        setState(() => selectedMenu = menuKey);
                        _fetchWorkspaceMembers(id);
                      },
                      userAccountBlockCollapsed: _buildUserAccountBlockCollapsed(),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: EdgeInsets.fromLTRB(40 * _s, 40 * _s, 40 * _s, 24 * _s),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                // Заголовок
                                Text(
                                  selectedMenu.startsWith('ws_')
                                    ? workspaces.firstWhere((w) => w['id'].toString() == selectedMenu.substring(3), orElse: () => {'name': 'Команда'})['name']
                                    : selectedMenu.tr(widget.currentLang),
                                  style: TextStyle(fontSize: 32 * _s, fontWeight: FontWeight.w700, letterSpacing: -1.0, color: textColor)
                                ),
                                
                                Row(
                                  children: [
                                    // Аватарки участников команды
                                    if (selectedMenu.startsWith('ws_')) ...[
                                      Builder(
                                        builder: (context) {
                                          int wsId = int.parse(selectedMenu.substring(3));
                                          List<Map<String, dynamic>> members = workspaceMembers[wsId] ?? [];
                                          
                                          return Row(
                                            children: members.map((m) {
                                              String rawName = m['full_name']?.toString().trim() ?? '';
                                              String name = rawName.isNotEmpty ? rawName : 'User';
                                              String initial = name[0].toUpperCase();
                                              
                                              // Статус Дзена
                                              bool isZen = zenStatuses[m['user_id'].toString()] == true;
                                              
                                              // 🚀 РАДАР ВЫГОРАНИЯ: Считаем активные задачи на сегодня
                                              String todayStr = _formatDate(DateTime.now());
                                              int todayTasksCount = tasks.where((t) => 
                                                t['workspace_id'] == wsId && 
                                                t['assigned_to'] == m['user_id'] && 
                                                t['due_date'] == todayStr && 
                                                t['is_completed'] != true &&
                                                t['parent_id'] == null // Считаем только главные задачи
                                              ).length;
                                              
                                              // Цветовая кодировка нагрузки
                                              // Через токены, а не стоковые Colors.*: после перехода на
                                              // тёплую палитру (2026-09-04) чистые red/orange/green
                                              // выглядели вставкой из другого приложения.
                                              Color heatColor = todayTasksCount >= 10
                                                  ? _tokens.danger
                                                  : (todayTasksCount >= 5 ? _tokens.warning : _tokens.success);
                                              
                                              return Padding(
                                                padding: EdgeInsets.only(right: 8 * _s),
                                                child: GestureDetector(
                                                  onTap: () => showUserProfileModal(
                                                    context: context,
                                                    userId: m['user_id'].toString(),
                                                    currentLang: widget.currentLang,
                                                    teamRole: m['role']?.toString(),
                                                    onOpenOwnSettings: _showAccountSettingsDialog,
                                                    onOpenConversation: (userId, name) => setState(() {
                                                      _pendingChatPartnerId = userId;
                                                      _pendingChatPartnerName = name;
                                                      selectedMenu = 'Сообщения';
                                                    }),
                                                  ),
                                                  child: Tooltip(
                                                  // Обновляем подсказку при наведении
                                                  message: isZen ? "$name (В глубоком фокусе 🧘‍♂️)" : "$name (${m['role']})\n🔥 Задач на сегодня: $todayTasksCount",
                                                  child: Opacity(
                                                    opacity: isZen ? 0.4 : 1.0, 
                                                    child: Stack(
                                                      clipBehavior: Clip.none, // Позволяем бейджику вылезать за края
                                                      alignment: Alignment.center,
                                                      children: [
                                                        CircleAvatar(
                                                          radius: 18 * _s,
                                                          // Палитра меток проекта вместо радуги Colors.primaries:
                                                          // стоковые primaries — чистые синий/розовый/бирюзовый,
                                                          // после перехода на тёплую базу они кричали сильнее
                                                          // всего остального интерфейса.
                                                          backgroundColor: isZen
                                                              ? _tokens.text3
                                                              : _tokens.tagPalette[members.indexOf(m) % _tokens.tagPalette.length],
                                                          child: Text(initial, style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14 * _s)),
                                                        ),
                                                        if (isZen)
                                                          Icon(LucideIcons.flower, color: Colors.white.withValues(alpha: 0.9), size: 20 * _s),
                                                          
                                                        // 🚀 РИСУЕМ БЕЙДЖИК НАГРУЗКИ
                                                        if (!isZen && todayTasksCount > 0)
                                                          Positioned(
                                                            bottom: -2,
                                                            right: -2,
                                                            child: Container(
                                                              padding: EdgeInsets.all(5 * _s),
                                                              decoration: BoxDecoration(
                                                                color: heatColor,
                                                                shape: BoxShape.circle,
                                                                border: Border.all(color: isDark ? const Color(0xFF1E1E1E) : Colors.white, width: 2)
                                                              ),
                                                              child: Text(
                                                                todayTasksCount.toString(),
                                                                style: TextStyle(color: Colors.white, fontSize: 10 * _s, fontWeight: FontWeight.bold)
                                                              )
                                                            )
                                                          )
                                                      ],
                                                    ),
                                                  ),
                                                  ),
                                                ),
                                              );
                                            }).toList(),
                                          );
                                        }
                                      ),
                                      SizedBox(width: 8 * _s),
                                      
                                      // Кнопка "Пригласить"
                                      Padding(
                                        padding: EdgeInsets.only(right: 16 * _s),
                                        child: ClarifyButton(
                                          variant: ClarifyButtonVariant.outline,
                                          scale: _s,
                                          icon: LucideIcons.userPlus,
                                          label: "Пригласить".tr(widget.currentLang),
                                          onPressed: () => showInviteMemberDialog(
                                            context: context,
                                            workspaceId: int.parse(selectedMenu.substring(3)),
                                            isDark: isDark,
                                            scale: _s,
                                            textColor: textColor,
                                            textMuted: textMuted,
                                            glassBorderColor: glassBorderColor,
                                            currentLang: widget.currentLang,
                                          ),
                                        ),
                                      ),
                                      Padding(
                                        padding: EdgeInsets.only(right: 16 * _s),
                                        child: ClarifyIconButton(
                                          icon: LucideIcons.logOut,
                                          scale: _s,
                                          tooltip: "Покинуть/удалить команду".tr(widget.currentLang),
                                          onPressed: () => _showLeaveOrDeleteWorkspace(int.parse(selectedMenu.substring(3))),
                                        ),
                                      ),
                                    ],

                                    // Вышло обновление. Значком в шапке, а не
                                    // модальным окном: обновление — это
                                    // предложение, а не событие, ради которого
                                    // человека надо прерывать. Кроме случая,
                                    // когда старая версия работать уже не может
                                    // — тогда значок красный.
                                    if (_availableUpdate != null)
                                      Padding(
                                        padding: EdgeInsets.only(right: 12 * _s),
                                        child: Tooltip(
                                          message: _availableUpdate!.required
                                              ? '${'Требуется обновление до версии'.tr(widget.currentLang)} ${_availableUpdate!.version}'
                                              : '${'Доступна версия'.tr(widget.currentLang)} ${_availableUpdate!.version}',
                                          child: ClarifyPressable(
                                            onTap: _openUpdateUrl,
                                            child: Icon(
                                              LucideIcons.download,
                                              color: _availableUpdate!.required ? _tokens.danger : _tokens.accent,
                                              size: 24 * _s,
                                            ),
                                          ),
                                        ),
                                      ),

                                    if (_isOffline)
                                      Padding(
                                        padding: EdgeInsets.only(right: 12 * _s),
                                        child: Icon(LucideIcons.cloudOff, color: _tokens.warning, size: 24 * _s),
                                      ),

                                    if (_pendingOpsCount > 0)
                                      Padding(
                                        padding: EdgeInsets.only(right: 12 * _s),
                                        child: Tooltip(
                                          message: "${'Несинхронизированных изменений: '.tr(widget.currentLang)}$_pendingOpsCount",
                                          child: Icon(LucideIcons.cloudAlert, color: _tokens.warning, size: 24 * _s),
                                        ),
                                      ),


                                    // Фокус-режим — filled только пока активен, один и тот же акцент, что и везде
                                    ClarifyButton(
                                      variant: _isMyZenActive ? ClarifyButtonVariant.filled : ClarifyButtonVariant.outline,
                                      scale: _s,
                                      icon: LucideIcons.flower,
                                      label: _isMyZenActive ? "В фокусе".tr(widget.currentLang) : "Фокусирование".tr(widget.currentLang),
                                      onPressed: _toggleZenMode,
                                    ),
                                    SizedBox(width: 12 * _s),
                                    // Пульс команды (только внутри воркспейса) — нейтральная иконка, не тревожный красный
                                    if (Features.social && selectedMenu.startsWith('ws_')) ...[
                                      ClarifyIconButton(
                                        icon: LucideIcons.heartPulse,
                                        scale: _s,
                                        tooltip: "Пульс команды".tr(widget.currentLang),
                                        onPressed: () => showTeamPulseDialog(
                                          context: context,
                                          wsId: int.parse(selectedMenu.substring(3)),
                                          scale: _s,
                                          currentLang: widget.currentLang,
                                          textColor: textColor,
                                          textMuted: textMuted,
                                          tasks: tasks,
                                          workspaceMembers: workspaceMembers,
                                          formatDate: _formatDate,
                                          buildGlassContainer: _buildGlassContainer,
                                        ),
                                      ),
                                      SizedBox(width: 4 * _s),
                                    ],
                                    ClarifyIconButton(icon: LucideIcons.refreshCw, scale: _s, onPressed: _fetchTasks),
                                    SizedBox(width: 4 * _s),
                                    ClarifyIconButton(
                                      icon: isDark ? LucideIcons.sun : LucideIcons.moon,
                                      scale: _s,
                                      onPressed: widget.toggleTheme,
                                    ),
                                    SizedBox(width: 16 * _s),
                                    ClarifyButton(
                                      variant: rightPanelState == 'ai' ? ClarifyButtonVariant.outline : ClarifyButtonVariant.filled,
                                      scale: _s,
                                      icon: rightPanelState == 'ai' ? LucideIcons.x : LucideIcons.sparkles,
                                      label: rightPanelState == 'ai' ? "Закрыть чат".tr(widget.currentLang) : "AI Ассистент".tr(widget.currentLang),
                                      onPressed: () => setState(() => rightPanelState = rightPanelState == 'ai' ? 'none' : 'ai'),
                                    ),
                                  ],
                                )
                              ],
                            ),
                          ),
                          if (activeTagFilter != null || activePriorityFilter != null)
                            Padding(
                              padding: EdgeInsets.fromLTRB(40 * _s, 0, 40 * _s, 24 * _s),
                              child: Row(
                                children: [
                                  if (activeTagFilter != null) ...[
                                    Container(
                                      padding: EdgeInsets.symmetric(horizontal: 16 * _s, vertical: 8 * _s), decoration: BoxDecoration(color: highlightColor, borderRadius: BorderRadius.circular(ClarifyRadius.pill), border: Border.all(color: _tokens.accent.withValues(alpha: 0.4))),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(LucideIcons.funnel, size: 18 * _s, color: _tokens.accent), SizedBox(width: 8 * _s),
                                          Text("${'Тег: '.tr(widget.currentLang)}#$activeTagFilter", style: TextStyle(color: _tokens.accent, fontWeight: FontWeight.bold, fontSize: 15 * _s)), SizedBox(width: 12 * _s),
                                          InkWell(onTap: () => setState(() => activeTagFilter = null), child: Container(padding: EdgeInsets.all(4 * _s), decoration: BoxDecoration(shape: BoxShape.circle, color: _tokens.accent.withValues(alpha: 0.6)), child: Icon(LucideIcons.x, size: 14 * _s, color: _tokens.onAccent),))
                                        ],
                                      )
                                    ),
                                    SizedBox(width: 12 * _s),
                                  ],
                                  if (activePriorityFilter != null)
                                    Container(
                                      padding: EdgeInsets.symmetric(horizontal: 16 * _s, vertical: 8 * _s), decoration: BoxDecoration(color: highlightColor, borderRadius: BorderRadius.circular(ClarifyRadius.pill), border: Border.all(color: _getPriorityColor(activePriorityFilter).withValues(alpha: 0.4))),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(LucideIcons.flag, size: 18 * _s, color: _getPriorityColor(activePriorityFilter)), SizedBox(width: 8 * _s),
                                          Text("${'Приоритет: '.tr(widget.currentLang)}${priorityFlagLabel(activePriorityFilter)}", style: TextStyle(color: _getPriorityColor(activePriorityFilter), fontWeight: FontWeight.bold, fontSize: 15 * _s)), SizedBox(width: 12 * _s),
                                          InkWell(onTap: () => setState(() => activePriorityFilter = null), child: Container(padding: EdgeInsets.all(4 * _s), decoration: BoxDecoration(shape: BoxShape.circle, color: _getPriorityColor(activePriorityFilter).withValues(alpha: 0.6)), child: Icon(LucideIcons.x, size: 14 * _s, color: _tokens.onAccent),))
                                        ],
                                      )
                                    ),
                                ],
                              )
                            ),
                          // Переходим к главному контенту (Через вынесенный виджет).
                          // SharedAxisTransition при смене пункта сайдбара — сдержанный
                          // переход вместо мгновенной смены (REDESIGN_V3_PLAN.md §3.6/5.6).
                          Expanded(
                            child: PageTransitionSwitcher(
                              duration: ClarifyMotion.slow,
                              // Дефолтный layoutBuilder пакета animations кладёт
                              // страницы в Stack(alignment: Alignment.center) —
                              // контент короче доступной высоты (как в
                              // "Статистике", в отличие от списков, которые
                              // всегда заполняют Expanded целиком) оказывался
                              // отцентрирован по вертикали, а не прижат к верху:
                              // отсюда "начинается не с самого верха". fit:expand
                              // заставляет каждую страницу занимать ровно всю
                              // высоту Expanded, alignment: topLeft — на случай,
                              // если что-то всё же не растянется на всю высоту.
                              layoutBuilder: (entries) => Stack(alignment: Alignment.topLeft, fit: StackFit.expand, children: entries),
                              transitionBuilder: (child, primaryAnimation, secondaryAnimation) => SharedAxisTransition(
                                animation: primaryAnimation,
                                secondaryAnimation: secondaryAnimation,
                                transitionType: SharedAxisTransitionType.horizontal,
                                child: child,
                              ),
                              child: KeyedSubtree(
                                key: ValueKey(selectedMenu),
                                child: Builder(builder: (context) {
                              final taskCardBuilders = TaskCardBuilders(
                                isDark: widget.isDark,
                                scale: _s,
                                compact: AppSettings.compactDensity.value,
                                currentLang: widget.currentLang,
                                workspaceMembers: workspaceMembers,
                                getPriorityColor: _getPriorityColor,
                                getSubtaskStats: _getSubtaskStats,
                                isOverdue: _isOverdue,
                                onToggle: _toggleTask,
                                onDelete: _deleteTask,
                                onTap: _handleTaskTap,
                                onTagTap: (tag) => setState(() => activeTagFilter = tag),
                                onPriorityTap: (priority) => setState(() => activePriorityFilter = priority),
                                onQuickUpdateTask: _updateTaskData,
                                buildGlassContainer: _buildGlassContainer,
                              );
                              return MainContentArea(
                              selectedMenu: selectedMenu,
                              currentLang: widget.currentLang,
                              filteredTasks: filteredTasks,
                              isDark: widget.isDark,
                              scale: _s,
                              onMenuSelected: (menu) => setState(() => selectedMenu = menu),
                              projectIconKeys: _readProjectIconKeys(),
                              onSetProjectIcon: _setProjectIcon,
                              projectColorKeys: _readProjectColorKeys(),
                              onSetProjectColor: _setProjectColor,
                              frozenCompletedRanks: _frozenCompletedRanks,
                              pendingChatPartnerId: _pendingChatPartnerId,
                              pendingChatPartnerName: _pendingChatPartnerName,
                              onOpenDirectChat: (partnerId, name) => setState(() {
                                _pendingChatPartnerId = partnerId;
                                _pendingChatPartnerName = name;
                                selectedMenu = 'Сообщения';
                              }),
                              currentCalendarDate: _currentCalendarDate,
                              onCalendarDateChanged: (newDate) {
                                setState(() {
                                  _currentCalendarDate = newDate;
                                });
                              },
                              // newIndex приходит из onReorderItem уже
                              // пересчитанным под вынутый элемент — своя
                              // поправка `if (newIndex > oldIndex) newIndex -= 1`
                              // стала бы второй по счёту и роняла бы задачу на
                              // позицию выше той, куда её отпустили.
                              onReorderTasks: (oldIndex, newIndex, targetTasks) {
                                setState(() {
                                  final item = targetTasks.removeAt(oldIndex);
                                  targetTasks.insert(newIndex, item);
                                });
                                _persistManualOrder(targetTasks);
                              },
                              // Быстрое добавление строкой (C1). Разбор уже
                              // сделан локально в ClarifyQuickAdd — здесь
                              // только сохранение.
                              // Силуэты вместо «Задач пока нет», пока идёт
                              // первая загрузка и показывать ещё нечего.
                              loading: _initialLoadPending && tasks.isEmpty,
                              onQuickCreate: (parsed) async {
                                await _createTaskManually({
                                  "_source": "quick",
                                  "title": parsed.title,
                                  "due_date": parsed.date == null ? null : _formatDate(parsed.date!),
                                  "due_time": parsed.time,
                                  "priority": parsed.priority ?? 'none',
                                  "tags": parsed.tag,
                                  "recurrence": null,
                                  "is_completed": false,
                                  "parent_id": null,
                                });
                              },
                              onTaskDropped: (task, targetDateStr, currentTargetTaskCount) {
                                _handleTaskDropped(task: task, targetDateStr: targetDateStr, currentTargetTaskCount: currentTargetTaskCount);
                              },
                              onPlusTap: (targetDate, currentTaskCount) {
                                _handlePlusTap(targetDate, currentTaskCount);
                              },
                              buildListTaskCard: taskCardBuilders.buildListTaskCard,
                              buildBoardTaskCardExpanded: taskCardBuilders.buildBoardTaskCardExpanded,
                              buildCalendarTaskCard: taskCardBuilders.buildCalendarTaskCard,
                              buildCalendarTaskChip: taskCardBuilders.buildCalendarTaskChip,
                              buildGlassContainer: _buildGlassContainer,
                              getLocalKanbanStatus: _getLocalKanbanStatus,
                              onSetLocalKanbanStatus: _setLocalKanbanStatus,
                              buildStatisticsDashboard: () => StatisticsDashboard(
                                tasks: tasks,
                                totalInBase: _totalTasksInBase,
                                workspaces: workspaces,
                                currentLang: widget.currentLang,
                                textColor: textColor,
                                textMuted: textMuted,
                                isOverdue: _isOverdue,
                                parseDate: _parseDate,
                                getPriorityColor: _getPriorityColor,
                                buildGlassContainer: _buildGlassContainer,
                              ),
                              // Тот же сгруппированный экран настроек, что и на мобильной
                              // версии (MobileSettingsScreen) — по прямому запросу
                              // пользователя "должно полностью совпадать с мобильной
                              // версией" (2026-08-01): плоское содержимое
                              // AccountSettingsPanel сюда не подходило, набор разделов
                              // и группировка там другие.
                              // Корзина (C6) — содержимое грузится отдельным
                              // запросом при открытии раздела, в общий кэш
                              // задач удалённое не попадает.
                              buildTrashPanel: _buildTrashPanelWidget,
                              buildArchivePanel: _buildArchivePanelWidget,
                              buildSettingsPanel: () {
                                final user = Supabase.instance.client.auth.currentUser;
                                final metadata = user?.userMetadata ?? {};
                                final fullName = metadata['full_name']?.toString() ?? '';
                                final initial = fullName.isNotEmpty ? fullName[0].toUpperCase() : '?';
                                return MobileSettingsScreen(
                                  currentLang: widget.currentLang,
                                  userInitial: initial,
                                  userFullName: fullName,
                                  isDark: isDark,
                                  onOpenAccountSettings: _openProfilePageFromSettingsTab,
                                  onOpenStatistics: () => setState(() => selectedMenu = 'Статистика'),
                                  onOpenFriends: () => setState(() => selectedMenu = 'Друзья'),
                                  onOpenMessages: () => setState(() => selectedMenu = 'Сообщения'),
                                  onOpenTrash: () => setState(() => selectedMenu = 'Корзина'),
                                  onOpenAbout: () => setState(() => selectedMenu = 'О приложении'),
                                  toggleTheme: widget.toggleTheme,
                                  changeLang: widget.changeLang,
                                  embedded: true,
                                );
                              },
                              );
                            }),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    ClipRect(
                      child: AnimatedContainer(
                        duration: ClarifyMotion.slow, curve: ClarifyMotion.spring, width: rightPanelState != 'none' ? 360 * _s : 0,
                        child: OverflowBox(
                          alignment: Alignment.centerRight,
                          minWidth: 360 * _s, maxWidth: 360 * _s,
                          child: AnimatedOpacity(
                            duration: ClarifyMotion.base, curve: ClarifyMotion.standard,
                            opacity: rightPanelState != 'none' ? 1 : 0,
                            child: _buildGlassContainer(
                              borderRadius: const BorderRadius.only(topLeft: Radius.circular(24), bottomLeft: Radius.circular(24)),
                              margin: EdgeInsets.zero,
                              child: rightPanelState == 'ai' ? AiChatPanel(
                                currentLang: widget.currentLang,
                                textColor: textColor,
                                textMuted: textMuted,
                                glassBorderColor: glassBorderColor,
                                chatBubbleAi: chatBubbleAi,
                                chatInput: chatInput,
                                chatMessages: chatMessages,
                                showOnboardingTip: _showAiOnboardingTip,
                                isAiTyping: isAiTyping,
                                controller: _aiChatController,
                                onVoiceRecorded: _sendVoiceMessageToAI,
                                onSend: _sendTaskToAI,
                              ) : const SizedBox.shrink()
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        // "Создать задачу" не имеет смысла в разделах без списка задач —
        // мешает вводить сообщения (Мессенджер) и смотреть контент
        // (Статистика/Друзья), см. фидбек пользователя 2026-08-01.
        floatingActionButton: {'Сообщения', 'Статистика', 'Друзья'}.contains(selectedMenu)
            ? null
            : Padding(
                padding: EdgeInsets.only(right: rightPanelState != 'none' ? 360.0 * _s : 0.0, bottom: 24.0 * _s),
                // Container transform через Hero откачен — "A Hero widget cannot be the
                // descendant of another Hero widget" при реальном запуске (не смог
                // безопасно продиагностировать вслепую без браузера/живой отладки).
                // Тот же эффект "окно вылетает из кнопки" сделан через
                // showClarifySurface() — точка клика ловится глобально
                // (LastTapTracker, main.dart), отдельно координаты FAB не нужны.
                child: FloatingActionButton.extended(
                  onPressed: () { if (_isDuplicating && _taskToDuplicate != null) { _showManualAddDialog(preselectedDate: DateTime.now(), sourceTaskForDuplicate: _taskToDuplicate); } else { _showManualAddDialog(); } },
                  // Тот же акцент, что у кнопки "AI Ассистент" (ClarifyButtonVariant.filled)
                  // — раньше FAB был захардкожен на стоковый Colors.blueAccent, из-за чего
                  // две акцентные кнопки в интерфейсе визуально спорили друг с другом.
                  backgroundColor: _tokens.accent, foregroundColor: _tokens.onAccent, elevation: 8, icon: Icon(LucideIcons.plus, size: 26 * _s), label: Text("Создать задачу".tr(widget.currentLang), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16 * _s)),
                ),
              ),
      ),
    );
  }

  void _showLeaveOrDeleteWorkspace(int wsId) {
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    final ws = workspaces.firstWhere((w) => w['id'] == wsId, orElse: () => {});
    final isOwner = ws['owner_id'] == currentUserId;
    final members = workspaceMembers[wsId] ?? [];
    final myMember = members.firstWhere((m) => m['user_id'] == currentUserId, orElse: () => {});
    final isAdmin = myMember['role'] == 'admin';

    showLeaveOrDeleteWorkspaceDialog(
      context: context,
      workspaceId: wsId,
      canDelete: isOwner || isAdmin,
      textColor: textColor,
      textMuted: textMuted,
      currentLang: widget.currentLang,
      onDone: () async {
        setState(() => selectedMenu = 'Мой день');
        await _fetchWorkspaces();
      },
    );
  }

  void _showAccountSettingsDialog() {
    showAccountSettingsDialog(
      context: context,
      isDark: isDark,
      textColor: textColor,
      textMuted: textMuted,
      glassColor: glassColor,
      glassBorderColor: glassBorderColor,
      highlightColor: highlightColor,
      currentLang: widget.currentLang,
      changeLang: widget.changeLang,
      onProfileChanged: () => setState(() {}),
      isMobileContext: MediaQuery.of(context).size.width < ClarifyBreakpoints.mobile,
      buildGlassContainer: _buildGlassContainer,
    );
  }

  // "Профиль" из строки-шапки вкладки "Настройки" (MobileSettingsScreen) —
  // ВСЕГДА полноэкранная страница, как на мобильной версии (см. скриншот
  // пользователя 2026-08-01), а не диалог-попап: в отличие от
  // _showAccountSettingsDialog выше (аватар на рейле, командная палитра),
  // здесь режим не должен зависеть от ширины окна — сама вкладка "Настройки"
  // уже целиком воспроизводит мобильный экран настроек, значит и переход из
  // неё в профиль обязан вести себя так же.
  void _openProfilePageFromSettingsTab() {
    showAccountSettingsDialog(
      context: context,
      isDark: isDark,
      textColor: textColor,
      textMuted: textMuted,
      glassColor: glassColor,
      glassBorderColor: glassBorderColor,
      highlightColor: highlightColor,
      currentLang: widget.currentLang,
      changeLang: widget.changeLang,
      onProfileChanged: () => setState(() {}),
      isMobileContext: true,
      buildGlassContainer: _buildGlassContainer,
    );
  }

  // Выполненная задача не просрочена по определению — этим _isOverdue и
  // отличается от taskWasPastDue, который отвечает на вопрос «дедлайн уже
  // прошёл» независимо от отметки (нужно для резервирования места под значок).
  bool _isOverdue(Map<String, dynamic> task) {
    if (task['is_completed'] == true) return false;
    return taskWasPastDue(task);
  }

  /// Момент дедлайна задачи. Без времени — конец дня.
  ///
  /// Общая реализация в core/clarify_date_format.dart: она же читает настоящие
  /// колонки дат (B4) и используется всеми четырьмя местами, где это раньше
  /// было скопировано.
  DateTime? _taskDeadline(Map<String, dynamic> task) => taskDeadline(task);
}
