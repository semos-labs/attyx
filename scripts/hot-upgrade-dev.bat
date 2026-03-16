@echo off
REM hot-upgrade-dev.bat — Build and trigger a hot-upgrade on Windows.
REM
REM Usage: scripts\hot-upgrade-dev.bat
REM
REM The daemon polls for upgrade-dev.exe every ~2s. Once found, it:
REM   - Renames running attyx.exe -> attyx.exe.old
REM   - Moves upgrade-dev.exe -> attyx.exe
REM   - Serializes session state with inherited HANDLE values
REM   - Spawns new daemon with bInheritHandles=TRUE
REM   - Old daemon keeps HPCON alive until all shells exit

set STATEDIR=%LOCALAPPDATA%\attyx
set STAGING=%STATEDIR%\upgrade-dev.exe
set BUILT=zig-out\bin\attyx.exe

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

echo [2/3] Staging binary at %STAGING%
copy /y "%BUILT%" "%STAGING%" >nul

echo [3/3] Staged. Daemon will pick it up within ~2s.
echo.
echo Watch daemon log: type "%STATEDIR%\daemon-debug-dev.log"
