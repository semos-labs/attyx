# fetch-msys2-sysroot.ps1
# Downloads a minimal MSYS2 sysroot with zsh for bundling with Attyx.
# No external dependencies required - bootstraps zstd automatically.
#
# Usage:  powershell -ExecutionPolicy Bypass -File scripts/fetch-msys2-sysroot.ps1
# Output: share/msys2/ (or -OutputDir)

param(
    [string]$OutputDir = "share\msys2",
    [string]$MirrorBase = "https://repo.msys2.org/msys/x86_64"
)

$ErrorActionPreference = "Stop"

# Skip if sysroot already exists.
$existingZsh = Join-Path $OutputDir "usr\bin\zsh.exe"
if (Test-Path $existingZsh) {
    Write-Host "MSYS2 sysroot already present - skipping download."
    exit 0
}

$tempDir = Join-Path $env:TEMP "attyx-msys2-fetch"
if (Test-Path $tempDir) { Remove-Item -Recurse -Force $tempDir }
New-Item -ItemType Directory -Force $tempDir | Out-Null

$extractDir = Join-Path $tempDir "extract"
New-Item -ItemType Directory -Force $extractDir | Out-Null

# --- Bootstrap zstd if not available ---
$zstdExe = "zstd"
$zstdCmd = Get-Command "zstd" -ErrorAction SilentlyContinue
if (-not $zstdCmd) {
    Write-Host "zstd not found - downloading standalone binary..."
    $zstdVer = "1.5.6"
    $zstdZip = Join-Path $tempDir "zstd.zip"
    $zstdUrl = "https://github.com/facebook/zstd/releases/download/v$zstdVer/zstd-v$zstdVer-win64.zip"
    Invoke-WebRequest -Uri $zstdUrl -OutFile $zstdZip -UseBasicParsing
    Expand-Archive -Path $zstdZip -DestinationPath $tempDir -Force
    $zstdExe = Join-Path $tempDir "zstd-v$zstdVer-win64\zstd.exe"
    if (-not (Test-Path $zstdExe)) {
        Write-Host "ERROR: Failed to bootstrap zstd" -ForegroundColor Red
        exit 1
    }
    Write-Host "  Using $zstdExe"
}

# Minimal package set for zsh to work.
$packages = @(
    "zsh-5.9-3-x86_64.pkg.tar.zst"
    "msys2-runtime-3.5.7-1-x86_64.pkg.tar.zst"
    "coreutils-8.32-5-x86_64.pkg.tar.zst"
    "ncurses-6.5-1-x86_64.pkg.tar.zst"
    "libreadline-8.2.013-1-x86_64.pkg.tar.zst"
    "pcre2-10.44-1-x86_64.pkg.tar.zst"
    "libiconv-1.17-1-x86_64.pkg.tar.zst"
    "libintl-0.22.4-1-x86_64.pkg.tar.zst"
    "bash-5.2.037-1-x86_64.pkg.tar.zst"
    "filesystem-2024.02.25-1-x86_64.pkg.tar.zst"
    "grep-3.11-1-x86_64.pkg.tar.zst"
    "sed-4.9-1-x86_64.pkg.tar.zst"
    "gawk-5.3.1-1-x86_64.pkg.tar.zst"
)

foreach ($pkg in $packages) {
    $url = "$MirrorBase/$pkg"
    $localPath = Join-Path $tempDir $pkg
    $tarPath = $localPath -replace '\.zst$', ''

    Write-Host "Downloading $pkg ..."
    Invoke-WebRequest -Uri $url -OutFile $localPath -UseBasicParsing

    Write-Host "  Decompressing ..."
    $ErrorActionPreference = "Continue"
    & $zstdExe -d $localPath -o $tarPath --force 2>$null
    $ErrorActionPreference = "Stop"
    if (-not (Test-Path $tarPath)) {
        Write-Host "ERROR: Failed to decompress $pkg" -ForegroundColor Red
        exit 1
    }

    Write-Host "  Extracting ..."
    tar -xf $tarPath -C $extractDir
}

# Assemble output sysroot with only needed parts.
if (Test-Path $OutputDir) { Remove-Item -Recurse -Force $OutputDir }
New-Item -ItemType Directory -Force $OutputDir | Out-Null

# usr/bin (executables + DLLs)
$srcBin = Join-Path $extractDir "usr\bin"
$dstBin = Join-Path $OutputDir "usr\bin"
if (Test-Path $srcBin) {
    New-Item -ItemType Directory -Force $dstBin | Out-Null
    Copy-Item -Path "$srcBin\*" -Destination $dstBin -Recurse -Force
}

# usr/lib/zsh (modules)
$srcZshLib = Join-Path $extractDir "usr\lib\zsh"
$dstZshLib = Join-Path $OutputDir "usr\lib\zsh"
if (Test-Path $srcZshLib) {
    New-Item -ItemType Directory -Force $dstZshLib | Out-Null
    Copy-Item -Path "$srcZshLib\*" -Destination $dstZshLib -Recurse -Force
}

# usr/share/terminfo (ncurses needs this)
$srcTerminfo = Join-Path $extractDir "usr\share\terminfo"
$dstTerminfo = Join-Path $OutputDir "usr\share\terminfo"
if (Test-Path $srcTerminfo) {
    New-Item -ItemType Directory -Force $dstTerminfo | Out-Null
    Copy-Item -Path "$srcTerminfo\*" -Destination $dstTerminfo -Recurse -Force
}

# etc/ (profile, zsh default configs)
$srcEtc = Join-Path $extractDir "etc"
$dstEtc = Join-Path $OutputDir "etc"
if (Test-Path $srcEtc) {
    New-Item -ItemType Directory -Force $dstEtc | Out-Null
    Copy-Item -Path "$srcEtc\*" -Destination $dstEtc -Recurse -Force
}

# usr/share/zsh (functions, completions)
$srcZshShare = Join-Path $extractDir "usr\share\zsh"
$dstZshShare = Join-Path $OutputDir "usr\share\zsh"
if (Test-Path $srcZshShare) {
    New-Item -ItemType Directory -Force $dstZshShare | Out-Null
    Copy-Item -Path "$srcZshShare\*" -Destination $dstZshShare -Recurse -Force
}

# Cleanup temp files.
Remove-Item -Recurse -Force $tempDir

# Verify.
$zshExe = Join-Path $OutputDir "usr\bin\zsh.exe"
if (Test-Path $zshExe) {
    $size = (Get-ChildItem -Recurse $OutputDir | Measure-Object -Property Length -Sum).Sum / 1MB
    Write-Host ""
    Write-Host "MSYS2 sysroot ready at: $OutputDir"
    Write-Host "  zsh.exe: $zshExe"
    Write-Host "  Total size: $([math]::Round($size, 1)) MB"
} else {
    Write-Host "ERROR: zsh.exe not found at $zshExe" -ForegroundColor Red
    exit 1
}
