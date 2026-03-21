param(
    [string]$Target = "x86_64-windows",
    [string]$Optimize = "ReleaseFast"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
Push-Location $root

try {
    Write-Host "Building attyx ($Target)..."
    zig build "-Doptimize=$Optimize" "-Dtarget=$Target"

    Write-Host "Building installer ($Target)..."
    zig build installer "-Doptimize=$Optimize" "-Dtarget=$Target"

    # Place payload in dist/ next to attyx-setup.exe (fallback path)
    $dist = "zig-out\bin\dist"
    if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
    New-Item -ItemType Directory $dist -Force | Out-Null

    Copy-Item zig-out\bin\attyx.exe "$dist\attyx.exe"
    if (Test-Path zig-out\bin\attyx-uninstall.exe) {
        Copy-Item zig-out\bin\attyx-uninstall.exe "$dist\attyx-uninstall.exe"
    }
    if (Test-Path zig-out\bin\share\msys2) {
        Copy-Item zig-out\bin\share\msys2 "$dist\share\msys2" -Recurse -Force
    }

    Write-Host "Done: zig-out\bin\attyx-setup.exe" -ForegroundColor Green
    Write-Host "Run it directly -- payload is in zig-out\bin\dist"
} finally {
    Pop-Location
}
