# test-update-windows.ps1 — Test the Windows auto-updater locally.
#
# Usage:  .\scripts\test-update-windows.ps1
#
# Builds attyx, hosts a fake appcast on localhost:8089, launches attyx
# pointed at it. Update window should appear ~5 seconds after launch.
# Press Ctrl+C to stop.

$ErrorActionPreference = "Continue"
$Port = 8089
$TestVersion = "99.0.0"

# ── Build ──
Write-Host "[1/3] Building..." -ForegroundColor Cyan
zig build 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    zig build 2>&1
    Write-Host "Build failed." -ForegroundColor Red; exit 1
}

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

Write-Host "[2/3] Test appcast ready (v$TestVersion)" -ForegroundColor Cyan

# ── Launch attyx in background ──
Write-Host "[3/3] Launching attyx + HTTP server on :$Port" -ForegroundColor Green
Write-Host "       Update window appears in ~5 seconds." -ForegroundColor DarkGray
Write-Host "       Press Ctrl+C to stop." -ForegroundColor DarkGray
Write-Host ""

$env:ATTYX_FEED_URL = "http://localhost:$Port/appcast.xml"
$Attyx = Start-Process -FilePath (Resolve-Path $Exe) -PassThru

# ── Run HTTP server inline (foreground) ──
$Listener = [System.Net.HttpListener]::new()
$Listener.Prefixes.Add("http://+:$Port/")
try { $Listener.Start() } catch {
    # Fallback: localhost only (no admin required)
    $Listener = [System.Net.HttpListener]::new()
    $Listener.Prefixes.Add("http://localhost:$Port/")
    $Listener.Start()
}

Write-Host "Server listening on http://localhost:$Port/" -ForegroundColor DarkGray

try {
    while ($Listener.IsListening) {
        $ctx = $Listener.GetContext()
        $path = $ctx.Request.Url.LocalPath.TrimStart('/')
        $file = Join-Path $Dir $path
        Write-Host "  -> $($ctx.Request.HttpMethod) /$path" -ForegroundColor DarkGray
        if (Test-Path $file) {
            $bytes = [System.IO.File]::ReadAllBytes($file)
            $ctx.Response.ContentLength64 = $bytes.Length
            $ctx.Response.StatusCode = 200
            $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        } else {
            $ctx.Response.StatusCode = 404
        }
        $ctx.Response.Close()
    }
} finally {
    $Listener.Stop()
    Stop-Process $Attyx -ErrorAction SilentlyContinue
    Remove-Item $Dir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Cleaned up." -ForegroundColor DarkGray
}
