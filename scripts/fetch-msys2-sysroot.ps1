# fetch-msys2-sysroot.ps1
# Downloads a minimal MSYS2 sysroot with zsh for bundling with Attyx.
# No external dependencies required - bootstraps zstd automatically.
# Package versions resolved dynamically from the MSYS2 repo.

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

# --- Resolve package versions from repo listing ---
Write-Host "Fetching package listing from $MirrorBase ..."
$listing = (Invoke-WebRequest -Uri "$MirrorBase/" -UseBasicParsing).Content

# Package base names (without version). Script finds latest .pkg.tar.zst for each.
$packageNames = @(
    "zsh"
    "msys2-runtime"
    "coreutils"
    "ncurses"
    "libreadline"
    "pcre2"
    "libiconv"
    "libintl"
    "bash"
    "filesystem"
    "grep"
    "sed"
    "gawk"
)

function Find-Package($name, $listing) {
    # Match: href="<name>-<version>-x86_64.pkg.tar.zst"
    # Use word boundary after name to avoid partial matches (e.g. "ncurses" vs "libncursesw")
    $pattern = "href=""($([regex]::Escape($name))-[0-9][^""]*-x86_64\.pkg\.tar\.zst)"""
    $matches = [regex]::Matches($listing, $pattern)
    if ($matches.Count -eq 0) { return $null }
    # Return the last match (latest version in directory listing)
    return $matches[$matches.Count - 1].Groups[1].Value
}

$packages = @()
foreach ($name in $packageNames) {
    $pkg = Find-Package $name $listing
    if (-not $pkg) {
        Write-Host "WARNING: Could not find package '$name' in repo - skipping" -ForegroundColor Yellow
        continue
    }
    $packages += $pkg
}

if ($packages.Count -lt 5) {
    Write-Host "ERROR: Too few packages resolved ($($packages.Count)) - check mirror URL" -ForegroundColor Red
    exit 1
}

# --- Download and extract packages ---
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

# --- Debug: show what was extracted ---
Write-Host ""
Write-Host "Extracted directory structure:"
Get-ChildItem -Path $extractDir -Recurse -Name | Where-Object { $_ -like "*zsh*" -or $_ -like "*bin*exe" } | Select-Object -First 20 | ForEach-Object { Write-Host "  $_" }
Write-Host ""

# --- Assemble output sysroot ---
if (Test-Path $OutputDir) { Remove-Item -Recurse -Force $OutputDir }
New-Item -ItemType Directory -Force $OutputDir | Out-Null

$copyDirs = @(
    @("usr\bin",           "usr\bin")
    @("usr\lib\zsh",       "usr\lib\zsh")
    @("usr\share\terminfo","usr\share\terminfo")
    @("usr\share\zsh",     "usr\share\zsh")
    @("etc",               "etc")
)

foreach ($pair in $copyDirs) {
    $src = Join-Path $extractDir $pair[0]
    $dst = Join-Path $OutputDir $pair[1]
    if (Test-Path $src) {
        New-Item -ItemType Directory -Force $dst | Out-Null
        Copy-Item -Path "$src\*" -Destination $dst -Recurse -Force
    }
}

# Debug: show output dir contents
Write-Host "Output directory contents:"
Get-ChildItem -Path $OutputDir -Recurse -Name | Select-Object -First 30 | ForEach-Object { Write-Host "  $_" }
Write-Host ""

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
