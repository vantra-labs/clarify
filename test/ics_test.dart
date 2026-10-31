import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/core/ics.dart';

/// Собирает минимальный корректный календарь вокруг тела события.
String calendar(String body, {String? name}) => [
      'BEGIN:VCALENDAR',
      'VERSION:2.0',
      'PRODID:-//Тест//RU',
      if (name != null) 'X-WR-CALNAME:$name',
      body,
      'END:VCALENDAR',
    ].join('\r\n');

void main() {
  group('разбор структуры', () {
    test('событие на весь день не получает времени', () {
      final cal = IcsParser.parse(calendar([
        'BEGIN:VEVENT',
        'UID:day-1@gasu',
        'SUMMARY:День знаний',
        'DTSTART;VALUE=DATE:20260901',
        'DTEND;VALUE=DATE:20260902',
        'END:VEVENT',
      ].join('\r\n')));

      expect(cal.events, hasLength(1));
      final e = cal.events.single;
      expect(e.summary, 'День знаний');
      expect(e.allDay, isTrue);
      expect(e.start, DateTime(2026, 9, 1));
      expect(e.uid, 'day-1@gasu');
    });

    test('дата без VALUE=DATE, но из восьми цифр тоже считается дневной', () {
      final cal = IcsParser.parse(calendar([
        'BEGIN:VEVENT',
        'SUMMARY:Без параметра',
        'DTSTART:20260901',
        'END:VEVENT',
      ].join('\r\n')));

      expect(cal.events.single.allDay, isTrue);
      expect(cal.events.single.start, DateTime(2026, 9, 1));
    });

    test('локальное время берётся как записано', () {
      final cal = IcsParser.parse(calendar([
        'BEGIN:VEVENT',
        'SUMMARY:Техническая механика',
        'DTSTART:20260921T201500',
        'DTEND:20260921T214500',
        'END:VEVENT',
      ].join('\r\n')));

      final e = cal.events.single;
      expect(e.allDay, isFalse);
      expect(e.start, DateTime(2026, 9, 21, 20, 15));
      expect(e.durationMinutes, 90);
    });

    test('время в UTC пересчитывается в местное', () {
      final cal = IcsParser.parse(calendar([
        'BEGIN:VEVENT',
        'SUMMARY:Созвон',
        'DTSTART:20260921T120000Z',
        'END:VEVENT',
      ].join('\r\n')));

      final expected = DateTime.utc(2026, 9, 21, 12).toLocal();
      expect(cal.events.single.start, expected);
    });

    test('TZID сохраняется, а время берётся со стенных часов', () {
      final cal = IcsParser.parse(calendar([
        'BEGIN:VEVENT',
        'SUMMARY:Пара',
        'DTSTART;TZID=Europe/Moscow:20260921T183000',
        'END:VEVENT',
      ].join('\r\n')));

      final e = cal.events.single;
      expect(e.tzid, 'Europe/Moscow');
      expect(e.start, DateTime(2026, 9, 21, 18, 30));
    });

    test('перенесённые строки склеиваются обратно', () {
      final cal = IcsParser.parse(calendar([
        'BEGIN:VEVENT',
        'SUMMARY:Очень длинное название пары, которое выгрузка разорвала',
        '  пополам прямо посередине',
        'DTSTART:20260921T100000',
        'END:VEVENT',
      ].join('\r\n')));

      expect(
        cal.events.single.summary,
        'Очень длинное название пары, которое выгрузка разорвала пополам прямо посередине',
      );
    });

    test('экранированные символы разворачиваются', () {
      final cal = IcsParser.parse(calendar([
        'BEGIN:VEVENT',
        'SUMMARY:Лекция\\, часть 1',
        r'DESCRIPTION:Первая строка\nВторая строка\;и точка с запятой\\конец',
        'DTSTART:20260921T100000',
        'END:VEVENT',
      ].join('\r\n')));

      final e = cal.events.single;
      expect(e.summary, 'Лекция, часть 1');
      expect(e.description, 'Первая строка\nВторая строка;и точка с запятой\\конец');
    });

    test('двоеточие внутри значения не ломает разбор', () {
      final cal = IcsParser.parse(calendar([
        'BEGIN:VEVENT',
        'SUMMARY:Встреча 10:30 у метро',
        'LOCATION:https://meet.example.com/room?id=1',
        'DTSTART:20260921T100000',
        'END:VEVENT',
      ].join('\r\n')));

      final e = cal.events.single;
      expect(e.summary, 'Встреча 10:30 у метро');
      expect(e.location, 'https://meet.example.com/room?id=1');
    });

    test('имя календаря читается, отменённое событие помечается', () {
      final cal = IcsParser.parse(calendar([
        'BEGIN:VEVENT',
        'SUMMARY:Отменённая пара',
        'STATUS:CANCELLED',
        'DTSTART:20260921T100000',
        'END:VEVENT',
      ].join('\r\n'), name: 'Расписание ГАСУ'));

      expect(cal.name, 'Расписание ГАСУ');
      expect(cal.events.single.isCancelled, isTrue);
    });

    test('незнакомые свойства и мусор не роняют разбор', () {
      final cal = IcsParser.parse(calendar([
        'X-НЕИЗВЕСТНОЕ-СВОЙСТВО:значение',
        'строка без двоеточия',
        'BEGIN:VEVENT',
        'SUMMARY:Живое событие',
        'DTSTART:20260921T100000',
        'X-MICROSOFT-CDO-BUSYSTATUS:BUSY',
        'ATTENDEE;CN="Иванов И.И.";ROLE=REQ-PARTICIPANT:mailto:a@b.c',
        'END:VEVENT',
      ].join('\r\n')));

      expect(cal.events, hasLength(1));
      expect(cal.events.single.summary, 'Живое событие');
    });

    test('несколько событий и перевод строк в стиле Unix', () {
      final cal = IcsParser.parse([
        'BEGIN:VCALENDAR',
        'BEGIN:VEVENT',
        'SUMMARY:Первое',
        'DTSTART:20260921T100000',
        'END:VEVENT',
        'BEGIN:VEVENT',
        'SUMMARY:Второе',
        'DTSTART:20260922T100000',
        'END:VEVENT',
        'END:VCALENDAR',
      ].join('\n'));

      expect(cal.events.map((e) => e.summary), ['Первое', 'Второе']);
    });

    test('пустой и бессмысленный ввод даёт пустой календарь без исключения', () {
      expect(IcsParser.parse('').events, isEmpty);
      expect(IcsParser.parse('совершенно не календарь').events, isEmpty);
    });
  });

  group('перевод правила повтора', () {
    test('ежедневно и через несколько дней', () {
      expect(icsRecurrenceToClarify('FREQ=DAILY').recurrence, 'daily');

      final every3 = icsRecurrenceToClarify('FREQ=DAILY;INTERVAL=3');
      expect(every3.recurrence, 'custom');
      expect(every3.intervalDays, 3);
    });

    test('еженедельно и через неделю', () {
      expect(icsRecurrenceToClarify('FREQ=WEEKLY').recurrence, 'weekly');

      final every2w = icsRecurrenceToClarify('FREQ=WEEKLY;INTERVAL=2');
      expect(every2w.recurrence, 'custom');
      expect(every2w.intervalDays, 14);
    });

    test('пять рабочих дней превращаются в режим будней', () {
      final r = icsRecurrenceToClarify('FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR');
      expect(r.recurrence, 'weekdays');
    });

    test('произвольный набор дней недели честно не поддерживается', () {
      expect(icsRecurrenceToClarify('FREQ=WEEKLY;BYDAY=MO,WE').recurrence, isNull);
    });

    test('ежемесячно поддерживается, ежегодно — нет', () {
      expect(icsRecurrenceToClarify('FREQ=MONTHLY').recurrence, 'monthly');
      expect(icsRecurrenceToClarify('FREQ=YEARLY').recurrence, isNull);
      expect(icsRecurrenceToClarify('FREQ=MONTHLY;INTERVAL=2').recurrence, isNull);
    });

    test('пустое и битое правило не создают повтора', () {
      expect(icsRecurrenceToClarify(null).recurrence, isNull);
      expect(icsRecurrenceToClarify('').recurrence, isNull);
      expect(icsRecurrenceToClarify('ерунда').recurrence, isNull);
      expect(icsRecurrenceToClarify('FREQ=DAILY;INTERVAL=0').recurrence, isNull);
    });
  });

  group('поля задачи', () {
    /// Набор ключей, который принимает TaskService.addTask. Расхождение здесь
    /// означает молча потерянную дату или повтор, поэтому он закреплён.
    const taskKeys = {
      'title',
      'due_date',
      'due_time',
      'duration_minutes',
      'note',
      'recurrence',
      'recurrence_interval',
      'recurrence_from_completion',
      'is_completed',
      'priority',
      'folder',
      'external_uid',
      'external_source',
    };

    test('имена полей совпадают с теми, что принимает addTask', () {
      final fields = icsEventToTaskFields(
        const IcsEvent(summary: 'Пара', start: null),
      );
      expect(fields.keys.toSet(), taskKeys);
    });

    test('событие со временем раскладывается в дату, время и длительность', () {
      final fields = icsEventToTaskFields(
        IcsEvent(
          summary: 'Техническая механика',
          uid: 'pair-42',
          start: DateTime(2026, 9, 21, 20, 15),
          end: DateTime(2026, 9, 21, 21, 45),
          location: 'MS Teams',
          description: 'Войтко А. М.',
        ),
        folder: 'Учёба',
        subscriptionId: 7,
      );

      expect(fields['title'], 'Техническая механика');
      expect(fields['due_date'], '21.09.2026');
      expect(fields['due_time'], '20:15');
      expect(fields['duration_minutes'], 90);
      expect(fields['folder'], 'Учёба');
      expect(fields['external_uid'], 'pair-42');
      expect(fields['external_source'], 7);
      expect(fields['note'], 'Место: MS Teams\n\nВойтко А. М.');
      expect(fields['is_completed'], isFalse);
      expect(fields['priority'], 'none');
    });

    test('у события на весь день нет ни времени, ни длительности', () {
      final fields = icsEventToTaskFields(
        IcsEvent(
          summary: 'День знаний',
          start: DateTime(2026, 9, 1),
          end: DateTime(2026, 9, 2),
          allDay: true,
        ),
      );

      expect(fields['due_date'], '01.09.2026');
      expect(fields['due_time'], isNull);
      expect(fields['duration_minutes'], isNull);
    });

    test('заметки можно не переносить', () {
      final fields = icsEventToTaskFields(
        const IcsEvent(summary: 'Пара', description: 'Много текста', location: 'Ауд. 1'),
        importNotes: false,
      );
      expect(fields['note'], isNull);
    });

    test('событие без названия получает понятную подстановку', () {
      final fields = icsEventToTaskFields(const IcsEvent(summary: ''));
      expect(fields['title'], 'Событие календаря');
    });

    test('повтор из RRULE доезжает до полей задачи', () {
      final fields = icsEventToTaskFields(
        IcsEvent(
          summary: 'Тренировка',
          start: DateTime(2026, 9, 21, 7),
          rrule: 'FREQ=WEEKLY;INTERVAL=2',
        ),
      );
      expect(fields['recurrence'], 'custom');
      expect(fields['recurrence_interval'], 14);
      expect(fields['recurrence_from_completion'], isFalse);
    });

    test('неподдерживаемый повтор даёт разовую задачу, а не выдуманный ритм', () {
      final fields = icsEventToTaskFields(
        IcsEvent(
          summary: 'День рождения',
          start: DateTime(2026, 9, 21),
          allDay: true,
          rrule: 'FREQ=YEARLY',
        ),
      );
      expect(fields['recurrence'], isNull);
      expect(fields['recurrence_interval'], isNull);
      expect(fields['due_date'], '21.09.2026');
    });

    test('сквозной путь: текст календаря превращается в поля задачи', () {
      final cal = IcsParser.parse(calendar([
        'BEGIN:VEVENT',
        'UID:lesson-1@moodle',
        'SUMMARY:Информационные технологии',
        'DTSTART;TZID=Europe/Moscow:20260922T183000',
        'DTEND;TZID=Europe/Moscow:20260922T200000',
        'LOCATION:Дистанционно',
        'RRULE:FREQ=WEEKLY;INTERVAL=2',
        'END:VEVENT',
      ].join('\r\n')));

      final fields = icsEventToTaskFields(cal.events.single, folder: 'ГАСУ');
      expect(fields['title'], 'Информационные технологии');
      expect(fields['due_date'], '22.09.2026');
      expect(fields['due_time'], '18:30');
      expect(fields['duration_minutes'], 90);
      expect(fields['recurrence'], 'custom');
      expect(fields['recurrence_interval'], 14);
      expect(fields['external_uid'], 'lesson-1@moodle');
      expect(fields['folder'], 'ГАСУ');
    });
  });
}
