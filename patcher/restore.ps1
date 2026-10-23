[CmdletBinding()]
param(
    [string]$BackupPath,
    [string]$GamePath,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Write-Banner {
    Write-Host ''
    Write-Host '========================================' -ForegroundColor DarkCyan
    Write-Host '  Big Dig - откат русского перевода' -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor DarkCyan
    Write-Host ''
}

function Fail([string]$Message) {
    Write-Host ''
    Write-Host "ОШИБКА: $Message" -ForegroundColor Red
    exit 1
}

Write-Banner

$desktop = [Environment]::GetFolderPath('Desktop')
if ([string]::IsNullOrWhiteSpace($desktop)) { $desktop = $env:USERPROFILE }
$backupRoot = Join-Path $desktop 'BigDig-RU-Backup'

if (-not $BackupPath) {
    if (-not (Test-Path -LiteralPath $backupRoot)) {
        Fail "Папка с бэкапами не найдена:`n$backupRoot"
    }

    $latest = Get-ChildItem -LiteralPath $backupRoot -Directory |
        Sort-Object Name -Descending |
        Select-Object -First 1

    if (-not $latest) {
        Fail "В папке нет бэкапов:`n$backupRoot"
    }

    $BackupPath = $latest.FullName
}

if (-not (Test-Path -LiteralPath $BackupPath)) {
    Fail "Бэкап не найден:`n$BackupPath"
}

$infoPath = Join-Path $BackupPath 'backup-info.json'
if (-not (Test-Path -LiteralPath $infoPath)) {
    Fail "В бэкапе нет backup-info.json:`n$BackupPath"
}

$info = Get-Content -LiteralPath $infoPath -Raw -Encoding UTF8 | ConvertFrom-Json

if (-not $GamePath) { $GamePath = $info.gamePath }
if (-not $GamePath) { Fail 'В бэкапе не указан путь к игре. Запустите Restore-RU.bat с параметром -GamePath.' }

if (-not (Test-Path -LiteralPath (Join-Path $GamePath 'BigDig.exe'))) {
    Fail "По пути из бэкапа нет BigDig.exe:`n$GamePath`nИгра переехала? Запустите Restore-RU.bat и укажите новую папку."
}

Write-Host "Бэкап: $BackupPath"
Write-Host "Игра:  $GamePath"
Write-Host ''

if ($DryRun) {
    Write-Host 'Режим проверки: файлы не изменяются.' -ForegroundColor Yellow
    foreach ($relative in $info.files) {
        $source = Join-Path $BackupPath $relative
        if (Test-Path -LiteralPath $source) {
            Write-Host "  будет восстановлен: $relative"
        } else {
            Write-Host "  НЕТ В БЭКАПЕ: $relative" -ForegroundColor Yellow
        }
    }
    foreach ($save in $info.saveFiles) {
        Write-Host "  сохранение: $($save.original)"
    }
    exit 0
}

$running = Get-Process -Name BigDig -ErrorAction SilentlyContinue
if ($running) {
    Fail 'Big Dig сейчас запущен. Закройте игру и запустите восстановление снова.'
}

$probe = Join-Path $GamePath '.bigdig-ru-write-test'
try {
    Set-Content -LiteralPath $probe -Value 'test' -Encoding ASCII -ErrorAction Stop
    Remove-Item -LiteralPath $probe -Force -ErrorAction Stop
} catch {
    Fail "Нет прав на запись в папку игры. Запустите Restore-RU.bat от имени администратора.`n$($_.Exception.Message)"
}

foreach ($relative in $info.files) {
    $source = Join-Path $BackupPath $relative
    if (-not (Test-Path -LiteralPath $source)) {
        Write-Host "  пропуск (нет в бэкапе): $relative" -ForegroundColor Yellow
        continue
    }

    $destination = Join-Path $GamePath $relative
    $destinationParent = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $destinationParent)) {
        New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
    }
    Copy-Item -LiteralPath $source -Destination $destination -Force
    Write-Host "  восстановлен: $relative"
}

foreach ($save in $info.saveFiles) {
    $source = Join-Path $BackupPath $save.backup
    if (-not (Test-Path -LiteralPath $source)) {
        Write-Host "  пропуск сохранения (нет в бэкапе): $($save.original)" -ForegroundColor Yellow
        continue
    }

    $saveParent = Split-Path -Parent $save.original
    if (-not (Test-Path -LiteralPath $saveParent)) {
        New-Item -ItemType Directory -Path $saveParent -Force | Out-Null
    }
    Copy-Item -LiteralPath $source -Destination $save.original -Force
    Write-Host "  сохранение: $($save.original)"
}

Write-Host ''
Write-Host 'Готово. Оригинальные файлы восстановлены.' -ForegroundColor Green
Write-Host 'Если Steam обновлял игру после установки патча, лучше сделать «Проверить целостность файлов».'
