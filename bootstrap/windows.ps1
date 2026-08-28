#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$Check,

    [ValidatePattern('^[a-z0-9][a-z0-9-]*$')]
    [string]$Profile = 'workstation'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$MinimumWinGetVersion = [version]'1.11.430'
$RepositoryRoot = Split-Path -Parent $PSScriptRoot
$SourceWindowsRoot = Join-Path $RepositoryRoot 'windows'
$SourceCapabilitiesRoot = Join-Path $SourceWindowsRoot 'capabilities'
$SourceProfilesRoot = Join-Path $SourceWindowsRoot 'profiles'
$StagingRoot = Join-Path $env:LOCALAPPDATA "caz.nix\windows\$Profile"
$StagedCapabilitiesRoot = Join-Path $StagingRoot 'capabilities'
$StagedScriptsRoot = Join-Path $StagedCapabilitiesRoot 'scripts'

function Test-CurrentUserCanSelfElevate {
    $whoAmI = Join-Path $env:SystemRoot 'System32\whoami.exe'
    $groups = @(& $whoAmI /groups /fo csv /nh 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not inspect the current Windows security groups with whoami.exe.'
    }

    return @($groups | Where-Object { $_ -match 'S-1-5-32-544' }).Count -gt 0
}

function Get-WinGetCommand {
    $command = Get-Command 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $command -and (Test-Path -LiteralPath $command.Source)) {
        return $command.Source
    }

    $appInstaller = Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if ($null -ne $appInstaller) {
        $candidate = Join-Path $appInstaller.InstallLocation 'winget.exe'
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

function Test-VCRedistInstalled {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'
    )
    foreach ($path in $paths) {
        $runtime = Get-ItemProperty -LiteralPath $path -ErrorAction SilentlyContinue
        if ($null -ne $runtime -and $runtime.Installed -eq 1) {
            return $true
        }
    }
    return $false
}

function Install-VCRedist {
    param([Parameter(Mandatory)][string]$WinGet)

    Write-Host 'Installing the Visual C++ runtime required by non-elevated WinGet Configuration...'
    & $WinGet install `
        --id Microsoft.VCRedist.2015+.x64 `
        --exact `
        --source winget `
        --silent `
        --accept-package-agreements `
        --accept-source-agreements `
        --disable-interactivity
    if ($LASTEXITCODE -ne 0) {
        throw "WinGet failed to install Microsoft.VCRedist.2015+.x64 (exit $LASTEXITCODE)."
    }
}

function Test-DscV3ProcessorAvailable {
    $candidates = @(
        @{ Name = 'Microsoft.DesiredStateConfiguration'; MinimumVersion = [version]'3.1' },
        @{ Name = 'Microsoft.DesiredStateConfiguration-Preview'; MinimumVersion = [version]'3.1.7' }
    )

    foreach ($candidate in $candidates) {
        $package = Get-AppxPackage -Name $candidate.Name -ErrorAction SilentlyContinue |
            Sort-Object Version -Descending |
            Select-Object -First 1
        if (
            $null -ne $package -and
            $package.Status -eq 'Ok' -and
            [version]$package.Version -ge $candidate.MinimumVersion
        ) {
            return $true
        }
    }

    return $false
}

function Get-ProfileCapabilities {
    $profilePath = Join-Path $SourceProfilesRoot "$Profile.json"
    if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
        $available = @(
            Get-ChildItem -LiteralPath $SourceProfilesRoot -Filter '*.json' -File |
                ForEach-Object BaseName |
                Sort-Object
        )
        throw "Unknown Windows profile '$Profile'. Available profiles: $($available -join ', ')."
    }

    $declaration = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
    $capabilities = @($declaration.capabilities)
    if ($capabilities.Count -eq 0 -or $capabilities[0] -ne 'base') {
        throw "Windows profile '$Profile' must select the base capability first."
    }

    foreach ($capability in $capabilities) {
        if ($capability -isnot [string] -or $capability -notmatch '^[a-z0-9][a-z0-9-]*$') {
            throw "Windows profile '$Profile' contains invalid capability name '$capability'."
        }
        $capabilityPath = Join-Path $SourceCapabilitiesRoot "$capability.winget"
        if (-not (Test-Path -LiteralPath $capabilityPath -PathType Leaf)) {
            throw "Windows profile '$Profile' selects a missing capability: $capability."
        }
    }

    $duplicates = @(
        $capabilities |
            Group-Object |
            Where-Object Count -GT 1 |
            Select-Object -ExpandProperty Name
    )
    if ($duplicates.Count -gt 0) {
        throw "Windows profile '$Profile' repeats capabilities: $($duplicates -join ', ')."
    }
    if (($capabilities -contains 'preferences') -and $capabilities[-1] -ne 'preferences') {
        throw "Windows profile '$Profile' must select optional preferences last."
    }

    return $capabilities
}

function Stage-Configuration {
    param([Parameter(Mandatory)][string[]]$Capabilities)

    New-Item -ItemType Directory -Path $StagedCapabilitiesRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $StagedScriptsRoot -Force | Out-Null

    $profileSource = Join-Path $SourceProfilesRoot "$Profile.json"
    Copy-Item -LiteralPath $profileSource -Destination (Join-Path $StagingRoot 'profile.json') -Force

    foreach ($capability in $Capabilities) {
        $source = Join-Path $SourceCapabilitiesRoot "$capability.winget"
        Copy-Item -LiteralPath $source -Destination (Join-Path $StagedCapabilitiesRoot "$capability.winget") -Force
    }

    if ($Capabilities -contains 'development') {
        $extensions = Join-Path $SourceWindowsRoot 'vscode-extensions.json'
        $helper = Join-Path $PSScriptRoot 'windows-vscode.ps1'
        if (-not (Test-Path -LiteralPath $extensions -PathType Leaf)) {
            throw "The Windows VS Code extension declaration is missing: $extensions"
        }
        if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) {
            throw "The Windows VS Code helper is missing: $helper"
        }
        Copy-Item -LiteralPath $extensions -Destination $StagedCapabilitiesRoot -Force
        Copy-Item -LiteralPath $helper -Destination $StagedScriptsRoot -Force
    }
}

function Assert-WinGetConfigurationReadable {
    param(
        [Parameter(Mandatory)][string]$WinGet,
        [Parameter(Mandatory)][string]$ConfigurationPath
    )

    foreach ($attempt in 1, 2) {
        & $WinGet configure show --file $ConfigurationPath
        if ($LASTEXITCODE -eq 0) {
            return
        }
        if ($attempt -eq 1) {
            Write-Warning "WinGet could not initialize '$ConfigurationPath'; retrying once."
        }
    }

    throw "WinGet could not parse and resolve '$ConfigurationPath' after two attempts."
}

try {
    $currentBuild = [int](Get-ItemPropertyValue `
        -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' `
        -Name CurrentBuild)
    if ($currentBuild -lt 22000) {
        throw "This configuration requires Windows 11 (build 22000 or later); detected build $currentBuild."
    }
    if (-not (Test-CurrentUserCanSelfElevate)) {
        throw 'Run this profile from a Windows account that is itself a local administrator. Supplying a different account at UAC would apply per-user state to the wrong identity.'
    }

    $capabilities = @(Get-ProfileCapabilities)

    # WSL paths are UNC paths from Windows. Stage inputs locally and launch
    # WinGet from a native working directory.
    Set-Location -LiteralPath $env:SystemRoot

    $winGet = Get-WinGetCommand
    if ([string]::IsNullOrWhiteSpace($winGet)) {
        throw 'WinGet is unavailable. Install or repair Microsoft App Installer from the Microsoft Store, then rerun this script.'
    }

    $versionText = @(& $winGet --version) | Select-Object -First 1
    $winGetVersion = [version]($versionText.Trim().TrimStart('v'))
    if ($winGetVersion -lt $MinimumWinGetVersion) {
        throw "WinGet $MinimumWinGetVersion or later is required; detected $winGetVersion. Update App Installer first."
    }

    if ($Check) {
        $missingPrerequisites = @()
        if (-not (Test-VCRedistInstalled)) {
            $missingPrerequisites += 'Microsoft.VCRedist.2015+.x64'
        }
        if (-not (Test-DscV3ProcessorAvailable)) {
            $missingPrerequisites += 'the Microsoft DSC v3 processor'
        }
        if ($missingPrerequisites.Count -gt 0) {
            Write-Host "A read-only check cannot provision missing prerequisites: $($missingPrerequisites -join ', '). Run the profile once without -Check."
            exit 10
        }
    }
    elseif (-not (Test-VCRedistInstalled)) {
        Install-VCRedist -WinGet $winGet
    }

    Stage-Configuration -Capabilities $capabilities

    foreach ($capability in $capabilities) {
        $configurationPath = Join-Path $StagedCapabilitiesRoot "$capability.winget"
        Assert-WinGetConfigurationReadable `
            -WinGet $winGet `
            -ConfigurationPath $configurationPath
    }

    $testFailures = @()
    foreach ($capability in $capabilities) {
        $configurationPath = Join-Path $StagedCapabilitiesRoot "$capability.winget"
        if ($Check) {
            Write-Host "Testing Windows capability: $capability"
            & $winGet configure test `
                --file $configurationPath `
                --accept-configuration-agreements `
                --disable-interactivity
            if ($LASTEXITCODE -ne 0) {
                $testFailures += "$capability (exit $LASTEXITCODE)"
            }
        }
        else {
            Write-Host "Applying Windows capability: $capability"
            & $winGet configure `
                --file $configurationPath `
                --accept-configuration-agreements `
                --disable-interactivity
            if ($LASTEXITCODE -ne 0) {
                throw "WinGet capability '$capability' failed (exit $LASTEXITCODE). Review the unit results above and rerun after correcting the failure."
            }
        }
    }

    if ($Check) {
        if ($testFailures.Count -gt 0) {
            Write-Host "Windows profile '$Profile' is not in its declared state: $($testFailures -join ', ')."
            exit 10
        }
        Write-Host "Windows profile '$Profile' is in its declared state."
        exit 0
    }

    Write-Host ''
    Write-Host "Windows profile '$Profile' is complete."
    if ($capabilities -contains 'preferences') {
        Write-Host 'Sign out once (or restart Explorer) to make every Explorer and taskbar preference visible.'
    }
    Write-Host 'Exact taskbar pin ordering remains a short manual step; see windows/README.md.'
}
catch {
    Write-Error $_
    exit 1
}
