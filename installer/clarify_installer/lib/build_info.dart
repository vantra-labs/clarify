/// Значения подставляет build_installer.ps1 из frontend/pubspec.yaml — руками
/// не править, иначе версия в «Программах и компонентах» разойдётся с версией
/// самого приложения.
const String kAppVersion = '1.0.6';
const String kAppName = 'Clarify';
const String kPublisher = 'VANTRA';
const String kAppExeName = 'Clarify.exe';

/// Имя копии установщика, которая кладётся в папку установки и служит
/// деинсталлятором (её же прописываем в UninstallString).
const String kUninstallerName = 'Clarify_uninstall.exe';

/// Ключ реестра, по которому Windows показывает приложение в списке
/// установленных. HKCU, а не HKLM: ставим для текущего пользователя, без
/// прав администратора.
const String kUninstallKeyPath =
    r'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\Clarify';
const String kRunKeyPath =
    r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
const String kRunValueName = 'Clarify';
