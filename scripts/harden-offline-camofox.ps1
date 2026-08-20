param(
    [Parameter(Mandatory = $true)][string]$InstallScript
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $InstallScript -PathType Leaf)) {
    throw "Generated install script not found: $InstallScript"
}

$text = [System.IO.File]::ReadAllText($InstallScript)
$marker = '# Stage definitions -- the single source of truth.'
$index = $text.IndexOf($marker, [System.StringComparison]::Ordinal)
if ($index -lt 0) {
    throw 'Upstream stage-definition marker moved; refusing to patch an unknown installer layout.'
}

$block = @'
# ============================================================================
# Full-offline Camofox hardening
# ============================================================================
# Upstream v2026.8.18 installs @askjo/camofox-browser globally under the
# Hermes-managed Node prefix. Its generic npm timeout helper can misread a
# successful Windows npm process, so strict offline mode performs the same
# install directly and verifies the resulting package before node-deps passes.

function Resolve-HermesOfflineCamofoxNpm {
    $npmExe = Join-Path $HermesHome 'node\npm.cmd'
    if (Test-Path -LiteralPath $npmExe -PathType Leaf) { return $npmExe }
    $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if (-not $npm) { $npm = Get-Command npm -ErrorAction SilentlyContinue }
    if (-not $npm) { throw 'Strict offline Camofox install requires npm, but npm was not found.' }
    $npmExe = $npm.Source
    if ($npmExe -like '*.ps1') {
        $cmdSibling = Join-Path (Split-Path $npmExe -Parent) 'npm.cmd'
        if (Test-Path -LiteralPath $cmdSibling -PathType Leaf) { $npmExe = $cmdSibling }
    }
    return $npmExe
}

function Install-AgentBrowser {
    if (-not $script:HermesOfflineMode) {
        & $script:HermesPreHardenInstallAgentBrowser
        return
    }

    $npmExe = Resolve-HermesOfflineCamofoxNpm
    $prefixDir = Join-Path $HermesHome 'node'
    if (-not (Test-Path -LiteralPath $prefixDir -PathType Container)) {
        New-Item -ItemType Directory -Path $prefixDir -Force | Out-Null
    }

    Write-Info 'Installing camofox browser server from bundled npm cache (offline)...'
    $previousEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $npmExe install -g --prefix $prefixDir --silent --ignore-scripts --offline --prefer-offline --no-audit --no-fund '@askjo/camofox-browser@^1.5.2' 2>&1 |
            ForEach-Object { "$_" | Write-Host }
        $npmExit = $LASTEXITCODE
        $ErrorActionPreference = $previousEap
        if ($npmExit -ne 0) {
            throw "Camofox npm install failed in strict offline mode (exit $npmExit). The bundled npm cache is incomplete."
        }
    } finally {
        $ErrorActionPreference = $previousEap
    }

    $packageJson = Join-Path $prefixDir 'node_modules\@askjo\camofox-browser\package.json'
    if (-not (Test-Path -LiteralPath $packageJson -PathType Leaf)) {
        throw "Camofox npm install returned success but package.json is missing: $packageJson"
    }
    try {
        $package = Get-Content -LiteralPath $packageJson -Raw | ConvertFrom-Json
    } catch {
        throw "Installed Camofox package.json could not be parsed: $($_.Exception.Message)"
    }
    if ($package.name -ne '@askjo/camofox-browser' -or [string]::IsNullOrWhiteSpace([string]$package.version)) {
        throw 'Installed Camofox package identity/version is invalid.'
    }

    $sysBrowser = Find-SystemBrowser
    if ($sysBrowser) {
        Write-BrowserEnv -BrowserPath $sysBrowser
        Write-Info 'Explicit browser override set -- Chromium download will be skipped when agent-browser installs on demand'
    }
    Write-Success "Camofox browser server verified ($($package.version))"
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

    # Unlike upstream's best-effort browser preparation path, Full Offline must
    # fail here if Camofox cannot be reconstructed entirely from bundled data.
    Install-AgentBrowser
    Install-BrowserUseCli
    Install-CuaDriver
}

# End Full-offline Camofox hardening

'@

# harden-offline-runtime.ps1 must have run first; its saved original browser
# function is what keeps non-offline behavior unchanged.
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
Write-Host "Applied strict offline Camofox override: $InstallScript"
