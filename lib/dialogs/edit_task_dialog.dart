import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../services/attachment_service.dart';
import '../widgets/clarify_attachments.dart';
import '../widgets/clarify_button.dart';
import '../widgets/clarify_day_load_warning.dart';
import '../widgets/clarify_duration_chips.dart';
import '../widgets/clarify_priority_lever.dart';
import '../widgets/clarify_surface.dart';
import '../widgets/clarify_toast.dart';
import '../widgets/clarify_date_time_picker.dart';
import '../core/clarify_date_format.dart';
import '../core/config.dart';
import '../widgets/clarify_text_field.dart';
import '../core/localization.dart';
import '../core/tags.dart';
import '../core/priority.dart';
import '../core/checklist.dart';
import '../core/theme/design_tokens.dart';

/// Диалог редактирования существующей задачи. Вынесено из
/// DesktopPlannerScreen (P3.1, docs/IMPROVEMENT_PLAN.md) — логика и разметка
/// не менялись (кроме текста лимита — см. ниже), только доступ к состоянию
/// родителя заменён на явные параметры функции.
void showEditTaskDialog({
  required BuildContext context,
  required Map<String, dynamic> task,
  required bool isDark,
  required Color textColor,
  required Color textMuted,
  required Color glassBorderColor,
  required String currentLang,
  required List<Map<String, dynamic>> tasks,
  required Map<int, List<Map<String, dynamic>>> workspaceMembers,
  required Future<void> Function(dynamic taskId, Map<String, dynamic> taskData)
  updateTaskData,
  required Color Function(String? priority) getPriorityColor,
  required String Function(DateTime date) formatDate,
  required DateTime? Function(String dateStr) parseDate,
  required Widget Function({
    required Widget child,
    BorderRadius? borderRadius,
    EdgeInsetsGeometry? padding,
    EdgeInsetsGeometry? margin,
    Color? customColor,
  })
  buildGlassContainer,
}) {
  final t = context.tokens;
  final TextEditingController titleController = TextEditingController(
    text: task['title'],
  );
  final TextEditingController noteController = TextEditingController(
    text: task['note'] ?? '',
  );
  final TextEditingController tagsController = TextEditingController(
    text: task['tags'] ?? '',
  );
  final TextEditingController checklistInputController =
      TextEditingController();
  List<ChecklistItem> checklistItems = parseChecklist(task['checklist']);
  String selectedPriority = task['priority'] ?? 'none';
  String selectedRecurrence = task['recurrence'] ?? 'none';
  int selectedRecurrenceInterval = (task['recurrence_interval'] as int?) ?? 2;
  // Повтор от даты выполнения, а не от плановой (C3).
  bool recurrenceFromCompletion = task['recurrence_from_completion'] == true;
  String? selectedAssigneeId = task['assigned_to'];
  DateTime? selectedDate = task['due_date'] != null
      ? parseDate(task['due_date'])
      : null;
  TimeOfDay? selectedTime;
  int? selectedDuration = task['duration_minutes'] as int?;
  if (task['due_time'] != null && task['due_time'].toString().contains(':')) {
    final parts = task['due_time'].split(':');
    selectedTime = TimeOfDay(
      hour: int.parse(parts[0]),
      minute: int.parse(parts[1]),
    );
  }
  void localShiftDate(int days, int months, StateSetter setStateDialog) {
    DateTime baseDate = selectedDate ?? DateTime.now();
    setStateDialog(
      () => selectedDate = DateTime(
        baseDate.year,
        baseDate.month + months,
        baseDate.day + days,
      ),
    );
  }

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

  bool isSaving = false;

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
                    "Редактировать".tr(currentLang),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 20,
                      color: textColor,
                    ),
                  ),
                  IconButton(
                    icon: Icon(LucideIcons.x, color: textMuted),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              ClarifyTextField(
                controller: titleController,
                style: TextStyle(color: textColor, fontSize: 16),
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
                              dayLoadMinutes(
                                tasks,
                                formatDate(selectedDate!),
                                excludeTaskId: task['id'] as int?,
                              ) +
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
                          onPressed: () => localShiftDate(1, 0, setStateDialog),
                        ),
                        ClarifyButton(
                          label: "+1 Неделя".tr(currentLang),
                          variant: ClarifyButtonVariant.ghost,
                          onPressed: () => localShiftDate(7, 0, setStateDialog),
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
                        labelText: "Теги".tr(currentLang),
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
                                  backgroundColor: t.accentSoft,
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
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          "Чек-лист".tr(currentLang),
                          style: TextStyle(color: textMuted, fontSize: 14),
                        ),
                        if (checklistItems.isNotEmpty)
                          Text(
                            '${checklistItems.where((e) => e.done).length}/${checklistItems.length}',
                            style: TextStyle(color: textMuted, fontSize: 13),
                          ),
                      ],
                    ),
                    if (checklistItems.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value:
                              checklistItems.where((e) => e.done).length /
                              checklistItems.length,
                          backgroundColor: t.border,
                          color: t.accent,
                          minHeight: 4,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...checklistItems.map((item) {
                        final index = checklistItems.indexOf(item);
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            children: [
                              GestureDetector(
                                onTap: () => setStateDialog(
                                  () => checklistItems[index] = ChecklistItem(
                                    text: item.text,
                                    done: !item.done,
                                  ),
                                ),
                                child: Icon(
                                  item.done
                                      ? LucideIcons.checkSquare
                                      : LucideIcons.square,
                                  size: 18,
                                  color: item.done ? t.accent : textMuted,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  item.text,
                                  style: TextStyle(
                                    color: item.done ? textMuted : textColor,
                                    decoration: item.done
                                        ? TextDecoration.lineThrough
                                        : TextDecoration.none,
                                  ),
                                ),
                              ),
                              IconButton(
                                icon: Icon(
                                  LucideIcons.x,
                                  size: 16,
                                  color: textMuted,
                                ),
                                constraints: const BoxConstraints(),
                                padding: EdgeInsets.zero,
                                onPressed: () => setStateDialog(
                                  () => checklistItems.removeAt(index),
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: checklistInputController,
                            style: TextStyle(color: textColor, fontSize: 14),
                            decoration: InputDecoration(
                              hintText: "Добавить пункт".tr(currentLang),
                              hintStyle: TextStyle(color: textMuted),
                              border: InputBorder.none,
                              isDense: true,
                            ),
                            onSubmitted: (val) {
                              final text = val.trim();
                              if (text.isEmpty) return;
                              setStateDialog(() {
                                checklistItems.add(
                                  ChecklistItem(text: text, done: false),
                                );
                                checklistInputController.clear();
                              });
                            },
                          ),
                        ),
                        IconButton(
                          icon: Icon(
                            LucideIcons.plus,
                            size: 18,
                            color: t.accent,
                          ),
                          onPressed: () {
                            final text = checklistInputController.text.trim();
                            if (text.isEmpty) return;
                            setStateDialog(() {
                              checklistItems.add(
                                ChecklistItem(text: text, done: false),
                              );
                              checklistInputController.clear();
                            });
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // ВЛОЖЕНИЯ. Сохраняются сразу, а не по кнопке «Сохранить»: файл
              // уже уехал в хранилище, и делать вид, что «Отмена» его вернёт,
              // нечестно. Зато приложенное видно мгновенно, а лишнее снимается
              // крестиком на плитке.
              //
              // Только у задачи с настоящим номером: у только что созданной он
              // временный и отрицательный, пока не ответил сервер (см.
              // TaskService.addTask), и вложение привязывать не к чему —
              // получился бы отказ базы вместо файла.
              if (task['id'] is int && (task['id'] as int) > 0) ...[
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: t.surfaceSunken,
                    borderRadius: BorderRadius.circular(ClarifyRadius.md),
                    border: Border.all(color: t.border),
                  ),
                  child: ClarifyAttachments(
                    owner: AttachmentOwner.task(task['id'] as int),
                    currentLang: currentLang,
                    canEdit: true,
                  ),
                ),
              ],

              if (task['workspace_id'] != null) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  dropdownColor: t.surface2,
                  decoration: InputDecoration(
                    labelText: "Назначить на...".tr(currentLang),
                    labelStyle: TextStyle(color: textMuted),
                    prefixIcon: Icon(
                      LucideIcons.user,
                      color: t.accent,
                      size: 20,
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
                    ...(workspaceMembers[task['workspace_id']] ?? []).map(
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
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  ClarifyButton(
                    label: "Отмена".tr(currentLang),
                    variant: ClarifyButtonVariant.ghost,
                    onPressed: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 12),
                  ClarifyButton(
                    label: "Сохранить".tr(currentLang),
                    variant: ClarifyButtonVariant.filled,
                    loading: isSaving,
                    onPressed: () async {
                      if (titleController.text.trim().isEmpty) return;

                      setStateDialog(() => isSaving = true);

                      final newDateStr = selectedDate != null
                          ? formatDate(selectedDate!)
                          : null;

                      // Перенос вперёд на невыполненной задаче — считаем как
                      // "перенос" (см. clarify_day_load_warning.dart doc и
                      // AppConfig.rescheduleWarningCount); перенос НАЗАД (или
                      // вперёд на уже выполненной задаче) не считается.
                      int newRescheduleCount =
                          (task['reschedule_count'] as int?) ?? 0;
                      if (task['is_completed'] != true &&
                          newDateStr != null &&
                          newDateStr != task['due_date']) {
                        final oldDate = parseClarifyDate(task['due_date']);
                        final newDate = parseClarifyDate(newDateStr);
                        if (oldDate != null &&
                            newDate != null &&
                            newDate.isAfter(oldDate)) {
                          newRescheduleCount += 1;
                        }
                      }

                      if (newDateStr != null &&
                          newDateStr != task['due_date']) {
                        final dayCount = tasks
                            .where(
                              (t) =>
                                  t['due_date'] == newDateStr &&
                                  t['parent_id'] == null,
                            )
                            .length;
                        if (dayCount >= AppConfig.dailyTaskLimit) {
                          ClarifyToast.show(
                            context,
                            "${'Достигнут лимит ('.tr(currentLang)}${AppConfig.dailyTaskLimit}${') на день!'.tr(currentLang)}",
                            variant: ClarifyToastVariant.danger,
                          );
                          setStateDialog(() => isSaving = false);
                          return;
                        }
                      }

                      await updateTaskData(task['id'], {
                        "title": titleController.text.trim(),
                        "due_date": newDateStr,
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
                        "is_completed": task['is_completed'] ?? false,
                        "parent_id": task['parent_id'],
                        "assigned_to": selectedAssigneeId,
                        "checklist": checklistItems.isEmpty
                            ? null
                            : encodeChecklist(checklistItems),
                        "reschedule_count": newRescheduleCount,
                      });

                      if (context.mounted) Navigator.of(context).pop();
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
