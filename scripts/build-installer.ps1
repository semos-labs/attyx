param(
    [string]$Target = "x86_64-windows",
    [string]$Optimize = "ReleaseFast"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
Push-Location $root

try {
    Write-Host "Building attyx ($Target)..."
    zig build -Doptimize=$Optimize -Dtarget=$Target

    Write-Host "Building installer ($Target)..."
    zig build installer -Doptimize=$Optimize -Dtarget=$Target

    # Assemble payload
    $staging = "build-staging"
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
    New-Item -ItemType Directory $staging -Force | Out-Null

    Copy-Item zig-out/bin/attyx.exe "$staging/attyx.exe"
    if (Test-Path zig-out/bin/attyx-uninstall.exe) {
        Copy-Item zig-out/bin/attyx-uninstall.exe "$staging/attyx-uninstall.exe"
    }
    if (Test-Path zig-out/bin/share/msys2) {
        Copy-Item zig-out/bin/share/msys2 "$staging/share/msys2" -Recurse -Force
    }

    # Create payload zip
    Write-Host "Creating payload zip..."
    $zipPath = "build-staging-payload.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath }
    Compress-Archive -Path "$staging/*" -DestinationPath $zipPath

    # Concatenate: setup exe + payload zip = self-extracting installer
    $arch = if ($Target -match "aarch64") { "arm64" } else { "x64" }
    $output = "attyx-windows-$arch-setup.exe"
    Write-Host "Assembling $output..."
    cmd /c "copy /b zig-out\bin\attyx-setup.exe + $zipPath $output" | Out-Null

    # Cleanup
    Remove-Item $staging -Recurse -Force
    Remove-Item $zipPath

    $size = [math]::Round((Get-Item $output).Length / 1MB, 1)
    Write-Host "Done: $output (${size} MB)" -ForegroundColor Green
} finally {
    Pop-Location
}
