#Requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent $PSScriptRoot
$WindowsRoot = Join-Path $RepositoryRoot 'windows'
$CapabilitiesRoot = Join-Path $WindowsRoot 'capabilities'
$ProfilesRoot = Join-Path $WindowsRoot 'profiles'
$ExpectedSchema = '$schema: https://raw.githubusercontent.com/PowerShell/DSC/main/schemas/2023/08/config/document.json'

$powerShellFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot 'bootstrap') -Filter '*.ps1' -File
)
foreach ($file in $powerShellFiles) {
    $tokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) {
        $messages = @($parseErrors | ForEach-Object { $_.Message }) -join '; '
        throw "PowerShell syntax errors in $($file.FullName): $messages"
    }
}

$jsonFiles = @(Get-ChildItem -LiteralPath $WindowsRoot -Filter '*.json' -File -Recurse)
foreach ($file in $jsonFiles) {
    $null = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
}

$capabilityFiles = @(Get-ChildItem -LiteralPath $CapabilitiesRoot -Filter '*.winget' -File)
$capabilityNames = @($capabilityFiles | ForEach-Object BaseName)
$requiredCapabilities = @(
    'base',
    'development',
    'game-stream-client',
    'game-stream-host',
    'gaming',
    'preferences'
)
foreach ($required in $requiredCapabilities) {
    if ($capabilityNames -notcontains $required) {
        throw "Windows capabilities are missing '$required.winget'."
    }
}
if ($capabilityNames.Count -ne $requiredCapabilities.Count) {
    throw "Unexpected Windows capabilities are present: $($capabilityNames -join ', ')."
}

foreach ($file in $capabilityFiles) {
    $content = Get-Content -LiteralPath $file.FullName -Raw
    $schemaLines = @($content -split "`r?`n" | Where-Object { $_ -match '^\$schema:' })
    if ($schemaLines.Count -ne 1 -or $schemaLines[0] -ne $ExpectedSchema) {
        throw "Windows capability '$($file.Name)' must contain exactly '$ExpectedSchema'."
    }
    if ($content -notmatch '(?m)^resources:\s*$') {
        throw "Windows capability '$($file.Name)' does not declare resources."
    }
    if ($content -match '(?m)^\s+useLatest:') {
        throw "Windows capability '$($file.Name)' must declare package presence without useLatest."
    }

    $resourceNames = @(
        [regex]::Matches($content, '(?m)^\s{4}name:\s*(\S+)\s*$') |
            ForEach-Object { $_.Groups[1].Value }
    )
    $duplicateNames = @(
        $resourceNames |
            Group-Object |
            Where-Object Count -GT 1 |
            Select-Object -ExpandProperty Name
    )
    if ($duplicateNames.Count -gt 0) {
        throw "Windows capability '$($file.Name)' repeats resource names: $($duplicateNames -join ', ')."
    }
}

$base = Get-Content -LiteralPath (Join-Path $CapabilitiesRoot 'base.winget') -Raw
if ($base -match 'Microsoft\.Windows/Registry|Microsoft\.DSC\.Transitional') {
    throw 'The base capability must remain package-only.'
}

$preferences = Get-Content -LiteralPath (Join-Path $CapabilitiesRoot 'preferences.winget') -Raw
if ($preferences -match 'ClassicContextMenu|86ca1aa0-34aa-4e8b-a509-50c905bae2a2') {
    throw 'The preferences capability must not restore the undocumented classic context-menu hack.'
}
if ($preferences -notmatch '(?m)^\s+name: DisableRecallForMachine\s*$') {
    throw 'The optional preferences capability must retain the device-wide Recall policy.'
}

$development = Get-Content -LiteralPath (Join-Path $CapabilitiesRoot 'development.winget') -Raw
if ($development -match 'WindowsWSL|Microsoft\.WSL|windows-wsl\.ps1') {
    throw 'WSL installation is a documented prerequisite and must not return to Windows desired state.'
}
if ($development -notmatch '(?m)^\s+name: WindowsVSCode\s*$') {
    throw 'The development capability must retain Windows VS Code integration.'
}

$profiles = @(Get-ChildItem -LiteralPath $ProfilesRoot -Filter '*.json' -File)
if ($profiles.Count -eq 0) {
    throw 'At least one Windows profile must be declared.'
}
foreach ($file in $profiles) {
    if ($file.BaseName -notmatch '^[a-z0-9][a-z0-9-]*$') {
        throw "Invalid Windows profile filename: $($file.Name)"
    }

    $profile = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
    $selected = @($profile.capabilities)
    $gameStreamProfile = $file.BaseName -in @('game-stream-host', 'game-stream-client')
    if ($selected.Count -eq 0) {
        throw "Windows profile '$($file.BaseName)' must select at least one capability."
    }
    if (-not $gameStreamProfile -and $selected[0] -ne 'base') {
        throw "Windows profile '$($file.BaseName)' must select base first."
    }
    if ($gameStreamProfile -and ($selected.Count -ne 1 -or $selected[0] -ne $file.BaseName)) {
        throw "Windows profile '$($file.BaseName)' must select only its focused role capability."
    }

    $duplicates = @(
        $selected |
            Group-Object |
            Where-Object Count -GT 1 |
            Select-Object -ExpandProperty Name
    )
    if ($duplicates.Count -gt 0) {
        throw "Windows profile '$($file.BaseName)' repeats capabilities: $($duplicates -join ', ')."
    }
    foreach ($capability in $selected) {
        if ($capability -isnot [string] -or $capabilityNames -notcontains $capability) {
            throw "Windows profile '$($file.BaseName)' selects missing capability '$capability'."
        }
    }
    if (($selected -contains 'preferences') -and $selected[-1] -ne 'preferences') {
        throw "Windows profile '$($file.BaseName)' must select optional preferences last."
    }
}

$hostCapability = Get-Content -LiteralPath (Join-Path $CapabilitiesRoot 'game-stream-host.winget') -Raw
$clientCapability = Get-Content -LiteralPath (Join-Path $CapabilitiesRoot 'game-stream-client.winget') -Raw
$gameStreamHelper = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'bootstrap\windows-game-stream.ps1') -Raw
$gameStreamSetup = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'bootstrap\game-stream-setup.ps1') -Raw
$gameStreamLifecycle = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'bootstrap\windows-game-stream-lifecycle.ps1') -Raw
$windowsBootstrap = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'bootstrap\windows.ps1') -Raw
$wslLauncher = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'bootstrap\windows.sh') -Raw
foreach ($required in @(
    'LizardByte.Sunshine',
    'WireGuard.WireGuard',
    'DisableLockScreenAppNotifications',
    'GameStreamHostPolicy',
    'game-stream-context.json',
    'PSNativeCommandUseErrorActionPreference'
)) {
    if ($hostCapability -notmatch [regex]::Escape($required)) {
        throw "The game-stream host capability is missing '$required'."
    }
}
foreach ($required in @(
    'MoonlightGameStreamingProject.Moonlight',
    'WireGuard.WireGuard',
    'GameStreamClientPolicy',
    'game-stream-context.json'
)) {
    if ($clientCapability -notmatch [regex]::Escape($required)) {
        throw "The game-stream client capability is missing '$required'."
    }
}
foreach ($required in @(
    "MinimumSunshineVersion = [version]'2026.516.143833'",
    "DangerousScriptExecution",
    "origin_web_ui_allowed",
    "global_prep_cmd",
    "PersistentKeepalive = 25",
    "sourceDigest",
    "trusted-shared-console",
    "Test-SunshineAlwaysAvailable",
    "Remove-RetiredSessionPolicy",
    "PSObject.Properties['DisplayName']",
    "Set-MoonlightFirewall",
    "Test-MoonlightFirewall",
    "caz.nix-game-stream-client-lan",
    "caz.nix-game-stream-client-tunnel",
    "StartupType Automatic",
    "StartupType Disabled",
    'Group = $ManagedFirewallGroup',
    "WireGuard tunnel service is not automatic and running",
    '$rule.Direction',
    '$rule.Profile',
    '$interfaceAliases.Count',
    'LocalSubnet4',
    "InterfaceType = @('Wired', 'Wireless')",
    'client-role IPv4 /28',
    'WireGuardTunnel`$',
    "ValidateSet('Lan', 'Remote')",
    '[string]$SourceDigest',
    'stage = $Stage.ToLowerInvariant()'
)) {
    if ($gameStreamHelper -notmatch [regex]::Escape($required)) {
        throw "The game-stream helper is missing the '$required' guardrail."
    }
}
foreach ($required in @(
    '$StagedGameStreamContext',
    'game-stream-context.json',
    'ConvertTo-Json',
    'Get-GameStreamSourceDigest -Capabilities $capabilities'
)) {
    if ($windowsBootstrap -notmatch [regex]::Escape($required)) {
        throw "The Windows bootstrap is missing the '$required' staged-context guardrail."
    }
}
if (
    $windowsBootstrap -match 'CAZ_GAME_STREAM_' -or
    $gameStreamHelper -match 'CAZ_GAME_STREAM_' -or
    $hostCapability -match 'CAZ_GAME_STREAM_' -or
    $clientCapability -match 'CAZ_GAME_STREAM_'
) {
    throw 'Game-stream state must cross the WinGet elevation boundary through the staged context, not process environment variables.'
}
foreach ($required in @(
    'powershell.exe',
    'wslpath -w',
    'windows-game-stream-lifecycle.ps1',
    '--prepare',
    '--enroll',
    '--reset-enrollment',
    'git -C',
    "rev-parse --verify 'HEAD^{commit}'",
    '-GameStreamStage',
    'stage=${stage:-lan}'
)) {
    if ($wslLauncher -notmatch [regex]::Escape($required)) {
        throw "The WSL Windows launcher is missing '$required'."
    }
}
if ($wslLauncher -match 'git\.exe|\.ssh') {
    throw 'The WSL Windows launcher must not depend on Windows Git or Windows SSH state.'
}
foreach ($required in @(
    'Set-RestrictedStagingAcl',
    'Copy-RequiredSource',
    'Start-Process',
    '-Verb RunAs',
    '-EncodedCommand',
    'last-error.log',
    '<redacted-wireguard-key>',
    'Remove-Item -LiteralPath $StagingRoot -Recurse -Force',
    'Consumed and removed the one-time enrollment response'
)) {
    if ($gameStreamLifecycle -notmatch [regex]::Escape($required)) {
        throw "The WSL-first game-stream lifecycle is missing '$required'."
    }
}
foreach ($document in @($gameStreamLifecycle, $gameStreamSetup)) {
    if ($document -notmatch [regex]::Escape('$selectedActionCount = @($selectedActions | Where-Object { $_ }).Count')) {
        throw 'Game-stream action selection must retain an array under Windows PowerShell 5.1 strict mode.'
    }
}
foreach ($required in @(
    '$childOutput = @(& powershell.exe @arguments 2>&1)',
    '$previousErrorActionPreference = $ErrorActionPreference',
    '$ErrorActionPreference = ''Continue''',
    '[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)',
    '[Console]::OutputEncoding = $previousConsoleOutputEncoding',
    '$ErrorActionPreference = $previousErrorActionPreference',
    'return $exitCode'
)) {
    if ($gameStreamSetup -notmatch [regex]::Escape($required)) {
        throw "The elevated role wrapper is missing its native stderr boundary: $required"
    }
}
foreach ($required in @(
    'function Assert-EndpointResolvable',
    '[Net.IPAddress]::TryParse($hostName, [ref]$parsedAddress)',
    '[Net.Dns]::GetHostAddresses($hostName)',
    'Assert-EndpointResolvable -Endpoint $response.endpoint',
    'function Remove-ManagedTunnelConfiguration',
    'function Reset-PartialTunnelImport',
    '$ErrorActionPreference = ''Continue''',
    '& $WireGuard /uninstalltunnelservice $TunnelName 2>&1',
    'Stop-Service -Name WireGuardManager -Force -ErrorAction Stop',
    '''Stopped''',
    '[IO.File]::Delete($path)',
    'Start-Service -Name WireGuardManager -ErrorAction Stop',
    '''Running''',
    'Reset-PartialTunnelImport -PendingPublicKey $pendingState.publicKey',
    'Write-WireGuardConfiguration -PendingState $pendingState -Response $response',
    '(Get-ActiveTunnelPublicKey) -ne $pendingState.publicKey',
    'enrollment was not finalized'
)) {
    if ($gameStreamSetup -notmatch [regex]::Escape($required)) {
        throw "The enrollment retry path is missing its deterministic partial-import recovery: $required"
    }
}
$endpointPreflightOffset = $gameStreamSetup.IndexOf('Assert-EndpointResolvable -Endpoint $response.endpoint')
$partialResetOffset = $gameStreamSetup.IndexOf('Reset-PartialTunnelImport -PendingPublicKey $pendingState.publicKey')
if ($endpointPreflightOffset -lt 0 -or $partialResetOffset -lt 0 -or $endpointPreflightOffset -gt $partialResetOffset) {
    throw 'The enrollment endpoint must resolve before partial state is reset or imported.'
}
if ($windowsBootstrap -notmatch '(?s)if \(\$capabilities -contains ''preferences''\) \{.*Exact taskbar pin ordering') {
    throw 'The manual taskbar reminder must remain scoped to profiles that select preferences.'
}
if ($gameStreamLifecycle -match '(?im)^\s*(PrivateKey|PublicKey|Endpoint|Address|AllowedIPs)\s*=') {
    throw 'The WSL-first lifecycle must not embed production WireGuard material.'
}
$configurationTestFunction = [regex]::Match(
    $gameStreamHelper,
    '(?s)function Test-Configuration \{(?<body>.*?)\n\}'
)
if (
    -not $configurationTestFunction.Success -or
    [regex]::Matches(
        $configurationTestFunction.Groups['body'].Value,
        'Get-TunnelPeerRoute -Wg \$wg'
    ).Count -ne 1 -or
    $configurationTestFunction.Groups['body'].Value -notmatch '\$tunnelReady -and \$null -ne \$wg'
) {
    throw 'The game-stream check must query wg.exe only behind the ready tunnel-service guard.'
}
foreach ($required in @(
    'caz.nix/game-stream-request/v1',
    'caz.nix/game-stream-enrollment/v1',
    'caz.nix/game-stream-local-state/v1',
    'Ensure-WireGuardTools',
    'Set-AdministratorOnlyAcl',
    'Write-PublicRequest',
    'ResetEnrollment',
    'Invoke-RoleConfiguration'
)) {
    if ($gameStreamSetup -notmatch [regex]::Escape($required)) {
        throw "The game-stream setup orchestrator is missing '$required'."
    }
}
$publicRequestFunction = [regex]::Match(
    $gameStreamSetup,
    '(?s)function Write-PublicRequest \{(?<body>.*?)\n\}'
)
if (
    -not $publicRequestFunction.Success -or
    $publicRequestFunction.Groups['body'].Value -match 'privateKey'
) {
    throw 'The public enrollment request must never contain the locally generated private key.'
}
$dangerousScriptsOffset = $gameStreamHelper.IndexOf('Remove-ItemProperty')
$enrollmentImportOffset = $gameStreamHelper.IndexOf(
    'Import-WireGuardEnrollment -WireGuard $wireGuard -EnrollmentFile $EnrollmentFile'
)
$tunnelStartOffset = $gameStreamHelper.IndexOf('Start-DpapiTunnelService -WireGuard $wireGuard')
if (
    $dangerousScriptsOffset -lt 0 -or
    $enrollmentImportOffset -lt 0 -or
    $tunnelStartOffset -lt 0 -or
    $dangerousScriptsOffset -gt $enrollmentImportOffset -or
    $dangerousScriptsOffset -gt $tunnelStartOffset
) {
    throw 'WireGuard Local System hooks must be disabled before enrollment import or tunnel start.'
}
$sunshineDisableOffset = $gameStreamHelper.IndexOf(
    'Set-Service -Name $sunshineService.Name -StartupType Disabled'
)
$sunshineStopOffset = $gameStreamHelper.IndexOf('Stop-Service -Name $sunshineService.Name -Force')
$sunshineSettingOffset = $gameStreamHelper.IndexOf('Set-SunshineSetting -Name upnp -Value disabled')
$sunshineAutomaticOffset = $gameStreamHelper.IndexOf(
    'Set-Service -Name $sunshineService.Name -StartupType Automatic'
)
$sunshineStartOffset = $gameStreamHelper.IndexOf('Start-Service -Name $sunshineService.Name')
if (
    @(
        $sunshineDisableOffset,
        $sunshineStopOffset,
        $sunshineSettingOffset,
        $sunshineAutomaticOffset,
        $sunshineStartOffset
    ) -contains -1 -or
    $sunshineDisableOffset -gt $sunshineStopOffset -or
    $sunshineStopOffset -gt $sunshineSettingOffset -or
    $sunshineSettingOffset -gt $sunshineAutomaticOffset -or
    $sunshineAutomaticOffset -gt $sunshineStartOffset
) {
    throw 'Sunshine must remain disabled and stopped until its managed settings are ready for restart.'
}
if ($gameStreamHelper -match '(?im)^\s*(PrivateKey|PublicKey|Endpoint|Address|AllowedIPs)\s*=') {
    throw 'The game-stream helper must not embed production WireGuard material.'
}
foreach ($retiredHelper in @(
    'bootstrap\windows-game-stream-session.ps1',
    'bootstrap\windows-game-stream-control.ps1'
)) {
    if (Test-Path -LiteralPath (Join-Path $RepositoryRoot $retiredHelper)) {
        throw "The retired game-stream session helper remains present: $retiredHelper"
    }
}

Write-Host "Validated $($powerShellFiles.Count) PowerShell files, $($jsonFiles.Count) JSON files, $($capabilityFiles.Count) capabilities, and $($profiles.Count) profiles."
