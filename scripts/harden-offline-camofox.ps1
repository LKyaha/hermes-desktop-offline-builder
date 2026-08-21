param(
    [Parameter(Mandatory = $true)][string]$InstallScript,
    [string]$WorkRoot = $(Join-Path (Split-Path $PSScriptRoot -Parent) 'offline-work'),
    [string]$PayloadRoot = $(Join-Path (Split-Path $PSScriptRoot -Parent) 'offline-bundle\payload')
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $InstallScript -PathType Leaf)) {
    throw "Generated install script not found: $InstallScript"
}

# ---------------------------------------------------------------------------
# Materialize Camofox into the bundled Node prefix at BUILD time.
# ---------------------------------------------------------------------------
# npm's cache is not a reproducible package store for a later global semver
# install: an online `npm install -g @askjo/camofox-browser@^1.5.2` can succeed
# and populate _cacache while a fresh `npm install -g --offline` still needs
# registry metadata that npm did not retain in a form it can resolve offline.
# Full Offline therefore ships the already-materialized global package tree.
# The target machine only verifies it; it never asks npm to reconstruct it.

$managedRoot = Join-Path $WorkRoot 'managed-runtime'
$nodeRoot = Join-Path $managedRoot 'node'
$npmCache = Join-Path $WorkRoot 'npm-cache'
$managedArchive = Join-Path $PayloadRoot 'managed-runtime.tar.gz'
$manifestPath = Join-Path $PayloadRoot 'manifest.json'
$npmExe = Join-Path $nodeRoot 'npm.cmd'

foreach ($required in @($managedRoot, $nodeRoot, $npmCache, $PayloadRoot)) {
    if (-not (Test-Path -LiteralPath $required -PathType Container)) {
        throw "Camofox payload finalization is missing build directory: $required"
    }
}
if (-not (Test-Path -LiteralPath $npmExe -PathType Leaf)) {
    throw "Bundled Node npm.cmd was not found: $npmExe"
}
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Offline payload manifest was not found: $manifestPath"
}

$oldCache = $env:NPM_CONFIG_CACHE
$oldAudit = $env:NPM_CONFIG_AUDIT
$oldFund = $env:NPM_CONFIG_FUND
$oldOffline = $env:NPM_CONFIG_OFFLINE
$oldPreferOffline = $env:NPM_CONFIG_PREFER_OFFLINE
try {
    $env:NPM_CONFIG_CACHE = $npmCache
    $env:NPM_CONFIG_AUDIT = 'false'
    $env:NPM_CONFIG_FUND = 'false'
    Remove-Item Env:\NPM_CONFIG_OFFLINE -ErrorAction SilentlyContinue
    Remove-Item Env:\NPM_CONFIG_PREFER_OFFLINE -ErrorAction SilentlyContinue

    Write-Host 'Materializing Camofox into bundled managed Node runtime...'
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $npmExe install -g --prefix $nodeRoot --ignore-scripts --no-audit --no-fund '@askjo/camofox-browser@^1.5.2' 2>&1 |
        ForEach-Object { "$_" | Write-Host }
    $npmExit = $LASTEXITCODE
    $ErrorActionPreference = $previousEap
    if ($npmExit -ne 0) {
        throw "Build-time Camofox materialization failed (npm exit $npmExit)."
    }
} finally {
    $ErrorActionPreference = 'Stop'
    if ($null -eq $oldCache) { Remove-Item Env:\NPM_CONFIG_CACHE -ErrorAction SilentlyContinue } else { $env:NPM_CONFIG_CACHE = $oldCache }
    if ($null -eq $oldAudit) { Remove-Item Env:\NPM_CONFIG_AUDIT -ErrorAction SilentlyContinue } else { $env:NPM_CONFIG_AUDIT = $oldAudit }
    if ($null -eq $oldFund) { Remove-Item Env:\NPM_CONFIG_FUND -ErrorAction SilentlyContinue } else { $env:NPM_CONFIG_FUND = $oldFund }
    if ($null -eq $oldOffline) { Remove-Item Env:\NPM_CONFIG_OFFLINE -ErrorAction SilentlyContinue } else { $env:NPM_CONFIG_OFFLINE = $oldOffline }
    if ($null -eq $oldPreferOffline) { Remove-Item Env:\NPM_CONFIG_PREFER_OFFLINE -ErrorAction SilentlyContinue } else { $env:NPM_CONFIG_PREFER_OFFLINE = $oldPreferOffline }
}

$camoPackageJson = Join-Path $nodeRoot 'node_modules\@askjo\camofox-browser\package.json'
if (-not (Test-Path -LiteralPath $camoPackageJson -PathType Leaf)) {
    throw "Build-time Camofox install succeeded but package.json is missing: $camoPackageJson"
}
$camoPackage = Get-Content -LiteralPath $camoPackageJson -Raw | ConvertFrom-Json
if ($camoPackage.name -ne '@askjo/camofox-browser' -or [string]::IsNullOrWhiteSpace([string]$camoPackage.version)) {
    throw 'Build-time Camofox package identity/version is invalid.'
}
$camofoxVersion = [string]$camoPackage.version
Write-Host "Bundled Camofox materialized: $camofoxVersion"

# prepare-offline-payload.ps1 has already created the six archives. Rebuild
# only managed-runtime.tar.gz after adding Camofox, then refresh manifest hashes
# so the normal hash-validation gate checks the final bytes that will ship.
$tarExe = Join-Path $env:SystemRoot 'System32\tar.exe'
if (-not (Test-Path -LiteralPath $tarExe -PathType Leaf)) {
    $tarCmd = Get-Command tar.exe -ErrorAction Stop
    $tarExe = $tarCmd.Source
}
if (Test-Path -LiteralPath $managedArchive -PathType Leaf) {
    Remove-Item -LiteralPath $managedArchive -Force
}
Write-Host 'Rebuilding managed-runtime.tar.gz with bundled Camofox...'
& $tarExe -czf $managedArchive -C $managedRoot .
if ($LASTEXITCODE -ne 0) { throw "tar failed while rebuilding managed-runtime.tar.gz (exit $LASTEXITCODE)" }

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$manifest.camofox_browser = $camofoxVersion
foreach ($entry in @($manifest.archives)) {
    $archivePath = Join-Path $PayloadRoot $entry.name
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        throw "Manifest archive disappeared during Camofox finalization: $($entry.name)"
    }
    $entry.bytes = (Get-Item -LiteralPath $archivePath).Length
    $entry.sha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding utf8

# ---------------------------------------------------------------------------
# Patch the target-side installer: verify, do not npm-install, Camofox; and
# normalize the managed Git worktree so the official online updater can take
# over cleanly on Windows.
# ---------------------------------------------------------------------------
$text = [System.IO.File]::ReadAllText($InstallScript)
$marker = '# Stage definitions -- the single source of truth.'
$index = $text.IndexOf($marker, [System.StringComparison]::Ordinal)
if ($index -lt 0) {
    throw 'Upstream stage-definition marker moved; refusing to patch an unknown installer layout.'
}

$block = @'
# ============================================================================
# Full-offline Camofox + official-updater handoff hardening
# ============================================================================
# Camofox is materialized into the bundled Node prefix at build time. Target
# machines never invoke npm for it; strict offline mode verifies the exact tree
# extracted from managed-runtime.tar.gz.

$script:HermesOfflinePreHandoffInstallRepository = (Get-Item Function:\Install-Repository).ScriptBlock

function Install-Repository {
    & $script:HermesOfflinePreHandoffInstallRepository
    if (-not $script:HermesOfflineMode) { return }

    # Upstream release history contains contributor-email metadata paths that
    # differ only by letter case. NTFS' normal case-insensitive worktree cannot
    # materialize both names, so an otherwise pristine release checkout appears
    # permanently dirty. The official updater then stashes that synthetic dirt
    # and can fail while switching detached HEAD back to main. contributors/ is
    # metadata only, not Hermes runtime code, so exclude that one tree using
    # Git's native sparse-worktree mechanism while keeping the exact HEAD and
    # official origin unchanged.
    $gitDir = Join-Path $InstallDir '.git'
    $gitInfo = Join-Path $gitDir 'info'
    if (-not (Test-Path -LiteralPath $gitInfo -PathType Container)) {
        throw 'Offline checkout is missing .git/info; cannot prepare official updater handoff.'
    }

    Push-Location $InstallDir
    try {
        git -c windows.appendAtomically=false config core.autocrlf false
        if ($LASTEXITCODE -ne 0) { throw 'Could not configure core.autocrlf for the offline checkout.' }
        git -c windows.appendAtomically=false config core.sparseCheckout true
        if ($LASTEXITCODE -ne 0) { throw 'Could not enable sparse checkout for Windows collision avoidance.' }
        git -c windows.appendAtomically=false config core.sparseCheckoutCone false
        if ($LASTEXITCODE -ne 0) { throw 'Could not select non-cone sparse checkout mode.' }

        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        $sparsePath = Join-Path $gitInfo 'sparse-checkout'
        [System.IO.File]::WriteAllText($sparsePath, "/*`r`n!/contributors/`r`n", $utf8NoBom)
        git -c windows.appendAtomically=false read-tree -mu HEAD
        if ($LASTEXITCODE -ne 0) { throw 'Could not apply sparse checkout for Windows case-collision metadata.' }

        # These are generated/managed install artifacts, not source edits. Keep
        # them out of the official updater's autostash while still letting real
        # user modifications remain visible to normal Git status/stash logic.
        $excludePath = Join-Path $gitInfo 'exclude'
        $excludeText = if (Test-Path -LiteralPath $excludePath) { [System.IO.File]::ReadAllText($excludePath) } else { '' }
        foreach ($pattern in @('/.hermes-offline-source.json', '/bin/')) {
            if ($excludeText -notmatch ('(?m)^' + [regex]::Escape($pattern) + '$')) {
                if ($excludeText -and -not $excludeText.EndsWith("`n")) { $excludeText += "`r`n" }
                $excludeText += "$pattern`r`n"
            }
        }
        [System.IO.File]::WriteAllText($excludePath, $excludeText, $utf8NoBom)

        $dirtyTracked = @(git -c windows.appendAtomically=false status --porcelain --untracked-files=no 2>$null | Where-Object { $_ -and $_.ToString().Trim() })
        if ($dirtyTracked.Count -gt 0) {
            throw "Offline managed checkout remains tracked-dirty after Windows collision hardening: $($dirtyTracked -join '; ')"
        }
    } finally {
        Pop-Location
    }
    Write-Success 'Managed Git checkout prepared for official online updater handoff'
}

function Install-AgentBrowser {
    if (-not $script:HermesOfflineMode) {
        & $script:HermesPreHardenInstallAgentBrowser
        return
    }

    $packageJson = Join-Path $HermesHome 'node\node_modules\@askjo\camofox-browser\package.json'
    if (-not (Test-Path -LiteralPath $packageJson -PathType Leaf)) {
        throw "Bundled Camofox package is missing: $packageJson"
    }

    try {
        $package = Get-Content -LiteralPath $packageJson -Raw | ConvertFrom-Json
    } catch {
        throw "Bundled Camofox package.json could not be parsed: $($_.Exception.Message)"
    }
    if ($package.name -ne '@askjo/camofox-browser' -or [string]::IsNullOrWhiteSpace([string]$package.version)) {
        throw 'Bundled Camofox package identity/version is invalid.'
    }

    $manifest = Get-Content -LiteralPath (Join-Path $script:HermesOfflinePayload 'manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.camofox_browser -and ([string]$package.version -ne [string]$manifest.camofox_browser)) {
        throw "Bundled Camofox version mismatch: package $($package.version), manifest $($manifest.camofox_browser)"
    }

    $sysBrowser = Find-SystemBrowser
    if ($sysBrowser) {
        Write-BrowserEnv -BrowserPath $sysBrowser
        Write-Info 'Explicit browser override set -- Chromium download will be skipped when agent-browser installs on demand'
    }
    Write-Success "Bundled Camofox browser server verified ($($package.version))"
    Write-Success 'Agent-browser ready'
}

function Install-NodeDeps {
    if (-not $script:HermesOfflineMode) {
        & $script:HermesPreHardenInstallNodeDeps
        return
    }

    Test-Node | Out-Null
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) { throw 'Offline Node dependency stage cannot find node.exe.' }

    Invoke-HermesOfflineNpmInstall -Label 'Browser/root' -Directory $InstallDir
    $tuiDir = Join-Path $InstallDir 'ui-tui'
    if (Test-Path -LiteralPath (Join-Path $tuiDir 'package.json') -PathType Leaf) {
        Invoke-HermesOfflineNpmInstall -Label 'TUI' -Directory $tuiDir
    }

    $browserRoot = $env:PLAYWRIGHT_BROWSERS_PATH
    if (-not $browserRoot -or -not (Test-Path -LiteralPath $browserRoot -PathType Container)) {
        throw 'PLAYWRIGHT_BROWSERS_PATH does not point at the bundled browser payload.'
    }
    $chromiumExe = Get-ChildItem -LiteralPath $browserRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @('chrome.exe', 'headless_shell.exe') } |
        Select-Object -First 1
    if (-not $chromiumExe) {
        throw 'Bundled Playwright payload does not contain a Chromium executable.'
    }
    Write-Success "Bundled Playwright Chromium verified ($($chromiumExe.FullName))"

    Install-AgentBrowser
    Install-BrowserUseCli
    Install-CuaDriver
}

# End Full-offline Camofox + updater handoff hardening

'@

# harden-offline-runtime.ps1 must have run first; preserve the real upstream
# browser function so non-offline invocations remain unchanged.
if ($text -notmatch 'HermesPreHardenInstallAgentBrowser') {
    $anchor = '$script:HermesPreHardenInstallCuaDriver = (Get-Item Function:\Install-CuaDriver).ScriptBlock'
    $anchorIndex = $text.IndexOf($anchor, [System.StringComparison]::Ordinal)
    if ($anchorIndex -lt 0) {
        throw 'Base offline hardening layout changed; cannot safely preserve upstream Install-AgentBrowser.'
    }
    $insertAt = $anchorIndex + $anchor.Length
    $text = $text.Insert($insertAt, "`r`n`$script:HermesPreHardenInstallAgentBrowser = (Get-Item Function:\Install-AgentBrowser).ScriptBlock")
    $index = $text.IndexOf($marker, [System.StringComparison]::Ordinal)
}

$patched = $text.Insert($index, $block)
$utf8Bom = New-Object System.Text.UTF8Encoding $true
[System.IO.File]::WriteAllText($InstallScript, $patched, $utf8Bom)
Write-Host "Applied build-materialized offline Camofox + official-updater handoff override: $InstallScript"
