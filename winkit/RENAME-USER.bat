@echo off
rem WinKit: double-click to change the Windows user name. It asks for administrator rights by itself.
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
echo Right-click RENAME-USER.bat and choose "Run as administrator".
echo.
pause
exit /b

:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0rename_user.ps1"
echo.
pause
