<#
================================================================================
 DiskHealth.ps1 — универсальный анализатор системного диска Windows
 Версия : 2.0
 Ядро   : Windows PowerShell 5.1+ (удобнее всего запускать через Run-DiskHealth.bat)

 ЧТО ДЕЛАЕТ
   1. Сам определяет системный диск (по переменной окружения SystemDrive).
   2. Сканирует: тома, большие папки, САМЫЕ БОЛЬШИЕ ФАЙЛЫ, профили (включая
      чужие профили на машине), AppData, приложения Microsoft Store (UWP),
      кэши браузеров и разработчика, кэши GPU, системных пожирателей
      (гибернация, WinSxS, теневые копии, кэш обновлений, Delivery
      Optimization, ESD, логи, индекс поиска, DriverStore и т.д.),
      установленные программы, образы WSL/Docker.
   3. РЯДОМ СО СКРИПТОМ создаёт отчёт DiskHealth_Report_<дата>.md и
      DiskHealth_Plan.json (план действий для режима -Fix).
   4. В конце предлагает МЕНЮ:
        [1] выполнить шаги плана — с ПОДТВЕРЖДЕНИЕМ каждого шага и показом
            освобождённого места после шага; всё пишется в DiskHealth_FixLog_*.txt
        [2] открыть отчёт
        [3] повторить анализ
        [0] выход

 ЗАПУСК
   Вариант А: двойной клик по Run-DiskHealth.bat (рекомендуется)
   Вариант Б: powershell -NoProfile -ExecutionPolicy Bypass -File .\DiskHealth.ps1
   Параметры:
     -Quick       быстрый режим: без глубоких проходов по AppData/профилям/UWP
     -NoElevate   не запрашивать права администратора (DISM/VSS будут пропущены)
     -Auto        без интерактивных вопросов и меню (просто анализ+отчёт)
     -Fix         НЕ анализировать заново: выполнить план из последнего отчёта
                  (DiskHealth_Plan.json) с подтверждением каждого шага

 БЕЗОПАСНОСТЬ
   Сам анализ НИЧЕГО не удаляет. Удаление происходит ТОЛЬКО если ты сам
   выберешь пункт [1] и подтвердишь конкретные шаги. Каждый шаг перед
   выполнением показывает, что именно сделает команда.
================================================================================
#>
param(
    [string]$OutputDir = $PSScriptRoot,
    [switch]$Quick,
    [switch]$NoElevate,
    [switch]$Auto,
    [switch]$Fix
)

$ErrorActionPreference = 'SilentlyContinue'
$Version  = '2.0'
$R_GREEN  = '🟢 Безопасно'
$R_YELLOW = '🟡 Осторожно'
$R_RED    = '🔴 Системное'
$runStart = Get-Date

# ------------------------- ПОВЫШЕНИЕ ПРАВ -------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $NoElevate) {
    try {
        Write-Host 'DiskHealth: нужны права администратора. Подтверди запрос UAC...' -ForegroundColor Yellow
        $relaunchArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath))
        if ($Quick) { $relaunchArgs += '-Quick' }
        if ($Auto)  { $relaunchArgs += '-Auto' }
        if ($Fix)   { $relaunchArgs += '-Fix' }
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -ArgumentList $relaunchArgs
        exit 0
    } catch {
        Write-Host 'UAC отклонён — продолжаю БЕЗ админ-прав: часть проверок будет пропущена.' -ForegroundColor Yellow
    }
}

# Системный диск нужен уже режиму -Fix, поэтому определяем сразу после элевации
$sysDrive = $env:SystemDrive
if (-not $sysDrive) { $sysDrive = 'C:' }
if (-not $sysDrive.EndsWith(':')) { $sysDrive = $sysDrive + ':' }

# --------------------------- ХЕЛПЕРЫ ----------------------------
$Report = New-Object System.Collections.Generic.List[string]
$Recs   = New-Object System.Collections.Generic.List[object]

# Сборщик самых больших файлов (включается только на проходе верхнего уровня)
$script:BigFiles   = New-Object System.Collections.Generic.List[object]
$script:CollectBig = $false
$script:BigFileMin = 500MB

function Write-Step { param([string]$Msg) Write-Host ('==> ' + $Msg) -ForegroundColor Cyan }
function Add-Md     { param([string[]]$Lines) foreach ($l in $Lines) { $Report.Add($l) } }
function Esc-md     { param([string]$s) return ($s -replace '\|', '\|') }

function Format-GBn { param($Bytes) if ($null -eq $Bytes -or $Bytes -le 0) { return [double]0 } return [math]::Round($Bytes/1GB,2) }
function Format-GBs { param($Bytes) $n = Format-GBn $Bytes; return ('{0:N2} ГБ' -f $n) }

function Get-FreeGB {
    $v = Get-Volume -DriveLetter $sysDrive.TrimEnd(':')
    if ($v) { return [math]::Round($v.SizeRemaining/1GB,2) }
    $ld = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='" + $sysDrive + "'")
    if ($ld) { return [math]::Round($ld.FreeSpace/1GB,2) }
    return 0
}

# Размер папки БЕЗ захода внутрь junction/symlink:
# перенесённые через ссылку кэши не задваиваются и не считаются на C:
function Get-DirSize {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return [long]0 }
    if (-not (Test-Path -LiteralPath $Path)) { return [long]0 }
    $sum   = [long]0
    $stack = New-Object System.Collections.Stack
    $stack.Push($Path)
    $dirs  = 0
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $dirs++
        if (($dirs % 1500) -eq 0) { Write-Progress -Activity 'DiskHealth: сканирование' -Status $dir -Id 1 }
        $items = Get-ChildItem -LiteralPath $dir -Force
        if ($items) {
            foreach ($it in $items) {
                if ($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                if ($it.PSIsContainer) { $stack.Push($it.FullName) }
                else {
                    $sum += [long]$it.Length
                    if ($script:CollectBig -and $it.Length -ge $script:BigFileMin) {
                        $script:BigFiles.Add([PSCustomObject]@{ Path=$it.FullName; Length=$it.Length })
                    }
                }
            }
        }
    }
    Write-Progress -Activity 'DiskHealth: сканирование' -Completed -Id 1
    return $sum
}

# Размеры подпапок (топ-N по размеру)
function Get-SubdirSizes {
    param([string]$Root, [int]$Top = 15)
    $out = @()
    if (Test-Path -LiteralPath $Root) {
        $out = Get-ChildItem -LiteralPath $Root -Directory -Force |
            Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) } |
            ForEach-Object {
                $s = Get-DirSize $_.FullName
                [PSCustomObject]@{ Name=$_.Name; Path=$_.FullName; Bytes=$s; GB=[math]::Round($s/1GB,2) }
            } | Sort-Object GB -Descending | Select-Object -First $Top
    }
    $out = @($out)
    return $out
}

# Классификация большого файла по расширению
function Get-FileClass {
    param([string]$Path)
    $ext = [System.IO.Path]::GetExtension($Path).ToLower()
    switch ($ext) {
        '.iso'  { return 'Образ диска' } '.img' { return 'Образ диска' }
        '.vhdx' { return 'Диск ВМ' }     '.vhd' { return 'Диск ВМ' } '.vmdk' { return 'Диск ВМ' }
        '.dmp'  { return 'Дамп' }
        '.log'  { return 'Лог' }
        '.tmp'  { return 'Временный' }   '.temp' { return 'Временный' }
        '.zip'  { return 'Архив' } '.7z' { return 'Архив' } '.rar' { return 'Архив' } '.gz' { return 'Архив' } '.cab' { return 'Архив' } '.msu' { return 'Обновление' }
        '.msi'  { return 'Установщик' } '.msp' { return 'Установщик' }
        '.mp4'  { return 'Видео' } '.mkv' { return 'Видео' } '.avi' { return 'Видео' } '.mov' { return 'Видео' }
        default { return 'Данные' }
    }
}

# Классификация папки верхнего уровня: категория + критичность + комментарий
function Get-TopDirInfo {
    param([string]$Name)
    switch ($Name) {
        'Windows'                    { return @('Системная', $R_RED, 'Никогда не удалять вручную. Чистится только DISM/cleanmgr') }
        'Program Files'              { return @('Программы (64-бит)', $R_RED, 'Только деинсталляцией, папки руками не сносить') }
        'Program Files (x86)'        { return @('Программы (32-бит)', $R_RED, 'Только деинсталляцией') }
        'ProgramData'                { return @('Данные программ', $R_RED, 'Не трогать руками') }
        'Users'                      { return @('Профили пользователей', $R_YELLOW, 'Разбирать внутри (AppData, Документы), не сносить целиком') }
        '$Recycle.Bin'               { return @('Корзина', $R_GREEN, 'Штатно: Clear-RecycleBin') }
        '$WinREAgent'                { return @('Хвосты обновления Windows', $R_GREEN, 'Можно удалить, если система стабильна') }
        'Windows.old'                { return @('Старая копия Windows', $R_GREEN, 'Чистится через cleanmgr') }
        'ESD'                        { return @('Дистрибутив Windows', $R_YELLOW, 'Нужен только для восстановления/переустановки Windows') }
        'Recovery'                   { return @('Служебная (WinRE)', $R_RED, 'Не трогать') }
        'PerfLogs'                   { return @('Служебная', $R_GREEN, 'Обычно пустая') }
        'System Volume Information'  { return @('Теневые копии', $R_YELLOW, 'Объём ограничивается через vssadmin, руками не чистить') }
        'AMD'                        { return @('Распакованные драйверы', $R_GREEN, 'Установочные файлы драйвера AMD — после установки можно удалить') }
        'NVIDIA'                     { return @('Распакованные драйверы', $R_GREEN, 'Установочные файлы драйвера NVIDIA — можно удалить') }
        'Intel'                      { return @('Распакованные драйверы', $R_GREEN, 'Установочные файлы драйвера Intel — можно удалить') }
        'inetpub'                    { return @('IIS (веб-сервер)', $R_YELLOW, 'Если не используешь IIS — можно удалить целиком через «Компоненты Windows»') }
        default                      { return @('Пользовательская/прочее', $R_YELLOW, 'Оцени вручную; можно перенести robocopy + junction') }
    }
}

# Совет по папке внутри AppData
function Get-AppDataAdvice {
    param([string]$Name)
    switch -Regex ($Name) {
        '^CapCut$'              { return '🟡 Кэш CapCut. Черновики проектов могут лежать там же — не сносить бездумно. Кэш переносится в настройках приложения' }
        '^Microsoft$'           { return '🟡 Внутри кэши Edge/OneDrive/Teams. Чистить точечно, папку не сносить' }
        '^Yandex$'              { return '🟡 Кэш Яндекс.Браузера. Чистить из настроек браузера' }
        '^GitHubDesktop$'       { return '🟢 Кэш клиента GitHub Desktop; сами репозитории лежат отдельно' }
        '^Discord$'             { return '🟢 Старые версии в подпапках app-* можно удалить' }
        '^Packages$'            { return '🔴 Данные UWP-приложений (Microsoft Store). Руками не трогать' }
        '^Code$'                { return '🟢 Кэши VS Code — чистятся безболезненно' }
        '^\.minecraft$'         { return '🟡 Миры/моды/сборки Minecraft. Переносится на другой диск' }
        '^PrismLauncher'        { return '🟡 Инстансы Minecraft. Переносится в настройках лаунчера' }
        '^(npm-cache|pip|uv)$'  { return '🟢 Кэши пакетных менеджеров, чистятся одной командой' }
        '-updater$'             { return '🟢 Хвосты автообновляторов приложений (старые версии)' }
        '^(PowerToys|Programs|Package Cache)$' { return '🟡 Установленные per-user программы — только деинсталляцией' }
        '^AMD$'                 { return '🟡 Драйверное ПО — чистить через деинсталлятор, не руками' }
        '^(NVIDIA|D3DSCache)$'  { return '🟢 Кэш шейдеров GPU — игры пересоздадут его сами' }
        default                 { return '—' }
    }
}

# ------------------- ИСПОЛНИТЕЛЬ ПЛАНА (с подтверждениями) -------------------
function Invoke-PlanSteps {
    param($Steps)
    if (-not $isAdmin) {
        Write-Host 'Выполнение плана доступно только с правами администратора. Перезапусти скрипт и подтверди UAC.' -ForegroundColor Red
        return
    }
    $runnable = @($Steps | Where-Object { $_.Cmd -and $_.Risk -ne $R_RED })
    if ($runnable.Count -eq 0) {
        Write-Host 'В плане нет шагов с командами — выполнять нечего.' -ForegroundColor Yellow
        return
    }
    Write-Host ''
    Write-Host ('=== ВЫПОЛНЕНИЕ ПЛАНА: ' + $runnable.Count + ' шагов с командами ===') -ForegroundColor White
    Write-Host 'Каждый шаг показывается ПЕРЕД выполнением и требует подтверждения.' -ForegroundColor Yellow
    Write-Host 'Занятые системой файлы пропускаются автоматически. Ничего не удаляется без твоего «y».' -ForegroundColor Yellow
    $a = Read-Host 'Начать выполнение? [y/д = да, что-то другое = отмена]'
    if ($a -notin @('y','Y','д','Д')) { Write-Host 'Отменено.' -ForegroundColor DarkGray; return }

    $logPath = Join-Path $OutputDir ('DiskHealth_FixLog_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.txt')
    try { Start-Transcript -Path $logPath | Out-Null } catch { }

    $all    = $false
    $idx    = 0
    $before = Get-FreeGB
    foreach ($s in $runnable) {
        $idx++
        Write-Host ''
        Write-Host ('--- Шаг ' + $idx + '/' + $runnable.Count + ': ' + $s.Target + ' (+' + $s.Gb + ' ГБ) ---') -ForegroundColor Cyan
        Write-Host ('  Что сделает: ' + $s.What)
        Write-Host '  Команда:' -ForegroundColor DarkGray
        Write-Host ('  ' + ($s.Cmd -replace "`r`n", "`r`n  ")) -ForegroundColor Gray
        $ans = 'a'
        if (-not $all) { $ans = Read-Host '  Выполнить? [y=да / a=все остальные / n=пропустить / q=стоп]' }
        if ($ans -eq 'q') { Write-Host 'Остановлено пользователем.' -ForegroundColor DarkGray; break }
        if ($ans -eq 'n' -and -not $all) { Write-Host 'Пропущено.' -ForegroundColor DarkGray; continue }
        if ($ans -eq 'a') { $all = $true }

        Write-Host '  Выполняю... (шаги с DISM могут занять 5-15 минут)' -ForegroundColor Yellow
        try { Invoke-Expression $s.Cmd } catch { Write-Host ('  Ошибка: ' + $_.Exception.Message) -ForegroundColor Red }
        $now = Get-FreeGB
        $delta = [math]::Round($now - $before, 2)
        Write-Host ('  Свободно на ' + $sysDrive + ': ' + $now + ' ГБ (+' + $delta + ' ГБ к началу)') -ForegroundColor Green
        if ($delta -le 0) { Write-Host '  Место может освободиться после перезагрузки (гибернация/подкачка) или файлы были заняты.' -ForegroundColor DarkGray }
        $before = $now
    }
    try { Stop-Transcript | Out-Null } catch { }
    Write-Host ''
    Write-Host ('Лог действий: ' + $logPath) -ForegroundColor Green
    Write-Host 'Совет: перезагрузись и запусти анализ снова, чтобы увидеть финальную картину.' -ForegroundColor Green
}

# ------------------------- МЕНЮ ПОСЛЕ ОТЧЁТА -------------------------
function Show-Menu {
    while ($true) {
        Write-Host ''
        Write-Host '=== ЧТО ДАЛЬШЕ? ===' -ForegroundColor White
        Write-Host ' [1] Выполнить шаги плана (с подтверждением каждого)'
        Write-Host ' [2] Открыть отчёт'
        Write-Host ' [3] Повторить анализ'
        Write-Host ' [0] Выход'
        $a = Read-Host 'Выбор (0-3)'
        switch ($a) {
            '1' { Invoke-PlanSteps $recsSorted }
            '2' { try { Invoke-Item -LiteralPath $reportPath } catch { Write-Host 'Не удалось открыть автоматически — найди файл вручную.' -ForegroundColor Yellow } }
            '3' {
                Write-Host 'Запускаю повторный анализ в этом же окне...' -ForegroundColor Cyan
                Start-Process -FilePath 'powershell.exe' -Wait -NoNewWindow -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath),'-NoElevate','-OutputDir',('"{0}"' -f $OutputDir))
                return
            }
            '0' { return }
            default { Write-Host 'Не понял. Введи 0, 1, 2 или 3.' -ForegroundColor DarkGray }
        }
    }
}

Write-Host ''
Write-Host ('DiskHealth v' + $Version + ' — анализ системного диска') -ForegroundColor White
$modeTxt = 'полный'; if ($Quick) { $modeTxt = 'быстрый' }
$admTxt  = 'есть';   if (-not $isAdmin) { $admTxt = 'НЕТ (часть проверок пропущена)' }
Write-Host ('Режим: ' + $modeTxt + ' | админ-права: ' + $admTxt) -ForegroundColor DarkGray
Write-Host 'Анализ ничего не удаляет. Удаление — только через меню [1] с подтверждением каждого шага.' -ForegroundColor DarkGray
Write-Host ''

# ------------------- РЕЖИМ -Fix: выполнить план последнего анализа -------------------
if ($Fix) {
    $planPath = Join-Path $PSScriptRoot 'DiskHealth_Plan.json'
    if (-not (Test-Path -LiteralPath $planPath)) {
        Write-Host 'Файл плана DiskHealth_Plan.json не найден. Сначала запусти обычный анализ.' -ForegroundColor Red
        if (-not $Auto) { Read-Host 'Нажми Enter для выхода' | Out-Null }
        exit 1
    }
    Write-Host ('Загружаю план: ' + $planPath) -ForegroundColor Cyan
    $recsSorted = @(Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    Write-Host ('Шагов в плане: ' + $recsSorted.Count + '. Внимание: план мог устареть — при сомнениях запусти свежий анализ.') -ForegroundColor Yellow
    Invoke-PlanSteps $recsSorted
    if (-not $Auto) { Read-Host 'Нажми Enter для выхода' | Out-Null }
    exit 0
}

# ------------------- СИСТЕМА И ТОМА -------------------
Write-Step 'Информация о системе и томах'
$sysDrive = $env:SystemDrive
if (-not $sysDrive) { $sysDrive = 'C:' }
if (-not $sysDrive.EndsWith(':')) { $sysDrive = $sysDrive + ':' }
$winRoot  = $env:SystemRoot
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$ramGb    = [math]::Round($cs.TotalPhysicalMemory/1GB,0)
$isLaptop = ($cs.PCSystemType -eq 2)

$volumes = Get-Volume | Where-Object { $_.DriveLetter } | Sort-Object DriveLetter | ForEach-Object {
    [PSCustomObject]@{
        Letter = ([string]$_.DriveLetter + ':')
        Label  = $_.FileSystemLabel
        SizeGB = [math]::Round($_.Size/1GB,1)
        FreeGB = [math]::Round($_.SizeRemaining/1GB,1)
        IsSys  = (([string]$_.DriveLetter + ':') -eq $sysDrive)
    }
}
if (-not $volumes) {
    $volumes = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3' | ForEach-Object {
        [PSCustomObject]@{
            Letter = $_.DeviceID
            Label  = $_.VolumeName
            SizeGB = [math]::Round($_.Size/1GB,1)
            FreeGB = [math]::Round($_.FreeSpace/1GB,1)
            IsSys  = ($_.DeviceID -eq $sysDrive)
        }
    }
}
$sysVol = $volumes | Where-Object { $_.IsSys } | Select-Object -First 1
if (-not $sysVol) { $sysVol = [PSCustomObject]@{ Letter=$sysDrive; Label=''; SizeGB=0; FreeGB=0; IsSys=$true } }
$sizeGB  = $sysVol.SizeGB
$freeGB  = $sysVol.FreeGB
$freePct = 0
if ($sizeGB -gt 0) { $freePct = [math]::Round($freeGB/$sizeGB*100,1) }

# ------------------- КОРНЕВЫЕ ФАЙЛЫ -------------------
Write-Step 'Файлы гибернации/подкачки в корне системного диска'
$rootFiles = Get-ChildItem -LiteralPath ($sysDrive + '\') -Force -File | Sort-Object Length -Descending
$hiberFile = $rootFiles | Where-Object { $_.Name -eq 'hiberfil.sys' } | Select-Object -First 1
$memDumpF  = $rootFiles | Where-Object { $_.Name -eq 'MEMORY.DMP' }  | Select-Object -First 1
$pageInfo  = Get-CimInstance Win32_PageFileUsage | Select-Object -First 1

# ------------------- ПАПКИ ВЕРХНЕГО УРОВНЯ + САМЫЕ БОЛЬШИЕ ФАЙЛЫ -------------------
Write-Step ('Сканирую папки верхнего уровня ' + $sysDrive + '\ — самый долгий этап (5-20 мин), не прерывай')
Write-Host '    Заодно собираю все файлы крупнее 500 МБ для отдельного отчёта...' -ForegroundColor DarkGray
$script:BigFiles = New-Object System.Collections.Generic.List[object]
$script:CollectBig = $true
$topDirs = Get-ChildItem -LiteralPath ($sysDrive + '\') -Directory -Force |
    Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) } |
    ForEach-Object {
        Write-Host ('    сканирую: ' + $_.Name) -ForegroundColor DarkGray
        $s = Get-DirSize $_.FullName
        [PSCustomObject]@{ Name=$_.Name; Path=$_.FullName; Bytes=$s; GB=[math]::Round($s/1GB,2) }
    } | Sort-Object GB -Descending
$script:CollectBig = $false
$topDirs = @($topDirs)

$bigTop = @($script:BigFiles |
    Sort-Object Length -Descending |
    Select-Object -First 20 |
    ForEach-Object {
        [PSCustomObject]@{
            Name   = [System.IO.Path]::GetFileName($_.Path)
            Path   = $_.Path
            Length = $_.Length
            GB     = [math]::Round($_.Length/1GB,2)
            Class  = (Get-FileClass $_.Path)
        }
    })

# ------------------- ИЗВЕСТНЫЕ ПОЖИРАТЕЛИ (расширенный список) -------------------
Write-Step 'Проверка известных системных пожирателей места'
$hogDefs = @(
    @{ Title='Кэш Центра обновлений (SoftwareDistribution\Download)'; Path=($sysDrive + '\Windows\SoftwareDistribution\Download') },
    @{ Title='Кэш установщиков MSI (Windows\Installer)';              Path=($winRoot + '\Installer') },
    @{ Title='Временные файлы Windows (Windows\Temp)';                Path=($winRoot + '\Temp') },
    @{ Title='Хвосты обновления Windows ($WinREAgent)';               Path=($sysDrive + '\$WinREAgent') },
    @{ Title='Старая копия Windows (Windows.old)';                    Path=($sysDrive + '\Windows.old') },
    @{ Title='Дистрибутив Windows (ESD)';                             Path=($sysDrive + '\ESD') },
    @{ Title='Логи Windows (Windows\Logs)';                           Path=($winRoot + '\Logs') },
    @{ Title='Prefetch (кэш запуска приложений)';                     Path=($winRoot + '\Prefetch') },
    @{ Title='Delivery Optimization (кэш раздачи обновлений)';        Path=($winRoot + '\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization') },
    @{ Title='Индекс поиска Windows (ProgramData\Microsoft\Search\Data)'; Path=($env:ProgramData + '\Microsoft\Search\Data') },
    @{ Title='Хранилище драйверов (DriverStore\FileRepository)';      Path=($winRoot + '\System32\DriverStore\FileRepository') },
    @{ Title='Package Cache (установщики, служебный)';                Path=($env:ProgramData + '\Package Cache') },
    @{ Title='Отчёты об ошибках Windows (WER)';                       Path=($env:ProgramData + '\Microsoft\Windows\WER') },
    @{ Title='Дампы ядра (LiveKernelReports)';                        Path=($winRoot + '\LiveKernelReports') },
    @{ Title='Мини-дампы BSOD (Minidump)';                            Path=($winRoot + '\Minidump') },
    @{ Title='Временные файлы пользователя (Temp)';                   Path=$env:TEMP },
    @{ Title='Аварийные дампы приложений (CrashDumps)';               Path=($env:LOCALAPPDATA + '\CrashDumps') },
    @{ Title='Корзина системного диска ($Recycle.Bin)';               Path=($sysDrive + '\$Recycle.Bin') }
)
$hogs = foreach ($h in $hogDefs) {
    $bytes = [long]0
    if (Test-Path -LiteralPath $h.Path) {
        $it = Get-Item -LiteralPath $h.Path -Force
        if ($it.PSIsContainer) { $bytes = Get-DirSize $h.Path } else { $bytes = [long]$it.Length }
    }
    [PSCustomObject]@{ Title=$h.Title; Path=$h.Path; Bytes=$bytes; GB=[math]::Round($bytes/1GB,2) }
}
$hogs = @($hogs)

# ------------------- WINSESX / VSS / COMPACT (только админ) -------------------
$winSxsGb = $null; $winSxsRecommended = $false; $winSxsRaw = ''
$vssUsedGb = $null; $vssRaw = ''
$compactOn = $null

if ($isAdmin) {
    Write-Step 'Анализ хранилища компонентов WinSxS через DISM (1-3 мин)'
    $dismOut = (& "$winRoot\System32\Dism.exe" /Online /Cleanup-Image /AnalyzeComponentStore | Out-String)
    $dismOut  = $dismOut -replace '\x08',''
    $winSxsRaw = ($dismOut -split "`r?`n" | Where-Object { $_ -match 'размер|Size|рекоменд|Recommend' }) -join "`r`n"
    $m = [regex]::Match($dismOut, '(?:[Фф]актический размер|[Aa]ctual Size)[^\d]*([\d]+(?:[.,]\d+)?)\s*(ГБ|GB)')
    if ($m.Success) { $winSxsGb = [double]($m.Groups[1].Value -replace ',', '.') }
    $recLine = ($dismOut -split "`r?`n") | Where-Object { $_ -match 'рекоменд|Recommend' } | Select-Object -First 1
    if ($recLine) { $winSxsRecommended = ($recLine -match 'Да|Yes') }

    Write-Step 'Теневые копии / точки восстановления (vssadmin)'
    $vssRaw = (& vssadmin.exe list shadowstorage | Out-String)
    $vssRaw  = $vssRaw -replace '\x08',''
    $m2 = [regex]::Match($vssRaw, '(?:Используемое пространство|Использовано|Used Space)[^\d]*([\d]+(?:[.,]\d+)?)\s*(ГБ|GB)')
    if (-not $m2.Success) {
        $vssLine = ($vssRaw -split "`r?`n") | Where-Object { $_ -match 'пространств|space' -and $_ -match '(ГБ|GB)' } | Select-Object -First 1
        if ($vssLine) { $m2 = [regex]::Match($vssLine, '([\d]+(?:[.,]\d+)?)\s*(ГБ|GB)') }
    }
    if ($m2.Success) { $vssUsedGb = [double]($m2.Groups[1].Value -replace ',', '.') }

    Write-Step 'Проверка сжатия системных файлов (CompactOS)'
    $cq = (& compact.exe /compactos:query | Out-String)
    if ($cq) {
        if ($cq -match 'не находится|is not in') { $compactOn = $false }
        elseif ($cq -match 'находится|is in')    { $compactOn = $true }
    }
}

# ------------------- ДАННЫЕ ПОЛЬЗОВАТЕЛЯ (пропускается в -Quick) -------------------
$profiles = @(); $personal = @(); $localTop = @(); $roamingTop = @(); $docsTop = @()
$browserCache = @(); $devCaches = @(); $vhdxList = @(); $discordVersions = @()
$otherProfilesData = @(); $uwpTop = @()
$odPath = $env:OneDrive
if (-not $odPath) { $odPath = Join-Path $env:USERPROFILE 'OneDrive' }
$odGb = [double]0

if (-not $Quick) {
    Write-Step 'Профили пользователей (C:\Users)'
    $profiles = Get-ChildItem -LiteralPath ($sysDrive + '\Users') -Directory -Force |
        Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) } |
        ForEach-Object {
            $s = Get-DirSize $_.FullName
            [PSCustomObject]@{ Name=$_.Name; GB=[math]::Round($s/1GB,2) }
        } | Sort-Object GB -Descending | Select-Object -First 6
    $profiles = @($profiles)

    Write-Step 'Личные папки и OneDrive текущего пользователя'
    $personal = 'Desktop','Documents','Downloads','Videos','Pictures','Music' | ForEach-Object {
        $p = Join-Path $env:USERPROFILE $_
        $s = Get-DirSize $p
        [PSCustomObject]@{ Folder=$_; GB=[math]::Round($s/1GB,2) }
    }
    if (Test-Path -LiteralPath $odPath) { $odGb = Format-GBn (Get-DirSize $odPath) }

    Write-Step 'AppData текущего пользователя (Local / Roaming)'
    $localTop   = Get-SubdirSizes -Root $env:LOCALAPPDATA -Top 20
    $roamingTop = Get-SubdirSizes -Root $env:APPDATA    -Top 15

    # --- AppData ДРУГИХ профилей (если на машине кто-то ещё работает) ---
    if ($isAdmin -and $profiles.Count -gt 1) {
        Write-Step 'AppData других профилей на этой машине'
        $myDir = $env:USERPROFILE.TrimEnd('\')
        $sysUsers = Join-Path $sysDrive 'Users'
        foreach ($prof in $profiles) {
            if ($prof.Name -in @('Public','Default','Default User','All Users')) { continue }
            $profDir = Join-Path $sysUsers $prof.Name
            if ($profDir -ieq $myDir) { continue }
            if ($prof.GB -lt 1) { continue }
            $la = Join-Path $profDir 'AppData\Local'
            $rm = Join-Path $profDir 'AppData\Roaming'
            $topLocal   = Get-SubdirSizes -Root $la -Top 8
            $topRoaming = Get-SubdirSizes -Root $rm -Top 5
            $otherProfilesData += [PSCustomObject]@{ Profile=$prof.Name; Local=$topLocal; Roaming=$topRoaming }
        }
    }

    Write-Step 'Содержимое папки «Документы»'
    $docsPath = [Environment]::GetFolderPath('MyDocuments')
    if (Test-Path -LiteralPath $docsPath) {
        $docsTop = Get-ChildItem -LiteralPath $docsPath -Force |
            ForEach-Object {
                if ($_.PSIsContainer) { $s = Get-DirSize $_.FullName } else { $s = [long]$_.Length }
                [PSCustomObject]@{ Name=$_.Name; GB=[math]::Round($s/1GB,2) }
            } | Sort-Object GB -Descending | Select-Object -First 15
        $docsTop = @($docsTop)
    }

    Write-Step 'Кэши браузеров (Chrome/Edge/Yandex/Firefox/Brave/Vivaldi/Opera)'
    $browserRoots = @(
        @{ Name='Google Chrome';   Root=($env:LOCALAPPDATA + '\Google\Chrome\User Data') },
        @{ Name='Microsoft Edge';  Root=($env:LOCALAPPDATA + '\Microsoft\Edge\User Data') },
        @{ Name='Яндекс.Браузер';  Root=($env:LOCALAPPDATA + '\Yandex\YandexBrowser\User Data') },
        @{ Name='Mozilla Firefox'; Root=($env:LOCALAPPDATA + '\Mozilla\Firefox\Profiles') },
        @{ Name='Brave';           Root=($env:LOCALAPPDATA + '\BraveSoftware\Brave-Browser\User Data') },
        @{ Name='Vivaldi';         Root=($env:LOCALAPPDATA + '\Vivaldi\User Data') },
        @{ Name='Opera';           Root=($env:LOCALAPPDATA + '\Opera Software\Opera Stable') }
    )
    $cacheDirNames = @('Cache','Code Cache','GPUCache','cache2','Service Worker')
    $browserCache = foreach ($b in $browserRoots) {
        if (Test-Path -LiteralPath $b.Root) {
            $cDirs = Get-ChildItem -LiteralPath $b.Root -Recurse -Depth 3 -Directory -Force |
                     Where-Object { $cacheDirNames -contains $_.Name }
            $bytes = [long]0
            foreach ($d in $cDirs) { $bytes += Get-DirSize $d.FullName }
            if ($bytes -gt 0) { [PSCustomObject]@{ Browser=$b.Name; Bytes=$bytes; GB=[math]::Round($bytes/1GB,2) } }
        }
    }
    $browserCache = @($browserCache)

    Write-Step 'Кэши разработчика, GPU и приложений (pip/npm/uv/NVIDIA/Steam...)'
    $devCaches = @(
        @{ Tool='pip';                Path=($env:LOCALAPPDATA + '\pip\cache');      Cmd='pip cache purge';          Advice='Кэш пакетов pip — пакеты перекачаются при следующей установке' },
        @{ Tool='npm';                Path=($env:LOCALAPPDATA + '\npm-cache');      Cmd='npm cache clean --force';  Advice='Кэш npm — пересоздастся сам' },
        @{ Tool='uv';                 Path=($env:LOCALAPPDATA + '\uv');             Cmd='uv cache clean';           Advice='Кэш uv — пересоздастся сам' },
        @{ Tool='yarn';               Path=($env:LOCALAPPDATA + '\Yarn\Cache');     Cmd='yarn cache clean';         Advice='Кэш yarn — пересоздастся сам' },
        @{ Tool='nuget';              Path=($env:USERPROFILE + '\.nuget\packages'); Cmd='dotnet nuget locals all --clear'; Advice='Пакеты NuGet — восстановятся при сборке' },
        @{ Tool='NVIDIA DXCache';     Path=($env:LOCALAPPDATA + '\NVIDIA\DXCache'); Cmd=('Remove-Item -LiteralPath "' + $env:LOCALAPPDATA + '\NVIDIA\DXCache\*" -Recurse -Force -ErrorAction SilentlyContinue'); Advice='Кэш шейдеров NVIDIA — игры пересоздадут, ничего не сломается' },
        @{ Tool='NVIDIA GLCache';     Path=($env:LOCALAPPDATA + '\NVIDIA\GLCache'); Cmd=('Remove-Item -LiteralPath "' + $env:LOCALAPPDATA + '\NVIDIA\GLCache\*" -Recurse -Force -ErrorAction SilentlyContinue'); Advice='Кэш шейдеров NVIDIA (OpenGL)' },
        @{ Tool='AMD DxCache';        Path=($env:LOCALAPPDATA + '\AMD\DxCache');    Cmd=('Remove-Item -LiteralPath "' + $env:LOCALAPPDATA + '\AMD\DxCache\*" -Recurse -Force -ErrorAction SilentlyContinue'); Advice='Кэш шейдеров AMD — игры пересоздадут' },
        @{ Tool='D3DSCache';          Path=($env:LOCALAPPDATA + '\D3DSCache');      Cmd=('Remove-Item -LiteralPath "' + $env:LOCALAPPDATA + '\D3DSCache\*" -Recurse -Force -ErrorAction SilentlyContinue'); Advice='Системный кэш DirectX — пересоздастся сам' },
        @{ Tool='INetCache (легаси)'; Path=($env:LOCALAPPDATA + '\Microsoft\Windows\INetCache'); Cmd=('Remove-Item -LiteralPath "' + $env:LOCALAPPDATA + '\Microsoft\Windows\INetCache\*" -Recurse -Force -ErrorAction SilentlyContinue'); Advice='Устаревший кэш IE/системы — можно чистить, занятое пропустится' },
        @{ Tool='Steam htmlcache';    Path=($env:LOCALAPPDATA + '\Steam\htmlcache'); Cmd=('Remove-Item -LiteralPath "' + $env:LOCALAPPDATA + '\Steam\htmlcache\*" -Recurse -Force -ErrorAction SilentlyContinue'); Advice='Кэш встроенного браузера Steam — закрой Steam перед чисткой' },
        @{ Tool='Epic webcache';      Path=($env:LOCALAPPDATA + '\EpicGamesLauncher\Saved\webcache'); Cmd=('Remove-Item -LiteralPath "' + $env:LOCALAPPDATA + '\EpicGamesLauncher\Saved\webcache\*" -Recurse -Force -ErrorAction SilentlyContinue'); Advice='Кэш лаунчера Epic — закрой лаунчер перед чисткой' },
        @{ Tool='Кэш миниатюр';       Path=($env:LOCALAPPDATA + '\Microsoft\Windows\Explorer'); Cmd=''; Advice='Файлы thumbcache_*.db. Чистится через cleanmgr («Эскизы») или после перезапуска explorer.exe' }
    ) | ForEach-Object {
        if (Test-Path -LiteralPath $_.Path) {
            $s = Get-DirSize $_.Path
            if ($s -gt 200MB) { [PSCustomObject]@{ Tool=$_.Tool; Path=$_.Path; GB=[math]::Round($s/1GB,2); Cmd=$_.Cmd; Advice=$_.Advice } }
        }
    }
    $devCaches = @($devCaches)

    # --- Приложения Microsoft Store (UWP) ---
    if ($isAdmin) {
        Write-Step 'Приложения Microsoft Store (UWP) — может занять пару минут'
        $seen = @{}
        $uwpRaw = foreach ($pk in (Get-AppxPackage)) {
            $loc = $pk.InstallLocation
            if ($loc -and $loc.StartsWith($sysDrive) -and -not $seen.ContainsKey($loc)) {
                $seen[$loc] = $true
                $s = Get-DirSize $loc
                [PSCustomObject]@{ Name=$pk.Name; FullName=$pk.PackageFullName; GB=[math]::Round($s/1GB,2) }
            }
        }
        $uwpTop = @($uwpRaw | Where-Object { $_.GB -ge 0.1 } | Sort-Object GB -Descending | Select-Object -First 12)
    }

    Write-Step 'Образы WSL/Docker (.vhdx)'
    $vhdxRoots = @(
        ($env:LOCALAPPDATA + '\Packages'),
        ($env:LOCALAPPDATA + '\Docker'),
        ($env:LOCALAPPDATA + '\wsl'),
        ($env:ProgramData + '\DockerDesktop')
    )
    $vhdxList = foreach ($r in $vhdxRoots) {
        if (Test-Path -LiteralPath $r) {
            Get-ChildItem -LiteralPath $r -Recurse -Depth 4 -Filter '*.vhdx' -Force | ForEach-Object {
                [PSCustomObject]@{ Path=$_.FullName; GB=[math]::Round($_.Length/1GB,2) }
            }
        }
    }
    $vhdxList = @($vhdxList | Sort-Object GB -Descending)

    Write-Step 'Накопившиеся версии Discord'
    $dDir = $env:LOCALAPPDATA + '\Discord'
    if (Test-Path -LiteralPath $dDir) {
        $discordVersions = Get-ChildItem -LiteralPath $dDir -Directory -Force |
            Where-Object { $_.Name -like 'app-*' } | ForEach-Object {
                $s = Get-DirSize $_.FullName
                $v = $null
                try { $v = [version]$_.Name.Substring(4) } catch { $v = [version]'0.0' }
                [PSCustomObject]@{ Name=$_.Name; Path=$_.FullName; GB=[math]::Round($s/1GB,2); Ver=$v }
            }
    }
    $discordVersions = @($discordVersions)
}

# ------------------- УСТАНОВЛЕННЫЕ ПРОГРАММЫ -------------------
Write-Step 'Реестр установленных программ'
$programs = Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                             'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                             'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' |
    Where-Object { $_.DisplayName } | ForEach-Object {
        $loc = $_.InstallLocation
        $onSys = $false
        if ($loc) { $onSys = ($loc -replace '/','\').ToUpper().StartsWith($sysDrive.ToUpper()) }
        [PSCustomObject]@{
            Name  = $_.DisplayName
            Ver   = $_.DisplayVersion
            MB    = [math]::Round($_.EstimatedSize/1KB,0)
            OnSys = $onSys
            Loc   = $loc
        }
    } | Where-Object { $_.MB -gt 0 } | Sort-Object MB -Descending | Select-Object -First 30
$programs = @($programs)

# ------------------- ДВИЖОК РЕКОМЕНДАЦИЙ -------------------
Write-Step 'Формирование плана действий'

function Add-Rec {
    param([double]$Gb, [string]$Risk, [string]$Target, [string]$What, [string]$Cmd)
    $Recs.Add([PSCustomObject]@{ Gb=$Gb; Risk=$Risk; Target=$Target; What=$What; Cmd=$Cmd })
}

# 1. Файл гибернации
if ($hiberFile -and $hiberFile.Length -gt 1GB) {
    $gb = Format-GBn $hiberFile.Length
    if ($isLaptop) {
        Add-Rec $gb $R_GREEN 'hiberfil.sys — файл гибернации' 'Ноутбук: команда ужмёт файл примерно вдвое, быстрый запуск сохранится. Если гибернацией не пользуешься совсем — powercfg /h off' 'powercfg /h /type reduced'
    } else {
        Add-Rec $gb $R_GREEN 'hiberfil.sys — файл гибернации' 'Отключает гибернацию и быстрый запуск, файл исчезнет после перезагрузки' 'powercfg /h off'
    }
}

# 2. Файл подкачки — информационный запрет
if ($pageInfo -and $pageInfo.Name) {
    if ($pageInfo.Name.ToUpper().StartsWith($sysDrive.ToUpper())) {
        Add-Rec (Format-GBn ($pageInfo.AllocatedBaseSize*1MB)) $R_RED 'pagefile.sys — файл подкачки' 'НЕ УДАЛЯТЬ. Система без него нестабильна. Уменьшать/переносить только осознанно' ''
    }
}

# 3. Кэш Центра обновлений
$hog = $hogs | Where-Object { $_.Title -like '*SoftwareDistribution*' } | Select-Object -First 1
if ($hog -and $hog.Bytes -gt 1GB) {
    Add-Rec (Format-GBn $hog.Bytes) $R_GREEN 'Кэш Центра обновлений Windows' 'Службы обновления останавливаются, кэш сносится, службы запускаются обратно. При необходимости файлы докачаются заново' ("Stop-Service wuauserv,bits -Force`r`nRemove-Item -Path '" + $sysDrive + "\Windows\SoftwareDistribution\Download\*' -Recurse -Force`r`nStart-Service wuauserv,bits")
}

# 4. Хвосты обновления $WinREAgent
$hog = $hogs | Where-Object { $_.Title -like '*WinREAgent*' } | Select-Object -First 1
if ($hog -and $hog.Bytes -gt 500MB) {
    Add-Rec (Format-GBn $hog.Bytes) $R_GREEN 'Хвосты обновления Windows ($WinREAgent)' 'Временные данные последнего обновления. Удаляй, если после обновления всё работает стабильно' ("Remove-Item -LiteralPath '" + $sysDrive + "\`$WinREAgent' -Recurse -Force")
}

# 5. Windows.old
$hog = $hogs | Where-Object { $_.Title -like '*Windows.old*' } | Select-Object -First 1
if ($hog -and $hog.Bytes -gt 500MB) {
    Add-Rec (Format-GBn $hog.Bytes) $R_GREEN 'Windows.old — старая копия Windows' 'Очистка через штатный cleanmgr: запусти команду, отметь «Предыдущие установки Windows» и «Очистка файлов обновлений»' ('cleanmgr /d ' + $sysDrive)
}

# 6. Windows\Temp
$hog = $hogs | Where-Object { $_.Title -like '*Windows\Temp*' } | Select-Object -First 1
if ($hog -and $hog.Bytes -gt 500MB) {
    Add-Rec (Format-GBn $hog.Bytes) $R_GREEN 'Windows\Temp' 'Системные временные файлы. Занятые файлы пропустятся сами' ('Remove-Item -Path "' + $winRoot + '\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue')
}

# 7. Temp пользователя
$hog = $hogs | Where-Object { $_.Title -like 'Временные файлы пользователя*' } | Select-Object -First 1
if ($hog -and $hog.Bytes -gt 500MB) {
    Add-Rec (Format-GBn $hog.Bytes) $R_GREEN 'Temp пользователя' 'Временные файлы приложений. Занятые пропустятся' 'Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue'
}

# 8. Корзина
$hog = $hogs | Where-Object { $_.Title -like '*Recycle*' } | Select-Object -First 1
if ($hog -and $hog.Bytes -gt 500MB) {
    Add-Rec (Format-GBn $hog.Bytes) $R_GREEN 'Корзина' 'Штатная очистка корзины системного диска' ('Clear-RecycleBin -DriveLetter ' + $sysDrive.TrimEnd(':') + ' -Force')
}

# 9. Дампы
$hog = $hogs | Where-Object { $_.Title -like '*CrashDumps*' } | Select-Object -First 1
if ($hog -and $hog.Bytes -gt 300MB) {
    Add-Rec (Format-GBn $hog.Bytes) $R_GREEN 'Аварийные дампы приложений' 'Дампы упавших программ — можно сносить' 'Remove-Item -Path "$env:LOCALAPPDATA\CrashDumps\*" -Recurse -Force'
}
$hog = $hogs | Where-Object { $_.Title -like '*WER*' } | Select-Object -First 1
if ($hog -and $hog.Bytes -gt 300MB) {
    Add-Rec (Format-GBn $hog.Bytes) $R_GREEN 'Отчёты об ошибках Windows (WER)' 'Очередь отчётов об ошибках — можно сносить' 'Remove-Item -Path "$env:ProgramData\Microsoft\Windows\WER\ReportQueue\*","$env:ProgramData\Microsoft\Windows\WER\ReportArchive\*" -Recurse -Force'
}
if ($memDumpF -and $memDumpF.Length -gt 1GB) {
    Add-Rec (Format-GBn $memDumpF.Length) $R_GREEN 'Полный дамп памяти MEMORY.DMP' 'Дамп памяти после сбоя — можно удалить' ('Remove-Item -LiteralPath "' + $memDumpF.FullName + '" -Force')
}

# 10. Теневые копии
if ($vssUsedGb -and $vssUsedGb -ge 4) {
    Add-Rec $vssUsedGb $R_YELLOW 'Теневые копии (точки восстановления)' 'Ограничивает хранилище теневых копий 4 ГБ: старые точки будут удаляться. После чистки создай свежую точку восстановления' ('vssadmin resize shadowstorage /for=' + $sysDrive + ' /on=' + $sysDrive + ' /maxsize=4GB')
}

# 11. WinSxS
if ( ($winSxsGb -and $winSxsGb -ge 12) -or $winSxsRecommended ) {
    $gb = [double]0
    if ($winSxsGb) { $gb = $winSxsGb }
    Add-Rec $gb $R_YELLOW 'Хранилище компонентов WinSxS' 'Штатная чистка DISM удаляет устаревшие версии компонентов (5-15 мин). Вариант с /ResetBase вычищает ещё больше, но после него нельзя откатывать уже установленные обновления' 'Dism.exe /Online /Cleanup-Image /StartComponentCleanup'
}

# 12. CompactOS
if ( ($compactOn -eq $false) -and ($freePct -lt 15) ) {
    $winBytes = ($topDirs | Where-Object { $_.Name -eq 'Windows' } | Select-Object -First 1).Bytes
    if ($winBytes -gt 20GB) {
        Add-Rec 3.0 $R_YELLOW 'Сжатие системных файлов (CompactOS)' 'Сжимает бинарники Windows: ~2-4 ГБ выгоды почти без потери скорости' 'compact /compactos:always'
    }
}

# 13. Браузерные кэши
$bcTotal = [long]0
if ($browserCache) { $bcTotal = ($browserCache | Measure-Object Bytes -Sum).Sum }
if ($bcTotal -gt 1GB) {
    Add-Rec (Format-GBn $bcTotal) $R_GREEN 'Кэши браузеров' 'Чистится из настроек браузера: Ctrl+Shift+Del → «Изображения и файлы кэша». Через сам браузер безопаснее, чем удалять папки' ''
}

# 14. Кэши разработчика, GPU и приложений
foreach ($dc in $devCaches) {
    if ($dc.GB -ge 0.2) { Add-Rec $dc.GB $R_GREEN ('Кэш: ' + $dc.Tool) $dc.Advice $dc.Cmd }
}

# 15. Старые версии Discord
$dvSorted = @($discordVersions | Sort-Object Ver -Descending)
if ($dvSorted.Count -ge 2) {
    $old = @($dvSorted | Select-Object -Skip 1)
    $oldGb = [math]::Round((($old | Measure-Object GB -Sum).Sum),2)
    if ($oldGb -ge 0.3) {
        $pathsLit = ($old | ForEach-Object { "'" + $_.Path + "'" }) -join ','
        Add-Rec $oldGb $R_GREEN 'Discord: старые версии клиента' 'Полностью закрой Discord (включая трей), затем команда удалит старые app-* папки. Новейшая версия остаётся' ('Remove-Item -LiteralPath @(' + $pathsLit + ') -Recurse -Force')
    }
}

# 16. CapCut
$cap = $localTop | Where-Object { $_.Name -eq 'CapCut' } | Select-Object -First 1
if ($cap -and $cap.GB -ge 1) {
    Add-Rec $cap.GB $R_YELLOW 'CapCut (AppData\Local)' 'Внутри кэш и ЧЕРНОВИКИ ПРОЕКТОВ. Сначала перенеси кэш/черновики на несистемный диск в настройках CapCut, затем чисти кэш средствами приложения' ''
}

# 17. Крупные личные папки
foreach ($p in $personal) {
    if ($p.GB -ge 5) {
        Add-Rec $p.GB $R_YELLOW ('Личная папка: ' + $p.Folder) 'Разбери содержимое, крупное перенеси на несистемный диск. Перенос папки целиком — robocopy + junction (шаблон в разделе «Профилактика»)' ''
    }
}

# 18. Большой OneDrive
if ($odGb -ge 5) {
    Add-Rec $odGb $R_GREEN 'OneDrive' 'Включи «Файлы по запросу» (Files On-Demand) и освободи место командой attrib +U -P /s для папки OneDrive — файлы останутся в облаке, с диска уйдут локальные копии' ''
}

# 19. Мало места — Storage Sense
if ($freePct -lt 10) {
    Add-Rec 0 $R_GREEN 'Автоочистка на будущее (Storage Sense)' 'Включает автоматическую очистку временных файлов и корзины, чтобы диск снова не забивался' "Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' -Name 01 -Value 1"
}

# 20. Логи Windows
$hog = $hogs | Where-Object { $_.Title -like 'Логи Windows*' } | Select-Object -First 1
if ($hog -and $hog.Bytes -gt 1GB) {
    Add-Rec (Format-GBn $hog.Bytes) $R_GREEN 'Логи Windows (Windows\Logs)' 'Старые журналы (CBS, DISM и т.д.). Занятые системой файлы пропустятся сами' ('Remove-Item -Path "' + $winRoot + '\Logs\*" -Recurse -Force -ErrorAction SilentlyContinue')
}

# 21. Дистрибутив Windows (ESD)
$hog = $hogs | Where-Object { $_.Title -like '*ESD*' } | Select-Object -First 1
if ($hog -and $hog.Bytes -gt 500MB) {
    Add-Rec (Format-GBn $hog.Bytes) $R_YELLOW 'C:\ESD — файлы дистрибутива Windows' 'Нужны только если планируешь восстановление/сброс Windows с этого диска. Если система стабильна — можно удалить' ('Remove-Item -LiteralPath "' + $sysDrive + '\ESD\*" -Recurse -Force -ErrorAction SilentlyContinue')
}

# 22. Delivery Optimization
$hog = $hogs | Where-Object { $_.Title -like '*DeliveryOptimization*' } | Select-Object -First 1
if ($hog -and $hog.Bytes -gt 500MB) {
    Add-Rec (Format-GBn $hog.Bytes) $R_GREEN 'Кэш Delivery Optimization' 'Обрывки обновлений Windows, которыми система делится с другими ПК по сети. Полностью безопасно чистить штатным командлетом' 'Delete-DeliveryOptimizationCache -Force'
}

# 23. Индекс поиска Windows
$hog = $hogs | Where-Object { $_.Title -like '*Индекс поиска*' } | Select-Object -First 1
if ($hog -and $hog.Bytes -gt 1GB) {
    Add-Rec (Format-GBn $hog.Bytes) $R_YELLOW 'Индекс поиска Windows' 'Руками не удалять при работающей службе. Перестрой индекс: Параметры → Поиск в Windows → Дополнительно → Перестроить (индекс соберётся заново, меньше и свежее)' ''
}

# 24. DriverStore
$hog = $hogs | Where-Object { $_.Title -like '*DriverStore*' } | Select-Object -First 1
if ($hog -and $hog.Bytes -gt 15GB) {
    Add-Rec (Format-GBn $hog.Bytes) $R_YELLOW 'DriverStore — хранилище драйверов' 'Копит старые версии драйверов (чаще всего видеодрайверы). Сначала посмотри список командой ниже; старые дубли пакетов удаляются через pnputil /delete-driver oemXX.inf (проверяй, что удаляешь старую версию). Саму папку руками НЕ чистить' 'pnputil /enum-drivers'
}

# 25. Гигантские одиночные файлы (дампы/логи/временные/образы)
$bigRecs = 0
foreach ($bf in $bigTop) {
    if ($bigRecs -ge 3) { break }
    if ($bf.GB -lt 1) { continue }
    if ($bf.Class -in @('Дамп','Лог','Временный')) {
        Add-Rec $bf.GB $R_GREEN ('Большой файл: ' + $bf.Name) ('Класс: ' + $bf.Class + '. Путь: ' + $bf.Path + ' — убедись, что файл не нужен, и удали') ('Remove-Item -LiteralPath "' + $bf.Path + '" -Force')
        $bigRecs++
    } elseif ($bf.Class -eq 'Образ диска') {
        Add-Rec $bf.GB $R_YELLOW ('Большой файл: ' + $bf.Name) ('Класс: образ диска. Путь: ' + $bf.Path + ' — если образ уже не нужен (распакован/записан), можно удалить') ('Remove-Item -LiteralPath "' + $bf.Path + '" -Force')
        $bigRecs++
    }
}

$recsSorted = @($Recs | Sort-Object Gb -Descending)
$potentialGb = [double]0
$potSum = ($recsSorted | Where-Object { $_.Risk -ne $R_RED } | Measure-Object Gb -Sum).Sum
if ($potSum) { $potentialGb = [math]::Round($potSum,1) }

# Сохраняем план для режима -Fix и для повторного запуска
$planPath = Join-Path $OutputDir 'DiskHealth_Plan.json'
$recsSorted | Select-Object Gb, Risk, Target, What, Cmd | ConvertTo-Json -Depth 3 | Out-File -LiteralPath $planPath -Encoding UTF8

# ------------------- ГЕНЕРАЦИЯ ОТЧЁТА (часть 1) -------------------
Write-Step 'Генерация отчёта'
$now = Get-Date
if (-not (Test-Path -LiteralPath $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
$reportPath = Join-Path $OutputDir ('DiskHealth_Report_' + $now.ToString('yyyyMMdd_HHmmss') + '.md')

$modeStr = 'полный'; if ($Quick) { $modeStr = 'быстрый' }
$adminStr = 'администратор'; if (-not $isAdmin) { $adminStr = 'БЕЗ админ-прав (DISM/VSS/UWP пропущены)' }

Add-Md @(
'# 🩺 DiskHealth — отчёт о состоянии системного диска',
'',
('> **Дата:** ' + $now.ToString('yyyy-MM-dd HH:mm') + ' | **Скрипт:** DiskHealth.ps1 v' + $Version),
('> **Компьютер:** ' + $env:COMPUTERNAME + ' / ' + $env:USERNAME + ' | **ОС:** ' + $os.Caption + ' | **RAM:** ' + $ramGb + ' ГБ'),
('> **Режим:** ' + $modeStr + ' | **Права:** ' + $adminStr),
'',
'Анализ ничего не удалял — это только диагностика. Отчёт и план (DiskHealth_Plan.json) лежат рядом со скриптом.',
'Выполнить шаги плана с подтверждением каждого: `powershell -File .\DiskHealth.ps1 -Fix` или пункт [1] в меню скрипта.',
'',
'---',
'',
'## 📊 Сводка по томам',
'',
'| Диск | Метка | Размер, ГБ | Свободно, ГБ | Примечание |',
'|---|---|---|---|---|'
)
foreach ($v in $volumes) {
    $note = ''
    if ($v.IsSys) { $note = '⬅ системный' }
    if ($v.IsSys -and $v.SizeGB -gt 0 -and ($v.FreeGB/$v.SizeGB) -lt 0.10) { $note = $note + ' ⚠️ критически мало места' }
    Add-Md ('| ' + $v.Letter + ' | ' + (Esc-md $v.Label) + ' | ' + $v.SizeGB + ' | ' + $v.FreeGB + ' | ' + $note + ' |')
}
Add-Md @(
'',
('**Системный диск ' + $sysDrive + ':** занято ' + ($sizeGB - $freeGB) + ' из ' + $sizeGB + ' ГБ, свободно **' + $freeGB + ' ГБ (' + $freePct + '%)**.'),
('**Потенциально можно освободить (по зелёным и жёлтым пунктам плана): ~' + $potentialGb + ' ГБ.**'),
'',
('Легенда: ' + $R_GREEN + ' — можно делать смело; ' + $R_YELLOW + ' — сначала прочитай комментарий; ' + $R_RED + ' — системно важно, руками не трогать.'),
'',
'---',
'',
'## 🚑 План действий (по убыванию выгоды)',
'',
'Выполняй шаги по одному. После каждого шага проверяй свободное место: `Get-Volume ' + $sysDrive + '`',
'Скрипт умеет выполнять план сам (с подтверждением каждого шага): `powershell -File .\DiskHealth.ps1 -Fix`',
'',
'| # | Цель | Размер, ГБ | Критичность | Что делать |',
'|---|---|---|---|---|'
)
$i = 0
foreach ($r in $recsSorted) {
    $i++
    Add-Md ('| ' + $i + ' | ' + (Esc-md $r.Target) + ' | ' + $r.Gb + ' | ' + $r.Risk + ' | ' + (Esc-md $r.What) + ' |')
}
Add-Md ''
$i = 0
foreach ($r in $recsSorted) {
    if ($r.Cmd) {
        $i++
        Add-Md @(
('**Шаг ' + $i + ': ' + $r.Target + '**'),
'',
'```powershell',
$r.Cmd,
'```',
'')
    }
}

Add-Md @(
'---',
'',
('## 🗂 Большие директории на ' + $sysDrive + '\'),
'',
'| Папка | Размер | % диска | Категория | Критичность удаления | Комментарий |',
'|---|---|---|---|---|---|'
)
foreach ($d in ($topDirs | Where-Object { $_.GB -ge 0.5 })) {
    $info = Get-TopDirInfo $d.Name
    $pct = 0
    if ($sizeGB -gt 0) { $pct = [math]::Round($d.Bytes/1GB/$sizeGB*100,1) }
    Add-Md ('| ' + $d.Name + ' | ' + $d.GB + ' ГБ | ' + $pct + '% | ' + $info[0] + ' | ' + $info[1] + ' | ' + $info[2] + ' |')
}

if ($bigTop.Count -gt 0) {
    Add-Md @('','### 🐘 Самые большие файлы (топ-20, от 500 МБ)','',
    'Проверь по одному: часто среди них очевидный мусор (образы, старые архивы, дампы).','',
    '| Файл | Размер | Класс | Полный путь |','|---|---|---|---|')
    foreach ($bf in $bigTop) {
        $p = $bf.Path
        if ($p.Length -gt 100) { $p = $p.Substring(0,100) + '…' }
        Add-Md ('| ' + (Esc-md $bf.Name) + ' | ' + $bf.GB + ' ГБ | ' + $bf.Class + ' | ' + (Esc-md $p) + ' |')
    }
}

if (-not $Quick) {
    Add-Md @('','---','','## 👤 Профили пользователей (C:\Users)','',
    '| Профиль | Размер |','|---|---|')
    foreach ($p in $profiles) { Add-Md ('| ' + $p.Name + ' | ' + $p.GB + ' ГБ |') }

    Add-Md @('','### Личные папки','',
    '| Папка | Размер |','|---|---|')
    foreach ($p in $personal) { Add-Md ('| ' + $p.Folder + ' | ' + $p.GB + ' ГБ |') }
    if ($odGb -gt 0) { Add-Md ('| OneDrive (' + $odPath + ') | ' + $odGb + ' ГБ |') }

    if ($otherProfilesData.Count -gt 0) {
        Add-Md @('','### AppData других профилей','')
        foreach ($op in $otherProfilesData) {
            Add-Md @('',('**Профиль: ' + $op.Profile + '**'),'',
            '| Папка | Размер |','|---|---|')
            foreach ($d in ($op.Local | Select-Object -First 8)) {
                if ($d.GB -lt 0.05) { continue }
                Add-Md ('| Local\' + $d.Name + ' | ' + $d.GB + ' ГБ |')
            }
            foreach ($d in ($op.Roaming | Select-Object -First 5)) {
                if ($d.GB -lt 0.05) { continue }
                Add-Md ('| Roaming\' + $d.Name + ' | ' + $d.GB + ' ГБ |')
            }
        }
    }

    Add-Md @('','### AppData\Local текущего пользователя (топ-20)','',
    '| Папка | Размер | Комментарий |','|---|---|---|')
    foreach ($d in $localTop) {
        if ($d.GB -lt 0.05) { continue }
        Add-Md ('| ' + $d.Name + ' | ' + $d.GB + ' ГБ | ' + (Get-AppDataAdvice $d.Name) + ' |')
    }

    Add-Md @('','### AppData\Roaming текущего пользователя (топ-15)','',
    '| Папка | Размер | Комментарий |','|---|---|---|')
    foreach ($d in $roamingTop) {
        if ($d.GB -lt 0.05) { continue }
        Add-Md ('| ' + $d.Name + ' | ' + $d.GB + ' ГБ | ' + (Get-AppDataAdvice $d.Name) + ' |')
    }

    Add-Md @('','### Внутри «Документы» (топ-15)','',
    '| Объект | Размер |','|---|---|')
    foreach ($d in $docsTop) { Add-Md ('| ' + $d.Name + ' | ' + $d.GB + ' ГБ |') }
}

# ------------------- ГЕНЕРАЦИЯ ОТЧЁТА (часть 2) -------------------
Add-Md @('','---','','## 🧱 Системные потребители места','',
'| Что | Размер | Как чистить |','|---|---|---|')
$hiberStr = '—'
if ($hiberFile) { $hiberStr = Format-GBs $hiberFile.Length }
Add-Md ('| Файл гибернации hiberfil.sys | ' + $hiberStr + ' | ' + $R_GREEN + ' powercfg /h off (или /type reduced на ноутбуке) |')
$pgStr = '—'
if ($pageInfo -and $pageInfo.Name) {
    $pgStr = [math]::Round($pageInfo.AllocatedBaseSize/1KB,2).ToString() + ' ГБ (на ' + $pageInfo.Name + ')'
}
Add-Md ('| Файл подкачки pagefile | ' + $pgStr + ' | ' + $R_RED + ' руками не трогать |')
if ($winSxsGb) {
    Add-Md ('| Хранилище компонентов WinSxS (фактический размер) | ' + $winSxsGb + ' ГБ | ' + $R_YELLOW + ' Dism /StartComponentCleanup |')
} else {
    Add-Md ('| Хранилище компонентов WinSxS | н/д | ' + $R_YELLOW + ' нужен запуск от администратора |')
}
if ($null -ne $vssUsedGb) {
    Add-Md ('| Теневые копии (vssadmin) | ' + $vssUsedGb + ' ГБ | ' + $R_YELLOW + ' vssadmin resize shadowstorage /maxsize=4GB |')
}
foreach ($h in $hogs) { Add-Md ('| ' + $h.Title + ' | ' + $h.GB + ' ГБ | ' + $R_GREEN + ' см. план действий |') }
if ($memDumpF) { Add-Md ('| Полный дамп памяти MEMORY.DMP | ' + (Format-GBs $memDumpF.Length) + ' | ' + $R_GREEN + ' можно удалить файл |') }

Add-Md @('','---','','## 🧰 Крупнейшие установленные программы (топ-30 по размеру)','',
('Программы с отметкой «да» в колонке «На ' + $sysDrive + '» занимают системный диск. Удалять только через «Параметры → Приложения».'),'',
('| Программа | Версия | Размер, МБ | На ' + $sysDrive + ' | Путь |'),'|---|---|---|---|---|')
foreach ($p in $programs) {
    $flag = 'нет'; if ($p.OnSys) { $flag = 'да' }
    $loc = ''; if ($p.Loc) { $loc = $p.Loc }
    if ($loc.Length -gt 60) { $loc = $loc.Substring(0,60) + '…' }
    Add-Md ('| ' + (Esc-md $p.Name) + ' | ' + $p.Ver + ' | ' + $p.MB + ' | ' + $flag + ' | ' + (Esc-md $loc) + ' |')
}

if (-not $Quick) {
    Add-Md @('','---','','## 🛍 Приложения Microsoft Store (UWP, топ-12)','',
    'Удалять только через «Параметры → Приложения» или командой `Get-AppxPackage <имя> | Remove-AppxPackage`. Руками папки в `WindowsApps` не трогать.','',
    '| Пакет | Размер |','|---|---|')
    if ($uwpTop.Count -gt 0) {
        foreach ($u in $uwpTop) { Add-Md ('| ' + (Esc-md $u.Name) + ' | ' + $u.GB + ' ГБ |') }
    } else {
        Add-Md 'Крупных UWP-приложений не найдено (или нет прав администратора).'
    }
}

Add-Md @('','---','','## 💽 Образы WSL/Docker (.vhdx)','')
if ($vhdxList.Count -gt 0) {
    Add-Md @('| Файл | Размер |','|---|---|')
    foreach ($v in $vhdxList) { Add-Md ('| ' + (Esc-md $v.Path) + ' | ' + $v.GB + ' ГБ |') }
    Add-Md @('',
    'Если образ огромный: для Docker — сначала `docker system prune -a` внутри контейнеров, затем `wsl --shutdown` и сжатие образа; для WSL — `wsl --export` / `--import` на другой диск или `Optimize-VHD` (Hyper-V). Руками удалять `.vhdx` НЕЛЬЗЯ — это весь диск виртуальной машины.')
} else {
    Add-Md 'Образы WSL/Docker не найдены (или режим -Quick).'
}

Add-Md @('','---','','## 🌐 Кэши браузеров и разработчика','')
if ($browserCache.Count -gt 0) {
    Add-Md @('| Браузер | Объём кэша |','|---|---|')
    foreach ($b in $browserCache) { Add-Md ('| ' + $b.Browser + ' | ' + $b.GB + ' ГБ |') }
} else {
    Add-Md 'Браузерные кэши не найдены (или режим -Quick).'
}
if ($devCaches.Count -gt 0) {
    Add-Md @('','| Что | Объём | Комментарий | Команда очистки |','|---|---|---|---|')
    foreach ($d in $devCaches) {
        $cmdTxt = '—'
        if ($d.Cmd) { $cmdTxt = '`' + $d.Cmd + '`' }
        Add-Md ('| ' + $d.Tool + ' | ' + $d.GB + ' ГБ | ' + $d.Advice + ' | ' + $cmdTxt + ' |')
    }
}

if ($isAdmin) {
    Add-Md @('','---','','## 📎 Сырой вывод DISM и vssadmin (для сверки)','',
    '```text',
    $winSxsRaw,
    '',
    '--- vssadmin ---',
    $vssRaw,
    '```')
}

Add-Md @('','---','','## ⛔ Чего делать НЕЛЬЗЯ','',
'- ❌ Удалять вручную содержимое `C:\Windows` (включая `WinSxS`, `Installer`, `DriverStore`) — только штатные очистки (DISM, cleanmgr, pnputil).',
'- ❌ Удалять `pagefile.sys`, `swapfile.sys`, `hiberfil.sys` руками — только через powercfg/настройки системы.',
'- ❌ Сносить папки из `AppData\Local\Packages` и `C:\Program Files\WindowsApps` — это данные приложений из Microsoft Store.',
'- ❌ Чистить `ProgramData\Package Cache` — сломаются восстановление и обновление программ.',
'- ❌ Удалять `.vhdx` образы WSL/Docker — это диски виртуальных машин.',
'- ❌ Удалять junction-ссылки через проводник или `Remove-Item -Recurse` в PowerShell 5.1 — можно вынести ЦЕЛЕВУЮ папку. Ссылка снимается командой `cmd /c rmdir "C:\путь\к\ссылке"` (без /S).',
'- ❌ Чистить папку `Windows\System32\DriverStore\FileRepository` руками — только через `pnputil`.',
'- ⚠️ После первой чистки, когда появится место, создай свежую точку восстановления.')

Add-Md @('','---','','## 🧯 Профилактика: как перестать забивать системный диск','',
'1. **Кэши в другое место.** Всё, что умеет переезд (CapCut, OBS, лаунчеры, npm/pip/uv), переноси в настройках приложений на несистемный диск.',
'2. **Перенос папки без поломки программ (junction):**',
'',
'```powershell',
'# 1) копируем содержимое (пример: с C: на F:)',
'robocopy "C:\Users\ИМЯ\AppData\Roaming\.minecraft" "F:\Migrated\.minecraft" /E /COPY:DAT /DCOPY:DAT /R:1 /W:1',
'# 2) переименовываем старую папку (страховка, удалишь позже)',
'Rename-Item "C:\Users\ИМЯ\AppData\Roaming\.minecraft" ".minecraft_old"',
'# 3) создаём junction — программы будут видеть папку на старом месте',
'cmd /c mklink /J "C:\Users\ИМЯ\AppData\Roaming\.minecraft" "F:\Migrated\.minecraft"',
'# 4) проверяем, что всё работает, и только потом удаляем "_old"',
'```',
'',
'3. **Тяжёлое ПО — сразу на несистемный диск:** Steam-библиотеки, игры, модели LLM, виртуалки, кэши нейросетей.',
'4. **Теневые копии ограничь один раз:** `vssadmin resize shadowstorage /for=C: /on=C: /maxsize=4GB`.',
'5. **Storage Sense** (автоочистка временных файлов) — см. шаг в плане действий.',
'6. **Держи на SSD запас от 10-15%:** иначе падает скорость и растёт износ.',
'',
'---',
'',
'## 🔁 Как повторить анализ',
'',
'```powershell',
'# в папке со скриптом — полный анализ:',
'powershell -NoProfile -ExecutionPolicy Bypass -File .\DiskHealth.ps1',
'# быстрый режим без глубоких проходов по AppData:',
'powershell -NoProfile -ExecutionPolicy Bypass -File .\DiskHealth.ps1 -Quick',
'# без запроса админ-прав (урезанный отчёт):',
'powershell -NoProfile -ExecutionPolicy Bypass -File .\DiskHealth.ps1 -NoElevate',
'# без интерактивных вопросов (для планировщика/скриптов):',
'powershell -NoProfile -ExecutionPolicy Bypass -File .\DiskHealth.ps1 -Auto',
'# выполнить план из ПОСЛЕДНЕГО анализа (с подтверждением каждого шага):',
'powershell -NoProfile -ExecutionPolicy Bypass -File .\DiskHealth.ps1 -Fix',
'```',
'',
('Отчёт сохранён: ' + $reportPath),
('План действий (для -Fix): ' + (Join-Path $OutputDir 'DiskHealth_Plan.json')))

# ------------------- ЗАПИСЬ И ФИНАЛ -------------------
$Report -join "`r`n" | Out-File -LiteralPath $reportPath -Encoding UTF8
$elapsed = [math]::Round(((Get-Date) - $runStart).TotalMinutes, 1)

Write-Host ''
Write-Host ('ГОТОВО за ' + $elapsed + ' мин. Отчёт: ' + $reportPath) -ForegroundColor Green
Write-Host ('План действий: ' + $planPath + ' (шагов: ' + $recsSorted.Count + ')') -ForegroundColor Green
Write-Host '--- Топ находок ---' -ForegroundColor White
foreach ($r in ($recsSorted | Select-Object -First 6)) {
    Write-Host ('  ' + $r.Target + ' — ' + $r.Gb + ' ГБ') -ForegroundColor Gray
}
try { Invoke-Item -LiteralPath $reportPath } catch { }

if ($Auto) {
    Write-Host 'Режим -Auto: интерактивное меню пропущено.'
} else {
    Show-Menu
}
