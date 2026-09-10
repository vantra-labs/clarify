import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../services/attachment_service.dart';
import '../widgets/clarify_attachments.dart';
import '../widgets/clarify_duration_chips.dart';
import '../widgets/clarify_surface.dart';
import '../widgets/clarify_task_checkbox.dart';
import '../widgets/clarify_text_field.dart';
import '../widgets/clarify_toast.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../core/localization.dart';
import '../core/theme/design_tokens.dart';
import '../core/log.dart';

/// Диалог деталей задачи: чек-лист подзадач + обсуждение (комментарии).
/// Вынесено из DesktopPlannerScreen (P3.1, docs/IMPROVEMENT_PLAN.md) —
/// логика и разметка не менялись, только доступ к состоянию родителя
/// заменён на явные параметры функции.
void showTaskDetailsDialog({
  required BuildContext context,
  required Map<String, dynamic> task,
  required bool isDark,
  required Color textColor,
  required Color textMuted,
  required Color glassColor,
  required Color glassBorderColor,
  required Color cardColor,
  required Color doneCardColor,
  required Color highlightColor,
  required String currentLang,
  required List<Map<String, dynamic>> tasks,
  required Map<int, List<Map<String, dynamic>>> workspaceMembers,
  required Color Function(String? priority) getPriorityColor,
  required Future<void> Function(Map<String, dynamic> task) onToggleTask,
  required Future<void> Function(dynamic taskId) onDeleteTask,
  required void Function(String tag) onTagTap,
  required void Function(Map<String, dynamic> task) onDuplicate,
  required void Function(Map<String, dynamic> task) onEdit,
  required Widget Function({
    required Widget child,
    BorderRadius? borderRadius,
    EdgeInsetsGeometry? padding,
    EdgeInsetsGeometry? margin,
    Color? customColor,
  }) buildGlassContainer,
}) {
  final t = context.tokens;
  // Контроллер для чата
  final TextEditingController commentController = TextEditingController();
  List<Map<String, dynamic>> comments = [];
  bool isCommentsLoaded = false;

  showClarifyResponsiveSurface(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.4),
    builder: (context) {
      return StatefulBuilder(builder: (context, setStateDialog) {

        // Загружаем комментарии (чат) — только для командных задач, для
        // соло-задач обсуждение не имеет смысла и не показывается вовсе.
        if (!isCommentsLoaded && task['workspace_id'] != null) {
          isCommentsLoaded = true;
          Supabase.instance.client
              .from('task_comments')
              .select()
              .eq('task_id', task['id'])
              .order('created_at', ascending: true)
              .then((data) {
            if (context.mounted) {
              setStateDialog(() {
                comments = List<Map<String, dynamic>>.from(data);
              });
            }
          });
        }

        // Вычисляем подзадачи (чек-лист)
        final subtasks = tasks.where((t) => t['parent_id'] == task['id']).toList();

        final content = Column(
                    mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text("Детали задачи".tr(currentLang), style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: textMuted, letterSpacing: 1.2)),
                          IconButton(icon: Icon(LucideIcons.x, color: textMuted), padding: EdgeInsets.zero, constraints: const BoxConstraints(), onPressed: () => Navigator.pop(context))
                        ]
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          if (task['priority'] != null && task['priority'] != 'none') Container(margin: const EdgeInsets.only(right: 12), width: 14, height: 14, decoration: BoxDecoration(shape: BoxShape.circle, color: getPriorityColor(task['priority']), boxShadow: [BoxShadow(color: getPriorityColor(task['priority']).withValues(alpha: 0.5), blurRadius: 8)])),
                          Expanded(child: Text(task['title'] ?? '', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: textColor))),
                        ],
                      ),
                      if (task['tags'] != null && task['tags'].toString().trim().isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          children: task['tags'].toString().split(',').map((tag) => GestureDetector(onTap: () { Navigator.pop(context); onTagTap(tag.trim()); }, child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), decoration: BoxDecoration(color: highlightColor, borderRadius: BorderRadius.circular(16), border: Border.all(color: t.accent.withValues(alpha: 0.4))), child: Text("#${tag.trim()}", style: TextStyle(fontSize: 13, color: t.accent, fontWeight: FontWeight.bold))), )).toList(),
                        )
                      ],
                      const SizedBox(height: 24),
                      // Сгруппированная карточка метаданных — тот же рецепт
                      // (surfaceSunken/ClarifyRadius.md/border), что и в
                      // edit_task_dialog/manual_add_dialog, для единого стиля
                      // всех диалогов задачи.
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(color: t.surfaceSunken, borderRadius: BorderRadius.circular(ClarifyRadius.md), border: Border.all(color: t.border)),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: t.accentSoft, borderRadius: BorderRadius.circular(8)), child: Icon(LucideIcons.calendarDays, color: t.accent, size: 20)),
                                const SizedBox(width: 12),
                                Expanded(child: Text("${task['due_date'] ?? 'Входящие (Без даты)'.tr(currentLang)}  •  ${task['due_time'] ?? 'Весь день'.tr(currentLang)}${task['due_time'] != null && task['duration_minutes'] != null ? ' (${formatDurationMinutes(task['duration_minutes'] as int, currentLang)})' : ''}", style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: textColor))),
                                if (task['recurrence'] != null && task['recurrence'] != 'none') ...[SizedBox(width: 12), Icon(LucideIcons.repeat, size: 18, color: t.text3)]
                              ],
                            ),
                            // ИСПОЛНИТЕЛЬ
                            if (task['assigned_to'] != null) ...[
                              Divider(color: t.border, height: 24),
                              Row(
                                children: [
                                  Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: t.accentSoft, borderRadius: BorderRadius.circular(8)), child: Icon(LucideIcons.user, color: t.accent, size: 20)),
                                  const SizedBox(width: 12),
                                  Expanded(child: Builder(builder: (context) {
                                    var members = workspaceMembers[task['workspace_id']] ?? [];
                                    var member = members.firstWhere((m) => m['user_id'] == task['assigned_to'], orElse: () => <String, dynamic>{});
                                    String name = member.isNotEmpty ? (member['full_name'] ?? 'Участник'.tr(currentLang)) : 'Неизвестно'.tr(currentLang);
                                    return Text("${'Исполнитель: '.tr(currentLang)}$name", style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: textColor));
                                  })),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),

                      if (task['note'] != null && task['note'].toString().isNotEmpty) ...[
                        const SizedBox(height: 24),
                        Container(
                          width: double.infinity, padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(color: doneCardColor, borderRadius: BorderRadius.circular(12), border: Border.all(color: glassBorderColor)),
                          child: MarkdownBody(
                            data: task['note'],
                            styleSheet: MarkdownStyleSheet(
                              p: TextStyle(color: textColor, fontSize: 15, height: 1.5),
                              strong: TextStyle(color: textColor, fontWeight: FontWeight.bold),
                              em: TextStyle(color: textColor, fontStyle: FontStyle.italic),
                              listBullet: TextStyle(color: t.accent),
                            )
                          )
                        ),
                      ],
                      // ВЛОЖЕНИЯ — только просмотр и открытие. Прикладывать и
                      // убирать файлы, как и добавлять пункты чек-листа, можно
                      // в окне редактирования: здесь окно деталей.
                      // Раздел сам прячется, если вложений нет. Временный
                      // (отрицательный) номер только что созданной задачи
                      // пропускаем — вложений у неё быть ещё не может.
                      if (task['id'] is int && (task['id'] as int) > 0) ...[
                        const SizedBox(height: 24),
                        ClarifyAttachments(
                          owner: AttachmentOwner.task(task['id'] as int),
                          currentLang: currentLang,
                        ),
                      ],

                      const SizedBox(height: 32), Divider(color: glassBorderColor), const SizedBox(height: 16),

                      // ЧЕК-ЛИСТ (ПОДЗАДАЧИ)
                      Row(
                        children: [
                          Icon(LucideIcons.listChecks, color: t.accent), const SizedBox(width: 8),
                          Text("Чек-лист".tr(currentLang), style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: textColor)), const Spacer(),
                          if (subtasks.isNotEmpty) Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), decoration: BoxDecoration(color: glassColor, borderRadius: BorderRadius.circular(12)), child: Text("${subtasks.where((t) => t['is_completed'] == true).length} ${'из'.tr(currentLang)} ${subtasks.length}", style: TextStyle(color: textMuted, fontWeight: FontWeight.bold))),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (subtasks.isNotEmpty)
                        Column(
                          children: subtasks.map((subtask) {
                            bool isSubDone = subtask['is_completed'] == true;
                            return Container(
                              margin: const EdgeInsets.only(bottom: 8), padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), decoration: BoxDecoration(color: isSubDone ? doneCardColor : cardColor, borderRadius: BorderRadius.circular(12), border: Border.all(color: glassBorderColor)),
                              child: Row(
                                children: [
                                  ClarifyCheckCircle(value: isSubDone, borderColor: glassBorderColor, checkedColor: t.accent, onTap: () async { await onToggleTask(subtask); setStateDialog(() {}); }),
                                  const SizedBox(width: 10),
                                  Expanded(child: ClarifyStrikeText(text: subtask['title'], isDone: isSubDone, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, color: isSubDone ? textMuted : textColor))),
                                  const SizedBox(width: 4),
                                  IconButton(icon: Icon(LucideIcons.x, size: 18, color: t.danger), onPressed: () async { await onDeleteTask(subtask['id']); setStateDialog(() {}); })
                                ],
                              ),
                            );
                          }).toList(),
                        ),
                      // Добавление НОВЫХ пунктов чек-листа — только в окне
                      // редактирования, по прямому запросу; здесь (окно
                      // деталей) остаётся только просмотр/отметка/удаление
                      // уже существующих пунктов.

                      // ЧАТ (ОБСУЖДЕНИЕ) — только для задач команды, для
                      // соло-задач раздел не имеет смысла (не с кем обсуждать).
                      if (task['workspace_id'] != null) ...[
                      const SizedBox(height: 32),
                      Divider(color: glassBorderColor),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Icon(LucideIcons.messageCircle, color: t.accent),
                          const SizedBox(width: 8),
                          Text("Обсуждение".tr(currentLang), style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: textColor)),
                        ],
                      ),
                      const SizedBox(height: 16),

                      if (comments.isNotEmpty)
                        Container(
                          constraints: const BoxConstraints(maxHeight: 250),
                          margin: const EdgeInsets.only(bottom: 16),
                          child: SingleChildScrollView(
                            child: Column(
                              children: comments.map((c) {
                                bool isMyComment = c['user_id'] == Supabase.instance.client.auth.currentUser?.id;
                                String authorName = "Пользователь";
                                String initial = "?";
                                if (task['workspace_id'] != null) {
                                  var members = workspaceMembers[task['workspace_id']] ?? [];
                                  var member = members.firstWhere((m) => m['user_id'] == c['user_id'], orElse: () => <String, dynamic>{});
                                  if (member.isNotEmpty) {
                                    authorName = member['full_name'] ?? authorName;
                                    initial = authorName[0].toUpperCase();
                                  }
                                } else if (isMyComment) {
                                  authorName = "Я";
                                  initial = "Я";
                                }

                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisAlignment: isMyComment ? MainAxisAlignment.end : MainAxisAlignment.start,
                                    children: [
                                      if (!isMyComment)
                                        Padding(
                                          padding: const EdgeInsets.only(right: 8),
                                          child: CircleAvatar(radius: 14, backgroundColor: t.tagPalette[7], child: Text(initial, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold))),
                                        ),

                                      Flexible(
                                        child: Container(
                                          padding: const EdgeInsets.all(12),
                                          decoration: BoxDecoration(
                                            color: isMyComment ? t.accentSoft : glassColor,
                                            borderRadius: BorderRadius.circular(12).copyWith(
                                              topLeft: !isMyComment ? const Radius.circular(0) : const Radius.circular(12),
                                              topRight: isMyComment ? const Radius.circular(0) : const Radius.circular(12),
                                            ),
                                            border: Border.all(color: isMyComment ? t.accent.withValues(alpha: 0.3) : glassBorderColor)
                                          ),
                                          child: Column(
                                            crossAxisAlignment: isMyComment ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                            children: [
                                              Text(authorName, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isMyComment ? t.accent : textMuted)),
                                              const SizedBox(height: 4),
                                              Text(c['text'] ?? '', style: TextStyle(fontSize: 14, color: textColor)),
                                            ],
                                          ),
                                        ),
                                      ),

                                      if (isMyComment)
                                        Padding(
                                          padding: const EdgeInsets.only(left: 8),
                                          child: CircleAvatar(radius: 14, backgroundColor: t.accent, child: Text(initial, style: TextStyle(color: t.onAccent, fontSize: 12, fontWeight: FontWeight.bold))),
                                        ),
                                    ],
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                        ),

                      Row(
                        children: [
                          Expanded(
                            child: ClarifyTextField(
                              controller: commentController,
                              style: TextStyle(color: textColor),
                              hintText: "Написать комментарий...".tr(currentLang),
                              dense: true,
                              onSubmitted: (text) async {
                                if (commentController.text.trim().isEmpty) return;
                                final submittedText = commentController.text.trim();
                                commentController.clear();

                                final user = Supabase.instance.client.auth.currentUser;
                                if (user == null) return;

                                final newComment = {
                                  'task_id': task['id'],
                                  'user_id': user.id,
                                  'text': submittedText,
                                };

                                setStateDialog(() {
                                  comments.add({...newComment, 'created_at': DateTime.now().toIso8601String()});
                                });

                                try {
                                  await Supabase.instance.client.from('task_comments').insert(newComment);
                                } catch (e) {
                                  logError("Ошибка отправки комментария: $e");
                                }
                              }
                            )
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            style: IconButton.styleFrom(backgroundColor: t.accent, padding: const EdgeInsets.all(12)),
                            icon: Icon(LucideIcons.send, color: t.onAccent, size: 20),
                            onPressed: () async {
                              if (commentController.text.trim().isEmpty) return;
                              final text = commentController.text.trim();
                              commentController.clear();

                              final user = Supabase.instance.client.auth.currentUser;
                              if (user == null) return;

                              final newComment = {
                                'task_id': task['id'],
                                'user_id': user.id,
                                'text': text,
                              };

                              setStateDialog(() {
                                comments.add({...newComment, 'created_at': DateTime.now().toIso8601String()});
                              });

                              try {
                                await Supabase.instance.client.from('task_comments').insert(newComment);
                              } catch (e) {
                                logError("Ошибка отправки комментария: $e");
                              }
                            }
                          )
                        ],
                      ),
                      ], // конец блока "Обсуждение" (только для командных задач)

                      // КНОПКИ УПРАВЛЕНИЯ ЗАДАЧЕЙ — второстепенные действия
                      // (удалить/дублировать) сведены к иконкам, чтобы ряд
                      // гарантированно помещался в одну строку на узких
                      // экранах; единственная подписанная кнопка — основное
                      // действие "Изменить".
                      const SizedBox(height: 32),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Tooltip(
                                message: "Удалить".tr(currentLang),
                                child: IconButton(
                                  style: IconButton.styleFrom(backgroundColor: t.dangerSoft),
                                  icon: Icon(LucideIcons.trash2, color: t.danger, size: 20),
                                  onPressed: () { Navigator.of(context).pop(); onDeleteTask(task['id']); },
                                ),
                              ),
                              const SizedBox(width: 8),
                              Tooltip(
                                message: "Дублировать".tr(currentLang),
                                child: IconButton(
                                  style: IconButton.styleFrom(backgroundColor: highlightColor),
                                  icon: Icon(LucideIcons.copy, color: t.accent, size: 20),
                                  onPressed: () {
                                    if (isClarifyDialogMobile(context)) {
                                      // Мобильный: сразу открываем предзаполненное окно
                                      // добавления — закрыть текущий диалог нужно ДО
                                      // вызова onDuplicate (тот сам откроет новый),
                                      // иначе последующий pop() случайно закроет уже
                                      // новое окно вместо этого (см. паттерн "Изменить" выше).
                                      ClarifySurfaceTransitionOut.markCollapseOnClose(context);
                                      Navigator.of(context).pop();
                                      onDuplicate(task);
                                    } else {
                                      onDuplicate(task);
                                      Navigator.of(context).pop();
                                      ClarifyToast.show(context, "Кликни на плюсик любого дня".tr(currentLang), variant: ClarifyToastVariant.info);
                                    }
                                  },
                                ),
                              ),
                            ],
                          ),
                          ElevatedButton.icon(style: ElevatedButton.styleFrom(backgroundColor: t.accent, foregroundColor: t.onAccent, padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))), icon: const Icon(LucideIcons.pencil, size: 18), label: Text("Изменить".tr(currentLang), style: TextStyle(fontWeight: FontWeight.bold)), onPressed: () { ClarifySurfaceTransitionOut.markCollapseOnClose(context); Navigator.of(context).pop(); onEdit(task); }),
                        ],
                      )
                    ],
                  );

        // Мобильный — bottom sheet (showClarifyResponsiveSurface уже даёт
        // форму/ширину/drag-to-dismiss), десктоп — прежняя карточка по центру.
        if (isClarifyDialogMobile(context)) {
          // showClarifyBottomSheet сам не добавляет боковой/нижний отступ
          // контенту (глазурь/ручка — edge-to-edge), контент кладёт свой.
          return SingleChildScrollView(
            child: Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, MediaQuery.of(context).padding.bottom + 20),
              child: content,
            ),
          );
        }
        return Center(
          child: Material(
            color: Colors.transparent,
            child: buildGlassContainer(
              borderRadius: ClarifyRadius.dialogShell,
              padding: const EdgeInsets.all(32),
              child: SizedBox(
                width: (MediaQuery.sizeOf(context).width - 96).clamp(280.0, 450.0),
                child: SingleChildScrollView(child: content),
              ),
            ),
          ),
        );
      });
    }
  );
}
