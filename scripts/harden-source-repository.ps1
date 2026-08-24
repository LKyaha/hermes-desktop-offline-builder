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

# The build checkout is intentionally allowed to be a Git partial clone for CI
# speed. It must NEVER be used as the parent of the checkout shipped to users.
# A local clone of a partial/promisor repository can look healthy while the
# original CI object store is still present, then fail later on a clean machine
# when `git fetch origin main` receives thin-pack deltas whose bases are absent.
# Build the distributable checkout directly from the official remote instead.
if (Test-Path -LiteralPath $sourceStage) {
    Remove-Item -LiteralPath $sourceStage -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $sourceStage | Out-Null

Write-Host 'Rebuilding bundled Hermes source as a self-contained non-partial Git checkout...'
& git -C $sourceStage init
if ($LASTEXITCODE -ne 0) { throw 'git init failed for bundled source checkout.' }
& git -C $sourceStage remote add origin $officialOrigin
if ($LASTEXITCODE -ne 0) { throw 'Could not add official Hermes origin.' }

# Fetch a depth-1 snapshot: all objects needed by the packaged release are
# present, but we do not bloat the offline installer with the repository's full
# history. Prefer the user/build ref (release tag in normal automation), then
# fall back to the exact commit for manual SHA builds.
$fetchCandidates = @($HermesRef, $HermesCommit) |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -Unique
$fetched = $false
foreach ($candidate in $fetchCandidates) {
    Write-Host "Fetching complete release snapshot from official origin: $candidate"
    & git -C $sourceStage fetch --depth=1 --no-tags origin $candidate
    if ($LASTEXITCODE -eq 0) {
        & git -C $sourceStage cat-file -e "$HermesCommit^{commit}" 2>$null
        if ($LASTEXITCODE -eq 0) {
            $fetched = $true
            break
        }
    }
}
if (-not $fetched) {
    throw "Could not fetch a complete official snapshot containing $HermesCommit"
}

& git -C $sourceStage checkout --detach $HermesCommit
if ($LASTEXITCODE -ne 0) { throw "Could not checkout bundled Hermes commit $HermesCommit" }

$head = (& git -C $sourceStage rev-parse HEAD | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $head -ne $HermesCommit) {
    throw "Bundled source HEAD mismatch: expected $HermesCommit, got $head"
}
$origin = (& git -C $sourceStage remote get-url origin | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $origin -ne $officialOrigin) {
    throw "Bundled source origin mismatch: $origin"
}

# Fail closed on every mechanism that can make a repository depend on objects
# outside the archive. A normal depth-1 clone has .git/shallow; that is safe.
$gitDir = Join-Path $sourceStage '.git'
$alternates = Join-Path $gitDir 'objects\info\alternates'
if (Test-Path -LiteralPath $alternates -PathType Leaf) {
    throw 'Bundled source repository unexpectedly contains an objects/info/alternates dependency.'
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

# `git fsck` plus explicit object reads guarantee the current release snapshot
# does not rely on missing objects. This is the invariant the previous local
# clone failed to enforce.
& git -C $sourceStage fsck --full --no-reflogs
if ($LASTEXITCODE -ne 0) { throw 'Bundled source repository failed git fsck.' }
& git -C $sourceStage rev-list --objects HEAD | ForEach-Object {
    $oid = ($_ -split ' ', 2)[0]
    if ($oid) {
        & git -C $sourceStage cat-file -e $oid 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Bundled source is missing reachable object $oid" }
    }
}
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
Write-Host 'Rebuilding hermes-source.tar.gz from self-contained checkout...'
& $tar -czf $sourceArchive -C $sourceStage .
if ($LASTEXITCODE -ne 0) { throw 'Failed to rebuild hermes-source.tar.gz.' }

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$entry = @($manifest.archives | Where-Object { $_.name -eq 'hermes-source.tar.gz' })
if ($entry.Count -ne 1) { throw 'manifest.json does not contain exactly one hermes-source.tar.gz entry.' }
$sourceFile = Get-Item -LiteralPath $sourceArchive
$entry[0].bytes = [int64]$sourceFile.Length
$entry[0].sha256 = (Get-FileHash -LiteralPath $sourceArchive -Algorithm SHA256).Hash.ToLowerInvariant()
$manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding utf8

Write-Host "Bundled source checkout hardened: $HermesCommit"
Write-Host "Source archive: $($sourceFile.Length) bytes, sha256=$($entry[0].sha256)"
