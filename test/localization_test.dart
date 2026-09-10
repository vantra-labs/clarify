import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/core/localization.dart';

void main() {
  group('полнота словаря', () {
    // Отсутствующий ключ .tr() возвращает как есть — то есть русский текст в
    // английском интерфейсе, молча, без единой жалобы в консоли. Поймать это
    // можно только сверкой: 10.09.2026 так нашлось 66 строк без перевода.
    test('каждая строка, запрашивающая перевод, есть в словаре', () {
      final missing = <String, Set<String>>{};
      final patterns = [
        RegExp(r"'((?:[^'\\\n]|\\.)*)'\s*\.tr\("),
        RegExp(r'"((?:[^"\\\n]|\\.)*)"\s*\.tr\('),
      ];

      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.path.endsWith('localization.dart')) continue;
        final source = entity.readAsStringSync();
        for (final pattern in patterns) {
          for (final match in pattern.allMatches(source)) {
            // В исходнике перевод строки записан двумя знаками (\ и n), а в
            // словаре на этом месте живёт настоящий перевод строки — без
            // обратного разбора ключ не сойдётся сам с собой.
            final key = match
                .group(1)!
                .replaceAll(r'\n', '\n')
                .replaceAll(r"\'", "'")
                .replaceAll(r'\"', '"')
                .replaceAll(r'\\', r'\');
            // Строка с подстановкой ('Ошибка: $e') в словаре не найдётся
            // никогда — её нужно разбивать на переводимый префикс и значение.
            // Это отдельная ошибка, а не пропущенный перевод.
            if (key.contains(r'$')) continue;
            if (!T.dict.containsKey(key)) {
              missing.putIfAbsent(key, () => <String>{}).add(entity.path);
            }
          }
        }
      }

      expect(
        missing,
        isEmpty,
        reason: 'без перевода остались строки:\n'
            '${missing.entries.map((e) => '  "${e.key}" — ${e.value.join(', ')}').join('\n')}',
      );
    });

    test('у каждого ключа есть и русский, и английский', () {
      final broken = T.dict.entries
          .where((e) =>
              (e.value['ru'] ?? '').isEmpty || (e.value['en'] ?? '').isEmpty)
          .map((e) => e.key)
          .toList();
      expect(broken, isEmpty, reason: 'неполные переводы: $broken');
    });
  });

  group('TranslateExtension.tr', () {
    test('возвращает русский перевод для известного ключа', () {
      expect('Сегодня'.tr('ru'), 'Сегодня');
    });

    test('возвращает английский перевод для известного ключа', () {
      expect('Сегодня'.tr('en'), 'Today');
    });

    test('возвращает исходную строку, если перевод не найден', () {
      const missingKey = 'Такого ключа точно нет в словаре';
      expect(missingKey.tr('ru'), missingKey);
      expect(missingKey.tr('en'), missingKey);
    });

    test('возвращает исходную строку для неизвестного языка', () {
      expect('Сегодня'.tr('fr'), 'Сегодня');
    });
  });
}
