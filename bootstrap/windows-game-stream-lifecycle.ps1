#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Host', 'Client')]
    [string]$Role,

    [switch]$Prepare,

    [string]$Output,

    [string]$Enroll,

    [switch]$ResetEnrollment,

    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$SourceCommit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent $PSScriptRoot
$Profile = "game-stream-$($Role.ToLowerInvariant())"
$StagingParent = Join-Path $env:LOCALAPPDATA "caz.nix\game-stream-lifecycle\$Profile"
$StagingRoot = Join-Path $StagingParent ([guid]::NewGuid().ToString('N'))
$StagedRepositoryRoot = Join-Path $StagingRoot 'source'
$StagedBootstrapRoot = Join-Path $StagedRepositoryRoot 'bootstrap'
$StagedWindowsRoot = Join-Path $StagedRepositoryRoot 'windows'
$StagedProfilesRoot = Join-Path $StagedWindowsRoot 'profiles'
$StagedCapabilitiesRoot = Join-Path $StagedWindowsRoot 'capabilities'
$StagedSetup = Join-Path $StagedBootstrapRoot 'game-stream-setup.ps1'
$StagedRequest = Join-Path $StagingRoot 'request.json'
$StagedResponse = Join-Path $StagingRoot 'response.json'
$StagedLog = Join-Path $StagingRoot 'elevated.log'
$RetainedFailureLog = Join-Path $StagingParent 'last-error.log'

function Test-CurrentUserCanSelfElevate {
    $whoAmI = Join-Path $env:SystemRoot 'System32\whoami.exe'
    $groups = @(& $whoAmI /groups /fo csv /nh 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not inspect the current Windows security groups with whoami.exe.'
    }
    return @($groups | Where-Object { $_ -match 'S-1-5-32-544' }).Count -gt 0
}

function Set-RestrictedStagingAcl {
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
    $null = & $icacls `
        $StagingRoot `
        '/inheritance:r' `
        '/grant:r' `
        "*$($currentSid):(OI)(CI)F" `
        '*S-1-5-18:(OI)(CI)F' `
        '*S-1-5-32-544:(OI)(CI)F'
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not restrict the local game-stream lifecycle staging directory.'
    }
}

function Copy-RequiredSource {
    $null = New-Item -ItemType Directory -Path $StagingRoot
    Set-RestrictedStagingAcl
    $null = New-Item -ItemType Directory -Path $StagedBootstrapRoot -Force
    $null = New-Item -ItemType Directory -Path $StagedProfilesRoot -Force
    $null = New-Item -ItemType Directory -Path $StagedCapabilitiesRoot -Force

    foreach ($name in @(
        'game-stream-setup.ps1',
        'windows-game-stream-lifecycle.ps1',
        'windows-game-stream.ps1',
        'windows.ps1'
    )) {
        $source = Join-Path $PSScriptRoot $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "A required game-stream source file is unavailable: $source"
        }
        Copy-Item -LiteralPath $source -Destination (Join-Path $StagedBootstrapRoot $name) -Force
    }

    $profileSource = Join-Path $RepositoryRoot "windows\profiles\$Profile.json"
    $capabilitySource = Join-Path $RepositoryRoot "windows\capabilities\$Profile.winget"
    foreach ($source in @($profileSource, $capabilitySource)) {
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "A required game-stream declaration is unavailable: $source"
        }
    }
    Copy-Item -LiteralPath $profileSource -Destination $StagedProfilesRoot -Force
    Copy-Item -LiteralPath $capabilitySource -Destination $StagedCapabilitiesRoot -Force
}

function ConvertTo-SingleQuotedLiteral {
    param([Parameter(Mandatory)][string]$Value)

    return "'$($Value.Replace("'", "''"))'"
}

function Invoke-ElevatedLifecycle {
    $setupLiteral = ConvertTo-SingleQuotedLiteral -Value $StagedSetup
    $roleLiteral = ConvertTo-SingleQuotedLiteral -Value $Role
    $logLiteral = ConvertTo-SingleQuotedLiteral -Value $StagedLog
    $invocation = "& $setupLiteral -Role $roleLiteral"

    if ($Prepare) {
        $invocation += " -Prepare -Output $(ConvertTo-SingleQuotedLiteral -Value $StagedRequest)"
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Enroll)) {
        $invocation += " -Enroll $(ConvertTo-SingleQuotedLiteral -Value $StagedResponse)"
        $invocation += " -SourceCommit $(ConvertTo-SingleQuotedLiteral -Value $SourceCommit.ToLowerInvariant())"
    }
    else {
        $invocation += ' -ResetEnrollment -Confirm:$false'
    }
    $command = @"
try {
    $invocation *> $logLiteral
}
catch {
    (`$_ | Format-List * -Force | Out-String) |
        Add-Content -LiteralPath $logLiteral -Encoding UTF8
    exit 1
}
"@

    $encodedCommand = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($command)
    )
    $powerShell = Join-Path $PSHOME 'powershell.exe'
    try {
        $process = Start-Process `
            -FilePath $powerShell `
            -Verb RunAs `
            -ArgumentList @(
                '-NoLogo',
                '-NoProfile',
                '-NonInteractive',
                '-ExecutionPolicy',
                'Bypass',
                '-EncodedCommand',
                $encodedCommand
            ) `
            -Wait `
            -PassThru
    }
    catch {
        throw "Windows elevation was canceled or failed: $($_.Exception.Message)"
    }

    $redactedLog = ''
    if (Test-Path -LiteralPath $StagedLog -PathType Leaf) {
        $redactedLog = (Get-Content -LiteralPath $StagedLog -Raw) -replace `
            '(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{43}=(?![A-Za-z0-9+/])', `
            '<redacted-wireguard-key>'
        $redactedLog.TrimEnd() -split "`r?`n" | ForEach-Object { Write-Host $_ }
    }
    if ($process.ExitCode -ne 0) {
        if ([string]::IsNullOrWhiteSpace($redactedLog)) {
            $redactedLog = 'The elevated process returned no diagnostic output.'
        }
        $null = New-Item -ItemType Directory -Path $StagingParent -Force
        Set-Content -LiteralPath $RetainedFailureLog -Value $redactedLog -Encoding UTF8
        throw "The elevated game-stream lifecycle action failed with exit code $($process.ExitCode). The key-redacted diagnostic log is retained at '$RetainedFailureLog'."
    }
    Remove-Item -LiteralPath $RetainedFailureLog -Force -ErrorAction SilentlyContinue
}

$selectedActions = @(
    [bool]$Prepare,
    -not [string]::IsNullOrWhiteSpace($Enroll),
    [bool]$ResetEnrollment
)
$selectedActionCount = @($selectedActions | Where-Object { $_ }).Count
if ($selectedActionCount -ne 1) {
    throw 'Choose exactly one of Prepare, Enroll, or ResetEnrollment.'
}
if ($Prepare -and [string]::IsNullOrWhiteSpace($Output)) {
    throw 'Prepare requires an explicit output path for the public request.'
}
if (-not $Prepare -and -not [string]::IsNullOrWhiteSpace($Output)) {
    throw 'Output is accepted only with Prepare.'
}
if (-not [string]::IsNullOrWhiteSpace($Enroll) -and [string]::IsNullOrWhiteSpace($SourceCommit)) {
    throw 'Enroll requires the reviewed Git source commit supplied by WSL.'
}
if ($Prepare -and -not [string]::IsNullOrWhiteSpace($SourceCommit)) {
    throw 'Prepare does not accept a source commit because it does not apply a role.'
}
if ($ResetEnrollment -and -not [string]::IsNullOrWhiteSpace($SourceCommit)) {
    throw 'ResetEnrollment does not accept a source commit.'
}
if (-not (Test-CurrentUserCanSelfElevate)) {
    throw 'Run this lifecycle from a Windows account that is itself a local administrator.'
}

try {
    Copy-RequiredSource
    if (-not [string]::IsNullOrWhiteSpace($Enroll)) {
        if (-not (Test-Path -LiteralPath $Enroll -PathType Leaf)) {
            throw "The enrollment response is unavailable: $Enroll"
        }
        Copy-Item -LiteralPath $Enroll -Destination $StagedResponse -Force
    }

    Invoke-ElevatedLifecycle

    if ($Prepare) {
        if (-not (Test-Path -LiteralPath $StagedRequest -PathType Leaf)) {
            throw 'The elevated preparation completed without producing a public request.'
        }
        $outputParent = Split-Path -Parent ([IO.Path]::GetFullPath($Output))
        if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $outputParent -Force
        }
        Copy-Item -LiteralPath $StagedRequest -Destination $Output -Force
        Write-Host "Public enrollment request copied to $Output."
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Enroll)) {
        Remove-Item -LiteralPath $Enroll -Force
        Write-Host 'Consumed and removed the one-time enrollment response after successful application.'
    }
}
finally {
    Remove-Item -LiteralPath $StagingRoot -Recurse -Force -ErrorAction SilentlyContinue
}
