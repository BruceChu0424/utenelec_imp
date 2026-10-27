@echo off
setlocal
REM Run this file together with the supplied erp-trust-init.ps1.
REM Installs the pinned company root for the CURRENT user; no administrator needed.
if not exist "%~dp0erp-trust-init.ps1" (
  echo [ERROR] erp-trust-init.ps1 is missing. Extract the complete ZIP first.
  pause
  exit /b 1
)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0erp-trust-init.ps1"
set "UTEN_TRUST_RESULT=%errorlevel%"
echo.
pause
exit /b %UTEN_TRUST_RESULT%
