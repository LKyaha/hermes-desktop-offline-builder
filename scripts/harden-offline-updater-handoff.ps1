param(
    [Parameter(Mandatory = $true)][string]$InstallScript
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $InstallScript -PathType Leaf)) {
    throw "Generated install script not found: $InstallScript"
}

$text = [System.IO.File]::ReadAllText($InstallScript)
$startMarker = '$script:HermesOfflinePreHandoffInstallRepository = (Get-Item Function:\Install-Repository).ScriptBlock'
$endMarker = 'function Install-AgentBrowser {'
$start = $text.IndexOf($startMarker, [System.StringComparison]::Ordinal)
if ($start -lt 0) {
    throw 'Camofox updater-handoff repository wrapper was not found in generated install.ps1.'
}
$end = $text.IndexOf($endMarker, $start, [System.StringComparison]::Ordinal)
if ($end -lt 0) {
    throw 'Could not find Install-AgentBrowser after updater-handoff repository wrapper.'
}

$replacement = @'
$script:HermesOfflinePreHandoffInstallRepository = (Get-Item Function:\Install-Repository).ScriptBlock

function Install-Repository {
    & $script:HermesOfflinePreHandoffInstallRepository
    if (-not $script:HermesOfflineMode) { return }

    # hermes-source.tar.gz is prepared at build time as a Windows-safe sparse
    # checkout BEFORE its first worktree materialization. Do not run read-tree,
    # reset, or change autocrlf here: mutating an already-extracted checkout can
    # manufacture hundreds of false modifications from CRLF normalization and
    # cannot repair a case collision that already happened on NTFS. Target-side
    # responsibility is validation only.
    $gitExe = Join-Path $HermesHome 'git\cmd\git.exe'
    if (-not (Test-Path -LiteralPath $gitExe -PathType Leaf)) {
        throw "Managed Git is missing during official-updater handoff validation: $gitExe"
    }
    $gitDir = Join-Path $InstallDir '.git'
    $gitInfo = Join-Path $gitDir 'info'
    if (-not (Test-Path -LiteralPath $gitInfo -PathType Container)) {
        throw 'Offline checkout is missing .git/info; cannot validate official updater handoff.'
    }

    Push-Location $InstallDir
    try {
        $autocrlf = (& $gitExe config --get core.autocrlf 2>$null | Out-String).Trim().ToLowerInvariant()
        if ($LASTEXITCODE -ne 0 -or $autocrlf -ne 'false') {
            throw "Bundled checkout was not prepared with core.autocrlf=false (got '$autocrlf')."
        }

        $sparseEnabled = (& $gitExe config --get core.sparseCheckout 2>$null | Out-String).Trim().ToLowerInvariant()
        if ($LASTEXITCODE -ne 0 -or $sparseEnabled -notin @('true', 'yes', 'on', '1')) {
            throw "Bundled checkout does not have sparse checkout enabled (got '$sparseEnabled')."
        }

        $sparsePath = Join-Path $gitInfo 'sparse-checkout'
        if (-not (Test-Path -LiteralPath $sparsePath -PathType Leaf)) {
            throw 'Bundled checkout is missing .git/info/sparse-checkout.'
        }
        $sparseText = [System.IO.File]::ReadAllText($sparsePath)
        if ($sparseText -notmatch '(?m)^!/contributors/$') {
            throw 'Bundled sparse-checkout rules do not exclude contributors/.'
        }
        if (Test-Path -LiteralPath (Join-Path $InstallDir 'contributors')) {
            throw 'contributors/ was materialized even though the bundled checkout should exclude it.'
        }

        # Installer-managed untracked artifacts should never make the official
        # updater autostash. The build-time source payload already carries these
        # rules; keep this idempotent repair limited to .git metadata only.
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        $excludePath = Join-Path $gitInfo 'exclude'
        $excludeText = if (Test-Path -LiteralPath $excludePath -PathType Leaf) {
            [System.IO.File]::ReadAllText($excludePath)
        } else { '' }
        foreach ($pattern in @('/.hermes-offline-source.json', '/bin/')) {
            if ($excludeText -notmatch ('(?m)^' + [regex]::Escape($pattern) + '$')) {
                if ($excludeText -and -not $excludeText.EndsWith("`n")) { $excludeText += "`r`n" }
                $excludeText += "$pattern`r`n"
            }
        }
        [System.IO.File]::WriteAllText($excludePath, $excludeText, $utf8NoBom)

        $head = (& $gitExe rev-parse HEAD 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $head) { throw 'Bundled checkout has no resolvable HEAD.' }
        $origin = (& $gitExe remote get-url origin 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $origin -ne 'https://github.com/NousResearch/hermes-agent.git') {
            throw "Bundled checkout origin is not the official Hermes repository: $origin"
        }

        $dirtyTracked = @(& $gitExe status --porcelain --untracked-files=no 2>$null | Where-Object { $_ -and $_.ToString().Trim() })
        if ($LASTEXITCODE -ne 0) { throw 'Could not inspect bundled checkout Git status.' }
        if ($dirtyTracked.Count -gt 0) {
            throw "Offline managed checkout is tracked-dirty before official updater handoff: $($dirtyTracked -join '; ')"
        }
    } finally {
        Pop-Location
    }
    Write-Success 'Windows-safe managed Git checkout verified for official online updater handoff'
}

'@

$patched = $text.Substring(0, $start) + $replacement + $text.Substring($end)
if ($patched -match 'read-tree -mu HEAD') {
    throw 'Generated offline installer still mutates the extracted checkout with read-tree.'
}

$utf8Bom = New-Object System.Text.UTF8Encoding $true
[System.IO.File]::WriteAllText($InstallScript, $patched, $utf8Bom)
Write-Host "Replaced target-side updater mutation with validation-only handoff gate: $InstallScript"
