import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:clarify_installer/build_info.dart';
import 'package:clarify_installer/install_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Собирает временный zip с заданными файлами — заменяет настоящий payload.zip
/// там, где важна только механика распаковки.
File _makeZip(Directory dir, Map<String, String> files) {
  final source = Directory(p.join(dir.path, 'src'))..createSync(recursive: true);
  files.forEach((name, content) {
    final file = File(p.join(source.path, name.replaceAll('/', p.separator)));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  });

  final zipPath = p.join(dir.path, 'payload.zip');
  ZipFileEncoder()
    ..create(zipPath)
    ..addDirectory(source, includeDirName: false)
    ..close();
  return File(zipPath);
}

void main() {
  group('пути установки', () {
    test('по умолчанию ставим в папку пользователя, без Program Files', () {
      final dir = Installer.defaultInstallDir();
      expect(dir, endsWith(p.join('Programs', kAppName)));
      expect(dir.toLowerCase(), contains('appdata'));
      // Program Files потребовал бы прав администратора и UAC — сознательно нет.
      expect(dir.toLowerCase(), isNot(contains('program files')));
    });

    test('ярлыки метим в меню Пуск и на рабочий стол текущего пользователя', () {
      expect(Installer.startMenuShortcutPath, endsWith('$kAppName.lnk'));
      expect(Installer.startMenuShortcutPath, contains('Start Menu'));
      expect(Installer.desktopShortcutPath, endsWith('$kAppName.lnk'));
    });
  });

  group('разбор ответа реестра', () {
    test('путь с пробелами читается целиком', () {
      const output = '''

HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Clarify
    InstallLocation    REG_SZ    C:\\Users\\Никита\\AppData\\Local\\Programs\\My Clarify

''';
      expect(
        Installer.parseRegQueryOutput(output, 'InstallLocation'),
        r'C:\Users\Никита\AppData\Local\Programs\My Clarify',
      );
    });

    test('нет значения — нет и результата', () {
      expect(Installer.parseRegQueryOutput('ERROR: The system was unable to find', 'InstallLocation'), isNull);
    });
  });

  group('распаковка', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('clarify_installer_test'));
    tearDown(() => temp.deleteSync(recursive: true));

    test('файлы и вложенные папки оказываются на месте', () async {
      final zip = _makeZip(temp, {
        'Clarify.exe': 'exe-заглушка',
        'data/flutter_assets/AssetManifest.json': '{}',
        'data/app.so': 'so',
      });
      final target = Directory(p.join(temp.path, 'install'));

      final sizeKb = await Installer.extractArchive(zipPath: zip.path, targetDir: target.path);

      expect(File(p.join(target.path, 'Clarify.exe')).readAsStringSync(), 'exe-заглушка');
      expect(File(p.join(target.path, 'data', 'flutter_assets', 'AssetManifest.json')).existsSync(), isTrue);
      expect(File(p.join(target.path, 'data', 'app.so')).existsSync(), isTrue);
      expect(sizeKb, greaterThan(0));
    });

    test('прогресс идёт от начала к концу и заканчивается на 0.85', () async {
      final zip = _makeZip(temp, {'a.txt': 'a' * 100, 'b.txt': 'b' * 100, 'c.txt': 'c' * 100});
      final target = Directory(p.join(temp.path, 'install2'));

      final values = <double>[];
      await Installer.extractArchive(
        zipPath: zip.path,
        targetDir: target.path,
        onProgress: (progress) {
          expect(progress.step, InstallStep.extracting);
          values.add(progress.value);
        },
      );

      expect(values.length, 3);
      expect(values.first, greaterThan(0.08));
      // Полоса не должна доезжать до конца на распаковке: после неё ещё
      // ярлыки и реестр.
      expect(values.last, closeTo(0.85, 0.001));
      expect(values, orderedEquals(List<double>.from(values)..sort()));
    });

    test('архив с выходом за пределы папки отвергается', () async {
      // Собираем архив вручную: ZipFileEncoder такой путь не создаст, а
      // проверить защиту надо именно от подменённого payload.
      final archive = Archive()..addFile(ArchiveFile('../evil.txt', 4, 'evil'.codeUnits));
      final zipPath = p.join(temp.path, 'evil.zip');
      File(zipPath).writeAsBytesSync(ZipEncoder().encode(archive)!);

      final target = Directory(p.join(temp.path, 'install3'))..createSync(recursive: true);

      expect(
        () => Installer.extractArchive(zipPath: zipPath, targetDir: target.path),
        throwsA(isA<InstallException>()),
      );
      expect(File(p.join(temp.path, 'evil.txt')).existsSync(), isFalse);
    });
  });
}
