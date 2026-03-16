@echo off
REM hot-upgrade-dev.bat — Build and trigger a hot-upgrade on Windows.
REM
REM Usage: scripts\hot-upgrade-dev.bat

set STATEDIR=%LOCALAPPDATA%\attyx
set STAGING=%STATEDIR%\upgrade-dev.exe
set BUILT=zig-out\bin\attyx.exe
set BUILT_OLD=zig-out\bin\attyx.exe.old

if not exist "%BUILT%" goto :dobuild

REM Try to free the locked exe
if exist "%BUILT_OLD%" del /f "%BUILT_OLD%" 2>nul
rename "%BUILT%" attyx.exe.old 2>nul

REM Check if rename worked
if not exist "%BUILT%" (
    echo [*] Renamed locked exe to .old
    goto :dobuild
)

REM Rename failed — kill daemon so build can overwrite
echo [!] Rename failed. Killing daemon...
"%BUILT%" kill-daemon 2>nul
timeout /t 2 /nobreak >nul

:dobuild
echo [1/3] Building...
zig build
if errorlevel 1 (
    echo Build failed.
    exit /b 1
)

if not exist "%BUILT%" (
    echo Built binary not found at %BUILT%
    exit /b 1
)

if not exist "%STATEDIR%" mkdir "%STATEDIR%"

if exist "%BUILT_OLD%" del /f "%BUILT_OLD%" 2>nul

echo [2/3] Staging binary at %STAGING%
copy /y "%BUILT%" "%STAGING%" >nul

echo [3/3] Staged. Daemon will pick it up within ~2s.
echo.
echo Watch: Get-Content "%STATEDIR%\daemon-debug-dev.log" -Tail 20 -Wait
