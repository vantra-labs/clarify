import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../core/localization.dart';
import '../core/theme/design_tokens.dart';
import '../services/attachment_service.dart';
import 'chat_message_widgets.dart';
import 'clarify_attachments.dart';
import 'clarify_toast.dart';
import 'icon_picker_dialog.dart';

/// Командный групповой чат — мобильный аналог вкладки "Команда" в
/// MessengerShell (widgets/messenger_shell.dart:_TeamChatList/_TeamChatPane),
/// который раньше был доступен только на десктопе: с телефона зайти в общий
/// чат команды было вообще нельзя (фидбек пользователя 2026-08-01 — "должно
/// быть одно кроссплатформенное приложение, не должно быть отличий в базовых
/// вещах"). Та же пара экранов, что и у личных сообщений
/// (ConversationsListScreen/ConversationScreen, widgets/conversations_screen.dart) —
/// список/чат через Navigator.push, а не встроенная 3-колоночная панель (той
/// нет места на узком экране), но те же RPC и та же логика реплаев/пинов/
/// редактирования/удаления, что и в десктопной версии.
class WorkspaceConversationsListScreen extends StatefulWidget {
  final String currentLang;

  const WorkspaceConversationsListScreen({super.key, required this.currentLang});

  @override
  State<WorkspaceConversationsListScreen> createState() => _WorkspaceConversationsListScreenState();
}

class _WorkspaceConversationsListScreenState extends State<WorkspaceConversationsListScreen> {
  List<Map<String, dynamic>>? _conversations;
  RealtimeChannel? _channel;

  @override
  void initState() {
    super.initState();
    _load();
    _channel = Supabase.instance.client.channel('mobile_workspace_messages_list')
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

  void _openWorkspace(int workspaceId, String workspaceName) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => WorkspaceChatScreen(currentLang: widget.currentLang, workspaceId: workspaceId, workspaceName: workspaceName),
    )).then((_) => _load());
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    if (_conversations == null) return const Center(child: CircularProgressIndicator());
    if (_conversations!.isEmpty) {
      return Center(child: Text('Нет команд'.tr(widget.currentLang), style: TextStyle(color: t.text3, fontSize: 15)));
    }

    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: _conversations!.length,
      itemBuilder: (context, index) {
        final c = _conversations![index];
        final wsId = (c['workspace_id'] as num).toInt();
        final unread = (c['unread_count'] as num?)?.toInt() ?? 0;
        final name = (c['name'] as String?)?.trim();
        final displayName = (name == null || name.isEmpty) ? 'Команда'.tr(widget.currentLang) : name;
        final wsColor = t.tagPalette[wsId % t.tagPalette.length];

        return Material(
          color: t.surface,
          borderRadius: BorderRadius.circular(ClarifyRadius.md),
          child: InkWell(
            borderRadius: BorderRadius.circular(ClarifyRadius.md),
            onTap: () => _openWorkspace(wsId, displayName),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: wsColor.withValues(alpha: 0.15),
                    child: Icon(c['icon'] != null ? iconByKey(c['icon'].toString()) : LucideIcons.usersRound, color: wsColor, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(displayName, style: TextStyle(color: t.text, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                        if (c['last_message'] != null)
                          Text(c['last_message'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: t.text3))
                        else
                          Text('Сообщений пока нет'.tr(widget.currentLang), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: t.text3)),
                      ],
                    ),
                  ),
                  if (unread > 0)
                    Container(
                      margin: const EdgeInsets.only(left: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(color: wsColor, borderRadius: BorderRadius.circular(ClarifyRadius.pill)),
                      child: Text('$unread', style: TextStyle(color: t.onAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                    ),
                ],
              ),
            ),
          ),
        );
      },
      // Немного отступа между карточками — тот же visual language, что и
      // у ConversationsListScreen, только там его даёт buildGlassContainer.
    );
  }
}

class WorkspaceChatScreen extends StatefulWidget {
  final String currentLang;
  final int workspaceId;
  final String workspaceName;

  const WorkspaceChatScreen({super.key, required this.currentLang, required this.workspaceId, required this.workspaceName});

  @override
  State<WorkspaceChatScreen> createState() => _WorkspaceChatScreenState();
}

class _WorkspaceChatScreenState extends State<WorkspaceChatScreen> {
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
    Supabase.instance.client.rpc('mark_workspace_read', params: {'ws_id': widget.workspaceId}).catchError((_) => null);
    _channel = Supabase.instance.client.channel('mobile_workspace_chat_${widget.workspaceId}')
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
      isMobile: true,
      isMine: isMine,
      isPinned: m['pinned'] as bool? ?? false,
      currentLang: widget.currentLang,
      onReply: () => setState(() {
        _replyingTo = m;
        _editingMessage = null;
      }),
      onForward: () => forwardMessage(
        context: context,
        isMobile: true,
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

    return Scaffold(
      backgroundColor: t.bg,
      appBar: AppBar(
        backgroundColor: t.bg,
        elevation: 0,
        foregroundColor: t.text,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(radius: 14, backgroundColor: wsColor.withValues(alpha: 0.15), child: Icon(LucideIcons.usersRound, size: 14, color: wsColor)),
            const SizedBox(width: 10),
            Flexible(child: Text(widget.workspaceName, style: const TextStyle(fontFamily: 'Golos Text', fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
      body: Column(
        children: [
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
          SafeArea(
            top: false,
            child: ChatComposer(
              currentLang: widget.currentLang,
              onSubmit: _submit,
              replyPreviewLabel: _replyingTo == null ? null : _senderLabel(_replyingTo!),
              replyPreviewText: _replyingTo == null ? null : _replyingTo!['text'] as String,
              onCancelReply: () => setState(() => _replyingTo = null),
              isEditing: _editingMessage != null,
              editingInitialText: _editingMessage?['text'] as String?,
              onCancelEdit: () => setState(() => _editingMessage = null),
            ),
          ),
        ],
      ),
    );
  }
}
