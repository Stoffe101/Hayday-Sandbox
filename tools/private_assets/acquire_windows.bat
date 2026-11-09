@echo off
rem Hayday Sandbox: build + install the PRIVATE original-art pack (personal use only, never redistribute).
rem Double-click this file, or run it from a command prompt with extra options, e.g.
rem   acquire_windows.bat -InstallPython
rem   acquire_windows.bat -Steps build
rem   acquire_windows.bat -DryRun
rem It runs Acquire-HaydayAssets.ps1 (next to this file) with a process-only execution-policy bypass.
rem See docs\PRIVATE_ASSETS.md.
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Acquire-HaydayAssets.ps1" %*
set "RC=%ERRORLEVEL%"
rem Keep the window open when started by double-click (no arguments).
if "%~1"=="" pause
endlocal & exit /b %RC%
