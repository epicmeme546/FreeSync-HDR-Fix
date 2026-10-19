@echo off
net session >nul 2>&1
if %errorlevel% equ 0 goto run
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b
:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0FreeSyncHDRFix.ps1" -Mode Revert
echo.
pause
