import 'dart:convert';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../core/config.dart';
import '../core/log.dart';
import 'task_cache.dart';

class TaskService {
  final Box _tasksBox = Hive.box('tasks_cache');
  late final TaskCache _cache = TaskCache(_tasksBox);
  final Box _pendingOpsBox = Hive.box('pending_ops');
  RealtimeChannel? _realtimeChannel;

  // --- ЗАМЕНИТЬ НАЧАЛО КЛАССА И ФУНКЦИИ ДО updateTask ВКЛЮЧИТЕЛЬНО ---

  // Операции (create/update/delete), которые не удалось отправить на сервер
  // из-за сети — переживают перезапуск приложения (хранятся в Hive) и
  // досылаются автоматически при следующем успешном сетевом запросе.
  late List<Map<String, dynamic>> _pendingOps = _loadPendingOps();

  List<Map<String, dynamic>> _loadPendingOps() {
    final raw = _pendingOpsBox.get('ops');
    if (raw == null) return [];
    return List<Map<String, dynamic>>.from(json.decode(raw));
  }

  void _savePendingOps() {
    _pendingOpsBox.put('ops', json.encode(_pendingOps));
  }

  bool get hasPendingOps => _pendingOps.isNotEmpty;
  int get pendingOpsCount => _pendingOps.length;

  void _queuePendingOp(String type, Map<String, dynamic> payload) {
    _pendingOps.add({'type': type, 'payload': payload});
    _savePendingOps();
  }

  /// Пытается досослать все отложенные операции. Вызывается в начале
  /// [fetchTasks] — успешный сетевой запрос сам по себе доказывает, что
  /// сеть снова доступна, отдельный слушатель подключения не нужен.
  Future<void> flushPendingOps() async {
    if (_pendingOps.isEmpty) return;

    final remaining = <Map<String, dynamic>>[];
    for (final op in _pendingOps) {
      try {
        final type = op['type'] as String;
        final payload = Map<String, dynamic>.from(op['payload'] as Map);
        if (type == 'update') {
          await Supabase.instance.client
              .from('tasks')
              .update(Map<String, dynamic>.from(payload['data'] as Map))
              .eq('id', payload['taskId']);
        } else if (type == 'delete') {
          await Supabase.instance.client.from('tasks').delete().eq('id', payload['taskId']);
        } else if (type == 'create') {
          await Supabase.instance.client.from('tasks').insert(Map<String, dynamic>.from(payload['data'] as Map));
        }
      } catch (e) {
        remaining.add(op); // сеть всё ещё недоступна — оставляем в очереди
      }
    }
    _pendingOps = remaining;
    _savePendingOps();
  }

  // --- ЗАМЕНИ ЭТУ ФУНКЦИЮ ---
  // 1. Получение локального кэша (теперь с генерацией новой ссылки!)
  List<Map<String, dynamic>> getCachedTasks() {
    return _cache.loadFromDiskIfEmpty();
  }
  // --- КОНЕЦ ЗАМЕНЫ ---

  // 2. Загрузка данных из Supabase
  Future<List<Map<String, dynamic>>> fetchTasks() async {
    await flushPendingOps();

    // order('id') — не косметика: без него PostgREST отдаёт строки в порядке
    // физического расположения в таблице, а он меняется после каждого UPDATE
    // (обновлённая строка переезжает в конец heap). Из-за этого список задач
    // после отметки "выполнено" приходил в другом порядке, и задачи, у которых
    // ключи сортировки на клиенте совпадают, визуально прыгали по списку.
    //
    // Окно загрузки (B3): раньше здесь был select() без единого ограничения —
    // тянулись все задачи за всю историю, при каждом запуске И при каждом
    // realtime-событии. Теперь грузим то, что реально нужно на экранах:
    //   * всё невыполненное — независимо от возраста;
    //   * выполненное за последний год (окно — AppConfig.completedTasksWindowDays);
    //   * все подзадачи — иначе у активной задачи «0/2» превратилось бы в «0/1»,
    //     когда выполненная подзадача выпала из окна по возрасту;
    //   * выполненное БЕЗ даты отметки — таких задач в базе 2, они старше
    //     колонки completed_at. Когда неизвестно, когда задачу закрыли, честнее
    //     оставить её, чем выбросить: NULL в SQL не равен ничему, и без этой
    //     ветки они не попали бы ни под одно условие и просто исчезли бы.
    // is_completed сравнивается ещё и с null: колонка nullable, и у задач,
    // созданных до появления значения по умолчанию, там NULL — без этой ветки
    // они бы тоже пропали.
    // Та же граница, что у истории (fetchArchive) — иначе между окном и
    // историей появилась бы дыра из задач, невидимых нигде, либо перекрытие.
    final cutoff = archiveCutoff().toIso8601String();
    final data = await Supabase.instance.client
        .from('tasks')
        .select()
        // Корзина (C6): удалённое не показывается нигде, кроме самой корзины.
        // Фильтр стоит здесь, в единственной точке загрузки списка, — тогда его
        // не нужно повторять в каждом разделе и невозможно забыть в новом.
        .isFilter('deleted_at', null)
        .or('is_completed.is.null,'
            'is_completed.eq.false,'
            'completed_at.is.null,'
            'completed_at.gte.$cutoff,'
            'parent_id.not.is.null')
        .order('id')
        .timeout(const Duration(seconds: 15));

    _cache.replaceAll(List<Map<String, dynamic>>.from(data));
    return _cache.tasks;
  }

  // 3. Подписка на сокеты (Realtime)
  //
  // Раньше подписка на tasks шла по ВСЕЙ таблице без фильтра: сервер на каждое
  // изменение проверял права для каждого подписчика, а клиент в ответ
  // перечитывал свои задачи целиком. Пока пользователей десяток — незаметно, на
  // сотне активных это постоянный шквал лишней работы у всех сразу.
  //
  // Теперь два адресных фильтра вместо одного всеохватного:
  //   * свои задачи — по user_id;
  //   * командные — по workspace_id из списка команд пользователя (одной
  //     подпиской через in-фильтр, а не по подписке на команду).
  // Фильтр по user_id один не годится: у командной задачи владелец — тот, кто
  // её создал, и правки коллег до нас бы не долетали.
  //
  // Список команд известен не сразу (грузится после старта), поэтому метод
  // рассчитан на повторный вызов: старый канал закрывается, открывается новый.
  // Повторная подписка с тем же набором команд пропускается — незачем рвать
  // рабочее соединение на каждый перерисованный экран.
  List<int>? _subscribedWorkspaceIds;

  void initRealtime({
    required void Function(PostgresChangePayload payload) onTaskEvent,
    required Function onZenChanged,
    List<int> workspaceIds = const [],
  }) {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;

    final sorted = [...workspaceIds]..sort();
    if (_realtimeChannel != null &&
        _subscribedWorkspaceIds != null &&
        _sameIds(_subscribedWorkspaceIds!, sorted)) {
      return;
    }

    _realtimeChannel?.unsubscribe();

    final channel = Supabase.instance.client.channel('clarify_changes');

    channel.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'tasks',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'user_id',
        value: user.id,
      ),
      callback: onTaskEvent,
    );

    if (sorted.isNotEmpty) {
      channel.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'tasks',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.inFilter,
          column: 'workspace_id',
          value: sorted,
        ),
        callback: onTaskEvent,
      );
    }

    // user_status фильтром не сужаем СОЗНАТЕЛЬНО: экран показывает статусы
    // коллег, а не только свой. Кого именно видно, решает RLS на таблице
    // (sql/rls_visibility.sql) — до неё сюда прилетали статусы вообще всех
    // пользователей сервиса.
    channel.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'user_status',
      callback: (payload) => onZenChanged(),
    );

    channel.subscribe();
    _realtimeChannel = channel;
    _subscribedWorkspaceIds = sorted;
  }

  bool _sameIds(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void dispose() {
    _realtimeChannel?.unsubscribe();
    _realtimeChannel = null;
    _subscribedWorkspaceIds = null;
  }
  
  // 5. Создание задачи (Мгновенный Optimistic UI + Фикс типов для календаря)
  Future<int?> addTask(Map<String, dynamic> taskData) async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return null;

    taskData['user_id'] = user.id;

    // Генерируем временный ID
    final tempId = -DateTime.now().millisecondsSinceEpoch;
    
    // Создаем полностью валидный объект задачи со всеми дефолтными полями,
    // чтобы календарь и фильтры 7 дней не падали из-за null-полей
    final optimisticTask = {
      'id': tempId,
      'title': taskData['title'] ?? '',
      'due_date': taskData['due_date'], // Жестко сохраняем дату для календаря!
      'due_time': taskData['due_time'],
      'note': taskData['note'],
      'priority': taskData['priority'] ?? 'none',
      'tags': taskData['tags'],
      'recurrence': taskData['recurrence'],
      'recurrence_interval': taskData['recurrence_interval'],
      'recurrence_from_completion': taskData['recurrence_from_completion'] ?? false,
      'is_completed': taskData['is_completed'] ?? false,
      'parent_id': taskData['parent_id'],
      'folder': taskData['folder'],
      'workspace_id': taskData['workspace_id'],
      'assigned_to': taskData['assigned_to'],
      'user_id': user.id,
    };

    // Мгновенно показываем задачу и сохраняем на диск — см. TaskCache.
    _cache.addOptimistic(optimisticTask);

    // Фоновая отправка на сервер Supabase
    try {
      final response = await Supabase.instance.client
          .from('tasks')
          .insert(taskData)
          .select()
          .single();

      final realId = response['id'] as int;
      
      // Заменяем временную задачу на официальную серверную.
      _cache.confirmOptimistic(tempId, Map<String, dynamic>.from(response));

      return realId;
    } on PostgrestException {
      // Сервер ответил и отклонил запрос (RLS/валидация/etc.) — это не
      // сетевая проблема, повторная отправка того же payload даст тот же
      // отказ. В очередь не кладём, даём вызывающему коду показать
      // настоящую причину вместо "нет сети".
      //
      // И обязательно убираем оптимистичную запись. Раньше она оставалась
      // висеть в памяти и в Hive: пользователь видел созданную задачу, закрывал
      // приложение, открывал — задачи нет, без единого объяснения. Честная
      // ошибка сразу подрывает доверие куда меньше, чем задача-призрак.
      _cache.removeOptimistic(tempId);
      rethrow;
    } catch (e) {
      logError("Фоновое сохранение на сервер не удалось: $e");
      // Задача уже показана пользователю (optimistic UI) — без очереди она
      // бы бесследно исчезла при следующем успешном fetchTasks(), который
      // полностью перезаписывает _inMemoryTasks данными с сервера.
      _queuePendingOp('create', {'data': taskData});
      rethrow; // вызывающий код (тост "не удалось сохранить") не меняем
    }
  }

  // --- КОНЕЦ ИЗМЕНЕНИЙ В СЕРВИСЕ ---
  // --- КОНЕЦ ЗАМЕНЫ ---

  // 6. Обновление задачи
  Future<void> updateTask(int taskId, Map<String, dynamic> updates) async {
    try {
      await Supabase.instance.client.from('tasks').update(updates).eq('id', taskId);
    } on PostgrestException {
      // Сервер ответил отказом (RLS/валидация/etc.) — не сетевая проблема,
      // ретрай с тем же payload даст тот же результат, в очередь не кладём.
      rethrow;
    } catch (e) {
      _queuePendingOp('update', {'taskId': taskId, 'data': updates});
      rethrow; // вызывающий код (например, откат чекбокса) не меняем
    }
  }

  /// Сохраняет порядок, который человек выставил перетаскиванием.
  ///
  /// До 09.09.2026 перетаскивание меняло только список в памяти экрана:
  /// колонка `order_index` в базе была у всех задач нулевой, и порядок
  /// возвращался к прежнему при первом же обновлении списка. Снаружи это
  /// выглядело как работающая функция — до перезапуска.
  ///
  /// Нумеруем с шагом 1000, а не подряд: между соседями остаётся место, и
  /// следующая вставка чаще всего трогает одну строку вместо всего списка.
  ///
  /// Пишем только те задачи, у которых значение реально изменилось: после
  /// перетаскивания одной строки таких обычно две-три, а не весь экран.
  /// Обновления идут по одному — Supabase не даёт обновить разные строки
  /// разными значениями одним запросом, а батч через upsert потребовал бы
  /// слать все остальные колонки и рисковать затереть чужие правки.
  Future<void> saveManualOrder(List<Map<String, dynamic>> orderedTasks) async {
    final changed = <int, int>{};
    for (var i = 0; i < orderedTasks.length; i++) {
      final task = orderedTasks[i];
      final id = task['id'];
      if (id is! int) continue;
      final next = i * 1000;
      if ((task['order_index'] as int?) == next) continue;
      // Локальную копию правим сразу: список на экране уже перестроен, и до
      // ответа сервера сортировка должна опираться на новые значения.
      task['order_index'] = next;
      changed[id] = next;
    }
    if (changed.isEmpty) return;

    for (final entry in changed.entries) {
      await updateTask(entry.key, {'order_index': entry.value});
    }
  }

  // 7. Удаление задачи — в корзину, а не насовсем (C6).
  //
  // Раньше здесь был честный DELETE: задача исчезала навсегда, а отменить это
  // можно было только в пределах анимации свайпа на мобильном, то есть пары
  // секунд. При этом крестик удаления висит в каждой строке списка.
  //
  // Подзадачи уезжают вместе с родителем: восстановленная задача без своих
  // подзадач — это уже другая задача. Каскад делается здесь, а не триггером в
  // базе: триггер не отличил бы «удалили родителя» от «удалили одну подзадачу».
  Future<void> deleteTask(int taskId) async {
    final String deletedAt = DateTime.now().toIso8601String();
    try {
      await Supabase.instance.client
          .from('tasks')
          .update({'deleted_at': deletedAt})
          .or('id.eq.$taskId,parent_id.eq.$taskId');
    } on PostgrestException {
      rethrow;
    } catch (e) {
      _queuePendingOp('update', {
        'taskId': taskId,
        'data': {'deleted_at': deletedAt},
      });
      rethrow;
    }
  }

  /// Возвращает задачу из корзины вместе с её подзадачами.
  Future<void> restoreTask(int taskId) async {
    await Supabase.instance.client
        .from('tasks')
        .update({'deleted_at': null})
        .or('id.eq.$taskId,parent_id.eq.$taskId');
  }

  /// Удаляет задачу окончательно, минуя корзину. Подзадачи уходят каскадом по
  /// внешнему ключу, отдельно их удалять не нужно.
  Future<void> deleteTaskForever(int taskId) async {
    await Supabase.instance.client.from('tasks').delete().eq('id', taskId);
  }

  /// Применяет одно realtime-событие к кэшу вместо перечитывания всей таблицы
  /// (вторая половина B2).
  ///
  /// Раньше на КАЖДОЕ событие шёл полный select() всех задач пользователя.
  /// Отметил задачу — сервер прислал событие — приложение выкачало весь список
  /// заново, чтобы узнать про одну изменившуюся строку. При двух устройствах
  /// или командной задаче это превращается в постоянный поток лишних запросов.
  ///
  /// Возвращает false, если событие применить нельзя и нужен полный фетч:
  /// пришло не то, чего мы ждём (нет id), либо тип события неизвестен. Полный
  /// фетч остаётся честным запасным путём — «применить неправильно» здесь хуже,
  /// чем «перечитать лишний раз».
  ///
  /// Сама логика — в TaskCache: она про список в памяти, а не про сеть, и
  /// только поэтому её удалось покрыть тестами (сервис завязан на живой клиент
  /// Supabase, подменить который в тестах нечем).
  bool applyRealtimeChange(PostgresChangePayload payload) {
    final bool isDelete = payload.eventType == PostgresChangeEvent.delete;
    return _cache.applyChange(
      eventType: isDelete ? 'DELETE' : (payload.eventType == PostgresChangeEvent.insert ? 'INSERT' : 'UPDATE'),
      record: isDelete ? payload.oldRecord : payload.newRecord,
    );
  }

  /// Сколько задач у пользователя ВСЕГО (B3).
  ///
  /// Единственное число статистики, которое клиент знать не может: он грузит
  /// окно, а не всю таблицу. Пока окно содержит всё, разницы нет — но подпись
  /// «Всего задач в базе» это обещание, которое клиент перестанет выполнять
  /// ровно в тот день, когда окно начнёт отсекать старое, и сделает это молча.
  ///
  /// Именно COUNT, а не перенос расчётов в SQL: правила «просрочено / гниёт /
  /// переносили» остаются в одном месте (они зеркалят значки на карточках), а
  /// у сервера спрашивается только то, что знает один сервер.
  ///
  /// null — узнать не удалось (нет сети). Вызывающий код обязан отличать это
  /// от нуля и не выдавать загруженное окно за всю базу.
  Future<int?> fetchTotalTaskCount() async {
    try {
      final response = await Supabase.instance.client
          .from('tasks')
          .select()
          .isFilter('deleted_at', null)
          .count(CountOption.exact)
          .timeout(const Duration(seconds: 10));
      return response.count;
    } catch (e) {
      logError('Не удалось получить общее число задач: $e');
      return null;
    }
  }

  /// Содержимое корзины — грузится отдельным запросом и только когда открыт
  /// сам раздел. В общий кэш задач эти строки не попадают: иначе их пришлось
  /// бы отфильтровывать в каждом списке, а достаточно одного фильтра в
  /// fetchTasks.
  Future<List<Map<String, dynamic>>> fetchTrash() async {
    final data = await Supabase.instance.client
        .from('tasks')
        .select()
        .not('deleted_at', 'is', null)
        .isFilter('parent_id', null)
        .order('deleted_at', ascending: false)
        .timeout(const Duration(seconds: 15));
    return List<Map<String, dynamic>>.from(data);
  }

  /// Выполненные задачи СТАРШЕ окна загрузки — вторая половина B3.
  ///
  /// fetchTasks грузит окно (всё невыполненное + выполненное за
  /// [AppConfig.completedTasksWindowDays]), и это правильно: тянуть тысячи
  /// задач при каждом запуске и каждом realtime-событии — то, ради чего окно и
  /// вводилось. Но задачи за пределами окна становились НЕДОСТУПНЫ вообще:
  /// они есть в базе, а увидеть их нечем. Это не оптимизация, а потеря данных
  /// с точки зрения человека.
  ///
  /// Поэтому — отдельный запрос, по требованию и страницами. В общий кэш эти
  /// строки не попадают: иначе окно потеряло бы смысл, а списки пришлось бы
  /// фильтровать в каждом разделе.
  ///
  /// [before] — грузить то, что старше этого момента. Для первой страницы
  /// передаётся граница окна, для следующих — `completed_at` последней
  /// показанной задачи. Смещением (offset) листать нельзя: между запросами
  /// список меняется, и страницы начали бы перекрываться или пропускать
  /// задачи.
  Future<List<Map<String, dynamic>>> fetchArchive({
    required DateTime before,
    int limit = 50,
  }) async {
    final data = await Supabase.instance.client
        .from('tasks')
        .select()
        .isFilter('deleted_at', null)
        .isFilter('parent_id', null)
        .eq('is_completed', true)
        .lt('completed_at', before.toUtc().toIso8601String())
        .order('completed_at', ascending: false)
        .limit(limit)
        .timeout(const Duration(seconds: 15));
    return List<Map<String, dynamic>>.from(data);
  }

  /// Граница окна загрузки — с неё начинается история.
  ///
  /// Одно место на всё приложение: разъехавшись, окно и история либо оставили
  /// бы дыру между собой (задачи, невидимые нигде), либо показывали бы одни и
  /// те же задачи дважды.
  static DateTime archiveCutoff() => DateTime.now()
      .subtract(const Duration(days: AppConfig.completedTasksWindowDays));
}

