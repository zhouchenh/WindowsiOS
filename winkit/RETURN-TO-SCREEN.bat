@echo off
rem SPDX-License-Identifier: GPL-2.0-or-later
rem WinKit: hands this Remote Desktop session back to the VM's own screen (the app), without signing in again.
rem Run it inside the Remote Desktop session; it asks for administrator rights by itself. The Remote Desktop
rem client is disconnected and Windows goes on, still signed in, on the app's screen.
cd /d "%~dp0"
if /i "%SESSIONNAME%"=="Console" goto console
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
echo Right-click RETURN-TO-SCREEN.bat and choose "Run as administrator".
echo.
pause
exit /b

:console
echo This is already the VM's own screen: nothing to hand back.
pause
exit /b

:run
rem The session this runs in (the Remote Desktop one): its id, from the process itself.
set SID=
for /f %%i in ('powershell -NoProfile -Command "(Get-Process -Id $PID).SessionId"') do set SID=%%i
if "%SID%"=="" goto failed
tscon %SID% /dest:console
if errorlevel 1 goto failed
exit /b

:failed
echo.
echo Windows did not hand the session over (tscon failed). Sign in on the app's screen instead.
pause
exit /b
