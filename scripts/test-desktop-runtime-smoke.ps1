param(
    [Parameter(Mandatory = $true)][string]$TestHome,
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$TestHome = (Resolve-Path -LiteralPath $TestHome).Path
$desktopRoot = Join-Path $TestHome 'hermes-agent\apps\desktop\release\win-unpacked'
$exe = Join-Path $desktopRoot 'Hermes.exe'
$icon = Join-Path $desktopRoot 'resources\icon.ico'
$logPath = Join-Path $TestHome 'logs\desktop.log'
$userData = Join-Path $TestHome 'ci-desktop-smoke-user-data'

foreach ($required in @($exe, $icon)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Packaged Desktop runtime smoke is missing required file: $required"
    }
}
if ((Get-Item -LiteralPath $icon).Length -lt 1024) {
    throw "Packaged Desktop icon looks invalid or empty: $icon"
}
if (Test-Path -LiteralPath $userData) {
    Remove-Item -LiteralPath $userData -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $userData | Out-Null

$beforeLogChars = 0
if (Test-Path -LiteralPath $logPath -PathType Leaf) {
    $beforeLogChars = [System.IO.File]::ReadAllText($logPath).Length
}

# Reserve a loopback port for Chromium CDP, then release it immediately before
# launch. This smoke exercises the exact packaged Desktop installed from the
# offline payload and verifies that its renderer comes from the bundled local
# files and that the managed Hermes backend actually reaches its ready state.
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
$cdpPort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
$listener.Stop()

$envNames = @(
    'HERMES_HOME',
    'HERMES_DESKTOP_USER_DATA_DIR',
    'HERMES_DESKTOP_SKIP_QUIT_CONFIRM'
)
$oldEnv = @{}
foreach ($name in $envNames) {
    $oldEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

$proc = $null
try {
    $env:HERMES_HOME = $TestHome
    $env:HERMES_DESKTOP_USER_DATA_DIR = $userData
    $env:HERMES_DESKTOP_SKIP_QUIT_CONFIRM = '1'

    Write-Host "Launching final packaged Desktop: $exe"
    Write-Host "CDP probe port: $cdpPort"
    $proc = Start-Process -FilePath $exe `
        -WorkingDirectory $desktopRoot `
        -ArgumentList @("--remote-debugging-address=127.0.0.1", "--remote-debugging-port=$cdpPort") `
        -PassThru

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $rendererUrl = $null
    $backendReady = $false
    $lastTargets = @()

    while ([DateTime]::UtcNow -lt $deadline) {
        if ($proc.HasExited) {
            throw "Hermes.exe exited during runtime smoke with code $($proc.ExitCode)."
        }

        try {
            $targets = @(Invoke-RestMethod -Uri "http://127.0.0.1:$cdpPort/json/list" -TimeoutSec 2)
            $lastTargets = $targets
            foreach ($target in $targets) {
                $url = [string]$target.url
                if ([string]::IsNullOrWhiteSpace($url)) { continue }
                if ([string]$target.type -eq 'page' -and $url -match '^file:' -and $url -match 'dist/index\.html') {
                    $rendererUrl = $url
                }
            }
        } catch {
            # CDP starts a little after the Electron process; keep polling.
        }

        if (Test-Path -LiteralPath $logPath -PathType Leaf) {
            $allLog = [System.IO.File]::ReadAllText($logPath)
            $newLog = if ($allLog.Length -gt $beforeLogChars) { $allLog.Substring($beforeLogChars) } else { '' }
            if ($newLog -match 'Renderer failed to load') {
                Write-Host '----- desktop.log smoke tail -----'
                Get-Content -LiteralPath $logPath -Tail 120
                throw 'Packaged Desktop renderer failed to load during runtime smoke.'
            }

            # Current Hermes Desktop launches the headless local backend with
            # `hermes serve`, which announces HERMES_BACKEND_READY. Older
            # dashboard-backed builds announced HERMES_DASHBOARD_READY. Accept
            # either protocol marker so this gate tests readiness rather than a
            # historical implementation detail.
            if ($newLog -match 'HERMES_(?:BACKEND|DASHBOARD)_READY\s+port=\d+') {
                $backendReady = $true
            }
        }

        if ($rendererUrl -and $backendReady) { break }
        Start-Sleep -Milliseconds 500
    }

    if (-not $rendererUrl) {
        Write-Host '----- CDP targets seen -----'
        $lastTargets | Select-Object type, title, url | Format-Table -AutoSize
        if (Test-Path -LiteralPath $logPath) {
            Write-Host '----- desktop.log smoke tail -----'
            Get-Content -LiteralPath $logPath -Tail 120
        }
        throw 'Packaged Desktop never exposed its bundled local file:// renderer target.'
    }
    if (-not $backendReady) {
        if (Test-Path -LiteralPath $logPath) {
            Write-Host '----- desktop.log smoke tail -----'
            Get-Content -LiteralPath $logPath -Tail 160
        }
        throw 'Packaged Desktop renderer loaded, but the local Hermes backend never announced a ready marker.'
    }

    Write-Host "Packaged Desktop renderer loaded from: $rendererUrl"
    Write-Host 'Packaged Desktop local backend announced ready.'
    Write-Host 'Packaged Desktop runtime smoke passed.'
} finally {
    if ($proc -and -not $proc.HasExited) {
        # Kill the whole Electron/backend tree so the following official-updater
        # lifecycle gate never sees a venv/process lock from this smoke test.
        & taskkill.exe /PID $proc.Id /T /F 2>$null | Out-Null
        Start-Sleep -Milliseconds 500
    }
    foreach ($name in $envNames) {
        [Environment]::SetEnvironmentVariable($name, $oldEnv[$name], 'Process')
    }
}
