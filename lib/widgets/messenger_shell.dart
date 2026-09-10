import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../core/localization.dart';
import '../core/theme/design_tokens.dart';
import '../services/attachment_service.dart';
import 'chat_message_widgets.dart';
import 'clarify_attachments.dart';
import 'clarify_illustrations.dart';
import 'clarify_toast.dart';
import 'icon_picker_dialog.dart';

typedef MessengerGlassBuilder = Widget Function({
  required Widget child,
  EdgeInsetsGeometry? margin,
  EdgeInsetsGeometry? padding,
  Color? customColor,
});

/// Мессенджер — 3-колоночный макет в духе Telegram Desktop (обсуждённая
/// концепция): свёрнутая icon-полоса основного сайдбара — снаружи, в
/// DesktopPlannerScreen/SidebarMenu — здесь только вторая и третья колонки:
/// список чатов (личные/командные вкладки) и открытый чат. Выбранный чат —
/// состояние этого виджета, а не Navigator.push поверх всего шелла, иначе
/// сайдбар и список чатов пропадали бы под полноэкранным диалогом.
class MessengerShell extends StatefulWidget {
  final String currentLang;
  final double scale;
  final MessengerGlassBuilder buildGlassContainer;
  final String? initialPartnerId;
  final String? initialPartnerName;

  const MessengerShell({
    super.key,
    required this.currentLang,
    this.scale = 1.0,
    required this.buildGlassContainer,
    this.initialPartnerId,
    this.initialPartnerName,
  });

  @override
  State<MessengerShell> createState() => _MessengerShellState();
}

sealed class _ChatTarget {
  const _ChatTarget();
}

final class _DirectTarget extends _ChatTarget {
  final String partnerId;
  final String partnerName;
  const _DirectTarget(this.partnerId, this.partnerName);
}

final class _TeamTarget extends _ChatTarget {
  final int workspaceId;
  final String workspaceName;
  const _TeamTarget(this.workspaceId, this.workspaceName);
}

class _MessengerShellState extends State<MessengerShell> with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(length: 2, vsync: this);
  _ChatTarget? _selected;

  @override
  void initState() {
    super.initState();
    if (widget.initialPartnerId != null) {
      _selected = _DirectTarget(widget.initialPartnerId!, widget.initialPartnerName ?? '');
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final s = widget.scale;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          // Нижняя граница ширины: 320 * s на окне 1100px давало ~180px, и
          // подпись вкладки «Команды» обрезалась на полуслове (2026-09-04).
          // Список чатов — не декоративная колонка, ему нужна минимальная
          // читаемая ширина независимо от масштаба окна.
          width: (320 * s).clamp(250.0, 380.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TabBar(
                controller: _tabController,
                labelColor: t.accent,
                unselectedLabelColor: t.text3,
                indicatorColor: t.accent,
                tabs: [
                  Tab(text: 'Личные'.tr(widget.currentLang)),
                  Tab(text: 'Команды'.tr(widget.currentLang)),
                ],
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _DirectChatList(
                      currentLang: widget.currentLang,
                      buildGlassContainer: widget.buildGlassContainer,
                      selectedPartnerId: switch (_selected) { _DirectTarget d => d.partnerId, _ => null },
                      onSelect: (id, name) => setState(() => _selected = _DirectTarget(id, name)),
                    ),
                    _TeamChatList(
                      currentLang: widget.currentLang,
                      buildGlassContainer: widget.buildGlassContainer,
                      selectedWorkspaceId: switch (_selected) { _TeamTarget team => team.workspaceId, _ => null },
                      onSelect: (id, name) => setState(() => _selected = _TeamTarget(id, name)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        VerticalDivider(width: 1, thickness: 1, color: t.border),
        Expanded(
          child: switch (_selected) {
            // Пустое состояние с иллюстрацией, как в списках задач
            // (2026-09-04): голая серая строка посреди половины экрана
            // читалась как «здесь что-то сломалось».
            null => Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const ClarifyIllustration(type: ClarifyIllustrationType.teamOrbit, size: 84),
                    const SizedBox(height: 18),
                    Text(
                      'Выберите чат слева'.tr(widget.currentLang),
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: t.text2),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      'Личные переписки и чаты команд — в одном месте'.tr(widget.currentLang),
                      style: TextStyle(fontSize: 13, color: t.text3),
                    ),
                  ],
                ),
              ),
            _DirectTarget d => _DirectChatPane(
                key: ValueKey('dm_${d.partnerId}'),
                currentLang: widget.currentLang,
                scale: s,
                partnerId: d.partnerId,
                partnerName: d.partnerName,
              ),
            _TeamTarget team => _TeamChatPane(
                key: ValueKey('team_${team.workspaceId}'),
                currentLang: widget.currentLang,
                scale: s,
                workspaceId: team.workspaceId,
                workspaceName: team.workspaceName,
              ),
          },
        ),
      ],
    );
  }
}

class _DirectChatList extends StatefulWidget {
  final String currentLang;
  final MessengerGlassBuilder buildGlassContainer;
  final String? selectedPartnerId;
  final void Function(String partnerId, String partnerName) onSelect;

  const _DirectChatList({
    required this.currentLang,
    required this.buildGlassContainer,
    required this.selectedPartnerId,
    required this.onSelect,
  });

  @override
  State<_DirectChatList> createState() => _DirectChatListState();
}

class _DirectChatListState extends State<_DirectChatList> {
  List<Map<String, dynamic>>? _conversations;
  RealtimeChannel? _channel;

  @override
  void initState() {
    super.initState();
    _load();
    _channel = Supabase.instance.client.channel('messenger_dm_list')
      ..onPostgresChanges(event: PostgresChangeEvent.all, schema: 'public', table: 'messages', callback: (_) => _load())
      ..subscribe();
  }

  @override
  void dispose() {
    _channel?.unsubscribe();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final data = await Supabase.instance.client.rpc('list_conversations');
      if (mounted) setState(() => _conversations = List<Map<String, dynamic>>.from(data));
    } catch (e) {
      if (mounted) setState(() => _conversations = []);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    if (_conversations == null) return const Center(child: CircularProgressIndicator());
    if (_conversations!.isEmpty) {
      return Center(child: Text('Пока нет сообщений'.tr(widget.currentLang), style: TextStyle(color: t.text3, fontSize: 15)));
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _conversations!.length,
      itemBuilder: (context, index) {
        final c = _conversations![index];
        final partnerId = c['partner_id'] as String;
        final unread = (c['unread_count'] as num?)?.toInt() ?? 0;
        final name = (c['full_name'] as String?)?.trim();
        final displayName = (name == null || name.isEmpty) ? 'Без имени'.tr(widget.currentLang) : name;
        final selected = widget.selectedPartnerId == partnerId;

        return widget.buildGlassContainer(
          margin: const EdgeInsets.only(bottom: 8),
          customColor: selected ? t.accentSoft : null,
          child: ListTile(
            onTap: () => widget.onSelect(partnerId, displayName),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            leading: CircleAvatar(
              radius: 18,
              backgroundColor: t.accentSoft,
              backgroundImage: c['avatar_url'] != null ? NetworkImage(c['avatar_url'] as String) : null,
              child: c['avatar_url'] == null ? Text(displayName[0].toUpperCase(), style: TextStyle(color: t.accent, fontWeight: FontWeight.bold)) : null,
            ),
            title: Text(displayName, style: TextStyle(color: t.text, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: c['last_message'] != null
                ? Text(c['last_message'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: t.text3))
                : null,
            trailing: unread > 0
                ? Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: t.accent, borderRadius: BorderRadius.circular(ClarifyRadius.pill)),
                    child: Text('$unread', style: TextStyle(color: t.onAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                  )
                : null,
          ),
        );
      },
    );
  }
}

class _TeamChatList extends StatefulWidget {
  final String currentLang;
  final MessengerGlassBuilder buildGlassContainer;
  final int? selectedWorkspaceId;
  final void Function(int workspaceId, String workspaceName) onSelect;

  const _TeamChatList({
    required this.currentLang,
    required this.buildGlassContainer,
    required this.selectedWorkspaceId,
    required this.onSelect,
  });

  @override
  State<_TeamChatList> createState() => _TeamChatListState();
}

class _TeamChatListState extends State<_TeamChatList> {
  List<Map<String, dynamic>>? _conversations;
  RealtimeChannel? _channel;

  @override
  void initState() {
    super.initState();
    _load();
    _channel = Supabase.instance.client.channel('messenger_team_list')
      ..onPostgresChanges(event: PostgresChangeEvent.all, schema: 'public', table: 'workspace_messages', callback: (_) => _load())
      ..subscribe();
  }

  @override
  void dispose() {
    _channel?.unsubscribe();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final data = await Supabase.instance.client.rpc('list_workspace_conversations');
      if (mounted) setState(() => _conversations = List<Map<String, dynamic>>.from(data));
    } catch (e) {
      if (mounted) setState(() => _conversations = []);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    if (_conversations == null) return const Center(child: CircularProgressIndicator());
    if (_conversations!.isEmpty) {
      return Center(child: Text('Нет команд'.tr(widget.currentLang), style: TextStyle(color: t.text3, fontSize: 15)));
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _conversations!.length,
      itemBuilder: (context, index) {
        final c = _conversations![index];
        final wsId = (c['workspace_id'] as num).toInt();
        final unread = (c['unread_count'] as num?)?.toInt() ?? 0;
        final name = (c['name'] as String?)?.trim();
        final displayName = (name == null || name.isEmpty) ? 'Команда'.tr(widget.currentLang) : name;
        final selected = widget.selectedWorkspaceId == wsId;
        final wsColor = t.tagPalette[wsId % t.tagPalette.length];

        return widget.buildGlassContainer(
          margin: const EdgeInsets.only(bottom: 8),
          customColor: selected ? wsColor.withValues(alpha: 0.15) : null,
          child: ListTile(
            onTap: () => widget.onSelect(wsId, displayName),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            leading: CircleAvatar(
              radius: 18,
              backgroundColor: wsColor.withValues(alpha: 0.15),
              child: Icon(c['icon'] != null ? iconByKey(c['icon'].toString()) : LucideIcons.usersRound, color: wsColor, size: 18),
            ),
            title: Text(displayName, style: TextStyle(color: t.text, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: c['last_message'] != null
                ? Text(c['last_message'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: t.text3))
                : Text('Сообщений пока нет'.tr(widget.currentLang), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: t.text3)),
            trailing: unread > 0
                ? Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: wsColor, borderRadius: BorderRadius.circular(ClarifyRadius.pill)),
                    child: Text('$unread', style: TextStyle(color: t.onAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                  )
                : null,
          ),
        );
      },
    );
  }
}

class _ChatPaneHeader extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color iconColor;

  const _ChatPaneHeader({required this.title, required this.icon, required this.iconColor});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
      child: Row(
        children: [
          CircleAvatar(radius: 16, backgroundColor: iconColor.withValues(alpha: 0.15), child: Icon(icon, size: 16, color: iconColor)),
          const SizedBox(width: 12),
          Expanded(child: Text(title, style: TextStyle(fontFamily: 'Golos Text', fontSize: 17, fontWeight: FontWeight.w700, color: t.text), maxLines: 1, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }
}

class _DirectChatPane extends StatefulWidget {
  final String currentLang;
  final double scale;
  final String partnerId;
  final String partnerName;

  const _DirectChatPane({super.key, required this.currentLang, required this.scale, required this.partnerId, required this.partnerName});

  @override
  State<_DirectChatPane> createState() => _DirectChatPaneState();
}

class _DirectChatPaneState extends State<_DirectChatPane> {
  final _scrollController = ScrollController();
  final Map<dynamic, GlobalKey> _messageKeys = {};
  List<Map<String, dynamic>>? _messages;
  ChatAttachments _attachments = ChatAttachments.empty;
  RealtimeChannel? _channel;
  Map<String, dynamic>? _replyingTo;
  Map<String, dynamic>? _editingMessage;

  String get _myId => Supabase.instance.client.auth.currentUser!.id;

  GlobalKey _keyFor(dynamic id) => _messageKeys.putIfAbsent(id, () => GlobalKey());

  // См. _ConversationScreenState._scrollToMessage (conversations_screen.dart) —
  // та же логика перехода к закреплённому сообщению, продублирована здесь по
  // тому же принципу, что и вся остальная desktop/mobile-пара в этом файле.
  void _scrollToMessage(dynamic id) {
    final index = _messages?.indexWhere((m) => m['id'] == id) ?? -1;
    if (index == -1) return;
    final ctx = _messageKeys[id]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx, duration: ClarifyMotion.slow, alignment: 0.5, curve: Curves.easeOut);
      return;
    }
    if (_scrollController.hasClients && _messages!.length > 1) {
      final estimate = _scrollController.position.maxScrollExtent * (index / (_messages!.length - 1));
      _scrollController.jumpTo(estimate.clamp(0, _scrollController.position.maxScrollExtent));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final retryCtx = _messageKeys[id]?.currentContext;
        if (retryCtx != null) Scrollable.ensureVisible(retryCtx, duration: ClarifyMotion.base, alignment: 0.5, curve: Curves.easeOut);
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
    Supabase.instance.client.rpc('mark_conversation_read', params: {'partner_id': widget.partnerId}).catchError((_) => null);
    _channel = Supabase.instance.client.channel('messenger_dm_pane_${widget.partnerId}')
      ..onPostgresChanges(event: PostgresChangeEvent.all, schema: 'public', table: 'messages', callback: (_) => _load())
      ..subscribe();
  }

  @override
  void dispose() {
    _channel?.unsubscribe();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final data = await Supabase.instance.client
          .from('messages')
          .select()
          .or('and(from_id.eq.$_myId,to_id.eq.${widget.partnerId}),and(from_id.eq.${widget.partnerId},to_id.eq.$_myId)')
          .order('created_at', ascending: true);
      if (mounted) {
        final messages = List<Map<String, dynamic>>.from(data);
        setState(() => _messages = messages);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        });
        final attachments = await loadChatAttachments(
          column: 'message_id',
          messageIds: messages.map((m) => (m['id'] as num).toInt()).toList(),
        );
        if (mounted) setState(() => _attachments = attachments);
      }
    } on PostgrestException {
      if (mounted) setState(() => _messages = []);
    }
  }

  Future<void> _submit(String text, List<AttachmentDraft> attachments) async {
    if (_editingMessage != null) {
      await _editMessage((_editingMessage!['id'] as num).toInt(), text);
    } else {
      await _sendMessage(text, attachments);
    }
  }

  Future<void> _sendMessage(String text, List<AttachmentDraft> attachments) async {
    try {
      // Нужен номер вставленного сообщения: к нему привязываются вложения.
      final inserted = await Supabase.instance.client.from('messages').insert({
        'from_id': _myId,
        'to_id': widget.partnerId,
        'text': text,
        if (_replyingTo != null) 'reply_to_id': _replyingTo!['id'],
      }).select('id').single();
      if (mounted) setState(() => _replyingTo = null);
      if (attachments.isNotEmpty) {
        final failed = await uploadAttachmentDrafts(
          drafts: attachments,
          owner: AttachmentOwner.message((inserted['id'] as num).toInt()),
        );
        if (failed.isNotEmpty && mounted) {
          ClarifyToast.show(context, '${'Не отправились файлы: '.tr(widget.currentLang)}${failed.join(', ')}', variant: ClarifyToastVariant.danger);
        }
      }
      await _load();
    } on PostgrestException catch (e) {
      if (mounted) ClarifyToast.show(context, '${'Ошибка отправки: '.tr(widget.currentLang)}${e.message}', variant: ClarifyToastVariant.danger);
    }
  }

  Future<void> _editMessage(int id, String text) async {
    try {
      await Supabase.instance.client.rpc('edit_message', params: {'message_id': id, 'new_text': text});
      if (mounted) setState(() => _editingMessage = null);
      await _load();
    } on PostgrestException catch (e) {
      if (mounted) ClarifyToast.show(context, '${'Ошибка редактирования: '.tr(widget.currentLang)}${e.message}', variant: ClarifyToastVariant.danger);
    }
  }

  Future<void> _deleteMessage(int id) async {
    try {
      await Supabase.instance.client.rpc('delete_message', params: {'message_id': id});
      await _load();
    } on PostgrestException catch (e) {
      if (mounted) ClarifyToast.show(context, '${'Ошибка удаления: '.tr(widget.currentLang)}${e.message}', variant: ClarifyToastVariant.danger);
    }
  }

  Future<void> _togglePin(int id) async {
    try {
      await Supabase.instance.client.rpc('toggle_pin_message', params: {'message_id': id});
      await _load();
    } on PostgrestException catch (e) {
      if (mounted) ClarifyToast.show(context, '${'Ошибка: '.tr(widget.currentLang)}${e.message}', variant: ClarifyToastVariant.danger);
    }
  }

  void _openActions(Map<String, dynamic> m) {
    final isMine = m['from_id'] == _myId;
    final id = (m['id'] as num).toInt();
    showMessageActions(
      context: context,
      isMobile: false,
      isMine: isMine,
      isPinned: m['pinned'] as bool? ?? false,
      currentLang: widget.currentLang,
      onReply: () => setState(() {
        _replyingTo = m;
        _editingMessage = null;
      }),
      onForward: () => forwardMessage(
        context: context,
        isMobile: false,
        currentLang: widget.currentLang,
        text: m['text'] as String,
        forwardedFromName: isMine ? 'Вы'.tr(widget.currentLang) : widget.partnerName,
      ),
      onTogglePin: () => _togglePin(id),
      onEdit: isMine
          ? () => setState(() {
                _editingMessage = m;
                _replyingTo = null;
              })
          : null,
      onDelete: isMine ? () => _deleteMessage(id) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final byId = _messages == null ? <dynamic, Map<String, dynamic>>{} : {for (final m in _messages!) m['id']: m};
    final pinnedList = _messages?.where((m) => m['pinned'] == true).toList() ?? const [];
    final pinnedMessage = pinnedList.isEmpty ? null : pinnedList.first;

    return Column(
      children: [
        _ChatPaneHeader(title: widget.partnerName, icon: LucideIcons.user, iconColor: context.tokens.accent),
        if (pinnedMessage != null)
          PinnedMessageBar(
            currentLang: widget.currentLang,
            text: pinnedMessage['text'] as String,
            onTap: () => _scrollToMessage(pinnedMessage['id']),
            onUnpin: () => _togglePin((pinnedMessage['id'] as num).toInt()),
          ),
        Expanded(
          child: _messages == null
              ? const Center(child: CircularProgressIndicator())
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(16),
                  itemCount: _messages!.length,
                  itemBuilder: (context, index) {
                    final m = _messages![index];
                    final isMine = m['from_id'] == _myId;
                    final replyTo = byId[m['reply_to_id']];
                    return KeyedSubtree(
                      key: _keyFor(m['id']),
                      child: ChatMessageBubble(
                        currentLang: widget.currentLang,
                        message: m,
                        isMine: isMine,
                        showReadTicks: true,
                        replyToMessage: replyTo,
                        replyToSenderLabel: replyTo == null ? '' : (replyTo['from_id'] == _myId ? 'Вы'.tr(widget.currentLang) : widget.partnerName),
                        onOpenActions: () => _openActions(m),
                        attachments: _attachments,
                      ),
                    );
                  },
                ),
        ),
        ChatComposer(
          currentLang: widget.currentLang,
          onSubmit: _submit,
          replyPreviewLabel: _replyingTo == null ? null : (_replyingTo!['from_id'] == _myId ? 'Вы'.tr(widget.currentLang) : widget.partnerName),
          replyPreviewText: _replyingTo == null ? null : _replyingTo!['text'] as String,
          onCancelReply: () => setState(() => _replyingTo = null),
          isEditing: _editingMessage != null,
          editingInitialText: _editingMessage?['text'] as String?,
          onCancelEdit: () => setState(() => _editingMessage = null),
        ),
      ],
    );
  }
}

class _TeamChatPane extends StatefulWidget {
  final String currentLang;
  final double scale;
  final int workspaceId;
  final String workspaceName;

  const _TeamChatPane({super.key, required this.currentLang, required this.scale, required this.workspaceId, required this.workspaceName});

  @override
  State<_TeamChatPane> createState() => _TeamChatPaneState();
}

class _TeamChatPaneState extends State<_TeamChatPane> {
  final _scrollController = ScrollController();
  final Map<dynamic, GlobalKey> _messageKeys = {};
  List<Map<String, dynamic>>? _messages;
  ChatAttachments _attachments = ChatAttachments.empty;
  RealtimeChannel? _channel;
  Map<String, dynamic>? _replyingTo;
  Map<String, dynamic>? _editingMessage;

  String get _myId => Supabase.instance.client.auth.currentUser!.id;

  GlobalKey _keyFor(dynamic id) => _messageKeys.putIfAbsent(id, () => GlobalKey());

  void _scrollToMessage(dynamic id) {
    final index = _messages?.indexWhere((m) => m['id'] == id) ?? -1;
    if (index == -1) return;
    final ctx = _messageKeys[id]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx, duration: ClarifyMotion.slow, alignment: 0.5, curve: Curves.easeOut);
      return;
    }
    if (_scrollController.hasClients && _messages!.length > 1) {
      final estimate = _scrollController.position.maxScrollExtent * (index / (_messages!.length - 1));
      _scrollController.jumpTo(estimate.clamp(0, _scrollController.position.maxScrollExtent));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final retryCtx = _messageKeys[id]?.currentContext;
        if (retryCtx != null) Scrollable.ensureVisible(retryCtx, duration: ClarifyMotion.base, alignment: 0.5, curve: Curves.easeOut);
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
    Supabase.instance.client.rpc('mark_workspace_read', params: {'ws_id': widget.workspaceId}).catchError((_) => null);
    _channel = Supabase.instance.client.channel('messenger_team_pane_${widget.workspaceId}')
      ..onPostgresChanges(event: PostgresChangeEvent.all, schema: 'public', table: 'workspace_messages', callback: (_) => _load())
      ..subscribe();
  }

  @override
  void dispose() {
    _channel?.unsubscribe();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final data = await Supabase.instance.client.rpc('list_workspace_messages', params: {'ws_id': widget.workspaceId});
      if (mounted) {
        final messages = List<Map<String, dynamic>>.from(data);
        setState(() => _messages = messages);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        });
        final attachments = await loadChatAttachments(
          column: 'workspace_message_id',
          messageIds: messages.map((m) => (m['id'] as num).toInt()).toList(),
        );
        if (mounted) setState(() => _attachments = attachments);
      }
    } on PostgrestException {
      if (mounted) setState(() => _messages = []);
    }
  }

  String _senderLabel(Map<String, dynamic> m) {
    if (m['from_id'] == _myId) return 'Вы'.tr(widget.currentLang);
    final name = (m['full_name'] as String?)?.trim();
    return (name == null || name.isEmpty) ? 'Без имени'.tr(widget.currentLang) : name;
  }

  Future<void> _submit(String text, List<AttachmentDraft> attachments) async {
    if (_editingMessage != null) {
      await _editMessage((_editingMessage!['id'] as num).toInt(), text);
    } else {
      await _sendMessage(text, attachments);
    }
  }

  Future<void> _sendMessage(String text, List<AttachmentDraft> attachments) async {
    try {
      // Нужен номер вставленного сообщения: к нему привязываются вложения.
      final inserted = await Supabase.instance.client.from('workspace_messages').insert({
        'workspace_id': widget.workspaceId,
        'from_id': _myId,
        'text': text,
        if (_replyingTo != null) 'reply_to_id': _replyingTo!['id'],
      }).select('id').single();
      if (mounted) setState(() => _replyingTo = null);
      if (attachments.isNotEmpty) {
        final failed = await uploadAttachmentDrafts(
          drafts: attachments,
          owner: AttachmentOwner.workspaceMessage((inserted['id'] as num).toInt()),
        );
        if (failed.isNotEmpty && mounted) {
          ClarifyToast.show(context, '${'Не отправились файлы: '.tr(widget.currentLang)}${failed.join(', ')}', variant: ClarifyToastVariant.danger);
        }
      }
      await _load();
    } on PostgrestException catch (e) {
      if (mounted) ClarifyToast.show(context, '${'Ошибка отправки: '.tr(widget.currentLang)}${e.message}', variant: ClarifyToastVariant.danger);
    }
  }

  Future<void> _editMessage(int id, String text) async {
    try {
      await Supabase.instance.client.rpc('edit_workspace_message', params: {'message_id': id, 'new_text': text});
      if (mounted) setState(() => _editingMessage = null);
      await _load();
    } on PostgrestException catch (e) {
      if (mounted) ClarifyToast.show(context, '${'Ошибка редактирования: '.tr(widget.currentLang)}${e.message}', variant: ClarifyToastVariant.danger);
    }
  }

  Future<void> _deleteMessage(int id) async {
    try {
      await Supabase.instance.client.rpc('delete_workspace_message', params: {'message_id': id});
      await _load();
    } on PostgrestException catch (e) {
      if (mounted) ClarifyToast.show(context, '${'Ошибка удаления: '.tr(widget.currentLang)}${e.message}', variant: ClarifyToastVariant.danger);
    }
  }

  Future<void> _togglePin(int id) async {
    try {
      await Supabase.instance.client.rpc('toggle_pin_workspace_message', params: {'message_id': id});
      await _load();
    } on PostgrestException catch (e) {
      if (mounted) ClarifyToast.show(context, '${'Ошибка: '.tr(widget.currentLang)}${e.message}', variant: ClarifyToastVariant.danger);
    }
  }

  void _openActions(Map<String, dynamic> m) {
    final isMine = m['from_id'] == _myId;
    final id = (m['id'] as num).toInt();
    showMessageActions(
      context: context,
      isMobile: false,
      isMine: isMine,
      isPinned: m['pinned'] as bool? ?? false,
      currentLang: widget.currentLang,
      onReply: () => setState(() {
        _replyingTo = m;
        _editingMessage = null;
      }),
      onForward: () => forwardMessage(
        context: context,
        isMobile: false,
        currentLang: widget.currentLang,
        text: m['text'] as String,
        forwardedFromName: _senderLabel(m),
      ),
      onTogglePin: () => _togglePin(id),
      onEdit: isMine
          ? () => setState(() {
                _editingMessage = m;
                _replyingTo = null;
              })
          : null,
      onDelete: isMine ? () => _deleteMessage(id) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final wsColor = t.tagPalette[widget.workspaceId % t.tagPalette.length];
    final byId = _messages == null ? <dynamic, Map<String, dynamic>>{} : {for (final m in _messages!) m['id']: m};
    final pinnedList = _messages?.where((m) => m['pinned'] == true).toList() ?? const [];
    final pinnedMessage = pinnedList.isEmpty ? null : pinnedList.first;

    return Column(
      children: [
        _ChatPaneHeader(title: widget.workspaceName, icon: LucideIcons.usersRound, iconColor: wsColor),
        if (pinnedMessage != null)
          PinnedMessageBar(
            currentLang: widget.currentLang,
            text: pinnedMessage['text'] as String,
            onTap: () => _scrollToMessage(pinnedMessage['id']),
            onUnpin: () => _togglePin((pinnedMessage['id'] as num).toInt()),
          ),
        Expanded(
          child: _messages == null
              ? const Center(child: CircularProgressIndicator())
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(16),
                  itemCount: _messages!.length,
                  itemBuilder: (context, index) {
                    final m = _messages![index];
                    final isMine = m['from_id'] == _myId;
                    final replyTo = byId[m['reply_to_id']];
                    return KeyedSubtree(
                      key: _keyFor(m['id']),
                      child: ChatMessageBubble(
                        currentLang: widget.currentLang,
                        message: m,
                        isMine: isMine,
                        senderLabel: isMine ? null : _senderLabel(m),
                        replyToMessage: replyTo,
                        replyToSenderLabel: replyTo == null ? '' : _senderLabel(replyTo),
                        onOpenActions: () => _openActions(m),
                        attachments: _attachments,
                      ),
                    );
                  },
                ),
        ),
        ChatComposer(
          currentLang: widget.currentLang,
          onSubmit: _submit,
          replyPreviewLabel: _replyingTo == null ? null : _senderLabel(_replyingTo!),
          replyPreviewText: _replyingTo == null ? null : _replyingTo!['text'] as String,
          onCancelReply: () => setState(() => _replyingTo = null),
          isEditing: _editingMessage != null,
          editingInitialText: _editingMessage?['text'] as String?,
          onCancelEdit: () => setState(() => _editingMessage = null),
        ),
      ],
    );
  }
}
