#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Host', 'Client')]
    [string]$Role,

    [switch]$Check,

    [string]$ResultPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SunshineExecutable = Join-Path $env:ProgramFiles 'Sunshine\sunshine.exe'
$SunshineConfiguration = Join-Path $env:ProgramFiles 'Sunshine\config\sunshine.conf'
$SunshineLog = Join-Path $env:ProgramFiles 'Sunshine\config\sunshine.log'
$HostDisplaySettings = @{
    dd_configuration_option = 'ensure_primary'
    dd_resolution_option = 'auto'
    dd_refresh_rate_option = 'auto'
    dd_config_revert_on_disconnect = 'enabled'
}
$MoonlightExecutable = Join-Path $env:ProgramFiles 'Moonlight Game Streaming\Moonlight.exe'
$WireGuardExecutable = Join-Path $env:ProgramFiles 'WireGuard\wireguard.exe'
$LegacyTunnelService = 'WireGuardTunnel$game-stream'
$ManagedHostFirewallGroup = 'caz.nix game-stream host'
$ManagedHostTcpRule = 'caz.nix-game-stream-host-lan-tcp'
$ManagedHostUdpRule = 'caz.nix-game-stream-host-lan-udp'
$RetiredFirewallRules = @(
    'caz.nix-game-stream-host-tunnel-tcp',
    'caz.nix-game-stream-host-tunnel-udp',
    'caz.nix-game-stream-client-lan',
    'caz.nix-game-stream-client-tunnel'
)
$LegacySessionPolicyRoot = Join-Path $env:ProgramFiles 'caz.nix\game-stream-host'
$LegacySessionPolicyTaskName = 'caz.nix game-stream session arbiter'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-CurrentUserCanSelfElevate {
    $whoAmI = Join-Path $env:SystemRoot 'System32\whoami.exe'
    $groups = @(& $whoAmI /groups /fo csv /nh 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not inspect the current Windows security groups.'
    }
    return @($groups | Where-Object { $_ -match 'S-1-5-32-544' }).Count -gt 0
}

function Get-WinGetCommand {
    $command = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $command -and (Test-Path -LiteralPath $command.Source)) {
        return $command.Source
    }

    $appInstaller = Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if ($null -ne $appInstaller) {
        $candidate = Join-Path $appInstaller.InstallLocation 'winget.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    return $null
}

function Install-PackageIfMissing {
    param(
        [Parameter(Mandatory)][string]$WinGet,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$ExpectedExecutable
    )

    if (Test-Path -LiteralPath $ExpectedExecutable -PathType Leaf) {
        Write-Host "Package is present: $Id"
        return
    }

    Write-Host "Installing package: $Id"
    & $WinGet install `
        --id $Id `
        --exact `
        --source winget `
        --silent `
        --accept-package-agreements `
        --accept-source-agreements `
        --disable-interactivity
    if ($LASTEXITCODE -ne 0) {
        throw "WinGet failed to install $Id (exit $LASTEXITCODE)."
    }
    if (-not (Test-Path -LiteralPath $ExpectedExecutable -PathType Leaf)) {
        throw "WinGet reported success, but the expected executable for $Id is absent."
    }
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

function Get-VirtualDisplayDevice {
    # Device instance numbers and friendly names can change after reinstalling.
    # Match the driver's hardware ID instead, without including absent devices.
    foreach ($device in @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction SilentlyContinue)) {
        $hardwareIds = Get-PnpDeviceProperty `
            -InstanceId $device.InstanceId `
            -KeyName DEVPKEY_Device_HardwareIds `
            -ErrorAction SilentlyContinue
        if ($null -ne $hardwareIds -and @($hardwareIds.Data) -contains 'Root\MttVDD') {
            $device
        }
    }
}

function Get-VirtualDisplayIdFromLog {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [DateTime]$Since = [DateTime]::MinValue
    )

    # Sunshine documents these device_id values as the Windows output_name.
    # Only inspect the newest enumeration; a previous boot may describe a
    # removed display. Never fall back to the TV or a numbered DISPLAY name.
    $marker = 'Currently available display devices:'
    $offset = $Content.LastIndexOf($marker, [StringComparison]::Ordinal)
    if ($offset -lt 0) {
        throw 'Sunshine has not logged its display devices yet.'
    }
    if ($Since -ne [DateTime]::MinValue) {
        $lineStart = $Content.LastIndexOf("`n", $offset) + 1
        $heading = $Content.Substring($lineStart, $offset - $lineStart)
        $timestamp = [regex]::Match($heading, '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)?)\]')
        if (-not $timestamp.Success -or [DateTime]::Parse(
            $timestamp.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture
        ) -lt $Since) {
            throw 'Waiting for a fresh Sunshine display enumeration.'
        }
    }
    $remaining = $Content.Substring($offset + $marker.Length).TrimStart()
    $json = [regex]::Match($remaining, '(?s)^\[(?:\s*\]|.*?\r?\n\])')
    if (-not $json.Success) {
        throw 'The latest Sunshine display enumeration is incomplete or unavailable.'
    }
    $displays = ConvertFrom-Json -InputObject $json.Value
    $virtualDisplays = @($displays | Where-Object {
        $_.friendly_name -in @('VDD by MTT', 'MTT', 'IDD HDR', 'Virtual Display Driver')
    })
    if ($virtualDisplays.Count -ne 1) {
        throw "Expected one Virtual Display Driver monitor in Sunshine; found $($virtualDisplays.Count). Check the display list in Sunshine Troubleshooting."
    }
    $identifier = [string]$virtualDisplays[0].device_id
    if ($identifier -notmatch '^\{[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\}$') {
        throw 'Sunshine did not report a valid Windows device_id for the virtual monitor.'
    }
    return $identifier
}

function Get-VirtualDisplayConfiguration {
    $directory = Get-ItemPropertyValue `
        -LiteralPath 'HKLM:\SOFTWARE\MikeTheTech\VirtualDisplayDriver' `
        -Name VDDPATH -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($directory)) {
        $directory = Join-Path $env:SystemDrive 'VirtualDisplayDriver'
    }
    return Join-Path $directory 'vdd_settings.xml'
}

function Wait-SunshineVirtualDisplay {
    param([Parameter(Mandatory)][DateTime]$Since)

    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        try {
            return Get-VirtualDisplayIdFromLog -Since $Since -Content (
                Get-Content -LiteralPath $SunshineLog -Raw
            )
        }
        catch {
            $displayError = $_.Exception.Message
            Start-Sleep -Milliseconds 500
        }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Could not select the virtual display: $displayError"
}

function Add-VirtualDisplayModes {
    param([Parameter(Mandatory)][xml]$Configuration)

    $resolutions = $Configuration.SelectSingleNode('/vdd_settings/resolutions')
    if ($null -eq $resolutions) {
        throw 'The virtual display configuration has no resolutions section.'
    }
    $changed = $false
    # Include both laptop aspect ratios and the low-bandwidth diagnostic mode.
    foreach ($size in @('1280x720', '1280x800', '1920x1080', '1920x1200', '2560x1440', '2560x1600')) {
        $width, $height = $size -split 'x'
        $resolution = $Configuration.SelectSingleNode(
            "/vdd_settings/resolutions/resolution[width='$width' and height='$height']"
        )
        if ($null -eq $resolution) {
            $resolution = $Configuration.CreateElement('resolution')
            foreach ($field in @{ width = $width; height = $height }.GetEnumerator()) {
                $element = $Configuration.CreateElement($field.Key)
                $element.InnerText = $field.Value
                $null = $resolution.AppendChild($element)
            }
            $null = $resolutions.AppendChild($resolution)
            $changed = $true
        }
        foreach ($rate in @('30', '60')) {
            $globalRate = $Configuration.SelectSingleNode("/vdd_settings/global/g_refresh_rate[text()='$rate']")
            if ($null -eq $globalRate -and $null -eq $resolution.SelectSingleNode("refresh_rate[text()='$rate']")) {
                $element = $Configuration.CreateElement('refresh_rate')
                $element.InnerText = $rate
                $null = $resolution.AppendChild($element)
                $changed = $true
            }
        }
    }
    return $changed
}

function Set-VirtualDisplayModes {
    $path = Get-VirtualDisplayConfiguration
    $configuration = [xml]::new()
    $configuration.XmlResolver = $null
    $configuration.Load($path)
    if (Add-VirtualDisplayModes -Configuration $configuration) {
        if (-not (Test-Path -LiteralPath "$path.before-headless")) {
            Copy-Item -LiteralPath $path -Destination "$path.before-headless"
        }
        $configuration.Save($path)
        $device = @(Get-VirtualDisplayDevice)[0]
        & "$env:SystemRoot\System32\pnputil.exe" /restart-device $device.InstanceId
        if ($LASTEXITCODE -ne 0) {
            throw 'Virtual display modes were saved, but the driver needs a Windows restart before continuing.'
        }
    }
}

function Assert-VirtualDisplayReady {
    $devices = @(Get-VirtualDisplayDevice)
    if ($devices.Count -ne 1 -or $devices[0].Status -ne 'OK') {
        throw @'
Install and enable one VirtualDrivers display adapter before applying the host baseline.
Run: winget install --id VirtualDrivers.Virtual-Display-Driver --exact --source winget
Open VDD Control and install the display driver, then rerun this command.
WinGet installs the control app; a successful package install alone is not a working driver.
'@
    }
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

    $directory = Split-Path -Parent $SunshineConfiguration
    $null = New-Item -ItemType Directory -Path $directory -Force
    $lines = [Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $SunshineConfiguration -PathType Leaf) {
        foreach ($line in @(Get-Content -LiteralPath $SunshineConfiguration)) {
            $lines.Add($line)
        }
    }

    $pattern = "^\s*$([regex]::Escape($Name))\s*="
    for ($index = $lines.Count - 1; $index -ge 0; $index--) {
        if ($lines[$index] -match $pattern) {
            $lines.RemoveAt($index)
        }
    }
    $lines.Add("$Name = $Value")
    [IO.File]::WriteAllLines(
        $SunshineConfiguration,
        [string[]]$lines,
        [Text.UTF8Encoding]::new($false)
    )
}

function Get-SunshineInboundRules {
    $byDisplayName = @(
        Get-NetFirewallRule -DisplayName '*Sunshine*' -ErrorAction SilentlyContinue |
            Where-Object Direction -EQ Inbound
    )
    $byProgram = @(
        Get-NetFirewallApplicationFilter `
            -Program $SunshineExecutable `
            -ErrorAction SilentlyContinue |
            Get-NetFirewallRule -ErrorAction SilentlyContinue |
            Where-Object Direction -EQ Inbound
    )
    return @($byDisplayName + $byProgram | Sort-Object Name -Unique)
}

function Set-SunshineFirewall {
    foreach ($name in @($ManagedHostTcpRule, $ManagedHostUdpRule) + $RetiredFirewallRules) {
        Remove-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
    }
    foreach ($rule in @(Get-SunshineInboundRules)) {
        if ($rule.Enabled -eq 'True') {
            Disable-NetFirewallRule -Name $rule.Name
        }
    }

    $common = @{
        Group = $ManagedHostFirewallGroup
        Direction = 'Inbound'
        Action = 'Allow'
        Enabled = 'True'
        Profile = 'Private'
        Program = $SunshineExecutable
        RemoteAddress = 'LocalSubnet4'
        InterfaceType = @('Wired', 'Wireless')
    }
    $null = New-NetFirewallRule `
        @common `
        -Name $ManagedHostTcpRule `
        -DisplayName 'Game stream host TCP from the private local subnet' `
        -Protocol TCP `
        -LocalPort 47984, 47989, 48010
    $null = New-NetFirewallRule `
        @common `
        -Name $ManagedHostUdpRule `
        -DisplayName 'Game stream host UDP and discovery from the private local subnet' `
        -Protocol UDP `
        -LocalPort 5353, 47998-48000, 48002, 48010
}

function Remove-RetiredGameStreamState {
    foreach ($name in $RetiredFirewallRules) {
        Remove-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
    }
}

function Test-ManagedHostRule {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Protocol,
        [Parameter(Mandatory)][string[]]$Ports
    )

    $rule = Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue
    if (
        $null -eq $rule -or
        $rule.Enabled -ne 'True' -or
        $rule.Action -ne 'Allow' -or
        $rule.Direction -ne 'Inbound' -or
        $rule.Profile -ne 'Private'
    ) {
        return $false
    }
    $application = $rule | Get-NetFirewallApplicationFilter
    $address = $rule | Get-NetFirewallAddressFilter
    $port = $rule | Get-NetFirewallPortFilter
    $actualPorts = @($port.LocalPort | ForEach-Object { $_.ToString() } | Sort-Object)
    return (
        $application.Program -ieq $SunshineExecutable -and
        @($address.RemoteAddress).Count -eq 1 -and
        @($address.RemoteAddress)[0] -ieq 'LocalSubnet4' -and
        $port.Protocol -ieq $Protocol -and
        -not (Compare-Object $actualPorts @($Ports | Sort-Object))
    )
}

function Test-SunshineFirewall {
    if (-not (Test-ManagedHostRule -Name $ManagedHostTcpRule -Protocol TCP -Ports @('47984', '47989', '48010'))) {
        return $false
    }
    if (-not (Test-ManagedHostRule -Name $ManagedHostUdpRule -Protocol UDP -Ports @('5353', '47998-48000', '48002', '48010'))) {
        return $false
    }
    foreach ($rule in @(Get-SunshineInboundRules)) {
        if ($rule.Name -notin @($ManagedHostTcpRule, $ManagedHostUdpRule) -and $rule.Enabled -eq 'True') {
            return $false
        }
    }
    return $true
}

function Set-HostBaseline {
    Assert-VirtualDisplayReady
    $sunshineService = Get-SunshineService
    if ($null -eq $sunshineService) {
        throw 'Sunshine is installed, but its Windows service is unavailable.'
    }

    # Keep a local backup before changing either network or display settings.
    if (Test-Path -LiteralPath $SunshineConfiguration -PathType Leaf) {
        $backup = "$SunshineConfiguration.before-headless"
        if (-not (Test-Path -LiteralPath $backup)) {
            Copy-Item -LiteralPath $SunshineConfiguration -Destination $backup
        }
    }

    # Complete driver work first so an installation/restart failure leaves the
    # existing Sunshine service and network policy available for recovery.
    Set-VirtualDisplayModes
    Set-Service -Name $sunshineService.Name -StartupType Disabled
    if ((Get-Service -Name $sunshineService.Name).Status -ne 'Stopped') {
        Stop-Service -Name $sunshineService.Name -Force
    }

    Set-SunshineSetting -Name upnp -Value disabled
    Set-SunshineSetting -Name origin_web_ui_allowed -Value pc
    Set-SunshineSetting -Name address_family -Value ipv4
    Set-SunshineSetting -Name global_prep_cmd -Value '[]'
    Set-SunshineFirewall

    Unregister-ScheduledTask `
        -TaskName $LegacySessionPolicyTaskName `
        -Confirm:$false `
        -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $LegacySessionPolicyRoot -Recurse -Force -ErrorAction SilentlyContinue

    $policyPath = 'HKLM:\Software\Policies\Microsoft\Windows\System'
    $null = New-Item -Path $policyPath -Force
    $null = New-ItemProperty `
        -LiteralPath $policyPath `
        -Name DisableLockScreenAppNotifications `
        -PropertyType DWord `
        -Value 1 `
        -Force

    Set-Service -Name $sunshineService.Name -StartupType Automatic
    $enumerationSince = Get-Date
    Start-Service -Name $sunshineService.Name

    # Restarting refreshes Sunshine's own enumeration, including inactive
    # virtual monitors. Keep the service usable if discovery fails.
    $displayId = Wait-SunshineVirtualDisplay -Since $enumerationSince

    Stop-Service -Name $sunshineService.Name -Force
    try {
        Set-SunshineSetting -Name output_name -Value $displayId
        foreach ($setting in $HostDisplaySettings.GetEnumerator()) {
            Set-SunshineSetting -Name $setting.Key -Value $setting.Value
        }
    }
    finally {
        $enumerationSince = Get-Date
        Start-Service -Name $sunshineService.Name
    }
    $null = Wait-SunshineVirtualDisplay -Since $enumerationSince
    Write-Host "Sunshine will stream virtual display $displayId and restore the display layout on disconnect."
}

function Set-ClientBaseline {
    $null = New-Item -ItemType Directory -Path 'HKLM:\Software\WireGuard' -Force
    Remove-ItemProperty `
        -LiteralPath 'HKLM:\Software\WireGuard' `
        -Name DangerousScriptExecution `
        -ErrorAction SilentlyContinue
    Remove-RetiredGameStreamState
}

function Get-ConfigurationFindings {
    $findings = [Collections.Generic.List[string]]::new()
    if ($Role -eq 'Host') {
        if (-not (Test-Path -LiteralPath $SunshineExecutable -PathType Leaf)) {
            $findings.Add('Sunshine is not installed')
            return @($findings)
        }
        foreach ($setting in @{
            upnp = 'disabled'
            origin_web_ui_allowed = 'pc'
            address_family = 'ipv4'
            global_prep_cmd = '[]'
        }.GetEnumerator()) {
            if ((Get-SunshineSetting -Name $setting.Key) -ne $setting.Value) {
                $findings.Add("Sunshine setting '$($setting.Key)' differs")
            }
        }
        foreach ($setting in $HostDisplaySettings.GetEnumerator()) {
            if ((Get-SunshineSetting -Name $setting.Key) -ne $setting.Value) {
                $findings.Add("Sunshine display setting '$($setting.Key)' differs")
            }
        }
        try {
            Assert-VirtualDisplayReady
            $displayConfiguration = [xml]::new()
            $displayConfiguration.XmlResolver = $null
            $displayConfiguration.Load((Get-VirtualDisplayConfiguration))
            if (Add-VirtualDisplayModes -Configuration $displayConfiguration) {
                $findings.Add('virtual display is missing laptop resolutions or 30/60 Hz modes')
            }
            $displayId = Get-VirtualDisplayIdFromLog -Content (
                Get-Content -LiteralPath $SunshineLog -Raw
            )
            if ((Get-SunshineSetting -Name output_name) -ne $displayId) {
                $findings.Add('Sunshine is not configured to capture the virtual display')
            }
        }
        catch {
            $findings.Add($_.Exception.Message)
        }
        if (-not (Test-SunshineFirewall)) {
            $findings.Add('Sunshine private-LAN firewall policy differs')
        }
        $service = Get-SunshineService
        if ($null -eq $service) {
            $findings.Add('Sunshine service is absent')
        }
        else {
            $serviceConfiguration = Get-CimInstance Win32_Service -Filter "Name='$($service.Name)'"
            if ($serviceConfiguration.StartMode -ne 'Auto' -or $service.Status -ne 'Running') {
                $findings.Add('Sunshine service is not automatic and running')
            }
        }
        $lockScreenPolicy = Get-ItemPropertyValue `
            -LiteralPath 'HKLM:\Software\Policies\Microsoft\Windows\System' `
            -Name DisableLockScreenAppNotifications `
            -ErrorAction SilentlyContinue
        if ($lockScreenPolicy -ne 1) {
            $findings.Add('lock-screen application notifications are not disabled')
        }
    }
    else {
        if (-not (Test-Path -LiteralPath $MoonlightExecutable -PathType Leaf)) {
            $findings.Add('Moonlight is not installed')
        }
        if (-not (Test-Path -LiteralPath $WireGuardExecutable -PathType Leaf)) {
            $findings.Add('WireGuard is not installed')
        }
    }
    return @($findings)
}

function Write-Observations {
    if ($Role -eq 'Host') {
        if ($null -ne (Get-Service -Name $LegacyTunnelService -ErrorAction SilentlyContinue)) {
            Write-Warning 'A legacy host WireGuard tunnel remains installed. Remove it after migrating the gateway and client.'
        }
        foreach ($network in @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)) {
            if ($network.IPv4Connectivity -ne 'Disconnected' -and $network.NetworkCategory -ne 'Private') {
                Write-Warning "Network '$($network.InterfaceAlias)' is $($network.NetworkCategory); Sunshine is blocked on this adapter."
            }
        }
        Write-Host 'In Moonlight, enable Optimize game settings for automatic virtual-display resolution.'
        Write-Host 'Prove a fresh stream with the TV off, then repeat after idle and reboot before relying on unattended access.'
    }
    else {
        $tunnel = Get-Service -Name $LegacyTunnelService -ErrorAction SilentlyContinue
        if ($null -eq $tunnel) {
            Write-Host 'Manual step: import the client-only game-stream tunnel with the WireGuard app.'
        }
        else {
            Write-Host "Observed WireGuard tunnel service state: $($tunnel.Status)"
        }
    }
}

function Invoke-Main {
    $currentBuild = [int](Get-ItemPropertyValue `
        -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' `
        -Name CurrentBuild)
    if ($currentBuild -lt 22000) {
        throw "Windows 11 is required; detected build $currentBuild."
    }

    if (-not $Check) {
        $winGet = Get-WinGetCommand
        if ([string]::IsNullOrWhiteSpace($winGet)) {
            throw 'WinGet is unavailable. Install or repair Microsoft App Installer, then rerun.'
        }
        if ($Role -eq 'Host') {
            Install-PackageIfMissing `
                -WinGet $winGet `
                -Id LizardByte.Sunshine `
                -ExpectedExecutable $SunshineExecutable
            Set-HostBaseline
        }
        else {
            Install-PackageIfMissing `
                -WinGet $winGet `
                -Id MoonlightGameStreamingProject.Moonlight `
                -ExpectedExecutable $MoonlightExecutable
            Install-PackageIfMissing `
                -WinGet $winGet `
                -Id WireGuard.WireGuard `
                -ExpectedExecutable $WireGuardExecutable
            Set-ClientBaseline
        }
    }

    $findings = @(Get-ConfigurationFindings)
    if ($findings.Count -gt 0) {
        Write-Host "Windows game-stream $($Role.ToLowerInvariant()) baseline differs:"
        foreach ($finding in $findings) {
            Write-Host "- $finding"
        }
        throw 'Rerun without --check to apply the stable Windows baseline.'
    }

    Write-Host "Windows game-stream $($Role.ToLowerInvariant()) baseline is ready."
    Write-Observations
}

function Write-ElevatedResult {
    $captured = [Collections.Generic.List[string]]::new()
    $exitCode = 0
    try {
        & { Invoke-Main } *>&1 |
            ForEach-Object { $captured.Add($_.ToString()) }
    }
    catch {
        $captured.Add($_.Exception.Message)
        if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) {
            $captured.Add($_.ScriptStackTrace)
        }
        $exitCode = 1
    }
    [ordered]@{
        exitCode = $exitCode
        output = @($captured)
    } |
        ConvertTo-Json -Depth 3 |
        Set-Content -LiteralPath $ResultPath -Encoding UTF8
    exit $exitCode
}

if (-not (Test-IsAdministrator)) {
    if (-not (Test-CurrentUserCanSelfElevate)) {
        throw 'Run from a Windows account that is itself a local administrator.'
    }

    $stagingRoot = Join-Path $env:LOCALAPPDATA 'caz.nix\game-stream-bootstrap'
    $stagedScript = Join-Path $stagingRoot 'windows-game-stream.ps1'
    $resultFile = Join-Path $stagingRoot 'result.json'
    $null = New-Item -ItemType Directory -Path $stagingRoot -Force
    try {
        Copy-Item -LiteralPath $PSCommandPath -Destination $stagedScript -Force
        Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue

        $arguments = @(
            '-NoLogo',
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            "`"$stagedScript`"",
            '-Role',
            $Role,
            '-ResultPath',
            "`"$resultFile`""
        )
        if ($Check) {
            $arguments += '-Check'
        }
        $process = Start-Process `
            -FilePath powershell.exe `
            -ArgumentList ($arguments -join ' ') `
            -Verb RunAs `
            -Wait `
            -PassThru
        if (-not (Test-Path -LiteralPath $resultFile -PathType Leaf)) {
            throw "The elevated Windows action exited $($process.ExitCode) without returning a result."
        }
        $result = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
        foreach ($line in @($result.output)) {
            Write-Host $line
        }
        $resultExitCode = [int]$result.exitCode
    }
    finally {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    exit $resultExitCode
}

if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
    Write-ElevatedResult
}

try {
    Invoke-Main
}
catch {
    Write-Error $_
    exit 1
}
