# 🩺 DiskHealth — отчёт о состоянии системного диска

> **Дата:** 2026-10-27 19:11 | **Скрипт:** DiskHealth.ps1 v2.0
> **Компьютер:** DESKTOP-324JDP3 / ssurikin | **ОС:** Майкрософт Windows 11 Pro | **RAM:** 63 ГБ
> **Режим:** полный | **Права:** администратор

Анализ ничего не удалял — это только диагностика. Отчёт и план (DiskHealth_Plan.json) лежат рядом со скриптом.
Выполнить шаги плана с подтверждением каждого: `powershell -File .\DiskHealth.ps1 -Fix` или пункт [1] в меню скрипта.

---

## 📊 Сводка по томам

| Диск | Метка | Размер, ГБ | Свободно, ГБ | Примечание |
|---|---|---|---|---|
| C: |  | 144 | 15.7 | ⬅ системный |
| D: |  | 808.8 | 65.7 |  |
| E: | Зарезервировано системой | 0.6 | 0.1 |  |
| F: |  | 465.7 | 423.5 |  |
| G: |  | 223 | 30.6 |  |
| H: | SSD | 976.6 | 936.9 |  |
| Q: | Зарезервировано системой | 0.1 | 0.1 |  |

**Системный диск C::** занято 128.3 из 144 ГБ, свободно **15.7 ГБ (10.9%)**.
**Потенциально можно освободить (по зелёным и жёлтым пунктам плана): ~33.2 ГБ.**

Легенда: 🟢 Безопасно — можно делать смело; 🟡 Осторожно — сначала прочитай комментарий; 🔴 Системное — системно важно, руками не трогать.

---

## 🚑 План действий (по убыванию выгоды)

Выполняй шаги по одному. После каждого шага проверяй свободное место: `Get-Volume 
C:
`
Скрипт умеет выполнять план сам (с подтверждением каждого шага): `powershell -File .\DiskHealth.ps1 -Fix`

| # | Цель | Размер, ГБ | Критичность | Что делать |
|---|---|---|---|---|
| 1 | Личная папка: Documents | 16.08 | 🟡 Осторожно | Разбери содержимое, крупное перенеси на несистемный диск. Перенос папки целиком — robocopy + junction (шаблон в разделе «Профилактика») |
| 2 | Хранилище компонентов WinSxS | 7.35 | 🟡 Осторожно | Штатная чистка DISM удаляет устаревшие версии компонентов (5-15 мин). Вариант с /ResetBase вычищает ещё больше, но после него нельзя откатывать уже установленные обновления |
| 3 | pagefile.sys — файл подкачки | 4 | 🔴 Системное | НЕ УДАЛЯТЬ. Система без него нестабильна. Уменьшать/переносить только осознанно |
| 4 | CapCut (AppData\Local) | 3.89 | 🟡 Осторожно | Внутри кэш и ЧЕРНОВИКИ ПРОЕКТОВ. Сначала перенеси кэш/черновики на несистемный диск в настройках CapCut, затем чисти кэш средствами приложения |
| 5 | Индекс поиска Windows | 2.07 | 🟡 Осторожно | Руками не удалять при работающей службе. Перестрой индекс: Параметры → Поиск в Windows → Дополнительно → Перестроить (индекс соберётся заново, меньше и свежее) |
| 6 | Кэши браузеров | 1.92 | 🟢 Безопасно | Чистится из настроек браузера: Ctrl+Shift+Del → «Изображения и файлы кэша». Через сам браузер безопаснее, чем удалять папки |
| 7 | Temp пользователя | 1.22 | 🟢 Безопасно | Временные файлы приложений. Занятые пропустятся |
| 8 | Кэш: AMD DxCache | 0.38 | 🟢 Безопасно | Кэш шейдеров AMD — игры пересоздадут |
| 9 | Кэш: Кэш миниатюр | 0.24 | 🟢 Безопасно | Файлы thumbcache_*.db. Чистится через cleanmgr («Эскизы») или после перезапуска explorer.exe |

**Шаг 1: Хранилище компонентов WinSxS**

```powershell
Dism.exe /Online /Cleanup-Image /StartComponentCleanup
```

**Шаг 2: Temp пользователя**

```powershell
Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
```

**Шаг 3: Кэш: AMD DxCache**

```powershell
Remove-Item -LiteralPath "C:\Users\ssurikin\AppData\Local\AMD\DxCache\*" -Recurse -Force -ErrorAction SilentlyContinue
```

---

## 🗂 Большие директории на C:\

| Папка | Размер | % диска | Категория | Критичность удаления | Комментарий |
|---|---|---|---|---|---|
| Users | 67.81 ГБ | 47.1% | Профили пользователей | 🟡 Осторожно | Разбирать внутри (AppData, Документы), не сносить целиком |
| Windows | 34.16 ГБ | 23.7% | Системная | 🔴 Системное | Никогда не удалять вручную. Чистится только DISM/cleanmgr |
| Program Files | 20.53 ГБ | 14.3% | Программы (64-бит) | 🔴 Системное | Только деинсталляцией, папки руками не сносить |
| Program Files (x86) | 7.09 ГБ | 4.9% | Программы (32-бит) | 🔴 Системное | Только деинсталляцией |
| ProgramData | 6.46 ГБ | 4.5% | Данные программ | 🔴 Системное | Не трогать руками |
| CustomPrograms | 3.66 ГБ | 2.5% | Пользовательская/прочее | 🟡 Осторожно | Оцени вручную; можно перенести robocopy + junction |

### 🐘 Самые большие файлы (топ-20, от 500 МБ)

Проверь по одному: часто среди них очевидный мусор (образы, старые архивы, дампы).

| Файл | Размер | Класс | Полный путь |
|---|---|---|---|
| Windows.db | 1.97 ГБ | Данные | C:\ProgramData\Microsoft\Search\Data\Applications\Windows\Windows.db |
| db.sqlite | 1.83 ГБ | Данные | C:\Users\ssurikin\.zcode\cli\db\db.sqlite |
| Store - Year 4 - Updates 37-48 v1.5.package | 1.33 ГБ | Данные | C:\Users\ssurikin\Documents\Electronic Arts\The Sims 3\Mods\Packages\Store - Year 4 - Updates 37-48 … |
| Store - Year 3 - Updates 25-36 v1.5.package | 1.28 ГБ | Данные | C:\Users\ssurikin\Documents\Electronic Arts\The Sims 3\Mods\Packages\Store - Year 3 - Updates 25-36 … |
| Store - Year 1 - Updates 01-12 v1.5.package | 1.28 ГБ | Данные | C:\Users\ssurikin\Documents\Electronic Arts\The Sims 3\Mods\Packages\Store - Year 1 - Updates 01-12 … |
| Store - Year 2 - Updates 13-24 v1.5.package | 1.16 ГБ | Данные | C:\Users\ssurikin\Documents\Electronic Arts\The Sims 3\Mods\Packages\Store - Year 2 - Updates 13-24 … |
| Store - Year 5 - Updates 49-60 v1.5.package | 0.89 ГБ | Данные | C:\Users\ssurikin\Documents\Electronic Arts\The Sims 3\Mods\Packages\Store - Year 5 - Updates 49-60 … |
| system.vhd | 0.71 ГБ | Диск ВМ | C:\Program Files\WSL\system.vhd |
| Exosphere 2.zip | 0.61 ГБ | Архив | C:\Users\ssurikin\AppData\Roaming\PrismLauncher\instances\Exosphere 2.zip |
| ggml-cuda.dll | 0.53 ГБ | Данные | C:\Users\ssurikin\.lmstudio\extensions\backends\llama.cpp-win-x86_64-nvidia-cuda-avx2-2.54.0\ggml-cu… |

---

## 👤 Профили пользователей (C:\Users)

| Профиль | Размер |
|---|---|
| ssurikin | 67.81 ГБ |
| Default | 0 ГБ |
| Public | 0 ГБ |

### Личные папки

| Папка | Размер |
|---|---|
| Desktop | 1.37 ГБ |
| Documents | 16.08 ГБ |
| Downloads | 0.57 ГБ |
| Videos | 0 ГБ |
| Pictures | 0.02 ГБ |
| Music | 0 ГБ |

### AppData\Local текущего пользователя (топ-20)

| Папка | Размер | Комментарий |
|---|---|---|
| Microsoft | 4.17 ГБ | 🟡 Внутри кэши Edge/OneDrive/Teams. Чистить точечно, папку не сносить |
| CapCut | 3.89 ГБ | 🟡 Кэш CapCut. Черновики проектов могут лежать там же — не сносить бездумно. Кэш переносится в настройках приложения |
| Yandex | 3.55 ГБ | 🟡 Кэш Яндекс.Браузера. Чистить из настроек браузера |
| GitHubDesktop | 1.54 ГБ | 🟢 Кэш клиента GitHub Desktop; сами репозитории лежат отдельно |
| Packages | 1.33 ГБ | 🔴 Данные UWP-приложений (Microsoft Store). Руками не трогать |
| PowerToys | 0.94 ГБ | 🟡 Установленные per-user программы — только деинсталляцией |
| Mozilla | 0.82 ГБ | — |
| Stoat | 0.81 ГБ | — |
| Programs | 0.73 ГБ | 🟡 Установленные per-user программы — только деинсталляцией |
| Discord | 0.62 ГБ | 🟢 Старые версии в подпапках app-* можно удалить |
| AMD | 0.58 ГБ | 🟡 Драйверное ПО — чистить через деинсталлятор, не руками |
| Medibang | 0.38 ГБ | — |
| @zcodedesktop-updater | 0.36 ГБ | 🟢 Хвосты автообновляторов приложений (старые версии) |
| EpicGamesLauncher | 0.31 ГБ | — |
| Package Cache | 0.27 ГБ | 🟡 Установленные per-user программы — только деинсталляцией |
| obsidian-updater | 0.27 ГБ | 🟢 Хвосты автообновляторов приложений (старые версии) |
| termius-updater | 0.24 ГБ | 🟢 Хвосты автообновляторов приложений (старые версии) |
| kenshi | 0.23 ГБ | — |
| yandexmusic-updater | 0.21 ГБ | 🟢 Хвосты автообновляторов приложений (старые версии) |
| CrashDumps | 0.18 ГБ | — |

### AppData\Roaming текущего пользователя (топ-15)

| Папка | Размер | Комментарий |
|---|---|---|
| .minecraft | 6.47 ГБ | 🟡 Миры/моды/сборки Minecraft. Переносится на другой диск |
| PrismLauncher | 3.25 ГБ | 🟡 Инстансы Minecraft. Переносится в настройках лаунчера |
| Code | 1.14 ГБ | 🟢 Кэши VS Code — чистятся безболезненно |
| npm | 0.82 ГБ | — |
| Python | 0.62 ГБ | — |
| obs-studio | 0.47 ГБ | — |
| YandexMusic | 0.32 ГБ | — |
| Microsoft | 0.3 ГБ | 🟡 Внутри кэши Edge/OneDrive/Teams. Чистить точечно, папку не сносить |
| obsidian | 0.24 ГБ | — |
| Bitrix | 0.21 ГБ | — |
| discord | 0.14 ГБ | 🟢 Старые версии в подпапках app-* можно удалить |
| kingsoft | 0.13 ГБ | — |
| com.adobe.dunamis | 0.12 ГБ | — |
| ollama app.exe | 0.1 ГБ | — |
| Mozilla | 0.1 ГБ | — |

### Внутри «Документы» (топ-15)

| Объект | Размер |
|---|---|
| Electronic Arts | 9.02 ГБ |
| My Games | 5.08 ГБ |
| Mount and Blade II Bannerlord | 1.97 ГБ |
| Max Payne 2 Savegames | 0.01 ГБ |
| Respawn | 0 ГБ |
| NoMoreBorder | 0 ГБ |
| My Videos | 0 ГБ |
| PowerShell | 0 ГБ |
| Мои игры | 0 ГБ |
| Настраиваемые шаблоны Office | 0 ГБ |
| desktop.ini | 0 ГБ |
| Voicemeeter | 0 ГБ |
| Warcraft III | 0 ГБ |
| WindowsPowerShell | 0 ГБ |
| My Pictures | 0 ГБ |

---

## 🧱 Системные потребители места

| Что | Размер | Как чистить |
|---|---|---|
| Файл гибернации hiberfil.sys | — | 🟢 Безопасно powercfg /h off (или /type reduced на ноутбуке) |
| Файл подкачки pagefile | 4 ГБ (на C:\pagefile.sys) | 🔴 Системное руками не трогать |
| Хранилище компонентов WinSxS (фактический размер) | 7.35 ГБ | 🟡 Осторожно Dism /StartComponentCleanup |
| Кэш Центра обновлений (SoftwareDistribution\Download) | 0.01 ГБ | 🟢 Безопасно см. план действий |
| Кэш установщиков MSI (Windows\Installer) | 3 ГБ | 🟢 Безопасно см. план действий |
| Временные файлы Windows (Windows\Temp) | 0.06 ГБ | 🟢 Безопасно см. план действий |
| Хвосты обновления Windows ($WinREAgent) | 0 ГБ | 🟢 Безопасно см. план действий |
| Старая копия Windows (Windows.old) | 0 ГБ | 🟢 Безопасно см. план действий |
| Дистрибутив Windows (ESD) | 0 ГБ | 🟢 Безопасно см. план действий |
| Логи Windows (Windows\Logs) | 0.07 ГБ | 🟢 Безопасно см. план действий |
| Prefetch (кэш запуска приложений) | 0.01 ГБ | 🟢 Безопасно см. план действий |
| Delivery Optimization (кэш раздачи обновлений) | 0.02 ГБ | 🟢 Безопасно см. план действий |
| Индекс поиска Windows (ProgramData\Microsoft\Search\Data) | 2.07 ГБ | 🟢 Безопасно см. план действий |
| Хранилище драйверов (DriverStore\FileRepository) | 5.75 ГБ | 🟢 Безопасно см. план действий |
| Package Cache (установщики, служебный) | 0.31 ГБ | 🟢 Безопасно см. план действий |
| Отчёты об ошибках Windows (WER) | 0.01 ГБ | 🟢 Безопасно см. план действий |
| Дампы ядра (LiveKernelReports) | 0 ГБ | 🟢 Безопасно см. план действий |
| Мини-дампы BSOD (Minidump) | 0 ГБ | 🟢 Безопасно см. план действий |
| Временные файлы пользователя (Temp) | 1.22 ГБ | 🟢 Безопасно см. план действий |
| Аварийные дампы приложений (CrashDumps) | 0.18 ГБ | 🟢 Безопасно см. план действий |
| Корзина системного диска ($Recycle.Bin) | 0.17 ГБ | 🟢 Безопасно см. план действий |

---

## 🧰 Крупнейшие установленные программы (топ-30 по размеру)

Программы с отметкой «да» в колонке «На C:» занимают системный диск. Удалять только через «Параметры → Приложения».

| Программа | Версия | Размер, МБ | На C: | Путь |
|---|---|---|---|---|
| GaomonTablet | 16.0.0.194 | 64914 | нет |  |
| Fallout New Vegas Extended Edition, версия 12.12.25.1 | 12.12.25.1 | 50529 | нет | D:\Games\FNVEE\ |
| Unreal Tournament 2004 | 2.0.0.6 | 5792 | нет | D:\Games\Unreal Tournament 2004\ |
| Adobe Photoshop 2026 | 27.0.0.25 | 5621 | нет | D:\Custom Programs\Adobe Photoshop 2026 |
| Docker Desktop | 4.96.3 | 3410 | нет | D:\Custom Programs\Docker |
| Ollama version 0.40.8 | 0.40.8 | 3125 | нет | D:\Custom Programs\Ollama\ |
| Microsoft Edge | 156.0.4314.42 | 2833 | да | C:\Program Files (x86)\Microsoft\Edge\Application |
| Community Modpack for Mafia: The City of Lost Heaven |  | 2636 | нет | D:\Custom Programs\Steam\steamapps\common\Mafia\ |
| Microsoft Edge WebView2 Runtime | 155.0.4283.62 | 2121 | да | C:\Program Files (x86)\Microsoft\EdgeWebView\Application |
| LM Studio 0.4.26+4 | 0.4.26+4 | 2004 | нет |  |
| PowerToys (Preview) x64 | 0.100.2 | 1211 | да | C:\Users\ssurikin\AppData\Local\PowerToys\ |
| Windows Subsystem for Linux | 3.0.3.0 | 1168 | нет |  |
| Max Payne Sound Fix & ENG Voices 1.0 | 1.0 | 1150 | нет | D:\Games\MaxPayne\Max Payne Sound Fix & ENG Voices\ |
| Obsidian | 1.10.3 | 977 | нет |  |
| Blender | 5.1.1 | 976 | нет | D:\CustomPrograms\Blender\ |
| ZCode 3.16.3 | 3.16.3 | 799 | нет |  |
| EA app | 13.709.2.6223 | 797 | нет |  |
| Max Payne | 1.0.0.0 | 785 | нет | D:\Games\Max Payne\ |
| Termius 9.37.5 | 9.37.5 | 754 | нет |  |
| Epic Online Services | 4.1.0 | 722 | нет |  |
| Antigravity (User) | 1.11.3 | 702 | да | C:\CustomPrograms\Antigravity\ |
| PowerToys (Preview) | 0.100.2 | 673 | да | C:\Users\ssurikin\AppData\Local\PowerToys\ |
| ChaosTricks, версия 2.21.0 | 2.21.0 | 652 | да | C:\CustomPrograms\ChaosTricks\ |
| Microsoft OneDrive | 26.183.0920.0005 | 564 | нет |  |
| EA app | 12.0.0.0 | 564 | нет |  |
| UXP WebView Support | 1.3.0 | 558 | да | C:\Program Files\Common Files\Adobe\Microsoft\EdgeWebView |
| Microsoft Visual Studio Code (User) | 1.113.0 | 551 | нет | D:\Custom Programs\Microsoft VS Code\ |
| Яндекс Телемост | 3.2.2.10363 | 497 | да | C:\Program Files\Yandex\YandexTelemost\ |
| AMD Software | 26.10.1 | 475 | да | C:\Program Files\AMD\CIM\BIN64 |
| AMD Settings | 2026.1015.1803.2112 | 443 | да | C:\Program Files\AMD\CNext\CNext\ |

---

## 🛍 Приложения Microsoft Store (UWP, топ-12)

Удалять только через «Параметры → Приложения» или командой `Get-AppxPackage <имя> | Remove-AppxPackage`. Руками папки в `WindowsApps` не трогать.

| Пакет | Размер |
|---|---|
| Microsoft.Windows.Photos | 0.86 ГБ |
| 9426MICRO-STARINTERNATION.MSICenter | 0.71 ГБ |
| Microsoft.ScreenSketch | 0.57 ГБ |
| Microsoft.Paint | 0.41 ГБ |
| MicrosoftWindows.Client.CBS | 0.33 ГБ |
| Microsoft.MicrosoftOfficeHub | 0.32 ГБ |
| Microsoft.GamingApp | 0.3 ГБ |
| MSTeams | 0.29 ГБ |
| Microsoft.GetHelp | 0.27 ГБ |
| Microsoft.GamingServices | 0.23 ГБ |
| MicrosoftWindows.Client.Core | 0.22 ГБ |
| Microsoft.LanguageExperiencePackru-RU | 0.22 ГБ |

---

## 💽 Образы WSL/Docker (.vhdx)

Образы WSL/Docker не найдены (или режим -Quick).

---

## 🌐 Кэши браузеров и разработчика

| Браузер | Объём кэша |
|---|---|
| Microsoft Edge | 0.15 ГБ |
| Яндекс.Браузер | 0.98 ГБ |
| Mozilla Firefox | 0.79 ГБ |

| Что | Объём | Комментарий | Команда очистки |
|---|---|---|---|
| AMD DxCache | 0.38 ГБ | Кэш шейдеров AMD — игры пересоздадут | `Remove-Item -LiteralPath "C:\Users\ssurikin\AppData\Local\AMD\DxCache\*" -Recurse -Force -ErrorAction SilentlyContinue` |
| Кэш миниатюр | 0.24 ГБ | Файлы thumbcache_*.db. Чистится через cleanmgr («Эскизы») или после перезапуска explorer.exe | — |

---

## 📎 Сырой вывод DISM и vssadmin (для сверки)

```text
Размер хранилища компонентов по данным проводника : 7.71 GB
Фактический размер хранилища компонентов : 7.35 GB
Рекомендуется очистка хранилища компонентов : Да

--- vssadmin ---
vssadmin 1.1 - Программа командной строки для администрирования службы теневого копирования томов
(C) Корпорация Майкрософт (Microsoft Corportion), 2001-2013.

Отсутствуют элементы, соответствующие запросу.

```

---

## ⛔ Чего делать НЕЛЬЗЯ

- ❌ Удалять вручную содержимое `C:\Windows` (включая `WinSxS`, `Installer`, `DriverStore`) — только штатные очистки (DISM, cleanmgr, pnputil).
- ❌ Удалять `pagefile.sys`, `swapfile.sys`, `hiberfil.sys` руками — только через powercfg/настройки системы.
- ❌ Сносить папки из `AppData\Local\Packages` и `C:\Program Files\WindowsApps` — это данные приложений из Microsoft Store.
- ❌ Чистить `ProgramData\Package Cache` — сломаются восстановление и обновление программ.
- ❌ Удалять `.vhdx` образы WSL/Docker — это диски виртуальных машин.
- ❌ Удалять junction-ссылки через проводник или `Remove-Item -Recurse` в PowerShell 5.1 — можно вынести ЦЕЛЕВУЮ папку. Ссылка снимается командой `cmd /c rmdir "C:\путь\к\ссылке"` (без /S).
- ❌ Чистить папку `Windows\System32\DriverStore\FileRepository` руками — только через `pnputil`.
- ⚠️ После первой чистки, когда появится место, создай свежую точку восстановления.

---

## 🧯 Профилактика: как перестать забивать системный диск

1. **Кэши в другое место.** Всё, что умеет переезд (CapCut, OBS, лаунчеры, npm/pip/uv), переноси в настройках приложений на несистемный диск.
2. **Перенос папки без поломки программ (junction):**

```powershell
# 1) копируем содержимое (пример: с C: на F:)
robocopy "C:\Users\ИМЯ\AppData\Roaming\.minecraft" "F:\Migrated\.minecraft" /E /COPY:DAT /DCOPY:DAT /R:1 /W:1
# 2) переименовываем старую папку (страховка, удалишь позже)
Rename-Item "C:\Users\ИМЯ\AppData\Roaming\.minecraft" ".minecraft_old"
# 3) создаём junction — программы будут видеть папку на старом месте
cmd /c mklink /J "C:\Users\ИМЯ\AppData\Roaming\.minecraft" "F:\Migrated\.minecraft"
# 4) проверяем, что всё работает, и только потом удаляем "_old"
```

3. **Тяжёлое ПО — сразу на несистемный диск:** Steam-библиотеки, игры, модели LLM, виртуалки, кэши нейросетей.
4. **Теневые копии ограничь один раз:** `vssadmin resize shadowstorage /for=C: /on=C: /maxsize=4GB`.
5. **Storage Sense** (автоочистка временных файлов) — см. шаг в плане действий.
6. **Держи на SSD запас от 10-15%:** иначе падает скорость и растёт износ.

---

## 🔁 Как повторить анализ

```powershell
# в папке со скриптом — полный анализ:
powershell -NoProfile -ExecutionPolicy Bypass -File .\DiskHealth.ps1
# быстрый режим без глубоких проходов по AppData:
powershell -NoProfile -ExecutionPolicy Bypass -File .\DiskHealth.ps1 -Quick
# без запроса админ-прав (урезанный отчёт):
powershell -NoProfile -ExecutionPolicy Bypass -File .\DiskHealth.ps1 -NoElevate
# без интерактивных вопросов (для планировщика/скриптов):
powershell -NoProfile -ExecutionPolicy Bypass -File .\DiskHealth.ps1 -Auto
# выполнить план из ПОСЛЕДНЕГО анализа (с подтверждением каждого шага):
powershell -NoProfile -ExecutionPolicy Bypass -File .\DiskHealth.ps1 -Fix
```

Отчёт сохранён: D:\PERSONAL_STASH\2 ssurikin\programming\projects\Scripts\Cleaning\DiskHealth_Report_20261027_191124.md
План действий (для -Fix): D:\PERSONAL_STASH\2 ssurikin\programming\projects\Scripts\Cleaning\DiskHealth_Plan.json
