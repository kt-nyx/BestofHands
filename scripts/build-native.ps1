# SPDX-License-Identifier: Unlicense

[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release', 'RelWithDebInfo')]
    [string]$Configuration = 'Release',
    [switch]$PerformanceDiagnostics,
    [switch]$Install,
    [string]$GameBinPath = $env:BG3_BIN,
    [string]$CMakeGenerator = $env:CMAKE_GENERATOR
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $root 'native'
$build = Join-Path $root 'build\native'

$cmakeCommand = Get-Command cmake -ErrorAction SilentlyContinue
$cmakeCandidates = @(
    if ($null -ne $cmakeCommand) { $cmakeCommand.Source }
    'C:\Program Files\CMake\bin\cmake.exe'
    'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
    'C:\Program Files\Microsoft Visual Studio\18\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
$cmake = $cmakeCandidates |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    Select-Object -First 1
if ($null -eq $cmake) {
    throw 'CMake was not found. Install the C++ CMake tools from Visual Studio.'
}
$ctest = Join-Path (Split-Path -Parent $cmake) 'ctest.exe'
$performanceDiagnosticsValue = if ($PerformanceDiagnostics) { 'ON' } else { 'OFF' }
if (-not [string]::IsNullOrWhiteSpace($CMakeGenerator) -and
    $CMakeGenerator -cne 'Visual Studio 18 2026' -and
    $CMakeGenerator -cne 'Visual Studio 17 2022') {
    throw "Unsupported CMake generator '$CMakeGenerator'. Use Visual Studio 2026 or 2022."
}

$configureArguments = @('-S', $source, '-B', $build)
if (-not [string]::IsNullOrWhiteSpace($CMakeGenerator)) {
    $configureArguments += @('-G', $CMakeGenerator)
}
$configureArguments += @(
    '-A', 'x64',
    "-DBEST_OF_HANDS_PERF_DIAGNOSTICS=$performanceDiagnosticsValue"
)
& $cmake @configureArguments
if ($LASTEXITCODE -ne 0) {
    throw 'Native CMake configuration failed.'
}
$cachePath = Join-Path $build 'CMakeCache.txt'
$generatorMatch = [regex]::Match(
    (Get-Content -LiteralPath $cachePath -Raw),
    '(?m)^CMAKE_GENERATOR:INTERNAL=(Visual Studio (?:18 2026|17 2022))\r?$'
)
if (-not $generatorMatch.Success) {
    throw 'Native CMake configuration did not select Visual Studio 2026 or 2022.'
}
Write-Host "Using CMake generator: $($generatorMatch.Groups[1].Value)"

& $cmake --build $build --config $Configuration --parallel
if ($LASTEXITCODE -ne 0) {
    throw 'Native DLL compilation failed.'
}
& $ctest --test-dir $build -C $Configuration --output-on-failure
if ($LASTEXITCODE -ne 0) {
    throw 'Native unit tests failed.'
}

$dll = Join-Path $build 'bin\NativeMods\BestofHands.dll'
if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) {
    throw "Native build did not produce the expected DLL: $dll"
}

$bytes = [IO.File]::ReadAllBytes($dll)
if ($bytes.Length -lt 0x100 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) {
    throw "Native output is not a PE DLL: $dll"
}
$peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
$machine = [BitConverter]::ToUInt16($bytes, $peOffset + 4)
if ($machine -ne 0x8664) {
    throw ('Native output is not AMD64 (machine 0x{0:x4}): {1}' -f $machine, $dll)
}

if ($Configuration -eq 'Release') {
    $ascii = [Text.Encoding]::ASCII.GetString($bytes)
    $forbiddenTraceMarkers = @(
        'native_profile_source_selected'
        'native_client_'
        'native_quick_lockpick_started'
    )
    foreach ($marker in $forbiddenTraceMarkers) {
        if ($ascii.Contains($marker)) {
            throw "Release DLL retained disabled trace payload '$marker': $dll"
        }
    }
    Write-Host 'Verified release DLL contains no disabled native trace payloads.'
    if (-not $PerformanceDiagnostics) {
        foreach ($marker in @('perf_diagnostics_enabled', 'roll_profile')) {
            if ($ascii.Contains($marker)) {
                throw "Release DLL retained disabled performance payload '$marker': $dll"
            }
        }
        Write-Host 'Verified release DLL contains no disabled performance payloads.'
    }
    else {
        foreach ($marker in @('perf_diagnostics_enabled', 'roll_profile')) {
            if (-not $ascii.Contains($marker)) {
                throw "Diagnostic DLL is missing performance payload '$marker': $dll"
            }
        }
        Write-Host 'Verified diagnostic DLL contains the requested performance payloads.'
    }
}

Write-Host "Created $dll" -ForegroundColor Green
Write-Host "SHA-256: $((Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash)"

if ($Install) {
    if ([string]::IsNullOrWhiteSpace($GameBinPath)) {
        $GameBinPath = 'Z:\Games\SteamLibrary\steamapps\common\Baldurs Gate 3\bin'
    }
    $resolvedGameBin = [IO.Path]::GetFullPath($GameBinPath)
    if (-not (Test-Path -LiteralPath (Join-Path $resolvedGameBin 'bg3_dx11.exe') -PathType Leaf) -and
        -not (Test-Path -LiteralPath (Join-Path $resolvedGameBin 'bg3.exe') -PathType Leaf)) {
        throw "BG3 executable was not found under: $resolvedGameBin"
    }
    $nativeMods = Join-Path $resolvedGameBin 'NativeMods'
    New-Item -ItemType Directory -Path $nativeMods -Force | Out-Null
    $legacyDll = Join-Path $nativeMods 'BestOfHandsNative.dll'
    if (Test-Path -LiteralPath $legacyDll -PathType Leaf) {
        Remove-Item -LiteralPath $legacyDll -Force
        Write-Host "Removed obsolete $legacyDll" -ForegroundColor Yellow
    }
    Copy-Item -LiteralPath $dll -Destination (Join-Path $nativeMods 'BestofHands.dll') -Force
    Write-Host "Installed BestofHands.dll to $nativeMods" -ForegroundColor Green
}
