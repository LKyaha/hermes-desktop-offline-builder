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

$beforeLogLength = 0L
if (Test-Path -LiteralPath $logPath -PathType Leaf) {
    $beforeLogLength = (Get-Item -LiteralPath $logPath).Length
}

# Reserve a loopback port for Chromium CDP, then release it immediately before
# launch. The packaged app is started with an intentionally BROKEN dev-server
# override; a correct production build must ignore it and load file://.../dist/index.html.
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
$cdpPort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
$listener.Stop()
$badDevServer = 'http://127.0.0.1:9'

$envNames = @(
    'HERMES_HOME',
    'HERMES_DESKTOP_USER_DATA_DIR',
    'HERMES_DESKTOP_DEV_SERVER',
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
    $env:HERMES_DESKTOP_DEV_SERVER = $badDevServer
    $env:HERMES_DESKTOP_SKIP_QUIT_CONFIRM = '1'

    Write-Host "Launching final packaged Desktop with poisoned dev-server env: $badDevServer"
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
                if ($url -like "$badDevServer*") {
                    throw "Packaged Hermes.exe honored HERMES_DESKTOP_DEV_SERVER and navigated to $url"
                }
                if ([string]$target.type -eq 'page' -and $url -match '^file:' -and $url -match 'dist/index\.html') {
                    $rendererUrl = $url
                }
            }
        } catch {
            if ($_.Exception.Message -match 'honored HERMES_DESKTOP_DEV_SERVER') { throw }
            # CDP starts a little after the Electron process; keep polling.
        }

        if (Test-Path -LiteralPath $logPath -PathType Leaf) {
            $allLog = [System.IO.File]::ReadAllText($logPath)
            $newLog = if ($allLog.Length -gt $beforeLogLength) { $allLog.Substring([int]$beforeLogLength) } else { '' }
            if ($newLog -match 'Renderer failed to load') {
                Write-Host '----- desktop.log smoke tail -----'
                Get-Content -LiteralPath $logPath -Tail 120
                throw 'Packaged Desktop renderer failed to load during runtime smoke.'
            }
            if ($newLog -match 'HERMES_DASHBOARD_READY') {
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
        throw 'Packaged Desktop never exposed a local file:// renderer target.'
    }
    if (-not $backendReady) {
        if (Test-Path -LiteralPath $logPath) {
            Write-Host '----- desktop.log smoke tail -----'
            Get-Content -LiteralPath $logPath -Tail 160
        }
        throw 'Packaged Desktop renderer loaded, but the local Hermes backend never announced HERMES_DASHBOARD_READY.'
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
