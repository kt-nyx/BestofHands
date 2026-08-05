# SPDX-License-Identifier: Unlicense

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$version = '1.7.12'
$archiveName = "actionlint_${version}_windows_amd64.zip"
$expected = '6E7241B51E6817EA6A047693D8E6FED13B31819C9A0DD6C5A726E1592D22F6E9'
$toolRoot = Join-Path $env:LOCALAPPDATA "BestOfHands\actionlint\$version"
$archive = Join-Path $toolRoot $archiveName
$executable = Join-Path $toolRoot 'actionlint.exe'

New-Item -ItemType Directory -Path $toolRoot -Force | Out-Null
if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
    $url = "https://github.com/rhysd/actionlint/releases/download/v$version/$archiveName"
    Invoke-WebRequest -Uri $url -OutFile $archive
}
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -cne $expected) {
    throw 'Pinned actionlint archive hash mismatch.'
}
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
    Expand-Archive -LiteralPath $archive -DestinationPath $toolRoot -Force
}
$workflows = @(
    Get-ChildItem -Path (Join-Path $root '.github\workflows\*.yml'),
        (Join-Path $root '.github\workflows\*.yaml') -File -ErrorAction SilentlyContinue |
        ForEach-Object FullName
)
if ($workflows.Count -eq 0) {
    throw 'No GitHub Actions workflows were found.'
}
& $executable @workflows
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
Write-Host "actionlint passed: $($workflows.Count) workflows"
