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
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Get-Sha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Append-TestByte([string]$Path) {
    $stream = [System.IO.File]::Open($Path, 'Append', 'Write', 'Read')
    try { $stream.WriteByte(0x7f) } finally { $stream.Dispose() }
}

foreach ($required in @($OfflineInstallScript, $transactionScript, (Join-Path $PayloadRoot 'manifest.json'), $gitExe, $desktop, $nodeExe, $python, $hermes)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Offline-upgrade preflight missing: $required" }
}
if (-not (Test-Path -LiteralPath (Join-Path $installRoot '.git') -PathType Container)) { throw 'Installed checkout has no .git directory.' }

# Record the known-good current payload bytes, then synthesize a prior release.
$expectedDesktopHash = Get-Sha256 $desktop
$expectedNodeHash = Get-Sha256 $nodeExe
Push-Location $installRoot
try {
    if ((& $gitExe rev-parse HEAD).Trim() -ne $InstalledCommit) { throw 'Fresh install HEAD does not match packaged commit.' }
    $oldCommit = (& $gitExe rev-parse "$InstalledCommit^" 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $oldCommit) {
        & $gitExe fetch --depth 2 origin $InstalledCommit
        if ($LASTEXITCODE -ne 0) { throw 'Could not fetch enough history for the old-version fixture.' }
        $oldCommit = (& $gitExe rev-parse "$InstalledCommit^" | Out-String).Trim()
    }
    if (-not $oldCommit -or $oldCommit -eq $InstalledCommit) { throw 'Could not resolve a distinct prior commit.' }
    & $gitExe checkout -f --detach $oldCommit
    if ($LASTEXITCODE -ne 0) { throw "Could not synthesize prior checkout $oldCommit." }
} finally { Pop-Location }

$userStateDir = Join-Path $TestHome 'ci-offline-upgrade-user-state'
New-Item -ItemType Directory -Force -Path $userStateDir | Out-Null
$userState = Join-Path $userStateDir 'state.json'
[System.IO.File]::WriteAllText($userState, "{`"canary`":`"$([Guid]::NewGuid().ToString('N'))`"}", $utf8NoBom)
$userStateHash = Get-Sha256 $userState

$sourceCanary = Join-Path $installRoot 'ci-local-source-edit.txt'
$sourceCanaryValue = "old-managed-checkout-$([Guid]::NewGuid().ToString('N'))"
[System.IO.File]::WriteAllText($sourceCanary, $sourceCanaryValue, $utf8NoBom)
Append-TestByte $desktop
Append-TestByte $nodeExe
if ((Get-Sha256 $desktop) -eq $expectedDesktopHash -or (Get-Sha256 $nodeExe) -eq $expectedNodeHash) { throw 'Old-version mutation fixture failed.' }
[System.IO.File]::WriteAllText($sourceMarker, ([ordered]@{ schema = 1; hermes_commit = $oldCommit; hermes_ref = 'ci-prior' } | ConvertTo-Json), $utf8NoBom)
[System.IO.File]::WriteAllText($runtimeMarker, ([ordered]@{ schema = 1; hermes_commit = $oldCommit; hermes_ref = 'ci-prior'; prepared_at = 'ci' } | ConvertTo-Json), $utf8NoBom)

# Production wrapper behavior: stage ALL old managed bytes by same-volume rename.
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $transactionScript -Mode Begin -HermesHome $TestHome -InstallDir $installRoot
if ($LASTEXITCODE -ne 0) { throw 'Transaction Begin failed.' }
if (-not (Test-Path -LiteralPath $transactionPath -PathType Leaf)) { throw 'Transaction marker was not created.' }
if (-not (Test-Path -LiteralPath $rollbackRoot -PathType Container)) { throw 'Temporary rollback directory was not created.' }
if (Test-Path -LiteralPath $installRoot) { throw 'Old live checkout was not staged out of the install path.' }

$txn = Get-Content -LiteralPath $transactionPath -Raw | ConvertFrom-Json
if ($txn.state -ne 'active') { throw "Transaction state is '$($txn.state)', expected active." }
$oldInstallEntry = @($txn.entries) | Where-Object { [string]$_.source -eq $installRoot } | Select-Object -First 1
if (-not $oldInstallEntry) { throw 'Transaction did not capture old checkout.' }
$oldInstallRollback = [string]$oldInstallEntry.rollback
$rollbackCanary = Join-Path $oldInstallRollback 'ci-local-source-edit.txt'
if (-not (Test-Path -LiteralPath $rollbackCanary) -or [System.IO.File]::ReadAllText($rollbackCanary) -ne $sourceCanaryValue) { throw 'Temporary rollback did not preserve old checkout bytes.' }

# CI disk optimization only. Real user transactions retain the complete old tree.
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

    $manifestRaw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $OfflineInstallScript -Manifest -IncludeDesktop -Commit $InstalledCommit -Branch main -HermesHome $TestHome -InstallDir $installRoot
    if ($LASTEXITCODE -ne 0) { throw 'Offline upgrade manifest query failed.' }
    $manifest = ($manifestRaw | Out-String | ConvertFrom-Json)
    foreach ($stage in $manifest.stages) {
        Write-Host "===== TRANSACTIONAL OFFLINE->OFFLINE STAGE: $($stage.name) ====="
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $OfflineInstallScript -Stage $stage.name -IncludeDesktop -NonInteractive -Json -Commit $InstalledCommit -Branch main -HermesHome $TestHome -InstallDir $installRoot
        if ($LASTEXITCODE -ne 0) { throw "Offline-to-offline stage failed: $($stage.name)" }
    }
} catch {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $transactionScript -Mode Rollback -HermesHome $TestHome -InstallDir $installRoot
    throw
} finally {
    foreach ($name in $envNames) {
        $old = $savedEnv[$name]
        if ($null -eq $old) { Remove-Item -LiteralPath "Env:\$name" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($name, $old, 'Process') }
    }
}

# Validate the new managed install before committing/deleting rollback bytes.
$gitExe = Join-Path $TestHome 'git\cmd\git.exe'
Push-Location $installRoot
try {
    if ((& $gitExe rev-parse HEAD).Trim() -ne $InstalledCommit) { throw 'Offline upgrade did not land on packaged commit.' }
    $origin = (& $gitExe remote get-url origin).Trim()
    if ($origin -notmatch '^https://github\.com/NousResearch/hermes-agent(?:\.git)?/?$') { throw "Wrong origin after offline upgrade: $origin" }
    $trackedDirty = @(& $gitExe status --porcelain --untracked-files=no 2>$null | Where-Object { $_ -and $_.ToString().Trim() })
    if ($trackedDirty.Count -ne 0) { throw "Checkout is tracked-dirty before official updater handoff: $($trackedDirty -join '; ')" }
} finally { Pop-Location }

if ((Get-Sha256 $userState) -ne $userStateHash) { throw 'HERMES_HOME user-state canary changed.' }
if ((Get-Sha256 $desktop) -ne $expectedDesktopHash) { throw 'Packaged Desktop bytes were not restored.' }
if ((Get-Sha256 $nodeExe) -ne $expectedNodeHash) { throw 'Packaged Node bytes were not restored.' }
if (Test-Path -LiteralPath (Join-Path $installRoot 'ci-local-source-edit.txt')) { throw 'Old managed-checkout edit leaked into fresh source.' }

$sourceRecord = Get-Content -LiteralPath $sourceMarker -Raw | ConvertFrom-Json
$runtimeRecord = Get-Content -LiteralPath $runtimeMarker -Raw | ConvertFrom-Json
if ($sourceRecord.hermes_commit -ne $InstalledCommit -or $runtimeRecord.hermes_commit -ne $InstalledCommit) { throw 'Offline version markers were not advanced.' }
foreach ($required in @($desktop, $nodeExe, $python, $hermes, (Join-Path $TestHome 'bin\browser-use.exe'), (Join-Path $TestHome 'tools\bin\cua-driver.exe'))) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Post-upgrade file missing: $required" }
}
& $python -c 'import dotenv, openai, rich, prompt_toolkit, fastapi, uvicorn, onnxruntime, faster_whisper, sounddevice, openwakeword'
if ($LASTEXITCODE -ne 0) { throw 'Post-upgrade Python/voice imports failed.' }
if (-not (Test-Path -LiteralPath (Join-Path $TestHome 'node\node_modules\@askjo\camofox-browser\package.json'))) { throw 'Camofox missing after upgrade.' }
$browser = Get-ChildItem -LiteralPath (Join-Path $TestHome 'ms-playwright') -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -in @('chrome.exe', 'headless_shell.exe') } | Select-Object -First 1
if (-not $browser) { throw 'Playwright Chromium missing after upgrade.' }

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $transactionScript -Mode Commit -HermesHome $TestHome -InstallDir $installRoot
if ($LASTEXITCODE -ne 0) { throw 'Transaction Commit failed.' }
if ((Test-Path -LiteralPath $transactionPath) -or (Test-Path -LiteralPath $rollbackRoot)) { throw 'Successful upgrade left temporary transaction storage behind.' }
if (@(Get-ChildItem -LiteralPath $TestHome -Directory -Filter 'hermes-agent.offline-backup-*' -ErrorAction SilentlyContinue).Count -ne 0) { throw 'Successful upgrade left legacy permanent backup directories.' }
Write-Host "Transactional offline-to-offline upgrade passed: $oldCommit -> $InstalledCommit"

# Cheap intentional-failure fixture verifies exact rollback without allocating
# a second multi-GB Hermes tree on the hosted runner.
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
if ($LASTEXITCODE -ne 0) { throw 'Failure fixture Begin failed.' }
New-Item -ItemType Directory -Force -Path $failureInstall, (Join-Path $failureHome 'node'), (Join-Path $failureHome 'tools\bin') | Out-Null
[System.IO.File]::WriteAllText((Join-Path $failureInstall 'new-partial.txt'), 'new-partial', $utf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $failureHome 'node\node.exe'), 'new-broken-node', $utf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $failureHome 'tools\bin\new-only.exe'), 'new-only', $utf8NoBom)

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $transactionScript -Mode Rollback -HermesHome $failureHome -InstallDir $failureInstall
if ($LASTEXITCODE -ne 0) { throw 'Failure fixture Rollback failed.' }
if ((Get-Sha256 $oldSource) -ne $oldSourceHash) { throw 'Rollback did not restore old source bytes.' }
if ((Get-Sha256 $oldNode) -ne $oldNodeHash) { throw 'Rollback did not restore old runtime bytes.' }
if ((Get-Sha256 $failureUser) -ne $failureUserHash) { throw 'Rollback changed user state.' }
if (Test-Path -LiteralPath (Join-Path $failureInstall 'new-partial.txt')) { throw 'Rollback left partial new source.' }
if (Test-Path -LiteralPath (Join-Path $failureHome 'tools')) { throw 'Rollback left new-only managed runtime.' }
$failureTxn = Join-Path $failureHome '.hermes-offline-update-transaction.json'
$failureRollback = Join-Path $failureHome '.hermes-offline-rollback'
if ((Test-Path -LiteralPath $failureTxn) -or (Test-Path -LiteralPath $failureRollback)) { throw 'Rollback fixture left transaction metadata.' }
Write-Host 'Intentional-failure transaction rollback gate passed.'
