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
# Hermes Desktop Offline Builder strict runtime overrides (v2)
# ============================================================================
# These definitions are intentionally placed immediately before the upstream
# stage table, so they are the implementations invoked by the official stage
# protocol while leaving the protocol/UI itself untouched.

$script:HermesPreHardenInstallNodeDeps = (Get-Item Function:\Install-NodeDeps).ScriptBlock
$script:HermesPreHardenInstallCuaDriver = (Get-Item Function:\Install-CuaDriver).ScriptBlock

function Invoke-HermesOfflineNpmInstall {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Directory
    )

    if (-not (Test-Path -LiteralPath (Join-Path $Directory 'package.json') -PathType Leaf)) {
        Write-Info "Skipping $Label (package.json not present)"
        return
    }

    $npmExe = Join-Path $HermesHome 'node\npm.cmd'
    if (-not (Test-Path -LiteralPath $npmExe -PathType Leaf)) {
        $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
        if (-not $npm) { $npm = Get-Command npm -ErrorAction SilentlyContinue }
        if (-not $npm) { throw "$Label requires npm, but npm was not found." }
        $npmExe = $npm.Source
        if ($npmExe -like '*.ps1') {
            $cmdSibling = Join-Path (Split-Path $npmExe -Parent) 'npm.cmd'
            if (Test-Path -LiteralPath $cmdSibling -PathType Leaf) { $npmExe = $cmdSibling }
        }
    }

    Write-Info "Installing $Label from bundled npm cache (offline)..."
    Push-Location $Directory
    $previousEap = $ErrorActionPreference
    try {
        # Do not use upstream _Invoke-NativeWithTimeout here. On GitHub's
        # Windows Server 2025 runner Start-Process has been observed to return a
        # completed Process whose ExitCode property is blank, causing a real
        # npm exit 0 to be reported as failure. A direct invocation gives us
        # PowerShell's reliable $LASTEXITCODE and streams output naturally.
        $ErrorActionPreference = 'Continue'
        & $npmExe install --offline --prefer-offline --no-audit --no-fund 2>&1 | ForEach-Object { "$_" | Write-Host }
        $npmExit = $LASTEXITCODE
        $ErrorActionPreference = $previousEap
        if ($npmExit -ne 0) {
            throw "$Label npm install failed in strict offline mode (exit $npmExit). The payload npm cache is incomplete."
        }
    } finally {
        $ErrorActionPreference = $previousEap
        Pop-Location
    }
    Write-Success "$Label dependencies installed from bundled cache"
}

function Get-HermesOfflineCuaContractStatus {
    param([Parameter(Mandatory = $true)][string]$DriverPath)

    $issues = New-Object System.Collections.Generic.List[string]
    $version = $null
    $manifest = $null

    try {
        $versionOutput = (& $DriverPath --version 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            $issues.Add("--version exited $LASTEXITCODE")
        } else {
            $versionMatch = [regex]::Match($versionOutput, '(\d+\.\d+\.\d+)')
            if (-not $versionMatch.Success) {
                $issues.Add("--version did not contain semver: $versionOutput")
            } else {
                $version = $versionMatch.Groups[1].Value
                if ([version]$version -lt [version]'0.20.0') {
                    $issues.Add("version $version is below Hermes minimum 0.20.0")
                }
            }
        }
    } catch {
        $issues.Add("--version could not run: $($_.Exception.Message)")
    }

    try {
        $manifestText = (& $DriverPath manifest 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            $issues.Add("manifest exited $LASTEXITCODE")
        } elseif (-not $manifestText) {
            $issues.Add('manifest returned no JSON')
        } else {
            $manifest = $manifestText | ConvertFrom-Json
        }
    } catch {
        $issues.Add("manifest JSON could not be parsed: $($_.Exception.Message)")
    }

    if ($manifest) {
        if (-not $manifest.mcp_invocation -or -not @($manifest.mcp_invocation.args).Count) {
            $issues.Add('manifest is missing mcp_invocation.args')
        }

        $required = [ordered]@{
            mcp = @('--socket', '--grant')
            serve = @('--socket', '--permission-mode', '--capability-manifest', '--approve-capability-manifest', '--embedded')
            stop = @('--socket')
        }
        foreach ($commandName in $required.Keys) {
            $command = @($manifest.subcommands) | Where-Object { $_.name -eq $commandName } | Select-Object -First 1
            if (-not $command) {
                $issues.Add("manifest is missing subcommand '$commandName'")
                continue
            }
            $argNames = @($command.args | ForEach-Object { $_.name })
            foreach ($requiredArg in $required[$commandName]) {
                if ($requiredArg -notin $argNames) {
                    $issues.Add("manifest $commandName is missing $requiredArg")
                }
            }
        }
    }

    return [pscustomobject]@{
        Ready = ($issues.Count -eq 0)
        Version = $version
        Issues = @($issues)
    }
}

function Install-CuaDriver {
    if (-not $script:HermesOfflineMode) {
        & $script:HermesPreHardenInstallCuaDriver
        return
    }

    if ($SkipComputerUse) {
        Write-Info 'Skipping Computer Use (-SkipComputerUse)'
        return
    }

    $driverPath = Join-Path $HermesHome 'tools\bin\cua-driver.exe'
    if (-not (Test-Path -LiteralPath $driverPath -PathType Leaf)) {
        $driver = Get-Command cua-driver -ErrorAction SilentlyContinue
        if ($driver) { $driverPath = $driver.Source }
    }
    if (-not (Test-Path -LiteralPath $driverPath -PathType Leaf)) {
        throw 'Offline payload is missing cua-driver.exe.'
    }

    $status = Get-HermesOfflineCuaContractStatus -DriverPath $driverPath
    if (-not $status.Ready) {
        foreach ($issue in $status.Issues) { Write-Warn "cua-driver contract: $issue" }
        throw "Bundled cua-driver failed the Hermes runtime contract: $($status.Issues -join '; ')"
    }

    # Compare with the upstream PowerShell probe for diagnostics, but use the
    # explicit field-by-field validation above as the authority. This avoids a
    # false negative in the installer helper while still refusing binaries that
    # omit any field Hermes' own tests require.
    $upstreamAccepted = $false
    try { $upstreamAccepted = Test-CuaDriverRuntimeContract -DriverPath $driverPath } catch { }
    if (-not $upstreamAccepted) {
        Write-Warn "Upstream Test-CuaDriverRuntimeContract returned false for cua-driver $($status.Version), but the exact Hermes-required manifest contract passed; continuing with the validated bundled binary."
    }
    Write-Success "Bundled Computer Use driver verified (cua-driver $($status.Version))"
}

function Install-NodeDeps {
    if (-not $script:HermesOfflineMode) {
        & $script:HermesPreHardenInstallNodeDeps
        return
    }

    Test-Node | Out-Null
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) { throw 'Offline Node dependency stage cannot find node.exe.' }

    # Mirror the official Windows stage's two npm install locations, but with
    # npm explicitly locked to its bundled cache and direct exit-code handling.
    Invoke-HermesOfflineNpmInstall -Label 'Browser/root' -Directory $InstallDir
    $tuiDir = Join-Path $InstallDir 'ui-tui'
    if (Test-Path -LiteralPath (Join-Path $tuiDir 'package.json') -PathType Leaf) {
        Invoke-HermesOfflineNpmInstall -Label 'TUI' -Directory $tuiDir
    }

    # Playwright is pre-downloaded during payload construction. Do not run
    # `npx playwright install` on the target; validate the bundled browser tree
    # instead so a missing browser is a build failure, not a first-use download.
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

    # Preserve optional browser environment setup/camofox preparation where the
    # upstream function exists. It is best-effort upstream; Browser Use and CUA
    # below are strict because the Full package promises them ready offline.
    $agentBrowserFn = Get-Command Install-AgentBrowser -CommandType Function -ErrorAction SilentlyContinue
    if ($agentBrowserFn) {
        try { Install-AgentBrowser } catch { Write-Warn "Install-AgentBrowser offline preparation warning: $($_.Exception.Message)" }
    }

    Install-BrowserUseCli
    Install-CuaDriver
}

# End strict runtime overrides

'@

$patched = $text.Insert($index, $block)
$utf8Bom = New-Object System.Text.UTF8Encoding $true
[System.IO.File]::WriteAllText($InstallScript, $patched, $utf8Bom)
Write-Host "Applied strict offline runtime overrides: $InstallScript"
