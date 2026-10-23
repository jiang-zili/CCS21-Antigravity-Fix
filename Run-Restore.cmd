@echo off
setlocal DisableDelayedExpansion
"%~dp0Run-Fix.cmd" -Restore -NoRestart %*
