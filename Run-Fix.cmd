@echo off
setlocal
if not exist "%~dp0Fix-CCS21-Antigravity.ps1" (
  echo Missing Fix-CCS21-Antigravity.ps1. Extract the complete ZIP first.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Fix-CCS21-Antigravity.ps1" %*
if errorlevel 1 (
  echo Repair failed. Read the error above. No forced shutdown was performed.
  pause
  exit /b 1
)
echo Script finished. Read the installation and reload status above.
pause
