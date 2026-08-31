#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Host', 'Client')]
    [string]$Role,

    [switch]$Prepare,

    [string]$Output,

    [string]$Enroll,

    [switch]$Check,

    [switch]$ResetEnrollment,

    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$SourceCommit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RequestSchema = 'caz.nix/game-stream-request/v1'
$ResponseSchema = 'caz.nix/game-stream-enrollment/v1'
$LocalStateSchema = 'caz.nix/game-stream-local-state/v1'
$TunnelName = 'game-stream'
$TunnelServiceName = "WireGuardTunnel`$$TunnelName"
$WireGuardRoot = Join-Path $env:ProgramFiles 'WireGuard'
$WireGuard = Join-Path $WireGuardRoot 'wireguard.exe'
$Wg = Join-Path $WireGuardRoot 'wg.exe'
$DpapiConfiguration = Join-Path $WireGuardRoot "Data\Configurations\$TunnelName.conf.dpapi"
$PlaintextConfiguration = Join-Path $WireGuardRoot "Data\Configurations\$TunnelName.conf"
$StateRoot = Join-Path $env:ProgramData "caz.nix\game-stream-enrollment-$($Role.ToLowerInvariant())"
$PendingStateFile = Join-Path $StateRoot 'pending.json'
$EnrolledStateFile = Join-Path $StateRoot 'enrolled.json'
$ComposedConfiguration = Join-Path $StateRoot 'game-stream.conf'
$WindowsBootstrap = Join-Path $PSScriptRoot 'windows.ps1'

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
        throw 'Could not restrict enrollment state to System and Administrators.'
    }
}

function Initialize-StateRoot {
    $null = New-Item -ItemType Directory -Path $StateRoot -Force
    Set-AdministratorOnlyAcl -Path $StateRoot
}

function Get-WinGetCommand {
    $command = Get-Command 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $command -and (Test-Path -LiteralPath $command.Source -PathType Leaf)) {
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

function Ensure-WireGuardTools {
    if (
        (Test-Path -LiteralPath $WireGuard -PathType Leaf) -and
        (Test-Path -LiteralPath $Wg -PathType Leaf)
    ) {
        return
    }

    $winGet = Get-WinGetCommand
    if ([string]::IsNullOrWhiteSpace($winGet)) {
        throw 'WinGet is unavailable. Install or repair Microsoft App Installer, then rerun Prepare.'
    }
    Write-Host 'Installing the official WireGuard package needed to generate this device key...'
    & $winGet install `
        --id WireGuard.WireGuard `
        --exact `
        --source winget `
        --silent `
        --accept-package-agreements `
        --accept-source-agreements `
        --disable-interactivity
    if ($LASTEXITCODE -ne 0) {
        throw "WinGet failed to install WireGuard.WireGuard (exit $LASTEXITCODE)."
    }
    if (
        -not (Test-Path -LiteralPath $WireGuard -PathType Leaf) -or
        -not (Test-Path -LiteralPath $Wg -PathType Leaf)
    ) {
        throw 'WireGuard installed without its expected command-line tools.'
    }
}

function Test-WireGuardKey {
    param([Parameter(Mandatory)][string]$Key)

    if ($Key -notmatch '^[A-Za-z0-9+/]{43}=$') {
        return $false
    }
    try {
        return [Convert]::FromBase64String($Key).Length -eq 32
    }
    catch {
        return $false
    }
}

function Test-Ipv4RouteWithPrefix {
    param(
        [Parameter(Mandatory)][string]$Route,
        [Parameter(Mandatory)][ValidateRange(0, 32)][int]$Prefix
    )

    if ($Route -notmatch "^(?<address>(\d{1,3}\.){3}\d{1,3})/$Prefix$") {
        return $false
    }
    [uint64]$addressValue = 0
    foreach ($octet in $Matches.address.Split('.')) {
        if ([int]$octet -gt 255) {
            return $false
        }
        $addressValue = ($addressValue * 256) + [int]$octet
    }
    if ($Prefix -lt 32) {
        [uint64]$blockSize = [Math]::Pow(2, 32 - $Prefix)
        if (($addressValue % $blockSize) -ne 0) {
            return $false
        }
    }
    return $true
}

function ConvertTo-Ipv4RouteInteger {
    param([Parameter(Mandatory)][string]$Route)

    [uint64]$value = 0
    foreach ($octet in (($Route -split '/', 2)[0]).Split('.')) {
        $value = ($value * 256) + [int]$octet
    }
    return $value
}

function Test-RequestId {
    param([Parameter(Mandatory)][string]$RequestId)

    return $RequestId -match '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
}

function Get-JsonDocument {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "JSON input is unavailable: $Path"
    }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Assert-ExactProperties {
    param(
        [Parameter(Mandatory)][object]$Document,
        [Parameter(Mandatory)][string[]]$Expected,
        [Parameter(Mandatory)][string]$Description
    )

    $actual = @($Document.PSObject.Properties.Name | Sort-Object)
    if (Compare-Object @($actual) @($Expected | Sort-Object)) {
        throw "$Description contains unexpected or missing fields."
    }
}

function Read-LocalState {
    param([Parameter(Mandatory)][string]$Path)

    $state = Get-JsonDocument -Path $Path
    Assert-ExactProperties `
        -Document $state `
        -Expected @('schema', 'role', 'requestId', 'publicKey', 'privateKey') `
        -Description 'Local enrollment state'
    if (
        $state.schema -ne $LocalStateSchema -or
        $state.role -ne $Role.ToLowerInvariant() -or
        -not (Test-RequestId -RequestId $state.requestId) -or
        -not (Test-WireGuardKey -Key $state.publicKey) -or
        -not (Test-WireGuardKey -Key $state.privateKey)
    ) {
        throw 'Local enrollment state is invalid or belongs to another role.'
    }
    $derivedPublicKey = @($state.privateKey | & $Wg pubkey 2>$null) | Select-Object -First 1
    if ($LASTEXITCODE -ne 0 -or $derivedPublicKey -ne $state.publicKey) {
        throw 'The pending private key does not match its public enrollment request.'
    }
    return $state
}

function Read-EnrolledState {
    if (-not (Test-Path -LiteralPath $EnrolledStateFile -PathType Leaf)) {
        return $null
    }
    $state = Get-JsonDocument -Path $EnrolledStateFile
    Assert-ExactProperties `
        -Document $state `
        -Expected @('schema', 'role', 'requestId', 'publicKey') `
        -Description 'Enrolled device state'
    if (
        $state.schema -ne $LocalStateSchema -or
        $state.role -ne $Role.ToLowerInvariant() -or
        -not (Test-RequestId -RequestId $state.requestId) -or
        -not (Test-WireGuardKey -Key $state.publicKey)
    ) {
        throw 'Enrolled device state is invalid or belongs to another role.'
    }
    return $state
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)][object]$Document,
        [Parameter(Mandatory)][string]$Path
    )

    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }
    $encoding = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText(
        [IO.Path]::GetFullPath($Path),
        (($Document | ConvertTo-Json -Depth 4) + "`n"),
        $encoding
    )
}

function Write-PublicRequest {
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][string]$Path
    )

    Write-JsonFile -Path $Path -Document ([ordered]@{
        schema = $RequestSchema
        role = $Role.ToLowerInvariant()
        requestId = $State.requestId
        publicKey = $State.publicKey
    })
}

function Get-ActiveTunnelPublicKey {
    if (-not (Test-Path -LiteralPath $Wg -PathType Leaf)) {
        return $null
    }
    $key = $null
    $exitCode = 1
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $key = @(& $Wg show $TunnelName public-key 2>$null) | Select-Object -First 1
        $exitCode = $LASTEXITCODE
    }
    catch {
        return $null
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if (
        $exitCode -ne 0 -or
        [string]::IsNullOrWhiteSpace($key) -or
        -not (Test-WireGuardKey -Key $key)
    ) {
        return $null
    }
    return $key
}

function Reset-PartialTunnelImport {
    param([Parameter(Mandatory)][string]$PendingPublicKey)

    $activePublicKey = Get-ActiveTunnelPublicKey
    if ($null -ne $activePublicKey -and $activePublicKey -ne $PendingPublicKey) {
        throw 'An unrelated active WireGuard tunnel already uses the managed game-stream name. Reset it explicitly before replacement.'
    }

    if ($null -ne (Get-Service -Name $TunnelServiceName -ErrorAction SilentlyContinue)) {
        $uninstallOutput = @()
        $uninstallExitCode = 1
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $uninstallOutput = @(& $WireGuard /uninstalltunnelservice $TunnelName 2>&1)
            $uninstallExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        $uninstallOutput | ForEach-Object { Write-Host ($_.ToString()) }
        if (
            $uninstallExitCode -ne 0 -and
            $null -ne (Get-Service -Name $TunnelServiceName -ErrorAction SilentlyContinue)
        ) {
            throw 'WireGuard could not remove the incomplete game-stream tunnel service.'
        }
    }

    Remove-Item -LiteralPath $PlaintextConfiguration -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $DpapiConfiguration -Force -ErrorAction SilentlyContinue
    if (
        (Test-Path -LiteralPath $PlaintextConfiguration -PathType Leaf) -or
        (Test-Path -LiteralPath $DpapiConfiguration -PathType Leaf)
    ) {
        throw 'WireGuard could not clear the incomplete game-stream configuration for deterministic re-import.'
    }
}

function Read-EnrollmentResponse {
    param([Parameter(Mandatory)][string]$Path)

    $response = Get-JsonDocument -Path $Path
    Assert-ExactProperties `
        -Document $response `
        -Expected @(
            'schema',
            'role',
            'requestId',
            'gatewayPublicKey',
            'endpoint',
            'address',
            'allowedIps',
            'persistentKeepalive'
        ) `
        -Description 'Enrollment response'
    $expectedAllowedPrefix = if ($Role -eq 'Host') { 28 } else { 32 }
    if (
        $response.schema -isnot [string] -or
        $response.role -isnot [string] -or
        $response.requestId -isnot [string] -or
        $response.gatewayPublicKey -isnot [string] -or
        $response.endpoint -isnot [string] -or
        $response.address -isnot [string] -or
        $response.allowedIps -isnot [string] -or
        $response.schema -ne $ResponseSchema -or
        $response.role -ne $Role.ToLowerInvariant() -or
        -not (Test-RequestId -RequestId $response.requestId) -or
        -not (Test-WireGuardKey -Key $response.gatewayPublicKey) -or
        $response.endpoint -notmatch '^[A-Za-z0-9.-]+:[1-9][0-9]{0,4}$' -or
        [int]($response.endpoint -replace '^.*:', '') -lt 1 -or
        [int]($response.endpoint -replace '^.*:', '') -gt 65535 -or
        -not (Test-Ipv4RouteWithPrefix -Route $response.address -Prefix 32) -or
        -not (Test-Ipv4RouteWithPrefix -Route $response.allowedIps -Prefix $expectedAllowedPrefix) -or
        [int]$response.persistentKeepalive -ne 25
    ) {
        throw 'Enrollment response is malformed or belongs to another role.'
    }
    $addressValue = ConvertTo-Ipv4RouteInteger -Route $response.address
    $allowedValue = ConvertTo-Ipv4RouteInteger -Route $response.allowedIps
    if (
        ($Role -eq 'Host' -and $addressValue -ge $allowedValue -and $addressValue -lt ($allowedValue + 16)) -or
        ($Role -eq 'Client' -and $addressValue -eq $allowedValue)
    ) {
        throw 'Enrollment response address and peer route overlap.'
    }
    return $response
}

function Write-WireGuardConfiguration {
    param(
        [Parameter(Mandatory)][object]$PendingState,
        [Parameter(Mandatory)][object]$Response
    )

    Initialize-StateRoot
    $lines = @(
        '[Interface]',
        "Address = $($Response.address)",
        "PrivateKey = $($PendingState.privateKey)",
        '',
        '[Peer]',
        "PublicKey = $($Response.gatewayPublicKey)",
        "Endpoint = $($Response.endpoint)",
        "AllowedIPs = $($Response.allowedIps)",
        'PersistentKeepalive = 25'
    )
    $encoding = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllLines($ComposedConfiguration, $lines, $encoding)
}

function Invoke-RoleConfiguration {
    param(
        [switch]$ReadOnly,
        [string]$EnrollmentFile
    )

    if (-not (Test-Path -LiteralPath $WindowsBootstrap -PathType Leaf)) {
        throw 'The declarative Windows bootstrap is missing beside this setup script.'
    }
    $arguments = @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $WindowsBootstrap,
        '-Profile',
        "game-stream-$($Role.ToLowerInvariant())",
        '-GameStreamStage',
        'Remote'
    )
    if ($ReadOnly) {
        $arguments += '-Check'
    }
    if (-not [string]::IsNullOrWhiteSpace($EnrollmentFile)) {
        $arguments += @('-GameStreamEnrollmentFile', $EnrollmentFile)
    }
    if (-not [string]::IsNullOrWhiteSpace($SourceCommit)) {
        $arguments += @('-SourceCommit', $SourceCommit)
    }

    $childOutput = @()
    $exitCode = 1
    $previousErrorActionPreference = $ErrorActionPreference
    $previousConsoleOutputEncoding = [Console]::OutputEncoding
    try {
        $ErrorActionPreference = 'Continue'
        [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
        $childOutput = @(& powershell.exe @arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        [Console]::OutputEncoding = $previousConsoleOutputEncoding
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $childOutput | ForEach-Object { Write-Host ($_.ToString()) }
    return $exitCode
}

$selectedActions = @(
    [bool]$Prepare,
    -not [string]::IsNullOrWhiteSpace($Enroll),
    [bool]$Check,
    [bool]$ResetEnrollment
)
$selectedActionCount = @($selectedActions | Where-Object { $_ }).Count
if ($selectedActionCount -gt 1) {
    throw 'Choose only one of Prepare, Enroll, Check, or ResetEnrollment.'
}
if ($Prepare -and [string]::IsNullOrWhiteSpace($Output)) {
    throw 'Prepare requires -Output for the public enrollment request.'
}
if (-not $Prepare -and -not [string]::IsNullOrWhiteSpace($Output)) {
    throw '-Output is accepted only with -Prepare.'
}
if ($Check -and -not [string]::IsNullOrWhiteSpace($SourceCommit)) {
    throw '-Check derives the reviewed digest from local source and does not accept SourceCommit.'
}

if ($Check) {
    $exitCode = Invoke-RoleConfiguration -ReadOnly
    exit $exitCode
}

if (-not (Test-IsAdministrator)) {
    throw 'Open PowerShell as Administrator before preparing, enrolling, applying, or resetting this role.'
}

if ($ResetEnrollment) {
    $enrolledState = $null
    if (Test-Path -LiteralPath $EnrolledStateFile -PathType Leaf) {
        try {
            $enrolledState = Read-EnrolledState
        }
        catch {
            Write-Warning 'Local enrollment metadata is malformed; reset will remove it without displaying a request ID.'
        }
    }
    $hasLocalEnrollment = (
        $null -ne $enrolledState -or
        (Test-Path -LiteralPath $EnrolledStateFile -PathType Leaf) -or
        (Test-Path -LiteralPath $PendingStateFile -PathType Leaf) -or
        (Test-Path -LiteralPath $DpapiConfiguration -PathType Leaf) -or
        (Test-Path -LiteralPath $PlaintextConfiguration -PathType Leaf)
    )
    $target = if ($null -ne $enrolledState) {
        "local $($Role.ToLowerInvariant()) request $($enrolledState.requestId)"
    }
    else {
        "local $($Role.ToLowerInvariant()) enrollment material"
    }
    if ($hasLocalEnrollment -and $PSCmdlet.ShouldProcess(
        $target,
        'remove the WireGuard tunnel and local enrollment state'
    )) {
        if (Test-Path -LiteralPath $WireGuard -PathType Leaf) {
            & $WireGuard /uninstalltunnelservice $TunnelName
            if ($LASTEXITCODE -ne 0 -and $null -ne (Get-Service -Name $TunnelServiceName -ErrorAction SilentlyContinue)) {
                throw 'WireGuard could not uninstall the game-stream tunnel service.'
            }
        }
        Remove-Item -LiteralPath $DpapiConfiguration -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $PlaintextConfiguration -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $StateRoot -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host 'Local enrollment was reset. Revoke the old request on the gateway and in Sunshine if you have not already done so.'
    }
    elseif (-not $hasLocalEnrollment) {
        Write-Host 'No local enrollment material exists for this role.'
    }
    exit 0
}

if ($Prepare) {
    Ensure-WireGuardTools
    Initialize-StateRoot
    if (Test-Path -LiteralPath $PendingStateFile -PathType Leaf) {
        $state = Read-LocalState -Path $PendingStateFile
    }
    else {
        $enrolledState = Read-EnrolledState
        if ($null -ne $enrolledState) {
            Write-PublicRequest -State $enrolledState -Path $Output
            Write-Host "This device is already enrolled; reproduced its public request at $Output."
            exit 0
        }
        if (Test-Path -LiteralPath $DpapiConfiguration -PathType Leaf) {
            throw 'A DPAPI tunnel exists without matching local enrollment metadata. Reset it explicitly before preparing a replacement.'
        }
        $privateKey = @(& $Wg genkey 2>$null) | Select-Object -First 1
        if ($LASTEXITCODE -ne 0 -or -not (Test-WireGuardKey -Key $privateKey)) {
            throw 'WireGuard could not generate a valid private key.'
        }
        $publicKey = @($privateKey | & $Wg pubkey 2>$null) | Select-Object -First 1
        if ($LASTEXITCODE -ne 0 -or -not (Test-WireGuardKey -Key $publicKey)) {
            throw 'WireGuard could not derive a valid public key.'
        }
        $state = [ordered]@{
            schema = $LocalStateSchema
            role = $Role.ToLowerInvariant()
            requestId = [guid]::NewGuid().ToString('D').ToLowerInvariant()
            publicKey = $publicKey
            privateKey = $privateKey
        }
        Write-JsonFile -Document $state -Path $PendingStateFile
        Set-AdministratorOnlyAcl -Path $StateRoot
    }
    Write-PublicRequest -State $state -Path $Output
    Write-Host "Public enrollment request written to $Output. The private key remains in the administrator-only local state."
    exit 0
}

if (-not [string]::IsNullOrWhiteSpace($Enroll)) {
    Ensure-WireGuardTools
    $response = Read-EnrollmentResponse -Path $Enroll
    $enrolledState = Read-EnrolledState
    if ($null -ne $enrolledState) {
        if (
            $enrolledState.requestId -ne $response.requestId -or
            (Get-ActiveTunnelPublicKey) -ne $enrolledState.publicKey
        ) {
            throw 'This response differs from the existing enrollment. Revoke and reset explicitly before replacement.'
        }
        $exitCode = Invoke-RoleConfiguration
        if ($exitCode -eq 0) {
            Remove-Item -LiteralPath $Enroll -Force -ErrorAction SilentlyContinue
        }
        exit $exitCode
    }
    if (-not (Test-Path -LiteralPath $PendingStateFile -PathType Leaf)) {
        throw 'No pending local private key exists. Run Prepare on this same device first.'
    }
    $pendingState = Read-LocalState -Path $PendingStateFile
    if ($pendingState.requestId -ne $response.requestId) {
        throw 'The response does not match this device pending request ID.'
    }

    if (
        (Test-Path -LiteralPath $DpapiConfiguration -PathType Leaf) -or
        (Test-Path -LiteralPath $PlaintextConfiguration -PathType Leaf) -or
        $null -ne (Get-Service -Name $TunnelServiceName -ErrorAction SilentlyContinue)
    ) {
        Reset-PartialTunnelImport -PendingPublicKey $pendingState.publicKey
    }
    Write-WireGuardConfiguration -PendingState $pendingState -Response $response
    $exitCode = Invoke-RoleConfiguration -EnrollmentFile $ComposedConfiguration
    if ($exitCode -ne 0) {
        throw "Declarative role enrollment failed with exit code $exitCode. The restricted pending state was retained for a safe rerun."
    }
    if ((Get-ActiveTunnelPublicKey) -ne $pendingState.publicKey) {
        throw 'The converged tunnel public key does not match the pending enrollment key. Pending state was retained and enrollment was not finalized.'
    }

    Write-JsonFile -Path $EnrolledStateFile -Document ([ordered]@{
        schema = $LocalStateSchema
        role = $Role.ToLowerInvariant()
        requestId = $pendingState.requestId
        publicKey = $pendingState.publicKey
    })
    Set-AdministratorOnlyAcl -Path $StateRoot
    Remove-Item -LiteralPath $PendingStateFile -Force
    Remove-Item -LiteralPath $ComposedConfiguration -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Enroll -Force -ErrorAction SilentlyContinue
    Write-Host "The game-stream-$($Role.ToLowerInvariant()) role is enrolled and applied."
    exit 0
}

$exitCode = Invoke-RoleConfiguration
exit $exitCode
