param(
    [Parameter(Mandatory = $true)][string]$UpstreamRoot,
    [Parameter(Mandatory = $true)][string]$HermesCommit,
    [string]$WorkRoot = $(Join-Path (Split-Path $PSScriptRoot -Parent) 'offline-work'),
    [string]$PayloadRoot = $(Join-Path (Split-Path $PSScriptRoot -Parent) 'offline-bundle\payload')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$UpstreamRoot = (Resolve-Path -LiteralPath $UpstreamRoot).Path
$WorkRoot = (Resolve-Path -LiteralPath $WorkRoot).Path
$PayloadRoot = (Resolve-Path -LiteralPath $PayloadRoot).Path

$gitExe = Join-Path $WorkRoot 'managed-runtime\git\cmd\git.exe'
$sourceStage = Join-Path $WorkRoot 'source-stage'
$sourceArchive = Join-Path $PayloadRoot 'hermes-source.tar.gz'
$manifestPath = Join-Path $PayloadRoot 'manifest.json'

if (-not (Test-Path -LiteralPath $gitExe -PathType Leaf)) {
    throw "Bundled PortableGit is missing: $gitExe"
}
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Offline payload manifest is missing: $manifestPath"
}

# Recreate the source payload from Git objects, not from the Windows worktree.
# The upstream release currently contains contributor metadata whose file names
# differ only by case. A normal checkout on NTFS cannot materialize both names.
# Also, changing core.autocrlf only after extraction makes already-normalized
# CRLF files look modified. Configure BOTH sparse checkout and autocrlf before
# the very first worktree materialization instead.
if (Test-Path -LiteralPath $sourceStage) {
    Remove-Item -LiteralPath $sourceStage -Recurse -Force
}

Write-Host 'Creating no-checkout Hermes source clone for Windows-safe payload...'
& $gitExe -c core.autocrlf=false clone --no-hardlinks --no-checkout $UpstreamRoot $sourceStage
if ($LASTEXITCODE -ne 0) { throw 'Could not create no-checkout source staging clone.' }

Push-Location $sourceStage
try {
    & $gitExe remote set-url origin 'https://github.com/NousResearch/hermes-agent.git'
    if ($LASTEXITCODE -ne 0) { throw 'Could not reset staged source origin to official Hermes.' }

    & $gitExe config core.autocrlf false
    if ($LASTEXITCODE -ne 0) { throw 'Could not set staged core.autocrlf=false.' }
    & $gitExe config core.sparseCheckout true
    if ($LASTEXITCODE -ne 0) { throw 'Could not enable staged sparse checkout.' }
    & $gitExe config core.sparseCheckoutCone false
    if ($LASTEXITCODE -ne 0) { throw 'Could not select non-cone sparse checkout mode.' }

    $gitInfo = Join-Path $sourceStage '.git\info'
    New-Item -ItemType Directory -Force -Path $gitInfo | Out-Null
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText(
        (Join-Path $gitInfo 'sparse-checkout'),
        "/*`r`n!/contributors/`r`n",
        $utf8NoBom
    )

    # These are installer-generated artifacts, not source changes. Keeping them
    # out of status prevents the official updater from autostashing our marker
    # or the generated bin/ compatibility shims after networking is restored.
    $excludePath = Join-Path $gitInfo 'exclude'
    $excludeText = if (Test-Path -LiteralPath $excludePath -PathType Leaf) {
        [System.IO.File]::ReadAllText($excludePath)
    } else { '' }
    foreach ($pattern in @('/.hermes-offline-source.json', '/bin/')) {
        if ($excludeText -notmatch ('(?m)^' + [regex]::Escape($pattern) + '$')) {
            if ($excludeText -and -not $excludeText.EndsWith("`n")) { $excludeText += "`r`n" }
            $excludeText += "$pattern`r`n"
        }
    }
    [System.IO.File]::WriteAllText($excludePath, $excludeText, $utf8NoBom)

    # Only now materialize the worktree. contributors/ never reaches NTFS and
    # every tracked file is written with LF semantics from the outset.
    & $gitExe checkout --detach $HermesCommit
    if ($LASTEXITCODE -ne 0) { throw "Could not pin staged source clone to $HermesCommit" }

    $head = (& $gitExe rev-parse HEAD 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $head -ne $HermesCommit) {
        throw "Source staging HEAD mismatch: expected $HermesCommit, got $head"
    }

    if (Test-Path -LiteralPath (Join-Path $sourceStage 'contributors')) {
        throw 'Windows-safe staged checkout unexpectedly materialized contributors/.'
    }

    $autocrlf = (& $gitExe config --get core.autocrlf 2>$null | Out-String).Trim().ToLowerInvariant()
    if ($autocrlf -ne 'false') { throw "Staged checkout core.autocrlf is not false: $autocrlf" }
    $sparse = (& $gitExe config --get core.sparseCheckout 2>$null | Out-String).Trim().ToLowerInvariant()
    if ($sparse -notin @('true', 'yes', 'on', '1')) { throw "Staged sparse checkout is not enabled: $sparse" }

    $dirty = @(& $gitExe status --porcelain --untracked-files=no 2>$null | Where-Object { $_ -and $_.ToString().Trim() })
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect staged source Git status.' }
    if ($dirty.Count -gt 0) {
        throw "Windows-safe staged source checkout is tracked-dirty: $($dirty -join '; ')"
    }

    Write-Host "Windows-safe staged source is clean at $head; contributors/ excluded before checkout."
} finally {
    Pop-Location
}

$tarExe = Join-Path $env:SystemRoot 'System32\tar.exe'
if (-not (Test-Path -LiteralPath $tarExe -PathType Leaf)) {
    $tarExe = (Get-Command tar.exe -ErrorAction Stop).Source
}
if (Test-Path -LiteralPath $sourceArchive -PathType Leaf) {
    Remove-Item -LiteralPath $sourceArchive -Force
}
Write-Host 'Rebuilding hermes-source.tar.gz from Windows-safe source stage...'
& $tarExe -czf $sourceArchive -C $sourceStage .
if ($LASTEXITCODE -ne 0) { throw "tar failed while rebuilding hermes-source.tar.gz (exit $LASTEXITCODE)" }

# Sanity-check that no worktree contributor path leaked into the archive. Git
# objects may of course contain those historical blobs; only worktree paths are
# intentionally sparse.
$listing = @(& $tarExe -tzf $sourceArchive)
if ($LASTEXITCODE -ne 0) { throw 'Could not list rebuilt hermes-source.tar.gz.' }
if ($listing | Where-Object { $_ -match '^\.?/?contributors(?:/|$)' }) {
    throw 'Rebuilt Hermes source archive still contains a contributors/ worktree path.'
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$entry = @($manifest.archives) | Where-Object { $_.name -eq 'hermes-source.tar.gz' } | Select-Object -First 1
if (-not $entry) { throw 'Manifest has no hermes-source.tar.gz archive entry.' }
$entry.bytes = (Get-Item -LiteralPath $sourceArchive).Length
$entry.sha256 = (Get-FileHash -LiteralPath $sourceArchive -Algorithm SHA256).Hash.ToLowerInvariant()
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding utf8

Write-Host 'Rebuilt and rehashed Windows-safe Hermes source payload.'
