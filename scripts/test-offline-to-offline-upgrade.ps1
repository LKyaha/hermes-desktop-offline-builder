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
$transactionScript = Join-Path $PSScriptRoot 'offline-transaction.ps1'
$installRoot = Join-Path $TestHome 'hermes-agent'
$gitExe = Join-Path $TestHome 'git\cmd\git.exe'
$desktop = Join-Path $installRoot 'apps\desktop\release\win-unpacked\Hermes.exe'
$nodeExe = Join-Path $TestHome 'node\node.exe'
$python = Join-Path $installRoot 'venv\Scripts\python.exe'
$hermes = Join-Path $installRoot 'venv\Scripts\hermes.exe'
$sourceMarker = Join-Path $installRoot '.hermes-offline-source.json'
$runtimeMarker = Join-Path $TestHome '.hermes-offline-runtime.json'
$transactionPath = Join-Path $TestHome '.hermes-offline-update-transaction.json'
$rollbackRoot = Join-Path $TestHome '.hermes-offline-rollback'

foreach ($required in @($OfflineInstallScript, $transactionScript, (Join-Path $PayloadRoot 'manifest.json'), $gitExe, $desktop, $nodeExe, $python, $hermes)) {
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

$expectedDesktopHash = Get-Sha256 $desktop
$expectedNodeHash = Get-Sha256 $nodeExe

# Turn the freshly installed current tree into a synthetic prior offline
# version. This is fixture-only; the actual upgrade below is fully offline.
Push-Location $installRoot
try {
    $currentHead = (& $gitExe rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $currentHead -ne $InstalledCommit) {
        throw "Expected freshly installed HEAD $InstalledCommit, got '$currentHead'."
    }
    $oldCommit = (& $gitExe rev-parse "$InstalledCommit^" 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $oldCommit) {
        & $gitExe fetch --depth 2 origin $InstalledCommit
        if ($LASTEXITCODE -ne 0) { throw 'Could not fetch enough history to synthesize a prior offline install.' }
        $oldCommit = (& $gitExe rev-parse "$InstalledCommit^" | Out-String).Trim()
    }
    if (-not $oldCommit -or $oldCommit -eq $InstalledCommit) {
        throw 'Could not resolve a distinct previous Hermes commit for offline-upgrade simulation.'
    }
    & $gitExe checkout -f --detach $oldCommit
    if ($LASTEXITCODE -ne 0) { throw "Could not park synthetic old install at $oldCommit." }
    if ((& $gitExe rev-parse HEAD).Trim() -ne $oldCommit) { throw 'Synthetic old checkout did not land on the requested prior commit.' }
} finally { Pop-Location }

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

$sourceCanary = Join-Path $installRoot 'ci-local-source-edit.txt'
$sourceCanaryValue = "local-source-edit-$([Guid]::NewGuid().ToString('N'))"
[System.IO.File]::WriteAllText($sourceCanary, $sourceCanaryValue, [System.Text.UTF8Encoding]::new($false))

Append-TestByte $desktop
Append-TestByte $nodeExe
if ((Get-Sha256 $desktop) -eq $expectedDesktopHash) { throw 'Desktop mutation fixture did not change the file hash.' }
if ((Get-Sha256 $nodeExe) -eq $expectedNodeHash) { throw 'Node mutation fixture did not change the file hash.' }

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($sourceMarker, ([ordered]@{ schema = 1; hermes_commit = $oldCommit; hermes_ref = 'ci-synthetic-prior-offline' } | ConvertTo-Json), $utf8NoBom)
[System.IO.File]::WriteAllText($runtimeMarker, ([ordered]@{ schema = 1; hermes_commit = $oldCommit; hermes_ref = 'ci-synthetic-prior-offline'; prepared_at = 'ci-synthetic' } | ConvertTo-Json), $utf8NoBom)

# The production wrapper does this before launching official Bootstrap. Same-
# volume Move-Item operations stage the old managed bytes without copying them.
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $transactionScript -Mode Begin -HermesHome $TestHome -InstallDir $installRoot
if ($LASTEXITCODE -ne 0) { throw 'Could not begin offline upgrade transaction.' }
if (-not (Test-Path -LiteralPath $transactionPath -PathType Leaf) -or -not (Test-Path -LiteralPath $rollbackRoot -PathType Container)) {
    throw 'Existing install was not protected by an active offline upgrade transaction.'
}
if (Test-Path -LiteralPath $installRoot) { throw 'Begin transaction did not move the old managed checkout out of the live install path.' }

$txn = Get-Content -LiteralPath $transactionPath -Raw | ConvertFrom-Json
if ($txn.state -ne 'active') { throw "Expected active transaction, got '$($txn.state)'." }
$oldInstallEntry = @($txn.entries) | Where-Object { [string]$_.source -eq $installRoot } | Select-Object -First 1
if (-not $oldInstallEntry) { throw 'Transaction did not capture the previous Hermes checkout.' }
$oldInstallRollback = [string]$oldInstallEntry.rollback
$rollbackCanary = Join-Path $oldInstallRollback 'ci-local-source-edit.txt'
if (-not (Test-Path -LiteralPath $rollbackCanary -PathType Leaf) -or [System.IO.File]::ReadAllText($rollbackCanary) -ne $sourceCanaryValue) {
    throw 'Temporary rollback data did not preserve the old managed checkout exactly.'
}

# Hosted runners are space-constrained. After proving the real rollback tree
# exists, discard only bulky reproducible directories inside this CI rollback
# fixture. Production transactions retain everything until Commit/Rollback.
foreach ($rel in @('venv', 'node_modules', 'apps\desktop\node_modules', 'apps\desktop\release', 'ui-tui\node_modules', 'web\node_modules')) {
    $p = Join-Path $oldInstallRollback $rel
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
}

$savedEnv = @{}
$envNames = @('HERMES_OFFLINE_PAYLOAD', 'HERMES_OFFLINE_STRICT', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY')
foreach ($name in $envNames) { $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }

try {
    $env:HERMES_OFFLINE_PAYLOAD = $PayloadRoot
    $env:HERMES_OFFLINE_STRICT = '1'
    $env:HTTP_PROXY = 'http://127.0.0.1:9'
    $env:HTTPS_PROXY = 'http://127.0.0.1:9'
    $env:ALL_PROXY = 'http://127.0.0.1:9'
    $env:NO_PROXY = '127.0.0.1,localhost'

    $manifestRaw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $OfflineInstallScript `
        -Manifest -IncludeDesktop -Commit $InstalledCommit -Branch main -HermesHome $TestHome -InstallDir $installRoot
    if ($LASTEXITCODE -ne 0) { throw 'Offline upgrade manifest query failed.' }
    $stageManifest = ($manifestRaw | Out-String | ConvertFrom-Json)

    foreach ($stage in $stageManifest.stages) {
        Write-Host "===== TRANSACTIONAL OFFLINE->OFFLINE STAGE: $($stage.name) ====="
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $OfflineInstallScript `
            -Stage $stage.name -IncludeDesktop -NonInteractive -Json `
            -Commit $InstalledCommit -Branch main -HermesHome $TestHome -InstallDir $installRoot
        if ($LASTEXITCODE -ne 0) { throw "Offline-to-offline upgrade stage failed: $($stage.name)" }
    }
} catch {
    # Mirror the outer wrapper: any terminal Bootstrap failure rolls the whole
    # managed installation back before surfacing the error.
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $transactionScript -Mode Rollback -HermesHome $TestHome -InstallDir $installRoot
    throw
} finally {
    foreach ($name in $envNames) {
        $old = $savedEnv[$name]
        if ($null -eq $old) { Remove-Item -LiteralPath "Env:\$name" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($name, $old, 'Process') }
    }
}

Push-Location $installRoot
try {
    $afterHead = (& (Join-Path $TestHome 'git\cmd\git.exe') rev-parse HEAD).Trim()
    if ($afterHead -ne $InstalledCommit) { throw "Offline upgrade did not land on packaged commit: $afterHead" }
    $origin = (& (Join-Path $TestHome 'git\cmd\git.exe') remote get-url origin).Trim()
    if ($origin -notmatch '^https://github\.com/NousResearch/hermes-agent(?:\.git)?/?$') { throw "Offline upgrade changed official origin: $origin" }
    $trackedDirty = @(& (Join-Path $TestHome 'git\cmd\git.exe') status --porcelain --untracked-files=no 2>$null | Where-Object { $_ -and $_.ToString().Trim() })
    if ($trackedDirty.Count -ne 0) { throw "Packaged checkout is tracked-dirty before official updater handoff: $($trackedDirty -join '; ')" }
} finally { Pop-Location }

if (-not (Test-Path -LiteralPath $userState -PathType Leaf) -or (Get-Sha256 $userState) -ne $userStateHash) {
    throw 'Offline-to-offline upgrade did not preserve HERMES_HOME user state byte-for-byte.'
}
if ((Get-Sha256 $desktop) -ne $expectedDesktopHash) { throw 'Offline upgrade did not restore packaged Desktop bytes.' }
if ((Get-Sha256 $nodeExe) -ne $expectedNodeHash) { throw 'Offline upgrade did not restore packaged managed Node bytes.' }
if (Test-Path -LiteralPath (Join-Path $installRoot 'ci-local-source-edit.txt')) {
    throw 'Old managed-checkout local edit leaked into the fresh packaged checkout.'
}

$sourceRecord = Get-Content -LiteralPath $sourceMarker -Raw | ConvertFrom-Json
$runtimeRecord = Get-Content -LiteralPath $runtimeMarker -Raw | ConvertFrom-Json
if ($sourceRecord.hermes_commit -ne $InstalledCommit -or $runtimeRecord.hermes_commit -ne $InstalledCommit) {
    throw 'Offline source/runtime version markers were not advanced to the packaged commit.'
}

foreach ($required in @($desktop, $nodeExe, $python, $hermes, (Join-Path $TestHome 'bin\browser-use.exe'), (Join-Path $TestHome 'tools\bin\cua-driver.exe'))) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Offline upgrade is missing required file: $required" }
}
& $python -c 'import dotenv, openai, rich, prompt_toolkit, fastapi, uvicorn, onnxruntime, faster_whisper, sounddevice, openwakeword'
if ($LASTEXITCODE -ne 0) { throw 'Offline-to-offline upgrade Python/voice validation failed.' }

$camofox = Join-Path $TestHome 'node\node_modules\@askjo\camofox-browser\package.json'
if (-not (Test-Path -LiteralPath $camofox -PathType Leaf)) { throw 'Offline upgrade lost bundled Camofox.' }
$playwrightBrowser = Get-ChildItem -LiteralPath (Join-Path $TestHome 'ms-playwright') -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -in @('chrome.exe', 'headless_shell.exe') } | Select-Object -First 1
if (-not $playwrightBrowser) { throw 'Offline upgrade lost bundled Playwright Chromium.' }

# Bootstrap returned success: release old managed bytes immediately. No
# permanent offline-backup-* is allowed to accumulate on user machines.
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $transactionScript -Mode Commit -HermesHome $TestHome -InstallDir $installRoot
if ($LASTEXITCODE -ne 0) { throw 'Could not commit offline upgrade transaction.' }
if (Test-Path -LiteralPath $transactionPath -or Test-Path -LiteralPath $rollbackRoot) {
    throw 'Successful offline upgrade left transaction/rollback storage behind.'
}
$legacyBackups = @(Get-ChildItem -LiteralPath $TestHome -Directory -Filter 'hermes-agent.offline-backup-*' -ErrorAction SilentlyContinue)
if ($legacyBackups.Count -ne 0) { throw 'Successful transactional upgrade left legacy permanent backup directories behind.' }
Write-Host "Transactional offline-to-offline upgrade passed: $oldCommit -> $InstalledCommit"

# ---------------------------------------------------------------------------
# Cheap destructive-failure fixture: prove Rollback restores exact old managed
# bytes and removes new-only managed artifacts, without duplicating another
# multi-GB real Hermes install on the hosted runner.
# ---------------------------------------------------------------------------
$failureHome = Join-Path (Split-Path $TestHome -Parent) 'offline-transaction-failure-fixture'
if (Test-Path -LiteralPath $failureHome) { Remove-Item -LiteralPath $failureHome -Recurse -Force }
$failureInstall = Join-Path $failureHome 'hermes-agent'
New-Item -ItemType Directory -Force -Path $failureInstall, (Join-Path $failureHome 'node') | Out-Null
$oldSource = Join-Path $failureInstall 'old-managed.txt'
$oldNode = Join-Path $failureHome 'node\node.exe'
$failureUser = Join-Path $failureHome 'user-state.txt'
[System.IO.File]::WriteAllText($oldSource, 'old-source-bytes', $utf8NoBom)
[System.IO.File]::WriteAllText($oldNode, 'old-node-bytes', $utf8NoBom)
[System.IO.File]::WriteAllText($failureUser, 'user-state-must-survive', $utf8NoBom)
$oldSourceHash = Get-Sha256 $oldSource
$oldNodeHash = Get-Sha256 $oldNode
$failureUserHash = Get-Sha256 $failureUser

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $transactionScript -Mode Begin -HermesHome $failureHome -InstallDir $failureInstall
if ($LASTEXITCODE -ne 0) { throw 'Failure fixture could not begin transaction.' }
New-Item -ItemType Directory -Force -Path $failureInstall, (Join-Path $failureHome 'node'), (Join-Path $failureHome 'tools\bin') | Out-Null
[System.IO.File]::WriteAllText((Join-Path $failureInstall 'new-partial.txt'), 'new-partial-source', $utf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $failureHome 'node\node.exe'), 'new-broken-node', $utf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $failureHome 'tools\bin\new-only.exe'), 'new-only', $utf8NoBom)

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $transactionScript -Mode Rollback -HermesHome $failureHome -InstallDir $failureInstall
if ($LASTEXITCODE -ne 0) { throw 'Failure fixture rollback command failed.' }
if (-not (Test-Path -LiteralPath $oldSource) -or (Get-Sha256 $oldSource) -ne $oldSourceHash) { throw 'Rollback did not restore exact old source bytes.' }
if (-not (Test-Path -LiteralPath $oldNode) -or (Get-Sha256 $oldNode) -ne $oldNodeHash) { throw 'Rollback did not restore exact old managed runtime bytes.' }
if ((Get-Sha256 $failureUser) -ne $failureUserHash) { throw 'Rollback modified user state outside managed paths.' }
if (Test-Path -LiteralPath (Join-Path $failureInstall 'new-partial.txt')) { throw 'Rollback left partial new source behind.' }
if (Test-Path -LiteralPath (Join-Path $failureHome 'tools')) { throw 'Rollback left a new-only managed runtime directory behind.' }
if (Test-Path -LiteralPath (Join-Path $failureHome '.hermes-offline-update-transaction.json') -or Test-Path -LiteralPath (Join-Path $failureHome '.hermes-offline-rollback')) {
    throw 'Rollback fixture left transaction metadata behind.'
}
Write-Host 'Intentional-failure transaction rollback gate passed.'
