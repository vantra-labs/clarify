import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/core/attachment_prepare.dart';
import 'package:image/image.dart' as img;

/// Картинка, похожая на настоящий кадр с телефона: 4032×3024 с плавными
/// переходами и шумом. Ровная заливка сжалась бы в килобайты и дала бы
/// неправдоподобно радостные цифры.
Uint8List cameraLikePhoto({int width = 4032, int height = 3024}) {
  final image = img.Image(width: width, height: height);
  final random = Random(42);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final r = (x * 255 ~/ width) + random.nextInt(24);
      final g = (y * 255 ~/ height) + random.nextInt(24);
      final b = ((x + y) * 255 ~/ (width + height)) + random.nextInt(24);
      image.setPixelRgb(x, y, r.clamp(0, 255), g.clamp(0, 255), b.clamp(0, 255));
    }
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 92));
}

void main() {
  group('подготовка вложения', () {
    test('снимок с телефона ужимается в разы', () {
      final original = cameraLikePhoto();
      final prepared = prepareAttachment(bytes: original, mimeType: 'image/jpeg');

      final ratio = original.length / prepared.sizeBytes;
      // Печатаем, чтобы экономия была видна цифрой, а не только утверждением.
      // ignore: avoid_print
      print('исходник ${original.length ~/ 1024} КБ → '
          '${prepared.sizeBytes ~/ 1024} КБ (в ${ratio.toStringAsFixed(1)} раза)');

      expect(prepared.wasRecompressed, isTrue);
      expect(prepared.sizeBytes, lessThan(original.length));
      expect(ratio, greaterThan(3));
    });

    test('длинная сторона не превышает предел, пропорции сохранены', () {
      final original = cameraLikePhoto(width: 4032, height: 3024);
      final prepared = prepareAttachment(bytes: original, mimeType: 'image/jpeg');

      final decoded = img.decodeImage(prepared.bytes)!;
      expect(max(decoded.width, decoded.height), kMaxImageDimension);
      // 4:3 должно остаться 4:3 — с точностью до округления на целых пикселях.
      expect(decoded.width / decoded.height, closeTo(4 / 3, 0.01));
    });

    test('вертикальный кадр остаётся вертикальным', () {
      final original = cameraLikePhoto(width: 3024, height: 4032);
      final prepared = prepareAttachment(bytes: original, mimeType: 'image/jpeg');

      final decoded = img.decodeImage(prepared.bytes)!;
      expect(decoded.height, greaterThan(decoded.width),
          reason: 'портретный снимок не должен лечь на бок');
      expect(max(decoded.width, decoded.height), kMaxImageDimension);
    });

    test('маленькую картинку не растягиваем и не портим', () {
      final small = Uint8List.fromList(
        img.encodeJpg(cameraLikeSmall(), quality: 85),
      );
      final prepared = prepareAttachment(bytes: small, mimeType: 'image/jpeg');

      final decoded = img.decodeImage(prepared.bytes)!;
      expect(max(decoded.width, decoded.height), lessThanOrEqualTo(200));
      expect(prepared.sizeBytes, lessThanOrEqualTo(small.length),
          reason: 'подготовка не должна увеличивать файл');
    });

    test('превью заметно меньше самого файла', () {
      final original = cameraLikePhoto();
      final prepared = prepareAttachment(bytes: original, mimeType: 'image/jpeg');

      expect(prepared.thumbnail, isNotNull);
      expect(prepared.thumbnail!.length, lessThan(prepared.sizeBytes ~/ 3));
      final thumb = img.decodeImage(prepared.thumbnail!)!;
      expect(max(thumb.width, thumb.height), kThumbDimension);
    });

    test('уже сжатое не трогаем: pdf проходит байт в байт', () {
      final pdf = Uint8List.fromList(List.generate(5000, (i) => i % 256));
      final prepared =
          prepareAttachment(bytes: pdf, mimeType: 'application/pdf');

      expect(prepared.wasRecompressed, isFalse);
      expect(prepared.bytes, equals(pdf));
      expect(prepared.thumbnail, isNull);
      expect(prepared.extension, 'pdf');
    });

    test('битый файл не теряется, а уходит как есть', () {
      // Заявлен image/png, а внутри мусор: потерять вложение хуже, чем не
      // сэкономить на нём.
      final broken = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      final prepared =
          prepareAttachment(bytes: broken, mimeType: 'image/png');

      expect(prepared.wasRecompressed, isFalse);
      expect(prepared.bytes, equals(broken));
    });

    test('одинаковое содержимое даёт одинаковый хэш, разное — разный', () {
      final a = prepareAttachment(
          bytes: Uint8List.fromList([9, 9, 9]), mimeType: 'application/pdf');
      final b = prepareAttachment(
          bytes: Uint8List.fromList([9, 9, 9]), mimeType: 'application/pdf');
      final c = prepareAttachment(
          bytes: Uint8List.fromList([9, 9, 8]), mimeType: 'application/pdf');

      expect(a.contentHash, b.contentHash,
          reason: 'на этом держится хранение одного файла в единственном экземпляре');
      expect(a.contentHash, isNot(c.contentHash));
    });

    test('пересохранение срезает EXIF вместе с координатами съёмки', () {
      final original = cameraLikePhoto(width: 2000, height: 1500);
      final prepared =
          prepareAttachment(bytes: original, mimeType: 'image/jpeg');

      final decoded = img.decodeImage(prepared.bytes)!;
      expect(decoded.exif.gpsIfd.isEmpty, isTrue,
          reason: 'геометки не должны уезжать в хранилище вместе с фотографией');
    });
  });
}

/// Маленькая картинка (200×150) — заведомо меньше предела уменьшения.
img.Image cameraLikeSmall() {
  final image = img.Image(width: 200, height: 150);
  final random = Random(7);
  for (var y = 0; y < 150; y++) {
    for (var x = 0; x < 200; x++) {
      image.setPixelRgb(x, y, random.nextInt(256), random.nextInt(256), random.nextInt(256));
    }
  }
  return image;
}
