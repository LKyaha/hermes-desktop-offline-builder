param(
    [Parameter(Mandatory = $true)][string]$UpstreamInstallScript,
    [Parameter(Mandatory = $true)][string]$OutputScript,
    [Parameter(Mandatory = $true)][string]$HermesCommit
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $UpstreamInstallScript -PathType Leaf)) {
    throw "Upstream install.ps1 not found: $UpstreamInstallScript"
}

$source = [System.IO.File]::ReadAllText($UpstreamInstallScript)
$marker = '# Stage definitions -- the single source of truth.'
$markerIndex = $source.IndexOf($marker, [System.StringComparison]::Ordinal)
if ($markerIndex -lt 0) {
    throw "Could not find stage-definition insertion marker in upstream install.ps1. Upstream installer structure changed; refusing to emit an unverified offline script."
}

$adapter = @'
# ============================================================================
# Hermes Desktop Offline Builder adapter
# ============================================================================
# This block is injected by hermes-desktop-offline-builder. It deliberately
# leaves the upstream stage protocol intact and changes only the data source:
# managed prerequisites, package caches, repository source and the prebuilt
# Desktop app come from HERMES_OFFLINE_PAYLOAD instead of the network.

$script:HermesOfflinePayload = $env:HERMES_OFFLINE_PAYLOAD
$script:HermesOfflineMode = (
    -not [string]::IsNullOrWhiteSpace($script:HermesOfflinePayload) -and
    (Test-Path -LiteralPath (Join-Path $script:HermesOfflinePayload 'manifest.json') -PathType Leaf)
)

function Invoke-HermesOfflineTarExtract {
    param(
        [Parameter(Mandatory = $true)][string]$ArchiveName,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $archive = Join-Path $script:HermesOfflinePayload $ArchiveName
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
        throw "Offline payload is incomplete: missing $archive"
    }

    $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
    if (-not $tar) { $tar = Get-Command tar -ErrorAction SilentlyContinue }
    if (-not $tar) {
        throw 'Windows tar.exe is required to unpack the Hermes offline payload.'
    }

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Write-Info "Expanding offline payload $ArchiveName ..."
    & $tar.Source -xzf $archive -C $Destination
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to extract $ArchiveName (tar exit $LASTEXITCODE)"
    }
}

function Initialize-HermesOfflineEnvironment {
    if (-not $script:HermesOfflineMode) { return }

    New-Item -ItemType Directory -Force -Path $HermesHome | Out-Null

    $manifest = Get-Content -LiteralPath (Join-Path $script:HermesOfflinePayload 'manifest.json') -Raw | ConvertFrom-Json
    $runtimeMarker = Join-Path $HermesHome '.hermes-offline-runtime.json'
    $runtimeNeedsRefresh = $true
    if (Test-Path -LiteralPath $runtimeMarker -PathType Leaf) {
        try {
            $old = Get-Content -LiteralPath $runtimeMarker -Raw | ConvertFrom-Json
            if ($old.hermes_commit -eq $manifest.hermes_commit) {
                $runtimeNeedsRefresh = $false
            }
        } catch { }
    }

    if ($runtimeNeedsRefresh -or -not (Test-Path -LiteralPath (Join-Path $HermesHome 'bin\uv.exe'))) {
        Invoke-HermesOfflineTarExtract -ArchiveName 'managed-runtime.tar.gz' -Destination $HermesHome
    }
    if ($runtimeNeedsRefresh -or -not (Test-Path -LiteralPath (Join-Path $HermesHome 'uv-cache'))) {
        Invoke-HermesOfflineTarExtract -ArchiveName 'uv-cache.tar.gz' -Destination (Join-Path $HermesHome 'uv-cache')
    }
    if ($runtimeNeedsRefresh -or -not (Test-Path -LiteralPath (Join-Path $HermesHome 'npm-cache'))) {
        Invoke-HermesOfflineTarExtract -ArchiveName 'npm-cache.tar.gz' -Destination (Join-Path $HermesHome 'npm-cache')
    }
    if ($runtimeNeedsRefresh -or -not (Test-Path -LiteralPath (Join-Path $HermesHome 'ms-playwright'))) {
        Invoke-HermesOfflineTarExtract -ArchiveName 'ms-playwright.tar.gz' -Destination (Join-Path $HermesHome 'ms-playwright')
    }

    $runtimeRecord = [ordered]@{
        schema = 1
        hermes_commit = $manifest.hermes_commit
        hermes_ref = $manifest.hermes_ref
        prepared_at = $manifest.prepared_at
    } | ConvertTo-Json
    [System.IO.File]::WriteAllText($runtimeMarker, $runtimeRecord, (New-Object System.Text.UTF8Encoding $false))

    # Make every upstream stage see the managed offline toolchain first.
    $pathFront = @(
        (Join-Path $HermesHome 'bin'),
        (Join-Path $HermesHome 'node'),
        (Join-Path $HermesHome 'git\cmd'),
        (Join-Path $HermesHome 'git\bin'),
        (Join-Path $HermesHome 'git\usr\bin'),
        (Join-Path $HermesHome 'tools\bin')
    ) | Where-Object { Test-Path -LiteralPath $_ }
    if ($pathFront.Count -gt 0) {
        $env:Path = (($pathFront -join ';') + ';' + $env:Path)
    }

    # uv: managed Python + a build-time-warmed cache, with network hard-disabled.
    $env:UV_PYTHON_INSTALL_DIR = Join-Path $HermesHome 'python'
    $env:UV_CACHE_DIR = Join-Path $HermesHome 'uv-cache'
    $env:UV_OFFLINE = '1'
    $env:UV_NO_PROGRESS = '1'

    # npm/npx: cache-only mode. Any missing tarball becomes a hard build defect
    # instead of silently reaching the registry from the target machine.
    $env:NPM_CONFIG_CACHE = Join-Path $HermesHome 'npm-cache'
    $env:NPM_CONFIG_OFFLINE = 'true'
    $env:NPM_CONFIG_PREFER_OFFLINE = 'true'
    $env:NPM_CONFIG_AUDIT = 'false'
    $env:NPM_CONFIG_FUND = 'false'

    # Playwright uses this location both for installation and runtime lookup.
    $env:PLAYWRIGHT_BROWSERS_PATH = Join-Path $HermesHome 'ms-playwright'

    Write-Info "Hermes offline mode active (payload commit $($manifest.hermes_commit))"
}

# Preserve upstream implementations so the generated script can still be run
# normally when HERMES_OFFLINE_PAYLOAD is not supplied.
$script:HermesOnlineInstallRepository = (Get-Item Function:\Install-Repository).ScriptBlock
$script:HermesOnlineInstallDesktop = (Get-Item Function:\Install-Desktop).ScriptBlock

function Install-Repository {
    if (-not $script:HermesOfflineMode) {
        & $script:HermesOnlineInstallRepository
        return
    }

    $manifest = Get-Content -LiteralPath (Join-Path $script:HermesOfflinePayload 'manifest.json') -Raw | ConvertFrom-Json
    $sourceArchive = Join-Path $script:HermesOfflinePayload 'hermes-source.tar.gz'
    if (-not (Test-Path -LiteralPath $sourceArchive -PathType Leaf)) {
        throw "Offline payload is incomplete: missing $sourceArchive"
    }

    $versionMarker = Join-Path $InstallDir '.hermes-offline-source.json'
    if ((Test-Path -LiteralPath $versionMarker -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $InstallDir '.git'))) {
        try {
            $current = Get-Content -LiteralPath $versionMarker -Raw | ConvertFrom-Json
            if ($current.hermes_commit -eq $manifest.hermes_commit) {
                Write-Success "Bundled Hermes source already installed ($($manifest.hermes_ref))"
                return
            }
        } catch { }
    }

    if (Test-Path -LiteralPath $InstallDir) {
        $backup = "$InstallDir.offline-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Write-Warn "Replacing the managed Hermes checkout with bundled $($manifest.hermes_ref)."
        Write-Warn "The previous checkout is preserved at $backup."
        Move-Item -LiteralPath $InstallDir -Destination $backup -ErrorAction Stop
    }

    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Invoke-HermesOfflineTarExtract -ArchiveName 'hermes-source.tar.gz' -Destination $InstallDir

    if (-not (Test-Path -LiteralPath (Join-Path $InstallDir '.git'))) {
        throw 'Bundled Hermes source extracted but .git metadata is missing.'
    }

    Push-Location $InstallDir
    try {
        git -c windows.appendAtomically=false config windows.appendAtomically false 2>$null
        git -c windows.appendAtomically=false config core.autocrlf false 2>$null
        $head = (& git rev-parse HEAD 2>$null).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $head) {
            throw 'Bundled Hermes checkout has no resolvable HEAD.'
        }
        if ($head -ne $manifest.hermes_commit) {
            throw "Bundled source HEAD $head does not match manifest commit $($manifest.hermes_commit)."
        }
    } finally {
        Pop-Location
    }

    $record = [ordered]@{
        schema = 1
        hermes_commit = $manifest.hermes_commit
        hermes_ref = $manifest.hermes_ref
    } | ConvertTo-Json
    [System.IO.File]::WriteAllText($versionMarker, $record, (New-Object System.Text.UTF8Encoding $false))
    Write-Success "Bundled Hermes source installed ($($manifest.hermes_ref))"
}

function Install-Desktop {
    if (-not $script:HermesOfflineMode) {
        & $script:HermesOnlineInstallDesktop
        return
    }

    $releaseDir = Join-Path $InstallDir 'apps\desktop\release'
    $desktopDir = Join-Path $releaseDir 'win-unpacked'
    if (Test-Path -LiteralPath $desktopDir) {
        Remove-Item -LiteralPath $desktopDir -Recurse -Force -ErrorAction Stop
    }
    New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null
    Invoke-HermesOfflineTarExtract -ArchiveName 'desktop-win-x64.tar.gz' -Destination $releaseDir

    $desktopExe = Join-Path $desktopDir 'Hermes.exe'
    if (-not (Test-Path -LiteralPath $desktopExe -PathType Leaf)) {
        throw "Offline Desktop payload extracted but Hermes.exe is missing at $desktopExe"
    }
    Write-Success 'Desktop app installed from prebuilt offline payload'
}

if ($script:HermesOfflineMode -and -not $Manifest) {
    Initialize-HermesOfflineEnvironment
}

# End Hermes Desktop Offline Builder adapter

'@

$patched = $source.Insert($markerIndex, $adapter)

# Stamp the builder commit into a comment for forensic support. This is not used
# as executable data; the upstream -Commit argument remains authoritative.
$patched = "# Offline payload target commit: $HermesCommit`r`n" + $patched

$outDir = Split-Path -Parent $OutputScript
if ($outDir) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

# Windows PowerShell 5.1 interprets BOM-less script files using the active ANSI
# code page. Match upstream bootstrap-cache behavior and emit UTF-8 with BOM.
$utf8Bom = New-Object System.Text.UTF8Encoding $true
[System.IO.File]::WriteAllText($OutputScript, $patched, $utf8Bom)

Write-Host "Generated offline install script: $OutputScript"
