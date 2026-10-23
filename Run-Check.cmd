@echo off
setlocal DisableDelayedExpansion
"%~dp0Run-Fix.cmd" -CheckOnly -NoRestart %*
