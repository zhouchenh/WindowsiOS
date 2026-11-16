@echo off
rem WinKit: double-click to install (or repair) the clipboard helper: what is copied in Windows
rem appears on the iPhone and the other way round. No administrator rights needed.
rem "CLIPBOARD.bat remove" takes it away again (as uninstall_clipboard.ps1 does).
cd /d "%~dp0"
if /i "%~1"=="remove" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0clipboard_setup.ps1" -Remove
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0clipboard_setup.ps1"
)
echo.
pause
