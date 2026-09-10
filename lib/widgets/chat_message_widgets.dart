import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../core/localization.dart';
import '../services/attachment_service.dart';
import '../core/theme/design_tokens.dart';
import 'clarify_attachments.dart';
import 'clarify_bottom_sheet.dart';
import 'clarify_glass.dart';
import 'clarify_surface.dart';
import 'clarify_toast.dart';

/// Общие виджеты чата — переиспользуются десктопным [MessengerShell]
/// (личные + командные чаты) и мобильным [ConversationScreen], которые
/// раньше независимо дублировали рендер пузырька/композера. Централизует
/// Telegram-подобные функции: ответ, пересылка, закрепление, редактирование,
/// удаление, тики отправлено/прочитано.

String formatMessageTime(DateTime createdAt) {
  final local = createdAt.toLocal();
  final h = local.hour.toString().padLeft(2, '0');
  final m = local.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

/// Пузырёк сообщения. [message] — сырая карта из Supabase (id, from_id,
/// text, created_at, опционально read_at/edited_at/forwarded_from_name/
/// pinned/reply_to_id) — тот же паттерн, что и `Map<String,dynamic>` для
/// задач в остальном приложении, без отдельного модельного класса.
class ChatMessageBubble extends StatelessWidget {
  final String currentLang;
  final Map<String, dynamic> message;
  final bool isMine;
  final String? senderLabel;
  final bool showReadTicks;
  final Map<String, dynamic>? replyToMessage;
  final String replyToSenderLabel;
  final VoidCallback onOpenActions;

  /// Вложения всей переписки — пузырёк берёт из них свои. Грузит их чат одним
  /// запросом на все сообщения (см. [loadChatAttachments]).
  final ChatAttachments attachments;

  const ChatMessageBubble({
    super.key,
    required this.currentLang,
    required this.message,
    required this.isMine,
    this.senderLabel,
    this.showReadTicks = false,
    this.replyToMessage,
    this.replyToSenderLabel = '',
    required this.onOpenActions,
    this.attachments = ChatAttachments.empty,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = message['text'] as String;
    final createdAt = DateTime.parse(message['created_at'] as String);
    final editedAt = message['edited_at'] as String?;
    final forwardedFrom = message['forwarded_from_name'] as String?;
    final readAt = message['read_at'];
    final metaColor = isMine ? t.onAccent.withValues(alpha: 0.7) : t.text3;
    final myAttachments = attachments.of(message['id']);

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onOpenActions,
        onSecondaryTap: onOpenActions,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          constraints: const BoxConstraints(maxWidth: 320),
          decoration: BoxDecoration(color: isMine ? t.accent : t.surface2, borderRadius: BorderRadius.circular(ClarifyRadius.lg)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (senderLabel != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(senderLabel!, style: TextStyle(color: t.accent, fontSize: 12, fontWeight: FontWeight.bold)),
                ),
              if (replyToMessage != null)
                Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: BoxDecoration(
                    color: (isMine ? t.onAccent : t.accent).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(ClarifyRadius.sm),
                    border: Border(left: BorderSide(color: isMine ? t.onAccent : t.accent, width: 2)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(replyToSenderLabel, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: isMine ? t.onAccent : t.accent)),
                      Text(replyToMessage!['text'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: metaColor)),
                    ],
                  ),
                ),
              if (forwardedFrom != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text('${'Переслано от'.tr(currentLang)} $forwardedFrom', style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic, color: metaColor)),
                ),
              // Сообщение может состоять из одного файла — тогда пустой текст
              // не занимает строку.
              if (text.isNotEmpty)
                Text(text, style: TextStyle(color: isMine ? t.onAccent : t.text)),
              if (myAttachments.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(top: text.isEmpty ? 0 : 8, bottom: 2),
                  child: ClarifyAttachmentTiles(
                    attachments: myAttachments,
                    previewUrls: attachments.previewUrls,
                    currentLang: currentLang,
                  ),
                ),
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (editedAt != null) ...[
                    Text('изменено'.tr(currentLang), style: TextStyle(fontSize: 10.5, color: metaColor)),
                    const SizedBox(width: 4),
                  ],
                  Text(formatMessageTime(createdAt), style: TextStyle(fontSize: 10.5, color: metaColor)),
                  if (showReadTicks && isMine) ...[
                    const SizedBox(width: 3),
                    Icon(readAt != null ? LucideIcons.checkCheck : LucideIcons.check, size: 13, color: metaColor),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Плашка закреплённого сообщения — как в Telegram, сразу под шапкой чата,
/// а не внутри самого пузырька (см. showMessageActions/onTogglePin — в чате
/// поддерживается ровно одно закреплённое сообщение на диалог/команду).
class PinnedMessageBar extends StatelessWidget {
  final String currentLang;
  final String text;
  final VoidCallback onTap;
  final VoidCallback onUnpin;

  const PinnedMessageBar({
    super.key,
    required this.currentLang,
    required this.text,
    required this.onTap,
    required this.onUnpin,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Material(
      color: t.surface2,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
          child: Row(
            children: [
              Icon(LucideIcons.pin, size: 15, color: t.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Закреплено'.tr(currentLang), style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: t.accent)),
                    Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: t.text2)),
                  ],
                ),
              ),
              InkWell(onTap: onUnpin, borderRadius: BorderRadius.circular(ClarifyRadius.sm), child: Padding(padding: const EdgeInsets.all(4), child: Icon(LucideIcons.pinOff, size: 17, color: t.text3))),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionItem {
  final IconData icon;
  final String label;
  final Color? color;
  final VoidCallback onTap;
  const _ActionItem({required this.icon, required this.label, this.color, required this.onTap});
}

class _ActionTile extends StatelessWidget {
  final _ActionItem item;
  const _ActionTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final color = item.color ?? t.text;
    return InkWell(
      onTap: () {
        Navigator.of(context).pop();
        item.onTap();
      },
      borderRadius: BorderRadius.circular(ClarifyRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: [
            Icon(item.icon, size: 18, color: color),
            const SizedBox(width: 12),
            Text(item.label, style: TextStyle(fontSize: 15, color: color)),
          ],
        ),
      ),
    );
  }
}

/// Меню действий над сообщением — Ответить/Переслать/Закрепить(-открепить)
/// всегда, Изменить/Удалить только для своих сообщений. Десктоп — вылет из
/// точки клика ([showClarifySurface]), мобильный — шторка снизу.
Future<void> showMessageActions({
  required BuildContext context,
  required bool isMobile,
  required bool isMine,
  required bool isPinned,
  required String currentLang,
  required VoidCallback onReply,
  required VoidCallback onForward,
  required VoidCallback onTogglePin,
  VoidCallback? onEdit,
  VoidCallback? onDelete,
}) async {
  final t = context.tokens;
  final items = <_ActionItem>[
    _ActionItem(icon: LucideIcons.reply, label: 'Ответить'.tr(currentLang), onTap: onReply),
    _ActionItem(icon: LucideIcons.forward, label: 'Переслать'.tr(currentLang), onTap: onForward),
    _ActionItem(
      icon: isPinned ? LucideIcons.pinOff : LucideIcons.pin,
      label: (isPinned ? 'Открепить' : 'Закрепить').tr(currentLang),
      onTap: onTogglePin,
    ),
    if (onEdit != null) _ActionItem(icon: LucideIcons.penLine, label: 'Изменить сообщение'.tr(currentLang), onTap: onEdit),
    if (onDelete != null) _ActionItem(icon: LucideIcons.trash2, label: 'Удалить'.tr(currentLang), color: t.danger, onTap: onDelete),
  ];

  if (isMobile) {
    await showClarifyBottomSheet(
      context: context,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [for (final item in items) _ActionTile(item: item)]),
      ),
    );
  } else {
    await showClarifySurface(
      context: context,
      builder: (context) => Center(
        child: ClarifyGlass(
          borderRadius: BorderRadius.circular(ClarifyRadius.md),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 240),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(mainAxisSize: MainAxisSize.min, children: [for (final item in items) _ActionTile(item: item)]),
            ),
          ),
        ),
      ),
    );
  }
}

class _PreviewBanner extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? text;
  final VoidCallback? onClose;

  const _PreviewBanner({required this.icon, required this.label, this.text, this.onClose});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: t.accentSoft,
        borderRadius: BorderRadius.circular(ClarifyRadius.sm),
        border: Border(left: BorderSide(color: t.accent, width: 2)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: t.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: t.accent)),
                if (text != null) Text(text!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: t.text2)),
              ],
            ),
          ),
          if (onClose != null) InkWell(onTap: onClose, child: Icon(LucideIcons.x, size: 16, color: t.text3)),
        ],
      ),
    );
  }
}

/// Композер с полями ввода и опциональными баннерами ответа/редактирования.
/// Одна и та же логика отправки для нового сообщения и сохранения правки —
/// вызывающий код решает, что означает [onSubmit], по своему состоянию
/// (реплай/эдит хранятся у него, не здесь).
class ChatComposer extends StatefulWidget {
  final String currentLang;

  /// Отправка. Файлы приходят вторым аргументом: их нельзя сохранить до того,
  /// как у сообщения появится номер, поэтому прикладывает их вызывающий — сразу
  /// после вставки сообщения.
  final Future<void> Function(String text, List<AttachmentDraft> attachments)
      onSubmit;
  final String? replyPreviewLabel;
  final String? replyPreviewText;
  final VoidCallback? onCancelReply;
  final bool isEditing;
  final String? editingInitialText;
  final VoidCallback? onCancelEdit;

  const ChatComposer({
    super.key,
    required this.currentLang,
    required this.onSubmit,
    this.replyPreviewLabel,
    this.replyPreviewText,
    this.onCancelReply,
    this.isEditing = false,
    this.editingInitialText,
    this.onCancelEdit,
  });

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  final _controller = TextEditingController();
  final List<AttachmentDraft> _drafts = [];
  bool _isSending = false;

  @override
  void didUpdateWidget(covariant ChatComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isEditing && !oldWidget.isEditing) {
      _controller.text = widget.editingInitialText ?? '';
      _controller.selection = TextSelection.collapsed(offset: _controller.text.length);
    } else if (!widget.isEditing && oldWidget.isEditing) {
      _controller.clear();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    // Сообщение из одного файла, без подписи, — нормальный случай; пустое и без
    // файлов отправлять нечего.
    if ((text.isEmpty && _drafts.isEmpty) || _isSending) return;
    final wasEditing = widget.isEditing;
    final attachments = List<AttachmentDraft>.from(_drafts);
    setState(() => _isSending = true);
    if (!wasEditing) {
      _controller.clear();
      _drafts.clear();
    }
    await widget.onSubmit(text, attachments);
    if (mounted) {
      setState(() => _isSending = false);
      if (wasEditing) _controller.clear();
    }
  }

  Future<void> _pick() async {
    final free = AttachmentService.maxPerOwner - _drafts.length;
    if (free <= 0) {
      ClarifyToast.show(
        context,
        '${'Больше файлов прикрепить нельзя, максимум '.tr(widget.currentLang)}${AttachmentService.maxPerOwner}',
        variant: ClarifyToastVariant.warning,
      );
      return;
    }
    final picked = await pickAttachmentDrafts(
      context: context,
      currentLang: widget.currentLang,
      limit: free,
    );
    if (picked.isEmpty || !mounted) return;
    setState(() => _drafts.addAll(picked));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.replyPreviewText != null)
          _PreviewBanner(
            icon: LucideIcons.reply,
            label: widget.replyPreviewLabel ?? '',
            text: widget.replyPreviewText,
            onClose: widget.onCancelReply,
          ),
        if (widget.isEditing)
          _PreviewBanner(
            icon: LucideIcons.penLine,
            label: 'Редактирование сообщения'.tr(widget.currentLang),
            onClose: widget.onCancelEdit,
          ),
        // Выбранные файлы — над полем ввода, чтобы было видно, что уйдёт
        // вместе с сообщением. При правке текста их не показываем: правка
        // меняет только текст.
        if (!widget.isEditing)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: ClarifyAttachmentDrafts(
                drafts: _drafts,
                currentLang: widget.currentLang,
                onRemove: (draft) => setState(() => _drafts.remove(draft)),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Row(
            children: [
              if (!widget.isEditing)
                IconButton(
                  icon: Icon(LucideIcons.paperclip, color: t.text3),
                  tooltip: 'Прикрепить файл'.tr(widget.currentLang),
                  onPressed: _isSending ? null : _pick,
                ),
              Expanded(
                child: TextField(
                  controller: _controller,
                  style: TextStyle(color: t.text),
                  decoration: InputDecoration(
                    hintText: 'Сообщение...'.tr(widget.currentLang),
                    hintStyle: TextStyle(color: t.text3),
                    filled: true,
                    fillColor: t.surface2,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(ClarifyRadius.pill), borderSide: BorderSide.none),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: Icon(widget.isEditing ? LucideIcons.check : LucideIcons.send, color: t.accent),
                onPressed: _isSending ? null : _submit,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

typedef ForwardTarget = ({String? partnerId, String? partnerName, int? workspaceId, String? workspaceName});

/// Выбор адресата пересылки — свой упрощённый список (личные + командные),
/// не переиспользует _DirectChatList/_TeamChatList из messenger_shell.dart,
/// потому что тем нужен выбор состояния текущего экрана, а этому — просто
/// вернуть один выбранный таргет и закрыться.
Future<void> showForwardPicker({
  required BuildContext context,
  required bool isMobile,
  required String currentLang,
  required List<Map<String, dynamic>> directConversations,
  required List<Map<String, dynamic>> teamConversations,
  required void Function(ForwardTarget target) onPicked,
}) async {
  Widget buildList(BuildContext context) {
    final t = context.tokens;
    if (directConversations.isEmpty && teamConversations.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Text('Пока нет сообщений'.tr(currentLang), style: TextStyle(color: t.text3)),
      );
    }
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        for (final c in directConversations)
          ListTile(
            leading: CircleAvatar(
              radius: 16,
              backgroundColor: t.accentSoft,
              backgroundImage: c['avatar_url'] != null ? NetworkImage(c['avatar_url'] as String) : null,
              child: c['avatar_url'] == null ? Icon(LucideIcons.user, size: 16, color: t.accent) : null,
            ),
            title: Text(((c['full_name'] as String?)?.trim().isNotEmpty ?? false) ? c['full_name'] as String : 'Без имени'.tr(currentLang)),
            onTap: () {
              Navigator.of(context).pop();
              onPicked((partnerId: c['partner_id'] as String, partnerName: c['full_name'] as String?, workspaceId: null, workspaceName: null));
            },
          ),
        for (final c in teamConversations)
          ListTile(
            leading: CircleAvatar(radius: 16, backgroundColor: t.accentSoft, child: Icon(LucideIcons.usersRound, size: 16, color: t.accent)),
            title: Text(((c['name'] as String?)?.trim().isNotEmpty ?? false) ? c['name'] as String : 'Команда'.tr(currentLang)),
            onTap: () {
              Navigator.of(context).pop();
              onPicked((partnerId: null, partnerName: null, workspaceId: (c['workspace_id'] as num).toInt(), workspaceName: c['name'] as String?));
            },
          ),
      ],
    );
  }

  if (isMobile) {
    await showClarifyBottomSheet(
      context: context,
      builder: (context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(padding: const EdgeInsets.all(16), child: Align(alignment: Alignment.centerLeft, child: Text('Переслать сообщение'.tr(currentLang), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)))),
            Flexible(child: buildList(context)),
          ],
        ),
      ),
    );
  } else {
    await showClarifySurface(
      context: context,
      builder: (context) => Center(
        child: ClarifyGlass(
          borderRadius: BorderRadius.circular(ClarifyRadius.md),
          child: SizedBox(
            width: 320,
            height: 400,
            child: Column(
              children: [
                Padding(padding: const EdgeInsets.all(16), child: Align(alignment: Alignment.centerLeft, child: Text('Переслать сообщение'.tr(currentLang), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)))),
                Expanded(child: buildList(context)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Пересылка сообщения — грузит список личных + командных диалогов, даёт
/// выбрать адресата и вставляет копию текста с пометкой forwarded_from_name.
/// Общая точка входа для десктопных панелей (личка/команда) и мобильного
/// экрана переписки — иначе загрузка списков и вставка дублировались бы
/// в трёх местах.
Future<void> forwardMessage({
  required BuildContext context,
  required bool isMobile,
  required String currentLang,
  required String text,
  required String forwardedFromName,
}) async {
  final client = Supabase.instance.client;
  final myId = client.auth.currentUser!.id;
  var directs = <Map<String, dynamic>>[];
  var teams = <Map<String, dynamic>>[];
  try {
    final d = await client.rpc('list_conversations');
    directs = List<Map<String, dynamic>>.from(d as List);
  } on PostgrestException {
    // список диалогов недоступен — пересылка всё равно возможна в команды
  }
  try {
    final w = await client.rpc('list_workspace_conversations');
    teams = List<Map<String, dynamic>>.from(w as List);
  } on PostgrestException {
    // список команд недоступен — пересылка всё равно возможна в личку
  }
  if (!context.mounted) return;

  await showForwardPicker(
    context: context,
    isMobile: isMobile,
    currentLang: currentLang,
    directConversations: directs,
    teamConversations: teams,
    onPicked: (target) async {
      try {
        if (target.partnerId != null) {
          await client.from('messages').insert({
            'from_id': myId,
            'to_id': target.partnerId,
            'text': text,
            'forwarded_from_name': forwardedFromName,
          });
        } else if (target.workspaceId != null) {
          await client.from('workspace_messages').insert({
            'workspace_id': target.workspaceId,
            'from_id': myId,
            'text': text,
            'forwarded_from_name': forwardedFromName,
          });
        }
      } on PostgrestException catch (e) {
        if (context.mounted) ClarifyToast.show(context, '${'Ошибка пересылки: '.tr(currentLang)}${e.message}', variant: ClarifyToastVariant.danger);
      }
    },
  );
}
