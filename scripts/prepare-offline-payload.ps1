param(
    [Parameter(Mandatory = $true)][string]$UpstreamRoot,
    [Parameter(Mandatory = $true)][string]$WorkRoot,
    [Parameter(Mandatory = $true)][string]$PayloadRoot,
    [Parameter(Mandatory = $true)][string]$HermesRef,
    [Parameter(Mandatory = $true)][string]$HermesCommit
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$UpstreamRoot = (Resolve-Path $UpstreamRoot).Path
New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
New-Item -ItemType Directory -Force -Path $PayloadRoot | Out-Null
$WorkRoot = (Resolve-Path $WorkRoot).Path
$PayloadRoot = (Resolve-Path $PayloadRoot).Path

$installScript = Join-Path $UpstreamRoot 'scripts\install.ps1'
if (-not (Test-Path $installScript)) { throw "Missing upstream install.ps1: $installScript" }
$text = [System.IO.File]::ReadAllText($installScript)

function Read-QuotedSetting([string]$name) {
    $m = [regex]::Match($text, ('\$' + [regex]::Escape($name) + '\s*=\s*"([^"]+)"'))
    if (-not $m.Success) { throw "Could not parse `$${name} from upstream install.ps1" }
    return $m.Groups[1].Value
}

$pythonVersion = Read-QuotedSetting 'PythonVersion'
$nodeMajor = Read-QuotedSetting 'NodeVersion'
$gitTag = Read-QuotedSetting 'gitTag'
$gitVer = Read-QuotedSetting 'gitVer'

Write-Host "Upstream runtime policy: Python $pythonVersion, Node $nodeMajor, Git $gitTag"

$managed = Join-Path $WorkRoot 'managed-runtime'
$uvCache = Join-Path $WorkRoot 'uv-cache'
$npmCache = Join-Path $WorkRoot 'npm-cache'
$playwrightRoot = Join-Path $WorkRoot 'ms-playwright'
$venvProbe = Join-Path $WorkRoot 'venv-probe'
$sourceStage = Join-Path $WorkRoot 'source-stage'
$toolProbe = Join-Path $WorkRoot 'uv-tool-probe'

foreach ($p in @($managed, $uvCache, $npmCache, $playwrightRoot, $venvProbe, $sourceStage, $toolProbe)) {
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
}
New-Item -ItemType Directory -Force -Path (Join-Path $managed 'bin') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $managed 'tools\bin') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $managed 'tools\licenses') | Out-Null

$publicHeaders = @{ 'User-Agent' = 'hermes-desktop-offline-builder' }

function Download([string]$Uri, [string]$Destination) {
    Write-Host "Downloading $Uri"
    Invoke-WebRequest -Headers $publicHeaders -Uri $Uri -OutFile $Destination -UseBasicParsing
}

# ---------------------------------------------------------------------------
# uv (same upstream policy as install.ps1: current official uv release)
# ---------------------------------------------------------------------------
$uvRelease = Invoke-RestMethod -Headers $publicHeaders -Uri 'https://api.github.com/repos/astral-sh/uv/releases/latest'
$uvAsset = $uvRelease.assets | Where-Object { $_.name -eq 'uv-x86_64-pc-windows-msvc.zip' } | Select-Object -First 1
if (-not $uvAsset) { throw 'Could not find Windows x64 uv release asset.' }
$uvZip = Join-Path $WorkRoot 'uv.zip'
$uvExtract = Join-Path $WorkRoot 'uv-extract'
Download $uvAsset.browser_download_url $uvZip
Expand-Archive -Path $uvZip -DestinationPath $uvExtract -Force
$uvExe = Get-ChildItem $uvExtract -Recurse -Filter uv.exe | Select-Object -First 1
if (-not $uvExe) { throw 'uv release archive did not contain uv.exe' }
Copy-Item $uvExe.FullName (Join-Path $managed 'bin\uv.exe') -Force
Remove-Item $uvZip -Force
Remove-Item $uvExtract -Recurse -Force
$uv = Join-Path $managed 'bin\uv.exe'
$uvVersion = (& $uv --version | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Bundled uv.exe failed to execute.' }

# ---------------------------------------------------------------------------
# uv-managed Python. UV_PYTHON_INSTALL_DIR makes the tree relocatable under
# %LOCALAPPDATA%\hermes\python on the target machine.
# ---------------------------------------------------------------------------
$env:UV_PYTHON_INSTALL_DIR = Join-Path $managed 'python'
$env:UV_NO_PROGRESS = '1'
& $uv python install $pythonVersion
if ($LASTEXITCODE -ne 0) { throw "uv python install $pythonVersion failed" }
$pythonProbe = & $uv python find $pythonVersion
if ($LASTEXITCODE -ne 0 -or -not $pythonProbe) { throw 'Managed Python was installed but uv cannot find it.' }
Write-Host "Managed Python: $pythonProbe"

# ---------------------------------------------------------------------------
# Portable Node.js, following upstream's latest-v<major>.x policy.
# ---------------------------------------------------------------------------
$nodeIndexUrl = "https://nodejs.org/dist/latest-v${nodeMajor}.x/"
$nodeIndex = Invoke-WebRequest -Headers $publicHeaders -Uri $nodeIndexUrl -UseBasicParsing
$nodeMatch = [regex]::Matches($nodeIndex.Content, "node-v${nodeMajor}\.\d+\.\d+-win-x64\.zip") | Select-Object -First 1
if (-not $nodeMatch) { throw "Could not resolve latest Node v${nodeMajor}.x Windows x64 archive." }
$nodeZipName = $nodeMatch.Value
$nodeZip = Join-Path $WorkRoot $nodeZipName
$nodeExtract = Join-Path $WorkRoot 'node-extract'
Download ($nodeIndexUrl + $nodeZipName) $nodeZip
Expand-Archive -Path $nodeZip -DestinationPath $nodeExtract -Force
$nodeDir = Get-ChildItem $nodeExtract -Directory | Select-Object -First 1
if (-not $nodeDir -or -not (Test-Path (Join-Path $nodeDir.FullName 'node.exe'))) { throw 'Node archive layout was unexpected.' }
Copy-Item $nodeDir.FullName (Join-Path $managed 'node') -Recurse -Force
Remove-Item $nodeZip -Force
Remove-Item $nodeExtract -Recurse -Force
$nodeVersion = (& (Join-Path $managed 'node\node.exe') --version | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Bundled Node.js failed to execute.' }

# ---------------------------------------------------------------------------
# PortableGit, using the exact version pinned by upstream install.ps1.
# ---------------------------------------------------------------------------
$gitAssetName = "PortableGit-$gitVer-64-bit.7z.exe"
$gitUrl = "https://github.com/git-for-windows/git/releases/download/$gitTag/$gitAssetName"
$gitSfx = Join-Path $WorkRoot $gitAssetName
$gitDir = Join-Path $managed 'git'
Download $gitUrl $gitSfx
New-Item -ItemType Directory -Force -Path $gitDir | Out-Null
$gitExtract = Start-Process -FilePath $gitSfx -ArgumentList "-o`"$gitDir`"", '-y' -NoNewWindow -Wait -PassThru
if ($gitExtract.ExitCode -ne 0) { throw "PortableGit extraction failed: $($gitExtract.ExitCode)" }
Remove-Item $gitSfx -Force
$gitExe = Join-Path $gitDir 'cmd\git.exe'
$bashExe = Join-Path $gitDir 'bin\bash.exe'
if (-not (Test-Path $gitExe) -or -not (Test-Path $bashExe)) { throw 'PortableGit payload is incomplete.' }
& $gitExe --version
if ($LASTEXITCODE -ne 0) { throw 'Bundled PortableGit failed to execute.' }

# ---------------------------------------------------------------------------
# ripgrep + FFmpeg. These are placed on Hermes' managed tools PATH.
# ---------------------------------------------------------------------------
$rgRelease = Invoke-RestMethod -Headers $publicHeaders -Uri 'https://api.github.com/repos/BurntSushi/ripgrep/releases/latest'
$rgAsset = $rgRelease.assets | Where-Object { $_.name -match 'x86_64-pc-windows-msvc\.zip$' } | Select-Object -First 1
if (-not $rgAsset) { throw 'Could not find ripgrep Windows x64 release asset.' }
$rgZip = Join-Path $WorkRoot 'ripgrep.zip'
$rgExtract = Join-Path $WorkRoot 'ripgrep-extract'
Download $rgAsset.browser_download_url $rgZip
Expand-Archive $rgZip $rgExtract -Force
$rgExe = Get-ChildItem $rgExtract -Recurse -Filter rg.exe | Select-Object -First 1
if (-not $rgExe) { throw 'ripgrep archive did not contain rg.exe' }
Copy-Item $rgExe.FullName (Join-Path $managed 'tools\bin\rg.exe') -Force
Get-ChildItem $rgExtract -Recurse -File | Where-Object { $_.Name -match '^(LICENSE|COPYING|UNLICENSE)' } | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $managed ('tools\licenses\ripgrep-' + $_.Name)) -Force
}
Remove-Item $rgZip -Force
Remove-Item $rgExtract -Recurse -Force

$ffmpegZip = Join-Path $WorkRoot 'ffmpeg.zip'
$ffmpegExtract = Join-Path $WorkRoot 'ffmpeg-extract'
Download 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip' $ffmpegZip
Expand-Archive $ffmpegZip $ffmpegExtract -Force
foreach ($name in @('ffmpeg.exe', 'ffprobe.exe')) {
    $exe = Get-ChildItem $ffmpegExtract -Recurse -Filter $name | Select-Object -First 1
    if (-not $exe) { throw "FFmpeg archive did not contain $name" }
    Copy-Item $exe.FullName (Join-Path $managed "tools\bin\$name") -Force
}
Get-ChildItem $ffmpegExtract -Recurse -File | Where-Object { $_.Name -match '^(LICENSE|COPYING)' } | Select-Object -First 5 | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $managed ('tools\licenses\ffmpeg-' + $_.Name)) -Force
}
Remove-Item $ffmpegZip -Force
Remove-Item $ffmpegExtract -Recurse -Force

# ---------------------------------------------------------------------------
# cua-driver. Hermes' upstream installer currently fetches trycua's installer
# at runtime. For a true offline install, parse that installer's baked stable
# version during the build and ship its Windows x64 binaries directly on the
# managed PATH. Upstream Install-CuaDriver then sees a compatible existing
# driver and skips its network installer.
# ---------------------------------------------------------------------------
$cuaInstallerUrl = 'https://raw.githubusercontent.com/trycua/cua/main/libs/cua-driver/scripts/install.ps1'
$cuaInstallerText = (Invoke-WebRequest -Headers $publicHeaders -Uri $cuaInstallerUrl -UseBasicParsing).Content
$cuaVersionMatch = [regex]::Match($cuaInstallerText, '\$Script:CuaDriverRsBakedVersion\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"')
if (-not $cuaVersionMatch.Success) { throw 'Could not parse cua-driver baked stable version.' }
$cuaVersion = $cuaVersionMatch.Groups[1].Value
$cuaTag = "cua-driver-rs-v$cuaVersion"
$cuaZipName = "cua-driver-rs-$cuaVersion-windows-x86_64.zip"
$cuaZip = Join-Path $WorkRoot $cuaZipName
$cuaExtract = Join-Path $WorkRoot 'cua-driver-extract'
Download "https://github.com/trycua/cua/releases/download/$cuaTag/$cuaZipName" $cuaZip
Expand-Archive $cuaZip $cuaExtract -Force
$cuaExe = Get-ChildItem $cuaExtract -Recurse -Filter cua-driver.exe | Select-Object -First 1
if (-not $cuaExe) { throw 'cua-driver archive did not contain cua-driver.exe.' }
Copy-Item $cuaExe.FullName (Join-Path $managed 'tools\bin\cua-driver.exe') -Force
$cuaTheme = Get-ChildItem $cuaExtract -Recurse -Filter cua-cursor-theme.exe | Select-Object -First 1
if ($cuaTheme) { Copy-Item $cuaTheme.FullName (Join-Path $managed 'tools\bin\cua-cursor-theme.exe') -Force }
Get-ChildItem $cuaExtract -Recurse -File | Where-Object { $_.Name -match '^(LICENSE|COPYING|NOTICE)' } | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $managed ('tools\licenses\cua-driver-' + $_.Name)) -Force
}
& (Join-Path $managed 'tools\bin\cua-driver.exe') --version
if ($LASTEXITCODE -ne 0) { throw 'Bundled cua-driver failed to execute.' }
Remove-Item $cuaZip -Force
Remove-Item $cuaExtract -Recurse -Force

# ---------------------------------------------------------------------------
# Warm uv's cache by performing the exact Tier-0 install upstream uses, then
# eagerly cache the extra stacks that Desktop itself installs later.
# ---------------------------------------------------------------------------
$env:UV_CACHE_DIR = $uvCache
$env:UV_PYTHON_INSTALL_DIR = Join-Path $managed 'python'
$env:UV_PROJECT_ENVIRONMENT = $venvProbe
$env:UV_NO_PROGRESS = '1'
Push-Location $UpstreamRoot
try {
    & $uv sync --extra all --locked
    if ($LASTEXITCODE -ne 0) { throw 'uv sync --extra all --locked failed while warming offline cache.' }
    $probePython = Join-Path $venvProbe 'Scripts\python.exe'
    if (-not (Test-Path $probePython)) { throw 'uv cache warm-up did not create a probe venv.' }
    & $probePython -c 'import dotenv, openai, rich, prompt_toolkit, fastapi, uvicorn'
    if ($LASTEXITCODE -ne 0) { throw 'Python baseline import probe failed after cache warm-up.' }

    & $uv pip install --python $probePython -e '.[wake,voice]'
    if ($LASTEXITCODE -ne 0) { throw 'Could not cache Desktop wake/voice dependencies.' }
    & $probePython -c 'import onnxruntime, faster_whisper, sounddevice, openwakeword'
    if ($LASTEXITCODE -ne 0) { throw 'Wake/voice import probe failed after cache warm-up.' }

    # Warm the uv tool cache for the exact command upstream runs. The tool
    # environment itself is disposable; on the target, UV_OFFLINE recreates it
    # correctly at the user's paths from this cache.
    Remove-Item Env:\UV_PROJECT_ENVIRONMENT -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path (Join-Path $toolProbe 'bin') | Out-Null
    $env:UV_TOOL_DIR = Join-Path $toolProbe 'tools'
    $env:UV_TOOL_BIN_DIR = Join-Path $toolProbe 'bin'
    $env:UV_PYTHON = $pythonProbe
    & $uv tool install browser-use --force
    if ($LASTEXITCODE -ne 0) { throw 'Could not warm uv cache for browser-use CLI.' }
    $browserUseExe = Join-Path $toolProbe 'bin\browser-use.exe'
    if (-not (Test-Path $browserUseExe -PathType Leaf)) { throw 'browser-use tool install did not create browser-use.exe.' }
    $browserUseVersion = (& $browserUseExe --version 2>&1 | Out-String).Trim()
} finally {
    Pop-Location
    Remove-Item Env:\UV_TOOL_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:\UV_TOOL_BIN_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:\UV_PYTHON -ErrorAction SilentlyContinue
}
Remove-Item $venvProbe -Recurse -Force
Remove-Item $toolProbe -Recurse -Force

# ---------------------------------------------------------------------------
# Warm npm cache for the monorepo, browser helper package, and Playwright.
# ---------------------------------------------------------------------------
$env:NPM_CONFIG_CACHE = $npmCache
$env:NPM_CONFIG_AUDIT = 'false'
$env:NPM_CONFIG_FUND = 'false'
$env:PLAYWRIGHT_BROWSERS_PATH = $playwrightRoot
Push-Location $UpstreamRoot
try {
    npm ci
    if ($LASTEXITCODE -ne 0) { throw 'npm ci failed while warming offline npm cache.' }

    $camoProbe = Join-Path $WorkRoot 'camofox-probe'
    New-Item -ItemType Directory -Force -Path $camoProbe | Out-Null
    npm install --prefix $camoProbe --ignore-scripts --no-save '@askjo/camofox-browser@^1.5.2'
    if ($LASTEXITCODE -ne 0) { throw 'Failed to warm npm cache for @askjo/camofox-browser.' }
    Remove-Item $camoProbe -Recurse -Force

    npx --yes playwright install chromium
    if ($LASTEXITCODE -ne 0) { throw 'Playwright Chromium download failed during payload preparation.' }
} finally {
    Pop-Location
}

if (-not (Get-ChildItem $playwrightRoot -Directory -ErrorAction SilentlyContinue)) {
    throw 'Playwright reported success but no browser payload was created.'
}

$desktopDir = Join-Path $UpstreamRoot 'apps\desktop\release\win-unpacked'
if (-not (Test-Path (Join-Path $desktopDir 'Hermes.exe'))) {
    throw "Prebuilt Desktop is missing: $desktopDir\Hermes.exe"
}

# Create a clean managed source clone containing .git metadata but no build-time
# node_modules. Reset origin so future online `hermes update` does not point at
# the ephemeral GitHub Actions workspace path.
& git clone --no-hardlinks $UpstreamRoot $sourceStage
if ($LASTEXITCODE -ne 0) { throw 'Could not create clean source staging clone.' }
Push-Location $sourceStage
try {
    git remote set-url origin 'https://github.com/NousResearch/hermes-agent.git'
    git checkout --detach $HermesCommit
    if ($LASTEXITCODE -ne 0) { throw "Could not pin staged source clone to $HermesCommit" }
    $head = (git rev-parse HEAD).Trim()
    if ($head -ne $HermesCommit) { throw "Source staging HEAD mismatch: $head" }
} finally {
    Pop-Location
}

# ---------------------------------------------------------------------------
# Collapse cache trees into six payload archives. The target uses Windows'
# built-in bsdtar, so no extra decompressor is required.
# ---------------------------------------------------------------------------
$tar = (Get-Command tar.exe -ErrorAction Stop).Source
function New-TarGz([string]$SourceDir, [string]$Destination) {
    if (Test-Path $Destination) { Remove-Item $Destination -Force }
    Write-Host "Creating $(Split-Path $Destination -Leaf) from $SourceDir"
    & $tar -czf $Destination -C $SourceDir .
    if ($LASTEXITCODE -ne 0) { throw "tar failed for $SourceDir" }
}

New-TarGz $managed (Join-Path $PayloadRoot 'managed-runtime.tar.gz')
New-TarGz $uvCache (Join-Path $PayloadRoot 'uv-cache.tar.gz')
New-TarGz $npmCache (Join-Path $PayloadRoot 'npm-cache.tar.gz')
New-TarGz $playwrightRoot (Join-Path $PayloadRoot 'ms-playwright.tar.gz')
New-TarGz $sourceStage (Join-Path $PayloadRoot 'hermes-source.tar.gz')
New-TarGz (Split-Path $desktopDir -Parent) (Join-Path $PayloadRoot 'desktop-win-x64.tar.gz')

$desktopListing = & $tar -tzf (Join-Path $PayloadRoot 'desktop-win-x64.tar.gz')
if (-not ($desktopListing -match 'win-unpacked[/\\]Hermes\.exe')) {
    throw 'Desktop archive does not contain win-unpacked/Hermes.exe.'
}

$archives = Get-ChildItem $PayloadRoot -Filter '*.tar.gz' | Sort-Object Name
$archiveInfo = @()
foreach ($a in $archives) {
    $archiveInfo += [ordered]@{
        name = $a.Name
        bytes = $a.Length
        sha256 = (Get-FileHash $a.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

$manifest = [ordered]@{
    schema = 1
    upstream = 'NousResearch/hermes-agent'
    hermes_ref = $HermesRef
    hermes_commit = $HermesCommit
    platform = 'windows'
    arch = 'x64'
    python = $pythonVersion
    node_major = $nodeMajor
    node = $nodeVersion
    git = $gitTag
    uv = $uvVersion
    cua_driver = $cuaVersion
    browser_use = $browserUseVersion
    prepared_at = (Get-Date).ToUniversalTime().ToString('o')
    archives = $archiveInfo
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $PayloadRoot 'manifest.json') -Encoding utf8

Write-Host 'Offline payload prepared:'
Get-ChildItem $PayloadRoot | Select-Object Name, Length | Format-Table -AutoSize
