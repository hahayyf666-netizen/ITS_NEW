@echo off
setlocal
powershell -ExecutionPolicy Bypass -File "%~dp0run_from_package.ps1" %*
endlocal