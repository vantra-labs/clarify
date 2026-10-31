import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'build_info.dart';

/// Этапы, которые видит пользователь. Отдельный enum, а не просто строки, —
/// экран прогресса подписывает шаг сам и на своём языке.
enum InstallStep { preparing, extracting, shortcuts, registry, cleanup, finished }

class InstallProgress {
  final InstallStep step;

  /// 0..1 внутри всей операции, не внутри шага: пользователю важна общая
  /// полоса, а не «90% третьего этапа из пяти».
  final double value;
  final String detail;

  const InstallProgress(this.step, this.value, this.detail);
}

/// Ошибка установки с человеческим текстом. Технические подробности
/// (stderr процесса, путь) кладём в [details] — их показываем мелким шрифтом
/// под сообщением, чтобы при обращении в поддержку было что прислать.
class InstallException implements Exception {
  final String message;
  final String? details;

  const InstallException(this.message, [this.details]);

  @override
  String toString() => details == null ? message : '$message\n$details';
}

typedef ProgressCallback = void Function(InstallProgress progress);

class Installer {
  /// Папка, куда распакована временная копия установщика (там же лежит
  /// payload.zip). Определяется от исполняемого файла, а не от текущей
  /// рабочей папки: рабочая папка при запуске из проводника — произвольная.
  static String get _installerDir => p.dirname(Platform.resolvedExecutable);

  static String get payloadPath => p.join(_installerDir, 'payload.zip');

  /// Путь к тому самому одиночному exe, который запустил пользователя
  /// (передаёт нативная оболочка аргументом --self). Именно он копируется в
  /// папку установки как деинсталлятор.
  final String? selfExePath;

  Installer({this.selfExePath});

  static String defaultInstallDir() {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData == null || localAppData.isEmpty) {
      // Теоретически невозможно на живой Windows, но лучше честно упасть
      // здесь, чем молча поставить приложение в корень диска.
      throw const InstallException('Не удалось определить папку пользователя (LOCALAPPDATA).');
    }
    return p.join(localAppData, 'Programs', kAppName);
  }

  static String get startMenuShortcutPath {
    final appData = Platform.environment['APPDATA'] ?? '';
    return p.join(appData, 'Microsoft', 'Windows', 'Start Menu', 'Programs', '$kAppName.lnk');
  }

  static String get desktopShortcutPath {
    final userProfile = Platform.environment['USERPROFILE'] ?? '';
    return p.join(userProfile, 'Desktop', '$kAppName.lnk');
  }

  // --- Состояние уже установленной копии ---------------------------------

  /// Путь предыдущей установки, если приложение уже стоит. Берём из реестра,
  /// а не из папки по умолчанию: пользователь мог поставить в другое место, и
  /// обновление обязано лечь туда же, а не создать вторую копию.
  static Future<String?> existingInstallLocation() => _queryRegValue('InstallLocation');

  static Future<String?> installedVersion() => _queryRegValue('DisplayVersion');

  /// Стоит ли сейчас автозапуск. Нужно при обновлении: галочку в окне надо
  /// показать в том состоянии, в каком человек её оставил, иначе обновление
  /// молча выключило бы ему автозапуск.
  static Future<bool> isAutostartEnabled() async {
    final result = await Process.run('reg', ['query', kRunKeyPath, '/v', kRunValueName]);
    if (result.exitCode != 0) return false;
    return parseRegQueryOutput(result.stdout.toString(), kRunValueName) != null;
  }

  static Future<String?> _queryRegValue(String name) async {
    final result = await Process.run('reg', ['query', kUninstallKeyPath, '/v', name]);
    if (result.exitCode != 0) return null;
    return parseRegQueryOutput(result.stdout.toString(), name);
  }

  /// Выделено отдельно и открыто для тестов: вывод `reg query` — это несколько
  /// строк с заголовком ключа, а само значение может содержать пробелы (путь
  /// вида `C:\Program Files\...`), поэтому по последнему пробелу его резать
  /// нельзя.
  static String? parseRegQueryOutput(String stdout, String name) {
    final match = RegExp('$name\\s+REG_\\w+\\s+(.+)').firstMatch(stdout);
    final value = match?.group(1)?.trim();
    if (value == null || value.isEmpty) return null;
    return value;
  }

  /// Запущен ли сейчас сам Clarify. Файлы работающего приложения Windows
  /// перезаписать не даст, поэтому это надо знать ДО начала распаковки, а не
  /// узнавать из ошибки на середине.
  static Future<bool> isAppRunning() async {
    final result = await Process.run('tasklist', ['/FI', 'IMAGENAME eq $kAppExeName', '/NH']);
    return result.stdout.toString().toLowerCase().contains(kAppExeName.toLowerCase());
  }

  static Future<void> closeApp() async {
    await Process.run('taskkill', ['/F', '/IM', kAppExeName]);
    // taskkill возвращается сразу, а закрытие процесса занимает мгновение —
    // без паузы следующая же попытка удалить файлы упирается в занятый exe.
    for (var attempt = 0; attempt < 20; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!await isAppRunning()) return;
    }
  }

  // --- Установка ----------------------------------------------------------

  Future<void> install({
    required String targetDir,
    required bool desktopShortcut,
    required bool autostart,
    required ProgressCallback onProgress,
  }) async {
    onProgress(const InstallProgress(InstallStep.preparing, 0.02, 'Проверяем папку установки'));

    final payload = File(payloadPath);
    if (!payload.existsSync()) {
      throw InstallException(
        'Повреждён установочный файл: не найдена упакованная программа.',
        'Ожидался $payloadPath',
      );
    }

    if (await isAppRunning()) {
      onProgress(const InstallProgress(InstallStep.preparing, 0.04, 'Закрываем запущенный Clarify'));
      await closeApp();
    }

    final target = Directory(targetDir);
    if (target.existsSync()) {
      // Обновление поверх: старые файлы сносим целиком, иначе останутся
      // библиотеки от предыдущей версии, которых уже нет в новой, — Flutter
      // при несовпадении версий движка и ассетов падает молча, без окна.
      onProgress(const InstallProgress(InstallStep.preparing, 0.06, 'Удаляем предыдущую версию'));
      await _deleteDirectoryContents(target, keepFileNames: {kUninstallerName});
    } else {
      target.createSync(recursive: true);
    }

    // --- Распаковка ---
    final installedSizeKb = await extractArchive(
      zipPath: payloadPath,
      targetDir: targetDir,
      onProgress: onProgress,
    );

    final appExe = p.join(targetDir, kAppExeName);
    if (!File(appExe).existsSync()) {
      throw InstallException(
        'После распаковки не найден исполняемый файл программы.',
        'Ожидался $appExe',
      );
    }

    // --- Ярлыки ---
    onProgress(const InstallProgress(InstallStep.shortcuts, 0.88, 'Создаём ярлыки'));
    await _createShortcut(
      linkPath: startMenuShortcutPath,
      targetPath: appExe,
      workingDirectory: targetDir,
      description: 'Clarify — планировщик задач',
    );
    if (desktopShortcut) {
      await _createShortcut(
        linkPath: desktopShortcutPath,
        targetPath: appExe,
        workingDirectory: targetDir,
        description: 'Clarify — планировщик задач',
      );
    } else {
      await _deleteQuietly(File(desktopShortcutPath));
    }

    // --- Деинсталлятор ---
    onProgress(const InstallProgress(InstallStep.registry, 0.92, 'Готовим удаление программы'));
    final uninstallerPath = p.join(targetDir, kUninstallerName);
    // Рядом с нами лежит облегчённая сборка установщика — та же программа, но
    // без упакованного внутрь приложения (оно ей для удаления не нужно).
    // Копируем её, а не сам запущенный файл: тот тащит за собой всю программу
    // целиком и оставил бы в папке установки лишние 40 МБ навсегда.
    final slimUninstaller = File(p.join(_installerDir, 'uninstaller.exe'));
    if (slimUninstaller.existsSync()) {
      slimUninstaller.copySync(uninstallerPath);
    } else if (selfExePath != null && File(selfExePath!).existsSync()) {
      File(selfExePath!).copySync(uninstallerPath);
    }
    if (!File(uninstallerPath).existsSync()) {
      throw const InstallException(
        'Не удалось подготовить удаление программы.',
        'Не найден файл деинсталлятора рядом с установщиком.',
      );
    }

    // --- Реестр ---
    await _writeUninstallEntry(
      targetDir: targetDir,
      appExe: appExe,
      uninstallerPath: uninstallerPath,
      estimatedSizeKb: installedSizeKb,
    );

    if (autostart) {
      await _regSetValue(kRunKeyPath, kRunValueName, 'REG_SZ', '"$appExe" --autostart');
    } else {
      await Process.run('reg', ['delete', kRunKeyPath, '/v', kRunValueName, '/f']);
    }

    onProgress(const InstallProgress(InstallStep.finished, 1.0, 'Готово'));
  }

  /// Распаковывает zip в [targetDir], возвращая суммарный размер в килобайтах
  /// (он уходит в реестр как EstimatedSize — размер, который Windows покажет
  /// в «Программах и компонентах»).
  ///
  /// Открыт отдельно от [install] ради тестов: это единственная часть
  /// установки, которую можно проверить целиком, не трогая реестр и меню Пуск.
  static Future<int> extractArchive({
    required String zipPath,
    required String targetDir,
    ProgressCallback? onProgress,
  }) async {
    final input = InputFileStream(zipPath);
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBuffer(input);
    } catch (e) {
      await input.close();
      throw InstallException('Не удалось прочитать упакованную программу.', '$e');
    }

    final files = archive.files.where((f) => f.isFile).toList();
    final totalBytes = files.fold<int>(0, (sum, f) => sum + f.size);
    var writtenBytes = 0;
    var installedSizeKb = 0;

    try {
      for (final file in files) {
        // Zip хранит разделителем '/', на диск пишем через системный. И
        // отбрасываем попытки выйти за пределы папки установки ('..'):
        // архив собираем мы сами, но установщик не должен уметь писать куда
        // угодно, даже если payload кто-то подменит.
        final relative = file.name.replaceAll('/', p.separator);
        final outPath = p.normalize(p.join(targetDir, relative));
        if (!p.isWithin(targetDir, outPath)) {
          throw InstallException(
            'Упакованная программа повреждена.',
            'Недопустимый путь внутри архива: ${file.name}',
          );
        }

        Directory(p.dirname(outPath)).createSync(recursive: true);

        final output = OutputFileStream(outPath);
        try {
          file.writeContent(output);
        } finally {
          await output.close();
        }

        writtenBytes += file.size;
        installedSizeKb += (file.size / 1024).ceil();
        // 0.08..0.85 — распаковка занимает почти всё время установки, остальные
        // шаги мгновенные, и полоса не должна врать про это соотношение.
        final value = totalBytes == 0 ? 0.85 : 0.08 + 0.77 * (writtenBytes / totalBytes);
        onProgress?.call(InstallProgress(InstallStep.extracting, value, p.basename(file.name)));

        // Уступаем кадр интерфейсу: без этого полоса замирает до конца
        // распаковки и выглядит как зависшая программа.
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      await input.close();
    }

    return installedSizeKb;
  }

  Future<void> _writeUninstallEntry({
    required String targetDir,
    required String appExe,
    required String uninstallerPath,
    required int estimatedSizeKb,
  }) async {
    final now = DateTime.now();
    final installDate = '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}';

    final values = <String, (String, String)>{
      'DisplayName': ('REG_SZ', kAppName),
      'DisplayVersion': ('REG_SZ', kAppVersion),
      'Publisher': ('REG_SZ', kPublisher),
      'InstallLocation': ('REG_SZ', targetDir),
      'DisplayIcon': ('REG_SZ', appExe),
      'UninstallString': ('REG_SZ', '"$uninstallerPath" --uninstall'),
      'QuietUninstallString': ('REG_SZ', '"$uninstallerPath" --uninstall --silent'),
      'InstallDate': ('REG_SZ', installDate),
      'EstimatedSize': ('REG_DWORD', '$estimatedSizeKb'),
      'NoModify': ('REG_DWORD', '1'),
      'NoRepair': ('REG_DWORD', '1'),
    };

    for (final entry in values.entries) {
      await _regSetValue(kUninstallKeyPath, entry.key, entry.value.$1, entry.value.$2);
    }
  }

  Future<void> _regSetValue(String key, String name, String type, String data) async {
    final result = await Process.run('reg', ['add', key, '/v', name, '/t', type, '/d', data, '/f']);
    if (result.exitCode != 0) {
      throw InstallException(
        'Не удалось записать сведения о программе в реестр.',
        'reg add $key /v $name → ${result.stderr}',
      );
    }
  }

  /// Ярлык создаётся через COM-объект WScript.Shell — единственный способ
  /// сделать настоящий .lnk без сторонних библиотек. Скрипт пишем во временный
  /// файл и запускаем через -File: в варианте с -Command путь с пробелами и
  /// кириллицей пришлось бы экранировать вручную, и любая скобка в имени
  /// пользователя ломала бы установку.
  Future<void> _createShortcut({
    required String linkPath,
    required String targetPath,
    required String workingDirectory,
    required String description,
  }) async {
    Directory(p.dirname(linkPath)).createSync(recursive: true);

    final script = File(p.join(Directory.systemTemp.path, 'clarify_shortcut_${DateTime.now().microsecondsSinceEpoch}.ps1'));
    // Одинарная кавычка внутри пути (папка пользователя вида D'Artagnan) в
    // PowerShell закрывает строку — удваиваем её, как того требует синтаксис.
    String psPath(String value) => value.replaceAll("'", "''");
    script.writeAsStringSync('''
\$shell = New-Object -ComObject WScript.Shell
\$link = \$shell.CreateShortcut('${psPath(linkPath)}')
\$link.TargetPath = '${psPath(targetPath)}'
\$link.WorkingDirectory = '${psPath(workingDirectory)}'
\$link.IconLocation = '${psPath(targetPath)},0'
\$link.Description = '${psPath(description)}'
\$link.Save()
''', flush: true);

    try {
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
      ]);
      if (result.exitCode != 0 || !File(linkPath).existsSync()) {
        throw InstallException(
          'Не удалось создать ярлык.',
          '$linkPath → ${result.stderr}',
        );
      }
    } finally {
      await _deleteQuietly(script);
    }
  }

  // --- Удаление -----------------------------------------------------------

  /// [removeUserData] — снести ещё и локальные данные (кэш задач и настройки).
  /// По умолчанию выключено: человек может удалять программу перед
  /// переустановкой и не ждать, что у него пропадут локальные настройки.
  Future<void> uninstall({
    required bool removeUserData,
    required ProgressCallback onProgress,
  }) async {
    onProgress(const InstallProgress(InstallStep.preparing, 0.05, 'Проверяем запущенные копии'));
    if (await isAppRunning()) {
      await closeApp();
    }

    onProgress(const InstallProgress(InstallStep.registry, 0.2, 'Убираем автозапуск'));
    await Process.run('reg', ['delete', kRunKeyPath, '/v', kRunValueName, '/f']);

    onProgress(const InstallProgress(InstallStep.shortcuts, 0.35, 'Удаляем ярлыки'));
    await _deleteQuietly(File(startMenuShortcutPath));
    await _deleteQuietly(File(desktopShortcutPath));

    final installDir = await existingInstallLocation() ??
        p.dirname(selfExePath ?? Platform.resolvedExecutable);

    if (removeUserData) {
      onProgress(const InstallProgress(InstallStep.cleanup, 0.5, 'Удаляем локальные данные'));
      await _removeUserData();
    }

    onProgress(const InstallProgress(InstallStep.cleanup, 0.65, 'Удаляем файлы программы'));
    final dir = Directory(installDir);
    if (dir.existsSync()) {
      // Всё, кроме самого деинсталлятора: он сейчас запущен (точнее, запущена
      // нативная оболочка из этого файла), и Windows не даст удалить образ
      // работающего процесса. Его сносит отложенная команда ниже.
      await _deleteDirectoryContents(dir, keepFileNames: {kUninstallerName});
    }

    onProgress(const InstallProgress(InstallStep.registry, 0.85, 'Убираем запись из «Программ и компонентов»'));
    await Process.run('reg', ['delete', kUninstallKeyPath, '/f']);

    await _scheduleSelfDeletion(installDir);

    onProgress(const InstallProgress(InstallStep.finished, 1.0, 'Готово'));
  }

  Future<void> _removeUserData() async {
    final documents = Platform.environment['USERPROFILE'];
    if (documents == null) return;
    // Hive кладёт боксы в «Документы» (Hive.init(getApplicationDocumentsDirectory)
    // в main.dart приложения) — удаляем поимённо, а не по маске: в этой же
    // папке лежат документы пользователя.
    for (final name in const ['tasks_cache.hive', 'settings.hive', 'pending_ops.hive']) {
      await _deleteQuietly(File(p.join(documents, 'Documents', name)));
      await _deleteQuietly(File(p.join(documents, 'Documents', '$name.lock')));
    }
  }

  /// Папку с деинсталлятором удаляет отдельный фоновый процесс: пока наш exe
  /// запущен, Windows держит его файл занятым и удалить каталог не даёт.
  ///
  /// Важна именно попытка в цикле, а не одна отложенная команда. Первая версия
  /// ждала три секунды и один раз пыталась удалить — при тихом удалении это
  /// срабатывало (процесс к тому моменту уже вышел), а при удалении через окно
  /// человек ещё смотрел на экран «Clarify удалён», деинсталлятор был запущен,
  /// и папка оставалась на диске насовсем. Теперь цикл повторяет попытку раз в
  /// секунду примерно полминуты и заканчивает сразу, как только папка исчезла.
  Future<void> _scheduleSelfDeletion(String installDir) async {
    final script = File(p.join(
      Directory.systemTemp.path,
      'clarify_cleanup_${DateTime.now().microsecondsSinceEpoch}.bat',
    ));
    script.writeAsStringSync('''
@echo off
for /l %%i in (1,1,30) do (
  ping 127.0.0.1 -n 2 >nul
  rd /s /q "$installDir" 2>nul
  if not exist "$installDir" goto done
)
:done
del "%~f0"
''', flush: true);

    await Process.start(
      'cmd',
      ['/c', script.path],
      mode: ProcessStartMode.detached,
      // Рабочая папка — системная временная, а не наша: по умолчанию дочерний
      // процесс унаследовал бы каталог, из которого запущен установщик, и
      // полминуты держал бы его занятым. Из-за этого оболочка не могла удалить
      // свою временную папку и та оставалась в TEMP.
      workingDirectory: Directory.systemTemp.path,
    );
  }

  // --- Файловые помощники -------------------------------------------------

  Future<void> _deleteDirectoryContents(Directory dir, {Set<String> keepFileNames = const {}}) async {
    for (final entity in dir.listSync()) {
      final name = p.basename(entity.path);
      if (keepFileNames.contains(name)) continue;
      try {
        if (entity is Directory) {
          entity.deleteSync(recursive: true);
        } else {
          entity.deleteSync();
        }
      } on FileSystemException catch (e) {
        throw InstallException(
          'Не удалось удалить файлы предыдущей версии. Закройте Clarify и повторите.',
          '${entity.path} → ${e.message}',
        );
      }
    }
  }

  Future<void> _deleteQuietly(FileSystemEntity entity) async {
    try {
      if (entity.existsSync()) entity.deleteSync();
    } on FileSystemException {
      // Ярлык мог быть уже удалён руками, временный скрипт — подчищен
      // антивирусом. Это не повод показывать ошибку пользователю.
    }
  }
}
