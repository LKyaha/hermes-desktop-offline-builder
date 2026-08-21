param(
    [Parameter(Mandatory = $true)][string]$TestHome,
    [Parameter(Mandatory = $true)][string]$InstalledCommit
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$TestHome = (Resolve-Path -LiteralPath $TestHome).Path
$installRoot = Join-Path $TestHome 'hermes-agent'
$python = Join-Path $installRoot 'venv\Scripts\python.exe'
$desktop = Join-Path $installRoot 'apps\desktop\release\win-unpacked\Hermes.exe'
$updater = Join-Path $installRoot 'scripts\desktop-update\windows.ps1'
$gitExe = Join-Path $TestHome 'git\cmd\git.exe'

foreach ($required in @($python, $desktop, $updater, $gitExe)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Official-update takeover preflight is missing required file: $required"
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $installRoot '.git') -PathType Container)) {
    throw 'Offline install did not leave a real Git checkout for the official updater.'
}

# First prove that a machine which already has an older offline-managed install
# can consume the *new* offline payload in place. The helper turns the freshly
# installed current tree into a synthetic prior-version install, runs every
# current installer stage with networking hard-blocked, and validates user
# state preservation + source backup + runtime/Desktop replacement. Using the
# same test machine then immediately proves the second lifecycle hand-off below:
# current offline install -> official online Desktop updater.
$builderRoot = Split-Path -Parent $PSScriptRoot
$offlineUpgradeTest = Join-Path $PSScriptRoot 'test-offline-to-offline-upgrade.ps1'
$offlineInstallScript = Join-Path $builderRoot 'offline-bundle\offline-root\scripts\install.ps1'
$payloadRoot = Join-Path $builderRoot 'offline-bundle\payload'
foreach ($required in @($offlineUpgradeTest, $offlineInstallScript, (Join-Path $payloadRoot 'manifest.json'))) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Lifecycle compatibility gate is missing offline-upgrade input: $required"
    }
}
Write-Host '===== OFFLINE PACKAGE IN-PLACE UPGRADE GATE ====='
& $offlineUpgradeTest `
    -TestHome $TestHome `
    -OfflineInstallScript $offlineInstallScript `
    -PayloadRoot $payloadRoot `
    -InstalledCommit $InstalledCommit
Write-Host 'Offline package in-place upgrade gate passed.'

# The offline restrictions are deliberately installation-process-only. A real
# user closes the Bootstrap installer and later launches Hermes in a fresh
# process. Reproduce that boundary explicitly before invoking the repo-owned
# official Desktop updater.
foreach ($name in @(
    'HERMES_OFFLINE_PAYLOAD',
    'HERMES_OFFLINE_STRICT',
    'UV_OFFLINE',
    'NPM_CONFIG_OFFLINE',
    'NPM_CONFIG_PREFER_OFFLINE',
    'HTTP_PROXY',
    'HTTPS_PROXY',
    'ALL_PROXY',
    'NO_PROXY'
)) {
    Remove-Item -LiteralPath "Env:\$name" -ErrorAction SilentlyContinue
}

# A GitHub Actions step does not inherit User-PATH registry changes made by a
# child PowerShell process earlier in the same step. A normal newly-launched
# Hermes process does. Put the exact managed locations at the front here so
# the updater sees the same runtime set a real post-install process would see.
$managedPath = @(
    (Join-Path $TestHome 'bin'),
    (Join-Path $TestHome 'node'),
    (Join-Path $TestHome 'git\cmd'),
    (Join-Path $TestHome 'git\bin'),
    (Join-Path $TestHome 'git\usr\bin'),
    (Join-Path $TestHome 'tools\bin'),
    (Join-Path $installRoot 'venv\Scripts')
) | Where-Object { Test-Path -LiteralPath $_ }
$env:Path = (($managedPath -join ';') + ';' + $env:Path)
$env:HERMES_HOME = $TestHome
$env:HERMES_GIT_BASH_PATH = Join-Path $TestHome 'git\bin\bash.exe'
$env:UV_PYTHON_INSTALL_DIR = Join-Path $TestHome 'python'
$env:UV_CACHE_DIR = Join-Path $TestHome 'uv-cache'
$env:UV_TOOL_DIR = Join-Path $TestHome 'uv-tools'
$env:NPM_CONFIG_CACHE = Join-Path $TestHome 'npm-cache'
$env:PLAYWRIGHT_BROWSERS_PATH = Join-Path $TestHome 'ms-playwright'
$env:npm_config_engine_strict = 'false'
$env:CSC_IDENTITY_AUTO_DISCOVERY = 'false'

# Strict-offline knobs must never have leaked into the persistent user
# environment. If they did, the installed app could never follow official
# updates after reboot/login even though this CI process clears its own copy.
foreach ($name in @('HERMES_OFFLINE_PAYLOAD', 'HERMES_OFFLINE_STRICT', 'UV_OFFLINE', 'NPM_CONFIG_OFFLINE')) {
    $persisted = [Environment]::GetEnvironmentVariable($name, 'User')
    if (-not [string]::IsNullOrWhiteSpace($persisted)) {
        throw "Offline-only environment variable leaked into the User environment: $name=$persisted"
    }
}

Push-Location $installRoot
try {
    $beforeHead = (& $gitExe rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $beforeHead) { throw 'Could not resolve installed Hermes HEAD.' }
    if ($beforeHead -ne $InstalledCommit) {
        throw "Offline install HEAD $beforeHead does not match packaged commit $InstalledCommit."
    }

    $origin = (& $gitExe remote get-url origin).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $origin) { throw 'Bundled checkout has no readable origin remote.' }
    if ($origin -notmatch '^https://github\.com/NousResearch/hermes-agent(?:\.git)?/?$') {
        throw "Official update takeover would follow the wrong origin: $origin"
    }
    Write-Host "Official updater origin: $origin"

    # Resolve the target without mutating tracking refs so we can tell whether
    # this run exercised a real code transition or the official no-op path.
    $remoteLine = (& $gitExe ls-remote origin refs/heads/main | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $remoteLine) {
        throw 'Restored-online lifecycle test could not resolve origin/main.'
    }
    $remoteMainBefore = ($remoteLine -split '\s+')[0]
    $updateWasAvailable = ($remoteMainBefore -ne $beforeHead)
    Write-Host "Installed release HEAD: $beforeHead"
    Write-Host "origin/main before update: $remoteMainBefore"
    Write-Host "Real code transition available: $updateWasAvailable"

    # User-state canary outside the managed source tree. The official updater
    # may migrate real configuration, but it must never wipe arbitrary state in
    # HERMES_HOME while updating the managed checkout/runtime.
    $sentinel = Join-Path $TestHome 'official-update-preservation-sentinel.txt'
    $sentinelValue = "offline-builder-update-canary-$([Guid]::NewGuid().ToString('N'))"
    [System.IO.File]::WriteAllText($sentinel, $sentinelValue, [System.Text.UTF8Encoding]::new($false))

    Write-Host '===== OFFICIAL DESKTOP UPDATE TAKEOVER TEST ====='
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $updater `
        -InstallRoot $installRoot `
        -Branch main `
        -DesktopPid 0 `
        -NoUi
    $updateCode = $LASTEXITCODE
    if ($updateCode -ne 0) {
        $log = Join-Path $TestHome 'logs\desktop-update-handoff.log'
        if (Test-Path -LiteralPath $log) {
            Write-Host '----- desktop-update-handoff.log tail -----'
            Get-Content -LiteralPath $log -Tail 200
        }
        throw "Official Windows Desktop updater failed with exit $updateCode."
    }

    $resultPath = Join-Path $TestHome '.hermes-update-result.json'
    if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
        throw 'Official Desktop updater exited successfully but wrote no result record.'
    }
    $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    if (-not $result.ok -or [int]$result.exit_code -ne 0) {
        throw "Official Desktop updater result was not successful: $(Get-Content -LiteralPath $resultPath -Raw)"
    }

    $afterHead = (& $gitExe rev-parse HEAD).Trim()
    $trackingHead = (& $gitExe rev-parse origin/main).Trim()
    $afterBranch = (& $gitExe rev-parse --abbrev-ref HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $afterHead -or -not $trackingHead) {
        throw 'Could not resolve post-update Git state.'
    }
    if ($afterBranch -ne 'main') {
        throw "Official updater left checkout on '$afterBranch' instead of main."
    }
    if ($afterHead -ne $trackingHead) {
        throw "Official updater did not land on origin/main: HEAD=$afterHead origin/main=$trackingHead"
    }
    if ($updateWasAvailable -and $afterHead -eq $beforeHead) {
        throw 'origin/main differed from the packaged release, but the official updater did not move HEAD.'
    }

    if (-not (Test-Path -LiteralPath $desktop -PathType Leaf)) {
        throw 'Official update completed but the Desktop executable is missing.'
    }
    & $python -c 'import dotenv, openai, rich, prompt_toolkit, fastapi, uvicorn'
    if ($LASTEXITCODE -ne 0) { throw 'Post-official-update Python import validation failed.' }

    if (-not (Test-Path -LiteralPath $sentinel -PathType Leaf)) {
        throw 'Official update removed the HERMES_HOME preservation sentinel.'
    }
    $sentinelAfter = [System.IO.File]::ReadAllText($sentinel)
    if ($sentinelAfter -ne $sentinelValue) {
        throw 'Official update modified the HERMES_HOME preservation sentinel.'
    }

    # The canary written by the immediately preceding offline->offline upgrade
    # must survive the subsequent official updater too, proving continuity
    # across both supported upgrade routes in one lifecycle test.
    $offlineUpgradeState = Join-Path $TestHome 'ci-offline-upgrade-user-state\state.json'
    if (-not (Test-Path -LiteralPath $offlineUpgradeState -PathType Leaf)) {
        throw 'Official updater removed state preserved by the offline-to-offline upgrade gate.'
    }

    $originAfter = (& $gitExe remote get-url origin).Trim()
    if ($originAfter -ne $origin) {
        throw "Official updater changed the origin remote unexpectedly: $origin -> $originAfter"
    }

    Write-Host "Official update takeover passed: $beforeHead -> $afterHead"
    if (-not $updateWasAvailable) {
        Write-Host 'origin/main matched the packaged release, so this run exercised the official no-op update path.'
    }
} finally {
    Pop-Location
}
