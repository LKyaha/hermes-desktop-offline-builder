param(
    [Parameter(Mandatory = $true)][string]$PayloadRoot,
    [Parameter(Mandatory = $true)][string]$UpstreamRoot
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$PayloadRoot = (Resolve-Path -LiteralPath $PayloadRoot).Path
$UpstreamRoot = (Resolve-Path -LiteralPath $UpstreamRoot).Path
$desktopRoot = Join-Path $UpstreamRoot 'apps\desktop'
$bundledMain = Join-Path $desktopRoot 'dist\electron-main.mjs'
$rendererIndex = Join-Path $desktopRoot 'dist\index.html'
$releaseRoot = Join-Path $desktopRoot 'release'
$winUnpacked = Join-Path $releaseRoot 'win-unpacked'
$archive = Join-Path $PayloadRoot 'desktop-win-x64.tar.gz'
$manifestPath = Join-Path $PayloadRoot 'manifest.json'

foreach ($required in @($bundledMain, $rendererIndex, $archive, $manifestPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Packaged Desktop hardening input is missing: $required"
    }
}

# Upstream intentionally supports HERMES_DESKTOP_DEV_SERVER for development,
# but main.ts currently prefers that runtime environment variable even in a
# packaged build. A stale User/System variable can therefore turn a perfectly
# valid production Hermes.exe into an empty Electron shell pointed at a dead
# http://127.0.0.1:5174 dev server. Harden ONLY the generated production bundle;
# the Git checkout remains byte-for-byte upstream so official updates keep a
# clean source tree.
$text = [System.IO.File]::ReadAllText($bundledMain)
$rx = [regex]::new('(\bDEV_SERVER\s*=\s*)process\.env\.HERMES_DESKTOP_DEV_SERVER')
$matches = $rx.Matches($text)
if ($matches.Count -ne 1) {
    throw "Expected exactly one packaged DEV_SERVER assignment in $bundledMain; found $($matches.Count). Upstream Desktop launch logic changed."
}
$patched = $rx.Replace($text, '${1}void 0', 1)
if ($patched -match '\bDEV_SERVER\s*=\s*process\.env\.HERMES_DESKTOP_DEV_SERVER') {
    throw 'Packaged Desktop still honors HERMES_DESKTOP_DEV_SERVER after hardening.'
}
[System.IO.File]::WriteAllText($bundledMain, $patched, [System.Text.UTF8Encoding]::new($false))
Write-Host 'Disabled runtime HERMES_DESKTOP_DEV_SERVER override in generated production electron-main.mjs.'

# Re-run only electron-builder. npm run pack already produced a clean install
# stamp and renderer bundle; rebuilding the package from the patched generated
# dist avoids touching tracked upstream source or marking the install stamp dirty.
if (Test-Path -LiteralPath $winUnpacked) {
    Remove-Item -LiteralPath $winUnpacked -Recurse -Force
}
$oldCsc = $env:CSC_IDENTITY_AUTO_DISCOVERY
$oldEngineStrict = $env:npm_config_engine_strict
try {
    $env:CSC_IDENTITY_AUTO_DISCOVERY = 'false'
    $env:npm_config_engine_strict = 'false'
    Push-Location $desktopRoot
    try {
        & npm run builder -- --dir --publish never
        if ($LASTEXITCODE -ne 0) {
            throw "electron-builder repack failed with exit $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
} finally {
    $env:CSC_IDENTITY_AUTO_DISCOVERY = $oldCsc
    $env:npm_config_engine_strict = $oldEngineStrict
}

$exe = Join-Path $winUnpacked 'Hermes.exe'
$icon = Join-Path $winUnpacked 'resources\icon.ico'
$unpackedMain = Join-Path $winUnpacked 'resources\app.asar.unpacked\dist\electron-main.mjs'
foreach ($required in @($exe, $icon, $unpackedMain)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Repacked Desktop is missing required production file: $required"
    }
}
if ((Get-Item -LiteralPath $icon).Length -lt 1024) {
    throw "Packaged Desktop icon looks invalid or empty: $icon"
}
$runtimeMainText = [System.IO.File]::ReadAllText($unpackedMain)
if ($runtimeMainText -match '\bDEV_SERVER\s*=\s*process\.env\.HERMES_DESKTOP_DEV_SERVER') {
    throw 'Repacked Hermes.exe still contains the packaged dev-server override.'
}

# Rebuild the Desktop payload archive from the corrected win-unpacked tree.
$tar = Join-Path $env:SystemRoot 'System32\tar.exe'
if (-not (Test-Path -LiteralPath $tar -PathType Leaf)) {
    $tarCmd = Get-Command tar.exe -ErrorAction SilentlyContinue
    if (-not $tarCmd) { throw 'Windows inbox tar.exe is required to rebuild the Desktop payload.' }
    $tar = $tarCmd.Source
}
$newArchive = "$archive.new"
if (Test-Path -LiteralPath $newArchive) { Remove-Item -LiteralPath $newArchive -Force }
& $tar -czf $newArchive -C $releaseRoot 'win-unpacked'
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $newArchive -PathType Leaf)) {
    throw 'Failed to rebuild desktop-win-x64.tar.gz after Desktop hardening.'
}
Move-Item -LiteralPath $newArchive -Destination $archive -Force

$listing = & $tar -tzf $archive
if ($LASTEXITCODE -ne 0 -or -not ($listing -match 'win-unpacked[/\\]Hermes\.exe')) {
    throw 'Hardened Desktop archive does not contain win-unpacked/Hermes.exe.'
}
if (-not ($listing -match 'win-unpacked[/\\]resources[/\\]icon\.ico')) {
    throw 'Hardened Desktop archive does not contain resources/icon.ico.'
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$entry = @($manifest.archives | Where-Object { $_.name -eq 'desktop-win-x64.tar.gz' })
if ($entry.Count -ne 1) {
    throw "Payload manifest should contain exactly one desktop-win-x64.tar.gz entry; found $($entry.Count)."
}
$archiveInfo = Get-Item -LiteralPath $archive
$entry[0].bytes = $archiveInfo.Length
$entry[0].sha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
$manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding utf8

# The production-only patch must never dirty the tracked upstream checkout.
$trackedStatus = (& git -C $UpstreamRoot status --porcelain --untracked-files=no | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Could not verify upstream Git status after Desktop hardening.' }
if ($trackedStatus) {
    throw "Desktop hardening dirtied tracked upstream source unexpectedly:`n$trackedStatus"
}

Write-Host "Hardened packaged Desktop and refreshed payload archive: $archive"
Write-Host "Desktop SHA256: $($entry[0].sha256)"
