param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Begin', 'Commit', 'Rollback', 'Recover')]
    [string]$Mode,
    [string]$HermesHome,
    [string]$InstallDir
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Resolve-HermesHome {
    param([string]$Value)
    if (-not [string]::IsNullOrWhiteSpace($Value)) { return [System.IO.Path]::GetFullPath($Value) }
    if (-not [string]::IsNullOrWhiteSpace($env:HERMES_HOME)) { return [System.IO.Path]::GetFullPath($env:HERMES_HOME) }
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is unavailable and HERMES_HOME was not provided.' }
    return Join-Path $env:LOCALAPPDATA 'hermes'
}

$HermesHome = Resolve-HermesHome $HermesHome
if ([string]::IsNullOrWhiteSpace($InstallDir)) { $InstallDir = Join-Path $HermesHome 'hermes-agent' }
$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)
New-Item -ItemType Directory -Force -Path $HermesHome | Out-Null

$transactionPath = Join-Path $HermesHome '.hermes-offline-update-transaction.json'
$rollbackRoot = Join-Path $HermesHome '.hermes-offline-rollback'
$rollbackRecord = Join-Path $rollbackRoot 'transaction.json'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

# These are Hermes/offline-builder managed artifacts. User state such as .env,
# config.yaml, state.db, skills, sessions, cron data and credentials is never
# moved by this transaction layer.
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

function Write-Transaction {
    param([Parameter(Mandatory = $true)]$Record)
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
    $candidate = $null
    if (Test-Path -LiteralPath $transactionPath -PathType Leaf) { $candidate = $transactionPath }
    elseif (Test-Path -LiteralPath $rollbackRecord -PathType Leaf) { $candidate = $rollbackRecord }
    if (-not $candidate) { return $null }
    try { return (Get-Content -LiteralPath $candidate -Raw | ConvertFrom-Json) }
    catch { throw "Offline upgrade transaction record is unreadable: $candidate" }
}

function Remove-PathWithRetry {
    param([Parameter(Mandatory = $true)][string]$Path, [int]$Attempts = 8)
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
    return $false
}

function Restore-Transaction {
    param([Parameter(Mandatory = $true)]$Record)

    if ($Record.state -eq 'committed') {
        # Never roll back a version whose Bootstrap already returned success.
        # A committed record only means cleanup was interrupted.
        [void](Remove-PathWithRetry -Path $rollbackRoot)
        if (-not (Test-Path -LiteralPath $rollbackRoot)) {
            Remove-Item -LiteralPath $transactionPath -Force -ErrorAction SilentlyContinue
        }
        return
    }

    $Record.state = 'rolling_back'
    $Record.updated_at = (Get-Date).ToUniversalTime().ToString('o')
    Write-Transaction $Record

    # Drop every managed artifact the failed new install may have created,
    # including artifacts that did not exist before Begin.
    foreach ($path in @($Record.managed_paths)) {
        if ($path) {
            if (-not (Remove-PathWithRetry -Path ([string]$path))) {
                throw "Rollback could not remove the partial new managed artifact: $path"
            }
        }
    }

    foreach ($entry in @($Record.entries)) {
        $source = [string]$entry.source
        $saved = [string]$entry.rollback
        if (-not (Test-Path -LiteralPath $saved)) {
            throw "Rollback payload is missing the previous managed artifact: $saved"
        }
        $parent = Split-Path $source -Parent
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        Move-Item -LiteralPath $saved -Destination $source -Force -ErrorAction Stop
    }

    Remove-Item -LiteralPath $rollbackRecord -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $rollbackRoot) {
        [void](Remove-PathWithRetry -Path $rollbackRoot)
    }
    Remove-Item -LiteralPath $transactionPath -Force -ErrorAction SilentlyContinue
    Write-Host 'Hermes offline upgrade rollback restored the previous managed installation.'
}

function Recover-ExistingTransaction {
    $record = Read-Transaction
    if ($record) {
        if ($record.state -eq 'committed') {
            Write-Host 'Cleaning an already-committed Hermes offline upgrade transaction...'
        } else {
            Write-Warning 'An interrupted Hermes offline upgrade was detected; restoring the previous managed installation first.'
        }
        Restore-Transaction $record
        return
    }

    if (Test-Path -LiteralPath $rollbackRoot) {
        # With no transaction record there is no trustworthy mapping from the
        # rollback files to their original paths. Refuse to guess and preserve
        # the data rather than deleting potentially recoverable old bytes.
        throw "Found orphan Hermes rollback data without a transaction record: $rollbackRoot"
    }
}

switch ($Mode) {
    'Recover' {
        Recover-ExistingTransaction
        exit 0
    }

    'Begin' {
        Recover-ExistingTransaction

        # Fresh installs do not need rollback storage. Runtime-only leftovers
        # from an incomplete first install are intentionally overwritten by the
        # normal installer rather than treated as a valid previous version.
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
            $safeLeaf = $leaf -replace '[^A-Za-z0-9._-]', '_'
            $saved = Join-Path $rollbackRoot ('{0:D2}-{1}' -f $index, $safeLeaf)
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
            foreach ($entry in $entries) {
                Move-Item -LiteralPath $entry.source -Destination $entry.rollback -Force -ErrorAction Stop
            }
            $record.state = 'active'
            $record.updated_at = (Get-Date).ToUniversalTime().ToString('o')
            Write-Transaction $record
            Write-Host "Hermes offline upgrade transaction started; rollback data is temporary: $rollbackRoot"
        } catch {
            Write-Warning "Could not stage the existing Hermes installation for transactional upgrade: $($_.Exception.Message)"
            try { Restore-Transaction $record } catch { Write-Warning "Automatic rollback after Begin failure also failed: $($_.Exception.Message)" }
            throw
        }
        exit 0
    }

    'Rollback' {
        $record = Read-Transaction
        if (-not $record) {
            Write-Host 'No Hermes offline upgrade transaction needs rollback.'
            exit 0
        }
        Restore-Transaction $record
        exit 0
    }

    'Commit' {
        $record = Read-Transaction
        if (-not $record) {
            Write-Host 'No Hermes offline upgrade transaction needs commit.'
            exit 0
        }
        if ($record.state -eq 'rolling_back') {
            throw 'Cannot commit a Hermes offline upgrade transaction that is rolling back.'
        }

        # Publish the success state before deleting old bytes. If power is lost
        # during cleanup, the next installer run will finish cleanup rather than
        # incorrectly reverting a successfully installed new version.
        $record.state = 'committed'
        $record.updated_at = (Get-Date).ToUniversalTime().ToString('o')
        Write-Transaction $record

        $clean = Remove-PathWithRetry -Path $rollbackRoot
        if ($clean) {
            Remove-Item -LiteralPath $transactionPath -Force -ErrorAction SilentlyContinue
        } else {
            # The new installation is already committed and usable. Preserve the
            # small marker so a later installer launch knows to clean, never roll
            # back, the stale temporary directory.
            Write-Warning "Hermes upgrade succeeded but temporary rollback cleanup is pending: $rollbackRoot"
        }

        # Remove permanent backups left by older versions of this builder. They
        # are builder-owned managed-checkout snapshots, not Hermes user state.
        Get-ChildItem -LiteralPath $HermesHome -Directory -Filter 'hermes-agent.offline-backup-*' -ErrorAction SilentlyContinue | ForEach-Object {
            [void](Remove-PathWithRetry -Path $_.FullName)
        }
        Write-Host 'Hermes offline upgrade transaction committed; temporary rollback data was released.'
        exit 0
    }
}
