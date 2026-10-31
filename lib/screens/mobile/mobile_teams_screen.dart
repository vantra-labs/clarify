import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../core/features.dart';
import '../../core/localization.dart';
import '../../core/task_sort.dart';
import '../../core/theme/design_tokens.dart';
import '../../widgets/clarify_button.dart';
import 'widgets/swipe_to_delete_task_row.dart';
import '../../widgets/user_profile_modal.dart';
import '../../widgets/conversations_screen.dart';
import '../../widgets/clarify_illustrations.dart';

/// "Команды" — полный паритет с десктопом: список воркспейсов, участники,
/// приглашение, «Пульс команды», задачи команды. Раздела не было в первом
/// черновике мобильного макета — добавлен по прямому запросу.
class MobileTeamsScreen extends StatelessWidget {
  final String currentLang;
  final List<Map<String, dynamic>> workspaces;
  final Map<int, List<Map<String, dynamic>>> workspaceMembers;
  final List<Map<String, dynamic>> tasks;
  final VoidCallback onAddWorkspace;
  final void Function(int workspaceId) onOpenMembers;
  final void Function(int workspaceId) onInvite;
  final void Function(int workspaceId) onShowPulse;
  final void Function(int workspaceId) onLeaveOrDeleteWorkspace;
  final Color Function(String? priority) getPriorityColor;
  final Map<String, int> Function(dynamic parentId) getSubtaskStats;
  final bool Function(Map<String, dynamic> task) isOverdue;
  final void Function(Map<String, dynamic> task) onToggleTask;
  final void Function(dynamic taskId) onDeleteTask;
  final void Function(Map<String, dynamic> task) onTaskTap;
  final void Function(dynamic taskId, Map<String, dynamic> updates)
  onQuickUpdateTask;

  const MobileTeamsScreen({
    super.key,
    required this.currentLang,
    required this.workspaces,
    required this.workspaceMembers,
    required this.tasks,
    required this.onAddWorkspace,
    required this.onOpenMembers,
    required this.onInvite,
    required this.onShowPulse,
    required this.onLeaveOrDeleteWorkspace,
    required this.getPriorityColor,
    required this.getSubtaskStats,
    required this.isOverdue,
    required this.onToggleTask,
    required this.onDeleteTask,
    required this.onTaskTap,
    required this.onQuickUpdateTask,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Команды'.tr(currentLang), style: TextStyle(fontFamily: 'Golos Text', fontSize: 22, fontWeight: FontWeight.w700, color: t.text)),
              // Не ClarifyIconButton — у того стоковый минимальный тап-таргет
              // IconButton 48×48, который в этом Row (spaceBetween, стандартный
              // crossAxisAlignment.center) растягивал высоту всей строки и
              // визуально центрировал заголовок НИЖЕ, чем на остальных трёх
              // вкладках (у них в этой же строке нет второго элемента).
              Tooltip(
                message: 'Новая команда'.tr(currentLang),
                child: InkWell(
                  borderRadius: BorderRadius.circular(ClarifyRadius.sm),
                  onTap: onAddWorkspace,
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(LucideIcons.plus, size: 24, color: t.text2),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: workspaces.isEmpty
              ? _EmptyTeams(currentLang: currentLang, onAddWorkspace: onAddWorkspace)
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
                  itemCount: workspaces.length,
                  itemBuilder: (context, index) {
                    final ws = workspaces[index];
                    final wsId = ws['id'] as int;
                    final members = workspaceMembers[wsId] ?? [];
                    final wsColor = t.tagPalette[wsId % t.tagPalette.length];
                    final taskCount = tasks.where((task) => task['workspace_id'] == wsId && task['parent_id'] == null && task['is_completed'] != true).length;

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Material(
                        color: t.surface,
                        borderRadius: BorderRadius.circular(ClarifyRadius.md),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(ClarifyRadius.md),
                          onTap: () {
                            onOpenMembers(wsId);
                            Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => _WorkspaceDetailPage(
                                currentLang: currentLang,
                                workspace: ws,
                                color: wsColor,
                                members: members,
                                tasks: tasks.where((task) => task['workspace_id'] == wsId && task['parent_id'] == null).toList(),
                                onInvite: () => onInvite(wsId),
                                onShowPulse: () => onShowPulse(wsId),
                                onLeaveOrDeleteWorkspace: () => onLeaveOrDeleteWorkspace(wsId),
                                getPriorityColor: getPriorityColor,
                                getSubtaskStats: getSubtaskStats,
                                isOverdue: isOverdue,
                                onToggleTask: onToggleTask,
                                onDeleteTask: onDeleteTask,
                                onTaskTap: onTaskTap,
                                onQuickUpdateTask: onQuickUpdateTask,
                              ),
                            ));
                          },
                          child: Container(
                            decoration: BoxDecoration(borderRadius: BorderRadius.circular(ClarifyRadius.md), border: Border(left: BorderSide(color: wsColor, width: 3))),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                            child: Row(
                              children: [
                                Icon(LucideIcons.usersRound, color: wsColor, size: 22),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(ws['name']?.toString() ?? '', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: t.text)),
                                      const SizedBox(height: 2),
                                      Text('$taskCount ${'активных задач'.tr(currentLang)}', style: TextStyle(fontSize: 12.5, color: t.text3)),
                                    ],
                                  ),
                                ),
                                Icon(LucideIcons.chevronRight, color: t.text3),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _WorkspaceDetailPage extends StatelessWidget {
  final String currentLang;
  final Map<String, dynamic> workspace;
  final Color color;
  final List<Map<String, dynamic>> members;
  final List<Map<String, dynamic>> tasks;
  final VoidCallback onInvite;
  final VoidCallback onShowPulse;
  final VoidCallback onLeaveOrDeleteWorkspace;
  final Color Function(String? priority) getPriorityColor;
  final Map<String, int> Function(dynamic parentId) getSubtaskStats;
  final bool Function(Map<String, dynamic> task) isOverdue;
  final void Function(Map<String, dynamic> task) onToggleTask;
  final void Function(dynamic taskId) onDeleteTask;
  final void Function(Map<String, dynamic> task) onTaskTap;
  final void Function(dynamic taskId, Map<String, dynamic> updates)
  onQuickUpdateTask;

  const _WorkspaceDetailPage({
    required this.currentLang,
    required this.workspace,
    required this.color,
    required this.members,
    required this.tasks,
    required this.onInvite,
    required this.onShowPulse,
    required this.onLeaveOrDeleteWorkspace,
    required this.getPriorityColor,
    required this.getSubtaskStats,
    required this.isOverdue,
    required this.onToggleTask,
    required this.onDeleteTask,
    required this.onTaskTap,
    required this.onQuickUpdateTask,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // По сроку целиком: задачи команды одним днём не ограничены, а сравнение
    // только по времени ставило завтрашнюю раньше сегодняшней.
    final sorted = [...tasks]..sort(compareTasksByDue);

    return Scaffold(
      backgroundColor: t.bg,
      appBar: AppBar(
        backgroundColor: t.bg,
        elevation: 0,
        foregroundColor: t.text,
        title: Text(workspace['name']?.toString() ?? '', style: TextStyle(fontFamily: 'Golos Text', fontWeight: FontWeight.w700)),
        actions: [
          if (Features.social) ...[
            ClarifyIconButton(icon: LucideIcons.heartPulse, onPressed: onShowPulse, tooltip: 'Пульс команды'.tr(currentLang)),
            const SizedBox(width: 4),
          ],
          ClarifyIconButton(icon: LucideIcons.logOut, onPressed: onLeaveOrDeleteWorkspace, tooltip: 'Покинуть/удалить команду'.tr(currentLang)),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Row(
              children: [
                Expanded(
                  child: members.isEmpty
                      ? Text('Участников пока нет'.tr(currentLang), style: TextStyle(fontSize: 13, color: t.text3))
                      : SizedBox(
                          height: 34,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: members.length,
                            separatorBuilder: (_, _) => const SizedBox(width: 6),
                            itemBuilder: (context, i) {
                              final m = members[i];
                              final name = (m['full_name'] ?? '?').toString();
                              return GestureDetector(
                                onTap: () => showUserProfileModal(
                                  context: context,
                                  userId: m['user_id'].toString(),
                                  currentLang: currentLang,
                                  teamRole: m['role']?.toString(),
                                  onOpenConversation: (userId, name) => Navigator.of(context).push(MaterialPageRoute(
                                    builder: (_) => ConversationScreen(currentLang: currentLang, partnerId: userId, partnerName: name),
                                  )),
                                ),
                                child: CircleAvatar(
                                  radius: 17,
                                  backgroundColor: t.tagPalette[i % t.tagPalette.length],
                                  child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                                ),
                              );
                            },
                          ),
                        ),
                ),
                ClarifyButton(variant: ClarifyButtonVariant.outline, icon: LucideIcons.userPlus, label: 'Пригласить'.tr(currentLang), onPressed: onInvite),
              ],
            ),
          ),
          Expanded(
            child: sorted.isEmpty
                ? Center(child: Text('В этой команде пока нет задач'.tr(currentLang), style: TextStyle(fontSize: 14, color: t.text3)))
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
                    itemCount: sorted.length,
                    itemBuilder: (context, index) {
                      final task = sorted[index];
                      return SwipeToDeleteTaskRow(
                        task: task,
                        currentLang: currentLang,
                        showDate: true,
                        priorityColor: getPriorityColor(task['priority']),
                        subtaskStats: getSubtaskStats(task['id']),
                        overdue: isOverdue(task),
                        onToggle: () => onToggleTask(task),
                        onConfirmedDelete: () => onDeleteTask(task['id']),
                        onTap: () => onTaskTap(task),
                        onQuickUpdateTask: (updates) => onQuickUpdateTask(task['id'], updates),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _EmptyTeams extends StatelessWidget {
  final String currentLang;
  final VoidCallback onAddWorkspace;
  const _EmptyTeams({required this.currentLang, required this.onAddWorkspace});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ClarifyIllustration(type: ClarifyIllustrationType.teamOrbit, size: 72),
            const SizedBox(height: 16),
            Text('Пока нет ни одной команды'.tr(currentLang), textAlign: TextAlign.center, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: t.text2)),
            const SizedBox(height: 16),
            ClarifyButton(variant: ClarifyButtonVariant.filled, icon: LucideIcons.plus, label: 'Создать команду'.tr(currentLang), onPressed: onAddWorkspace),
          ],
        ),
      ),
    );
  }
}
