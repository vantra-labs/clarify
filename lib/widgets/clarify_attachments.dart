import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/localization.dart';
import '../core/log.dart';
import '../core/theme/design_tokens.dart';
import '../services/attachment_service.dart';
import 'clarify_toast.dart';

/// Вложения: плитки с превью, добавление по скрепке, просмотр и удаление.
///
/// Одно и то же используется и в задаче, и в сообщении — отличается только
/// владелец и тем, можно ли здесь править. Повторять разметку в трёх местах
/// значило бы трижды её потом и чинить.

/// Предел на один файл. Тот же, что в базе и в корзине хранилища; проверяем и
/// здесь, чтобы человек узнал об отказе сразу, а не после загрузки десяти
/// мегабайт по мобильной сети.
const int kMaxAttachmentBytes = 25 * 1024 * 1024;

/// Выбранный, но ещё не отправленный файл.
///
/// Нужен мессенджеру: вложение привязывается к сообщению, а его номер
/// появляется только после отправки. Поэтому файлы сначала ждут здесь.
class AttachmentDraft {
  final Uint8List bytes;
  final String fileName;
  final String mimeType;

  const AttachmentDraft({
    required this.bytes,
    required this.fileName,
    required this.mimeType,
  });

  bool get isImage => mimeType.startsWith('image/');
}

/// Открывает выбор файлов и возвращает годные.
///
/// Слишком большие отсеиваются здесь же, с понятным сообщением: это единственное
/// место, где человек ещё может что-то изменить.
Future<List<AttachmentDraft>> pickAttachmentDrafts({
  required BuildContext context,
  required String currentLang,
  int limit = AttachmentService.maxPerOwner,
}) async {
  final result = await FilePicker.platform.pickFiles(
    allowMultiple: true,
    // Без withData на десктопе приходит только путь, а нам нужны сами байты:
    // сжатие и хэш считаются до отправки.
    withData: true,
  );
  if (result == null) return const [];

  final drafts = <AttachmentDraft>[];
  final tooBig = <String>[];
  for (final file in result.files) {
    final bytes = file.bytes;
    if (bytes == null) continue;
    if (bytes.length > kMaxAttachmentBytes) {
      tooBig.add(file.name);
      continue;
    }
    drafts.add(AttachmentDraft(
      bytes: bytes,
      fileName: file.name,
      mimeType: _mimeForName(file.name),
    ));
    if (drafts.length >= limit) break;
  }

  if (tooBig.isNotEmpty && context.mounted) {
    ClarifyToast.show(
      context,
      '${'Слишком большой файл (максимум 25 МБ): '.tr(currentLang)}${tooBig.join(', ')}',
      variant: ClarifyToastVariant.warning,
    );
  }
  return drafts;
}

/// Раздел вложений у задачи или сообщения.
class ClarifyAttachments extends StatefulWidget {
  final AttachmentOwner owner;
  final String currentLang;

  /// Можно ли добавлять и удалять. У чужого сообщения — только смотреть.
  final bool canEdit;

  /// Подпись над плитками. В пузыре сообщения не нужна — там и так видно.
  final bool showHeader;

  /// Зовётся после добавления или удаления: задаче нужно обновить свою карточку
  /// (на ней показывается количество вложений).
  final VoidCallback? onChanged;

  const ClarifyAttachments({
    super.key,
    required this.owner,
    required this.currentLang,
    this.canEdit = false,
    this.showHeader = true,
    this.onChanged,
  });

  @override
  State<ClarifyAttachments> createState() => _ClarifyAttachmentsState();
}

class _ClarifyAttachmentsState extends State<ClarifyAttachments> {
  final _service = AttachmentService();
  List<Attachment>? _items;
  Map<String, String> _urls = const {};
  int _uploading = 0;
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await _service.listFor(widget.owner);
      final urls = await _service.signedUrls(
        items.map((a) => a.thumbPath ?? a.storagePath).toList(),
      );
      if (!mounted) return;
      setState(() {
        _items = items;
        _urls = urls;
        _loadError = null;
      });
    } catch (e) {
      logError('Не удалось загрузить вложения: $e');
      if (mounted) {
        setState(() {
          _items = const [];
          _loadError = e;
        });
      }
    }
  }

  Future<void> _add() async {
    final items = _items ?? const <Attachment>[];
    final free = AttachmentService.maxPerOwner - items.length;
    if (free <= 0) {
      ClarifyToast.show(
        context,
        '${'Больше файлов прикрепить нельзя, максимум '.tr(widget.currentLang)}${AttachmentService.maxPerOwner}',
        variant: ClarifyToastVariant.warning,
      );
      return;
    }

    final drafts = await pickAttachmentDrafts(
      context: context,
      currentLang: widget.currentLang,
      limit: free,
    );
    if (drafts.isEmpty || !mounted) return;

    setState(() => _uploading = drafts.length);
    for (final draft in drafts) {
      try {
        await _service.attach(
          bytes: draft.bytes,
          fileName: draft.fileName,
          mimeType: draft.mimeType,
          owner: widget.owner,
        );
      } catch (e) {
        logError('Не удалось приложить файл: $e');
        if (mounted) {
          ClarifyToast.show(
            context,
            '${'Файл не приложился: '.tr(widget.currentLang)}${draft.fileName}',
            variant: ClarifyToastVariant.danger,
          );
        }
      }
      if (mounted) setState(() => _uploading--);
    }
    if (!mounted) return;
    setState(() => _uploading = 0);
    await _load();
    widget.onChanged?.call();
  }

  Future<void> _remove(Attachment attachment) async {
    setState(() => _items = [..._items!]..remove(attachment));
    try {
      await _service.remove(attachment);
    } catch (e) {
      logError('Не удалось удалить вложение: $e');
      if (mounted) {
        ClarifyToast.show(
          context,
          'Вложение не удалилось'.tr(widget.currentLang),
          variant: ClarifyToastVariant.danger,
        );
      }
      await _load();
      return;
    }
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final items = _items;

    // Пока грузим — ничего не показываем вместо заголовка с пустотой: раздел
    // вложений у большинства задач пуст, и мигающая пустая рамка при каждом
    // открытии раздражала бы сильнее, чем задержка в полсекунды.
    if (items == null) return const SizedBox.shrink();
    if (items.isEmpty && !widget.canEdit && _loadError == null) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.showHeader) ...[
          Row(
            children: [
              Icon(LucideIcons.paperclip, size: 16, color: t.text3),
              const SizedBox(width: 8),
              Text(
                'Вложения'.tr(widget.currentLang),
                style: TextStyle(color: t.text3, fontSize: 14),
              ),
              if (items.isNotEmpty) ...[
                const Spacer(),
                Text(
                  '${items.length}/${AttachmentService.maxPerOwner}',
                  style: TextStyle(color: t.text3, fontSize: 13),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
        ],
        if (_loadError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Вложения не загрузились'.tr(widget.currentLang),
              style: TextStyle(color: t.danger, fontSize: 13),
            ),
          ),
        ClarifyAttachmentTiles(
          attachments: items,
          previewUrls: _urls,
          currentLang: widget.currentLang,
          onRemove: widget.canEdit ? _remove : null,
          uploadingCount: _uploading,
          onAdd: widget.canEdit &&
                  items.length + _uploading < AttachmentService.maxPerOwner
              ? _add
              : null,
        ),
      ],
    );
  }
}

/// Размер плитки. Достаточно, чтобы узнать фотографию, и достаточно мало, чтобы
/// шесть вложений влезли в узкий диалог.
const double _tileSize = 72;

/// Ряд плиток вложений.
///
/// Отдельно от [ClarifyAttachments], потому что в переписке вложения грузит сам
/// чат — одним запросом на все сообщения сразу. Запрос на каждый пузырь означал
/// бы сотню обращений при открытии диалога.
class ClarifyAttachmentTiles extends StatelessWidget {
  final List<Attachment> attachments;

  /// Ссылки на превью по пути файла. Чего нет — покажется значком.
  final Map<String, String> previewUrls;
  final String currentLang;

  /// null — убирать нельзя (чужое сообщение, окно деталей).
  final void Function(Attachment attachment)? onRemove;

  /// Сколько файлов прямо сейчас уезжает в хранилище.
  final int uploadingCount;

  /// null — добавлять нечем (нет права или достигнут предел).
  final VoidCallback? onAdd;

  const ClarifyAttachmentTiles({
    super.key,
    required this.attachments,
    required this.previewUrls,
    required this.currentLang,
    this.onRemove,
    this.uploadingCount = 0,
    this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final attachment in attachments)
          _AttachmentTile(
            attachment: attachment,
            previewUrl: previewUrls[attachment.thumbPath ?? attachment.storagePath],
            currentLang: currentLang,
            onTap: () => openAttachment(
              context: context,
              attachment: attachment,
              currentLang: currentLang,
            ),
            onRemove: onRemove == null ? null : () => onRemove!(attachment),
          ),
        for (var i = 0; i < uploadingCount; i++) const _UploadingTile(),
        if (onAdd != null) _AddTile(currentLang: currentLang, onTap: onAdd!),
      ],
    );
  }
}

/// Открывает вложение: картинку — на весь экран, остальное — системой.
Future<void> openAttachment({
  required BuildContext context,
  required Attachment attachment,
  required String currentLang,
}) async {
  final service = AttachmentService();
  void complain() {
    if (context.mounted) {
      ClarifyToast.show(
        context,
        'Не удалось открыть файл'.tr(currentLang),
        variant: ClarifyToastVariant.danger,
      );
    }
  }

  try {
    if (attachment.isImage) {
      final url = await service.signedUrl(attachment.storagePath);
      if (!context.mounted) return;
      showAttachmentViewer(
        context: context,
        url: url,
        title: attachment.originalName,
      );
      return;
    }
    // Не картинка — отдаём системе: там и просмотрщик документов, и папка
    // загрузок. Имя подставляем настоящее, иначе скачается хэш.
    final url = await service.signedUrl(
      attachment.storagePath,
      downloadAs: attachment.originalName,
    );
    final launched = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!launched) complain();
  } catch (e) {
    logError('Не удалось открыть вложение: $e');
    complain();
  }
}

class _AttachmentTile extends StatelessWidget {
  final Attachment attachment;
  final String? previewUrl;
  final String currentLang;
  final VoidCallback onTap;
  final VoidCallback? onRemove;

  const _AttachmentTile({
    required this.attachment,
    required this.previewUrl,
    required this.currentLang,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return SizedBox(
      width: _tileSize,
      height: _tileSize,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: Tooltip(
              message: '${attachment.originalName}\n${formatBytes(attachment.sizeBytes, currentLang)}',
              child: Material(
                color: t.surfaceSunken,
                borderRadius: BorderRadius.circular(ClarifyRadius.sm),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: onTap,
                  child: attachment.isImage && previewUrl != null
                      ? Image.network(
                          previewUrl!,
                          fit: BoxFit.cover,
                          // Картинка может не дойти (сеть, истёкшая ссылка) —
                          // показываем значок файла вместо серого провала.
                          errorBuilder: (context, _, _) =>
                              _FileFace(attachment: attachment),
                        )
                      : _FileFace(attachment: attachment),
                ),
              ),
            ),
          ),
          if (onRemove != null)
            Positioned(
              top: -6,
              right: -6,
              child: Tooltip(
                message: 'Убрать'.tr(currentLang),
                child: InkWell(
                  onTap: onRemove,
                  borderRadius: BorderRadius.circular(ClarifyRadius.pill),
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: t.surface2,
                      shape: BoxShape.circle,
                      border: Border.all(color: t.border),
                    ),
                    child: Icon(LucideIcons.x, size: 13, color: t.danger),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Лицо файла, у которого нет превью: значок по типу и расширение.
class _FileFace extends StatelessWidget {
  final Attachment attachment;

  const _FileFace({required this.attachment});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final name = attachment.originalName;
    final dot = name.lastIndexOf('.');
    final ext = dot > 0 && dot < name.length - 1
        ? name.substring(dot + 1).toUpperCase()
        : '';
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(iconForMime(attachment.mimeType), size: 24, color: t.accent),
        if (ext.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            ext.length > 5 ? ext.substring(0, 5) : ext,
            style: TextStyle(color: t.text3, fontSize: 10, fontWeight: FontWeight.bold),
          ),
        ],
      ],
    );
  }
}

class _UploadingTile extends StatelessWidget {
  const _UploadingTile();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      width: _tileSize,
      height: _tileSize,
      decoration: BoxDecoration(
        color: t.surfaceSunken,
        borderRadius: BorderRadius.circular(ClarifyRadius.sm),
        border: Border.all(color: t.border),
      ),
      child: Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2, color: t.accent),
        ),
      ),
    );
  }
}

class _AddTile extends StatelessWidget {
  final String currentLang;
  final VoidCallback onTap;

  const _AddTile({required this.currentLang, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Tooltip(
      message: 'Прикрепить файл'.tr(currentLang),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(ClarifyRadius.sm),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(ClarifyRadius.sm),
          child: Container(
            width: _tileSize,
            height: _tileSize,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(ClarifyRadius.sm),
              border: Border.all(color: t.border),
            ),
            child: Icon(LucideIcons.paperclip, size: 22, color: t.text3),
          ),
        ),
      ),
    );
  }
}

/// Просмотр картинки на весь экран.
///
/// С возможностью приблизить: вложение к задаче — это часто снимок документа
/// или сметы, и мелкий текст на нём нужно разглядеть.
void showAttachmentViewer({
  required BuildContext context,
  required String url,
  required String title,
}) {
  showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.9),
    builder: (context) => Stack(
      children: [
        Positioned.fill(
          child: InteractiveViewer(
            maxScale: 6,
            child: Center(
              child: Image.network(
                url,
                fit: BoxFit.contain,
                errorBuilder: (context, _, _) => const Icon(
                  LucideIcons.imageOff,
                  color: Colors.white54,
                  size: 48,
                ),
              ),
            ),
          ),
        ),
        // Закрытие по тапу мимо картинки намеренно НЕ делаем: при попытке
        // приблизить палец часто оказывается на чёрном поле, и снимок
        // закрывался бы вместо увеличения.
        Positioned(
          top: MediaQuery.of(context).padding.top + 8,
          right: 8,
          child: IconButton(
            icon: const Icon(LucideIcons.x, color: Colors.white),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        Positioned(
          bottom: MediaQuery.of(context).padding.bottom + 16,
          left: 24,
          right: 24,
          child: Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ),
      ],
    ),
  );
}

/// Значок по типу файла.
IconData iconForMime(String mimeType) {
  final mime = mimeType.toLowerCase();
  if (mime.startsWith('image/')) return LucideIcons.image;
  if (mime.startsWith('video/')) return LucideIcons.video;
  if (mime.startsWith('audio/')) return LucideIcons.music;
  if (mime == 'application/pdf') return LucideIcons.fileText;
  if (mime.contains('zip') || mime.contains('rar') || mime.contains('7z')) {
    return LucideIcons.fileArchive;
  }
  if (mime.contains('sheet') || mime.contains('excel') || mime.contains('csv')) {
    return LucideIcons.fileSpreadsheet;
  }
  return LucideIcons.file;
}

/// Размер файла по-человечески.
String formatBytes(int bytes, String lang) {
  if (bytes < 1024) return '$bytes ${'Б'.tr(lang)}';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).round()} ${'КБ'.tr(lang)}';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} ${'МБ'.tr(lang)}';
}

/// Тип файла по расширению.
///
/// Свой разбор, а не пакет mime: нужны ровно те типы, которые умеет сжимать
/// attachment_prepare (для остальных тип идёт в базу как есть и ни на что не
/// влияет), и тащить зависимость ради десяти строк незачем.
String _mimeForName(String fileName) {
  final dot = fileName.lastIndexOf('.');
  final ext = dot > 0 ? fileName.substring(dot + 1).toLowerCase() : '';
  return switch (ext) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'webp' => 'image/webp',
    'gif' => 'image/gif',
    'bmp' => 'image/bmp',
    'tif' || 'tiff' => 'image/tiff',
    'heic' => 'image/heic',
    'pdf' => 'application/pdf',
    'txt' => 'text/plain',
    'doc' || 'docx' => 'application/msword',
    'xls' || 'xlsx' => 'application/vnd.ms-excel',
    'csv' => 'text/csv',
    'zip' => 'application/zip',
    'rar' => 'application/vnd.rar',
    '7z' => 'application/x-7z-compressed',
    'mp4' => 'video/mp4',
    'mov' => 'video/quicktime',
    'mp3' => 'audio/mpeg',
    'm4a' => 'audio/mp4',
    'wav' => 'audio/wav',
    _ => 'application/octet-stream',
  };
}

/// Плитки выбранных, но ещё не отправленных файлов — над полем ввода.
class ClarifyAttachmentDrafts extends StatelessWidget {
  final List<AttachmentDraft> drafts;
  final String currentLang;
  final void Function(AttachmentDraft draft) onRemove;

  const ClarifyAttachmentDrafts({
    super.key,
    required this.drafts,
    required this.currentLang,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    if (drafts.isEmpty) return const SizedBox.shrink();
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: drafts.map((draft) {
          return Container(
            padding: const EdgeInsets.only(left: 10, right: 4, top: 4, bottom: 4),
            decoration: BoxDecoration(
              color: t.surfaceSunken,
              borderRadius: BorderRadius.circular(ClarifyRadius.pill),
              border: Border.all(color: t.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(iconForMime(draft.mimeType), size: 15, color: t.accent),
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 140),
                  child: Text(
                    draft.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: t.text2, fontSize: 13),
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  formatBytes(draft.bytes.length, currentLang),
                  style: TextStyle(color: t.text3, fontSize: 11),
                ),
                IconButton(
                  icon: Icon(LucideIcons.x, size: 14, color: t.text3),
                  constraints: const BoxConstraints(),
                  padding: const EdgeInsets.all(4),
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Убрать'.tr(currentLang),
                  onPressed: () => onRemove(draft),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// Вложения всей переписки: по номеру сообщения плюс готовые ссылки на превью.
class ChatAttachments {
  final Map<int, List<Attachment>> byMessage;
  final Map<String, String> previewUrls;

  const ChatAttachments({required this.byMessage, required this.previewUrls});

  /// Пустой набор — состояние «ещё не грузили» и «вложений нет» для чата
  /// неразличимы: в обоих случаях рисовать нечего.
  static const empty = ChatAttachments(byMessage: {}, previewUrls: {});

  List<Attachment> of(dynamic messageId) =>
      byMessage[(messageId as num?)?.toInt()] ?? const [];
}

/// Грузит вложения сразу всей переписки — два запроса вместо двух на сообщение.
///
/// [column] — `message_id` для личных чатов, `workspace_message_id` для чатов
/// команды.
///
/// Ошибку не пробрасывает: переписка важнее вложений, и чат, не открывшийся
/// из-за упавшего запроса превью, был бы худшим исходом.
Future<ChatAttachments> loadChatAttachments({
  required String column,
  required List<int> messageIds,
}) async {
  if (messageIds.isEmpty) return ChatAttachments.empty;
  final service = AttachmentService();
  try {
    final byMessage = await service.listForMany(column, messageIds);
    if (byMessage.isEmpty) return ChatAttachments.empty;
    final paths = byMessage.values
        .expand((list) => list)
        .map((a) => a.thumbPath ?? a.storagePath)
        .toList();
    return ChatAttachments(
      byMessage: byMessage,
      previewUrls: await service.signedUrls(paths),
    );
  } catch (e) {
    logError('Не удалось загрузить вложения переписки: $e');
    return ChatAttachments.empty;
  }
}

/// Отправляет выбранные файлы уже существующему владельцу.
///
/// Отдельная функция, а не метод виджета: мессенджер зовёт её после вставки
/// сообщения, когда собственного состояния вложений у него ещё нет.
///
/// Ошибку отдельного файла не превращаем в отказ целиком: сообщение уже
/// отправлено, и откатывать его из-за одной неудачной картинки хуже, чем
/// сказать, что именно не дошло.
Future<List<String>> uploadAttachmentDrafts({
  required List<AttachmentDraft> drafts,
  required AttachmentOwner owner,
}) async {
  final service = AttachmentService();
  final failed = <String>[];
  for (final draft in drafts) {
    try {
      await service.attach(
        bytes: draft.bytes,
        fileName: draft.fileName,
        mimeType: draft.mimeType,
        owner: owner,
      );
    } catch (e) {
      logError('Вложение не отправилось (${draft.fileName}): $e');
      failed.add(draft.fileName);
    }
  }
  return failed;
}
