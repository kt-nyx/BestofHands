# SPDX-License-Identifier: Unlicense

[CmdletBinding()]
param(
    [string]$GameBinPath = $(if ($env:BG3_BIN) { $env:BG3_BIN } else { 'Z:\Games\SteamLibrary\steamapps\common\Baldurs Gate 3\bin' }),
    [ValidateSet('bg3_dx11.exe', 'bg3.exe')]
    [string]$Executable = 'bg3_dx11.exe',
    [string]$SteamBuildId,
    [string]$OutputPath = '.\artifacts\compatibility-evidence.json'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$target = Join-Path ([IO.Path]::GetFullPath($GameBinPath)) $Executable
if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
    throw "BG3 executable was not found: $target"
}
$output = [IO.Path]::GetFullPath((Join-Path $root $OutputPath))
$arguments = @(
    'run', '--python', '3.13',
    '--with', 'pefile==2024.8.26',
    '--with', 'capstone==5.0.6',
    'python', (Join-Path $PSScriptRoot 'collect_compatibility_evidence.py'),
    $target, $output
)
if (-not [string]::IsNullOrWhiteSpace($SteamBuildId)) {
    $arguments += @('--steam-build-id', $SteamBuildId)
}
& uv @arguments
if ($LASTEXITCODE -ne 0) {
    throw 'Compatibility evidence collection failed.'
}
