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
}

# End Full-offline binary-download hardening

'@

$patched = $text.Insert($index, $block)
$utf8Bom = New-Object System.Text.UTF8Encoding $true
[System.IO.File]::WriteAllText($InstallScript, $patched, $utf8Bom)
Write-Host "Applied strict offline binary-download suppression: $InstallScript"
