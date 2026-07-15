# SPDX-License-Identifier: Unlicense

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$moduleRoot = Join-Path $root 'src\BestOfHands\Mods\BestOfHands'
$metaPath = Join-Path $moduleRoot 'meta.lsx'
$configPath = Join-Path $moduleRoot 'ScriptExtender\Config.json'
$bootstrapPath = Join-Path $moduleRoot 'ScriptExtender\Lua\BootstrapServer.lua'
$initPath = Join-Path $moduleRoot 'ScriptExtender\Lua\Server\Init.lua'
$toolVersionsPath = Join-Path $root 'tools\tool-versions.json'
$versionPath = Join-Path $root 'VERSION'
$licensePath = Join-Path $root 'LICENSE'
$readmePath = Join-Path $root 'README.md'
$developmentPath = Join-Path $root 'DEVELOPMENT.md'

$requiredFiles = @(
    $metaPath,
    $configPath,
    $bootstrapPath,
    $initPath,
    $toolVersionsPath,
    $versionPath,
    $licensePath,
    $readmePath,
    $developmentPath
)
foreach ($path in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required file is missing: $path"
    }
}

[xml]$meta = Get-Content -LiteralPath $metaPath -Raw
$moduleInfo = $meta.SelectSingleNode("//node[@id='ModuleInfo']")
if ($null -eq $moduleInfo) {
    throw 'meta.lsx does not contain ModuleInfo.'
}

function Get-MetaValue {
    param([Parameter(Mandatory)][string]$Id)

    $attribute = $moduleInfo.SelectSingleNode("attribute[@id='$Id']")
    if ($null -eq $attribute) {
        throw "meta.lsx is missing ModuleInfo attribute '$Id'."
    }

    return $attribute.value
}

$folder = Get-MetaValue -Id 'Folder'
$uuid = Get-MetaValue -Id 'UUID'
$version = Get-MetaValue -Id 'Version64'
$name = Get-MetaValue -Id 'Name'

if ($folder -ne 'BestOfHands') {
    throw "Unexpected module folder '$folder'."
}
if ($name -ne 'Best of Hands - Quick Lockpick & Disarm') {
    throw "Unexpected public module name '$name'."
}

$null = [Guid]::Parse($uuid)
if ([Int64]::Parse($version) -le 0) {
    throw 'Version64 must be positive.'
}

$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
if ($config.RequiredVersion -lt 29) {
    throw 'Script Extender RequiredVersion must be at least 29.'
}
if ($config.ModTable -ne 'BestOfHands') {
    throw "Unexpected Script Extender ModTable '$($config.ModTable)'."
}
if ('Lua' -notin $config.FeatureFlags) {
    throw "Config.json must enable the 'Lua' feature flag."
}

$bootstrap = Get-Content -LiteralPath $bootstrapPath -Raw
if ($bootstrap -notmatch 'Ext\.Require\("Server/Init\.lua"\)') {
    throw 'BootstrapServer.lua does not load Server/Init.lua.'
}

$toolVersions = Get-Content -LiteralPath $toolVersionsPath -Raw | ConvertFrom-Json
if ($toolVersions.bg3ScriptExtender.requiredApiVersion -ne $config.RequiredVersion) {
    throw 'tools/tool-versions.json and Config.json disagree on the Script Extender API floor.'
}

$semanticVersion = (Get-Content -LiteralPath $versionPath -Raw).Trim()
$semanticMatch = [regex]::Match(
    $semanticVersion,
    '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
)
if (-not $semanticMatch.Success) {
    throw "VERSION must contain a stable MAJOR.MINOR.PATCH value: '$semanticVersion'"
}
$major = [Int64]::Parse($semanticMatch.Groups[1].Value)
$minor = [Int64]::Parse($semanticMatch.Groups[2].Value)
$revision = [Int64]::Parse($semanticMatch.Groups[3].Value)
if ($major -gt 255 -or $minor -gt 255 -or $revision -gt 65535) {
    throw "VERSION cannot be represented by BG3 Version64: '$semanticVersion'"
}
$expectedVersion64 = (($major -shl 55) -bor ($minor -shl 47) -bor ($revision -shl 31)).ToString()

$settingsPath = Join-Path $moduleRoot 'ScriptExtender\Lua\Server\Settings.lua'
$settings = Get-Content -LiteralPath $settingsPath -Raw
if ($settings -notmatch ('VERSION\s*=\s*"' + [regex]::Escape($semanticVersion) + '"')) {
    throw "Settings.lua does not expose VERSION $semanticVersion."
}
if ($version -ne $expectedVersion64) {
    throw "meta.lsx Version64 '$version' does not encode VERSION '$semanticVersion' (expected '$expectedVersion64')."
}

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

$actualPackageFiles = Get-ChildItem -LiteralPath (Join-Path $root 'src\BestOfHands') -File -Recurse |
    ForEach-Object {
        $_.FullName.Substring((Join-Path $root 'src\BestOfHands').Length + 1).Replace('\', '/')
    } |
    Sort-Object

$packageDifference = Compare-Object -ReferenceObject $expectedPackageFiles -DifferenceObject $actualPackageFiles
if ($packageDifference) {
    $details = $packageDifference | Out-String
    throw "Package source content does not match the allowlist:`n$details"
}

$luaFiles = Get-ChildItem -LiteralPath (Join-Path $moduleRoot 'ScriptExtender\Lua') -Filter '*.lua' -File -Recurse
foreach ($luaFile in $luaFiles) {
    $content = Get-Content -LiteralPath $luaFile.FullName -Raw
    if ($content -notmatch '(?m)^-- SPDX-License-Identifier: Unlicense\s*$') {
        throw "Lua source is missing the Unlicense SPDX header: $($luaFile.FullName)"
    }
}

$commentCapableSource = @(
    Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -File |
        Where-Object { $_.Extension -in @('.ps1', '.py') }
    Get-ChildItem -LiteralPath (Join-Path $root 'tests') -File -Recurse |
        Where-Object { $_.Extension -eq '.lua' }
    Get-Item -LiteralPath (Join-Path $root '.github\workflows\ci.yml')
)
foreach ($sourceFile in $commentCapableSource) {
    $content = Get-Content -LiteralPath $sourceFile.FullName -Raw
    if ($content -notmatch '(?m)^(#|--)\s*SPDX-License-Identifier: Unlicense\s*$') {
        throw "Source is missing the Unlicense SPDX header: $($sourceFile.FullName)"
    }
}

$sourceText = ($luaFiles | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
$forbiddenCleanRoomMarkers = @(
    'SLEIGHTOFHAND_BUFF_ASTARION',
    'SLEIGHTOFHAND_BUFF_SHADOWHEART',
    'applyHighestSOH',
    'removeSOHBuff'
)
foreach ($marker in $forbiddenCleanRoomMarkers) {
    if ($sourceText.Contains($marker)) {
        throw "Clean-room guard rejected legacy implementation marker '$marker'."
    }
}

$license = Get-Content -LiteralPath $licensePath -Raw
if ($license -notmatch 'This is free and unencumbered software released into the public domain') {
    throw 'LICENSE is not the canonical Unlicense text expected by the release checks.'
}

$creditSurfaces = @($readmePath)
$requiredCredits = @(
    'Auto Lockpicking',
    'Volitio',
    'Use Best Sleight of Hand',
    'JonHinkerton',
    'Best in Party Skills',
    'imCioco'
)
foreach ($surface in $creditSurfaces) {
    $content = Get-Content -LiteralPath $surface -Raw
    foreach ($credit in $requiredCredits) {
        if (-not $content.Contains($credit)) {
            throw "Required reference credit '$credit' is missing from $surface"
        }
    }
}

$publicCopy = Get-Content -LiteralPath $readmePath -Raw
foreach ($requiredStatement in @('credit', 'The Unlicense')) {
    if ($publicCopy -notmatch [regex]::Escape($requiredStatement)) {
        throw "README is missing required statement '$requiredStatement'."
    }
}

Write-Host 'Repository validation passed.' -ForegroundColor Green
Write-Host "Module UUID: $uuid"
Write-Host "Version: $semanticVersion ($version)"
Write-Host "Script Extender API floor: $($config.RequiredVersion)"
Write-Host "Package allowlist: $($expectedPackageFiles.Count) files"
Write-Host "Documentation credit surfaces: $($creditSurfaces.Count)"
