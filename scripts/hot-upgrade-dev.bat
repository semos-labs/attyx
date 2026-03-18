@echo off
REM hot-upgrade-dev.bat — Test hot-upgrade with live sessions.
REM
REM Usage:
REM   1. Open attyx normally (zig build run), create tabs
REM   2. Run: scripts\hot-upgrade-dev.bat
REM   3. Daemon hot-upgrades within ~2s, tabs should survive
REM
REM How: copies the ALREADY-BUILT binary to the staging path.
REM The daemon is running the same binary, but the staged-binary
REM detection triggers the upgrade flow regardless.
REM
REM For code changes: kill daemon first, rebuild, then test.

set STATEDIR=%LOCALAPPDATA%\attyx
set STAGING=%STATEDIR%\upgrade-dev.exe
set BUILT=zig-out\bin\attyx.exe

if not exist "%BUILT%" (
    echo No built binary found. Run "zig build" first.
    exit /b 1
)

if not exist "%STATEDIR%" mkdir "%STATEDIR%"

echo Staging %BUILT% for hot-upgrade...
copy /y "%BUILT%" "%STAGING%" >nul

echo Done. Daemon will detect it within ~2s.
echo.
echo Watch: Get-Content "%STATEDIR%\daemon-debug-dev.log" -Tail 30 -Wait
