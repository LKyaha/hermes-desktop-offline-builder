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
# Injected by hermes-desktop-offline-builder. The upstream stage protocol and
# UI contract are kept intact; only the backing data source changes.

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

    # IMPORTANT: do not resolve tar from PATH first. Once the bundled
    # PortableGit is activated, Git for Windows' GNU tar precedes the Windows
    # bsdtar and interprets a native path like D:\bundle\file.tar.gz as
    # host "D" + remote path, producing "Cannot connect to D". Windows'
    # inbox bsdtar accepts drive-letter paths and is what the earlier payload
    # extraction stages already use successfully.
    $tarExe = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (-not (Test-Path -LiteralPath $tarExe -PathType Leaf)) {
        $tarCmd = Get-Command tar.exe -ErrorAction SilentlyContinue
        if (-not $tarCmd) { $tarCmd = Get-Command tar -ErrorAction SilentlyContinue }
        if (-not $tarCmd) { throw 'Windows tar.exe is required to unpack the Hermes offline payload.' }
        $tarExe = $tarCmd.Source
    }

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Write-Info "Expanding offline payload $ArchiveName ..."
    & $tarExe -xzf $archive -C $Destination
    if ($LASTEXITCODE -ne 0) { throw "Failed to extract $ArchiveName (tar exit $LASTEXITCODE; executable $tarExe)" }
}

function Set-HermesOfflineUserPath {
    param([string[]]$Entries)

    $entries = @($Entries | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
    if ($entries.Count -eq 0) { return }

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $old = if ($userPath) { @($userPath -split ';' | Where-Object { $_ }) } else { @() }
    $seen = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    $ordered = New-Object System.Collections.Generic.List[string]
    foreach ($entry in (@($entries) + @($old))) {
        if ($entry -and $seen.Add($entry)) { $ordered.Add($entry) }
    }
    [Environment]::SetEnvironmentVariable('Path', ([string]::Join(';', $ordered)), 'User')
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
            if ($old.hermes_commit -eq $manifest.hermes_commit) { $runtimeNeedsRefresh = $false }
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
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($runtimeMarker, $runtimeRecord, $utf8NoBom)

    $processPathFront = @(
        (Join-Path $HermesHome 'bin'),
        (Join-Path $HermesHome 'node'),
        (Join-Path $HermesHome 'git\cmd'),
        (Join-Path $HermesHome 'git\bin'),
        (Join-Path $HermesHome 'git\usr\bin'),
        (Join-Path $HermesHome 'tools\bin')
    ) | Where-Object { Test-Path -LiteralPath $_ }
    if ($processPathFront.Count -gt 0) {
        $env:Path = (($processPathFront -join ';') + ';' + $env:Path)
    }

    $persistentPath = @(
        (Join-Path $HermesHome 'node'),
        (Join-Path $HermesHome 'git\cmd'),
        (Join-Path $HermesHome 'git\bin'),
        (Join-Path $HermesHome 'git\usr\bin'),
        (Join-Path $HermesHome 'tools\bin')
    )
    Set-HermesOfflineUserPath -Entries $persistentPath

    $managedBash = Join-Path $HermesHome 'git\bin\bash.exe'
    if (Test-Path -LiteralPath $managedBash -PathType Leaf) {
        $env:HERMES_GIT_BASH_PATH = $managedBash
        [Environment]::SetEnvironmentVariable('HERMES_GIT_BASH_PATH', $managedBash, 'User')
    }

    $env:UV_PYTHON_INSTALL_DIR = Join-Path $HermesHome 'python'
    $env:UV_CACHE_DIR = Join-Path $HermesHome 'uv-cache'
    $env:UV_TOOL_DIR = Join-Path $HermesHome 'uv-tools'
    $env:UV_OFFLINE = '1'
    $env:UV_NO_PROGRESS = '1'

    $env:NPM_CONFIG_CACHE = Join-Path $HermesHome 'npm-cache'
    $env:NPM_CONFIG_OFFLINE = 'true'
    $env:NPM_CONFIG_PREFER_OFFLINE = 'true'
    $env:NPM_CONFIG_AUDIT = 'false'
    $env:NPM_CONFIG_FUND = 'false'

    $env:PLAYWRIGHT_BROWSERS_PATH = Join-Path $HermesHome 'ms-playwright'
    Write-Info "Hermes offline mode active (payload commit $($manifest.hermes_commit))"
}

# Preserve online implementations. Offline wrappers below can reuse the exact
# upstream behavior, then promote optional warnings to hard validation gates.
$script:HermesOnlineInstallRepository = (Get-Item Function:\Install-Repository).ScriptBlock
$script:HermesOnlineInstallDesktop = (Get-Item Function:\Install-Desktop).ScriptBlock
$script:HermesOnlineInstallDesktopVoiceDeps = (Get-Item Function:\Install-DesktopVoiceDeps).ScriptBlock
$script:HermesOnlineInstallBrowserUseCli = (Get-Item Function:\Install-BrowserUseCli).ScriptBlock
$script:HermesOnlineInstallCuaDriver = (Get-Item Function:\Install-CuaDriver).ScriptBlock

function Install-Repository {
    if (-not $script:HermesOfflineMode) { & $script:HermesOnlineInstallRepository; return }

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
        if ($LASTEXITCODE -ne 0 -or -not $head) { throw 'Bundled Hermes checkout has no resolvable HEAD.' }
        if ($head -ne $manifest.hermes_commit) {
            throw "Bundled source HEAD $head does not match manifest commit $($manifest.hermes_commit)."
        }
    } finally {
        Pop-Location
    }

    $record = [ordered]@{ schema = 1; hermes_commit = $manifest.hermes_commit; hermes_ref = $manifest.hermes_ref } | ConvertTo-Json
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($versionMarker, $record, $utf8NoBom)
    Write-Success "Bundled Hermes source installed ($($manifest.hermes_ref))"
}

function Install-DesktopVoiceDeps {
    if (-not $script:HermesOfflineMode) { & $script:HermesOnlineInstallDesktopVoiceDeps; return }

    & $script:HermesOnlineInstallDesktopVoiceDeps
    $python = Join-Path $InstallDir 'venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw 'Voice validation failed: venv Python is missing.' }
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $python -c 'import onnxruntime, faster_whisper, sounddevice, openwakeword' 2>&1 | Out-Null
    $voiceExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP
    if ($voiceExit -ne 0) {
        throw 'Bundled offline cache is missing one or more Desktop voice/wake dependencies.'
    }
    Write-Success 'Offline voice + wake-word dependencies verified'
}

function Install-BrowserUseCli {
    if (-not $script:HermesOfflineMode) { & $script:HermesOnlineInstallBrowserUseCli; return }

    & $script:HermesOnlineInstallBrowserUseCli
    $managedBrowserUse = Join-Path $HermesHome 'bin\browser-use.exe'
    if (-not (Test-Path -LiteralPath $managedBrowserUse -PathType Leaf)) {
        throw 'Bundled uv cache could not provision browser-use CLI in offline mode.'
    }
    Write-Success 'Offline Browser Use CLI verified'
}

function Install-CuaDriver {
    if (-not $script:HermesOfflineMode) { & $script:HermesOnlineInstallCuaDriver; return }

    if ($SkipComputerUse) {
        Write-Info 'Skipping Computer Use (-SkipComputerUse)'
        return
    }
    $driver = Get-Command cua-driver -ErrorAction SilentlyContinue
    if (-not $driver) { throw 'Offline payload is missing cua-driver.exe.' }
    if (-not (Test-CuaDriverRuntimeContract -DriverPath $driver.Source)) {
        throw "Bundled cua-driver is incompatible: $($driver.Source)"
    }
    Write-Success 'Bundled Computer Use driver verified'
}

function Install-Desktop {
    if (-not $script:HermesOfflineMode) { & $script:HermesOnlineInstallDesktop; return }

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

    # Preserve the official post-pack integration that would normally run after
    # npm run pack: Chromium AppContainer ACL + Desktop/Start Menu shortcuts.
    try {
        & icacls $desktopDir /grant '*S-1-15-2-2:(OI)(CI)(RX)' /T /C /Q | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warn "AppContainer ACL grant returned exit $LASTEXITCODE" }
    } catch {
        Write-Warn "Could not grant AppContainer ACL: $($_.Exception.Message)"
    }
    New-DesktopShortcuts -TargetExe $desktopExe
    Write-Success 'Desktop app installed from prebuilt offline payload'
}

if ($script:HermesOfflineMode -and -not $Manifest) {
    Initialize-HermesOfflineEnvironment
}

# In packaged/CI strict mode, any upstream PowerShell HTTP call is a build
# defect. uv/npm have their own explicit offline modes above.
if ($script:HermesOfflineMode -and $env:HERMES_OFFLINE_STRICT -eq '1') {
    function Invoke-WebRequest { throw 'Network access blocked by HERMES_OFFLINE_STRICT (Invoke-WebRequest).' }
    function Invoke-RestMethod { throw 'Network access blocked by HERMES_OFFLINE_STRICT (Invoke-RestMethod).' }
}

# End Hermes Desktop Offline Builder adapter

'@

$patched = $source.Insert($markerIndex, $adapter)
$patched = "# Offline payload target commit: $HermesCommit`r`n" + $patched

$outDir = Split-Path -Parent $OutputScript
if ($outDir) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

# Windows PowerShell 5.1 interprets BOM-less script files using the active ANSI
# code page. Match upstream bootstrap-cache behavior and emit UTF-8 with BOM.
$utf8Bom = New-Object System.Text.UTF8Encoding $true
[System.IO.File]::WriteAllText($OutputScript, $patched, $utf8Bom)

Write-Host "Generated offline install script: $OutputScript"
