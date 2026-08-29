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
$SessionPolicyTaskName = 'caz.nix game-stream session arbiter'
$StateRoot = Join-Path $env:ProgramData "caz.nix\game-stream-$($Role.ToLowerInvariant())"
$StateFile = Join-Path $StateRoot 'desired-state.json'
$SessionPolicyRoot = Join-Path $env:ProgramFiles 'caz.nix\game-stream-host'
$SessionPolicySource = Join-Path $PSScriptRoot 'windows-game-stream-session.ps1'
$SessionPolicyScript = Join-Path $SessionPolicyRoot 'windows-game-stream-session.ps1'
$WireGuardConfigurationRoot = Join-Path $env:ProgramFiles 'WireGuard\Data\Configurations'
$DpapiConfiguration = Join-Path $WireGuardConfigurationRoot "$TunnelName.conf.dpapi"
$PlaintextConfiguration = Join-Path $WireGuardConfigurationRoot "$TunnelName.conf"
$SunshineRoot = Join-Path $env:ProgramFiles 'Sunshine'
$SunshineExecutable = Join-Path $SunshineRoot 'sunshine.exe'
$SunshineConfiguration = Join-Path $SunshineRoot 'config\sunshine.conf'
$SunshineApplications = Join-Path $SunshineRoot 'config\apps.json'
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

function Get-RemoteAccountSid {
    param([Parameter(Mandatory)][string]$AccountName)

    $account = Get-LocalUser -Name $AccountName -ErrorAction SilentlyContinue
    if ($null -eq $account -or -not $account.Enabled) {
        throw 'The dedicated remote-play account must already exist and be enabled.'
    }
    if (-not (Test-RemoteAccountSidIsStandard -Sid $account.SID.Value)) {
        throw 'The dedicated remote-play account must be enabled and belong only to the built-in Users group.'
    }
    return $account.SID.Value
}

function Test-RemoteAccountSidIsStandard {
    param([Parameter(Mandatory)][string]$Sid)

    try {
        $securityIdentifier = [Security.Principal.SecurityIdentifier]::new($Sid)
        $account = Get-LocalUser -SID $securityIdentifier -ErrorAction Stop
        if (-not $account.Enabled) {
            return $false
        }
        $memberOf = [Collections.Generic.List[string]]::new()
        foreach ($group in @(Get-LocalGroup -ErrorAction Stop)) {
            $isMember = @(
                Get-LocalGroupMember -SID $group.SID -ErrorAction SilentlyContinue |
                    Where-Object { $_.SID.Value -eq $account.SID.Value }
            ).Count -gt 0
            if ($isMember) {
                $memberOf.Add($group.SID.Value)
            }
        }
        return $memberOf.Count -eq 1 -and $memberOf[0] -eq 'S-1-5-32-545'
    }
    catch {
        return $false
    }
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

function Get-SessionPolicyArguments {
    param(
        [Parameter(Mandatory)][ValidateSet('Gate', 'Reconcile')][string]$Mode,
        [Parameter(Mandatory)][string]$RemoteAccountSid,
        [Parameter(Mandatory)][string]$SunshineServiceName
    )

    return '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Mode {1} -RemoteAccountSid {2} -SunshineServiceName "{3}"' -f `
        $SessionPolicyScript, $Mode, $RemoteAccountSid, $SunshineServiceName
}

function Get-SunshineSessionPrepValue {
    param(
        [Parameter(Mandatory)][string]$RemoteAccountSid,
        [Parameter(Mandatory)][string]$SunshineServiceName
    )

    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = Get-SessionPolicyArguments `
        -Mode Gate `
        -RemoteAccountSid $RemoteAccountSid `
        -SunshineServiceName $SunshineServiceName
    $gate = [ordered]@{
        do = '"{0}" {1}' -f $powerShell, $arguments
        elevated = $false
    }
    return ConvertTo-Json -InputObject @($gate) -Compress
}

function Set-SessionPolicyAcl {
    $null = & (Join-Path $env:SystemRoot 'System32\icacls.exe') `
        $SessionPolicyRoot `
        '/inheritance:r' `
        '/grant:r' `
        '*S-1-5-18:(OI)(CI)F' `
        '*S-1-5-32-544:(OI)(CI)F' `
        '*S-1-5-32-545:(OI)(CI)RX'
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not restrict the session arbiter to administrator writes and standard-user execution.'
    }
}

function Test-SessionPolicyAcl {
    if (-not (Test-Path -LiteralPath $SessionPolicyRoot -PathType Container)) {
        return $false
    }
    $acl = Get-Acl -LiteralPath $SessionPolicyRoot
    if (-not $acl.AreAccessRulesProtected) {
        return $false
    }
    $rules = $acl.GetAccessRules(
        $true,
        $false,
        [Security.Principal.SecurityIdentifier]
    )
    $allowedSids = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-32-545')
    foreach ($rule in $rules) {
        if (
            $rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            $rule.IdentityReference.Value -notin $allowedSids
        ) {
            return $false
        }
    }
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        if (@($rules | Where-Object {
            $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            $_.IdentityReference.Value -eq $sid -and
            ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq
                [Security.AccessControl.FileSystemRights]::FullControl
        }).Count -eq 0) {
            return $false
        }
    }
    $usersRule = @($rules | Where-Object {
        $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
        $_.IdentityReference.Value -eq 'S-1-5-32-545'
    })
    $writeRights = (
        [Security.AccessControl.FileSystemRights]::WriteData -bor
        [Security.AccessControl.FileSystemRights]::AppendData -bor
        [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
        [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership
    )
    return (
        $usersRule.Count -gt 0 -and
        @($usersRule | Where-Object {
            ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::ReadAndExecute) -eq
                [Security.AccessControl.FileSystemRights]::ReadAndExecute -and
            ($_.FileSystemRights -band $writeRights) -eq 0
        }).Count -eq $usersRule.Count
    )
}

function Register-SessionPolicyTask {
    param(
        [Parameter(Mandatory)][string]$RemoteAccountSid,
        [Parameter(Mandatory)][string]$SunshineServiceName
    )

    $taskService = New-Object -ComObject 'Schedule.Service'
    $taskService.Connect()
    $rootFolder = $taskService.GetFolder('\')
    $definition = $taskService.NewTask(0)
    $definition.RegistrationInfo.Description = 'Fail-closed Sunshine availability based on the active Windows console session.'
    $definition.Principal.UserId = 'SYSTEM'
    $definition.Principal.LogonType = 5
    $definition.Principal.RunLevel = 1
    $definition.Settings.Enabled = $true
    $definition.Settings.Hidden = $true
    $definition.Settings.StartWhenAvailable = $true
    $definition.Settings.DisallowStartIfOnBatteries = $false
    $definition.Settings.StopIfGoingOnBatteries = $false
    $definition.Settings.ExecutionTimeLimit = 'PT1M'
    $definition.Settings.MultipleInstances = 2

    $null = $definition.Triggers.Create(8)
    $null = $definition.Triggers.Create(9)
    foreach ($stateChange in @(1, 2, 7, 8)) {
        $trigger = $definition.Triggers.Create(11)
        $trigger.StateChange = $stateChange
    }

    $action = $definition.Actions.Create(0)
    $action.Path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action.Arguments = Get-SessionPolicyArguments `
        -Mode Reconcile `
        -RemoteAccountSid $RemoteAccountSid `
        -SunshineServiceName $SunshineServiceName
    $null = $rootFolder.RegisterTaskDefinition(
        $SessionPolicyTaskName,
        $definition,
        6,
        'SYSTEM',
        $null,
        5,
        $null
    )
}

function Test-NoSunshinePrepExclusions {
    if (-not (Test-Path -LiteralPath $SunshineApplications -PathType Leaf)) {
        return $true
    }
    try {
        $applications = Get-Content -LiteralPath $SunshineApplications -Raw | ConvertFrom-Json
        foreach ($application in @($applications.apps)) {
            if ($application.'exclude-global-prep-cmd' -eq $true) {
                return $false
            }
        }
        return $true
    }
    catch {
        return $false
    }
}

function Enable-SessionPolicy {
    param(
        [Parameter(Mandatory)][string]$RemoteAccountSid,
        [Parameter(Mandatory)][System.ServiceProcess.ServiceController]$SunshineService
    )

    Stop-Service -Name $SunshineService.Name -Force -ErrorAction SilentlyContinue
    Set-Service -Name $SunshineService.Name -StartupType Disabled
    if (-not (Test-NoSunshinePrepExclusions)) {
        throw 'Every Sunshine application must inherit the global remote-play session gate.'
    }
    if (-not (Test-Path -LiteralPath $SessionPolicySource -PathType Leaf)) {
        throw 'The staged game-stream session arbiter is unavailable.'
    }
    $null = New-Item -ItemType Directory -Path $SessionPolicyRoot -Force
    Copy-Item -LiteralPath $SessionPolicySource -Destination $SessionPolicyScript -Force
    Set-SessionPolicyAcl
    Set-SunshineSetting `
        -Name global_prep_cmd `
        -Value (Get-SunshineSessionPrepValue `
            -RemoteAccountSid $RemoteAccountSid `
            -SunshineServiceName $SunshineService.Name)
    Register-SessionPolicyTask `
        -RemoteAccountSid $RemoteAccountSid `
        -SunshineServiceName $SunshineService.Name
    Set-Service -Name $SunshineService.Name -StartupType Automatic
    & $SessionPolicyScript `
        -Mode Reconcile `
        -RemoteAccountSid $RemoteAccountSid `
        -SunshineServiceName $SunshineService.Name
}

function Disable-SessionPolicy {
    param([Parameter(Mandatory)][System.ServiceProcess.ServiceController]$SunshineService)

    Unregister-ScheduledTask -TaskName $SessionPolicyTaskName -Confirm:$false -ErrorAction SilentlyContinue
    Set-SunshineSetting -Name global_prep_cmd -Value '[]'
    Stop-Service -Name $SunshineService.Name -Force -ErrorAction SilentlyContinue
    Set-Service -Name $SunshineService.Name -StartupType Disabled
    Remove-Item -LiteralPath $SessionPolicyRoot -Recurse -Force -ErrorAction SilentlyContinue
}

function Test-SessionPolicy {
    param(
        [Parameter(Mandatory)][string]$RemoteAccountSid,
        [Parameter(Mandatory)][System.ServiceProcess.ServiceController]$SunshineService
    )

    if (
        -not (Test-Path -LiteralPath $SessionPolicySource -PathType Leaf) -or
        -not (Test-Path -LiteralPath $SessionPolicyScript -PathType Leaf) -or
        -not (Test-SessionPolicyAcl) -or
        (Get-FileHash -LiteralPath $SessionPolicySource -Algorithm SHA256).Hash -ne
            (Get-FileHash -LiteralPath $SessionPolicyScript -Algorithm SHA256).Hash
    ) {
        return $false
    }
    if (
        (Get-SunshineSetting -Name global_prep_cmd) -ne
            (Get-SunshineSessionPrepValue `
                -RemoteAccountSid $RemoteAccountSid `
                -SunshineServiceName $SunshineService.Name) -or
        -not (Test-NoSunshinePrepExclusions)
    ) {
        return $false
    }

    $service = Get-CimInstance Win32_Service -Filter "Name='$($SunshineService.Name)'"
    if ($null -eq $service -or $service.StartMode -ne 'Auto') {
        return $false
    }

    try {
        $taskService = New-Object -ComObject 'Schedule.Service'
        $taskService.Connect()
        $taskXml = $taskService.GetFolder('\').GetTask($SessionPolicyTaskName).Xml
        $requiredFragments = @(
            '<BootTrigger',
            '<LogonTrigger',
            '<StateChange>ConsoleConnect</StateChange>',
            '<StateChange>ConsoleDisconnect</StateChange>',
            '<StateChange>SessionLock</StateChange>',
            '<StateChange>SessionUnlock</StateChange>',
            [Security.SecurityElement]::Escape($SessionPolicyScript),
            $RemoteAccountSid,
            [Security.SecurityElement]::Escape($SunshineService.Name)
        )
        foreach ($fragment in $requiredFragments) {
            if (-not $taskXml.Contains($fragment)) {
                return $false
            }
        }
    }
    catch {
        return $false
    }
    return $true
}

function Test-SessionPolicyDisabled {
    param([Parameter(Mandatory)][System.ServiceProcess.ServiceController]$SunshineService)

    $service = Get-CimInstance Win32_Service -Filter "Name='$($SunshineService.Name)'"
    if (
        $null -eq $service -or
        $service.StartMode -ne 'Disabled' -or
        $SunshineService.Status -ne 'Stopped' -or
        (Get-SunshineSetting -Name global_prep_cmd) -ne '[]' -or
        (Test-Path -LiteralPath $SessionPolicyRoot)
    ) {
        return $false
    }
    return $null -eq (Get-ScheduledTask -TaskName $SessionPolicyTaskName -ErrorAction SilentlyContinue)
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
        [Parameter(Mandatory)][string]$RemotePlay,
        [AllowNull()][string]$RemoteAccountSid,
        [AllowNull()][string]$SourceCommit
    )

    Initialize-StateRoot
    [ordered]@{
        role = $Role.ToLowerInvariant()
        remotePlay = $RemotePlay
        remoteAccountSid = $RemoteAccountSid
        sourceCommit = $SourceCommit
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
    $sourceCommit = if ($null -ne $state) { $state.sourceCommit } else { $null }

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
        $state.role -ne $Role.ToLowerInvariant() -or
        $state.remotePlay -notin @('Enabled', 'Disabled') -or
        $state.sourceCommit -notmatch '^[0-9a-f]{40}$'
    ) {
        $drift.Add('stored desired-state metadata is invalid or belongs to another role')
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
        if ($null -ne $state -and $null -ne $wg) {
            $peerRoute = Get-TunnelPeerRoute -Wg $wg
            if ($null -ne $peerRoute -and -not (Test-SunshineFirewall -RemoteAddress $peerRoute)) {
                $drift.Add('Sunshine firewall rules are broad or differ from the enrolled client route')
            }
            if (
                [string]::IsNullOrWhiteSpace($state.remoteAccountSid) -or
                -not (Test-RemoteAccountSidIsStandard -Sid $state.remoteAccountSid)
            ) {
                $manual.Add('dedicated standard remote-play account selection is required')
            }
        }
        $sunshineService = Get-SunshineService
        if ($null -eq $sunshineService) {
            $drift.Add('Sunshine service is absent')
        }
        elseif (
            $null -ne $state -and
            -not [string]::IsNullOrWhiteSpace($state.remoteAccountSid)
        ) {
            if (
                $state.remotePlay -eq 'Enabled' -and
                -not (Test-SessionPolicy `
                    -RemoteAccountSid $state.remoteAccountSid `
                    -SunshineService $sunshineService)
            ) {
                $drift.Add('Sunshine unattended session arbitration differs')
            }
            if (
                $state.remotePlay -eq 'Disabled' -and
                -not (Test-SessionPolicyDisabled -SunshineService $sunshineService)
            ) {
                $drift.Add('Sunshine is not fail-closed while remote play is disabled')
            }
        }
        $warnings.Add('headless display, power, lock-screen capture, and session-switch disconnect behavior still require pilot evidence')
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

$remotePlay = [Environment]::GetEnvironmentVariable('CAZ_GAME_STREAM_REMOTE_PLAY')
if ($remotePlay -notin @('Enabled', 'Disabled')) {
    $remotePlay = 'Disabled'
}
$sourceCommit = [Environment]::GetEnvironmentVariable('CAZ_GAME_STREAM_SOURCE_COMMIT')
if ($sourceCommit -notmatch '^[0-9a-fA-F]{40}$') {
    throw 'The reviewed source commit is missing or invalid.'
}
$sourceCommit = $sourceCommit.ToLowerInvariant()
$remoteAccountSid = $null

if ($Role -eq 'Host') {
    $sunshineVersion = Get-SunshineVersion
    if ($null -eq $sunshineVersion -or $sunshineVersion -lt $MinimumSunshineVersion) {
        throw "Sunshine $MinimumSunshineVersion or later stable is required."
    }
    $remoteAccount = [Environment]::GetEnvironmentVariable('CAZ_GAME_STREAM_REMOTE_ACCOUNT')
    if ([string]::IsNullOrWhiteSpace($remoteAccount)) {
        throw 'Manual ceremony required: select the existing dedicated standard remote-play account.'
    }
    $remoteAccountSid = Get-RemoteAccountSid -AccountName $remoteAccount

    Set-SunshineSetting -Name upnp -Value disabled
    Set-SunshineSetting -Name origin_web_ui_allowed -Value pc
    Set-SunshineSetting -Name address_family -Value ipv4
    Set-SunshineFirewall -RemoteAddress $peerRoute

    $sunshineService = Get-SunshineService
    if ($null -eq $sunshineService) {
        throw 'Sunshine is installed, but its Windows service is unavailable.'
    }
    if ($remotePlay -eq 'Enabled') {
        Enable-SessionPolicy `
            -RemoteAccountSid $remoteAccountSid `
            -SunshineService $sunshineService
    }
    else {
        Disable-SessionPolicy -SunshineService $sunshineService
    }
}

Save-DesiredState `
    -RemotePlay $remotePlay `
    -RemoteAccountSid $remoteAccountSid `
    -SourceCommit $sourceCommit

Write-Host "Applied declarative game-stream-$($Role.ToLowerInvariant()) security state."
