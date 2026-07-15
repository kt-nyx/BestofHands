# SPDX-License-Identifier: Unlicense

[CmdletBinding()]
param(
    [string]$DivinePath = $env:DIVINE_PATH,
    [switch]$Install
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $root 'src\BestOfHands'
$dist = Join-Path $root 'dist'
$pakName = 'BestofHands.pak'
$destination = Join-Path $dist $pakName

& (Join-Path $PSScriptRoot 'validate.ps1')

$candidates = @(
    $DivinePath,
    (Join-Path $root 'tools\ExportTool\Packed\Tools\Divine.exe'),
    (Join-Path $root 'tools\ExportTool\Tools\Divine.exe'),
    (Join-Path $root 'tools\Divine.exe'),
    (Join-Path $env:LOCALAPPDATA 'BG3ModManager\Tools\Divine.exe')
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

$resolvedDivine = $candidates |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    Select-Object -First 1

if ($null -eq $resolvedDivine) {
    throw @"
Divine.exe was not found. Install the current LSLib ExportTool and either:
  - pass -DivinePath 'C:\path\to\Divine.exe'
  - set the DIVINE_PATH environment variable
  - extract it under tools\ExportTool
"@
}

New-Item -ItemType Directory -Path $dist -Force | Out-Null
if (Test-Path -LiteralPath $destination) {
    Remove-Item -LiteralPath $destination -Force
}

& $resolvedDivine -g bg3 -a create-package -s $source -d $destination -c lz4hc
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $destination -PathType Leaf)) {
    throw "Divine failed to create $destination"
}

Write-Host "Created $destination" -ForegroundColor Green

$manifestOutput = & $resolvedDivine -g bg3 -a list-package -s $destination
if ($LASTEXITCODE -ne 0) {
    throw "Divine created the package but could not read its manifest: $destination"
}
$manifestOutput | ForEach-Object { Write-Host $_ }

$expectedPackageFiles = @(
    'Mods/BestOfHands/meta.lsx',
    'Mods/BestOfHands/ScriptExtender/Config.json',
    'Mods/BestOfHands/ScriptExtender/Lua/BootstrapServer.lua',
    'Mods/BestOfHands/ScriptExtender/Lua/Server/LegacyAssistanceCleanup.lua',
    'Mods/BestOfHands/ScriptExtender/Lua/Server/Diagnostics.lua',
    'Mods/BestOfHands/ScriptExtender/Lua/Server/Init.lua',
    'Mods/BestOfHands/ScriptExtender/Lua/Server/InteractionCoordinator.lua',
    'Mods/BestOfHands/ScriptExtender/Lua/Server/PartySkillResolver.lua',
    'Mods/BestOfHands/ScriptExtender/Lua/Server/RuntimeApi.lua',
    'Mods/BestOfHands/ScriptExtender/Lua/Server/Settings.lua'
) | Sort-Object
$actualPackageFiles = $manifestOutput |
    Where-Object { $_ -match "`t" } |
    ForEach-Object { ($_ -split "`t")[0].Replace('\', '/') } |
    Sort-Object
$manifestDifference = Compare-Object -ReferenceObject $expectedPackageFiles -DifferenceObject $actualPackageFiles
if ($manifestDifference) {
    $details = $manifestDifference | Out-String
    Remove-Item -LiteralPath $destination -Force
    throw "Built package content does not match the release allowlist; the package was removed:`n$details"
}

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$verificationDirectory = [IO.Path]::GetFullPath(
    (Join-Path $tempRoot "best-of-hands-package-verify-$([Guid]::NewGuid())")
)
if (-not $verificationDirectory.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing unsafe package verification path: $verificationDirectory"
}

try {
    New-Item -ItemType Directory -Path $verificationDirectory -Force | Out-Null
    & $resolvedDivine -g bg3 -a extract-package -s $destination -d $verificationDirectory
    if ($LASTEXITCODE -ne 0) {
        throw "Divine could not extract the package for content verification: $destination"
    }

    foreach ($relativePath in $expectedPackageFiles) {
        $sourceFile = Join-Path $source ($relativePath.Replace('/', '\'))
        $extractedFile = Join-Path $verificationDirectory ($relativePath.Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $extractedFile -PathType Leaf)) {
            throw "Extracted package is missing expected file: $relativePath"
        }
        $sourceHash = (Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash
        $extractedHash = (Get-FileHash -LiteralPath $extractedFile -Algorithm SHA256).Hash
        if ($sourceHash -ne $extractedHash) {
            throw "Extracted package content differs from source: $relativePath"
        }
    }
}
finally {
    if (Test-Path -LiteralPath $verificationDirectory -PathType Container) {
        $resolvedVerificationDirectory = [IO.Path]::GetFullPath(
            (Resolve-Path -LiteralPath $verificationDirectory).Path
        )
        if (-not $resolvedVerificationDirectory.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing unsafe verification cleanup path: $resolvedVerificationDirectory"
        }
        Remove-Item -LiteralPath $resolvedVerificationDirectory -Recurse -Force
    }
}

$hash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
Write-Host "Verified package allowlist ($($actualPackageFiles.Count) files)." -ForegroundColor Green
Write-Host 'Verified extracted package content byte-for-byte against source.' -ForegroundColor Green
Write-Host "SHA-256: $hash"

if ($Install) {
    $modsDirectory = Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3\Mods"
    if (-not (Test-Path -LiteralPath $modsDirectory -PathType Container)) {
        throw "BG3 Mods directory was not found: $modsDirectory"
    }

    Copy-Item -LiteralPath $destination -Destination (Join-Path $modsDirectory $pakName) -Force
    Write-Host "Installed $pakName to $modsDirectory" -ForegroundColor Green
}
