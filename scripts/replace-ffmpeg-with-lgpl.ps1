param(
    [Parameter(Mandatory = $true)][string]$PayloadRoot,
    [Parameter(Mandatory = $true)][string]$WorkRoot
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$PayloadRoot = (Resolve-Path $PayloadRoot).Path
New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
$WorkRoot = (Resolve-Path $WorkRoot).Path

$archive = Join-Path $PayloadRoot 'managed-runtime.tar.gz'
$manifestPath = Join-Path $PayloadRoot 'manifest.json'
if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) { throw "Missing managed runtime archive: $archive" }
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Missing payload manifest: $manifestPath" }

$tar = (Get-Command tar.exe -ErrorAction SilentlyContinue).Source
if (-not $tar) { $tar = (Get-Command tar -ErrorAction Stop).Source }

$stage = Join-Path $WorkRoot 'ffmpeg-lgpl-runtime'
$download = Join-Path $WorkRoot 'ffmpeg-lgpl-shared.zip'
$extract = Join-Path $WorkRoot 'ffmpeg-lgpl-extract'
foreach ($path in @($stage, $extract)) {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $path | Out-Null
}
if (Test-Path -LiteralPath $download) { Remove-Item -LiteralPath $download -Force }

Write-Host 'Extracting managed runtime for FFmpeg redistribution hardening...'
& $tar -xzf $archive -C $stage
if ($LASTEXITCODE -ne 0) { throw 'Could not extract managed-runtime.tar.gz.' }

$headers = @{
    'User-Agent' = 'hermes-desktop-offline-builder'
    'Accept' = 'application/vnd.github+json'
}
$release = Invoke-RestMethod -Headers $headers -Uri 'https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/latest'
$asset = @($release.assets) | Where-Object { $_.name -match '^ffmpeg-.*-win64-lgpl-shared\.zip$' } | Select-Object -First 1
if (-not $asset) { throw 'Latest BtbN/FFmpeg-Builds release has no Windows x64 LGPL shared ZIP asset.' }

Write-Host "Downloading LGPL shared FFmpeg: $($asset.name)"
Invoke-WebRequest -Headers $headers -Uri $asset.browser_download_url -OutFile $download -UseBasicParsing
Expand-Archive -Path $download -DestinationPath $extract -Force

$binDir = Get-ChildItem -LiteralPath $extract -Recurse -Directory | Where-Object { $_.Name -eq 'bin' } | Select-Object -First 1
if (-not $binDir) { throw 'BtbN FFmpeg archive did not contain a bin directory.' }
foreach ($required in @('ffmpeg.exe', 'ffprobe.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $binDir.FullName $required) -PathType Leaf)) {
        throw "BtbN FFmpeg archive is missing $required"
    }
}

$managedBin = Join-Path $stage 'tools\bin'
$licenseDir = Join-Path $stage 'tools\licenses'
New-Item -ItemType Directory -Force -Path $managedBin, $licenseDir | Out-Null

# The previous Gyan build is static. Remove its executables and old FFmpeg
# notices, then install the complete BtbN shared bin directory so the DLLs
# required by ffmpeg.exe/ffprobe.exe travel with the executables.
Remove-Item -LiteralPath (Join-Path $managedBin 'ffmpeg.exe') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $managedBin 'ffprobe.exe') -Force -ErrorAction SilentlyContinue
Get-ChildItem -LiteralPath $licenseDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'ffmpeg-*' -or $_.Name -like 'btbn-ffmpeg-*' } |
    Remove-Item -Force
Copy-Item -Path (Join-Path $binDir.FullName '*') -Destination $managedBin -Recurse -Force

$licenseFiles = Get-ChildItem -LiteralPath $extract -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^(LICENSE|COPYING|COPYRIGHT|NOTICE)(\..*)?$' } |
    Select-Object -First 50
$index = 0
foreach ($file in $licenseFiles) {
    $index++
    $safeName = ($file.Name -replace '[^A-Za-z0-9._-]', '_')
    Copy-Item $file.FullName (Join-Path $licenseDir ("btbn-ffmpeg-{0:D2}-{1}" -f $index, $safeName)) -Force
}

$notice = @"
FFmpeg distribution used by Hermes Desktop Offline Builder
==========================================================
Binary provider: BtbN/FFmpeg-Builds
Release tag: $($release.tag_name)
Binary asset: $($asset.name)
Binary source page: https://github.com/BtbN/FFmpeg-Builds/releases/tag/$($release.tag_name)
Build scripts/source repository: https://github.com/BtbN/FFmpeg-Builds
FFmpeg upstream source: https://ffmpeg.org/download.html
Selected variant: Windows x64, LGPL, shared libraries

This builder intentionally selects the LGPL shared variant instead of a GPL
static build. License/copyright files found in the binary archive are retained
under tools/licenses in the offline payload. This notice is informational and
is not legal advice; downstream redistributors remain responsible for their
own license compliance.
"@
Set-Content -LiteralPath (Join-Path $licenseDir 'FFMPEG_DISTRIBUTION.txt') -Value $notice -Encoding utf8
Set-Content -LiteralPath (Join-Path $PayloadRoot 'THIRD_PARTY_NOTICES.txt') -Value $notice -Encoding utf8

$ffmpeg = Join-Path $managedBin 'ffmpeg.exe'
$ffprobe = Join-Path $managedBin 'ffprobe.exe'
$ffmpegVersion = (& $ffmpeg -version 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0) { throw 'Bundled LGPL shared ffmpeg.exe failed to execute.' }
& $ffprobe -version *> $null
if ($LASTEXITCODE -ne 0) { throw 'Bundled LGPL shared ffprobe.exe failed to execute.' }
if ($ffmpegVersion -match '--enable-gpl(?:\s|$)') { throw 'Refusing to bundle an FFmpeg build configured with --enable-gpl.' }
if ($ffmpegVersion -notmatch '--enable-shared(?:\s|$)') { throw 'Expected a shared FFmpeg build, but --enable-shared was not reported.' }
Write-Host 'Verified FFmpeg is a runnable LGPL shared build.'

Remove-Item -LiteralPath $archive -Force
& $tar -czf $archive -C $stage .
if ($LASTEXITCODE -ne 0) { throw 'Could not rebuild managed-runtime.tar.gz after FFmpeg replacement.' }

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$entry = @($manifest.archives) | Where-Object { $_.name -eq 'managed-runtime.tar.gz' } | Select-Object -First 1
if (-not $entry) { throw 'Payload manifest has no managed-runtime.tar.gz entry.' }
$item = Get-Item -LiteralPath $archive
$entry.bytes = $item.Length
$entry.sha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
$ffmpegMeta = [ordered]@{
    provider = 'BtbN/FFmpeg-Builds'
    release_tag = $release.tag_name
    asset = $asset.name
    license_variant = 'LGPL shared'
    binary_sha256 = (Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash.ToLowerInvariant()
}
$manifest | Add-Member -NotePropertyName ffmpeg_distribution -NotePropertyValue $ffmpegMeta -Force
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding utf8

Remove-Item -LiteralPath $stage -Recurse -Force
Remove-Item -LiteralPath $extract -Recurse -Force
Remove-Item -LiteralPath $download -Force
Write-Host "Replaced FFmpeg with BtbN LGPL shared asset: $($asset.name)"
