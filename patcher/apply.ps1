[CmdletBinding()]
param(
    [string]$GamePath,
    [switch]$SkipSave,
    [switch]$NoLaunch,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:FilesRoot = Join-Path $script:RepoRoot 'files'
$script:PatcherVersion = '1.0.0'

function Write-Banner {
    Write-Host ''
    Write-Host '========================================' -ForegroundColor DarkCyan
    Write-Host '  Big Dig - русский перевод  v1.0.0' -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor DarkCyan
    Write-Host ''
}

function Fail([string]$Message) {
    Write-Host ''
    Write-Host "ОШИБКА: $Message" -ForegroundColor Red
    exit 1
}

function Normalize-GamePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }

    $p = $Path.Trim().Trim('"')

    if (-not (Test-Path -LiteralPath $p)) { return $null }

    if (Test-Path -LiteralPath (Join-Path $p 'BigDig.exe')) {
        return (Resolve-Path -LiteralPath $p).Path
    }
    if ((Split-Path -Leaf $p) -ieq 'BigDig_Data') {
        return (Resolve-Path -LiteralPath (Split-Path -Parent $p)).Path
    }
    if (Test-Path -LiteralPath (Join-Path $p '..\BigDig.exe')) {
        return (Resolve-Path -LiteralPath (Join-Path $p '..')).Path
    }
    if (Test-Path -LiteralPath (Join-Path $p 'game\BigDig.exe')) {
        return (Resolve-Path -LiteralPath (Join-Path $p 'game')).Path
    }
    if (Test-Path -LiteralPath (Join-Path $p 'Big Dig\BigDig.exe')) {
        return (Resolve-Path -LiteralPath (Join-Path $p 'Big Dig')).Path
    }

    return $null
}

function Find-GamePath {
    $candidates = New-Object System.Collections.Generic.List[string]
    $steamRoots = @()

    foreach ($key in @(
        'HKCU:\Software\Valve\Steam',
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam'
    )) {
        try {
            $props = Get-ItemProperty -Path $key -ErrorAction Stop
            foreach ($name in @('SteamPath', 'InstallPath')) {
                if ($props.$name) { $steamRoots += $props.$name }
            }
        } catch {
        }
    }

    foreach ($root in $steamRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $root = $root.Trim().Trim('"')
        $candidates.Add([System.IO.Path]::Combine($root, 'steamapps\common\Big Dig'))

        $vdf = [System.IO.Path]::Combine($root, 'steamapps\libraryfolders.vdf')
        if (Test-Path -LiteralPath $vdf) {
            $text = Get-Content -LiteralPath $vdf -Raw
            foreach ($match in [regex]::Matches($text, '"path"\s+"([^"]+)"')) {
                $library = $match.Groups[1].Value -replace '\\\\', '\'
                $candidates.Add([System.IO.Path]::Combine($library, 'steamapps\common\Big Dig'))
            }
        }
    }

    foreach ($path in @(
        'C:\Program Files (x86)\Steam\steamapps\common\Big Dig',
        'C:\Program Files\Steam\steamapps\common\Big Dig',
        'D:\SteamLibrary\steamapps\common\Big Dig',
        'E:\SteamLibrary\steamapps\common\Big Dig',
        (Join-Path $env:USERPROFILE 'Desktop\Big.Dig\game'),
        (Join-Path $env:USERPROFILE 'OneDrive\Desktop\Big.Dig\game'),
        (Join-Path $env:USERPROFILE 'Desktop\Big Dig'),
        (Join-Path $env:USERPROFILE 'OneDrive\Desktop\Big Dig')
    )) {
        if ($path) { $candidates.Add($path) }
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath ([System.IO.Path]::Combine($candidate, 'BigDig.exe'))) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

function Select-GameFolder {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Выберите папку, в которой лежит BigDig.exe'
        $dialog.ShowNewFolderButton = $false

        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            return $dialog.SelectedPath
        }
        return $null
    } catch {
        Write-Host 'Не удалось открыть окно выбора папки.' -ForegroundColor Yellow
        return (Read-Host 'Введите путь к папке с BigDig.exe')
    }
}

function Get-SaveFiles {
    $saveRoot = Join-Path $env:USERPROFILE 'AppData\LocalLow\BirdGang\BigDig'
    if (-not (Test-Path -LiteralPath $saveRoot)) { return @() }
    return @(Get-ChildItem -LiteralPath $saveRoot -Recurse -File -Filter '*_save.json' -ErrorAction SilentlyContinue)
}

function Test-PatchFiles {
    $sums = Join-Path $script:RepoRoot 'SHA256SUMS.txt'
    if (-not (Test-Path -LiteralPath $sums)) {
        Write-Host 'SHA256SUMS.txt не найден, проверка целостности пропущена.' -ForegroundColor Yellow
        return
    }

    Write-Host 'Проверяю файлы патча...'
    $bad = 0
    foreach ($line in Get-Content -LiteralPath $sums -Encoding UTF8) {
        if ($line -notmatch '^([0-9a-fA-F]{64})\s+(.+)$') { continue }

        $expected = $Matches[1].ToLower()
        $relative = $Matches[2].Trim()
        $file = Join-Path $script:RepoRoot ($relative -replace '/', '\')

        if (-not (Test-Path -LiteralPath $file)) {
            Write-Host "  НЕТ: $relative" -ForegroundColor Red
            $bad++
            continue
        }

        $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLower()
        if ($actual -ne $expected) {
            Write-Host "  БИТЫЙ: $relative" -ForegroundColor Red
            $bad++
        }
    }

    if ($bad -gt 0) {
        Fail "Файлы патча повреждены или неполные ($bad). Скачайте репозиторий заново."
    }
    Write-Host '  OK' -ForegroundColor Green
}

Write-Banner

if (-not (Test-Path -LiteralPath $script:FilesRoot)) {
    Fail 'Рядом с патчером нет папки files. Распакуйте архив целиком, не перетаскивайте один батник.'
}

Test-PatchFiles

if ($GamePath) { $GamePath = Normalize-GamePath $GamePath }
if (-not $GamePath) { $GamePath = Find-GamePath }

if (-not $GamePath) {
    Write-Host 'Игра не найдена автоматически.'
    Write-Host 'Укажите папку, в которой лежит BigDig.exe.'
    $GamePath = Select-GameFolder
    $GamePath = Normalize-GamePath $GamePath
}

if (-not $GamePath) {
    Fail 'Папка с BigDig.exe не выбрана.'
}

$dataRoot = Join-Path $GamePath 'BigDig_Data'
$aaRoot = Join-Path $dataRoot 'StreamingAssets\aa'
if (-not (Test-Path -LiteralPath (Join-Path $aaRoot 'catalog.bin'))) {
    Fail "В выбранной папке нет BigDig_Data\StreamingAssets\aa\catalog.bin. Это точно папка игры?`n$GamePath"
}

Write-Host "Игра: $GamePath"
Write-Host ''

$relativeFiles = @()
for ($i = 0; $i -lt 13; $i++) {
    $relativeFiles += "BigDig_Data\level$i"
}
$relativeFiles += 'BigDig_Data\StreamingAssets\aa\catalog.bin'
$relativeFiles += 'BigDig_Data\StreamingAssets\aa\StandaloneWindows64\localization-locales_assets_all.bundle'
$relativeFiles += 'BigDig_Data\StreamingAssets\aa\StandaloneWindows64\localization-string-tables-russian(ru)_assets_all.bundle'

$desktop = [Environment]::GetFolderPath('Desktop')
if ([string]::IsNullOrWhiteSpace($desktop)) { $desktop = $env:USERPROFILE }
$backupRoot = Join-Path $desktop 'BigDig-RU-Backup'
$stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$backupDir = Join-Path $backupRoot $stamp

if ($DryRun) {
    Write-Host 'Режим проверки: файлы не изменяются.' -ForegroundColor Yellow
    Write-Host "Бэкап был бы здесь: $backupDir"
    Write-Host 'Файлы к замене:'
    foreach ($relative in $relativeFiles) { Write-Host "  $relative" }

    $saveFiles = @(Get-SaveFiles)
    Write-Host "Сохранения: $($saveFiles.Count)"
    foreach ($save in $saveFiles) { Write-Host "  $($save.FullName)" }

    exit 0
}

$running = Get-Process -Name BigDig -ErrorAction SilentlyContinue
if ($running) {
    Fail 'Big Dig сейчас запущен. Закройте игру и запустите патчер снова.'
}

$probe = Join-Path $GamePath '.bigdig-ru-write-test'
try {
    Set-Content -LiteralPath $probe -Value 'test' -Encoding ASCII -ErrorAction Stop
    Remove-Item -LiteralPath $probe -Force -ErrorAction Stop
} catch {
    Fail "Нет прав на запись в папку игры. Запустите Apply-RU.bat от имени администратора.`n$($_.Exception.Message)"
}

New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
Write-Host "Бэкап: $backupDir"
Write-Host ''

Write-Host 'Бэкаплю оригинальные файлы...'
foreach ($relative in $relativeFiles) {
    $destination = Join-Path $GamePath $relative
    if (Test-Path -LiteralPath $destination) {
        $backupFile = Join-Path $backupDir $relative
        $backupParent = Split-Path -Parent $backupFile
        if (-not (Test-Path -LiteralPath $backupParent)) {
            New-Item -ItemType Directory -Path $backupParent -Force | Out-Null
        }
        Copy-Item -LiteralPath $destination -Destination $backupFile -Force
    }
}

$saveFiles = @()
$saveRecords = @()
if (-not $SkipSave) {
    $saveFiles = @(Get-SaveFiles)
    foreach ($save in $saveFiles) {
        $saveRoot = Join-Path $env:USERPROFILE 'AppData\LocalLow\BirdGang\BigDig'
        $relativeSave = $save.FullName.Substring($saveRoot.Length).TrimStart('\')
        $backupRelative = Join-Path 'save' $relativeSave
        $backupFile = Join-Path $backupDir $backupRelative
        $backupParent = Split-Path -Parent $backupFile
        if (-not (Test-Path -LiteralPath $backupParent)) {
            New-Item -ItemType Directory -Path $backupParent -Force | Out-Null
        }
        Copy-Item -LiteralPath $save.FullName -Destination $backupFile -Force
        $saveRecords += [pscustomobject]@{
            original = $save.FullName
            backup   = $backupRelative
        }
    }
}

$backupInfo = [pscustomobject]@{
    patcherVersion = $script:PatcherVersion
    timestamp      = (Get-Date).ToString('o')
    gamePath       = $GamePath
    files          = $relativeFiles
    saveFiles      = $saveRecords
}
$backupInfo | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $backupDir 'backup-info.json') -Encoding UTF8

Write-Host 'Ставлю русский перевод...'
try {
    foreach ($relative in $relativeFiles) {
        $source = Join-Path $script:FilesRoot $relative
        $destination = Join-Path $GamePath $relative
        $destinationParent = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $destinationParent)) {
            New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        }
        Copy-Item -LiteralPath $source -Destination $destination -Force
        Write-Host "  $relative"
    }
} catch {
    Fail "Не удалось скопировать файлы. Бэкап уже сделан: $backupDir`n$($_.Exception.Message)"
}

if ($SkipSave) {
    Write-Host 'Сохранение не трогаю (-SkipSave). Выберите русский в настройках игры.' -ForegroundColor Yellow
} elseif ($saveFiles.Count -eq 0) {
    Write-Host 'Сохранение не найдено. После запуска выберите «Русский» в настройках.' -ForegroundColor Yellow
} else {
    foreach ($save in $saveFiles) {
        try {
            $text = [System.IO.File]::ReadAllText($save.FullName, [System.Text.Encoding]::UTF8)
            if ($text -notmatch '"languageCode"\s*:\s*"[^"]*"') {
                Write-Host '  languageCode в сохранении не найден, оставляю как есть.' -ForegroundColor Yellow
                continue
            }

            if ($text -match '"languageCode"\s*:\s*"ru"') {
                Write-Host '  Язык в сохранении уже ru.' -ForegroundColor Green
                continue
            }

            $newText = [regex]::Replace($text, '("languageCode"\s*:\s*)"[^"]*"', '$1"ru"')
            [System.IO.File]::WriteAllText($save.FullName, $newText, (New-Object System.Text.UTF8Encoding($false)))
            Write-Host '  Язык в сохранении: ru' -ForegroundColor Green
        } catch {
            Write-Host "  Не удалось обновить сохранение: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host '  Файлы игры уже заменены. Выберите русский в настройках.' -ForegroundColor Yellow
        }
    }
}

Write-Host ''
Write-Host 'Готово.' -ForegroundColor Green
Write-Host "Бэкап: $backupDir"
Write-Host 'Запускайте Big Dig.'
Write-Host 'Если интерфейс остался на английском: Настройки -> Язык -> Русский.'

if (-not $NoLaunch) {
    $answer = Read-Host 'Запустить игру сейчас? (y/n)'
    if ($answer -match '^(y|yes|д|да)$') {
        Start-Process -FilePath (Join-Path $GamePath 'BigDig.exe')
    }
}
