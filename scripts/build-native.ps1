# SPDX-License-Identifier: Unlicense

[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release', 'RelWithDebInfo')]
    [string]$Configuration = 'Release',
    [switch]$Install,
    [string]$GameBinPath = $env:BG3_BIN
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

& $cmake -S $source -B $build -G 'Visual Studio 17 2022' -A x64
if ($LASTEXITCODE -ne 0) {
    throw 'Native CMake configuration failed.'
}
& $cmake --build $build --config $Configuration --parallel
if ($LASTEXITCODE -ne 0) {
    throw 'Native DLL compilation failed.'
}
& $ctest --test-dir $build -C $Configuration --output-on-failure
if ($LASTEXITCODE -ne 0) {
    throw 'Native unit tests failed.'
}

$dll = Join-Path $build 'bin\NativeMods\BestOfHandsNative.dll'
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
    Copy-Item -LiteralPath $dll -Destination (Join-Path $nativeMods 'BestOfHandsNative.dll') -Force
    Write-Host "Installed BestOfHandsNative.dll to $nativeMods" -ForegroundColor Green
}
