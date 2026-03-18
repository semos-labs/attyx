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

# Package base names. Script finds latest .pkg.tar.zst for each.
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
    "gmp"
)

function Find-Package($name, $listing) {
    $pattern = "href=""($([regex]::Escape($name))-[0-9][^""]*-x86_64\.pkg\.tar\.zst)"""
    $matches = [regex]::Matches($listing, $pattern)
    if ($matches.Count -eq 0) { return $null }
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

# --- Download packages in parallel ---
Write-Host "Downloading $($packages.Count) packages in parallel..."
$jobs = @()
foreach ($pkg in $packages) {
    $url = "$MirrorBase/$pkg"
    $localPath = Join-Path $tempDir $pkg
    $jobs += Start-Job -ScriptBlock {
        param($u, $p)
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $u -OutFile $p -UseBasicParsing
    } -ArgumentList $url, $localPath
}
$jobs | Wait-Job | Out-Null
$failed = $jobs | Where-Object { $_.State -eq 'Failed' }
$jobs | Remove-Job
if ($failed) {
    Write-Host "ERROR: Some downloads failed" -ForegroundColor Red
    exit 1
}
Write-Host "  All downloads complete."

# --- Decompress and extract sequentially ---
foreach ($pkg in $packages) {
    $localPath = Join-Path $tempDir $pkg
    $tarPath = $localPath -replace '\.zst$', ''

    Write-Host "  Extracting $pkg ..."
    $ErrorActionPreference = "Continue"
    & $zstdExe -d $localPath -o $tarPath --force 2>$null
    $ErrorActionPreference = "Stop"
    if (-not (Test-Path $tarPath)) {
        Write-Host "ERROR: Failed to decompress $pkg" -ForegroundColor Red
        exit 1
    }
    tar -xf $tarPath -C $extractDir
}

# --- Assemble output sysroot ---
if (Test-Path $OutputDir) { Remove-Item -Recurse -Force $OutputDir }
New-Item -ItemType Directory -Force $OutputDir | Out-Null

$srcDirs = @("usr\bin", "usr\lib\zsh", "usr\share\terminfo", "usr\share\zsh", "etc")
foreach ($rel in $srcDirs) {
    $src = Join-Path $extractDir $rel
    $dst = Join-Path $OutputDir $rel
    if (Test-Path $src) {
        New-Item -ItemType Directory -Force $dst | Out-Null
        Copy-Item -Path "$src\*" -Destination $dst -Recurse -Force
        Write-Host "  Copied $rel"
    }
}

# --- Replace /etc/profile with a minimal version for embedded use ---
# The MSYS2 default profile tries to create /dev/shm, init pacman keyring,
# copy network configs, etc. None of that applies to our bundled sysroot.
$profilePath = Join-Path $OutputDir "etc\profile"
$minimalProfile = @'
# Attyx bundled zsh - minimal /etc/profile
# Replaces MSYS2 default profile (no pacman, no /dev setup, no keyring).

# Basic PATH setup - our sysroot bin dir + inherited Windows PATH.
if [ -n "$MSYS2_PATH_TYPE" ] && [ "$MSYS2_PATH_TYPE" = "inherit" ]; then
    : # PATH already inherited from Windows
fi

# Set a sensible default SHELL if not set.
export SHELL="${SHELL:-/usr/bin/zsh}"

# HOME should already be set by attyx (bundled_shell.zig sets it).
# Fall back to USERPROFILE converted to MSYS path if somehow missing.
if [ -z "$HOME" ]; then
    HOME="$(cygpath -u "$USERPROFILE" 2>/dev/null || echo /)"
    export HOME
fi

# Source global zsh configs if they exist.
if [ -d /etc/profile.d ]; then
    for f in /etc/profile.d/*.sh; do
        [ -r "$f" ] && . "$f"
    done
fi
'@
[System.IO.File]::WriteAllText($profilePath, $minimalProfile, (New-Object System.Text.UTF8Encoding $false))
Write-Host "  Wrote minimal /etc/profile"

# Also write a minimal /etc/zsh/zprofile that just sources /etc/profile.
$zprofilePath = Join-Path $OutputDir "etc\zsh\zprofile"
$minimalZprofile = @'
# Source the main profile.
emulate sh -c 'source /etc/profile'
'@
New-Item -ItemType Directory -Force (Split-Path $zprofilePath) | Out-Null
[System.IO.File]::WriteAllText($zprofilePath, $minimalZprofile, (New-Object System.Text.UTF8Encoding $false))
Write-Host "  Wrote minimal /etc/zsh/zprofile"

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
