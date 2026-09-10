import 'package:flutter/material.dart';
import '../widgets/clarify_button.dart';
import '../widgets/clarify_glass.dart';
import '../widgets/clarify_surface.dart';
import '../widgets/clarify_toast.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../core/localization.dart';
import '../core/theme/design_tokens.dart';
import '../core/log.dart';

/// Диалоги управления проектами (папками) и командами (воркспейсами).
/// Вынесено из DesktopPlannerScreen (P3.1, docs/IMPROVEMENT_PLAN.md) — логика
/// и разметка не менялись, только доступ к состоянию родителя заменён на
/// явные параметры функций.

void showCreateWorkspaceDialog({
  required BuildContext context,
  required bool isDark,
  required double scale,
  required Color textColor,
  required Color textMuted,
  required Color glassBorderColor,
  required String currentLang,
  required Future<void> Function() onWorkspaceCreated,
}) {
  final ctrl = TextEditingController();
  bool isCreating = false;

  showClarifySurface(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.4),
    builder: (context) => StatefulBuilder(builder: (context, setStateDialog) {
      return Center(
        child: Material(
          color: Colors.transparent,
          child: ClarifyGlass(
            borderRadius: ClarifyRadius.dialogShell,
            padding: const EdgeInsets.all(24),
            child: SizedBox(
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Новая команда".tr(currentLang), style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 18)),
                  const SizedBox(height: 16),
                  TextField(
                    controller: ctrl,
                    style: TextStyle(color: textColor),
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: "Название (например, Альфа-Проект)".tr(currentLang),
                      hintStyle: TextStyle(color: textMuted),
                      enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: glassBorderColor)),
                    ),
                  ),
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
                        label: "Создать".tr(currentLang),
                        variant: ClarifyButtonVariant.filled,
                        loading: isCreating,
                        onPressed: () async {
                          if (ctrl.text.trim().isEmpty) return;
                          setStateDialog(() => isCreating = true);

                          final user = Supabase.instance.client.auth.currentUser;
                          try {
                            // 1. Создаем воркспейс
                            final newWorkspace = await Supabase.instance.client
                                .from('workspaces')
                                .insert({
                                  'name': ctrl.text.trim(),
                                  'owner_id': user!.id,
                                })
                                .select()
                                .single();

                            // 2. Добавляем себя как владельца
                            await Supabase.instance.client
                                .from('workspace_members')
                                .insert({
                                  'workspace_id': newWorkspace['id'],
                                  'user_id': user.id,
                                  'role': 'owner',
                                });

                            await onWorkspaceCreated(); // Обновляем список команд
                            if (context.mounted) Navigator.pop(context);
                          } catch (e) {
                            logError("Ошибка создания команды: $e");
                            if (context.mounted) setStateDialog(() => isCreating = false);
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }),
  );
}

void showInviteMemberDialog({
  required BuildContext context,
  required int workspaceId,
  required bool isDark,
  required double scale,
  required Color textColor,
  required Color textMuted,
  required Color glassBorderColor,
  required String currentLang,
}) {
  final codeCtrl = TextEditingController();
  bool isSending = false;
  final s = scale;

  showClarifySurface(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.4),
    builder: (context) => StatefulBuilder(builder: (context, setStateDialog) {
      return Center(
        child: Material(
          color: Colors.transparent,
          child: ClarifyGlass(
            borderRadius: ClarifyRadius.dialogShell,
            padding: const EdgeInsets.all(24),
            child: SizedBox(
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Пригласить коллегу".tr(currentLang), style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 18)),
                  const SizedBox(height: 16),
                  Text("Введите код друга пользователя. Найти его можно в профиле пользователя в Clarify.".tr(currentLang), style: TextStyle(color: textMuted, fontSize: 13 * s)),
                  SizedBox(height: 16 * s),
                  TextField(
                    controller: codeCtrl,
                    style: TextStyle(color: textColor),
                    autofocus: true,
                    textCapitalization: TextCapitalization.characters,
                    decoration: InputDecoration(
                      hintText: "Например, AB12CD".tr(currentLang),
                      hintStyle: TextStyle(color: textMuted),
                      enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: glassBorderColor)),
                    ),
                  ),
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
                        label: "Пригласить".tr(currentLang),
                        variant: ClarifyButtonVariant.filled,
                        loading: isSending,
                        onPressed: () async {
                          if (codeCtrl.text.trim().isEmpty) return;

                          setStateDialog(() => isSending = true);

                          try {
                            // Вызываем нашу SQL функцию через RPC
                            final response = await Supabase.instance.client.rpc(
                              'invite_user_by_code',
                              params: {
                                'target_code': codeCtrl.text.trim(),
                                'ws_id': workspaceId,
                              },
                            );

                            if (context.mounted) {
                              Navigator.pop(context);
                              // Показываем ответ от базы данных (Успех или Ошибка)
                              ClarifyToast.show(
                                context,
                                response.toString(),
                                variant: response.toString().startsWith('Успех') ? ClarifyToastVariant.success : ClarifyToastVariant.danger,
                              );
                            }
                          } catch (e) {
                            logError("Ошибка приглашения: $e");
                            if (context.mounted) {
                              ClarifyToast.show(context, '${'Ошибка сети: '.tr(currentLang)}$e', variant: ClarifyToastVariant.danger);
                              setStateDialog(() => isSending = false);
                            }
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }),
  );
}

/// Удаление всей команды (владелец/admin) или выход из неё (остальные участники)
/// — см. REDESIGN_V3_PLAN.md §3.12/5.12. RPC-функции определены в
/// `backend/clarify-backend/sql/workspace_delete_leave.sql` (применяются вручную
/// через Supabase SQL Editor — в репозитории нет системы миграций Supabase).
void showLeaveOrDeleteWorkspaceDialog({
  required BuildContext context,
  required int workspaceId,
  required bool canDelete,
  required Color textColor,
  required Color textMuted,
  required String currentLang,
  required Future<void> Function() onDone,
}) {
  bool isLoading = false;

  showClarifySurface(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.4),
    builder: (context) => StatefulBuilder(builder: (context, setStateDialog) {
      return Center(
        child: Material(
          color: Colors.transparent,
          child: ClarifyGlass(
            borderRadius: ClarifyRadius.dialogShell,
            padding: const EdgeInsets.all(24),
            child: SizedBox(
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    canDelete ? "Удалить команду?".tr(currentLang) : "Выйти из команды?".tr(currentLang),
                    style: TextStyle(color: textColor, fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    canDelete
                        ? "Команда и все её задачи будут удалены безвозвратно.".tr(currentLang)
                        : "Вы потеряете доступ к задачам и участникам этой команды.".tr(currentLang),
                    style: TextStyle(color: textMuted, fontSize: 14),
                  ),
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
                        label: canDelete ? "Удалить".tr(currentLang) : "Выйти".tr(currentLang),
                        variant: ClarifyButtonVariant.danger,
                        loading: isLoading,
                        onPressed: () async {
                          setStateDialog(() => isLoading = true);
                          try {
                            final response = await Supabase.instance.client.rpc(
                              canDelete ? 'delete_workspace' : 'leave_workspace',
                              params: {'ws_id': workspaceId},
                            );
                            if (context.mounted) Navigator.pop(context);
                            await onDone();
                            if (context.mounted) {
                              ClarifyToast.show(
                                context,
                                response.toString(),
                                variant: response.toString().startsWith('Успех') ? ClarifyToastVariant.success : ClarifyToastVariant.danger,
                              );
                            }
                          } catch (e) {
                            logError("Ошибка удаления/выхода из команды: $e");
                            if (context.mounted) {
                              ClarifyToast.show(context, '${'Ошибка сети: '.tr(currentLang)}$e', variant: ClarifyToastVariant.danger);
                              setStateDialog(() => isLoading = false);
                            }
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }),
  );
}
