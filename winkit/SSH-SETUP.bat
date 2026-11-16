@echo off
rem WinKit: double-click to install an OpenSSH server (key login only) and longer service start times.
rem It asks for administrator rights by itself. Runs ssh_setup.ps1.
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
echo Right-click SSH-SETUP.bat and choose "Run as administrator".
echo.
pause
exit /b

:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ssh_setup.ps1"
echo.
pause
