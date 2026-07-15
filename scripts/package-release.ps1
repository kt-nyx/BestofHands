# SPDX-License-Identifier: Unlicense

[CmdletBinding()]
param(
    [string]$PakPath
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root 'dist'
$pakName = 'BestofHands.pak'
$zipName = 'BestofHands.zip'
$metadataPath = Join-Path $root 'src\BestOfHands\Mods\BestOfHands\meta.lsx'
$infoGroup = '8aff5b5f-603d-4e22-8ae2-8510b2164a9b'
$created = '2026-07-15T01:30:22.2092206-04:00'

if ([string]::IsNullOrWhiteSpace($PakPath)) {
    $PakPath = Join-Path $dist $pakName
}
$PakPath = [IO.Path]::GetFullPath($PakPath)
$destination = [IO.Path]::GetFullPath((Join-Path $dist $zipName))

if (-not (Test-Path -LiteralPath $PakPath -PathType Leaf)) {
    throw "Verified package not found: $PakPath. Run scripts\build.ps1 first."
}
if ([IO.Path]::GetFileName($PakPath) -cne $pakName) {
    throw "Release input must be named exactly ${pakName}: $PakPath"
}
if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
    throw "Module metadata not found: $metadataPath"
}

[xml]$metadata = Get-Content -LiteralPath $metadataPath -Raw
$moduleInfo = $metadata.SelectSingleNode("//node[@id='ModuleInfo']")
if ($null -eq $moduleInfo) {
    throw "ModuleInfo was not found in $metadataPath"
}

function Get-ModuleAttribute {
    param([Parameter(Mandatory)][string]$Id)

    $attribute = $moduleInfo.SelectSingleNode("./attribute[@id='$Id']")
    if ($null -eq $attribute) {
        throw "Required metadata attribute '$Id' was not found in $metadataPath"
    }
    return [string]$attribute.value
}

$pakMd5 = (Get-FileHash -LiteralPath $PakPath -Algorithm MD5).Hash.ToLowerInvariant()
$info = [ordered]@{
    Mods = @(
        [ordered]@{
            Author       = Get-ModuleAttribute -Id 'Author'
            Name         = Get-ModuleAttribute -Id 'Name'
            Folder       = Get-ModuleAttribute -Id 'Folder'
            Version      = Get-ModuleAttribute -Id 'Version64'
            Description  = Get-ModuleAttribute -Id 'Description'
            UUID         = Get-ModuleAttribute -Id 'UUID'
            Created      = $created
            Dependencies = @()
            Group        = $infoGroup
        }
    )
    MD5 = $pakMd5
}

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$staging = [IO.Path]::GetFullPath(
    (Join-Path $tempRoot "best-of-hands-release-stage-$([Guid]::NewGuid())")
)
$verification = [IO.Path]::GetFullPath(
    (Join-Path $tempRoot "best-of-hands-release-verify-$([Guid]::NewGuid())")
)
foreach ($path in @($staging, $verification)) {
    if (-not $path.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing unsafe release temporary path: $path"
    }
}

try {
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    Copy-Item -LiteralPath $PakPath -Destination (Join-Path $staging $pakName)

    $infoPath = Join-Path $staging 'info.json'
    $infoJson = $info | ConvertTo-Json -Depth 8 -Compress
    [IO.File]::WriteAllText(
        $infoPath,
        $infoJson + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
    $releaseTimestamp = [DateTimeOffset]::Parse($created).UtcDateTime
    (Get-Item -LiteralPath (Join-Path $staging $pakName)).LastWriteTimeUtc = $releaseTimestamp
    (Get-Item -LiteralPath $infoPath).LastWriteTimeUtc = $releaseTimestamp

    New-Item -ItemType Directory -Path $dist -Force | Out-Null
    if (Test-Path -LiteralPath $destination) {
        Remove-Item -LiteralPath $destination -Force
    }
    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $destination -CompressionLevel Optimal

    New-Item -ItemType Directory -Path $verification -Force | Out-Null
    Expand-Archive -LiteralPath $destination -DestinationPath $verification
    $actualFiles = Get-ChildItem -LiteralPath $verification -File -Recurse |
        ForEach-Object { $_.FullName.Substring($verification.Length + 1).Replace('\', '/') } |
        Sort-Object
    $expectedFiles = @('BestofHands.pak', 'info.json') | Sort-Object
    $difference = Compare-Object -ReferenceObject $expectedFiles -DifferenceObject $actualFiles
    if ($difference) {
        throw "Release archive content differs from the two-file allowlist:`n$($difference | Out-String)"
    }

    $extractedPak = Join-Path $verification $pakName
    $sourcePakHash = (Get-FileHash -LiteralPath $PakPath -Algorithm SHA256).Hash
    $extractedPakHash = (Get-FileHash -LiteralPath $extractedPak -Algorithm SHA256).Hash
    if ($sourcePakHash -ne $extractedPakHash) {
        throw 'The PAK in the release archive differs from the verified build.'
    }

    $extractedInfo = Get-Content -LiteralPath (Join-Path $verification 'info.json') -Raw |
        ConvertFrom-Json
    if ($extractedInfo.MD5 -cne $pakMd5) {
        throw "info.json MD5 mismatch: $($extractedInfo.MD5)"
    }
    if ($extractedInfo.Mods.Count -ne 1 -or
        $extractedInfo.Mods[0].UUID -cne (Get-ModuleAttribute -Id 'UUID') -or
        $extractedInfo.Mods[0].Folder -cne (Get-ModuleAttribute -Id 'Folder')) {
        throw 'info.json identity does not match meta.lsx.'
    }
}
catch {
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        Remove-Item -LiteralPath $destination -Force
    }
    throw
}
finally {
    foreach ($path in @($staging, $verification)) {
        if (Test-Path -LiteralPath $path -PathType Container) {
            $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $path).Path)
            if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing unsafe release temporary cleanup path: $resolved"
            }
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}

$zipHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
Write-Host "Created $destination" -ForegroundColor Green
Write-Host 'Verified release archive allowlist: BestofHands.pak, info.json' -ForegroundColor Green
Write-Host 'Verified archived PAK byte-for-byte and info.json identity/MD5 against source.' -ForegroundColor Green
Write-Host "SHA-256: $zipHash"
