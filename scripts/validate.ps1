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
$noticesPath = Join-Path $root 'THIRD_PARTY_NOTICES.txt'
$workflowPath = Join-Path $root '.github\workflows\ci.yml'
$nativeCmakePath = Join-Path $root 'native\CMakeLists.txt'
$nativeResourcePath = Join-Path $root 'native\resources\BestofHands.rc.in'
$nativeHeaderPath = Join-Path $root 'native\include\BridgeProtocol.h'
$nativeQuickLockpickHeaderPath = Join-Path $root 'native\include\QuickLockpickState.h'
$nativeSourcePath = Join-Path $root 'native\src\BestOfHandsNative.cpp'
$nativeBridgePath = Join-Path $moduleRoot 'ScriptExtender\Lua\Server\NativeBridge.lua'

$requiredFiles = @(
    $metaPath,
    $configPath,
    $bootstrapPath,
    $initPath,
    $toolVersionsPath,
    $versionPath,
    $licensePath,
    $readmePath,
    $developmentPath,
    $noticesPath,
    $workflowPath,
    $nativeCmakePath,
    $nativeResourcePath,
    $nativeHeaderPath,
    $nativeQuickLockpickHeaderPath,
    $nativeSourcePath,
    $nativeBridgePath
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
$declaredDependencies = @($meta.SelectNodes("//node[@id='Dependencies']/children/node"))
if ($declaredDependencies.Count -ne 0) {
    throw 'Best of Hands optional integrations must not add metadata dependencies.'
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
if ($toolVersions.bg3NativeModLoader.installPath -cne 'bin/NativeMods/BestofHands.dll') {
    throw 'The native install path must use the shipped BestofHands.dll filename.'
}
if ($toolVersions.nativeBuildDependencies.safetyHook -ne '0.7.0' -or
    $toolVersions.nativeBuildDependencies.zydis -ne '4.1.0' -or
    $toolVersions.nativeBuildDependencies.zycore -ne '1.5.0') {
    throw 'Native dependency versions are missing or differ from the reviewed build set.'
}
$cmakeVersion = [string]$toolVersions.nativeBuildToolchain.cmake
$cmakeArchive = [string]$toolVersions.nativeBuildToolchain.archive
$cmakeArchiveSha256 = [string]$toolVersions.nativeBuildToolchain.archiveSha256
if ($cmakeVersion -notmatch '^\d+\.\d+\.\d+$' -or
    ([Version]$cmakeVersion) -lt [Version]'4.2.0' -or
    $cmakeArchive -cne "cmake-$cmakeVersion-windows-x86_64.zip" -or
    $cmakeArchiveSha256 -notmatch '^[0-9a-f]{64}$') {
    throw 'Pinned native CMake toolchain metadata is missing or invalid.'
}
$workflowText = Get-Content -LiteralPath $workflowPath -Raw
$expectedNexusDescription = @'
          description: |-
            IMPORTANT:
            You need to MANUALLY install the .dll in the downloaded .zip file after you install this mod via your mod manager! BG3MM will not install it for you!

            Place the .dll in: [BG3 folder]/bin/NativeMods
            Create the folder if it doesn't exist yet.
'@
if (-not $workflowText.Contains($expectedNexusDescription)) {
    throw 'The Nexus release file description differs from the approved manual-install text.'
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
    'Mods/BestOfHands/ScriptExtender/Lua/BootstrapClient.lua',
    'Mods/BestOfHands/ScriptExtender/Lua/BootstrapServer.lua',
    'Mods/BestOfHands/ScriptExtender/Lua/Client/NativePresentationBridge.lua',
    'Mods/BestOfHands/ScriptExtender/Lua/Shared/Channels.lua',
    'Mods/BestOfHands/ScriptExtender/Lua/Server/LegacyAssistanceCleanup.lua',
    'Mods/BestOfHands/ScriptExtender/Lua/Server/Diagnostics.lua',
    'Mods/BestOfHands/ScriptExtender/Lua/Server/Init.lua',
    'Mods/BestOfHands/ScriptExtender/Lua/Server/NativeBridge.lua',
    'Mods/BestOfHands/ScriptExtender/Lua/Server/NativeInteractionCoordinator.lua',
    'Mods/BestOfHands/ScriptExtender/Lua/Server/NativeRuntimeApi.lua',
    'Mods/BestOfHands/ScriptExtender/Lua/Server/PartySkillResolver.lua',
    'Mods/BestOfHands/ScriptExtender/Lua/Server/QuickLockpickCoordinator.lua',
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
    Get-ChildItem -LiteralPath (Join-Path $root 'native') -File -Recurse |
        Where-Object { $_.Extension -in @('.cpp', '.h') }
    Get-Item -LiteralPath $nativeCmakePath
    Get-Item -LiteralPath $workflowPath
)
foreach ($sourceFile in $commentCapableSource) {
    $content = Get-Content -LiteralPath $sourceFile.FullName -Raw
    if ($content -notmatch '(?m)^(#|--|//)\s*SPDX-License-Identifier: Unlicense\s*$') {
        throw "Source is missing the Unlicense SPDX header: $($sourceFile.FullName)"
    }
}

$powershellFiles = Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -File -Filter '*.ps1'
foreach ($powershellFile in $powershellFiles) {
    $parserTokens = $null
    $parserErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
        $powershellFile.FullName,
        [ref]$parserTokens,
        [ref]$parserErrors
    )
    if ($parserErrors.Count -ne 0) {
        $details = ($parserErrors | ForEach-Object { $_.Message }) -join [Environment]::NewLine
        throw "PowerShell syntax failed for $($powershellFile.FullName):`n$details"
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

$forbiddenOptionalIntegrationMarkers = @(
    'TemplateAddTo(',
    'TemplateRemoveFromParty(',
    'AddExplorationExperience(',
    '"Disarm Trap"'
)
foreach ($marker in $forbiddenOptionalIntegrationMarkers) {
    if ($sourceText.Contains($marker)) {
        throw "Optional integration boundary rejected owned Eternal behavior '$marker'."
    }
}
$forbiddenV1ExecutionMarkers = @(
    'RequestActiveRoll(',
    'PROC_ProcessLockpickItem(',
    'PROC_ProcessDisarmTrap(',
    'TemplateRemoveFrom(',
    'Osi.Unlock('
)
foreach ($marker in $forbiddenV1ExecutionMarkers) {
    if ($sourceText.Contains($marker)) {
        throw "V2 native boundary rejected legacy custom execution marker '$marker'."
    }
}

$initText = Get-Content -LiteralPath $initPath -Raw
foreach ($requiredNativeSurface in @(
    'Server/NativeBridge.lua',
    'Server/NativeInteractionCoordinator.lua',
    'Server/QuickLockpickCoordinator.lua',
    'listen("UseFinished"',
    'listen("RequestCanLockpick"',
    'listen("RequestCanDisarmTrap"',
    'listen("RequestProcessed"'
)) {
    if (-not $initText.Contains($requiredNativeSurface)) {
        throw "V2 native bootstrap surface is missing '$requiredNativeSurface'."
    }
}

$coordinatorPath = Join-Path $moduleRoot 'ScriptExtender\Lua\Server\NativeInteractionCoordinator.lua'
$coordinatorText = Get-Content -LiteralPath $coordinatorPath -Raw
foreach ($requiredDiagnosticSurface in @(
    'OnRequestedRollChanged',
    'OnRequestedRollDestroyed',
    'ServerRollStartSpellRequest',
    'native_requested_roll_state',
    'discarded_dice_total',
    'native_roll_bonus_spell_request',
    'native_roll_canceled',
    'native_tool_unavailable',
    'native_reference_roll_correlated',
    'native_delegation_retained_after_roll_destroy'
)) {
    if (-not $coordinatorText.Contains($requiredDiagnosticSurface)) {
        throw "Native diagnostic/lifecycle surface is missing '$requiredDiagnosticSurface'."
    }
}
if ($coordinatorText.Contains('native_roll_component_canceled')) {
    throw 'RequestedRoll.Canceled must not own native mapping cleanup.'
}

$clientBootstrapPath = Join-Path $moduleRoot 'ScriptExtender\Lua\BootstrapClient.lua'
$clientPresentationPath = Join-Path $moduleRoot 'ScriptExtender\Lua\Client\NativePresentationBridge.lua'
$clientBootstrapText = Get-Content -LiteralPath $clientBootstrapPath -Raw
$clientPresentationText = Get-Content -LiteralPath $clientPresentationPath -Raw
foreach ($requiredClientBootstrap in @(
    'Client/NativePresentationBridge.lua'
)) {
    if (-not $clientBootstrapText.Contains($requiredClientBootstrap)) {
        throw "Client bootstrap is missing '$requiredClientBootstrap'."
    }
}
foreach ($requiredClientPresentationSurface in @(
    'BestOfHandsNative.client',
    'client_profile_mapping_written',
    'client_profile_mapping_removed',
    'client_quick_lockpick_queued',
    'dc_active_roll_trace',
    'saveLeftClickSnapshot',
    'SendToServer',
    'rollUuid',
    'specialistHandle'
)) {
    if (-not $clientPresentationText.Contains($requiredClientPresentationSurface)) {
        throw "Client native presentation bridge is missing '$requiredClientPresentationSurface'."
    }
}
if ($clientPresentationText.Contains('component.AdvantageType =')) {
    throw 'Client presentation bridge must not mutate replicated RequestedRoll advantage state.'
}
$clientTraceWrites = [regex]::Matches(
    $clientPresentationText,
    'write\("TRACE"'
)
if ($clientTraceWrites.Count -ne 1 -or
    $clientPresentationText -notmatch
        'local function trace\([\s\S]*?if not traceEnabled then[\s\S]*?loadActionText\(\)') {
    throw 'Client TRACE output must pass only through the fail-closed trace gate.'
}

$runtimeApiPath = Join-Path $moduleRoot 'ScriptExtender\Lua\Server\NativeRuntimeApi.lua'
$runtimeApiText = Get-Content -LiteralPath $runtimeApiPath -Raw
if (-not $runtimeApiText.Contains('GetItemByTemplateInPartyInventory')) {
    throw 'Native runtime must use BG3 party inventory for the no-tool delegation precheck.'
}
foreach ($requiredMissingToolSurface in @(
    'DB_CustomLockpickItemResponse',
    'DB_CustomDisarmTrapResponse',
    'ShowError',
    'CannotUse'
)) {
    if (-not $runtimeApiText.Contains($requiredMissingToolSurface)) {
        throw "The no-tool rejection path is missing '$requiredMissingToolSurface'."
    }
}
foreach ($requiredQuickLockpickSurface in @(
    '"quick=" .. record.request',
    'operation = "queued"',
    '"eligible=" .. record.initiator',
    'tostring(record.targetNetId)'
)) {
    if (-not $clientPresentationText.Contains($requiredQuickLockpickSurface)) {
        throw "The native quick-lockpick queue path is missing '$requiredQuickLockpickSurface'."
    }
}
foreach ($forbiddenMappedTaskWrite in @(
    'controller.RunningTask = task',
    'controller.IsNewTaskStarted = true'
)) {
    if ($clientPresentationText.Contains($forbiddenMappedTaskWrite)) {
        throw "Lua must not bypass BG3's native task lifecycle with '$forbiddenMappedTaskWrite'."
    }
}

$nativeHeader = Get-Content -LiteralPath $nativeHeaderPath -Raw
if ($nativeHeader -notmatch ('kPluginVersion\s*=\s*"' + [regex]::Escape($semanticVersion) + '"')) {
    throw "Native bridge protocol does not expose version $semanticVersion."
}
$nativeCmake = Get-Content -LiteralPath $nativeCmakePath -Raw
if ($nativeCmake -notmatch ('project\(BestOfHandsNative VERSION ' + [regex]::Escape($semanticVersion))) {
    throw "Native CMake project does not expose version $semanticVersion."
}
if ($nativeCmake -notmatch 'OUTPUT_NAME\s+"BestofHands"') {
    throw 'Native CMake output must be named BestofHands.dll.'
}
if ($nativeCmake -notmatch 'resources/BestofHands\.rc\.in' -or
    $nativeCmake -notmatch 'generated/BestofHands\.rc') {
    throw 'Native CMake must compile the generated third-party-notices resource.'
}
$nativeResource = Get-Content -LiteralPath $nativeResourcePath -Raw
if ($nativeResource -notmatch 'RCDATA\s+"@BEST_OF_HANDS_NOTICES_PATH@"') {
    throw 'The native resource template must embed THIRD_PARTY_NOTICES.txt.'
}
$nativeSource = Get-Content -LiteralPath $nativeSourcePath -Raw
$nativeQuickLockpickHeader = Get-Content -LiteralPath $nativeQuickLockpickHeaderPath -Raw
if ($nativeSource.Contains('Log("INFO", "native_quick_lockpick_started"')) {
    throw 'Routine native quick-lockpick monitoring must not use an always-on INFO log.'
}
foreach ($requiredNativeMarker in @(
    'ProfileUiMidHook',
    'ProfileMathMidHook',
    'ClientRollPresentationMidHook',
    'ClientRollAggregateMidHook',
    'ClientRollStartMidHook',
    'ClientRollResultMidHook',
    'ClientRollFinalizeMidHook',
    'kProfileUiSignature',
    'kProfileMathSignature',
    'kClientRollPresentationSignature',
    'kClientRollAggregateSignature',
    'kClientRollStartSignature',
    'kClientRollPayloadReadySignature',
    'kClientRollPostDispatchSignature',
    'kClientRollResultSignature',
    'kClientRollFinalizeSignature',
    'native_profile_source_selected',
    'native_client_roll_presentation_selected',
    'native_client_roll_aggregate_guard',
    'native_client_roll_start_boundary',
    'native_client_roll_bonus_direct_handoff_armed',
    'pre_roll_synthetic_rows=0',
    'native_client_roll_selected_bonus_restored',
    'native_client_roll_result_consistency',
    'native_client_roll_finalize_consistency',
    'MatchClientPresentationLease',
    'kMaximumClientPresentationLeases',
    'client_roll_aggregate,client_roll_start,',
    'client_roll_payload_ready,client_roll_post_dispatch,',
    'client_roll_finalize',
    'result_numeric_values_unchanged=1',
    'kActiveRollFallbackOffset',
    'FreezeClientPresentationAdvantage',
    'ProfileScope::Client',
    'component_owner_unchanged=1',
    'requested_roll_owner_mutation=0',
    'native_profile_substitution',
    'quick_lockpick_task_adapter',
    'ClientInputControllerUpdateDetour',
    'TryInvokeSetRunningTask',
    'TryGetCharacterTask',
    'kClientGetCharacterTaskSignature',
    'clientGetCharacterTaskRva',
    'kClientInputControllerUpdateSignature',
    'kClientSetRunningTaskSignature',
    'FindStockCharacterTask',
    'BuildLeftClickRoutingSnapshot',
    'g_clientGetCharacterTaskProcedure',
    'StockLockpickTaskConfiguration',
    'activation=engine_set_running_task',
    'unsupported_game_build'
)) {
    if (-not $nativeSource.Contains($requiredNativeMarker)) {
        throw "Native source is missing required fail-closed marker '$requiredNativeMarker'."
    }
}
foreach ($forbiddenQuickLockpickNativeSurface in @(
    'kClientControllerUpdateVtableIndex',
    'kClientControllerSetRunningTaskVtableIndex',
    'ReadClientControllerMethod',
    'kClientControllerTasksOffset',
    'kClientCharacterTaskTypeOffset',
    'QuickLockpickActivation',
    'QuickLockpickDiagnostic',
    'native_left_click_snapshot_refreshed',
    'IsClientGetCharacterTaskAddress',
    'g_consumedQuickLockpickOrder',
    'kMaximumQuickLockpickRequests'
)) {
    if ($nativeSource.Contains($forbiddenQuickLockpickNativeSurface) -or
        $nativeHeader.Contains($forbiddenQuickLockpickNativeSurface) -or
        $nativeQuickLockpickHeader.Contains($forbiddenQuickLockpickNativeSurface)) {
        throw "Native source retains guessed quick-lockpick ABI '$forbiddenQuickLockpickNativeSurface'."
    }
}
foreach ($requiredQuickLockpickContract in @(
    'sizeof(StockLockpickTaskConfiguration) == 0x13',
    'BuildLeftClickRoutingSnapshot',
    'ResolveLeftClickTarget',
    'PruneConsumedQuickLockpicks'
)) {
    if (-not $nativeQuickLockpickHeader.Contains($requiredQuickLockpickContract)) {
        throw "Native quick-lockpick state contract is missing '$requiredQuickLockpickContract'."
    }
}
if ($sourceText.Contains('QUICK_LOCKPICK_DIAGNOSTICS')) {
    throw 'Production Lua retains the retired always-on quick-lockpick diagnostics switch.'
}
if ($sourceText -match 'TRACE_EVENTS\s*=\s*true') {
    throw 'Production Lua must default all trace switches to disabled.'
}
foreach ($removedProductionTraceHook in @(
    'ClientRollPhaseMidHook',
    'ClientModifierAnimationStartMidHook',
    'ClientModifierAnimationEndMidHook'
)) {
    if ($nativeSource.Contains($removedProductionTraceHook)) {
        throw "Production native source retains trace-only hook '$removedProductionTraceHook'."
    }
}
if ($nativeSource -notmatch 'constexpr bool TraceEnabled\(\) noexcept\s*\{\s*return false;') {
    throw 'Production native tracing must be compile-time disabled.'
}
if ($nativeSource -match 'PatchDisarm|PatchLockpick|PatchRequestedRoll|RouteFinishedEvent') {
    throw 'Native v2 must not mutate action-specific disarm or lockpick ownership state.'
}
if ($nativeSource.Contains('ClientSetRunningTaskDetour')) {
    throw 'Native v2 must not retain the bypassed public SetRunningTask interception path.'
}
if (-not $nativeSource.Contains('ClientTaskSelectionMidHook') -or
    -not $nativeSource.Contains('kClientTaskSelectionSignature')) {
    throw 'Native left-click lockpicking must use the signature-guarded internal task-selection boundary.'
}
if ($nativeSource.Contains('0x01b3a2d2')) {
    throw 'Native left-click lockpicking must intercept before BG3 retires non-winning task readiness.'
}
if ($nativeSource -notmatch 'safetyhook::create_mid') {
    throw 'Native v2 must install validated mid-function profile hooks.'
}

$reportedHooksMatch = [regex]::Match(
    $nativeSource,
    'constexpr std::string_view kReportedHooks\s*=\s*(?<body>[\s\S]*?);'
)
$requiredHooksSource = Get-Content -LiteralPath $nativeBridgePath -Raw
$requiredHooksMatch = [regex]::Match(
    $requiredHooksSource,
    'local REQUIRED_HOOKS\s*=\s*(?<body>[\s\S]*?)\r?\nlocal REQUIRED_FEATURES'
)
if (-not $reportedHooksMatch.Success -or -not $requiredHooksMatch.Success) {
    throw 'Could not parse the native/Lua hook handshake manifests.'
}
$reportedHooks = ([regex]::Matches(
    $reportedHooksMatch.Groups['body'].Value,
    '"([^"]*)"'
) | ForEach-Object { $_.Groups[1].Value }) -join ''
$requiredHooks = ([regex]::Matches(
    $requiredHooksMatch.Groups['body'].Value,
    '"([^"]*)"'
) | ForEach-Object { $_.Groups[1].Value }) -join ''
if ($reportedHooks -ne $requiredHooks) {
    throw "Native and Lua hook handshake manifests differ.`nNative: $reportedHooks`nLua: $requiredHooks"
}
if ($reportedHooks.Contains('client_roll_bonus_preserve_selected')) {
    throw 'Production hook manifest retains the retired observation-only selected-modifier hook.'
}

$reportedFeaturesMatch = [regex]::Match(
    $nativeSource,
    'constexpr std::string_view kReportedFeatures\s*=\s*(?<body>[\s\S]*?);'
)
$requiredFeaturesMatch = [regex]::Match(
    $requiredHooksSource,
    'local REQUIRED_FEATURES\s*=\s*"(?<value>[^"]*)"'
)
if (-not $reportedFeaturesMatch.Success -or -not $requiredFeaturesMatch.Success) {
    throw 'Could not parse the native/Lua feature handshake manifests.'
}
$reportedFeatures = ([regex]::Matches(
    $reportedFeaturesMatch.Groups['body'].Value,
    '"([^"]*)"'
) | ForEach-Object { $_.Groups[1].Value }) -join ''
$requiredFeatures = $requiredFeaturesMatch.Groups['value'].Value
if ($reportedFeatures -ne $requiredFeatures) {
    throw "Native and Lua feature handshake manifests differ.`nNative: $reportedFeatures`nLua: $requiredFeatures"
}

$license = Get-Content -LiteralPath $licensePath -Raw
if ($license -notmatch 'This is free and unencumbered software released into the public domain') {
    throw 'LICENSE is not the canonical Unlicense text expected by the release checks.'
}
$thirdPartyNotices = Get-Content -LiteralPath $noticesPath -Raw
foreach ($requiredNotice in @('SafetyHook 0.7.0', 'Boost Software License',
    'Zydis 4.1.0', 'Zycore 1.5.0', 'The MIT License')) {
    if (-not $thirdPartyNotices.Contains($requiredNotice)) {
        throw "THIRD_PARTY_NOTICES.txt is missing '$requiredNotice'."
    }
}

$creditSurfaces = @($readmePath)
$requiredCredits = @(
    'Auto Lockpicking',
    'Volitio',
    'Use Best Sleight of Hand',
    'JonHinkerton',
    'Best in Party Skills',
    'imCioco',
    'Eternal Lockpick',
    'Eternal Trap Disarm Kit',
    'SwissFred'
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
