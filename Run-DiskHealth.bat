@echo off
rem ============================================================
rem  DiskHealth launcher
rem  Analyzes the system disk and writes
rem  DiskHealth_Report_*.md next to this .bat file.
rem  If UAC asks for permission - click Yes.
rem ============================================================
echo Running DiskHealth...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0DiskHealth.ps1"
echo.
echo Done. Report file is in this folder.
pause
