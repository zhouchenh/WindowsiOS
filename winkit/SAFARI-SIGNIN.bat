@echo off
rem WinKit: double-click so that sign-in links from Windows open in Safari on the iPhone.
rem It asks for administrator rights by itself. Runs oauth_setup.ps1; uninstall_oauth.ps1 undoes it.
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
echo Right-click SAFARI-SIGNIN.bat and choose "Run as administrator".
echo.
pause
exit /b

:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0oauth_setup.ps1"
echo.
pause
