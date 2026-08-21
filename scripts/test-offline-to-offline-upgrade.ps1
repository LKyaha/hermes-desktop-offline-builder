param(
    [Parameter(Mandatory = $true)][string]$TestHome,
    [Parameter(Mandatory = $true)][string]$OfflineInstallScript,
    [Parameter(Mandatory = $true)][string]$PayloadRoot,
    [Parameter(Mandatory = $true)][string]$InstalledCommit
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$TestHome = (Resolve-Path -LiteralPath $TestHome).Path
$OfflineInstallScript = (Resolve-Path -LiteralPath $OfflineInstallScript).Path
$PayloadRoot = (Resolve-Path -LiteralPath $PayloadRoot).Path
$installRoot = Join-Path $TestHome 'hermes-agent'
$gitExe = Join-Path $TestHome 'git\cmd\git.exe'
$desktop = Join-Path $installRoot 'apps\desktop\release\win-unpacked\Hermes.exe'
$nodeExe = Join-Path $TestHome 'node\node.exe'
$python = Join-Path $installRoot 'venv\Scripts\python.exe'
$hermes = Join-Path $installRoot 'venv\Scripts\hermes.exe'
$sourceMarker = Join-Path $installRoot '.hermes-offline-source.json'
$runtimeMarker = Join-Path $TestHome '.hermes-offline-runtime.json'

foreach ($required in @($OfflineInstallScript, (Join-Path $PayloadRoot 'manifest.json'), $gitExe, $desktop, $nodeExe, $python, $hermes)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Offline-upgrade preflight is missing required file: $required"
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $installRoot '.git') -PathType Container)) {
    throw 'Offline-upgrade preflight requires a real installed Git checkout.'
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Append-TestByte([string]$Path) {
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    try { $stream.WriteByte(0x7f) } finally { $stream.Dispose() }
}

# The full offline-install gate immediately before this script produced a known
# good current-version install. Record the expected managed artifacts, then turn
# that tree into a synthetic prior offline installation. This exercises the
# actual *upgrade* branches of the current package without building a second
# ~1.5 GB historical payload on every CI run.
$expectedDesktopHash = Get-Sha256 $desktop
$expectedNodeHash = Get-Sha256 $nodeExe

Push-Location $installRoot
try {
    $currentHead = (& $gitExe rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $currentHead -ne $InstalledCommit) {
        throw "Expected freshly installed HEAD $InstalledCommit, got '$currentHead'."
    }

    # Prefer the first parent. The source staging clone carries Git metadata;
    # if this filtered clone needs a missing historical blob, the setup phase is
    # intentionally still online. The actual upgrade below is run with strict
    # offline guards and dead proxies.
    $oldCommit = (& $gitExe rev-parse "$InstalledCommit^" 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $oldCommit) {
        & $gitExe fetch --depth 2 origin $InstalledCommit
        if ($LASTEXITCODE -ne 0) { throw 'Could not fetch enough history to synthesize a prior offline install.' }
        $oldCommit = (& $gitExe rev-parse "$InstalledCommit^" | Out-String).Trim()
    }
    if (-not $oldCommit -or $oldCommit -eq $InstalledCommit) {
        throw 'Could not resolve a distinct previous Hermes commit for offline-upgrade simulation.'
    }

    # Upstream currently contains paths that differ only by letter case. On a
    # case-insensitive Windows filesystem that can make a freshly extracted,
    # otherwise-valid checkout appear dirty before CI has touched it. Forcing
    # this *fixture-only* transition is safe: we are deliberately synthesizing
    # an older install here. Real user modifications are added below and must
    # survive the actual offline upgrade inside its repository safety backup.
    & $gitExe checkout -f --detach $oldCommit
    if ($LASTEXITCODE -ne 0) { throw "Could not park synthetic old install at $oldCommit." }
    $oldHead = (& $gitExe rev-parse HEAD).Trim()
    if ($oldHead -ne $oldCommit) { throw "Synthetic old checkout mismatch: expected $oldCommit, got $oldHead." }
} finally {
    Pop-Location
}

# User state deliberately lives outside the managed source checkout. It must
# survive the source swap, venv recreation, Desktop replacement and all later
# upstream stages byte-for-byte.
$userStateDir = Join-Path $TestHome 'ci-offline-upgrade-user-state'
New-Item -ItemType Directory -Force -Path $userStateDir | Out-Null
$userState = Join-Path $userStateDir 'state.json'
$userStateValue = [ordered]@{
    schema = 1
    canary = "offline-to-offline-$([Guid]::NewGuid().ToString('N'))"
    installed_commit = $oldCommit
} | ConvertTo-Json -Compress
[System.IO.File]::WriteAllText($userState, $userStateValue, [System.Text.UTF8Encoding]::new($false))
$userStateHash = Get-Sha256 $userState

# An untracked source edit should not ride into the new checkout, but the
# repository-stage safety backup must retain it for manual recovery.
$sourceCanary = Join-Path $installRoot 'ci-local-source-edit.txt'
$sourceCanaryValue = "local-source-edit-$([Guid]::NewGuid().ToString('N'))"
[System.IO.File]::WriteAllText($sourceCanary, $sourceCanaryValue, [System.Text.UTF8Encoding]::new($false))

# Make the old Desktop/runtime observably different while keeping the files
# executable. PE loaders ignore trailing bytes; the upgrade must restore the
# exact packaged bytes from desktop-win-x64.tar.gz / managed-runtime.tar.gz.
Append-TestByte $desktop
Append-TestByte $nodeExe
if ((Get-Sha256 $desktop) -eq $expectedDesktopHash) { throw 'Desktop mutation fixture did not change the file hash.' }
if ((Get-Sha256 $nodeExe) -eq $expectedNodeHash) { throw 'Node mutation fixture did not change the file hash.' }

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$oldSourceRecord = [ordered]@{ schema = 1; hermes_commit = $oldCommit; hermes_ref = 'ci-synthetic-prior-offline' } | ConvertTo-Json
[System.IO.File]::WriteAllText($sourceMarker, $oldSourceRecord, $utf8NoBom)
$oldRuntimeRecord = [ordered]@{ schema = 1; hermes_commit = $oldCommit; hermes_ref = 'ci-synthetic-prior-offline'; prepared_at = 'ci-synthetic' } | ConvertTo-Json
[System.IO.File]::WriteAllText($runtimeMarker, $oldRuntimeRecord, $utf8NoBom)

$backupsBefore = @(
    Get-ChildItem -LiteralPath $TestHome -Directory -Filter 'hermes-agent.offline-backup-*' -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName }
)

$savedEnv = @{}
$envNames = @(
    'HERMES_OFFLINE_PAYLOAD', 'HERMES_OFFLINE_STRICT',
    'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY'
)
foreach ($name in $envNames) { $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }

$newBackup = $null
try {
    # From this point until every installer stage completes, network is a hard
    # defect. This proves a newer offline package can upgrade an existing
    # installation without silently falling back to GitHub/PyPI/npm.
    $env:HERMES_OFFLINE_PAYLOAD = $PayloadRoot
    $env:HERMES_OFFLINE_STRICT = '1'
    $env:HTTP_PROXY = 'http://127.0.0.1:9'
    $env:HTTPS_PROXY = 'http://127.0.0.1:9'
    $env:ALL_PROXY = 'http://127.0.0.1:9'
    $env:NO_PROXY = '127.0.0.1,localhost'

    $manifestRaw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $OfflineInstallScript `
        -Manifest -IncludeDesktop -Commit $InstalledCommit -Branch main `
        -HermesHome $TestHome -InstallDir $installRoot
    if ($LASTEXITCODE -ne 0) { throw 'Offline upgrade manifest query failed.' }
    $stageManifest = ($manifestRaw | Out-String | ConvertFrom-Json)

    foreach ($stage in $stageManifest.stages) {
        Write-Host "===== OFFLINE->OFFLINE UPGRADE STAGE: $($stage.name) ====="
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $OfflineInstallScript `
            -Stage $stage.name -IncludeDesktop -NonInteractive -Json `
            -Commit $InstalledCommit -Branch main `
            -HermesHome $TestHome -InstallDir $installRoot
        if ($LASTEXITCODE -ne 0) { throw "Offline-to-offline upgrade stage failed: $($stage.name)" }

        if ($stage.name -eq 'repository') {
            $backupsNow = @(Get-ChildItem -LiteralPath $TestHome -Directory -Filter 'hermes-agent.offline-backup-*' -ErrorAction SilentlyContinue)
            $newOnes = @($backupsNow | Where-Object { $backupsBefore -notcontains $_.FullName })
            if ($newOnes.Count -ne 1) {
                throw "Repository upgrade should create exactly one safety backup; found $($newOnes.Count)."
            }
            $newBackup = $newOnes[0].FullName
            if (-not (Test-Path -LiteralPath (Join-Path $newBackup '.git') -PathType Container)) {
                throw "Safety backup lost Git metadata: $newBackup"
            }
            # Use the managed Git outside the source tree; the backup does not
            # itself contain a Git executable.
            Push-Location $newBackup
            try {
                $backupHead = (& $gitExe rev-parse HEAD).Trim()
            } finally { Pop-Location }
            if ($backupHead -ne $oldCommit) {
                throw "Safety backup HEAD mismatch: expected $oldCommit, got $backupHead."
            }
            $backupCanary = Join-Path $newBackup 'ci-local-source-edit.txt'
            if (-not (Test-Path -LiteralPath $backupCanary -PathType Leaf)) {
                throw 'Safety backup did not preserve the local source edit canary.'
            }
            if ([System.IO.File]::ReadAllText($backupCanary) -ne $sourceCanaryValue) {
                throw 'Safety backup modified the local source edit canary.'
            }

            # The production backup remains intact. CI only discards bulky,
            # reproducible build/runtime directories *inside the test backup*
            # after proving the backup exists, otherwise creating the new venv
            # and node_modules can exceed the hosted runner disk budget.
            foreach ($rel in @(
                'venv', 'node_modules', 'apps\desktop\node_modules',
                'apps\desktop\release', 'ui-tui\node_modules', 'web\node_modules'
            )) {
                $p = Join-Path $newBackup $rel
                if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }
    }
} finally {
    foreach ($name in $envNames) {
        $old = $savedEnv[$name]
        if ($null -eq $old) { Remove-Item -LiteralPath "Env:\$name" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($name, $old, 'Process') }
    }
}

if (-not $newBackup -or -not (Test-Path -LiteralPath $newBackup -PathType Container)) {
    throw 'Offline-to-offline upgrade completed without retaining its safety backup.'
}

Push-Location $installRoot
try {
    $afterHead = (& $gitExe rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $afterHead -ne $InstalledCommit) {
        throw "Offline upgrade did not land on packaged commit: expected $InstalledCommit, got '$afterHead'."
    }
    $origin = (& $gitExe remote get-url origin).Trim()
    if ($origin -notmatch '^https://github\.com/NousResearch/hermes-agent(?:\.git)?/?$') {
        throw "Offline upgrade changed the official origin unexpectedly: $origin"
    }
} finally { Pop-Location }

if (-not (Test-Path -LiteralPath $userState -PathType Leaf) -or (Get-Sha256 $userState) -ne $userStateHash) {
    throw 'Offline-to-offline upgrade did not preserve the HERMES_HOME user-state canary byte-for-byte.'
}
if ((Get-Sha256 $desktop) -ne $expectedDesktopHash) {
    throw 'Offline-to-offline upgrade did not replace the old Desktop with the packaged Desktop bytes.'
}
if ((Get-Sha256 $nodeExe) -ne $expectedNodeHash) {
    throw 'Offline-to-offline upgrade did not refresh the managed Node runtime from the packaged runtime.'
}
if (Test-Path -LiteralPath (Join-Path $installRoot 'ci-local-source-edit.txt')) {
    throw 'Old untracked source edit leaked into the fresh managed checkout instead of remaining only in the safety backup.'
}

$sourceRecord = Get-Content -LiteralPath $sourceMarker -Raw | ConvertFrom-Json
$runtimeRecord = Get-Content -LiteralPath $runtimeMarker -Raw | ConvertFrom-Json
if ($sourceRecord.hermes_commit -ne $InstalledCommit) {
    throw "Source marker was not advanced to packaged commit $InstalledCommit."
}
if ($runtimeRecord.hermes_commit -ne $InstalledCommit) {
    throw "Runtime marker was not advanced to packaged commit $InstalledCommit."
}

foreach ($required in @($desktop, $nodeExe, $python, $hermes, (Join-Path $TestHome 'bin\browser-use.exe'), (Join-Path $TestHome 'tools\bin\cua-driver.exe'))) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Offline-to-offline upgrade is missing required post-upgrade file: $required"
    }
}
& $python -c 'import dotenv, openai, rich, prompt_toolkit, fastapi, uvicorn, onnxruntime, faster_whisper, sounddevice, openwakeword'
if ($LASTEXITCODE -ne 0) { throw 'Offline-to-offline upgrade Python/voice import validation failed.' }

$camofox = Join-Path $TestHome 'node\node_modules\@askjo\camofox-browser\package.json'
if (-not (Test-Path -LiteralPath $camofox -PathType Leaf)) {
    throw 'Offline-to-offline upgrade lost the managed Camofox browser server.'
}
$playwrightBrowser = Get-ChildItem -LiteralPath (Join-Path $TestHome 'ms-playwright') -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -in @('chrome.exe', 'headless_shell.exe') } | Select-Object -First 1
if (-not $playwrightBrowser) { throw 'Offline-to-offline upgrade lost the bundled Playwright Chromium runtime.' }

Write-Host "Offline-to-offline upgrade gate passed: $oldCommit -> $InstalledCommit"
Write-Host "Safety backup retained at: $newBackup"
