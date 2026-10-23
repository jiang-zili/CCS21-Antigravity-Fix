@echo off
setlocal DisableDelayedExpansion
if not exist "%~dp0Fix-CCS21-Antigravity.ps1" (
  echo Extract the complete repair ZIP first. The PowerShell script is missing.
  pause
  exit /b 1
)
echo Detecting Antigravity installations, entry points and compatible backends...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Fix-CCS21-Antigravity.ps1" %*
if errorlevel 1 (
  echo Repair failed. Read the error above. No forced shutdown was performed.
  pause
  exit /b 1
)
echo Operation completed. Review the results above. After repair, restart CCS and verify chat and Settings.
pause
