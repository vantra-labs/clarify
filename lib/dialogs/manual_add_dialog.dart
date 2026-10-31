import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'manual_add_ai_dialog.dart';
import '../widgets/clarify_button.dart';
import '../widgets/clarify_day_load_warning.dart';
import '../widgets/clarify_duration_chips.dart';
import '../widgets/clarify_priority_lever.dart';
import '../widgets/clarify_surface.dart';
import '../widgets/clarify_text_field.dart';
import '../widgets/clarify_toast.dart';
import '../widgets/clarify_date_time_picker.dart';
import '../core/app_settings.dart';
import '../core/config.dart';
import '../core/localization.dart';
import '../core/tags.dart';
import '../core/priority.dart';
import '../core/theme/design_tokens.dart';

/// Диалог создания новой задачи (в т.ч. дублирования). Вынесено из
/// DesktopPlannerScreen (P3.1, docs/IMPROVEMENT_PLAN.md) — логика и разметка
/// не менялись, только доступ к состоянию родителя заменён на явные
/// параметры функции.
///
/// ИЗВЕСТНЫЙ БАГ, обнаруженный при переносе (не исправлен в этом коммите —
/// извлечение кода должно быть чистым перемещением, не поведенческим
/// изменением): кнопки "+1 День"/"+1 Неделя" вызывают [shiftDate], которая
/// принимает `selectedDate` ПО ЗНАЧЕНИЮ и переприсваивает свой локальный
/// параметр — это не обновляет `selectedDate` в диалоге, поэтому видимая
/// дата на кнопке не меняется по клику (`setStateDialog` форсирует
/// перерисовку, но с тем же значением). В `_showEditTaskDialog` аналогичная
/// кнопка работает правильно, т.к. использует локальное замыкание, а не
/// функцию с параметром. См. docs/IMPROVEMENT_PLAN.md — стоит завести туда
/// отдельный пункt на исправление.
void showManualAddDialog({
  required BuildContext context,
  required bool isDark,
  required double scale,
  required Color textColor,
  required Color textMuted,
  required Color glassBorderColor,
  required Color doneCardColor,
  required Color highlightColor,
  required String currentLang,
  required String selectedMenu,
  required String? activeTagFilter,
  required List<Map<String, dynamic>> tasks,
  required Map<int, List<Map<String, dynamic>>> workspaceMembers,
  required bool isDuplicating,
  required VoidCallback onDuplicateHandled,
  required Future<int?> Function(Map<String, dynamic> taskData)
  createTaskManually,
  required Future<String> Function(String text, List<Map<String, String>> history)
  onAiParseText,
  required Future<String> Function(
    Uint8List audioBytes,
    String filename,
    String contentType,
  )
  onTranscribeVoice,
  required void Function(String dateStr) checkBurnoutWarning,
  required Map<String, dynamic> Function(String text) parseSmartInput,
  required Color Function(String? priority) getPriorityColor,
  required String Function(DateTime date) formatDate,
  required void Function(
    int days,
    int months,
    StateSetter setStateDialog,
    DateTime? currentDate,
  )
  shiftDate,
  required Widget Function({
    required Widget child,
    BorderRadius? borderRadius,
    EdgeInsetsGeometry? padding,
    EdgeInsetsGeometry? margin,
    Color? customColor,
  })
  buildGlassContainer,
  DateTime? preselectedDate,
  Map<String, dynamic>? sourceTaskForDuplicate,
  Offset? originOffset,
}) {
  final t = context.tokens;
  final s = scale;
  final bool isFromDuplicate = sourceTaskForDuplicate != null;
  final TextEditingController titleController = TextEditingController(
    text: isFromDuplicate ? sourceTaskForDuplicate['title'] : '',
  );
  final TextEditingController noteController = TextEditingController(
    text: isFromDuplicate ? (sourceTaskForDuplicate['note'] ?? '') : '',
  );
  final TextEditingController tagsController = TextEditingController(
    text: isFromDuplicate
        ? (sourceTaskForDuplicate['tags'] ?? '')
        : (activeTagFilter ?? ''),
  );
  final TextEditingController subtaskController = TextEditingController();

  String selectedPriority = isFromDuplicate
      ? (sourceTaskForDuplicate['priority'] ?? 'none')
      : AppSettings.quickAddDefaultPriority;
  String selectedRecurrence = isFromDuplicate
      ? (sourceTaskForDuplicate['recurrence'] ?? 'none')
      : AppSettings.quickAddDefaultRecurrence;
  int selectedRecurrenceInterval = isFromDuplicate
      ? ((sourceTaskForDuplicate['recurrence_interval'] as int?) ?? 2)
      : 2;
  // Повтор от даты выполнения, а не от плановой (C3). По умолчанию выключен —
  // «каждый понедельник» должно оставаться каждым понедельником.
  bool recurrenceFromCompletion = isFromDuplicate
      ? sourceTaskForDuplicate['recurrence_from_completion'] == true
      : false;
  String? selectedAssigneeId;
  DateTime? selectedDate = preselectedDate ?? DateTime.now();
  TimeOfDay? selectedTime;
  int? selectedDuration = isFromDuplicate
      ? (sourceTaskForDuplicate['duration_minutes'] as int?)
      : null;

  if (isFromDuplicate && sourceTaskForDuplicate['due_time'] != null) {
    final parts = sourceTaskForDuplicate['due_time'].split(':');
    selectedTime = TimeOfDay(
      hour: int.parse(parts[0]),
      minute: int.parse(parts[1]),
    );
  }

  List<String> tempSubtasks = [];
  if (isFromDuplicate) {
    final existingSubs = tasks
        .where((t) => t['parent_id'] == sourceTaskForDuplicate['id'])
        .toList();
    tempSubtasks = existingSubs.map((s) => s['title'].toString()).toList();
  }

  bool isSaving = false;

  final List<String> knownTags = collectAllTags(tasks);
  List<String> tagSuggestions() {
    final segments = tagsController.text
        .split(',')
        .map((e) => e.trim())
        .toList();
    final fragment = segments.isEmpty ? '' : segments.last;
    if (fragment.isEmpty) return const [];
    final existing = segments.take(segments.length - 1).toSet();
    return knownTags
        .where(
          (tag) =>
              tag.toLowerCase().contains(fragment.toLowerCase()) &&
              tag.toLowerCase() != fragment.toLowerCase() &&
              !existing.contains(tag),
        )
        .take(5)
        .toList();
  }

  void applyTagSuggestion(String tag, StateSetter setStateDialog) {
    final segments = tagsController.text
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (segments.isNotEmpty) segments.removeLast();
    segments.add(tag);
    setStateDialog(() {
      tagsController.text = '${segments.join(', ')}, ';
      tagsController.selection = TextSelection.collapsed(
        offset: tagsController.text.length,
      );
    });
  }

  showClarifyResponsiveSurface(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.4),
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setStateDialog) {
          final content = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    isFromDuplicate
                        ? "Дублирование".tr(currentLang)
                        : "Новая задача".tr(currentLang),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 20,
                      color: textColor,
                    ),
                  ),
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'AI Ассистент'.tr(currentLang),
                        icon: Icon(LucideIcons.sparkles, color: t.accent),
                        onPressed: () => showManualAddAiChatDialog(
                          context: context,
                          currentLang: currentLang,
                          textColor: textColor,
                          textMuted: textMuted,
                          onAiParseText: onAiParseText,
                          onTranscribeVoice: onTranscribeVoice,
                          buildGlassContainer: buildGlassContainer,
                        ),
                      ),
                      IconButton(
                        icon: Icon(LucideIcons.x, color: textMuted),
                        onPressed: () {
                          Navigator.pop(context);
                          if (isDuplicating) onDuplicateHandled();
                        },
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),
              ClarifyTextField(
                controller: titleController,
                style: TextStyle(color: textColor, fontSize: 16),
                autofocus: true,
                onChanged: (value) {
                  final parsed = parseSmartInput(value);
                  if (parsed['time'] != null) {
                    final parts = parsed['time'].split(':');
                    setStateDialog(
                      () => selectedTime = TimeOfDay(
                        hour: int.parse(parts[0]),
                        minute: int.parse(parts[1]),
                      ),
                    );
                  }
                  if (parsed['tags'] != null) {
                    final currentTags = tagsController.text.trim();
                    if (!currentTags.contains(parsed['tags'])) {
                      tagsController.text = currentTags.isEmpty
                          ? parsed['tags']
                          : "$currentTags, ${parsed['tags']}";
                    }
                  }
                },
                labelText: "Заголовок".tr(currentLang),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: t.surfaceSunken,
                  borderRadius: BorderRadius.circular(ClarifyRadius.md),
                  border: Border.all(color: t.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          "Приоритет: ".tr(currentLang),
                          style: TextStyle(color: textMuted, fontSize: 14),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ClarifyPriorityLever(
                            value: selectedPriority,
                            onChanged: (val) =>
                                setStateDialog(() => selectedPriority = val),
                            getPriorityColor: getPriorityColor,
                            textMuted: textMuted,
                          ),
                        ),
                        if (selectedPriority != 'none') ...[
                          const SizedBox(width: 4),
                          Text(
                            priorityFlagLabel(selectedPriority),
                            style: TextStyle(
                              color: getPriorityColor(selectedPriority),
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: ClarifyButton(
                            icon: LucideIcons.calendar,
                            label: selectedDate == null
                                ? "Без даты".tr(currentLang)
                                : formatDate(selectedDate!),
                            variant: ClarifyButtonVariant.outline,
                            onPressed: () async {
                              final picked = await showClarifyDatePicker(
                                context: context,
                                isDark: isDark,
                                currentLang: currentLang,
                                initialDate: selectedDate,
                              );
                              if (picked != null) {
                                setStateDialog(() => selectedDate = picked);
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ClarifyButton(
                            icon: LucideIcons.clock,
                            label: selectedTime == null
                                ? "Время".tr(currentLang)
                                : selectedTime!.format(context),
                            variant: ClarifyButtonVariant.outline,
                            onPressed: () async {
                              final picked = await showClarifyTimePicker(
                                context: context,
                                isDark: isDark,
                                currentLang: currentLang,
                                initialTime: selectedTime ?? TimeOfDay.now(),
                              );
                              if (picked != null) {
                                setStateDialog(() => selectedTime = picked);
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    if (selectedTime != null) ...[
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 6, right: 8),
                            child: Icon(
                              LucideIcons.hourglass,
                              size: 16,
                              color: textMuted,
                            ),
                          ),
                          Expanded(
                            child: ClarifyDurationChips(
                              selectedMinutes: selectedDuration,
                              currentLang: currentLang,
                              isDark: isDark,
                              onChanged: (minutes) => setStateDialog(
                                () => selectedDuration = minutes,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (selectedDate != null)
                      Builder(
                        builder: (context) {
                          final total =
                              dayLoadMinutes(tasks, formatDate(selectedDate!)) +
                              (selectedTime != null
                                  ? (selectedDuration ?? 0)
                                  : 0);
                          if (total <= AppConfig.dailyLoadWarningMinutes) {
                            return const SizedBox.shrink();
                          }
                          return ClarifyDayLoadWarning(
                            totalMinutes: total,
                            currentLang: currentLang,
                          );
                        },
                      ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        ClarifyButton(
                          label: "+1 День".tr(currentLang),
                          variant: ClarifyButtonVariant.ghost,
                          onPressed: () =>
                              shiftDate(1, 0, setStateDialog, selectedDate),
                        ),
                        ClarifyButton(
                          label: "+1 Неделя".tr(currentLang),
                          variant: ClarifyButtonVariant.ghost,
                          onPressed: () =>
                              shiftDate(7, 0, setStateDialog, selectedDate),
                        ),
                        ClarifyButton(
                          label: "Убрать".tr(currentLang),
                          variant: ClarifyButtonVariant.danger,
                          onPressed: () => setStateDialog(() {
                            selectedDate = null;
                            selectedTime = null;
                            selectedDuration = null;
                          }),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(LucideIcons.repeat, size: 18, color: textMuted),
                        const SizedBox(width: 8),
                        DropdownButton<String>(
                          value: selectedRecurrence,
                          dropdownColor: t.surface2,
                          underline: const SizedBox(),
                          style: TextStyle(fontSize: 14, color: textColor),
                          items: [
                            DropdownMenuItem(
                              value: 'none',
                              child: Text(
                                "Без повтора".tr(currentLang),
                                style: TextStyle(color: textColor),
                              ),
                            ),
                            DropdownMenuItem(
                              value: 'daily',
                              child: Text(
                                "Каждый день".tr(currentLang),
                                style: TextStyle(color: textColor),
                              ),
                            ),
                            DropdownMenuItem(
                              value: 'weekdays',
                              child: Text(
                                "По будням".tr(currentLang),
                                style: TextStyle(color: textColor),
                              ),
                            ),
                            DropdownMenuItem(
                              value: 'weekly',
                              child: Text(
                                "Каждую неделю".tr(currentLang),
                                style: TextStyle(color: textColor),
                              ),
                            ),
                            DropdownMenuItem(
                              value: 'monthly',
                              child: Text(
                                "Каждый месяц".tr(currentLang),
                                style: TextStyle(color: textColor),
                              ),
                            ),
                            DropdownMenuItem(
                              value: 'custom',
                              child: Text(
                                "Кастомно".tr(currentLang),
                                style: TextStyle(color: textColor),
                              ),
                            ),
                          ],
                          onChanged: (val) =>
                              setStateDialog(() => selectedRecurrence = val!),
                        ),
                      ],
                    ),
                    if (selectedRecurrence == 'custom') ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const SizedBox(width: 26),
                          Text(
                            "Каждые".tr(currentLang),
                            style: TextStyle(color: textMuted, fontSize: 14),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 56,
                            child: ClarifyTextField(
                              controller: TextEditingController(
                                text: selectedRecurrenceInterval.toString(),
                              ),
                              keyboardType: TextInputType.number,
                              style: TextStyle(color: textColor),
                              textAlign: TextAlign.center,
                              dense: true,
                              onChanged: (val) => selectedRecurrenceInterval =
                                  int.tryParse(val) ?? 2,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            "дней".tr(currentLang),
                            style: TextStyle(color: textMuted, fontSize: 14),
                          ),
                        ],
                      ),
                    ],
                    // Отсчёт следующего повтора: от плана или от факта (C3).
                    // Показывается только когда повтор вообще включён — иначе
                    // это переключатель ни к чему.
                    if (selectedRecurrence != 'none') ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const SizedBox(width: 26),
                          Expanded(
                            child: Text(
                              "Считать от даты выполнения".tr(currentLang),
                              style: TextStyle(color: textMuted, fontSize: 13.5),
                            ),
                          ),
                          Switch(
                            value: recurrenceFromCompletion,
                            onChanged: (val) => setStateDialog(
                              () => recurrenceFromCompletion = val,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: t.surfaceSunken,
                  borderRadius: BorderRadius.circular(ClarifyRadius.md),
                  border: Border.all(color: t.border),
                ),
                child: Column(
                  children: [
                    TextField(
                      controller: tagsController,
                      style: TextStyle(color: textColor),
                      onChanged: (_) => setStateDialog(() {}),
                      decoration: InputDecoration(
                        labelText: "Теги (через запятую)".tr(currentLang),
                        labelStyle: TextStyle(color: textMuted),
                        border: InputBorder.none,
                        isDense: true,
                      ),
                    ),
                    if (tagSuggestions().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: tagSuggestions()
                              .map(
                                (tag) => ActionChip(
                                  label: Text(
                                    tag,
                                    style: TextStyle(
                                      color: textColor,
                                      fontSize: 12,
                                    ),
                                  ),
                                  backgroundColor: highlightColor,
                                  onPressed: () =>
                                      applyTagSuggestion(tag, setStateDialog),
                                ),
                              )
                              .toList(),
                        ),
                      ),
                    Divider(color: t.border, height: 1),
                    TextField(
                      controller: noteController,
                      style: TextStyle(color: textColor),
                      maxLines: 2,
                      decoration: InputDecoration(
                        labelText: "Заметка".tr(currentLang),
                        labelStyle: TextStyle(color: textMuted),
                        alignLabelWithHint: true,
                        border: InputBorder.none,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Divider(color: glassBorderColor),
              const SizedBox(height: 8),
              Text(
                "Чек-лист (Подзадачи):".tr(currentLang),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 8),
              if (tempSubtasks.isNotEmpty)
                Column(
                  children: tempSubtasks.asMap().entries.map((entry) {
                    int idx = entry.key;
                    String subTitle = entry.value;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: doneCardColor,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: glassBorderColor),
                      ),
                      child: Row(
                        children: [
                          Icon(LucideIcons.circle, size: 16, color: textMuted),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              subTitle,
                              style: TextStyle(color: textColor),
                            ),
                          ),
                          IconButton(
                            icon: Icon(
                              LucideIcons.x,
                              size: 16,
                              color: t.danger,
                            ),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            onPressed: () => setStateDialog(
                              () => tempSubtasks.removeAt(idx),
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: ClarifyTextField(
                      controller: subtaskController,
                      style: TextStyle(color: textColor),
                      hintText: "Добавить пункт...".tr(currentLang),
                      dense: true,
                      onSubmitted: (text) {
                        if (text.trim().isNotEmpty) {
                          setStateDialog(() {
                            tempSubtasks.add(text.trim());
                            subtaskController.clear();
                          });
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  IconButton(
                    style: IconButton.styleFrom(
                      backgroundColor: highlightColor,
                      padding: const EdgeInsets.all(12),
                    ),
                    icon: Icon(LucideIcons.plus, color: t.accent),
                    onPressed: () {
                      if (subtaskController.text.trim().isNotEmpty) {
                        setStateDialog(() {
                          tempSubtasks.add(subtaskController.text.trim());
                          subtaskController.clear();
                        });
                      }
                    },
                  ),
                ],
              ),

              // 🚀 ВЫБОР ИСПОЛНИТЕЛЯ ТЕПЕРЬ ПРАВИЛЬНО ВНУТРИ СПИСКА CHILDREN
              if (selectedMenu.startsWith('ws_')) ...[
                SizedBox(height: 12 * s),
                DropdownButtonFormField<String>(
                  dropdownColor: t.surface2,
                  decoration: InputDecoration(
                    labelText: "Назначить на...".tr(currentLang),
                    labelStyle: TextStyle(color: textMuted),
                    prefixIcon: Icon(
                      LucideIcons.user,
                      color: textMuted,
                      size: 20 * s,
                    ),
                    enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: glassBorderColor),
                    ),
                  ),
                  initialValue: selectedAssigneeId,
                  items: [
                    DropdownMenuItem(
                      value: null,
                      child: Text(
                        "Никто".tr(currentLang),
                        style: TextStyle(color: textColor),
                      ),
                    ),
                    ...(workspaceMembers[int.parse(
                              selectedMenu.substring(3),
                            )] ??
                            [])
                        .map(
                          (m) => DropdownMenuItem(
                            value: m['user_id'] as String,
                            child: Text(
                              m['full_name'] ?? 'Участник',
                              style: TextStyle(color: textColor),
                            ),
                          ),
                        ),
                  ],
                  onChanged: (val) =>
                      setStateDialog(() => selectedAssigneeId = val),
                ),
              ],

              const SizedBox(height: 24),

              // КНОПКИ ОТМЕНА И СОХРАНИТЬ
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  ClarifyButton(
                    label: "Отмена".tr(currentLang),
                    variant: ClarifyButtonVariant.ghost,
                    onPressed: () {
                      Navigator.pop(context);
                      if (isDuplicating) onDuplicateHandled();
                    },
                  ),
                  const SizedBox(width: 12),
                  ClarifyButton(
                    label: "Сохранить".tr(currentLang),
                    variant: ClarifyButtonVariant.filled,
                    loading: isSaving,
                    onPressed: () async {
                      if (titleController.text.trim().isEmpty) return;

                      setStateDialog(() => isSaving = true);

                      int? currentWorkspaceId;
                      if (selectedMenu.startsWith('ws_')) {
                        currentWorkspaceId = int.tryParse(
                          selectedMenu.substring(3),
                        );
                      }

                      // Запускаем фоновую анонимную функцию для создания главной задачи и ее подзадач
                      () async {
                        int? newTaskId = await createTaskManually({
                          "_source": "manual",
                          "title": titleController.text.trim(),
                          "due_date": selectedDate != null
                              ? formatDate(selectedDate!)
                              : null,
                          "due_time": selectedTime != null
                              ? "${selectedTime!.hour.toString().padLeft(2, '0')}:${selectedTime!.minute.toString().padLeft(2, '0')}"
                              : null,
                          "duration_minutes": selectedTime != null
                              ? selectedDuration
                              : null,
                          "note": noteController.text.trim().isNotEmpty
                              ? noteController.text.trim()
                              : null,
                          "priority": selectedPriority,
                          "tags": tagsController.text.trim().isNotEmpty
                              ? tagsController.text.trim()
                              : null,
                          "recurrence": selectedRecurrence == 'none'
                              ? null
                              : selectedRecurrence,
                          "recurrence_interval": selectedRecurrence == 'custom'
                              ? selectedRecurrenceInterval
                              : null,
                          "recurrence_from_completion":
                              selectedRecurrence != 'none' &&
                              recurrenceFromCompletion,
                          "is_completed": false,
                          "parent_id": null,
                          "workspace_id": currentWorkspaceId,
                          "assigned_to": selectedAssigneeId,
                        });

                        if (newTaskId != null && tempSubtasks.isNotEmpty) {
                          for (String subTitle in tempSubtasks) {
                            await createTaskManually({
                              "_source": "subtask",
                              "title": subTitle,
                              "parent_id": newTaskId,
                              "is_completed": false,
                            });
                          }
                        }
                      }(); // Круглые скобки в конце сразу запускают эту фоновую задачу

                      if (context.mounted) Navigator.pop(context);

                      if (selectedDate != null) {
                        checkBurnoutWarning(formatDate(selectedDate!));
                      }

                      if (isDuplicating) {
                        onDuplicateHandled();
                        if (context.mounted) {
                          ClarifyToast.show(
                            context,
                            "Задача скопирована!".tr(currentLang),
                            variant: ClarifyToastVariant.success,
                          );
                        }
                      }

                      if (context.mounted) {
                        setStateDialog(() => isSaving = false);
                      }
                    },
                  ),
                ],
              ),
            ],
          );

          if (isClarifyDialogMobile(context)) {
            // showClarifyBottomSheet сам не добавляет боковой/нижний отступ
            // контенту (глазурь/ручка — edge-to-edge), контент кладёт свой.
            return SingleChildScrollView(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  20,
                  4,
                  20,
                  MediaQuery.of(context).padding.bottom + 20,
                ),
                child: content,
              ),
            );
          }
          return Center(
            child: Material(
              color: Colors.transparent,
              child: buildGlassContainer(
                borderRadius: ClarifyRadius.dialogShell,
                padding: const EdgeInsets.all(24),
                child: SizedBox(
                  width: (MediaQuery.sizeOf(context).width - 80).clamp(
                    280.0,
                    450.0,
                  ),
                  child: SingleChildScrollView(child: content),
                ),
              ),
            ),
          );
        },
      );
    },
  );
}
