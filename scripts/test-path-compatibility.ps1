param(
    [Parameter(Mandatory = $true)][string]$UpstreamInstallScript,
    [Parameter(Mandatory = $true)][string]$OfflineInstallScript
)

$ErrorActionPreference = 'Stop'

$UpstreamInstallScript = (Resolve-Path -LiteralPath $UpstreamInstallScript).Path
$OfflineInstallScript = (Resolve-Path -LiteralPath $OfflineInstallScript).Path

function Invoke-ResolvedPaths {
    param(
        [Parameter(Mandatory = $true)][string]$Script,
        [string]$HermesHomeEnv,
        [string]$ExplicitHermesHome,
        [string]$ExplicitInstallDir
    )

    $savedHermesHome = $env:HERMES_HOME
    $savedOfflinePayload = $env:HERMES_OFFLINE_PAYLOAD
    $savedOfflineStrict = $env:HERMES_OFFLINE_STRICT
    try {
        if ($null -eq $HermesHomeEnv) {
            Remove-Item Env:\HERMES_HOME -ErrorAction SilentlyContinue
        } else {
            $env:HERMES_HOME = $HermesHomeEnv
        }

        # Path compatibility is a comparison of the generated installer's
        # public path contract against the exact upstream installer. Do not
        # activate the offline payload here: -ShowResolvedPaths is explicitly
        # a no-side-effect query and should remain one.
        Remove-Item Env:\HERMES_OFFLINE_PAYLOAD -ErrorAction SilentlyContinue
        Remove-Item Env:\HERMES_OFFLINE_STRICT -ErrorAction SilentlyContinue

        $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script, '-ShowResolvedPaths')
        if ($ExplicitHermesHome) { $args += @('-HermesHome', $ExplicitHermesHome) }
        if ($ExplicitInstallDir) { $args += @('-InstallDir', $ExplicitInstallDir) }

        $raw = & powershell.exe @args
        if ($LASTEXITCODE -ne 0) {
            throw "-ShowResolvedPaths failed for $Script with exit $LASTEXITCODE"
        }
        try {
            return (($raw | Out-String).Trim() | ConvertFrom-Json)
        } catch {
            throw "Could not parse -ShowResolvedPaths JSON from $Script. Output: $($raw | Out-String)"
        }
    } finally {
        if ($null -eq $savedHermesHome) { Remove-Item Env:\HERMES_HOME -ErrorAction SilentlyContinue } else { $env:HERMES_HOME = $savedHermesHome }
        if ($null -eq $savedOfflinePayload) { Remove-Item Env:\HERMES_OFFLINE_PAYLOAD -ErrorAction SilentlyContinue } else { $env:HERMES_OFFLINE_PAYLOAD = $savedOfflinePayload }
        if ($null -eq $savedOfflineStrict) { Remove-Item Env:\HERMES_OFFLINE_STRICT -ErrorAction SilentlyContinue } else { $env:HERMES_OFFLINE_STRICT = $savedOfflineStrict }
    }
}

function Normalize-PathValue([object]$Value) {
    if ($null -eq $Value) { return $null }
    $s = [string]$Value
    if (-not $s) { return $s }
    try { return [System.IO.Path]::GetFullPath($s).TrimEnd('\') } catch { return $s.TrimEnd('\') }
}

function Assert-SameReport {
    param(
        [Parameter(Mandatory = $true)][string]$Scenario,
        [Parameter(Mandatory = $true)]$Official,
        [Parameter(Mandatory = $true)]$Offline
    )

    foreach ($field in @('hermes_home', 'install_dir', 'temp', 'long_profile_root')) {
        $a = Normalize-PathValue $Official.$field
        $b = Normalize-PathValue $Offline.$field
        if (-not [string]::Equals($a, $b, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Path compatibility regression in '$Scenario' for $field: official='$a' offline='$b'"
        }
    }

    # The resolver/normalization diagnostics are part of the upstream
    # -ShowResolvedPaths contract too. Compare their serialized values so a
    # future adapter insertion cannot silently change short-path handling.
    foreach ($field in @('resolver', 'normalized')) {
        $a = $Official.$field | ConvertTo-Json -Compress -Depth 8
        $b = $Offline.$field | ConvertTo-Json -Compress -Depth 8
        if ($a -ne $b) {
            throw "Path compatibility regression in '$Scenario' for $field: official=$a offline=$b"
        }
    }

    Write-Host "Path contract matches upstream [$Scenario]: HermesHome=$($Offline.hermes_home) InstallDir=$($Offline.install_dir)"
}

$scenarios = @(
    [ordered]@{ name = 'default'; envHome = $null; explicitHome = $null; explicitInstall = $null },
    [ordered]@{ name = 'HERMES_HOME override'; envHome = (Join-Path $env:RUNNER_TEMP 'hermes-path-env'); explicitHome = $null; explicitInstall = $null },
    [ordered]@{ name = 'explicit parameters'; envHome = $null; explicitHome = (Join-Path $env:RUNNER_TEMP 'hermes-path-explicit-home'); explicitInstall = (Join-Path $env:RUNNER_TEMP 'hermes-path-explicit-install') }
)

foreach ($scenario in $scenarios) {
    $official = Invoke-ResolvedPaths -Script $UpstreamInstallScript `
        -HermesHomeEnv $scenario.envHome `
        -ExplicitHermesHome $scenario.explicitHome `
        -ExplicitInstallDir $scenario.explicitInstall
    $offline = Invoke-ResolvedPaths -Script $OfflineInstallScript `
        -HermesHomeEnv $scenario.envHome `
        -ExplicitHermesHome $scenario.explicitHome `
        -ExplicitInstallDir $scenario.explicitInstall
    Assert-SameReport -Scenario $scenario.name -Official $official -Offline $offline
}

# Independently assert the canonical default directories on this Windows
# runner. This catches the pathological case where upstream and adapter both
# happen to be invoked under an accidentally contaminated HERMES_HOME.
$defaultOffline = Invoke-ResolvedPaths -Script $OfflineInstallScript
$expectedHome = Join-Path $env:LOCALAPPDATA 'hermes'
$expectedInstall = Join-Path $expectedHome 'hermes-agent'
if (-not [string]::Equals((Normalize-PathValue $defaultOffline.hermes_home), (Normalize-PathValue $expectedHome), [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Canonical HermesHome drifted: expected '$expectedHome', got '$($defaultOffline.hermes_home)'"
}
if (-not [string]::Equals((Normalize-PathValue $defaultOffline.install_dir), (Normalize-PathValue $expectedInstall), [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Canonical InstallDir drifted: expected '$expectedInstall', got '$($defaultOffline.install_dir)'"
}

Write-Host 'Official-vs-offline path compatibility gate passed.'
