@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0Install.ps1" %*
set "R3_EXIT=%ERRORLEVEL%"
echo.
pause
exit /b %R3_EXIT%
