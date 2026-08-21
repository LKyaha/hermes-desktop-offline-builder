param(
    [Parameter(Mandatory = $true)][string]$BootstrapExe,
    [int]$TimeoutSeconds = 45
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$BootstrapExe = (Resolve-Path -LiteralPath $BootstrapExe).Path
if (-not (Test-Path -LiteralPath $BootstrapExe -PathType Leaf)) {
    throw "Bootstrap smoke executable does not exist: $BootstrapExe"
}

# This gate targets the exact regression that made the first offline installer
# unusable: a Cargo --release build without Tauri's custom-protocol feature
# still navigated to build.devUrl (http://127.0.0.1:5175) instead of the
# embedded frontendDist. WebView2 remote-debugging flags are intentionally not
# used here: GitHub-hosted Windows runners can ignore process-scoped browser
# flags for high-integrity hosts, and the runner does not grant HKLM policy
# writes reliably. Instead, occupy the upstream devUrl with a local canary HTTP
# server. A broken dev-mode Bootstrap must contact that canary; a production
# Bootstrap must never do so.
$devHost = '127.0.0.1'
$devPort = 5175
$smokeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-bootstrap-smoke-" + [Guid]::NewGuid().ToString('N'))
$webViewUserData = Join-Path $smokeRoot 'webview2-user-data'
$canaryLog = Join-Path $smokeRoot 'dev-url-canary.log'
$canaryReady = Join-Path $smokeRoot 'dev-url-canary.ready'
New-Item -ItemType Directory -Force -Path $smokeRoot, $webViewUserData | Out-Null

$envNames = @(
    'HERMES_HOME',
    'HERMES_SETUP_DEV_REPO_ROOT',
    'WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS',
    'WEBVIEW2_USER_DATA_FOLDER'
)
$oldEnv = @{}
foreach ($name in $envNames) {
    $oldEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

$proc = $null
$canaryJob = $null
try {
    # Fail closed if some unrelated process already owns the exact upstream
    # dev-server port. Otherwise the test could miss a real dev-mode request.
    try {
        $existingListener = @(Get-NetTCPConnection -LocalPort $devPort -State Listen -ErrorAction SilentlyContinue)
        if ($existingListener.Count -gt 0) {
            throw "Bootstrap smoke cannot reserve $devHost`:$devPort because another process is already listening."
        }
    } catch {
        if ($_.Exception.Message -match 'cannot reserve') { throw }
        # Get-NetTCPConnection can be unavailable on stripped-down local images;
        # the TcpListener bind below remains authoritative.
    }

    $canaryJob = Start-Job -ArgumentList $canaryLog, $canaryReady, $devHost, $devPort -ScriptBlock {
        param($LogPath, $ReadyPath, $HostAddress, $Port)
        $ErrorActionPreference = 'Stop'
        $listener = [System.Net.Sockets.TcpListener]::new(
            [System.Net.IPAddress]::Parse($HostAddress),
            [int]$Port
        )
        try {
            $listener.Start()
            [System.IO.File]::WriteAllText($ReadyPath, 'ready', [System.Text.UTF8Encoding]::new($false))

            while ($true) {
                if (-not $listener.Pending()) {
                    Start-Sleep -Milliseconds 50
                    continue
                }

                $client = $listener.AcceptTcpClient()
                try {
                    $requestLine = '<tcp-connect>'
                    $stream = $client.GetStream()
                    $stream.ReadTimeout = 1200
                    $buffer = New-Object byte[] 4096
                    try {
                        $read = $stream.Read($buffer, 0, $buffer.Length)
                        if ($read -gt 0) {
                            $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
                            $firstLine = ($text -split "`r?`n", 2)[0]
                            if (-not [string]::IsNullOrWhiteSpace($firstLine)) {
                                $requestLine = $firstLine
                            }
                        }
                    } catch {
                        # A TCP connection alone is already enough to prove the
                        # packaged app tried to reach its development server.
                    }

                    $entry = "{0}`t{1}" -f [DateTime]::UtcNow.ToString('o'), $requestLine
                    [System.IO.File]::AppendAllText($LogPath, $entry + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))

                    $body = '<!doctype html><html><head><title>HERMES_BOOTSTRAP_DEV_URL_CANARY</title></head><body>dev URL canary</body></html>'
                    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
                    $headers = "HTTP/1.1 200 OK`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
                    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($headers)
                    try {
                        $stream.Write($headerBytes, 0, $headerBytes.Length)
                        $stream.Write($bodyBytes, 0, $bodyBytes.Length)
                        $stream.Flush()
                    } catch {
                        # The request marker was already persisted above.
                    }
                } finally {
                    $client.Dispose()
                }
            }
        } finally {
            $listener.Stop()
        }
    }

    $readyDeadline = [DateTime]::UtcNow.AddSeconds(8)
    while (-not (Test-Path -LiteralPath $canaryReady -PathType Leaf) -and [DateTime]::UtcNow -lt $readyDeadline) {
        if ($canaryJob.State -in @('Completed', 'Failed', 'Stopped')) {
            $jobText = (Receive-Job -Job $canaryJob -Keep -ErrorAction SilentlyContinue | Out-String).Trim()
            throw "Bootstrap devUrl canary server stopped before becoming ready. $jobText"
        }
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -LiteralPath $canaryReady -PathType Leaf)) {
        throw "Bootstrap devUrl canary server did not bind $devHost`:$devPort in time."
    }

    $env:HERMES_HOME = $smokeRoot
    Remove-Item Env:\HERMES_SETUP_DEV_REPO_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:\WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS -ErrorAction SilentlyContinue
    $env:WEBVIEW2_USER_DATA_FOLDER = $webViewUserData

    Write-Host "Launching packaged Bootstrap smoke: $BootstrapExe"
    Write-Host "Development-URL canary: http://$devHost`:$devPort/"
    Write-Host "WebView2 user data: $webViewUserData"

    # --repair is an upstream-supported force-setup flag. It prevents any
    # future installed-state fast path from hiding the installer UI in this gate.
    $proc = Start-Process -FilePath $BootstrapExe -ArgumentList '--repair' -PassThru

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $healthySamples = 0
    $lastWindow = $null
    $lastRenderer = @()

    while ([DateTime]::UtcNow -lt $deadline) {
        if ($proc.HasExited) {
            throw "Hermes-Setup.exe exited during production runtime smoke with code $($proc.ExitCode)."
        }

        if (Test-Path -LiteralPath $canaryLog -PathType Leaf) {
            $hits = @(Get-Content -LiteralPath $canaryLog -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.Trim() })
            if ($hits.Count -gt 0) {
                throw "Packaged Bootstrap contacted the Vite development URL http://$devHost`:$devPort instead of using embedded frontendDist. Canary hit(s): $($hits -join '; ')"
            }
        }

        try {
            $lastWindow = Get-Process -Id $proc.Id -ErrorAction Stop
        } catch {
            $lastWindow = $null
        }

        try {
            $lastRenderer = @(
                Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction Stop |
                    Where-Object {
                        [string]$_.CommandLine -like "*$webViewUserData*" -and
                        [string]$_.CommandLine -match '(?:^|\s)--type=renderer(?:\s|$)'
                    }
            )
        } catch {
            $lastRenderer = @()
        }

        $windowHealthy = $lastWindow -and $lastWindow.Responding -and $lastWindow.MainWindowTitle -eq 'Hermes'
        $rendererHealthy = $lastRenderer.Count -gt 0
        if ($windowHealthy -and $rendererHealthy) {
            $healthySamples++
            # Require the native window + renderer to remain healthy for several
            # consecutive polls, not merely flash into existence once.
            if ($healthySamples -ge 6) { break }
        } else {
            $healthySamples = 0
        }

        Start-Sleep -Milliseconds 400
    }

    if ($healthySamples -lt 6) {
        Write-Host '----- Bootstrap native window -----'
        if ($lastWindow) {
            $lastWindow | Select-Object Id, ProcessName, MainWindowTitle, Responding | Format-List
        } else {
            Write-Host '<not available>'
        }

        Write-Host '----- WebView2 renderer processes for this smoke -----'
        $lastRenderer | Select-Object ProcessId, ParentProcessId, CommandLine | Format-List

        $bootstrapLog = Join-Path $smokeRoot 'logs\bootstrap-installer.log'
        if (Test-Path -LiteralPath $bootstrapLog -PathType Leaf) {
            Write-Host '----- bootstrap-installer.log tail -----'
            Get-Content -LiteralPath $bootstrapLog -Tail 120
        }
        throw 'Packaged Bootstrap did not sustain a responsive Hermes window with a WebView2 renderer.'
    }

    # Give an incorrectly delayed navigation a final chance to hit the exact
    # devUrl before declaring the production-mode gate healthy.
    Start-Sleep -Seconds 3
    $hits = @()
    if (Test-Path -LiteralPath $canaryLog -PathType Leaf) {
        $hits = @(Get-Content -LiteralPath $canaryLog -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.Trim() })
    }
    if ($hits.Count -gt 0) {
        throw "Packaged Bootstrap contacted the Vite development URL http://$devHost`:$devPort instead of using embedded frontendDist. Canary hit(s): $($hits -join '; ')"
    }

    $bootstrapLog = Join-Path $smokeRoot 'logs\bootstrap-installer.log'
    if (-not (Test-Path -LiteralPath $bootstrapLog -PathType Leaf)) {
        throw 'Packaged Bootstrap stayed open but did not create bootstrap-installer.log.'
    }
    $bootstrapLogText = Get-Content -LiteralPath $bootstrapLog -Raw
    if ($bootstrapLogText -notmatch 'Hermes installer starting mode=') {
        throw 'Packaged Bootstrap log did not contain the expected installer startup marker.'
    }

    Write-Host "Bootstrap native window: $($lastWindow.MainWindowTitle) (Responding=$($lastWindow.Responding))"
    Write-Host "Bootstrap WebView2 renderer count: $($lastRenderer.Count)"
    Write-Host 'Bootstrap devUrl canary hits: 0'
    Write-Host 'Packaged Bootstrap frontend smoke passed.'
} finally {
    if ($proc -and -not $proc.HasExited) {
        & taskkill.exe /PID $proc.Id /T /F 2>$null | Out-Null
        Start-Sleep -Milliseconds 300
    }

    if ($canaryJob) {
        Stop-Job -Job $canaryJob -ErrorAction SilentlyContinue
        Remove-Job -Job $canaryJob -Force -ErrorAction SilentlyContinue
    }

    foreach ($name in $envNames) {
        [Environment]::SetEnvironmentVariable($name, $oldEnv[$name], 'Process')
    }
    if (Test-Path -LiteralPath $smokeRoot) {
        Remove-Item -LiteralPath $smokeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
