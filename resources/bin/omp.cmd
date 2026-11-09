@echo off
rem Soprano's PATH-scoped omp launcher for Windows (the bash `omp` beside it is the macOS/Linux
rem one). Forwards everything except `omp web` to the installed omp; never replaces it.
setlocal EnableDelayedExpansion
set "launcher_dir=%~dp0"
if "%launcher_dir:~-1%"=="\" set "launcher_dir=%launcher_dir:~0,-1%"

set "real_omp="
for %%E in (.exe .cmd .bat) do (
  if not defined real_omp (
    for /f "delims=" %%P in ('where omp%%E 2^>nul') do (
      if not defined real_omp (
        if /i not "%%~dpP"=="%launcher_dir%\" set "real_omp=%%P"
      )
    )
  )
)

if /i not "%~1"=="web" (
  if not defined real_omp (
    echo Soprano: install the omp CLI and make it available on PATH. 1>&2
    exit /b 127
  )
  "!real_omp!" %*
  exit /b !errorlevel!
)

set "web_dir=%SOPRANO_WEB_DIR%"
if not defined web_dir set "web_dir=%launcher_dir%\..\web"
if not exist "%web_dir%\bin\omp-web.js" if not defined SOPRANO_WEB_DIR set "web_dir=%launcher_dir%\..\..\web"
if not exist "%web_dir%\bin\omp-web.js" (
  echo Soprano: web runtime not found at %web_dir%. Reinstall Soprano or set SOPRANO_WEB_DIR. 1>&2
  exit /b 1
)
where node >nul 2>nul
if errorlevel 1 (
  echo Soprano: omp web requires Node.js ^>= 22.19.0. Install Node.js and retry. 1>&2
  exit /b 127
)
if not defined OMP_WEB_OMP_BIN (
  if not defined real_omp (
    echo Soprano: omp web requires the installed omp CLI on PATH ^(or OMP_WEB_OMP_BIN^). 1>&2
    exit /b 127
  )
  set "OMP_WEB_OMP_BIN=!real_omp!"
)
rem Drop the leading "web" argument.
set "args="
set "skipped="
for %%A in (%*) do (
  if defined skipped (set "args=!args! %%A") else set "skipped=1"
)
node "%web_dir%\bin\omp-web.js" !args!
exit /b !errorlevel!
