# Packages the cargo-built soprano.exe as soprano-<version>-windows-x64.zip:
#
#   soprano-<version>-windows-x64\
#     soprano.exe
#     resources\   Soprano_Soprano.bundle\ AgentHooks\ bin\ fonts\ icons\ (from resources\),
#                  bin\soprano.cmd, web\ (the built omp web app), ghostty\shell-integration\,
#                  LICENSE, LICENSE-ghostty
#
# Windows ships no terminfo database. Build first: cargo build -p soprano [--release]
# Usage: scripts\package-windows.ps1 [-Configuration debug|release] [-OutputDir <dir>]
[CmdletBinding()]
param(
    [ValidateSet('debug', 'release')]
    [string]$Configuration = 'release',
    [string]$OutputDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $OutputDir) {
    $OutputDir = Join-Path $repoRoot 'dist'
}
if (-not [System.IO.Path]::IsPathRooted($OutputDir)) {
    throw "The output directory must be an absolute path: $OutputDir"
}

$targetDir = $env:CARGO_TARGET_DIR
if ($targetDir) {
    if (-not [System.IO.Path]::IsPathRooted($targetDir)) {
        throw 'CARGO_TARGET_DIR must be an absolute directory.'
    }
} else {
    $targetDir = Join-Path $repoRoot 'target'
}

function Invoke-Native {
    param([string]$Command, [string[]]$Arguments)
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

# Version: [workspace.package] version in the root Cargo.toml.
$manifest = Get-Content -Raw (Join-Path $repoRoot 'Cargo.toml')
$section = [regex]::Match($manifest, '(?ms)^\[workspace\.package\]\s*$(.*?)(?=^\[|\z)')
$versionMatch = [regex]::Match($section.Groups[1].Value, '(?m)^version\s*=\s*"([^"]+)"')
if (-not $section.Success -or -not $versionMatch.Success) {
    throw 'Could not read [workspace.package] version from Cargo.toml.'
}
$version = $versionMatch.Groups[1].Value

$binary = Join-Path $targetDir "$Configuration\soprano.exe"
$repoResources = Join-Path $repoRoot 'resources'
$shellIntegration = Join-Path $repoRoot 'ghostty\src\shell-integration'
$webSource = Join-Path $repoRoot 'web'
foreach ($required in @(
        $binary,
        (Join-Path $repoResources 'Soprano_Soprano.bundle'),
        (Join-Path $repoResources 'AgentHooks'),
        (Join-Path $repoResources 'bin\omp'),
        (Join-Path $repoResources 'fonts'),
        (Join-Path $repoResources 'icons'),
        (Join-Path $repoRoot 'LICENSE'),
        (Join-Path $repoRoot 'Support\Licenses\LICENSE-ghostty'),
        (Join-Path $webSource 'package-lock.json'))) {
    if (-not (Test-Path $required)) {
        throw "Missing packaging input: $required"
    }
}
if (-not (Test-Path $shellIntegration)) {
    throw 'The ghostty submodule is not checked out. Run: git submodule update --init ghostty'
}

# Build our editable web fork, never download an upstream app at command runtime.
if (-not (Get-Command node -ErrorAction SilentlyContinue) -or -not (Get-Command npm -ErrorAction SilentlyContinue)) {
    throw 'Building omp web requires Node.js >= 22.19.0 and npm.'
}
$nodeCheck = 'const check = require(process.argv[1]); if (!check.isNodeVersionSupported(process.versions.node)) { console.error(check.getUnsupportedNodeVersionMessage(process.versions.node)); process.exit(1); }'
Invoke-Native node @('-e', $nodeCheck, (Join-Path $webSource 'bin\node-version.js'))
Push-Location $webSource
try {
    Invoke-Native npm @('ci', '--no-audit', '--no-fund')
    Invoke-Native npm @('run', 'build')
} finally {
    Pop-Location
}
$webStandalone = Join-Path $webSource '.next\standalone'
if (-not (Test-Path (Join-Path $webStandalone 'server.js'))) {
    throw "Missing standalone omp web server: $webStandalone\server.js"
}

$name = "soprano-$version-windows-x64"
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$stageDir = Join-Path $OutputDir ".soprano-package-$([guid]::NewGuid().ToString('N'))"
try {
    $staged = Join-Path $stageDir $name
    $resources = Join-Path $staged 'resources'
    New-Item -ItemType Directory -Force -Path $resources | Out-Null

    Copy-Item $binary (Join-Path $staged 'soprano.exe')
    foreach ($item in @('Soprano_Soprano.bundle', 'AgentHooks', 'bin', 'fonts', 'icons', 'licenses')) {
        Copy-Item -Recurse (Join-Path $repoResources $item) (Join-Path $resources $item)
    }
    Get-ChildItem -Recurse -Force -Path $resources -Filter '.DS_Store' | Remove-Item -Force
    # bin\soprano.cmd lets panes run the app binary as a CLI, like bin/soprano elsewhere.
    Set-Content -Encoding ascii -Path (Join-Path $resources 'bin\soprano.cmd') -Value @(
        '@echo off',
        '"%~dp0..\..\soprano.exe" %*'
    )

    $webDestination = Join-Path $resources 'web'
    New-Item -ItemType Directory -Force -Path $webDestination | Out-Null
    # Standalone tracing may already include these directories: merge their contents.
    Copy-Item -Recurse -Force (Join-Path $webStandalone '*') $webDestination
    $staticDestination = Join-Path $webDestination '.next\static'
    New-Item -ItemType Directory -Force -Path $staticDestination | Out-Null
    Copy-Item -Recurse -Force (Join-Path $webSource '.next\static\*') $staticDestination
    foreach ($item in @('bin', 'lib', 'public')) {
        $itemDestination = Join-Path $webDestination $item
        New-Item -ItemType Directory -Force -Path $itemDestination | Out-Null
        Copy-Item -Recurse -Force (Join-Path $webSource "$item\*") $itemDestination
    }
    $scriptsDestination = Join-Path $webDestination 'scripts\windows'
    New-Item -ItemType Directory -Force -Path $scriptsDestination | Out-Null
    Copy-Item -Recurse -Force (Join-Path $webSource 'scripts\windows\*') $scriptsDestination
    foreach ($file in @('package.json', 'package-lock.json', 'LICENSE')) {
        Copy-Item (Join-Path $webSource $file) $webDestination
    }
    # Development tests stay out of the package; the tray executable is Windows' own and stays.
    Get-ChildItem -Recurse -Force -Path $webDestination -Filter '*.test.mjs' | Remove-Item -Force

    $ghosttyDestination = Join-Path $resources 'ghostty'
    New-Item -ItemType Directory -Force -Path $ghosttyDestination | Out-Null
    Copy-Item -Recurse $shellIntegration (Join-Path $ghosttyDestination 'shell-integration')
    Get-ChildItem -Recurse -Force -Path $ghosttyDestination -Filter '*.md' | Remove-Item -Force

    Copy-Item (Join-Path $repoRoot 'LICENSE') (Join-Path $resources 'LICENSE')
    Copy-Item (Join-Path $repoRoot 'Support\Licenses\LICENSE-ghostty') (Join-Path $resources 'LICENSE-ghostty')

    $archive = Join-Path $OutputDir "$name.zip"
    $stagedArchive = Join-Path $stageDir "$name.zip"
    # bsdtar (tar.exe, built into Windows 10+) is far faster than Compress-Archive on node_modules.
    if (Get-Command tar.exe -ErrorAction SilentlyContinue) {
        Invoke-Native tar.exe @('-a', '-c', '-f', $stagedArchive, '-C', $stageDir, $name)
    } else {
        Compress-Archive -Path $staged -DestinationPath $stagedArchive
    }
    Move-Item -Force $stagedArchive $archive
    Write-Host "Created $archive"
} finally {
    if (Test-Path $stageDir) {
        Remove-Item -Recurse -Force $stageDir
    }
}
