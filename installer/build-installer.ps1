# Attyx — Build Windows installer
# Usage: powershell -ExecutionPolicy Bypass -File installer\build-installer.ps1
# Requires: Inno Setup (iscc.exe on PATH or default install location)

param(
    [string]$Version = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$dist = Join-Path $root "installer\dist"
$issFile = Join-Path $root "installer\attyx.iss"

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

# Step 1: Build
Write-Host ">> zig build" -ForegroundColor Yellow
Push-Location $root
zig build
Pop-Location

# Step 2: Copy to dist/
Write-Host ">> Copying to installer\dist\" -ForegroundColor Yellow
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

# Step 3: Find iscc.exe
$iscc = Get-Command iscc.exe -ErrorAction SilentlyContinue
if (-not $iscc) {
    $defaultPaths = @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
        "${env:ProgramFiles(x86)}\Inno Setup 5\ISCC.exe"
    )
    foreach ($p in $defaultPaths) {
        if (Test-Path $p) { $iscc = $p; break }
    }
    if (-not $iscc) {
        Write-Error "Inno Setup not found. Install from https://jrsoftware.org/issetup.html or add iscc.exe to PATH."
        exit 1
    }
} else {
    $iscc = $iscc.Source
}

# Step 4: Compile installer
Write-Host ">> iscc /DMyAppVersion=$Version" -ForegroundColor Yellow
& "$iscc" "/DMyAppVersion=$Version" "$issFile"
if ($LASTEXITCODE -ne 0) {
    Write-Error "Inno Setup compilation failed."
    exit 1
}

$output = Join-Path $root "installer\output\attyx-$Version-setup.exe"
Write-Host ""
Write-Host "Done! Installer: $output" -ForegroundColor Green
