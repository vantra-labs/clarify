/// Разбор календарей формата iCalendar (.ics, RFC 5545) и перевод событий в
/// поля задачи Clarify.
///
/// Без единой зависимости на Flutter, сеть и базу — ровно по тем же причинам,
/// что и [recurrence.dart]: поведение проверяется тестами, а не глазами в
/// приложении. Сеть и запись в базу живут в
/// `services/calendar_subscription_service.dart`.
///
/// Реализовано подмножество стандарта, которое реально встречается в выгрузках
/// Google Calendar, Apple, Outlook, Битрикс24 и вузовских ЛК: VEVENT, склейка
/// перенесённых строк, параметры свойств, DATE и DATE-TIME (локальные, UTC и с
/// TZID), экранирование текста и простые RRULE.
library;

/// Событие календаря в том виде, в каком его отдал источник.
class IcsEvent {
  const IcsEvent({
    required this.summary,
    this.uid,
    this.description,
    this.location,
    this.start,
    this.end,
    this.allDay = false,
    this.rrule,
    this.status,
    this.tzid,
  });

  /// Заголовок (SUMMARY). Пустая строка, если источник его не дал.
  final String summary;

  /// Стабильный идентификатор события в своём календаре (UID).
  ///
  /// Именно по нему повторная синхронизация узнаёт уже импортированное
  /// событие и правит его, а не плодит копию.
  final String? uid;

  final String? description;
  final String? location;

  /// Начало события как «время на стенных часах» пользователя.
  ///
  /// Для значений с суффиксом `Z` (UTC) пересчитано в местное время машины.
  /// Для значений с `TZID` время взято как записано — см. [tzid].
  final DateTime? start;
  final DateTime? end;

  /// Событие на весь день (`VALUE=DATE`): времени у него нет.
  final bool allDay;

  /// Правило повтора как есть, например `FREQ=WEEKLY;INTERVAL=2`.
  final String? rrule;

  /// `CANCELLED`, `TENTATIVE`, `CONFIRMED`.
  final String? status;

  /// Часовой пояс из параметра TZID, если он был.
  ///
  /// Полную базу часовых поясов мы не тянем: для расписания в своём же поясе
  /// (обычный случай) верное поведение — взять время как написано. Поле
  /// сохранено, чтобы расхождение можно было заметить, а не спрятать.
  final String? tzid;

  /// Событие отменено в источнике — импортировать его не нужно.
  bool get isCancelled => status?.toUpperCase() == 'CANCELLED';

  /// Длительность в минутах, если известны и начало, и конец.
  int? get durationMinutes {
    final s = start, e = end;
    if (s == null || e == null) return null;
    final minutes = e.difference(s).inMinutes;
    return minutes > 0 ? minutes : null;
  }

  @override
  String toString() => 'IcsEvent($summary, start=$start, allDay=$allDay)';
}

/// Разобранный календарь.
class IcsCalendar {
  const IcsCalendar({required this.events, this.name});

  /// Имя календаря (X-WR-CALNAME), если источник его прислал.
  final String? name;
  final List<IcsEvent> events;
}

/// Одно свойство строки: имя, параметры и значение.
class _IcsLine {
  const _IcsLine(this.name, this.params, this.value);
  final String name;
  final Map<String, String> params;
  final String value;
}

/// Разбор .ics.
class IcsParser {
  const IcsParser._();

  /// Разбирает содержимое файла .ics.
  ///
  /// Мусор и незнакомые свойства пропускаются молча: календарь от чужой
  /// системы почти всегда содержит что-то, чего мы не знаем, и падать из-за
  /// этого нельзя.
  static IcsCalendar parse(String text) {
    final lines = _unfold(text);
    final events = <IcsEvent>[];
    String? calendarName;

    Map<String, _IcsLine>? current;
    for (final raw in lines) {
      if (raw.isEmpty) continue;
      final line = _parseLine(raw);
      if (line == null) continue;

      final upper = line.name.toUpperCase();
      final value = line.value.trim();

      if (upper == 'BEGIN' && value.toUpperCase() == 'VEVENT') {
        current = <String, _IcsLine>{};
        continue;
      }
      if (upper == 'END' && value.toUpperCase() == 'VEVENT') {
        if (current != null) {
          final event = _buildEvent(current);
          if (event != null) events.add(event);
        }
        current = null;
        continue;
      }

      if (current != null) {
        // Повторяющееся свойство внутри события (например, несколько
        // EXDATE) — держим первое: дальше оно всё равно не используется.
        current.putIfAbsent(upper, () => line);
      } else if (upper == 'X-WR-CALNAME') {
        calendarName = _unescapeText(line.value);
      }
    }

    return IcsCalendar(events: events, name: calendarName);
  }

  /// Склейка перенесённых строк.
  ///
  /// По стандарту длинная строка разрывается, а продолжение начинается с
  /// пробела или табуляции. Без склейки длинные SUMMARY и DESCRIPTION
  /// рвутся посреди слова — это самая частая причина «кракозябр» при
  /// самодельном разборе.
  static List<String> _unfold(String text) {
    final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final out = <String>[];
    for (final line in normalized.split('\n')) {
      if (line.isEmpty) continue;
      final isContinuation = line.startsWith(' ') || line.startsWith('\t');
      if (isContinuation && out.isNotEmpty) {
        out[out.length - 1] = out.last + line.substring(1);
      } else {
        out.add(line);
      }
    }
    return out;
  }

  /// `DTSTART;TZID=Europe/Moscow:20260915T183000` → имя, параметры, значение.
  static _IcsLine? _parseLine(String raw) {
    // Двоеточие может встретиться и внутри значения (URL), поэтому ищем
    // первое, которое не находится внутри кавычек параметра.
    var inQuotes = false;
    var colon = -1;
    for (var i = 0; i < raw.length; i++) {
      final ch = raw[i];
      if (ch == '"') {
        inQuotes = !inQuotes;
      } else if (ch == ':' && !inQuotes) {
        colon = i;
        break;
      }
    }
    if (colon <= 0) return null;

    final head = raw.substring(0, colon);
    final value = raw.substring(colon + 1);

    final parts = _splitParams(head);
    if (parts.isEmpty) return null;

    final name = parts.first.trim();
    final params = <String, String>{};
    for (final p in parts.skip(1)) {
      final eq = p.indexOf('=');
      if (eq <= 0) continue;
      var v = p.substring(eq + 1).trim();
      if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
        v = v.substring(1, v.length - 1);
      }
      params[p.substring(0, eq).trim().toUpperCase()] = v;
    }
    return _IcsLine(name, params, value);
  }

  /// Деление заголовка по `;` с уважением к кавычкам.
  static List<String> _splitParams(String head) {
    final out = <String>[];
    final buf = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < head.length; i++) {
      final ch = head[i];
      if (ch == '"') {
        inQuotes = !inQuotes;
        buf.write(ch);
      } else if (ch == ';' && !inQuotes) {
        out.add(buf.toString());
        buf.clear();
      } else {
        buf.write(ch);
      }
    }
    if (buf.isNotEmpty) out.add(buf.toString());
    return out;
  }

  static IcsEvent? _buildEvent(Map<String, _IcsLine> props) {
    final dtStart = props['DTSTART'];
    final summaryLine = props['SUMMARY'];
    final summary = summaryLine == null ? '' : _unescapeText(summaryLine.value).trim();

    // Событие без начала и без названия импортировать не во что.
    if (dtStart == null && summary.isEmpty) return null;

    final startParsed = dtStart == null ? null : _parseDateValue(dtStart);
    final endLine = props['DTEND'];
    final endParsed = endLine == null ? null : _parseDateValue(endLine);

    return IcsEvent(
      summary: summary,
      uid: props['UID']?.value.trim(),
      description: _optionalText(props['DESCRIPTION']),
      location: _optionalText(props['LOCATION']),
      start: startParsed?.value,
      end: endParsed?.value,
      allDay: startParsed?.isDateOnly ?? false,
      rrule: props['RRULE']?.value.trim(),
      status: props['STATUS']?.value.trim(),
      tzid: dtStart?.params['TZID'],
    );
  }

  static String? _optionalText(_IcsLine? line) {
    if (line == null) return null;
    final v = _unescapeText(line.value).trim();
    return v.isEmpty ? null : v;
  }

  /// Экранирование текста по стандарту: `\n`, `\,`, `\;`, `\\`.
  static String _unescapeText(String value) {
    final buf = StringBuffer();
    for (var i = 0; i < value.length; i++) {
      final ch = value[i];
      if (ch != r'\' || i + 1 >= value.length) {
        buf.write(ch);
        continue;
      }
      final next = value[i + 1];
      i++;
      switch (next) {
        case 'n':
        case 'N':
          buf.write('\n');
          break;
        case r'\':
          buf.write(r'\');
          break;
        case ',':
          buf.write(',');
          break;
        case ';':
          buf.write(';');
          break;
        default:
          // Неизвестная последовательность — отдаём как есть, не теряя символ.
          buf.write(next);
      }
    }
    return buf.toString();
  }

  static _IcsDate? _parseDateValue(_IcsLine line) {
    final raw = line.value.trim();
    final isDateOnly = (line.params['VALUE'] ?? '').toUpperCase() == 'DATE' ||
        (raw.length == 8 && !raw.contains('T'));

    if (isDateOnly) {
      if (raw.length < 8) return null;
      final y = int.tryParse(raw.substring(0, 4));
      final m = int.tryParse(raw.substring(4, 6));
      final d = int.tryParse(raw.substring(6, 8));
      if (y == null || m == null || d == null) return null;
      return _IcsDate(DateTime(y, m, d), true);
    }

    // YYYYMMDDTHHMMSS[Z]
    if (raw.length < 15 || raw[8] != 'T') return null;
    final y = int.tryParse(raw.substring(0, 4));
    final mo = int.tryParse(raw.substring(4, 6));
    final d = int.tryParse(raw.substring(6, 8));
    final h = int.tryParse(raw.substring(9, 11));
    final mi = int.tryParse(raw.substring(11, 13));
    final s = int.tryParse(raw.substring(13, 15));
    if (y == null || mo == null || d == null || h == null || mi == null || s == null) {
      return null;
    }

    final isUtc = raw.endsWith('Z');
    if (isUtc) {
      // UTC пересчитываем в местное время машины: пользователь ожидает увидеть
      // в задаче то же время, что показывает его календарь.
      return _IcsDate(DateTime.utc(y, mo, d, h, mi, s).toLocal(), false);
    }
    // Локальное время или время с TZID — берём как написано.
    return _IcsDate(DateTime(y, mo, d, h, mi, s), false);
  }
}

class _IcsDate {
  const _IcsDate(this.value, this.isDateOnly);
  final DateTime value;
  final bool isDateOnly;
}

/// Результат перевода правила повтора в модель Clarify.
class IcsRecurrence {
  const IcsRecurrence(this.recurrence, this.intervalDays);

  /// Одно из значений, которые понимает приложение: `daily`, `weekdays`,
  /// `weekly`, `monthly`, `custom`. `null` — правило не поддерживается.
  final String? recurrence;

  /// Шаг в днях для `custom`.
  final int? intervalDays;
}

/// Перевод RRULE в повтор Clarify.
///
/// Модель приложения беднее стандарта: у неё нет ни ежегодного повтора, ни
/// произвольных наборов дней недели. Вместо того чтобы подменять их
/// «ближайшим похожим» и тихо врать пользователю о расписании, неподдерживаемые
/// правила возвращают `null` — задача создаётся разовой на свою дату.
IcsRecurrence icsRecurrenceToClarify(String? rrule) {
  if (rrule == null || rrule.trim().isEmpty) {
    return const IcsRecurrence(null, null);
  }

  final parts = <String, String>{};
  for (final chunk in rrule.split(';')) {
    final eq = chunk.indexOf('=');
    if (eq <= 0) continue;
    parts[chunk.substring(0, eq).trim().toUpperCase()] =
        chunk.substring(eq + 1).trim().toUpperCase();
  }

  final freq = parts['FREQ'];
  final interval = int.tryParse(parts['INTERVAL'] ?? '1') ?? 1;
  if (interval < 1) return const IcsRecurrence(null, null);

  final byDay = parts['BYDAY'];

  switch (freq) {
    case 'DAILY':
      if (interval == 1) return const IcsRecurrence('daily', null);
      return IcsRecurrence('custom', interval);

    case 'WEEKLY':
      // Ровно рабочие дни — у Clarify для этого есть отдельный режим.
      if (byDay != null) {
        final days = byDay.split(',').map((e) => e.trim()).toSet();
        const workweek = {'MO', 'TU', 'WE', 'TH', 'FR'};
        if (interval == 1 && days.length == 5 && days.containsAll(workweek)) {
          return const IcsRecurrence('weekdays', null);
        }
        // Несколько произвольных дней недели одной задачей не выражаются.
        if (days.length > 1) return const IcsRecurrence(null, null);
      }
      if (interval == 1) return const IcsRecurrence('weekly', null);
      return IcsRecurrence('custom', interval * 7);

    case 'MONTHLY':
      if (interval == 1) return const IcsRecurrence('monthly', null);
      return const IcsRecurrence(null, null);

    default:
      // YEARLY и всё остальное — честно не поддерживаем.
      return const IcsRecurrence(null, null);
  }
}

/// Дата в том виде, в каком её хранит Clarify: `ДД.ММ.ГГГГ`.
String icsFormatDate(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

/// Время в том виде, в каком его хранит Clarify: `ЧЧ:ММ`.
String icsFormatTime(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// Перевод события в набор полей задачи Clarify.
///
/// Имена ключей повторяют то, что принимает `TaskService.addTask`: любое
/// расхождение здесь означает, что задача сохранится без даты или без повтора,
/// поэтому набор ключей закреплён тестом.
Map<String, dynamic> icsEventToTaskFields(
  IcsEvent event, {
  String? folder,
  bool importNotes = true,
  int? subscriptionId,
}) {
  final start = event.start;
  final repeat = icsRecurrenceToClarify(event.rrule);

  final noteParts = <String>[];
  if (importNotes) {
    if (event.location != null) noteParts.add('Место: ${event.location}');
    if (event.description != null) noteParts.add(event.description!);
  }

  return <String, dynamic>{
    'title': event.summary.isEmpty ? 'Событие календаря' : event.summary,
    'due_date': start == null ? null : icsFormatDate(start),
    // У события на весь день времени нет — не выдумываем полночь, иначе оно
    // встанет в таймлайн на 00:00 и будет мозолить глаза каждое утро.
    'due_time': (start == null || event.allDay) ? null : icsFormatTime(start),
    'duration_minutes': event.allDay ? null : event.durationMinutes,
    'note': noteParts.isEmpty ? null : noteParts.join('\n\n'),
    'recurrence': repeat.recurrence,
    'recurrence_interval': repeat.intervalDays,
    'recurrence_from_completion': false,
    'is_completed': false,
    'priority': 'none',
    'folder': folder,
    'external_uid': event.uid,
    'external_source': subscriptionId,
  };
}
