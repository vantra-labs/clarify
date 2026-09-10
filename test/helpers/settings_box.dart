import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// Открывает Hive-бокс `settings` для виджет-тестов.
///
/// Нужен тем тестам, которые рисуют экраны, читающие пользовательские
/// настройки (AppSettings) — например способ сортировки списка задач. В
/// приложении бокс открывает main.dart до runApp, поэтому в бою он есть
/// всегда; в тестовой среде Hive не поднят вовсе, и обращение к настройке
/// падает с «Box not found».
///
/// Держать это в приложении (тихо отдавать значение по умолчанию, если бокс не
/// открыт) — плохой размен: тогда настоящая поломка хранилища выглядела бы как
/// «настройки просто не сохраняются», без единого сигнала.
void useSettingsBox() {
  late Directory tempDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('clarify_settings_test');
    Hive.init(tempDir.path);
    await Hive.openBox('settings');
  });

  tearDownAll(() async {
    // Hive.close() ждёт, пока допишутся все начатые записи. Запись, начатую
    // ВНУТРИ виджет-теста (тап по переключателю настройки), он не дождётся
    // никогда: у виджет-теста своё, остановленное время, и отложенная работа,
    // запланированная в нём, после конца теста уже не выполняется. Без предела
    // ожидания прогон вис на уборке — сами тесты при этом проходили.
    //
    // Бросить недописанную запись здесь не страшно: это временный каталог,
    // который строкой ниже удаляется целиком.
    await Hive.close()
        .timeout(const Duration(seconds: 2), onTimeout: () => const <void>[]);
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Файл бокса может остаться занятым как раз из-за недописанной записи.
      // Лишняя папка во временном каталоге системы — мелочь, а падение уборки
      // выглядело бы как провалившийся тест.
    }
  });
}
