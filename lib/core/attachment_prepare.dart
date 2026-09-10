import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;

/// Подготовка файла к отправке: сжатие картинок, превью, хэш содержимого.
///
/// Зачем вообще: снимок с телефона весит около пяти мегабайт, потому что несёт
/// разрешение, которого на экране всё равно не видно. На бесплатном тарифе
/// хранилища гигабайт — это двести таких снимков. После уменьшения до 1600
/// точек по длинной стороне тот же кадр весит около трёхсот килобайт, и в тот
/// же гигабайт помещается три тысячи. Экономия в пятнадцать раз достаётся
/// бесплатно: считает устройство, а не сервер.
///
/// Здесь только чистые функции над байтами — ни файловой системы, ни сети.
/// Так это можно проверить тестами, не поднимая ни хранилище, ни браузер.

/// Длинная сторона, до которой ужимаются картинки.
///
/// 1600 — компромисс: этого хватает, чтобы прочитать текст на фотографии
/// документа и рассмотреть деталь на скриншоте, но уже вчетверо меньше по
/// площади, чем типичный кадр телефона.
const int kMaxImageDimension = 1600;

/// Длинная сторона превью для списков.
const int kThumbDimension = 240;

/// Качество JPEG. Ниже 80 на фотографиях появляется заметная «грязь» вокруг
/// контрастных границ — как раз там, где на скриншотах текст.
const int kJpegQuality = 80;

/// Что получилось после подготовки.
class PreparedAttachment {
  /// Байты, которые пойдут в хранилище.
  final Uint8List bytes;

  /// Уменьшенная копия для списка. null — если превью не имеет смысла
  /// (не картинка) или исходник и так меньше превью.
  final Uint8List? thumbnail;

  /// MIME итогового файла: у пересжатой картинки он всегда image/jpeg,
  /// даже если исходник был PNG или HEIC.
  final String mimeType;

  /// Расширение для пути в хранилище, без точки.
  final String extension;

  /// SHA-256 итоговых байтов. По нему строится путь, поэтому один и тот же
  /// файл, приложенный дважды, физически лежит один раз.
  final String contentHash;

  /// Сжали ли мы файл вообще (для показа человеку и для тестов).
  final bool wasRecompressed;

  const PreparedAttachment({
    required this.bytes,
    required this.thumbnail,
    required this.mimeType,
    required this.extension,
    required this.contentHash,
    required this.wasRecompressed,
  });

  int get sizeBytes => bytes.length;
}

/// Форматы, которые имеет смысл пересжимать.
///
/// Всё остальное — уже сжатое (видео, pdf, архивы, документы Office): попытка
/// ужать их даст проценты и потратит время. Единственная реальная экономия там
/// — не прикладывать лишнего, а это решает человек, а не код.
bool isRecompressableImage(String mimeType) => const {
      'image/jpeg',
      'image/jpg',
      'image/png',
      'image/webp',
      'image/bmp',
      'image/tiff',
    }.contains(mimeType.toLowerCase());

/// Готовит файл к отправке.
///
/// Не-картинки проходят насквозь: считается только хэш. Картинки декодируются,
/// разворачиваются по EXIF, уменьшаются и пересохраняются в JPEG.
PreparedAttachment prepareAttachment({
  required Uint8List bytes,
  required String mimeType,
  int maxDimension = kMaxImageDimension,
  int quality = kJpegQuality,
}) {
  if (!isRecompressableImage(mimeType)) {
    return PreparedAttachment(
      bytes: bytes,
      thumbnail: null,
      mimeType: mimeType,
      extension: _extensionForMime(mimeType),
      contentHash: sha256.convert(bytes).toString(),
      wasRecompressed: false,
    );
  }

  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    // Заявленный тип не совпал с содержимым (битый файл, чужое расширение).
    // Отправляем как есть: потерять вложение хуже, чем не сэкономить на нём.
    return PreparedAttachment(
      bytes: bytes,
      thumbnail: null,
      mimeType: mimeType,
      extension: _extensionForMime(mimeType),
      contentHash: sha256.convert(bytes).toString(),
      wasRecompressed: false,
    );
  }

  // Разворот по EXIF до изменения размера: иначе портретный снимок с телефона
  // уедет в хранилище лежащим на боку — камеры пишут кадр как есть, а поворот
  // держат отдельной меткой, которая после пересохранения теряется.
  final upright = img.bakeOrientation(decoded);

  final resized = _fitWithin(upright, maxDimension);
  final encoded = Uint8List.fromList(img.encodeJpg(resized, quality: quality));

  // Если «сжатый» вариант оказался больше исходника — берём исходник. Так
  // бывает с маленькими картинками и со скриншотами в PNG, где плоские заливки
  // жмутся лучше, чем фотографический JPEG.
  final keepOriginal = encoded.length >= bytes.length;
  final resultBytes = keepOriginal ? bytes : encoded;
  final resultMime = keepOriginal ? mimeType : 'image/jpeg';

  final thumbSource = keepOriginal ? upright : resized;
  final thumb = Uint8List.fromList(
    img.encodeJpg(_fitWithin(thumbSource, kThumbDimension), quality: kJpegQuality),
  );

  return PreparedAttachment(
    bytes: resultBytes,
    // Превью нужно только если оно реально меньше самого файла: у маленькой
    // иконки хранить рядом ещё одну копию того же размера бессмысленно.
    thumbnail: thumb.length < resultBytes.length ? thumb : null,
    mimeType: resultMime,
    extension: keepOriginal ? _extensionForMime(mimeType) : 'jpg',
    contentHash: sha256.convert(resultBytes).toString(),
    wasRecompressed: !keepOriginal,
  );
}

/// Вписывает картинку в квадрат со стороной [maxDimension], сохраняя пропорции.
/// Картинку меньше указанного размера не трогает — растягивание только испортит
/// её и увеличит вес.
img.Image _fitWithin(img.Image source, int maxDimension) {
  final longest =
      source.width > source.height ? source.width : source.height;
  if (longest <= maxDimension) return source;

  return source.width >= source.height
      ? img.copyResize(source, width: maxDimension)
      : img.copyResize(source, height: maxDimension);
}

String _extensionForMime(String mimeType) => switch (mimeType.toLowerCase()) {
      'image/jpeg' || 'image/jpg' => 'jpg',
      'image/png' => 'png',
      'image/webp' => 'webp',
      'image/gif' => 'gif',
      'image/heic' => 'heic',
      'application/pdf' => 'pdf',
      'text/plain' => 'txt',
      _ => 'bin',
    };
