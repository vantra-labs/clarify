<#
.SYNOPSIS
    Собирает Clarify_Setup_<версия>.exe — один файл, который отдаём людям.

.DESCRIPTION
    Порядок сборки:
      1. читаем версию из frontend/pubspec.yaml и прописываем её в установщик,
         чтобы версия в «Программах и компонентах» не разъезжалась с реальной;
      2. собираем само приложение (release) и пакуем в payload.zip;
      3. собираем установщик на Flutter (release);
      4. складываем установщик и payload.zip в один bundle.zip;
      5. компилируем нативную оболочку (bootstrap.exe);
      6. дописываем bundle.zip к оболочке и добавляем 24-байтовую служебную
         запись в конец — по ней оболочка находит архив внутри себя.

.PARAMETER SkipApp
    Не пересобирать само приложение (использовать уже собранный release).
    Нужно, когда правишь только установщик.
#>
[CmdletBinding()]
param(
    [switch]$SkipApp
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent $root
# Раньше установщик лежал рядом с папкой frontend/ (локальная раскладка на
# машине владельца), теперь живёт внутри репозитория приложения — корень
# репозитория и есть приложение. Поддерживаются обе раскладки.
$frontend = if (Test-Path (Join-Path $repo 'frontend\pubspec.yaml')) { Join-Path $repo 'frontend' } else { $repo }
$installerApp = Join-Path $root 'clarify_installer'
$bootstrapDir = Join-Path $root 'bootstrap'
$work = Join-Path $root 'build'
$dist = Join-Path $root 'dist'

function Write-Step([string]$text) {
    Write-Host ''
    Write-Host "==> $text" -ForegroundColor Cyan
}

function Invoke-Checked([string]$what, [scriptblock]$action) {
    & $action
    if ($LASTEXITCODE -ne 0) { throw "$what — код возврата $LASTEXITCODE" }
}

# --- 0. Инструменты -----------------------------------------------------------

$sevenZip = @(
    'C:\Program Files\7-Zip\7z.exe',
    'C:\Program Files (x86)\7-Zip\7z.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $sevenZip) { throw 'Не найден 7z.exe — он нужен для упаковки. Установите 7-Zip.' }

$vcvars = Get-ChildItem 'C:\Program Files\Microsoft Visual Studio' -Recurse -Filter 'vcvars64.bat' -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $vcvars) { throw 'Не найден vcvars64.bat — нужен Visual Studio с компонентом C++.' }

# --- 1. Версия ----------------------------------------------------------------

Write-Step 'Версия'
$pubspec = Get-Content (Join-Path $frontend 'pubspec.yaml') -Raw
if ($pubspec -notmatch '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)') {
    throw 'Не удалось прочитать версию из frontend/pubspec.yaml'
}
$version = $Matches[1]
Write-Host "Версия приложения: $version"

$buildInfoPath = Join-Path $installerApp 'lib\build_info.dart'
$buildInfo = Get-Content $buildInfoPath -Raw
$buildInfo = [regex]::Replace($buildInfo, "const String kAppVersion = '[^']*';", "const String kAppVersion = '$version';")
Set-Content $buildInfoPath $buildInfo -Encoding UTF8 -NoNewline

# --- 2. Приложение ------------------------------------------------------------

$appRelease = Join-Path $frontend 'build\windows\x64\runner\Release'
if (-not $SkipApp) {
    Write-Step 'Сборка приложения Clarify (release)'
    Push-Location $frontend
    try { Invoke-Checked 'flutter build windows' { flutter build windows --release } }
    finally { Pop-Location }
}
if (-not (Test-Path (Join-Path $appRelease 'Clarify.exe'))) {
    throw "Не найден собранный Clarify.exe в $appRelease"
}

# --- 3. Установщик ------------------------------------------------------------

Write-Step 'Сборка установщика (release)'
Push-Location $installerApp
try {
    Invoke-Checked 'flutter pub get' { flutter pub get }
    Invoke-Checked 'flutter build windows' { flutter build windows --release }
}
finally { Pop-Location }

$installerRelease = Join-Path $installerApp 'build\windows\x64\runner\Release'
if (-not (Test-Path (Join-Path $installerRelease 'clarify_installer.exe'))) {
    throw "Не найден собранный clarify_installer.exe в $installerRelease"
}

# --- 4. Упаковка --------------------------------------------------------------

Write-Step 'Упаковка'
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Force $work | Out-Null
New-Item -ItemType Directory -Force $dist | Out-Null

$stage = Join-Path $work 'stage'
New-Item -ItemType Directory -Force $stage | Out-Null

# --- 5. Нативная оболочка -----------------------------------------------------

Write-Step 'Компиляция нативной оболочки'
$build = "`"$vcvars`" >nul 2>&1 && cd /d `"$bootstrapDir`" && rc /nologo bootstrap.rc && cl /nologo /O2 /W3 /EHsc /DUNICODE /D_UNICODE bootstrap.cpp bootstrap.res /Fe:bootstrap.exe /link /SUBSYSTEM:WINDOWS shlwapi.lib user32.lib shell32.lib"
cmd /c $build | Out-Null
$stub = Join-Path $bootstrapDir 'bootstrap.exe'
if (-not (Test-Path $stub)) { throw 'Не удалось скомпилировать bootstrap.exe' }

# Склейка одиночного exe: оболочка + архив + служебная запись из 24 байт
# (сигнатура, смещение архива, его размер) — по ней оболочка находит архив
# внутри себя.
function New-SingleFileExe([string]$stubPath, [string]$zipPath, [string]$outPath) {
    Copy-Item $stubPath $outPath -Force
    $stubLength = (Get-Item $stubPath).Length
    $zipLength = (Get-Item $zipPath).Length

    $output = [System.IO.File]::Open($outPath, [System.IO.FileMode]::Append)
    try {
        $zipStream = [System.IO.File]::OpenRead($zipPath)
        try { $zipStream.CopyTo($output) } finally { $zipStream.Dispose() }

        $footer = [byte[]]::new(24)
        [System.Text.Encoding]::ASCII.GetBytes('CLRFYPK1').CopyTo($footer, 0)
        [System.BitConverter]::GetBytes([UInt64]$stubLength).CopyTo($footer, 8)
        [System.BitConverter]::GetBytes([UInt64]$zipLength).CopyTo($footer, 16)
        $output.Write($footer, 0, $footer.Length)
    }
    finally { $output.Dispose() }
}

# --- 6. Облегчённый деинсталлятор --------------------------------------------

# Тот же установщик, но БЕЗ упакованного приложения: для удаления оно не нужно,
# а копия с приложением внутри оставляла бы в папке установки лишние ~40 МБ
# навсегда. Именно этот файл установщик кладёт рядом с программой.
Write-Step 'Сборка облегчённого деинсталлятора'
$slimStage = Join-Path $work 'stage_uninstaller'
New-Item -ItemType Directory -Force $slimStage | Out-Null
Copy-Item (Join-Path $installerRelease '*') $slimStage -Recurse -Force

$slimZip = Join-Path $work 'uninstaller.zip'
Invoke-Checked '7z (uninstaller)' { & $sevenZip a -tzip -mx=5 -bso0 -bsp0 $slimZip (Join-Path $slimStage '*') }

$uninstaller = Join-Path $stage 'uninstaller.exe'
New-SingleFileExe -stubPath $stub -zipPath $slimZip -outPath $uninstaller
Write-Host ("uninstaller.exe: {0:N1} МБ" -f ((Get-Item $uninstaller).Length / 1MB))

# --- 7. Упаковка --------------------------------------------------------------

Write-Step 'Упаковка'

# payload.zip — само приложение
$payload = Join-Path $stage 'payload.zip'
Invoke-Checked '7z (payload)' { & $sevenZip a -tzip -mx=5 -bso0 -bsp0 $payload (Join-Path $appRelease '*') }
Write-Host ("payload.zip: {0:N1} МБ" -f ((Get-Item $payload).Length / 1MB))

# bundle.zip — установщик, payload и облегчённый деинсталлятор
Copy-Item (Join-Path $installerRelease '*') $stage -Recurse -Force
$bundle = Join-Path $work 'bundle.zip'
Invoke-Checked '7z (bundle)' { & $sevenZip a -tzip -mx=5 -bso0 -bsp0 $bundle (Join-Path $stage '*') }
Write-Host ("bundle.zip: {0:N1} МБ" -f ((Get-Item $bundle).Length / 1MB))

# --- 8. Склейка ---------------------------------------------------------------

Write-Step 'Склейка одиночного файла'
$setupPath = Join-Path $dist "Clarify_Setup_$version.exe"
New-SingleFileExe -stubPath $stub -zipPath $bundle -outPath $setupPath

Write-Host ''
Write-Host "Готово: $setupPath" -ForegroundColor Green
Write-Host ("Размер: {0:N1} МБ" -f ((Get-Item $setupPath).Length / 1MB))
