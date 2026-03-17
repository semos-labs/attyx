# test-update-windows.ps1 — Test the Windows auto-updater locally.
#
# Usage:  .\scripts\test-update-windows.ps1
#
# Builds attyx, hosts a fake appcast on localhost, launches attyx pointed
# at it. The update window should appear ~5 seconds after launch.

$ErrorActionPreference = "Stop"
$Port = 8089
$TestVersion = "99.0.0"

# ── Build ──
Write-Host "[1/3] Building..." -ForegroundColor Cyan
zig build 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host "Build failed." -ForegroundColor Red; exit 1 }

$Exe = "zig-out\bin\attyx.exe"
if (-not (Test-Path $Exe)) { Write-Host "No binary at $Exe" -ForegroundColor Red; exit 1 }

# ── Generate test files ──
$Dir = "$env:TEMP\attyx-update-test"
if (Test-Path $Dir) { Remove-Item $Dir -Recurse -Force }
New-Item -ItemType Directory $Dir | Out-Null

Copy-Item $Exe "$Dir\attyx-windows-arm64.exe"
Copy-Item $Exe "$Dir\attyx-windows-x64.exe"

@"
<html><body style="font-family:Segoe UI,sans-serif;padding:16px">
<h3>What's New in $TestVersion</h3>
<ul>
<li>Live window resize during drag</li>
<li>PowerShell profile loading and predictive IntelliSense</li>
<li>Process name tracking in tab titles</li>
<li>Git Bash in shell picker</li>
<li>Registry PATH refresh for new tool installs</li>
</ul>
</body></html>
"@ | Set-Content "$Dir\release-notes.html" -Encoding UTF8

$Size = (Get-Item "$Dir\attyx-windows-arm64.exe").Length
@"
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Attyx</title>
    <item>
      <title>Attyx v$TestVersion</title>
      <sparkle:releaseNotesLink>http://localhost:$Port/release-notes.html</sparkle:releaseNotesLink>
      <enclosure url="http://localhost:$Port/attyx-windows-arm64.exe" os="windows" arch="arm64" sparkle:version="$TestVersion" length="$Size" type="application/octet-stream" />
      <enclosure url="http://localhost:$Port/attyx-windows-x64.exe" os="windows" arch="x86_64" sparkle:version="$TestVersion" length="$Size" type="application/octet-stream" />
    </item>
  </channel>
</rss>
"@ | Set-Content "$Dir\appcast.xml" -Encoding UTF8

Write-Host "[2/3] Test appcast ready (version $TestVersion)" -ForegroundColor Cyan

# ── HTTP server + attyx launch ──
Write-Host "[3/3] Starting server on :$Port and launching attyx..." -ForegroundColor Green
Write-Host "       Update window appears in ~5 seconds." -ForegroundColor DarkGray
Write-Host "       Close attyx to stop." -ForegroundColor DarkGray
Write-Host ""

# Run HTTP server as a background process
$ServerScript = @"
`$l = [System.Net.HttpListener]::new()
`$l.Prefixes.Add('http://localhost:$Port/')
`$l.Start()
while (`$l.IsListening) {
    try {
        `$c = `$l.GetContext()
        `$f = Join-Path '$Dir' `$c.Request.Url.LocalPath.TrimStart('/')
        if (Test-Path `$f) {
            `$b = [IO.File]::ReadAllBytes(`$f)
            `$c.Response.ContentLength64 = `$b.Length
            `$c.Response.OutputStream.Write(`$b, 0, `$b.Length)
        } else { `$c.Response.StatusCode = 404 }
        `$c.Response.Close()
    } catch { break }
}
"@

$Server = Start-Process powershell -ArgumentList "-NoProfile","-Command",$ServerScript -PassThru -WindowStyle Hidden
Start-Sleep 1

try {
    $env:ATTYX_FEED_URL = "http://localhost:$Port/appcast.xml"
    & ".\$Exe"
} finally {
    Stop-Process $Server -ErrorAction SilentlyContinue
    Remove-Item $Dir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Cleaned up." -ForegroundColor DarkGray
}
