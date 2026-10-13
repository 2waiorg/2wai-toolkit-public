# avatar_player_lab launcher.
#
# Usage:
#   .\run.ps1                    # web + local mint proxy auto-started (Mila / Dr. Alman work)
#   .\run.ps1 -Dev               # + dev-mode panels unlocked
#   .\run.ps1 -Android           # Pixel 5a (proxy still starts on this PC for Android to hit)
#   .\run.ps1 -Android -Dev      # both
#   .\run.ps1 -Shared            # force shared toolkit-demo key (skip Key Vault)
#   .\run.ps1 -NoProxy           # skip proxy startup (Mila / Dr. Alman won't render)

param(
  [switch]$Android,
  [switch]$Dev,
  [switch]$Shared,
  [switch]$NoProxy
)

# Proxy is on by default -- flip only when -NoProxy is explicit.
$startProxy = -not $NoProxy

$AZ = "C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd"
# Set TWAI_SK in your shell before running this script (your developer-portal
# sk_test_... key). Example:
#   $env:TWAI_SK = 'sk_test_...'
#   .\run.ps1
$SHARED_KEY = $env:TWAI_SK
if (-not $SHARED_KEY) {
  Write-Error "TWAI_SK not set. Export your sk_test_... key before running."
  exit 1
}
# Default: assume the mint proxy at ../mint_proxy_examples/node (relative to
# this script's parent); override via -ProxyDir if yours lives elsewhere.
$PROXY_DIR = (Resolve-Path "$PSScriptRoot/../mint_proxy_examples/node").Path
$PROXY_PORT = 8787
$WEB_PORT = 5179

function Free-Port {
  param([int]$port)
  try {
    $owners = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if (-not $owners) { return }
    foreach ($o in $owners) {
      try {
        $p = Get-Process -Id $o.OwningProcess -ErrorAction SilentlyContinue
        if ($p) {
          Write-Host "[port $port] killing leftover $($p.ProcessName) PID $($p.Id)" -ForegroundColor Yellow
          Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
      } catch { }
    }
    Start-Sleep -Milliseconds 500
  } catch { }
}

function Get-PersonalKey {
  if (-not (Test-Path $AZ)) {
    Write-Host "[key] az CLI not at expected path -- using shared" -ForegroundColor DarkYellow
    return $null
  }
  Write-Host "[key] querying Key Vault (5s timeout)..." -ForegroundColor Cyan
  # Wrap in background job with hard 5s timeout so slow network / VPN
  # can't hang the whole launcher.
  $job = Start-Job -ScriptBlock {
    param($az)
    & $az keyvault secret show --vault-name twaisecretskv --name twai-api-jim-sk --query value -o tsv 2>$null
    return $LASTEXITCODE
  } -ArgumentList $AZ
  $completed = Wait-Job $job -Timeout 5
  if (-not $completed) {
    Write-Host "[key] Key Vault fetch >5s -- killing + using shared" -ForegroundColor DarkYellow
    Stop-Job $job -ErrorAction SilentlyContinue
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    return $null
  }
  $lines = Receive-Job $job
  $exit = if ($lines -is [array]) { $lines[-1] } else { $lines }
  Remove-Job $job -Force -ErrorAction SilentlyContinue
  # First lines are the actual output; last is the exit code we returned
  $out = ''
  if ($lines -is [array] -and $lines.Count -gt 1) {
    $out = ($lines[0..($lines.Count - 2)] | Out-String).Trim()
  }
  if ($exit -ne 0) {
    Write-Host "[key] Key Vault fetch exit=$exit -- using shared" -ForegroundColor DarkYellow
    return $null
  }
  if ($out.StartsWith('sk_')) {
    return $out
  }
  Write-Host "[key] Key Vault returned unexpected value -- using shared" -ForegroundColor DarkYellow
  return $null
}

Write-Host "===== PHASE 1: resolve sk_ key =====" -ForegroundColor Magenta
# Resolve the sk_ key (used by both direct-api mode AND the proxy env)
$key = ''
$source = ''
if ($Shared) {
  $key = $SHARED_KEY
  $source = 'shared (--Shared flag)'
} else {
  $personal = Get-PersonalKey
  if ($personal) {
    $key = $personal
    $source = 'personal (Key Vault)'
  } else {
    $key = $SHARED_KEY
    $source = 'shared (fallback)'
  }
}
if (-not $key -or -not $key.StartsWith('sk_')) {
  Write-Host "[fatal] no usable sk_ key resolved" -ForegroundColor Red
  exit 1
}
$prefix = $key.Substring(0, [Math]::Min(12, $key.Length))
Write-Host "[key] source: $source" -ForegroundColor Cyan
Write-Host "[key] prefix: $prefix..." -ForegroundColor Cyan

# ---- Optional mint proxy startup ----
Write-Host "===== PHASE 2: mint proxy =====" -ForegroundColor Magenta
$proxyProc = $null
if ($startProxy) {
  if (-not (Test-Path (Join-Path $PROXY_DIR 'server.js'))) {
    Write-Host "[proxy] server.js not found at $PROXY_DIR" -ForegroundColor Red
    exit 1
  }
  # Check if 8787 is already listening
  $portInUse = $false
  try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $iar = $tcp.BeginConnect('127.0.0.1', $PROXY_PORT, $null, $null)
    $portInUse = $iar.AsyncWaitHandle.WaitOne(500) -and $tcp.Connected
    $tcp.Close()
  } catch { }
  if ($portInUse) {
    Write-Host "[proxy] port $PROXY_PORT already listening -- assuming proxy running" -ForegroundColor Yellow
  } else {
    # npm install if node_modules missing
    if (-not (Test-Path (Join-Path $PROXY_DIR 'node_modules'))) {
      Write-Host "[proxy] running npm install ..." -ForegroundColor Yellow
      Push-Location $PROXY_DIR
      npm install 2>&1 | Out-Null
      Pop-Location
    }
    Write-Host "[proxy] launching visible node window on port $PROXY_PORT" -ForegroundColor Green
    # Launch in a NEW PowerShell window so log output is visible + you can
    # see it die if it dies. Kills automatically when you close the window.
    $inner = "`$env:SK_KEY='$key'; `$env:PORT='$PROXY_PORT'; `$env:ALLOWED_ORIGIN='*'; Set-Location '$PROXY_DIR'; node server.js"
    $proxyProc = Start-Process powershell -ArgumentList @(
      '-NoExit',
      '-Command',
      $inner
    ) -PassThru
    # Poll for HTTP readiness (not just TCP open -- Node opens the socket
    # before Express is ready to route)
    Write-Host "[proxy] polling /healthz (max 10s)..." -ForegroundColor Cyan
    $ready = $false
    $i = 0
    for ($i = 0; $i -lt 20; $i++) {
      Start-Sleep -Milliseconds 500
      try {
        $r = Invoke-WebRequest -Uri "http://localhost:$PROXY_PORT/healthz" -TimeoutSec 1 -UseBasicParsing -ErrorAction Stop
        if ($r.StatusCode -eq 200) { $ready = $true; break }
      } catch { }
    }
    if ($ready) {
      $sec = [Math]::Round(($i + 1) * 0.5, 1)
      Write-Host "[proxy] UP after ${sec}s -- /healthz returned 200" -ForegroundColor Green
    } else {
      Write-Host "[proxy] FAILED to reach /healthz in 10s -- check the second PowerShell window" -ForegroundColor Red
      Write-Host "[proxy] Continuing anyway; Mila / Dr. Alman won't work until proxy is up" -ForegroundColor Red
    }
  }
}

Write-Host "===== PHASE 3: launch flutter =====" -ForegroundColor Magenta
# ---- Assemble flutter args ----
$flutterArgs = New-Object System.Collections.ArrayList
if ($Android) {
  [void]$flutterArgs.Add('-d')
  [void]$flutterArgs.Add('1A181JEG501702')
  Write-Host "[target] Android (Pixel 5a)" -ForegroundColor Cyan
} else {
  # Free the web port -- a prior flutter run often leaves the dev
  # server holding 5179, causing SocketException 10048 on relaunch.
  Free-Port -port $WEB_PORT
  # Use web-server (not chrome) target: bulletproof against flutter's
  # "Failed to launch browser after 3 tries" bug caused by stale
  # chrome-device debug ports / user-data-dir conflicts. Serve the
  # app; user opens the URL manually.
  [void]$flutterArgs.Add('-d')
  [void]$flutterArgs.Add('web-server')
  [void]$flutterArgs.Add('--web-port')
  [void]$flutterArgs.Add($WEB_PORT)
  [void]$flutterArgs.Add('--web-hostname')
  [void]$flutterArgs.Add('localhost')
  Write-Host "[target] web-server (port $WEB_PORT)" -ForegroundColor Cyan
  Write-Host "[target] once you see 'lib/main.dart is being served', open:" -ForegroundColor Cyan
  Write-Host "         http://localhost:$WEB_PORT" -ForegroundColor Yellow
}
[void]$flutterArgs.Add("--dart-define=TWAI_SK=$key")
if ($Dev) {
  [void]$flutterArgs.Add('--dart-define=DEV_MODE=1')
  Write-Host "[mode] DEV_MODE on" -ForegroundColor Yellow
} else {
  Write-Host "[mode] public (long-press v0.1 chip 2s to unlock dev)" -ForegroundColor Cyan
}

# ---- CD + launch ----
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

Write-Host "[run] flutter run $($flutterArgs -join ' ' -replace 'TWAI_SK=sk_[a-zA-Z0-9_]+', 'TWAI_SK=<key>')" -ForegroundColor Green
try {
  & flutter run @flutterArgs
} finally {
  if ($proxyProc -and -not $proxyProc.HasExited) {
    Write-Host "[proxy] stopping visible window PID $($proxyProc.Id)" -ForegroundColor Yellow
    Stop-Process -Id $proxyProc.Id -Force -ErrorAction SilentlyContinue
  }
}
