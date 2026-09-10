import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/attachment_prepare.dart';
import '../core/log.dart';

/// К чему прикреплено вложение.
///
/// В базе на каждого возможного владельца своя колонка с настоящим внешним
/// ключом (см. sql/attachments.sql), поэтому здесь — имя колонки и
/// идентификатор. Отдельный тип вместо трёх необязательных параметров: иначе
/// каждый вызов пришлось бы проверять на «задан ровно один», и однажды проверку
/// забыли бы.
class AttachmentOwner {
  final String column;
  final int id;

  const AttachmentOwner._(this.column, this.id);

  /// Задача.
  const AttachmentOwner.task(int id) : this._('task_id', id);

  /// Личное сообщение.
  const AttachmentOwner.message(int id) : this._('message_id', id);

  /// Сообщение в чате команды.
  const AttachmentOwner.workspaceMessage(int id)
      : this._('workspace_message_id', id);
}

/// Вложение так, как оно приходит из базы.
class Attachment {
  final int id;
  final String userId;
  final int? taskId;
  final int? messageId;
  final int? workspaceMessageId;
  final String storagePath;
  final String? thumbPath;
  final String originalName;
  final String mimeType;
  final int sizeBytes;

  const Attachment({
    required this.id,
    required this.userId,
    required this.taskId,
    required this.messageId,
    required this.workspaceMessageId,
    required this.storagePath,
    required this.thumbPath,
    required this.originalName,
    required this.mimeType,
    required this.sizeBytes,
  });

  factory Attachment.fromRow(Map<String, dynamic> row) => Attachment(
        id: row['id'] as int,
        userId: row['user_id'] as String,
        taskId: row['task_id'] as int?,
        messageId: row['message_id'] as int?,
        workspaceMessageId: row['workspace_message_id'] as int?,
        storagePath: row['storage_path'] as String,
        thumbPath: row['thumb_path'] as String?,
        originalName: row['original_name'] as String,
        mimeType: row['mime_type'] as String,
        sizeBytes: row['size_bytes'] as int,
      );

  bool get isImage => mimeType.startsWith('image/');
}

/// Загрузка, показ и удаление вложений.
///
/// Файлы лежат в приватной корзине `attachments` (см.
/// backend/clarify-backend/sql/attachments.sql), а таблица хранит только
/// описание: где файл, как назывался, сколько весит. В базу файлы не кладём —
/// её на бесплатном тарифе 500 МБ на всё, и одна фотография съела бы процент.
class AttachmentService {
  static const _bucket = 'attachments';

  /// Сколько вложений разрешено на одну задачу или сообщение.
  ///
  /// Ограничение здесь, а не в базе: это вопрос удобства, а не сохранности.
  /// Двадцать файлов в одной задаче — уже не задача, а папка, и показывать их
  /// в карточке всё равно нечем.
  static const int maxPerOwner = 10;

  SupabaseClient get _db => Supabase.instance.client;

  String get _userId {
    final id = _db.auth.currentUser?.id;
    if (id == null) throw StateError('Нет пользователя — вложение прикрепить не к кому');
    return id;
  }

  /// Прикрепляет файл к задаче или к сообщению.
  ///
  /// Тяжёлая часть (разбор и пересжатие картинки) уезжает в отдельный поток
  /// через compute: кадр с телефона декодируется заметное время, и на главном
  /// потоке это выглядело бы как зависшее приложение. На вебе compute
  /// выполняется на месте — там просто нет потоков, и это осознанный компромисс.
  Future<Attachment> attach({
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
    required AttachmentOwner owner,
  }) async {
    final prepared = await compute(
      _prepareInIsolate,
      _PrepareRequest(bytes: bytes, mimeType: mimeType),
    );

    final userId = _userId;
    // Путь из хэша содержимого: один и тот же файл, приложенный дважды,
    // занимает место один раз — вторая загрузка перезапишет его самим собой.
    final path = '$userId/${prepared.contentHash}.${prepared.extension}';
    final thumbPath = prepared.thumbnail == null
        ? null
        : '$userId/${prepared.contentHash}_thumb.jpg';

    await _uploadIfMissing(path, prepared.bytes, prepared.mimeType);
    if (prepared.thumbnail != null) {
      await _uploadIfMissing(thumbPath!, prepared.thumbnail!, 'image/jpeg');
    }

    final row = await _db
        .from('attachments')
        .insert({
          'user_id': userId,
          owner.column: owner.id,
          'storage_path': path,
          'thumb_path': thumbPath,
          'original_name': fileName,
          'mime_type': prepared.mimeType,
          'size_bytes': prepared.sizeBytes,
          'content_hash': prepared.contentHash,
        })
        .select()
        .single();

    return Attachment.fromRow(row);
  }

  /// Кладёт файл, если его там ещё нет.
  ///
  /// Повтор — не ошибка, а экономия: путь построен из хэша содержимого, значит
  /// файл по этому пути уже БИТ В БИТ тот же, и загружать его второй раз нечего.
  ///
  /// Намеренно без upsert, хотя он выглядел бы короче. Перезапись заставляет
  /// хранилище прочитать существующий объект, а читать его разрешено только при
  /// наличии описания в attachments (см. sql/attachments.sql) — а описание
  /// появляется ПОСЛЕ загрузки. Проверено живьём: с upsert загрузка падает с
  /// отказом по правилам доступа, без него проходит.
  Future<void> _uploadIfMissing(
    String path,
    Uint8List bytes,
    String contentType,
  ) async {
    try {
      await _db.storage.from(_bucket).uploadBinary(
            path,
            bytes,
            fileOptions: FileOptions(contentType: contentType),
          );
    } on StorageException catch (e) {
      if (e.statusCode == '409') return;
      rethrow;
    }
  }

  /// Вложения задачи или сообщения.
  Future<List<Attachment>> listFor(AttachmentOwner owner) async {
    final rows = await _db
        .from('attachments')
        .select()
        .eq(owner.column, owner.id)
        .order('created_at');
    return rows.map((r) => Attachment.fromRow(r)).toList();
  }

  /// Вложения сразу к нескольким сообщениям — одним запросом.
  ///
  /// Переписка грузится целиком, и запрос на каждый пузырь означал бы сотню
  /// обращений при открытии чата. Возвращает только тех, у кого вложения есть.
  Future<Map<int, List<Attachment>>> listForMany(
    String column,
    List<int> ids,
  ) async {
    if (ids.isEmpty) return const {};
    final rows = await _db
        .from('attachments')
        .select()
        .inFilter(column, ids.toSet().toList())
        .order('created_at');
    final grouped = <int, List<Attachment>>{};
    for (final row in rows) {
      final attachment = Attachment.fromRow(row);
      final ownerId = row[column] as int;
      grouped.putIfAbsent(ownerId, () => []).add(attachment);
    }
    return grouped;
  }

  /// Ссылка на файл, живущая ограниченное время.
  ///
  /// Корзина приватная, постоянной публичной ссылки у файла нет — иначе
  /// достаточно было бы один раз её узнать, чтобы читать чужое вложение вечно,
  /// даже потеряв доступ к самой задаче.
  ///
  /// [downloadAs] включает скачивание под настоящим именем: в хранилище файл
  /// лежит под хэшем, и без этого человек получил бы документ с именем вида
  /// «3f9a…c1.pdf».
  Future<String> signedUrl(
    String path, {
    Duration ttl = const Duration(hours: 1),
    String? downloadAs,
  }) =>
      _db.storage.from(_bucket).createSignedUrl(
            path,
            ttl.inSeconds,
            download: downloadAs == null ? null : DownloadBehavior.named(downloadAs),
          );

  /// Ссылки сразу на несколько файлов — одним запросом.
  ///
  /// Для списка превью это важно: иначе открытие задачи с десятью вложениями
  /// означало бы десять отдельных обращений к серверу.
  ///
  /// Пути, которые подписать не удалось (файл пропал), в ответе просто
  /// отсутствуют — вызывающий показывает вместо них заглушку, а не падает.
  Future<Map<String, String>> signedUrls(
    List<String> paths, {
    Duration ttl = const Duration(hours: 1),
  }) async {
    if (paths.isEmpty) return const {};
    final results = await _db.storage
        .from(_bucket)
        .createSignedUrlsResult(paths.toSet().toList(), ttl.inSeconds);
    final urls = <String, String>{};
    for (final result in results) {
      if (result case SignedUrlSuccess(:final path, :final signedUrl)) {
        urls[path] = signedUrl;
      }
    }
    return urls;
  }

  /// Удаляет вложение вместе с файлом.
  ///
  /// Файл сносим ТОЛЬКО если на него не ссылается никто больше: путь построен
  /// из хэша содержимого, поэтому один и тот же файл может быть приложен к
  /// нескольким задачам, и удаление одной из них не должно оставлять остальные
  /// с битой картинкой.
  Future<void> remove(Attachment attachment) async {
    await _db.from('attachments').delete().eq('id', attachment.id);

    final others = await _db
        .from('attachments')
        .select('id')
        .eq('storage_path', attachment.storagePath)
        .limit(1);
    if (others.isNotEmpty) return;

    try {
      await _db.storage.from(_bucket).remove([
        attachment.storagePath,
        if (attachment.thumbPath != null) attachment.thumbPath!,
      ]);
    } catch (e) {
      // Строку из таблицы мы уже убрали, вложение из интерфейса исчезло.
      // Оставшийся файл — это занятое место, а не поломка: перегружать этим
      // человека незачем, но в журнале след нужен.
      logError('Файл вложения не удалился из хранилища: $e');
    }
  }
}

/// Аргумент для [compute] — он принимает ровно один параметр.
class _PrepareRequest {
  final Uint8List bytes;
  final String mimeType;
  const _PrepareRequest({required this.bytes, required this.mimeType});
}

/// Верхнеуровневая функция: compute не умеет запускать методы объекта.
PreparedAttachment _prepareInIsolate(_PrepareRequest request) =>
    prepareAttachment(bytes: request.bytes, mimeType: request.mimeType);
