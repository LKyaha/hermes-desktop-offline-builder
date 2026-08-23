param(
    [Parameter(Mandatory = $true)][string]$InstallScript
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $InstallScript -PathType Leaf)) {
    throw "Generated install script not found: $InstallScript"
}

# ---------------------------------------------------------------------------
# CI clean-room guard
# ---------------------------------------------------------------------------
# GitHub-hosted Windows runners can already contain Electron / browser binary
# caches from the image or earlier build steps. That can make a dead-proxy
# "offline" npm test pass even though a real clean machine would try to fetch a
# binary. Scrub only known user/global binary-cache locations outside the
# workspace before the stage-protocol test runs.
if ($env:GITHUB_ACTIONS -eq 'true') {
    $cacheCandidates = New-Object System.Collections.Generic.List[string]

    if ($env:LOCALAPPDATA) {
        $cacheCandidates.Add((Join-Path $env:LOCALAPPDATA 'electron\Cache'))
        $cacheCandidates.Add((Join-Path $env:LOCALAPPDATA 'electron-builder\Cache'))
        $cacheCandidates.Add((Join-Path $env:LOCALAPPDATA 'ms-playwright'))
    }
    if ($env:USERPROFILE) {
        $cacheCandidates.Add((Join-Path $env:USERPROFILE '.electron'))
        $cacheCandidates.Add((Join-Path $env:USERPROFILE '.cache\electron'))
        $cacheCandidates.Add((Join-Path $env:USERPROFILE '.cache\puppeteer'))
        $cacheCandidates.Add((Join-Path $env:USERPROFILE '.cache\ms-playwright'))
    }

    $workspace = $null
    if ($env:GITHUB_WORKSPACE) {
        try { $workspace = [System.IO.Path]::GetFullPath($env:GITHUB_WORKSPACE).TrimEnd('\') } catch { }
    }

    foreach ($candidate in @($cacheCandidates | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }

        $full = [System.IO.Path]::GetFullPath($candidate).TrimEnd('\')
        if ($workspace -and $full.StartsWith($workspace + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to scrub a binary cache inside GITHUB_WORKSPACE: $full"
        }

        if (Test-Path -LiteralPath $full) {
            Write-Host "Scrubbing hosted-runner binary cache: $full"
            Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
        }
        if (Test-Path -LiteralPath $full) {
            throw "Hosted-runner binary cache survived scrub: $full"
        }
    }

    Write-Host 'Hosted-runner Electron/Puppeteer/Playwright binary caches scrubbed for clean-room offline validation.'
}

$text = [System.IO.File]::ReadAllText($InstallScript)
$marker = '# Stage definitions -- the single source of truth.'
$index = $text.IndexOf($marker, [System.StringComparison]::Ordinal)
if ($index -lt 0) {
    throw 'Upstream stage-definition marker moved; refusing to patch an unknown installer layout.'
}

$block = @'
# ============================================================================
# Full-offline binary-download hardening
# ============================================================================
# The Desktop executable and Playwright Chromium are already bundled. During a
# clean-machine npm ci, Electron's package postinstall otherwise tries to fetch
# its own runtime from the network. Hosted CI can accidentally hide this defect
# when the runner has a warm Electron cache. Explicitly suppress all browser /
# Electron binary download hooks in strict offline mode while keeping npm
# lifecycle scripts enabled for packages that legitimately need them.
if ($script:HermesOfflineMode) {
    $env:ELECTRON_SKIP_BINARY_DOWNLOAD = '1'
    $env:PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = '1'
    $env:PUPPETEER_SKIP_DOWNLOAD = 'true'
    $env:PUPPETEER_SKIP_CHROMIUM_DOWNLOAD = 'true'
}

# End Full-offline binary-download hardening

'@

$patched = $text.Insert($index, $block)
$utf8Bom = New-Object System.Text.UTF8Encoding $true
[System.IO.File]::WriteAllText($InstallScript, $patched, $utf8Bom)
Write-Host "Applied strict offline binary-download suppression: $InstallScript"
