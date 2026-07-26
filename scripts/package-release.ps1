# SPDX-License-Identifier: Unlicense

[CmdletBinding()]
param(
    [string]$PakPath,
    [string]$NativeDllPath,
    [string]$ReleaseTag
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root 'dist'
$pakName = 'BestofHands.pak'
$versionPath = Join-Path $root 'VERSION'
$metadataPath = Join-Path $root 'src\BestOfHands\Mods\BestOfHands\meta.lsx'
$noticesPath = Join-Path $root 'THIRD_PARTY_NOTICES.txt'
$infoGroup = '8aff5b5f-603d-4e22-8ae2-8510b2164a9b'
$created = '2026-07-15T01:30:22.2092206-04:00'

if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) {
    throw "Version file not found: $versionPath"
}
$version = (Get-Content -LiteralPath $versionPath -Raw).Trim()
if ($version -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
    throw "VERSION must contain a stable MAJOR.MINOR.PATCH value: '$version'"
}
$expectedTag = "v$version"
if ([string]::IsNullOrWhiteSpace($ReleaseTag)) {
    $ReleaseTag = $expectedTag
}
if ($ReleaseTag -cne $expectedTag) {
    throw "Release tag '$ReleaseTag' does not match VERSION '$version'. Expected '$expectedTag'."
}
$zipName = "BestofHands-$ReleaseTag.zip"
$checksumName = "$zipName.sha256"
$legacyDestination = [IO.Path]::GetFullPath((Join-Path $dist 'BestofHands.zip'))

if ([string]::IsNullOrWhiteSpace($PakPath)) {
    $PakPath = Join-Path $dist $pakName
}
if ([string]::IsNullOrWhiteSpace($NativeDllPath)) {
    $NativeDllPath = Join-Path $root 'build\native\bin\NativeMods\BestofHands.dll'
}
$PakPath = [IO.Path]::GetFullPath($PakPath)
$NativeDllPath = [IO.Path]::GetFullPath($NativeDllPath)
$destination = [IO.Path]::GetFullPath((Join-Path $dist $zipName))
$checksumDestination = [IO.Path]::GetFullPath((Join-Path $dist $checksumName))

if (-not (Test-Path -LiteralPath $PakPath -PathType Leaf)) {
    throw "Verified package not found: $PakPath. Run scripts\build.ps1 first."
}
if ([IO.Path]::GetFileName($PakPath) -cne $pakName) {
    throw "Release input must be named exactly ${pakName}: $PakPath"
}
if (-not (Test-Path -LiteralPath $NativeDllPath -PathType Leaf)) {
    throw "Verified native DLL not found: $NativeDllPath. Run scripts\build.ps1 first."
}
if ([IO.Path]::GetFileName($NativeDllPath) -cne 'BestofHands.dll') {
    throw "Native input must be named exactly BestofHands.dll: $NativeDllPath"
}
if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
    throw "Module metadata not found: $metadataPath"
}
if (-not (Test-Path -LiteralPath $noticesPath -PathType Leaf)) {
    throw "Third-party notices not found: $noticesPath"
}

if ($null -eq ('BestOfHands.ReleaseResourceReader' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace BestOfHands
{
    public static class ReleaseResourceReader
    {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern IntPtr LoadLibraryEx(
            string fileName,
            IntPtr file,
            uint flags);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr FindResource(
            IntPtr module,
            IntPtr name,
            IntPtr type);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern uint SizeofResource(
            IntPtr module,
            IntPtr resource);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr LoadResource(
            IntPtr module,
            IntPtr resource);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr LockResource(IntPtr resourceData);

        [DllImport("kernel32.dll")]
        public static extern bool FreeLibrary(IntPtr module);
    }
}
'@
}

function Get-NativeResourceBytes {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$ResourceId
    )

    $loadLibraryAsDataFile = 0x00000002
    $rtRcData = 10
    $module = [BestOfHands.ReleaseResourceReader]::LoadLibraryEx(
        $Path,
        [IntPtr]::Zero,
        $loadLibraryAsDataFile
    )
    if ($module -eq [IntPtr]::Zero) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "Could not open native DLL resources (Win32 $errorCode): $Path"
    }

    try {
        $resource = [BestOfHands.ReleaseResourceReader]::FindResource(
            $module,
            [IntPtr]$ResourceId,
            [IntPtr]$rtRcData
        )
        if ($resource -eq [IntPtr]::Zero) {
            $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "Native DLL resource $ResourceId was not found (Win32 $errorCode): $Path"
        }

        $resourceSize = [BestOfHands.ReleaseResourceReader]::SizeofResource(
            $module,
            $resource
        )
        $loadedResource = [BestOfHands.ReleaseResourceReader]::LoadResource(
            $module,
            $resource
        )
        $resourcePointer = [BestOfHands.ReleaseResourceReader]::LockResource(
            $loadedResource
        )
        if ($resourceSize -eq 0 -or $resourcePointer -eq [IntPtr]::Zero) {
            throw "Native DLL resource $ResourceId is empty or unreadable: $Path"
        }

        $bytes = [byte[]]::new([int]$resourceSize)
        [Runtime.InteropServices.Marshal]::Copy(
            $resourcePointer,
            $bytes,
            0,
            [int]$resourceSize
        )
        return $bytes
    }
    finally {
        [BestOfHands.ReleaseResourceReader]::FreeLibrary($module) | Out-Null
    }
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
    $nativeStage = Join-Path $staging 'bin\NativeMods'
    New-Item -ItemType Directory -Path $nativeStage -Force | Out-Null
    Copy-Item -LiteralPath $NativeDllPath -Destination (Join-Path $nativeStage 'BestofHands.dll')

    $infoPath = Join-Path $staging 'info.json'
    $infoJson = $info | ConvertTo-Json -Depth 8 -Compress
    [IO.File]::WriteAllText(
        $infoPath,
        $infoJson + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
    $releaseTimestamp = [DateTimeOffset]::Parse($created).UtcDateTime
    (Get-Item -LiteralPath (Join-Path $staging $pakName)).LastWriteTimeUtc = $releaseTimestamp
    (Get-Item -LiteralPath (Join-Path $nativeStage 'BestofHands.dll')).LastWriteTimeUtc = $releaseTimestamp
    (Get-Item -LiteralPath $infoPath).LastWriteTimeUtc = $releaseTimestamp

    New-Item -ItemType Directory -Path $dist -Force | Out-Null
    foreach ($outputPath in @($destination, $checksumDestination, $legacyDestination)) {
        if (Test-Path -LiteralPath $outputPath) {
            Remove-Item -LiteralPath $outputPath -Force
        }
    }
    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $destination -CompressionLevel Optimal

    New-Item -ItemType Directory -Path $verification -Force | Out-Null
    Expand-Archive -LiteralPath $destination -DestinationPath $verification
    $actualFiles = Get-ChildItem -LiteralPath $verification -File -Recurse |
        ForEach-Object { $_.FullName.Substring($verification.Length + 1).Replace('\', '/') } |
        Sort-Object
    $expectedFiles = @(
        'BestofHands.pak',
        'bin/NativeMods/BestofHands.dll',
        'info.json'
    ) | Sort-Object
    $difference = Compare-Object -ReferenceObject $expectedFiles -DifferenceObject $actualFiles
    if ($difference) {
        throw "Release archive content differs from the release allowlist:`n$($difference | Out-String)"
    }

    $extractedPak = Join-Path $verification $pakName
    $sourcePakHash = (Get-FileHash -LiteralPath $PakPath -Algorithm SHA256).Hash
    $extractedPakHash = (Get-FileHash -LiteralPath $extractedPak -Algorithm SHA256).Hash
    if ($sourcePakHash -ne $extractedPakHash) {
        throw 'The PAK in the release archive differs from the verified build.'
    }
    $extractedDll = Join-Path $verification 'bin\NativeMods\BestofHands.dll'
    $sourceDllHash = (Get-FileHash -LiteralPath $NativeDllPath -Algorithm SHA256).Hash
    $extractedDllHash = (Get-FileHash -LiteralPath $extractedDll -Algorithm SHA256).Hash
    if ($sourceDllHash -ne $extractedDllHash) {
        throw 'The native DLL in the release archive differs from the verified build.'
    }

    $sourceNotices = [IO.File]::ReadAllBytes($noticesPath)
    $embeddedNotices = Get-NativeResourceBytes -Path $extractedDll -ResourceId 101
    if ($sourceNotices.Length -ne $embeddedNotices.Length -or
        [Convert]::ToBase64String($sourceNotices) -cne
            [Convert]::ToBase64String($embeddedNotices)) {
        throw 'The third-party notices embedded in the native DLL differ from source.'
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

    $zipHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
    $checksumLine = "$zipHash *$zipName"
    [IO.File]::WriteAllText(
        $checksumDestination,
        $checksumLine + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
    $recordedChecksum = (Get-Content -LiteralPath $checksumDestination -Raw).Trim()
    if ($recordedChecksum -cne $checksumLine) {
        throw 'Release archive checksum sidecar could not be verified after writing.'
    }
}
catch {
    foreach ($outputPath in @($destination, $checksumDestination)) {
        if (Test-Path -LiteralPath $outputPath -PathType Leaf) {
            Remove-Item -LiteralPath $outputPath -Force
        }
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

Write-Host "Created $destination" -ForegroundColor Green
Write-Host "Created $checksumDestination" -ForegroundColor Green
Write-Host 'Verified release archive allowlist: PAK, native DLL, and info.json.' -ForegroundColor Green
Write-Host 'Verified archived PAK and native DLL byte-for-byte, embedded notices, and info.json identity/MD5 against source.' -ForegroundColor Green
Write-Host "SHA-256: $zipHash"
