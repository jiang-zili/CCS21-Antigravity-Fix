@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Fix-CCS21-Antigravity.ps1" %*
if errorlevel 1 (
  echo Repair failed. Read the error above. No forced shutdown was performed.
  pause
  exit /b 1
)
echo Done.
pause
