import 'dart:io';

import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:flutter/material.dart';

import 'build_info.dart';
import 'install_engine.dart';
import 'ui/installer_app.dart';

/// Аргументы, которые приходят от нативной оболочки (bootstrap.cpp) и от
/// системы:
///   --self=<путь>       путь к тому единственному exe, который запустил человек
///   --uninstall         режим удаления (так прописано в UninstallString реестра)
///   --silent            без окна и без вопросов: так Windows зовёт при «тихом»
///                       удалении, и так же удобно разворачивать на парк машин
///   --dir=<путь>        куда ставить (только вместе с --silent)
///   --desktop-shortcut  создать ярлык на рабочем столе (только с --silent)
///   --autostart         запускать вместе с Windows (только с --silent)
///
/// Код возврата в тихом режиме честный: 0 — получилось, 1 — нет. Иначе
/// развёртывание не смогло бы отличить успех от провала.
void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  final uninstall = args.contains('--uninstall');
  final silent = args.contains('--silent');
  final selfExePath = _valueOf(args, '--self=');

  if (silent) {
    final installer = Installer(selfExePath: selfExePath);
    try {
      if (uninstall) {
        await installer.uninstall(removeUserData: false, onProgress: (_) {});
      } else {
        await installer.install(
          targetDir: _valueOf(args, '--dir=') ?? Installer.defaultInstallDir(),
          desktopShortcut: args.contains('--desktop-shortcut'),
          autostart: args.contains('--autostart'),
          onProgress: (_) {},
        );
      }
      exit(0);
    } catch (e) {
      // Окна нет, поэтому единственный способ рассказать о причине — код
      // возврата и стандартный поток ошибок.
      stderr.writeln(e);
      exit(1);
    }
  }

  runApp(InstallerApp(uninstallMode: uninstall, selfExePath: selfExePath));

  doWhenWindowReady(() {
    // Фиксированный размер: установщик — не рабочее окно, тянуть его незачем,
    // а плавающая ширина только сломала бы выверенную вёрстку экранов.
    const size = Size(720, 520);
    appWindow.minSize = size;
    appWindow.maxSize = size;
    appWindow.size = size;
    appWindow.alignment = Alignment.center;
    appWindow.title = uninstall ? 'Удаление $kAppName' : 'Установка $kAppName';
    appWindow.show();
  });
}

/// Значение аргумента вида `--ключ=значение`. Кавычки по краям снимаем: их
/// добавляет нативная оболочка, когда прокидывает путь с пробелами.
String? _valueOf(List<String> args, String prefix) {
  final arg = args.firstWhere((a) => a.startsWith(prefix), orElse: () => '');
  if (arg.isEmpty) return null;
  var value = arg.substring(prefix.length);
  if (value.length > 1 && value.startsWith('"') && value.endsWith('"')) {
    value = value.substring(1, value.length - 1);
  }
  return value.isEmpty ? null : value;
}
