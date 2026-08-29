#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Host', 'Client')]
    [string]$Role,

    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TunnelName = 'game-stream'
$TunnelServiceName = "WireGuardTunnel`$$TunnelName"
$MinimumSunshineVersion = [version]'2026.516.143833'
$ManagedFirewallGroup = 'caz.nix game-stream host'
$ManagedTcpRule = 'caz.nix-game-stream-host-tcp'
$ManagedUdpRule = 'caz.nix-game-stream-host-udp'
$StateRoot = Join-Path $env:ProgramData "caz.nix\game-stream-$($Role.ToLowerInvariant())"
$StateFile = Join-Path $StateRoot 'desired-state.json'
$LegacySessionPolicyRoot = Join-Path $env:ProgramFiles 'caz.nix\game-stream-host'
$LegacySessionPolicyTaskName = 'caz.nix game-stream session arbiter'
$WireGuardConfigurationRoot = Join-Path $env:ProgramFiles 'WireGuard\Data\Configurations'
$DpapiConfiguration = Join-Path $WireGuardConfigurationRoot "$TunnelName.conf.dpapi"
$PlaintextConfiguration = Join-Path $WireGuardConfigurationRoot "$TunnelName.conf"
$SunshineRoot = Join-Path $env:ProgramFiles 'Sunshine'
$SunshineExecutable = Join-Path $SunshineRoot 'sunshine.exe'
$SunshineConfiguration = Join-Path $SunshineRoot 'config\sunshine.conf'
$SunshineState = Join-Path $SunshineRoot 'config\sunshine_state.json'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Set-AdministratorOnlyAcl {
    param([Parameter(Mandatory)][string]$Path)

    $null = & (Join-Path $env:SystemRoot 'System32\icacls.exe') `
        $Path `
        '/inheritance:r' `
        '/grant:r' `
        '*S-1-5-18:(OI)(CI)F' `
        '*S-1-5-32-544:(OI)(CI)F'
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not restrict the game-stream state directory to System and Administrators.'
    }
}

function Initialize-StateRoot {
    $null = New-Item -ItemType Directory -Path $StateRoot -Force
    Set-AdministratorOnlyAcl -Path $StateRoot
}

function Get-WireGuardCommand {
    $wireGuard = Join-Path $env:ProgramFiles 'WireGuard\wireguard.exe'
    if (-not (Test-Path -LiteralPath $wireGuard -PathType Leaf)) {
        return $null
    }
    return $wireGuard
}

function Get-WgCommand {
    $candidate = Join-Path $env:ProgramFiles 'WireGuard\wg.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return $candidate
    }
    return $null
}

function Get-IniValues {
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key
    )

    $values = [Collections.Generic.List[string]]::new()
    $currentSection = ''
    foreach ($line in ($Content -split "`r?`n")) {
        if ($line -match '^\s*\[(?<section>[^]]+)\]\s*$') {
            $currentSection = $Matches.section
            continue
        }
        if ($currentSection -ieq $Section -and $line -match '^\s*(?<key>[^#;=]+?)\s*=\s*(?<value>.*?)\s*$') {
            if ($Matches.key.Trim() -ieq $Key) {
                $values.Add($Matches.value.Trim())
            }
        }
    }
    return @($values)
}

function Test-ExactIpv4Route {
    param([Parameter(Mandatory)][string]$Route)

    if ($Route -notmatch '^(?<address>(\d{1,3}\.){3}\d{1,3})/32$') {
        return $false
    }
    foreach ($octet in $Matches.address.Split('.')) {
        if ([int]$octet -gt 255) {
            return $false
        }
    }
    return $true
}

function Assert-SafeEnrollment {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'The explicit local WireGuard enrollment file is unavailable.'
    }
    $content = Get-Content -LiteralPath $Path -Raw
    if ($content -match '(?im)^\s*(SaveConfig|DNS|Table|PreUp|PostUp|PreDown|PostDown)\s*=') {
        throw 'The enrollment contains a forbidden WireGuard directive.'
    }
    if (@([regex]::Matches($content, '(?im)^\s*\[Interface\]\s*$')).Count -ne 1) {
        throw 'The enrollment must contain exactly one Interface section.'
    }
    if (@([regex]::Matches($content, '(?im)^\s*\[Peer\]\s*$')).Count -ne 1) {
        throw 'The enrollment must contain exactly one gateway Peer section.'
    }

    $addresses = @(Get-IniValues -Content $content -Section Interface -Key Address)
    $privateKeys = @(Get-IniValues -Content $content -Section Interface -Key PrivateKey)
    $publicKeys = @(Get-IniValues -Content $content -Section Peer -Key PublicKey)
    $allowedIps = @(Get-IniValues -Content $content -Section Peer -Key AllowedIPs)
    $endpoints = @(Get-IniValues -Content $content -Section Peer -Key Endpoint)
    $keepalives = @(Get-IniValues -Content $content -Section Peer -Key PersistentKeepalive)

    if ($addresses.Count -ne 1 -or -not (Test-ExactIpv4Route -Route $addresses[0])) {
        throw 'The enrollment interface must use one exact IPv4 /32.'
    }
    if ($privateKeys.Count -ne 1 -or [string]::IsNullOrWhiteSpace($privateKeys[0])) {
        throw 'The enrollment must contain one private key.'
    }
    if ($publicKeys.Count -ne 1 -or [string]::IsNullOrWhiteSpace($publicKeys[0])) {
        throw 'The enrollment must contain one gateway public key.'
    }
    if (
        $allowedIps.Count -ne 1 -or
        $allowedIps[0] -match ',' -or
        -not (Test-ExactIpv4Route -Route $allowedIps[0])
    ) {
        throw 'The enrollment must route only the opposite game-stream role IPv4 /32.'
    }
    if ($endpoints.Count -ne 1 -or [string]::IsNullOrWhiteSpace($endpoints[0])) {
        throw 'The enrollment must contain one gateway endpoint.'
    }
    if ($keepalives.Count -ne 1 -or $keepalives[0] -ne '25') {
        throw 'The enrollment must declare PersistentKeepalive = 25.'
    }
}

function Import-WireGuardEnrollment {
    param(
        [Parameter(Mandatory)][string]$WireGuard,
        [Parameter(Mandatory)][string]$EnrollmentFile
    )

    Assert-SafeEnrollment -Path $EnrollmentFile
    if (Test-Path -LiteralPath $DpapiConfiguration -PathType Leaf) {
        throw 'A DPAPI-backed enrollment already exists. Reuse it without an enrollment input, or revoke it before an explicit replacement.'
    }

    $manager = Get-Service -Name WireGuardManager -ErrorAction SilentlyContinue
    if ($null -eq $manager) {
        & $WireGuard /installmanagerservice
        if ($LASTEXITCODE -ne 0) {
            throw 'WireGuard could not install its configuration manager service.'
        }
    }
    $manager = Get-Service -Name WireGuardManager -ErrorAction Stop
    if ($manager.Status -ne 'Running') {
        Start-Service -Name WireGuardManager
    }

    $null = New-Item -ItemType Directory -Path $WireGuardConfigurationRoot -Force
    Move-Item -LiteralPath $EnrollmentFile -Destination $PlaintextConfiguration -Force

    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (
        [DateTime]::UtcNow -lt $deadline -and
        (
            -not (Test-Path -LiteralPath $DpapiConfiguration -PathType Leaf) -or
            (Test-Path -LiteralPath $PlaintextConfiguration -PathType Leaf)
        )
    ) {
        Start-Sleep -Milliseconds 250
    }
    if (
        -not (Test-Path -LiteralPath $DpapiConfiguration -PathType Leaf) -or
        (Test-Path -LiteralPath $PlaintextConfiguration -PathType Leaf)
    ) {
        throw 'WireGuard did not convert and remove the plaintext enrollment within 30 seconds.'
    }

    if ($null -eq (Get-Service -Name $TunnelServiceName -ErrorAction SilentlyContinue)) {
        & $WireGuard /installtunnelservice $DpapiConfiguration
        if ($LASTEXITCODE -ne 0) {
            throw 'WireGuard could not install the DPAPI-backed tunnel service.'
        }
    }
    Set-Service -Name $TunnelServiceName -StartupType Automatic
    if ((Get-Service -Name $TunnelServiceName).Status -ne 'Running') {
        Start-Service -Name $TunnelServiceName
    }
}

function Start-DpapiTunnelService {
    param([Parameter(Mandatory)][string]$WireGuard)

    if ($null -eq (Get-Service -Name $TunnelServiceName -ErrorAction SilentlyContinue)) {
        & $WireGuard /installtunnelservice $DpapiConfiguration
        if ($LASTEXITCODE -ne 0) {
            throw 'WireGuard could not install the DPAPI-backed tunnel service.'
        }
    }
    Set-Service -Name $TunnelServiceName -StartupType Automatic
    if ((Get-Service -Name $TunnelServiceName).Status -ne 'Running') {
        Start-Service -Name $TunnelServiceName
    }
}

function Get-TunnelPeerRoute {
    param([Parameter(Mandatory)][string]$Wg)

    $output = @(& $Wg show $TunnelName allowed-ips 2>$null)
    if ($LASTEXITCODE -ne 0 -or $output.Count -ne 1) {
        return $null
    }
    $fields = @($output[0] -split '\s+' | Where-Object { $_ })
    if ($fields.Count -ne 2 -or $fields[1] -match ',' -or -not (Test-ExactIpv4Route -Route $fields[1])) {
        return $null
    }
    return $fields[1]
}

function Test-TunnelKeepalive {
    param([Parameter(Mandatory)][string]$Wg)

    $output = @(& $Wg show $TunnelName persistent-keepalive 2>$null)
    if ($LASTEXITCODE -ne 0 -or $output.Count -ne 1) {
        return $false
    }
    $fields = @($output[0] -split '\s+' | Where-Object { $_ })
    return $fields.Count -eq 2 -and $fields[1] -eq '25'
}

function Test-TunnelHandshakeHealthy {
    param([Parameter(Mandatory)][string]$Wg)

    $output = @(& $Wg show $TunnelName latest-handshakes 2>$null)
    if ($LASTEXITCODE -ne 0 -or $output.Count -ne 1) {
        return $false
    }
    $fields = @($output[0] -split '\s+' | Where-Object { $_ })
    if ($fields.Count -ne 2 -or $fields[1] -notmatch '^\d+$') {
        return $false
    }
    $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]$fields[1]
    return [long]$fields[1] -gt 0 -and $age -ge 0 -and $age -lt 180
}

function Test-MoonlightInstalled {
    $uninstallRoots = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($root in $uninstallRoots) {
        $match = Get-ItemProperty -Path $root -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match '^Moonlight(?: Game Streaming)?(?:\s|$)' } |
            Select-Object -First 1
        if ($null -ne $match) {
            return $true
        }
    }
    return $false
}

function Get-SunshineVersion {
    if (-not (Test-Path -LiteralPath $SunshineExecutable -PathType Leaf)) {
        return $null
    }
    $rawVersion = (Get-Item -LiteralPath $SunshineExecutable).VersionInfo.ProductVersion
    if ($rawVersion -notmatch '^\s*v?(?<version>\d+(?:\.\d+){2,3})\s*$') {
        return $null
    }
    return [version]$Matches.version
}

function Get-SunshineService {
    $service = Get-CimInstance Win32_Service |
        Where-Object { $_.PathName -match '(?i)[\\/]Sunshine[\\/].*(?:sunshine|sunshinesvc)\.exe' } |
        Select-Object -First 1
    if ($null -eq $service) {
        return $null
    }
    return Get-Service -Name $service.Name
}

function Get-SunshineSetting {
    param([Parameter(Mandatory)][string]$Name)

    if (-not (Test-Path -LiteralPath $SunshineConfiguration -PathType Leaf)) {
        return $null
    }
    $matches = @(
        Get-Content -LiteralPath $SunshineConfiguration |
            Where-Object { $_ -match "^\s*$([regex]::Escape($Name))\s*=" }
    )
    if ($matches.Count -ne 1) {
        return $null
    }
    return (($matches[0] -split '=', 2)[1]).Trim()
}

function Set-SunshineSetting {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )

    $configurationDirectory = Split-Path -Parent $SunshineConfiguration
    $null = New-Item -ItemType Directory -Path $configurationDirectory -Force
    $lines = [Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $SunshineConfiguration) {
        foreach ($line in @(Get-Content -LiteralPath $SunshineConfiguration)) {
            $lines.Add($line)
        }
    }
    $pattern = "^\s*$([regex]::Escape($Name))\s*="
    $indexes = @()
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match $pattern) {
            $indexes += $index
        }
    }
    for ($index = $indexes.Count - 1; $index -ge 0; $index--) {
        $lines.RemoveAt($indexes[$index])
    }
    $lines.Add("$Name = $Value")
    $encoding = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllLines($SunshineConfiguration, [string[]]$lines, $encoding)
}

function Remove-RetiredSessionPolicy {
    Unregister-ScheduledTask `
        -TaskName $LegacySessionPolicyTaskName `
        -Confirm:$false `
        -ErrorAction SilentlyContinue
    Set-SunshineSetting -Name global_prep_cmd -Value '[]'
    Remove-Item -LiteralPath $LegacySessionPolicyRoot -Recurse -Force -ErrorAction SilentlyContinue
}

function Test-RetiredSessionPolicyAbsent {
    return (
        $null -eq (Get-ScheduledTask -TaskName $LegacySessionPolicyTaskName -ErrorAction SilentlyContinue) -and
        -not (Test-Path -LiteralPath $LegacySessionPolicyRoot) -and
        (Get-SunshineSetting -Name global_prep_cmd) -eq '[]'
    )
}

function Test-SunshineAlwaysAvailable {
    param([Parameter(Mandatory)][System.ServiceProcess.ServiceController]$SunshineService)

    $service = Get-CimInstance Win32_Service -Filter "Name='$($SunshineService.Name)'"
    return (
        $null -ne $service -and
        $service.StartMode -eq 'Auto' -and
        $SunshineService.Status -eq 'Running'
    )
}

function Get-SunshineInboundRules {
    $rules = [Collections.Generic.List[object]]::new()
    foreach ($rule in @(Get-NetFirewallRule -Direction Inbound -ErrorAction SilentlyContinue)) {
        $application = $rule | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue
        if (
            $rule.DisplayName -match '(?i)Sunshine' -or
            ($null -ne $application -and $application.Program -ieq $SunshineExecutable)
        ) {
            $rules.Add($rule)
        }
    }
    return @($rules)
}

function Set-SunshineFirewall {
    param([Parameter(Mandatory)][string]$RemoteAddress)

    foreach ($rule in @(Get-SunshineInboundRules)) {
        if ($rule.Name -notin @($ManagedTcpRule, $ManagedUdpRule) -and $rule.Enabled -eq 'True') {
            Disable-NetFirewallRule -Name $rule.Name
        }
    }
    Remove-NetFirewallRule -Name $ManagedTcpRule -ErrorAction SilentlyContinue
    Remove-NetFirewallRule -Name $ManagedUdpRule -ErrorAction SilentlyContinue

    $common = @{
        DisplayGroup = $ManagedFirewallGroup
        Direction = 'Inbound'
        Action = 'Allow'
        Enabled = 'True'
        Profile = 'Any'
        Program = $SunshineExecutable
        RemoteAddress = $RemoteAddress
        InterfaceAlias = $TunnelName
    }
    $null = New-NetFirewallRule `
        @common `
        -Name $ManagedTcpRule `
        -DisplayName 'Game stream host TCP from enrolled client' `
        -Protocol TCP `
        -LocalPort 47984, 47989, 48010
    $null = New-NetFirewallRule `
        @common `
        -Name $ManagedUdpRule `
        -DisplayName 'Game stream host UDP from enrolled client' `
        -Protocol UDP `
        -LocalPort 47998-48000, 48002, 48010
}

function Test-SunshineFirewall {
    param([Parameter(Mandatory)][string]$RemoteAddress)

    $expected = @{
        $ManagedTcpRule = @{ Protocol = 'TCP'; Ports = @('47984', '47989', '48010') }
        $ManagedUdpRule = @{ Protocol = 'UDP'; Ports = @('47998-48000', '48002', '48010') }
    }
    foreach ($name in $expected.Keys) {
        $rule = Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
        if ($null -eq $rule -or $rule.Enabled -ne 'True' -or $rule.Action -ne 'Allow') {
            return $false
        }
        $application = $rule | Get-NetFirewallApplicationFilter
        $address = $rule | Get-NetFirewallAddressFilter
        $interface = $rule | Get-NetFirewallInterfaceFilter
        $port = $rule | Get-NetFirewallPortFilter
        if (
            $application.Program -ine $SunshineExecutable -or
            @($address.RemoteAddress).Count -ne 1 -or
            @($address.RemoteAddress)[0] -ine $RemoteAddress -or
            @($interface.InterfaceAlias) -notcontains $TunnelName -or
            $port.Protocol -ine $expected[$name].Protocol -or
            (Compare-Object @($port.LocalPort | Sort-Object) @($expected[$name].Ports | Sort-Object))
        ) {
            return $false
        }
    }
    foreach ($rule in @(Get-SunshineInboundRules)) {
        if ($rule.Name -notin @($ManagedTcpRule, $ManagedUdpRule) -and $rule.Enabled -eq 'True') {
            return $false
        }
    }
    return $true
}

function Save-DesiredState {
    param(
        [AllowNull()][string]$SourceCommit,
        [Parameter(Mandatory)][string]$SourceDigest
    )

    Initialize-StateRoot
    [ordered]@{
        role = $Role.ToLowerInvariant()
        sessionModel = if ($Role -eq 'Host') { 'trusted-shared-console' } else { 'not-applicable' }
        sourceCommit = $SourceCommit
        sourceDigest = $SourceDigest
    } | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

function Get-DesiredState {
    if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) {
        return $null
    }
    return Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
}

function Test-StateAcl {
    if (-not (Test-Path -LiteralPath $StateRoot -PathType Container)) {
        return $false
    }
    $acl = Get-Acl -LiteralPath $StateRoot
    if (-not $acl.AreAccessRulesProtected) {
        return $false
    }

    $allowedSids = @('S-1-5-18', 'S-1-5-32-544')
    $rules = $acl.GetAccessRules(
        $true,
        $false,
        [Security.Principal.SecurityIdentifier]
    )
    foreach ($rule in $rules) {
        if (
            $rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            $rule.IdentityReference.Value -notin $allowedSids
        ) {
            return $false
        }
    }
    foreach ($sid in $allowedSids) {
        $fullControl = @($rules | Where-Object {
            $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            $_.IdentityReference.Value -eq $sid -and
            ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq
                [Security.AccessControl.FileSystemRights]::FullControl
        })
        if ($fullControl.Count -eq 0) {
            return $false
        }
    }
    return $true
}

function Write-ComplianceResult {
    param(
        [Parameter(Mandatory)][ValidateSet('compliant', 'drifted', 'manual ceremony required', 'environmental warning')]
        [string]$Status,
        [Parameter(Mandatory)][string[]]$Findings,
        [AllowNull()][string]$SourceCommit
    )

    [ordered]@{
        role = "game-stream-$($Role.ToLowerInvariant())"
        status = $Status
        findings = $Findings
        sourceCommit = $SourceCommit
    } | ConvertTo-Json -Compress

    switch ($Status) {
        'compliant' { exit 0 }
        'drifted' { exit 10 }
        'manual ceremony required' { exit 20 }
        'environmental warning' { exit 30 }
    }
}

function Test-Configuration {
    $manual = [Collections.Generic.List[string]]::new()
    $drift = [Collections.Generic.List[string]]::new()
    $warnings = [Collections.Generic.List[string]]::new()
    $state = Get-DesiredState
    $stateProperties = if ($null -ne $state) { @($state.PSObject.Properties.Name) } else { @() }
    $sourceCommit = if ($stateProperties -contains 'sourceCommit') { $state.sourceCommit } else { $null }
    $expectedSourceDigest = [Environment]::GetEnvironmentVariable('CAZ_GAME_STREAM_SOURCE_DIGEST')
    $expectedSessionModel = if ($Role -eq 'Host') { 'trusted-shared-console' } else { 'not-applicable' }

    $wireGuard = Get-WireGuardCommand
    $wg = Get-WgCommand
    if ($null -eq $wireGuard -or $null -eq $wg) {
        $drift.Add('official WireGuard package is absent')
    }
    if ($Role -eq 'Client' -and -not (Test-MoonlightInstalled)) {
        $drift.Add('Moonlight package is absent')
    }
    if (-not (Test-Path -LiteralPath $DpapiConfiguration -PathType Leaf)) {
        $manual.Add('DPAPI-backed tunnel enrollment is required')
    }
    if (Test-Path -LiteralPath $PlaintextConfiguration -PathType Leaf) {
        $drift.Add('plaintext WireGuard configuration remains in the managed configuration directory')
    }
    if ($null -eq (Get-Service -Name $TunnelServiceName -ErrorAction SilentlyContinue)) {
        $manual.Add('WireGuard tunnel service enrollment is required')
    }
    elseif ($null -ne $wg) {
        if ($null -eq (Get-TunnelPeerRoute -Wg $wg)) {
            $drift.Add('tunnel route is not one exact opposite-role IPv4 /32')
        }
        if (-not (Test-TunnelKeepalive -Wg $wg)) {
            $drift.Add('tunnel keepalive differs from 25 seconds')
        }
        if (-not (Test-TunnelHandshakeHealthy -Wg $wg)) {
            $warnings.Add('gateway handshake is absent or stale')
        }
    }
    $dangerousScripts = Get-ItemPropertyValue `
        -LiteralPath 'HKLM:\Software\WireGuard' `
        -Name DangerousScriptExecution `
        -ErrorAction SilentlyContinue
    if ($dangerousScripts -eq 1) {
        $drift.Add('WireGuard Local System hook execution is enabled')
    }
    if ($null -eq $state) {
        $manual.Add('a declarative role apply is required')
    }
    elseif (
        $stateProperties -notcontains 'role' -or
        $stateProperties -notcontains 'sessionModel' -or
        $stateProperties -notcontains 'sourceCommit' -or
        $stateProperties -notcontains 'sourceDigest' -or
        $state.role -ne $Role.ToLowerInvariant() -or
        $state.sessionModel -ne $expectedSessionModel -or
        $state.sourceCommit -notmatch '^[0-9a-f]{40}$' -or
        $state.sourceDigest -notmatch '^[0-9a-f]{64}$'
    ) {
        $drift.Add('stored desired-state metadata is invalid or belongs to another role')
    }
    elseif (
        $expectedSourceDigest -notmatch '^[0-9a-f]{64}$' -or
        $state.sourceDigest -ne $expectedSourceDigest
    ) {
        $drift.Add('staged game-stream source bytes differ from the applied source digest')
    }
    elseif (-not (Test-StateAcl)) {
        $drift.Add('administrator-only desired-state ACL differs')
    }

    if ($Role -eq 'Host') {
        $sunshineVersion = Get-SunshineVersion
        if ($null -eq $sunshineVersion -or $sunshineVersion -lt $MinimumSunshineVersion) {
            $drift.Add('Sunshine is absent, prerelease, or below the security floor')
        }
        if (-not (Test-Path -LiteralPath $SunshineState -PathType Leaf)) {
            $manual.Add('Sunshine local credential creation and Moonlight pairing are required')
        }
        if (
            (Get-SunshineSetting -Name upnp) -ne 'disabled' -or
            (Get-SunshineSetting -Name origin_web_ui_allowed) -ne 'pc' -or
            (Get-SunshineSetting -Name address_family) -ne 'ipv4'
        ) {
            $drift.Add('Sunshine security-critical network settings differ')
        }
        if ($null -ne $wg) {
            $peerRoute = Get-TunnelPeerRoute -Wg $wg
            if ($null -ne $peerRoute -and -not (Test-SunshineFirewall -RemoteAddress $peerRoute)) {
                $drift.Add('Sunshine firewall rules are broad or differ from the enrolled client route')
            }
        }
        $sunshineService = Get-SunshineService
        if ($null -eq $sunshineService) {
            $drift.Add('Sunshine service is absent')
        }
        elseif (-not (Test-SunshineAlwaysAvailable -SunshineService $sunshineService)) {
            $drift.Add('Sunshine is not configured as an always-running automatic service')
        }
        if (-not (Test-RetiredSessionPolicyAbsent)) {
            $drift.Add('retired session-control machinery remains installed')
        }
        $warnings.Add('headless display, power, reboot, Windows login, and shared-console behavior still require pilot evidence')
    }

    if ($drift.Count -gt 0) {
        Write-ComplianceResult -Status drifted -Findings @($drift) -SourceCommit $sourceCommit
    }
    if ($manual.Count -gt 0) {
        Write-ComplianceResult -Status 'manual ceremony required' -Findings @($manual) -SourceCommit $sourceCommit
    }
    if ($warnings.Count -gt 0) {
        Write-ComplianceResult -Status 'environmental warning' -Findings @($warnings) -SourceCommit $sourceCommit
    }
    Write-ComplianceResult -Status compliant -Findings @('security-critical declarative state matches') -SourceCommit $sourceCommit
}

if ($Check) {
    Test-Configuration
}

if (-not (Test-IsAdministrator)) {
    throw 'The game-stream role resource must run with administrator elevation.'
}

$wireGuard = Get-WireGuardCommand
if ($null -eq $wireGuard) {
    throw 'The official WireGuard package must be installed before applying this role.'
}
$enrollmentFile = [Environment]::GetEnvironmentVariable('CAZ_GAME_STREAM_ENROLLMENT_FILE')
if (-not [string]::IsNullOrWhiteSpace($enrollmentFile)) {
    try {
        Import-WireGuardEnrollment -WireGuard $wireGuard -EnrollmentFile $enrollmentFile
    }
    finally {
        Remove-Item -LiteralPath $enrollmentFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $PlaintextConfiguration -Force -ErrorAction SilentlyContinue
    }
}
if (-not (Test-Path -LiteralPath $DpapiConfiguration -PathType Leaf)) {
    throw 'Manual ceremony required: provide the one-time local WireGuard enrollment file.'
}
Start-DpapiTunnelService -WireGuard $wireGuard

$null = New-Item -ItemType Directory -Path 'HKLM:\Software\WireGuard' -Force
Remove-ItemProperty `
    -LiteralPath 'HKLM:\Software\WireGuard' `
    -Name DangerousScriptExecution `
    -ErrorAction SilentlyContinue

$wg = Get-WgCommand
if ($null -eq $wg) {
    throw 'WireGuard wg.exe is unavailable after package installation.'
}
$peerRoute = Get-TunnelPeerRoute -Wg $wg
if ($null -eq $peerRoute -or -not (Test-TunnelKeepalive -Wg $wg)) {
    throw 'The active tunnel must contain one opposite-role /32 and PersistentKeepalive = 25.'
}

$sourceCommit = [Environment]::GetEnvironmentVariable('CAZ_GAME_STREAM_SOURCE_COMMIT')
if ($sourceCommit -notmatch '^[0-9a-fA-F]{40}$') {
    throw 'The reviewed source commit is missing or invalid.'
}
$sourceCommit = $sourceCommit.ToLowerInvariant()
$sourceDigest = [Environment]::GetEnvironmentVariable('CAZ_GAME_STREAM_SOURCE_DIGEST')
if ($sourceDigest -notmatch '^[0-9a-fA-F]{64}$') {
    throw 'The staged game-stream source digest is missing or invalid.'
}
$sourceDigest = $sourceDigest.ToLowerInvariant()

if ($Role -eq 'Host') {
    $sunshineVersion = Get-SunshineVersion
    if ($null -eq $sunshineVersion -or $sunshineVersion -lt $MinimumSunshineVersion) {
        throw "Sunshine $MinimumSunshineVersion or later stable is required."
    }
    Set-SunshineSetting -Name upnp -Value disabled
    Set-SunshineSetting -Name origin_web_ui_allowed -Value pc
    Set-SunshineSetting -Name address_family -Value ipv4
    Set-SunshineFirewall -RemoteAddress $peerRoute

    $sunshineService = Get-SunshineService
    if ($null -eq $sunshineService) {
        throw 'Sunshine is installed, but its Windows service is unavailable.'
    }
    Remove-RetiredSessionPolicy
    Set-Service -Name $sunshineService.Name -StartupType Automatic
    if ((Get-Service -Name $sunshineService.Name).Status -ne 'Running') {
        Start-Service -Name $sunshineService.Name
    }
    $sunshineService = Get-Service -Name $sunshineService.Name
    if (-not (Test-SunshineAlwaysAvailable -SunshineService $sunshineService)) {
        throw 'Sunshine could not be configured as an always-running automatic service.'
    }
}

Save-DesiredState `
    -SourceCommit $sourceCommit `
    -SourceDigest $sourceDigest

Write-Host "Applied declarative game-stream-$($Role.ToLowerInvariant()) security state."
