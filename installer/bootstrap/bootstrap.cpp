// Оболочка одиночного установочного файла Clarify.
//
// Зачем она вообще нужна: приложение на Flutter — это не один exe, а exe плюс
// библиотеки и папка data. Раздавать такое «одним файлом» нельзя, а показывать
// человеку архив с полусотней файлов — тем более. Поэтому наружу торчит один
// маленький нативный exe: к его концу дописан zip, внутри которого лежит наш
// установщик (тоже приложение на Flutter) и упакованная программа.
//
// Что делает: находит дописанный к себе архив по сигнатуре в последних 24
// байтах, распаковывает во временную папку системным tar.exe (есть в Windows
// 10/11 из коробки, сторонних зависимостей не требует), запускает установщик и
// ждёт его завершения, после чего убирает за собой. Своего интерфейса у неё
// нет — всё, что видит человек, рисует установщик на Flutter. Единственное
// исключение — окно с ошибкой, если распаковать не удалось: молча закрыться,
// не сказав ни слова, хуже всего.

#include <windows.h>
#include <shlwapi.h>
#include <string>
#include <vector>

namespace {

// Сигнатура и размеры лежат в самом конце файла: искать их с начала нельзя —
// exe-часть может содержать что угодно, включая случайное совпадение байтов.
const char kMagic[8] = {'C', 'L', 'R', 'F', 'Y', 'P', 'K', '1'};
const DWORD kFooterSize = 24;  // 8 байт сигнатуры + 8 смещение + 8 размер

void ShowError(const std::wstring& message, const std::wstring& details = L"") {
  std::wstring text = message;
  if (!details.empty()) {
    text += L"\n\n";
    text += details;
  }
  MessageBoxW(nullptr, text.c_str(), L"Установка Clarify", MB_ICONERROR | MB_OK);
}

std::wstring SelfPath() {
  std::vector<wchar_t> buffer(MAX_PATH);
  DWORD length = GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
  // MAX_PATH может не хватить: путь пользователя бывает длинным, а установщик
  // часто запускают прямо из папки «Загрузки» с длинным именем.
  while (length == buffer.size() && GetLastError() == ERROR_INSUFFICIENT_BUFFER) {
    buffer.resize(buffer.size() * 2);
    length = GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
  }
  return std::wstring(buffer.data(), length);
}

std::wstring SystemToolPath(const wchar_t* tool) {
  // Полный путь к системной утилите, а не голое имя: иначе поиск пойдёт по
  // PATH, где может оказаться чужой tar.exe или cmd.exe.
  std::vector<wchar_t> buffer(MAX_PATH);
  UINT length = GetSystemDirectoryW(buffer.data(), static_cast<UINT>(buffer.size()));
  if (length == 0) return tool;
  std::wstring path(buffer.data(), length);
  path += L"\\";
  path += tool;
  return path;
}

bool CreateUniqueTempDir(std::wstring& result) {
  std::vector<wchar_t> tempBuffer(MAX_PATH + 1);
  DWORD length = GetTempPathW(static_cast<DWORD>(tempBuffer.size()), tempBuffer.data());
  if (length == 0) return false;

  std::wstring base(tempBuffer.data(), length);
  for (int attempt = 0; attempt < 32; ++attempt) {
    std::wstring candidate = base + L"ClarifySetup_" + std::to_wstring(GetCurrentProcessId()) +
                             L"_" + std::to_wstring(GetTickCount64() + attempt);
    if (CreateDirectoryW(candidate.c_str(), nullptr)) {
      result = candidate;
      return true;
    }
  }
  return false;
}

void RemoveDirectoryRecursive(const std::wstring& dir) {
  WIN32_FIND_DATAW data;
  HANDLE handle = FindFirstFileW((dir + L"\\*").c_str(), &data);
  if (handle != INVALID_HANDLE_VALUE) {
    do {
      const std::wstring name = data.cFileName;
      if (name == L"." || name == L"..") continue;
      const std::wstring full = dir + L"\\" + name;
      if (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
        RemoveDirectoryRecursive(full);
      } else {
        SetFileAttributesW(full.c_str(), FILE_ATTRIBUTE_NORMAL);
        DeleteFileW(full.c_str());
      }
    } while (FindNextFileW(handle, &data));
    FindClose(handle);
  }

  // Сама папка удаляется не с первой попытки: сразу после выхода дочернего
  // процесса Windows ещё держит её как его рабочий каталог, и первый
  // RemoveDirectory возвращает ERROR_SHARING_VIOLATION. Без повторов в TEMP
  // копились пустые папки от каждого запуска установщика.
  for (int attempt = 0; attempt < 20; ++attempt) {
    if (RemoveDirectoryW(dir.c_str())) return;
    const DWORD error = GetLastError();
    if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) return;
    Sleep(100);
  }
}

// Подчищает папки от прошлых запусков: если предыдущий установщик был снят
// диспетчером задач или упал, его временная папка осталась бы в TEMP навсегда.
void CleanupStaleTempDirs() {
  std::vector<wchar_t> buffer(MAX_PATH + 1);
  const DWORD length = GetTempPathW(static_cast<DWORD>(buffer.size()), buffer.data());
  if (length == 0) return;
  const std::wstring temp(buffer.data(), length);

  WIN32_FIND_DATAW data;
  HANDLE handle = FindFirstFileW((temp + L"ClarifySetup_*").c_str(), &data);
  if (handle == INVALID_HANDLE_VALUE) return;

  const std::wstring ownPrefix = L"ClarifySetup_" + std::to_wstring(GetCurrentProcessId()) + L"_";
  do {
    if (!(data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) continue;
    const std::wstring name = data.cFileName;
    if (name == L"." || name == L"..") continue;
    // Свою собственную папку не трогаем — она сейчас в работе.
    if (name.rfind(ownPrefix, 0) == 0) continue;
    RemoveDirectoryRecursive(temp + name);
  } while (FindNextFileW(handle, &data));
  FindClose(handle);
}

// Достаёт дописанный архив из собственного файла. Читаем кусками, а не целиком
// в память: payload — это десятки мегабайт, и держать их в памяти незачем.
bool ExtractPayload(const std::wstring& selfPath, const std::wstring& zipPath, std::wstring& error) {
  HANDLE self = CreateFileW(selfPath.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (self == INVALID_HANDLE_VALUE) {
    error = L"Не удалось открыть установочный файл.";
    return false;
  }

  LARGE_INTEGER fileSize;
  if (!GetFileSizeEx(self, &fileSize) || fileSize.QuadPart < kFooterSize) {
    CloseHandle(self);
    error = L"Установочный файл повреждён (слишком мал).";
    return false;
  }

  LARGE_INTEGER footerPos;
  footerPos.QuadPart = fileSize.QuadPart - kFooterSize;
  if (!SetFilePointerEx(self, footerPos, nullptr, FILE_BEGIN)) {
    CloseHandle(self);
    error = L"Установочный файл повреждён (не читается служебная запись).";
    return false;
  }

  unsigned char footer[kFooterSize];
  DWORD read = 0;
  if (!ReadFile(self, footer, kFooterSize, &read, nullptr) || read != kFooterSize) {
    CloseHandle(self);
    error = L"Установочный файл повреждён (не читается служебная запись).";
    return false;
  }

  if (memcmp(footer, kMagic, sizeof(kMagic)) != 0) {
    CloseHandle(self);
    error = L"Установочный файл повреждён: внутри нет упакованной программы.\n"
            L"Скачайте установщик заново.";
    return false;
  }

  unsigned long long offset = 0;
  unsigned long long size = 0;
  memcpy(&offset, footer + 8, sizeof(offset));
  memcpy(&size, footer + 16, sizeof(size));

  if (offset + size + kFooterSize != static_cast<unsigned long long>(fileSize.QuadPart)) {
    CloseHandle(self);
    error = L"Установочный файл повреждён: размеры не сходятся.\nСкачайте установщик заново.";
    return false;
  }

  LARGE_INTEGER payloadPos;
  payloadPos.QuadPart = static_cast<LONGLONG>(offset);
  if (!SetFilePointerEx(self, payloadPos, nullptr, FILE_BEGIN)) {
    CloseHandle(self);
    error = L"Не удалось прочитать упакованную программу.";
    return false;
  }

  HANDLE out = CreateFileW(zipPath.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                           FILE_ATTRIBUTE_NORMAL, nullptr);
  if (out == INVALID_HANDLE_VALUE) {
    CloseHandle(self);
    error = L"Не удалось создать временный файл. Проверьте свободное место на диске.";
    return false;
  }

  std::vector<char> buffer(1 << 20);  // 1 МБ за проход
  unsigned long long left = size;
  bool ok = true;
  while (left > 0) {
    const DWORD chunk = static_cast<DWORD>(left < buffer.size() ? left : buffer.size());
    DWORD got = 0;
    if (!ReadFile(self, buffer.data(), chunk, &got, nullptr) || got == 0) {
      ok = false;
      break;
    }
    DWORD written = 0;
    if (!WriteFile(out, buffer.data(), got, &written, nullptr) || written != got) {
      ok = false;
      break;
    }
    left -= got;
  }

  CloseHandle(out);
  CloseHandle(self);

  if (!ok) {
    error = L"Не удалось распаковать установщик. Проверьте свободное место на диске.";
    return false;
  }
  return true;
}

// Запуск без единого мелькнувшего чёрного окна: установка должна выглядеть как
// одно приложение, а не как приложение поверх консоли.
bool RunHidden(const std::wstring& commandLine, DWORD* exitCode, const std::wstring& workingDir = L"") {
  STARTUPINFOW si = {};
  si.cb = sizeof(si);
  si.dwFlags = STARTF_USESHOWWINDOW;
  si.wShowWindow = SW_HIDE;

  PROCESS_INFORMATION pi = {};
  std::vector<wchar_t> mutableCommandLine(commandLine.begin(), commandLine.end());
  mutableCommandLine.push_back(L'\0');

  if (!CreateProcessW(nullptr, mutableCommandLine.data(), nullptr, nullptr, FALSE,
                      CREATE_NO_WINDOW, nullptr,
                      workingDir.empty() ? nullptr : workingDir.c_str(), &si, &pi)) {
    return false;
  }

  WaitForSingleObject(pi.hProcess, INFINITE);
  if (exitCode != nullptr) {
    GetExitCodeProcess(pi.hProcess, exitCode);
  }
  CloseHandle(pi.hProcess);
  CloseHandle(pi.hThread);
  return true;
}

std::wstring Quoted(const std::wstring& value) { return L"\"" + value + L"\""; }

}  // namespace

int APIENTRY wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
  const std::wstring selfPath = SelfPath();

  CleanupStaleTempDirs();

  std::wstring tempDir;
  if (!CreateUniqueTempDir(tempDir)) {
    ShowError(L"Не удалось создать временную папку.",
              L"Проверьте свободное место на диске и права на папку TEMP.");
    return 1;
  }

  const std::wstring zipPath = tempDir + L"\\bundle.zip";
  std::wstring error;
  if (!ExtractPayload(selfPath, zipPath, error)) {
    RemoveDirectoryRecursive(tempDir);
    ShowError(error);
    return 1;
  }

  // tar из состава Windows понимает zip (внутри libarchive) — это избавляет от
  // необходимости тащить в оболочку собственный распаковщик.
  const std::wstring tarCommand = Quoted(SystemToolPath(L"tar.exe")) + L" -x -f " + Quoted(zipPath) +
                                  L" -C " + Quoted(tempDir);
  DWORD tarExit = 1;
  if (!RunHidden(tarCommand, &tarExit) || tarExit != 0) {
    RemoveDirectoryRecursive(tempDir);
    ShowError(L"Не удалось распаковать установщик.",
              L"Проверьте свободное место на диске и что антивирус не блокирует установку.");
    return 1;
  }

  const std::wstring installerExe = tempDir + L"\\clarify_installer.exe";
  if (!PathFileExistsW(installerExe.c_str())) {
    RemoveDirectoryRecursive(tempDir);
    ShowError(L"Установочный файл повреждён: внутри нет установщика.",
              L"Скачайте установщик заново.");
    return 1;
  }

  // Аргументы командной строки пробрасываем как есть — так «Программы и
  // компоненты» смогут позвать этот же файл с --uninstall, а установщик поймёт,
  // что от него хотят. Плюс отдаём ему путь к самому себе: именно этот файл он
  // положит в папку установки как деинсталлятор.
  std::wstring commandLine = Quoted(installerExe) + L" --self=" + Quoted(selfPath);
  int argc = 0;
  LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (argv != nullptr) {
    for (int i = 1; i < argc; ++i) {
      commandLine += L" ";
      commandLine += Quoted(argv[i]);
    }
    LocalFree(argv);
  }

  STARTUPINFOW si = {};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi = {};
  std::vector<wchar_t> mutableCommandLine(commandLine.begin(), commandLine.end());
  mutableCommandLine.push_back(L'\0');

  DWORD exitCode = 1;
  if (CreateProcessW(nullptr, mutableCommandLine.data(), nullptr, nullptr, FALSE, 0, nullptr,
                     tempDir.c_str(), &si, &pi)) {
    WaitForSingleObject(pi.hProcess, INFINITE);
    GetExitCodeProcess(pi.hProcess, &exitCode);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
  } else {
    RemoveDirectoryRecursive(tempDir);
    ShowError(L"Не удалось запустить установщик.",
              L"Возможно, его заблокировал антивирус.");
    return 1;
  }

  RemoveDirectoryRecursive(tempDir);
  return static_cast<int>(exitCode);
}
