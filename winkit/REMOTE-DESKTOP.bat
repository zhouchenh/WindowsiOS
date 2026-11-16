@echo off
rem WinKit: double-click to let other devices use Remote Desktop to reach this Windows (Pro, Enterprise or
rem Education). It asks for administrator rights by itself. Runs enable_rdp.ps1; "enable_rdp.ps1 -Uninstall" undoes it.
cd /d "%~dp0"
whoami /groups | find "S-1-16-12288" >nul 2>&1
if not errorlevel 1 goto run
if "%~1"=="elevated" goto noadmin
echo Asking for administrator rights: choose Yes in the prompt...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList 'elevated' -Verb RunAs"
if errorlevel 1 goto noadmin
exit /b

:noadmin
echo.
echo Could not get administrator rights automatically.
echo Right-click REMOTE-DESKTOP.bat and choose "Run as administrator".
echo.
pause
exit /b

:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0enable_rdp.ps1"
echo.
pause
