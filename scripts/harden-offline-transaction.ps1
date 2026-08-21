param(
    [Parameter(Mandatory = $true)][string]$InstallScript
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $InstallScript -PathType Leaf)) {
    throw "Generated install script not found: $InstallScript"
}

# This hardener is an existing mandatory step in the full-offline builder, so
# use it as the gate that finalizes the source archive for Windows BEFORE the
# generated target installer is exercised. The initial payload preparer still
# creates a conventional clone; this pass deliberately rebuilds hermes-source
# from Git objects with sparse checkout + core.autocrlf configured before the
# first worktree materialization.
$builderRoot = Split-Path $PSScriptRoot -Parent
$workRoot = Join-Path $builderRoot 'offline-work'
$payloadRoot = Join-Path $builderRoot 'offline-bundle\payload'
$manifestPath = Join-Path $payloadRoot 'manifest.json'
$upstreamRoot = Join-Path $builderRoot 'upstream'
$sourceHardener = Join-Path $PSScriptRoot 'harden-windows-source-checkout.ps1'

foreach ($required in @($manifestPath, $upstreamRoot, $sourceHardener)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Transactional hardening requires the completed builder workspace; missing: $required"
    }
}
$payloadManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace([string]$payloadManifest.hermes_commit)) {
    throw 'Offline payload manifest does not contain hermes_commit.'
}
& $sourceHardener `
    -UpstreamRoot $upstreamRoot `
    -HermesCommit ([string]$payloadManifest.hermes_commit) `
    -WorkRoot $workRoot `
    -PayloadRoot $payloadRoot
if ($LASTEXITCODE -ne 0) {
    throw "Windows-safe source payload hardening failed with exit $LASTEXITCODE"
}

$text = [System.IO.File]::ReadAllText($InstallScript)
$old = @'
    if (Test-Path -LiteralPath $InstallDir) {
        $backup = "$InstallDir.offline-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Write-Warn "Replacing the managed Hermes checkout with bundled $($manifest.hermes_ref)."
        Write-Warn "The previous checkout is preserved at $backup."
        Move-Item -LiteralPath $InstallDir -Destination $backup -ErrorAction Stop
    }
'@

$new = @'
    if (Test-Path -LiteralPath $InstallDir) {
        # Upgrades of an existing managed checkout must be protected by the
        # outer single-file installer's whole-lifecycle transaction. Never
        # create a permanent source backup here: that would both consume user
        # disk indefinitely and protect only one stage instead of the complete
        # runtime/Desktop update.
        $transactionPath = Join-Path $HermesHome '.hermes-offline-update-transaction.json'
        $transactionActive = $false
        if (Test-Path -LiteralPath $transactionPath -PathType Leaf) {
            try {
                $transaction = Get-Content -LiteralPath $transactionPath -Raw | ConvertFrom-Json
                $transactionActive = ($transaction.state -eq 'active')
            } catch { }
        }
        if (-not $transactionActive) {
            throw 'Refusing to replace an existing Hermes installation without the outer transactional offline installer. Run the single-file Hermes offline EXE so the previous managed installation can be restored if any later stage fails.'
        }

        # If Bootstrap retries the repository stage after a partial extraction,
        # the real old installation is already safe in .hermes-offline-rollback.
        # Discard only this incomplete NEW checkout and retry extraction.
        Write-Warn 'Discarding a partial new checkout inside the active offline upgrade transaction...'
        Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction Stop
    }
'@

if (-not $text.Contains($old)) {
    throw 'Permanent offline-backup fallback block moved or changed; refusing to patch an unknown adapter layout.'
}

$patched = $text.Replace($old, $new)
if ($patched -match 'offline-backup-\$\(') {
    throw 'Permanent offline backup construction still exists after transaction hardening.'
}

$utf8Bom = New-Object System.Text.UTF8Encoding $true
[System.IO.File]::WriteAllText($InstallScript, $patched, $utf8Bom)
Write-Host "Removed permanent backup fallback from generated offline installer: $InstallScript"
