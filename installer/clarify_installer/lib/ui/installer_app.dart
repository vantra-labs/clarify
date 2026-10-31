import 'dart:io';

import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;

import '../build_info.dart';
import '../install_engine.dart';
import '../theme.dart';
import 'widgets.dart';

enum _Stage { welcome, working, done, failed }

class InstallerApp extends StatelessWidget {
  final bool uninstallMode;
  final String? selfExePath;

  const InstallerApp({super.key, required this.uninstallMode, this.selfExePath});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Установка $kAppName',
      debugShowCheckedModeBanner: false,
      theme: buildInstallerTheme(),
      // Масштаб текста фиксирован: установщик — окно фиксированного размера,
      // и системное увеличение шрифта ломало бы его вёрстку (то же решение,
      // что в самом Clarify).
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.0)),
        child: child!,
      ),
      home: _InstallerShell(uninstallMode: uninstallMode, selfExePath: selfExePath),
    );
  }
}

class _InstallerShell extends StatefulWidget {
  final bool uninstallMode;
  final String? selfExePath;

  const _InstallerShell({required this.uninstallMode, this.selfExePath});

  @override
  State<_InstallerShell> createState() => _InstallerShellState();
}

class _InstallerShellState extends State<_InstallerShell> {
  late final Installer _installer = Installer(selfExePath: widget.selfExePath);

  _Stage _stage = _Stage.welcome;
  String _targetDir = '';
  bool _desktopShortcut = true;
  bool _autostart = false;
  bool _removeUserData = false;
  String? _previousVersion;

  InstallProgress _progress = const InstallProgress(InstallStep.preparing, 0, '');
  String _errorMessage = '';
  String? _errorDetails;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    String target;
    try {
      target = Installer.defaultInstallDir();
    } on InstallException {
      target = r'C:\Clarify';
    }
    final existing = await Installer.existingInstallLocation();
    final version = await Installer.installedVersion();
    final autostart = await Installer.isAutostartEnabled();
    if (!mounted) return;
    setState(() {
      _targetDir = existing ?? target;
      _previousVersion = version;
      // При обновлении обе галочки показываем в том состоянии, в каком человек
      // их оставил: и ярлык (мог удалить осознанно), и автозапуск. Иначе
      // обновление тихо меняло бы уже сделанный выбор.
      if (existing != null) {
        _desktopShortcut = File(Installer.desktopShortcutPath).existsSync();
        _autostart = autostart;
      }
    });
  }

  bool get _isUpdate => _previousVersion != null;

  /// Сколько минимум показываем экран прогресса. На быстрой машине установка
  /// укладывается в полсекунды, и без этой паузы экран прогресса мелькает
  /// одним кадром: человек видит вспышку вместо процесса и не понимает, что
  /// вообще произошло. Пауза не искусственная задержка ради красоты — она
  /// делает переход читаемым.
  static const Duration _minimumVisibleWork = Duration(milliseconds: 1200);

  Future<void> _run() async {
    final startedAt = DateTime.now();
    setState(() {
      _stage = _Stage.working;
      _progress = const InstallProgress(InstallStep.preparing, 0, 'Начинаем');
    });

    try {
      if (widget.uninstallMode) {
        await _installer.uninstall(
          removeUserData: _removeUserData,
          onProgress: _onProgress,
        );
      } else {
        await _installer.install(
          targetDir: _targetDir,
          desktopShortcut: _desktopShortcut,
          autostart: _autostart,
          onProgress: _onProgress,
        );
      }
      final elapsed = DateTime.now().difference(startedAt);
      if (elapsed < _minimumVisibleWork) {
        await Future<void>.delayed(_minimumVisibleWork - elapsed);
      }
      if (!mounted) return;
      setState(() => _stage = _Stage.done);
    } on InstallException catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.failed;
        _errorMessage = e.message;
        _errorDetails = e.details;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.failed;
        _errorMessage = widget.uninstallMode
            ? 'Не удалось удалить программу.'
            : 'Не удалось установить программу.';
        _errorDetails = '$e';
      });
    }
  }

  void _onProgress(InstallProgress progress) {
    if (!mounted) return;
    setState(() => _progress = progress);
  }

  Future<void> _launchApp() async {
    final exe = p.join(_targetDir, kAppExeName);
    if (File(exe).existsSync()) {
      await Process.start(exe, const [], mode: ProcessStartMode.detached, workingDirectory: _targetDir);
    }
    exit(0);
  }

  Future<void> _pickFolder() async {
    // Штатный диалог выбора папки — через PowerShell: тянуть file_picker ради
    // одного окна значит тянуть в установщик ещё один плагин с нативной
    // частью. Диалог системный, но это ровно то место, где человек ждёт
    // системный диалог, а не нашу выдумку.
    final script = File(p.join(
      Directory.systemTemp.path,
      'clarify_pickdir_${DateTime.now().microsecondsSinceEpoch}.ps1',
    ));
    script.writeAsStringSync('''
Add-Type -AssemblyName System.Windows.Forms
\$dialog = New-Object System.Windows.Forms.FolderBrowserDialog
\$dialog.Description = 'Куда установить Clarify'
\$dialog.ShowNewFolderButton = \$true
if (\$dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { Write-Output \$dialog.SelectedPath }
''', flush: true);

    try {
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-STA',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
      ]);
      final chosen = result.stdout.toString().trim();
      if (chosen.isNotEmpty && mounted) {
        // Человек выбирает родительскую папку — кладём приложение в
        // подпапку с именем программы, а не вываливаем полсотни файлов
        // прямо в «Документы» или в корень диска.
        final alreadyOurs = p.basename(chosen).toLowerCase() == kAppName.toLowerCase();
        setState(() => _targetDir = alreadyOurs ? chosen : p.join(chosen, kAppName));
      }
    } finally {
      if (script.existsSync()) script.deleteSync();
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _stage == _Stage.working;

    return Scaffold(
      backgroundColor: Colors.transparent,
      // Скругление углов окна рисует сама Windows 11 — своё поверх него дало
      // бы двойной кант и тёмные зазоры в углах, поэтому фон здесь ровный.
      body: ColoredBox(
        color: InstallerTokens.bg,
        child: Stack(
          children: [
            const _AmbientGlow(),
            Column(
              children: [
                _titleBar(busy),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(40, 8, 40, 32),
                    child: AnimatedSwitcher(
                      duration: InstallerMotion.deliberate,
                      switchInCurve: InstallerMotion.standard,
                      switchOutCurve: InstallerMotion.standard,
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0, 0.04),
                            end: Offset.zero,
                          ).animate(animation),
                          child: child,
                        ),
                      ),
                      child: _body(),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _titleBar(bool busy) {
    return SizedBox(
      height: 46,
      child: Row(
        children: [
          Expanded(child: MoveWindow()),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: WindowControls(
              onMinimize: () => appWindow.minimize(),
              // Закрывать окно посреди распаковки нельзя: остался бы
              // наполовину установленный каталог без ярлыков и записи в
              // реестре, и следующая установка чинила бы это вслепую.
              closeEnabled: !busy,
              onClose: () => exit(0),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    switch (_stage) {
      case _Stage.welcome:
        return widget.uninstallMode ? _uninstallWelcome() : _installWelcome();
      case _Stage.working:
        return _working();
      case _Stage.done:
        return _done();
      case _Stage.failed:
        return _failed();
    }
  }

  // --- Экраны -------------------------------------------------------------

  Widget _installWelcome() {
    return Column(
      key: const ValueKey('welcome'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const InstallerLogo(),
            const SizedBox(width: 18),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  kAppName,
                  style: TextStyle(
                    fontFamily: 'Unbounded',
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                    color: InstallerTokens.text,
                    height: 1.1,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _isUpdate
                      ? 'Обновление с версии $_previousVersion до $kAppVersion'
                      : 'Планировщик задач с ИИ · версия $kAppVersion',
                  style: const TextStyle(color: InstallerTokens.text2, fontSize: 14),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 26),
        _pathRow(),
        const SizedBox(height: 14),
        InstallerOption(
          title: 'Ярлык на рабочем столе',
          subtitle: 'Чтобы запускать в один клик',
          icon: LucideIcons.monitor,
          value: _desktopShortcut,
          onChanged: (v) => setState(() => _desktopShortcut = v),
        ),
        const SizedBox(height: 10),
        InstallerOption(
          title: 'Запускать вместе с Windows',
          subtitle: 'Свернётся в трей и не будет мешать',
          icon: LucideIcons.power,
          value: _autostart,
          onChanged: (v) => setState(() => _autostart = v),
        ),
        const Spacer(),
        Row(
          children: [
            const Expanded(
              child: Text(
                'Установка не требует прав администратора\nи занимает меньше минуты',
                style: TextStyle(color: InstallerTokens.text3, fontSize: 12, height: 1.5),
              ),
            ),
            InstallerButton(
              label: _isUpdate ? 'Обновить' : 'Установить',
              icon: LucideIcons.download,
              primary: true,
              onPressed: _targetDir.isEmpty ? null : _run,
            ),
          ],
        ),
      ],
    );
  }

  Widget _pathRow() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        color: InstallerTokens.surfaceSunken,
        borderRadius: BorderRadius.circular(InstallerRadius.md),
        border: Border.all(color: InstallerTokens.border),
      ),
      child: Row(
        children: [
          const Icon(LucideIcons.folder, size: 18, color: InstallerTokens.text3),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Папка установки',
                  style: TextStyle(color: InstallerTokens.text3, fontSize: 11, letterSpacing: 0.4),
                ),
                const SizedBox(height: 3),
                Text(
                  _targetDir,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: InstallerTokens.text, fontSize: 13),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          InstallerButton(label: 'Изменить', onPressed: _pickFolder),
        ],
      ),
    );
  }

  Widget _uninstallWelcome() {
    return Column(
      key: const ValueKey('uninstall'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const InstallerLogo(),
            const SizedBox(width: 18),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Удалить Clarify?',
                    style: TextStyle(
                      fontFamily: 'Unbounded',
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      color: InstallerTokens.text,
                      height: 1.15,
                      letterSpacing: -0.5,
                    ),
                  ),
                  SizedBox(height: 6),
                  Text(
                    'Программа и её ярлыки будут удалены с компьютера.\nЗадачи в облаке останутся на месте.',
                    style: TextStyle(color: InstallerTokens.text2, fontSize: 13, height: 1.5),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 26),
        InstallerOption(
          title: 'Удалить и локальные данные',
          subtitle: 'Офлайн-кэш задач и настройки на этом компьютере',
          icon: LucideIcons.trash2,
          value: _removeUserData,
          onChanged: (v) => setState(() => _removeUserData = v),
        ),
        const Spacer(),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            InstallerButton(label: 'Отмена', onPressed: () => exit(0)),
            const SizedBox(width: 12),
            InstallerButton(
              label: 'Удалить',
              icon: LucideIcons.trash2,
              primary: true,
              onPressed: _run,
            ),
          ],
        ),
      ],
    );
  }

  Widget _working() {
    final percent = (_progress.value * 100).clamp(0, 100).round();
    return Column(
      key: const ValueKey('working'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const InstallerLogo(size: 48),
        const SizedBox(height: 24),
        Text(
          widget.uninstallMode ? 'Удаляем Clarify' : (_isUpdate ? 'Обновляем Clarify' : 'Устанавливаем Clarify'),
          style: const TextStyle(
            fontFamily: 'Unbounded',
            fontSize: 24,
            fontWeight: FontWeight.w700,
            color: InstallerTokens.text,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _stepLabel(_progress.step),
          style: const TextStyle(color: InstallerTokens.text2, fontSize: 14),
        ),
        const SizedBox(height: 28),
        InstallerProgressBar(value: _progress.value),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              // На шагах вроде «Создаём ярлыки» подпись под полосой совпадала
              // с заголовком шага, и одна и та же фраза стояла на экране
              // дважды. Под полосой место для подробностей (имя файла), а не
              // для повтора.
              child: Text(
                _progress.detail == _stepLabel(_progress.step) ? '' : _progress.detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: InstallerTokens.text3, fontSize: 12),
              ),
            ),
            Text(
              '$percent%',
              style: const TextStyle(
                color: InstallerTokens.text2,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _stepLabel(InstallStep step) {
    switch (step) {
      case InstallStep.preparing:
        return 'Готовим папку';
      case InstallStep.extracting:
        return 'Распаковываем файлы программы';
      case InstallStep.shortcuts:
        return 'Создаём ярлыки';
      case InstallStep.registry:
        return 'Регистрируем программу в системе';
      case InstallStep.cleanup:
        return 'Убираем за собой';
      case InstallStep.finished:
        return 'Почти готово';
    }
  }

  Widget _done() {
    return Column(
      key: const ValueKey('done'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: InstallerTokens.success.withValues(alpha: 0.14),
            shape: BoxShape.circle,
            border: Border.all(color: InstallerTokens.success.withValues(alpha: 0.5)),
          ),
          child: const Icon(LucideIcons.check, color: InstallerTokens.success, size: 28),
        ),
        const SizedBox(height: 24),
        Text(
          widget.uninstallMode ? 'Clarify удалён' : (_isUpdate ? 'Clarify обновлён' : 'Clarify установлен'),
          style: const TextStyle(
            fontFamily: 'Unbounded',
            fontSize: 26,
            fontWeight: FontWeight.w700,
            color: InstallerTokens.text,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          widget.uninstallMode
              ? 'Спасибо, что пользовались. Задачи в облаке остались на месте —\nвойдите под тем же аккаунтом, и всё вернётся.'
              : 'Ярлык уже в меню «Пуск».\nПри закрытии окна программа сворачивается в трей.',
          style: const TextStyle(color: InstallerTokens.text2, fontSize: 13, height: 1.6),
        ),
        const Spacer(),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            InstallerButton(label: 'Закрыть', onPressed: () => exit(0)),
            if (!widget.uninstallMode) ...[
              const SizedBox(width: 12),
              InstallerButton(
                label: 'Запустить Clarify',
                icon: LucideIcons.arrowRight,
                primary: true,
                onPressed: _launchApp,
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _failed() {
    return Column(
      key: const ValueKey('failed'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: InstallerTokens.danger.withValues(alpha: 0.14),
            shape: BoxShape.circle,
            border: Border.all(color: InstallerTokens.danger.withValues(alpha: 0.5)),
          ),
          child: const Icon(LucideIcons.triangleAlert, color: InstallerTokens.danger, size: 26),
        ),
        const SizedBox(height: 22),
        Text(
          _errorMessage,
          style: const TextStyle(
            fontFamily: 'Unbounded',
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: InstallerTokens.text,
            height: 1.3,
            letterSpacing: -0.4,
          ),
        ),
        if (_errorDetails != null) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: InstallerTokens.surfaceSunken,
              borderRadius: BorderRadius.circular(InstallerRadius.sm),
              border: Border.all(color: InstallerTokens.border),
            ),
            child: Text(
              _errorDetails!,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: InstallerTokens.text3, fontSize: 11, height: 1.5),
            ),
          ),
        ],
        const Spacer(),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            InstallerButton(label: 'Закрыть', onPressed: () => exit(1)),
            const SizedBox(width: 12),
            InstallerButton(
              label: 'Попробовать снова',
              icon: LucideIcons.refreshCw,
              primary: true,
              onPressed: () => setState(() => _stage = _Stage.welcome),
            ),
          ],
        ),
      ],
    );
  }
}

/// Мягкое акцентное свечение в углу — то же ощущение «живого фона», что и в
/// приложении (AmbientBackground), но статичное: установщик живёт минуту, и
/// анимированный фон здесь только жёг бы батарею ноутбука.
class _AmbientGlow extends StatelessWidget {
  const _AmbientGlow();

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(-0.9, -1.1),
              radius: 1.25,
              colors: [
                InstallerTokens.accent.withValues(alpha: 0.20),
                InstallerTokens.accent.withValues(alpha: 0.04),
                Colors.transparent,
              ],
              stops: const [0.0, 0.45, 1.0],
            ),
          ),
        ),
      ),
    );
  }
}
