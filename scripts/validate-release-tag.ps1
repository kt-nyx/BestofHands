# SPDX-License-Identifier: Unlicense

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Tag
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$versionPath = Join-Path $root 'VERSION'

if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) {
    throw "Version file not found: $versionPath"
}

$version = (Get-Content -LiteralPath $versionPath -Raw).Trim()
if ($version -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
    throw "VERSION must contain a stable MAJOR.MINOR.PATCH value: '$version'"
}

$expectedTag = "v$version"
if ($Tag -cne $expectedTag) {
    throw "Release tag '$Tag' does not match VERSION '$version'. Expected '$expectedTag'."
}

Write-Host "Release tag $Tag matches VERSION $version." -ForegroundColor Green
