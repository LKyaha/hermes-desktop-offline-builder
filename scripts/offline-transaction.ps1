param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Begin', 'Commit', 'Rollback', 'Recover')]
    [string]$Mode,
    [string]$HermesHome,
    [string]$InstallDir
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Resolve-HermesHome([string]$Value) {
    if (-not [string]::IsNullOrWhiteSpace($Value)) { return [System.IO.Path]::GetFullPath($Value) }
    if (-not [string]::IsNullOrWhiteSpace($env:HERMES_HOME)) { return [System.IO.Path]::GetFullPath($env:HERMES_HOME) }
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is unavailable and HERMES_HOME was not provided.' }
    Join-Path $env:LOCALAPPDATA 'hermes'
}

$HermesHome = Resolve-HermesHome $HermesHome
if ([string]::IsNullOrWhiteSpace($InstallDir)) { $InstallDir = Join-Path $HermesHome 'hermes-agent' }
$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)
New-Item -ItemType Directory -Force -Path $HermesHome | Out-Null

$transactionPath = Join-Path $HermesHome '.hermes-offline-update-transaction.json'
$rollbackRoot = Join-Path $HermesHome '.hermes-offline-rollback'
$rollbackRecord = Join-Path $rollbackRoot 'transaction.json'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$managedPaths = @(
    $InstallDir,
    (Join-Path $HermesHome 'bin'),
    (Join-Path $HermesHome 'git'),
    (Join-Path $HermesHome 'node'),
    (Join-Path $HermesHome 'python'),
    (Join-Path $HermesHome 'tools'),
    (Join-Path $HermesHome 'uv-cache'),
    (Join-Path $HermesHome 'uv-tools'),
    (Join-Path $HermesHome 'npm-cache'),
    (Join-Path $HermesHome 'ms-playwright'),
    (Join-Path $HermesHome '.hermes-offline-runtime.json'),
    (Join-Path $HermesHome 'hermes-setup.exe')
) | Select-Object -Unique

function Write-Transaction($Record) {
    $json = $Record | ConvertTo-Json -Depth 8
    foreach ($path in @($transactionPath, $rollbackRecord)) {
        $parent = Split-Path $path -Parent
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        $tmp = "$path.tmp"
        [System.IO.File]::WriteAllText($tmp, $json, $utf8NoBom)
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        Move-Item -LiteralPath $tmp -Destination $path -Force
    }
}

function Read-Transaction {
    $candidate = if (Test-Path -LiteralPath $transactionPath -PathType Leaf) { $transactionPath } elseif (Test-Path -LiteralPath $rollbackRecord -PathType Leaf) { $rollbackRecord } else { $null }
    if (-not $candidate) { return $null }
    try { Get-Content -LiteralPath $candidate -Raw | ConvertFrom-Json }
    catch { throw "Offline upgrade transaction record is unreadable: $candidate" }
}

function Remove-PathWithRetry([string]$Path, [int]$Attempts = 8) {
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return $true
        } catch {
            if ($attempt -eq $Attempts) {
                Write-Warning "Could not remove $Path after $Attempts attempts: $($_.Exception.Message)"
                return $false
            }
            Start-Sleep -Milliseconds (250 * $attempt)
        }
    }
    $false
}

function Remove-LegacyOfflineBackups {
    Get-ChildItem -LiteralPath $HermesHome -Directory -Filter 'hermes-agent.offline-backup-*' -ErrorAction SilentlyContinue | ForEach-Object {
        [void](Remove-PathWithRetry $_.FullName)
    }
}

function Assert-NewManagedInstallHealthy {
    $required = @(
        (Join-Path $InstallDir '.git'),
        (Join-Path $InstallDir '.hermes-bootstrap-complete'),
        (Join-Path $InstallDir 'venv\Scripts\python.exe'),
        (Join-Path $InstallDir 'venv\Scripts\hermes.exe'),
        (Join-Path $InstallDir 'apps\desktop\release\win-unpacked\Hermes.exe'),
        (Join-Path $HermesHome 'node\node.exe'),
        (Join-Path $HermesHome 'bin\uv.exe')
    )
    foreach ($path in $required) {
        if (-not (Test-Path -LiteralPath $path)) { throw "Transactional commit health check is missing: $path" }
    }

    $gitExe = Join-Path $HermesHome 'git\cmd\git.exe'
    if (-not (Test-Path -LiteralPath $gitExe -PathType Leaf)) { $gitExe = 'git' }
    Push-Location $InstallDir
    try {
        $head = (& $gitExe rev-parse HEAD 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $head) { throw 'Transactional commit could not resolve the new checkout HEAD.' }
        $sourceMarker = Join-Path $InstallDir '.hermes-offline-source.json'
        if (Test-Path -LiteralPath $sourceMarker -PathType Leaf) {
            $sourceRecord = Get-Content -LiteralPath $sourceMarker -Raw | ConvertFrom-Json
            if ($sourceRecord.hermes_commit -and [string]$sourceRecord.hermes_commit -ne $head) {
                throw "Transactional commit source marker/HEAD mismatch: $($sourceRecord.hermes_commit) vs $head"
            }
        }
    } finally { Pop-Location }
}

function Restore-Transaction($Record) {
    if ($Record.state -eq 'committed') {
        [void](Remove-PathWithRetry $rollbackRoot)
        if (-not (Test-Path -LiteralPath $rollbackRoot)) { Remove-Item -LiteralPath $transactionPath -Force -ErrorAction SilentlyContinue }
        Remove-LegacyOfflineBackups
        return
    }

    # Begin can fail after only some old paths were renamed. Only remove a live
    # path when its staged old counterpart actually exists. Once Begin reached
    # active, also remove managed paths that did not exist in the old version.
    $wasActive = ($Record.state -eq 'active' -or $Record.state -eq 'rolling_back')
    $Record.state = 'rolling_back'
    $Record.updated_at = (Get-Date).ToUniversalTime().ToString('o')
    Write-Transaction $Record

    $entryBySource = @{}
    foreach ($entry in @($Record.entries)) { $entryBySource[[string]$entry.source] = $entry }
    if ($wasActive) {
        foreach ($path in @($Record.managed_paths)) {
            if (-not $path) { continue }
            $source = [string]$path
            if ($entryBySource.ContainsKey($source)) { continue }
            if (-not (Remove-PathWithRetry $source)) { throw "Rollback could not remove new-only managed artifact: $source" }
        }
    }

    foreach ($entry in @($Record.entries)) {
        $source = [string]$entry.source
        $saved = [string]$entry.rollback
        $savedExists = Test-Path -LiteralPath $saved
        $sourceExists = Test-Path -LiteralPath $source
        if ($savedExists) {
            if ($sourceExists -and -not (Remove-PathWithRetry $source)) { throw "Rollback could not remove partial replacement: $source" }
            New-Item -ItemType Directory -Force -Path (Split-Path $source -Parent) | Out-Null
            Move-Item -LiteralPath $saved -Destination $source -Force -ErrorAction Stop
        } elseif (-not $sourceExists) {
            throw "Rollback cannot find either live or staged previous artifact: $source"
        }
    }

    Remove-Item -LiteralPath $rollbackRecord -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $rollbackRoot) { [void](Remove-PathWithRetry $rollbackRoot) }
    Remove-Item -LiteralPath $transactionPath -Force -ErrorAction SilentlyContinue
    Remove-LegacyOfflineBackups
    Write-Host 'Hermes offline upgrade rollback restored the previous managed installation.'
}

function Recover-ExistingTransaction {
    $record = Read-Transaction
    if ($record) {
        if ($record.state -eq 'committed') { Write-Host 'Cleaning an already-committed Hermes offline upgrade transaction...' }
        else { Write-Warning 'Interrupted Hermes offline upgrade detected; restoring the previous managed installation first.' }
        Restore-Transaction $record
        return
    }
    if (Test-Path -LiteralPath $rollbackRoot) { throw "Found orphan rollback data without a transaction record: $rollbackRoot" }
}

switch ($Mode) {
    'Recover' {
        Recover-ExistingTransaction
        exit 0
    }

    'Begin' {
        Recover-ExistingTransaction
        if (-not (Test-Path -LiteralPath $InstallDir -PathType Container)) {
            Write-Host 'No existing Hermes managed installation found; transactional rollback is not required.'
            exit 0
        }

        New-Item -ItemType Directory -Force -Path $rollbackRoot | Out-Null
        $entries = @()
        $index = 0
        foreach ($source in $managedPaths) {
            if (-not (Test-Path -LiteralPath $source)) { continue }
            $leaf = Split-Path $source -Leaf
            if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = 'managed' }
            $saved = Join-Path $rollbackRoot ('{0:D2}-{1}' -f $index, ($leaf -replace '[^A-Za-z0-9._-]', '_'))
            $entries += [ordered]@{ source = $source; rollback = $saved }
            $index++
        }
        $record = [ordered]@{
            schema = 1
            state = 'preparing'
            created_at = (Get-Date).ToUniversalTime().ToString('o')
            updated_at = (Get-Date).ToUniversalTime().ToString('o')
            hermes_home = $HermesHome
            install_dir = $InstallDir
            managed_paths = @($managedPaths)
            entries = @($entries)
        }
        Write-Transaction $record
        try {
            foreach ($entry in $entries) { Move-Item -LiteralPath $entry.source -Destination $entry.rollback -Force -ErrorAction Stop }
            $record.state = 'active'
            $record.updated_at = (Get-Date).ToUniversalTime().ToString('o')
            Write-Transaction $record
            Write-Host "Hermes offline upgrade transaction started; rollback data is temporary: $rollbackRoot"
        } catch {
            Write-Warning "Could not stage existing Hermes installation: $($_.Exception.Message)"
            try { Restore-Transaction $record } catch { Write-Warning "Automatic rollback after Begin failure also failed: $($_.Exception.Message)" }
            throw
        }
        exit 0
    }

    'Rollback' {
        $record = Read-Transaction
        if (-not $record) { Write-Host 'No Hermes offline upgrade transaction needs rollback.'; exit 0 }
        Restore-Transaction $record
        exit 0
    }

    'Commit' {
        $record = Read-Transaction
        if (-not $record) { Write-Host 'No Hermes offline upgrade transaction needs commit.'; exit 0 }
        if ($record.state -eq 'rolling_back') { throw 'Cannot commit a transaction that is rolling back.' }

        try { Assert-NewManagedInstallHealthy }
        catch {
            Write-Warning "New Hermes installation failed transactional health validation: $($_.Exception.Message)"
            Restore-Transaction $record
            throw
        }

        # Publish success before deleting old bytes. A power loss during cleanup
        # can therefore only leave cleanup work, never trigger a false rollback.
        $record.state = 'committed'
        $record.updated_at = (Get-Date).ToUniversalTime().ToString('o')
        Write-Transaction $record
        $clean = Remove-PathWithRetry $rollbackRoot
        if ($clean) { Remove-Item -LiteralPath $transactionPath -Force -ErrorAction SilentlyContinue }
        else { Write-Warning "Upgrade succeeded but temporary rollback cleanup is pending: $rollbackRoot" }
        Remove-LegacyOfflineBackups
        Write-Host 'Hermes offline upgrade transaction committed; temporary rollback data was released.'
        exit 0
    }
}
