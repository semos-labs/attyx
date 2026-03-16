@echo off
REM hot-upgrade-dev.bat — Build and trigger a hot-upgrade on Windows.
REM
REM Usage: scripts\hot-upgrade-dev.bat
REM
REM Flow:
REM   1. Try to rename locked exe (works on most Windows configs)
REM   2. If rename fails, kill daemon so build can overwrite
REM   3. Build
REM   4. Stage new binary -> daemon hot-upgrades within ~2s

set STATEDIR=%LOCALAPPDATA%\attyx
set STAGING=%STATEDIR%\upgrade-dev.exe
set BUILT=zig-out\bin\attyx.exe
set BUILT_OLD=zig-out\bin\attyx.exe.old

REM Try to rename the locked exe so zig build can write the new one.
if exist "%BUILT%" (
    if exist "%BUILT_OLD%" del /f "%BUILT_OLD%" 2>nul
    rename "%BUILT%" attyx.exe.old
    if exist "%BUILT%" (
        echo [!] Rename failed (file locked). Killing daemon...
        "%BUILT%" kill-daemon 2>nul
        timeout /t 2 /nobreak >nul
        if exist "%BUILT_OLD%" del /f "%BUILT_OLD%" 2>nul
    ) else (
        echo [*] Renamed locked exe to .old
    )
)

echo [1/3] Building...
zig build
if errorlevel 1 (
    echo Build failed.
    REM Restore old binary if build failed and we renamed
    if not exist "%BUILT%" (
        if exist "%BUILT_OLD%" rename "%BUILT_OLD%" attyx.exe 2>nul
    )
    exit /b 1
)

REM Clean up old binary
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
echo Watch: Get-Content "%STATEDIR%\daemon-debug-dev.log" -Tail 20 -Wait
