# Attyx — Build Windows installer
# Usage: powershell -ExecutionPolicy Bypass -File installer\build-installer.ps1
# Builds attyx, assembles payload, compiles the custom installer exe.

param(
    [string]$Version = "",
    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$dist = Join-Path $root "installer\dist"
$output = Join-Path $root "installer\output"

# Read version from build.zig.zon if not provided
if (-not $Version) {
    $zon = Get-Content (Join-Path $root "build.zig.zon") -Raw
    if ($zon -match '\.version\s*=\s*"([^"]+)"') {
        $Version = $Matches[1]
    } else {
        Write-Error "Could not read version from build.zig.zon. Pass -Version manually."
        exit 1
    }
}
Write-Host "Building Attyx $Version installer..." -ForegroundColor Cyan

# Step 1: Build attyx
if (-not $SkipBuild) {
    Write-Host ">> zig build" -ForegroundColor Yellow
    Push-Location $root
    zig build
    Pop-Location
}

# Step 2: Assemble dist/
Write-Host ">> Assembling payload in installer\dist\" -ForegroundColor Yellow
if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
New-Item -ItemType Directory -Path $dist -Force | Out-Null

$srcExe = Join-Path $root "zig-out\bin\attyx.exe"
if (-not (Test-Path $srcExe)) {
    Write-Error "zig-out\bin\attyx.exe not found. Run zig build first."
    exit 1
}
Copy-Item $srcExe -Destination $dist
Write-Host "  Copied attyx.exe"

$srcPdb = Join-Path $root "zig-out\bin\attyx.pdb"
if (Test-Path $srcPdb) {
    Copy-Item $srcPdb -Destination $dist
    Write-Host "  Copied attyx.pdb"
}

$sysroot = Join-Path $root "zig-out\bin\share\msys2"
if (Test-Path $sysroot) {
    Copy-Item $sysroot -Destination (Join-Path $dist "share\msys2") -Recurse -Force
    Write-Host "  Copied share\msys2\"
}

# Verify
$distExe = Join-Path $dist "attyx.exe"
if (-not (Test-Path $distExe)) {
    Write-Error "Failed to assemble dist: attyx.exe missing from $dist"
    exit 1
}
Write-Host "  Payload ready: $dist"

# Step 3: Compile custom installer
Write-Host ">> Compiling installer..." -ForegroundColor Yellow
New-Item -ItemType Directory -Path $output -Force | Out-Null
$setupExe = Join-Path $output "attyx-$Version-setup.exe"

$installerDir = Join-Path $root "installer"
Push-Location $installerDir
zig build --prefix "$output\zig-out"
Pop-Location

$builtExe = Join-Path $output "zig-out\bin\attyx-setup.exe"
if (-not (Test-Path $builtExe)) {
    Write-Error "Installer compilation failed."
    exit 1
}
Move-Item $builtExe $setupExe -Force
Remove-Item (Join-Path $output "zig-out") -Recurse -Force -ErrorAction SilentlyContinue

# Step 4: Copy dist/ next to setup exe
Write-Host ">> Copying payload next to installer..." -ForegroundColor Yellow
$setupDist = Join-Path $output "dist"
if (Test-Path $setupDist) { Remove-Item $setupDist -Recurse -Force }
Copy-Item $dist -Destination $setupDist -Recurse -Force

# Final verify
$finalCheck = Join-Path $setupDist "attyx.exe"
if (-not (Test-Path $finalCheck)) {
    Write-Error "Failed to copy payload to output\dist\"
    exit 1
}

Write-Host ""
Write-Host "Done! Installer: $setupExe" -ForegroundColor Green
Write-Host "  Payload:   $setupDist" -ForegroundColor DarkGray
