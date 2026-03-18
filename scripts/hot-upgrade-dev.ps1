# hot-upgrade-dev.ps1 — Build and trigger a hot-upgrade on Windows.
#
# Usage:
#   .\scripts\hot-upgrade-dev.ps1
#
# What it does:
#   1. Builds attyx (zig build)
#   2. Copies the new binary to the staging path (upgrade-dev.exe)
#   3. The running daemon detects the staged binary within ~2s
#   4. Daemon performs hot-upgrade: swaps exe, spawns new daemon,
#      host processes keep shells alive across the transition
#
# The daemon polls for upgrade-dev.exe every ~2s. Once found, it:
#   - Disconnects from host processes (they enter reconnect mode)
#   - Renames running attyx.exe → attyx.exe.old
#   - Moves upgrade-dev.exe → attyx.exe
#   - Serializes session state (pane IDs, not handles)
#   - Spawns new daemon (no handle inheritance needed)
#   - Old daemon exits cleanly; new daemon reconnects to hosts

$ErrorActionPreference = "Stop"

$stateDir = "$env:LOCALAPPDATA\attyx"
$stagingPath = "$stateDir\upgrade-dev.exe"

# Build
Write-Host "[1/3] Building..." -ForegroundColor Cyan
zig build 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Build failed." -ForegroundColor Red
    exit 1
}

# Find built binary
$builtExe = "zig-out\bin\attyx.exe"
if (-not (Test-Path $builtExe)) {
    Write-Host "Built binary not found at $builtExe" -ForegroundColor Red
    exit 1
}

# Ensure state dir exists
if (-not (Test-Path $stateDir)) {
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
}

# Stage the new binary
Write-Host "[2/3] Staging binary at $stagingPath" -ForegroundColor Cyan
Copy-Item $builtExe $stagingPath -Force

Write-Host "[3/3] Staged. Daemon will pick it up within ~2s." -ForegroundColor Green
Write-Host ""
Write-Host "Watch daemon log: Get-Content '$stateDir\daemon-debug-dev.log' -Tail 20 -Wait" -ForegroundColor DarkGray
