/// Мини-чек-лист внутри задачи (MISSING_FEATURES.md P1.4) — отдельно от
/// подзадач (`parent_id`, отдельные задачи): пункты списка, хранятся прямо
/// в задаче в jsonb-колонке `checklist` как [{text, done}], без своих id.
class ChecklistItem {
  final String text;
  final bool done;

  const ChecklistItem({required this.text, required this.done});

  Map<String, dynamic> toJson() => {'text': text, 'done': done};

  factory ChecklistItem.fromJson(Map<String, dynamic> json) =>
      ChecklistItem(text: json['text'] as String? ?? '', done: json['done'] == true);
}

/// Разбирает содержимое колонки `checklist` в список пунктов.
///
/// Результат ОБЯЗАН быть изменяемым: диалог редактирования задачи держит его
/// как рабочее состояние и добавляет/удаляет пункты прямо в нём. Здесь стояло
/// `const []` — а это неизменяемый список фиксированной длины, и добавление
/// падало с «Cannot add to an unmodifiable list». Ломалось ровно у задач БЕЗ
/// чек-листа, то есть у всех, где его пытались завести впервые; там, где
/// список уже был, всё работало (`.map().toList()` возвращает изменяемый), —
/// поэтому баг и прожил незамеченным.
List<ChecklistItem> parseChecklist(dynamic raw) {
  if (raw is! List) return <ChecklistItem>[];
  return raw.whereType<Map>().map((e) => ChecklistItem.fromJson(Map<String, dynamic>.from(e))).toList();
}

List<Map<String, dynamic>> encodeChecklist(List<ChecklistItem> items) =>
    items.map((e) => e.toJson()).toList();

Map<String, int> checklistStats(dynamic raw) {
  final items = parseChecklist(raw);
  return {'total': items.length, 'done': items.where((e) => e.done).length};
}
