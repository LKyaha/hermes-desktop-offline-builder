param(
    [Parameter(Mandatory = $true)][string]$WorkRoot,
    [Parameter(Mandatory = $true)][string]$PayloadRoot,
    [Parameter(Mandatory = $true)][string]$HermesRef,
    [Parameter(Mandatory = $true)][string]$HermesCommit
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$WorkRoot = (Resolve-Path -LiteralPath $WorkRoot).Path
$PayloadRoot = (Resolve-Path -LiteralPath $PayloadRoot).Path
$sourceStage = Join-Path $WorkRoot 'source-stage'
$sourceArchive = Join-Path $PayloadRoot 'hermes-source.tar.gz'
$manifestPath = Join-Path $PayloadRoot 'manifest.json'
$officialOrigin = 'https://github.com/NousResearch/hermes-agent.git'

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Offline payload manifest is missing: $manifestPath"
}

# The build checkout may be a partial clone for CI speed. The checkout shipped
# to users must be independent of that build tree AND must not be shallow.
# Hermes' official Windows updater performs ancestry/fetch/reset operations that
# are not reliable across a shallow boundary. A depth-1 repository can pass
# `git fsck`, run the packaged release perfectly, and still fail or mis-align on
# the first in-app update. Therefore the distributable source repository is a
# full-history, non-partial clone made directly from the official remote.
if (Test-Path -LiteralPath $sourceStage) {
    Remove-Item -LiteralPath $sourceStage -Recurse -Force
}

Write-Host 'Rebuilding bundled Hermes source as a full-history, non-partial Git checkout...'
& git clone --no-tags --no-checkout $officialOrigin $sourceStage
if ($LASTEXITCODE -ne 0) { throw 'Could not clone full Hermes history from the official origin.' }

# A manually requested commit/ref can theoretically be outside the default
# branch history. Fetch it without depth if the full clone did not already
# obtain it. Never introduce a shallow boundary here.
& git -C $sourceStage cat-file -e "$HermesCommit^{commit}" 2>$null
if ($LASTEXITCODE -ne 0) {
    $fetchCandidates = @($HermesRef, $HermesCommit) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
    $fetched = $false
    foreach ($candidate in $fetchCandidates) {
        Write-Host "Fetching requested full-history ref from official origin: $candidate"
        & git -C $sourceStage fetch --no-tags origin $candidate
        if ($LASTEXITCODE -eq 0) {
            & git -C $sourceStage cat-file -e "$HermesCommit^{commit}" 2>$null
            if ($LASTEXITCODE -eq 0) {
                $fetched = $true
                break
            }
        }
    }
    if (-not $fetched) {
        throw "Could not fetch official commit $HermesCommit"
    }
}

# Windows cannot materialize upstream contributor metadata paths that differ
# only by case. Exclude that metadata-only tree before checkout, matching the
# target-side updater handoff hardening, so the staged worktree stays clean.
$gitDir = Join-Path $sourceStage '.git'
$gitInfo = Join-Path $gitDir 'info'
New-Item -ItemType Directory -Force -Path $gitInfo | Out-Null
& git -C $sourceStage config core.autocrlf false
if ($LASTEXITCODE -ne 0) { throw 'Could not configure core.autocrlf for bundled checkout.' }
& git -C $sourceStage config core.sparseCheckout true
if ($LASTEXITCODE -ne 0) { throw 'Could not enable sparse checkout for bundled checkout.' }
& git -C $sourceStage config core.sparseCheckoutCone false
if ($LASTEXITCODE -ne 0) { throw 'Could not select non-cone sparse checkout mode.' }
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText((Join-Path $gitInfo 'sparse-checkout'), "/*`r`n!/contributors/`r`n", $utf8NoBom)

& git -C $sourceStage checkout --detach $HermesCommit
if ($LASTEXITCODE -ne 0) { throw "Could not checkout bundled Hermes commit $HermesCommit" }
& git -C $sourceStage read-tree -mu HEAD
if ($LASTEXITCODE -ne 0) { throw 'Could not apply sparse checkout to bundled Hermes source.' }

$head = (& git -C $sourceStage rev-parse HEAD | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $head -ne $HermesCommit) {
    throw "Bundled source HEAD mismatch: expected $HermesCommit, got $head"
}
$origin = (& git -C $sourceStage remote get-url origin | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $origin -ne $officialOrigin) {
    throw "Bundled source origin mismatch: $origin"
}

# Fail closed on every mechanism that can make the shipped repository depend on
# hidden external objects or truncated history.
$alternates = Join-Path $gitDir 'objects\info\alternates'
if (Test-Path -LiteralPath $alternates -PathType Leaf) {
    throw 'Bundled source repository unexpectedly contains an objects/info/alternates dependency.'
}
$shallowFile = Join-Path $gitDir 'shallow'
if (Test-Path -LiteralPath $shallowFile -PathType Leaf) {
    throw 'Bundled source repository is shallow; official Desktop update compatibility requires full history.'
}
foreach ($key in @('extensions.partialClone', 'remote.origin.promisor', 'remote.origin.partialclonefilter')) {
    $value = (& git -C $sourceStage config --local --get $key 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($value)) {
        throw "Bundled source repository unexpectedly carries partial-clone config: $key=$value"
    }
}
$promisorPacks = @(Get-ChildItem -LiteralPath (Join-Path $gitDir 'objects\pack') -Filter '*.promisor' -File -ErrorAction SilentlyContinue)
if ($promisorPacks.Count -gt 0) {
    throw "Bundled source repository contains promisor pack metadata: $(($promisorPacks.Name) -join ', ')"
}

# Full fsck verifies the history/object database that the official updater will
# inherit, not merely the current release tree.
& git -C $sourceStage fsck --full --no-reflogs
if ($LASTEXITCODE -ne 0) { throw 'Bundled full-history source repository failed git fsck.' }
$status = (& git -C $sourceStage status --porcelain=v1 --untracked-files=no | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Could not verify bundled source worktree status.' }
if ($status) { throw "Bundled source worktree is not clean:`n$status" }

# Rebuild only the source archive. Use Windows inbox bsdtar explicitly so a
# PortableGit tar earlier on PATH cannot reinterpret drive-letter paths.
$tar = Join-Path $env:SystemRoot 'System32\tar.exe'
if (-not (Test-Path -LiteralPath $tar -PathType Leaf)) {
    $tar = (Get-Command tar.exe -ErrorAction Stop).Source
}
if (Test-Path -LiteralPath $sourceArchive) { Remove-Item -LiteralPath $sourceArchive -Force }
Write-Host 'Rebuilding hermes-source.tar.gz from full-history checkout...'
& $tar -czf $sourceArchive -C $sourceStage .
if ($LASTEXITCODE -ne 0) { throw 'Failed to rebuild hermes-source.tar.gz.' }

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$entry = @($manifest.archives | Where-Object { $_.name -eq 'hermes-source.tar.gz' })
if ($entry.Count -ne 1) { throw 'manifest.json does not contain exactly one hermes-source.tar.gz entry.' }
$sourceFile = Get-Item -LiteralPath $sourceArchive
$entry[0].bytes = [int64]$sourceFile.Length
$entry[0].sha256 = (Get-FileHash -LiteralPath $sourceArchive -Algorithm SHA256).Hash.ToLowerInvariant()
$manifest | Add-Member -NotePropertyName git_history -NotePropertyValue 'full' -Force
$manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding utf8

Write-Host "Bundled full-history source checkout hardened: $HermesCommit"
Write-Host "Source archive: $($sourceFile.Length) bytes, sha256=$($entry[0].sha256)"
