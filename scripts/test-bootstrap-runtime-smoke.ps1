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

# WebView2 honors WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS. Use an ephemeral CDP
# port so CI can inspect the actual page loaded by the packaged Tauri webview.
# Keep the flag exactly to the Microsoft-documented form: remote-debugging-port
# only. This specifically catches the broken-build failure where a release-mode
# exe was produced without Tauri's custom-protocol feature and still navigated
# to http://127.0.0.1:5175 instead of embedded frontendDist.
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
$cdpPort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
$listener.Stop()

$smokeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-bootstrap-smoke-" + [Guid]::NewGuid().ToString('N'))
$webViewUserData = Join-Path $smokeRoot 'webview2-user-data'
New-Item -ItemType Directory -Force -Path $smokeRoot | Out-Null
New-Item -ItemType Directory -Force -Path $webViewUserData | Out-Null

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
try {
    $env:HERMES_HOME = $smokeRoot
    Remove-Item Env:\HERMES_SETUP_DEV_REPO_ROOT -ErrorAction SilentlyContinue
    $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=$cdpPort"
    $env:WEBVIEW2_USER_DATA_FOLDER = $webViewUserData

    Write-Host "Launching packaged Bootstrap smoke: $BootstrapExe"
    Write-Host "WebView2 CDP probe port: $cdpPort"
    Write-Host "WebView2 user data: $webViewUserData"
    Write-Host "WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=$env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS"

    # --repair is an upstream-supported force-setup flag. The smoke home is
    # already fresh, but this makes the intent explicit and prevents a future
    # launcher fast-path from hiding the installer UI during this gate.
    $proc = Start-Process -FilePath $BootstrapExe -ArgumentList '--repair' -PassThru

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $observed = @()
    $goodTarget = $null

    while ([DateTime]::UtcNow -lt $deadline) {
        if ($proc.HasExited) {
            throw "Hermes-Setup.exe exited during frontend smoke with code $($proc.ExitCode)."
        }

        try {
            $targets = @(Invoke-RestMethod -Uri "http://127.0.0.1:$cdpPort/json/list" -TimeoutSec 2)
            $observed = $targets
            foreach ($target in $targets) {
                if ([string]$target.type -ne 'page') { continue }
                $url = [string]$target.url
                $title = [string]$target.title

                if ($url -match '^https?://(?:127\.0\.0\.1|localhost):5175(?:/|$)') {
                    throw "Packaged Bootstrap loaded the Vite development server instead of embedded frontendDist: $url"
                }

                if ($title -eq 'Hermes' -and -not [string]::IsNullOrWhiteSpace($url)) {
                    $goodTarget = $target
                    break
                }
            }
        } catch {
            if ($_.Exception.Message -match 'loaded the Vite development server') { throw }
            # WebView2's remote-debugging endpoint comes up shortly after the
            # native process. Keep polling until the overall deadline.
        }

        if ($goodTarget) { break }
        Start-Sleep -Milliseconds 400
    }

    if (-not $goodTarget) {
        Write-Host '----- WebView2 targets seen -----'
        $observed | Select-Object type, title, url | Format-Table -AutoSize

        Write-Host '----- WebView2 child processes for this smoke -----'
        try {
            Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" |
                Where-Object { [string]$_.CommandLine -like "*$webViewUserData*" } |
                Select-Object ProcessId, ParentProcessId, CommandLine |
                Format-List
        } catch {
            Write-Host "Could not enumerate WebView2 child processes: $($_.Exception.Message)"
        }

        Write-Host '----- CDP port state -----'
        try {
            Get-NetTCPConnection -LocalPort $cdpPort -ErrorAction SilentlyContinue |
                Select-Object LocalAddress, LocalPort, State, OwningProcess |
                Format-Table -AutoSize
        } catch {
            Write-Host "Could not inspect CDP TCP port: $($_.Exception.Message)"
        }

        Write-Host '----- Bootstrap native window -----'
        try {
            $liveProc = Get-Process -Id $proc.Id -ErrorAction Stop
            $liveProc | Select-Object Id, ProcessName, MainWindowTitle, Responding | Format-List
        } catch {
            Write-Host "Could not inspect Bootstrap process window: $($_.Exception.Message)"
        }

        $bootstrapLog = Join-Path $smokeRoot 'logs\bootstrap-installer.log'
        if (Test-Path -LiteralPath $bootstrapLog -PathType Leaf) {
            Write-Host '----- bootstrap-installer.log tail -----'
            Get-Content -LiteralPath $bootstrapLog -Tail 120
        }
        throw 'Packaged Bootstrap never exposed a loaded Hermes frontend page through WebView2 CDP.'
    }

    Write-Host "Bootstrap frontend title: $($goodTarget.title)"
    Write-Host "Bootstrap frontend URL: $($goodTarget.url)"
    Write-Host 'Packaged Bootstrap frontend smoke passed.'
} finally {
    if ($proc -and -not $proc.HasExited) {
        & taskkill.exe /PID $proc.Id /T /F 2>$null | Out-Null
        Start-Sleep -Milliseconds 300
    }
    foreach ($name in $envNames) {
        [Environment]::SetEnvironmentVariable($name, $oldEnv[$name], 'Process')
    }
    if (Test-Path -LiteralPath $smokeRoot) {
        Remove-Item -LiteralPath $smokeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
