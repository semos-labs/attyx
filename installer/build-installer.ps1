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
Copy-Item (Join-Path $root "zig-out\bin\attyx.exe") $dist
if (Test-Path (Join-Path $root "zig-out\bin\attyx.pdb")) {
    Copy-Item (Join-Path $root "zig-out\bin\attyx.pdb") $dist
}
$sysroot = Join-Path $root "zig-out\bin\share\msys2"
if (Test-Path $sysroot) {
    $destSysroot = Join-Path $dist "share\msys2"
    New-Item -ItemType Directory -Path $destSysroot -Force | Out-Null
    xcopy /E /I /Q "$sysroot" "$destSysroot" | Out-Null
}

# Step 3: Compile custom installer
Write-Host ">> Compiling installer..." -ForegroundColor Yellow
New-Item -ItemType Directory -Path $output -Force | Out-Null
$installerC = Join-Path $root "installer\installer.c"
$installerRc = Join-Path $root "installer\installer.rc"
$setupExe = Join-Path $output "attyx-$Version-setup.exe"

# Use zig cc to compile the installer (works without MSVC)
Push-Location (Join-Path $root "installer")
zig cc $installerC $installerRc `
    -o $setupExe `
    -target x86_64-windows-gnu `
    -lkernel32 -luser32 -lgdi32 -lshell32 -lole32 `
    -ladvapi32 -lshlwapi -luuid `
    "-Wl,--subsystem,windows" `
    -O2
Pop-Location

if (-not (Test-Path $setupExe)) {
    Write-Error "Installer compilation failed."
    exit 1
}

# Step 4: Copy dist/ next to the setup exe (installer expects it)
$setupDist = Join-Path $output "dist"
if (Test-Path $setupDist) { Remove-Item $setupDist -Recurse -Force }
xcopy /E /I /Q "$dist" "$setupDist" | Out-Null

Write-Host ""
Write-Host "Done! Installer: $setupExe" -ForegroundColor Green
Write-Host "  Distribute the entire 'output' folder (setup exe + dist/)." -ForegroundColor DarkGray
