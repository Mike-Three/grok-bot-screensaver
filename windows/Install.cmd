@echo off
rem Installs Grok Bot Screensaver as your screensaver (current user, no admin needed).
set DEST=%LOCALAPPDATA%\GrokBotScreensaver
if not exist "%DEST%" mkdir "%DEST%"
copy /Y "%~dp0Grok Bot Screensaver.scr" "%DEST%\Grok Bot Screensaver.scr" >nul
reg add "HKCU\Control Panel\Desktop" /v SCRNSAVE.EXE /t REG_SZ /d "%DEST%\Grok Bot Screensaver.scr" /f >nul
reg add "HKCU\Control Panel\Desktop" /v ScreenSaveActive /t REG_SZ /d 1 /f >nul
reg add "HKCU\Control Panel\Desktop" /v ScreenSaveTimeOut /t REG_SZ /d 600 /f >nul
rundll32.exe user32.dll,UpdatePerUserSystemParameters
echo Grok Bot Screensaver is now your screensaver (starts after 10 minutes idle).
pause
