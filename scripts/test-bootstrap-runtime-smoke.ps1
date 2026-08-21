param(
    [Parameter(Mandatory = $true)][string]$BootstrapExe,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$BootstrapExe = (Resolve-Path -LiteralPath $BootstrapExe).Path
if (-not (Test-Path -LiteralPath $BootstrapExe -PathType Leaf)) {
    throw "Bootstrap smoke executable does not exist: $BootstrapExe"
}

# WebView2 honors WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS. Use an ephemeral CDP
# port so CI can inspect the actual page loaded by the packaged Tauri webview.
# This specifically catches the broken-build failure where a release-mode exe
# was produced with plain `cargo build --release` and still navigated to the
# development URL http://127.0.0.1:5175 instead of embedded frontendDist.
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
$cdpPort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
$listener.Stop()

$smokeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("hermes-bootstrap-smoke-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $smokeRoot | Out-Null

$envNames = @('HERMES_HOME', 'HERMES_SETUP_DEV_REPO_ROOT', 'WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS')
$oldEnv = @{}
foreach ($name in $envNames) {
    $oldEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

$proc = $null
try {
    $env:HERMES_HOME = $smokeRoot
    Remove-Item Env:\HERMES_SETUP_DEV_REPO_ROOT -ErrorAction SilentlyContinue
    $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-address=127.0.0.1 --remote-debugging-port=$cdpPort"

    Write-Host "Launching packaged Bootstrap smoke: $BootstrapExe"
    Write-Host "WebView2 CDP probe port: $cdpPort"
    $proc = Start-Process -FilePath $BootstrapExe -PassThru

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
        $bootstrapLog = Join-Path $smokeRoot 'logs\bootstrap-installer.log'
        if (Test-Path -LiteralPath $bootstrapLog -PathType Leaf) {
            Write-Host '----- bootstrap-installer.log tail -----'
            Get-Content -LiteralPath $bootstrapLog -Tail 120
        }
        throw 'Packaged Bootstrap never exposed a loaded Hermes frontend page.'
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
