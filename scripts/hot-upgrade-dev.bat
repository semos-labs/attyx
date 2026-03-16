@echo off
REM hot-upgrade-dev.bat — Build and trigger a hot-upgrade on Windows.
REM
REM Usage: scripts\hot-upgrade-dev.bat
REM
REM Flow:
REM   1. Rename locked zig-out\bin\attyx.exe -> .old (works while running)
REM   2. Build (zig build can now write the new binary)
REM   3. Copy new binary to staging path
REM   4. Daemon detects staged binary within ~2s -> hot-upgrade kicks in

set STATEDIR=%LOCALAPPDATA%\attyx
set STAGING=%STATEDIR%\upgrade-dev.exe
set BUILT=zig-out\bin\attyx.exe
set BUILT_OLD=zig-out\bin\attyx.exe.old

REM Step 1: Rename the locked exe so zig build can write the new one.
REM rename works on locked files — the running process keeps using the old binary from memory.
if exist "%BUILT%" (
    if exist "%BUILT_OLD%" del /f "%BUILT_OLD%" 2>nul
    rename "%BUILT%" attyx.exe.old 2>nul
)

echo [1/3] Building...
zig build
if errorlevel 1 (
    echo Build failed.
    REM Restore the old binary if build failed
    if not exist "%BUILT%" (
        if exist "%BUILT_OLD%" rename "%BUILT_OLD%" attyx.exe 2>nul
    )
    exit /b 1
)

REM Clean up the old binary (may fail if still locked — that's fine)
if exist "%BUILT_OLD%" del /f "%BUILT_OLD%" 2>nul

if not exist "%BUILT%" (
    echo Built binary not found at %BUILT%
    exit /b 1
)

if not exist "%STATEDIR%" mkdir "%STATEDIR%"

echo [2/3] Staging binary at %STAGING%
copy /y "%BUILT%" "%STAGING%" >nul

echo [3/3] Staged. Daemon will pick it up within ~2s.
echo.
echo Watch daemon log: Get-Content "%STATEDIR%\daemon-debug-dev.log" -Tail 20 -Wait
