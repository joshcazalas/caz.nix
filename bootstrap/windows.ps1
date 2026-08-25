#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$Check,

    [switch]$Prepare,

    [ValidatePattern('^[a-z0-9][a-z0-9-]*$')]
    [string]$Profile = 'workstation'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$MinimumWinGetVersion = [version]'1.11.430'
$MinimumDscVersion = [version]'3.2.3'
$DscBundleUri = 'https://github.com/PowerShell/DSC/releases/download/v3.2.3/DSC-3.2.3-Win.msixbundle'
$DscBundleSha256 = '86ceaa0cfba4ea225bd50f3187595a9fcb2e900c0601d0aeadd51023ea967a40'
$RepositoryRoot = Split-Path -Parent $PSScriptRoot
$SourceWindowsRoot = Join-Path $RepositoryRoot 'windows'
$SourceCapabilitiesRoot = Join-Path $SourceWindowsRoot 'capabilities'
$SourceProfilesRoot = Join-Path $SourceWindowsRoot 'profiles'
$DscValidationScript = Join-Path $PSScriptRoot 'windows-dsc-validation.ps1'
$StagingRoot = Join-Path $env:LOCALAPPDATA "caz.nix\windows\$Profile"
$StagedCapabilitiesRoot = Join-Path $StagingRoot 'capabilities'
$StagedScriptsRoot = Join-Path $StagedCapabilitiesRoot 'scripts'

if (-not (Test-Path -LiteralPath $DscValidationScript -PathType Leaf)) {
    throw "The Microsoft DSC validation helper is missing: $DscValidationScript"
}
. $DscValidationScript

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

function Invoke-WinGetInstall {
    param(
        [Parameter(Mandatory)][string]$WinGet,
        [Parameter(Mandatory)][string]$Id
    )

    Write-Host "Installing prerequisite package $Id..."
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

function Test-StableDscInstalled {
    $package = Get-AppxPackage -Name 'Microsoft.DesiredStateConfiguration' -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if ($null -eq $package -or $package.Status -ne 'Ok') {
        return $false
    }

    return [version]$package.Version -ge $MinimumDscVersion
}

function Get-StableDscCommand {
    $package = Get-AppxPackage -Name 'Microsoft.DesiredStateConfiguration' -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if ($null -eq $package -or $package.Status -ne 'Ok' -or [version]$package.Version -lt $MinimumDscVersion) {
        throw "Healthy stable Microsoft DSC $MinimumDscVersion or later is required."
    }

    $candidate = Join-Path $package.InstallLocation 'dsc.exe'
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Microsoft DSC is registered, but dsc.exe is missing from $($package.InstallLocation)."
    }
    return $candidate
}

function Install-StableDsc {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "caz-nix-dsc-$PID"
    $bundlePath = Join-Path $tempRoot "DSC-$MinimumDscVersion-Win.msixbundle"

    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Write-Host "Downloading Microsoft DSC $MinimumDscVersion from its official release..."
        Invoke-WebRequest -Uri $DscBundleUri -OutFile $bundlePath -UseBasicParsing

        $actualHash = (Get-FileHash -LiteralPath $bundlePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $DscBundleSha256) {
            throw "Microsoft DSC bundle checksum mismatch. Expected $DscBundleSha256, received $actualHash."
        }

        Add-AppxPackage -Path $bundlePath -ErrorAction Stop
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }

    if (-not (Test-StableDscInstalled)) {
        throw "Microsoft DSC $MinimumDscVersion was installed, but its stable Appx registration is not healthy for the current user."
    }
}

function Get-ProfileCapabilities {
    $profilePath = Join-Path $SourceProfilesRoot "$Profile.json"
    if (-not (Test-Path -LiteralPath $profilePath)) {
        $available = @(
            Get-ChildItem -LiteralPath $SourceProfilesRoot -Filter '*.json' -File |
                ForEach-Object BaseName |
                Sort-Object
        )
        throw "Unknown Windows profile '$Profile'. Available profiles: $($available -join ', ')."
    }

    $declaration = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
    $capabilities = @($declaration.capabilities)
    if ($capabilities.Count -eq 0) {
        throw "Windows profile '$Profile' must select at least one capability."
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
    if ($capabilities[0] -ne 'base') {
        throw "Windows profile '$Profile' must select the base capability first."
    }

    return $capabilities
}

function Stage-Configuration {
    param([Parameter(Mandatory)][string[]]$Capabilities)

    New-Item -ItemType Directory -Path $StagingRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $StagedCapabilitiesRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $StagedScriptsRoot -Force | Out-Null

    $profileSource = Join-Path $SourceProfilesRoot "$Profile.json"
    Copy-Item -LiteralPath $profileSource -Destination (Join-Path $StagingRoot 'profile.json') -Force

    foreach ($capability in $Capabilities) {
        $source = Join-Path $SourceCapabilitiesRoot "$capability.winget"
        if (-not (Test-Path -LiteralPath $source)) {
            throw "Capability '$capability' is missing its configuration file: $source"
        }
        Copy-Item -LiteralPath $source -Destination (Join-Path $StagedCapabilitiesRoot "$capability.winget") -Force
    }

    $dataFiles = @()
    if ($Capabilities -contains 'development') {
        $dataFiles += 'vscode-extensions.json'
    }
    if ($Capabilities -contains 'debloat') {
        $dataFiles += 'debloat-appx.json'
    }
    foreach ($file in $dataFiles) {
        $source = Join-Path $SourceWindowsRoot $file
        if (-not (Test-Path -LiteralPath $source)) {
            throw "Required Windows capability data is missing: $source"
        }
        Copy-Item -LiteralPath $source -Destination (Join-Path $StagedCapabilitiesRoot $file) -Force
    }

    $scriptSources = @()
    if ($Capabilities -contains 'base') {
        $scriptSources += Join-Path $PSScriptRoot 'windows-font.ps1'
    }
    if ($Capabilities -contains 'development') {
        $scriptSources += Join-Path $SourceWindowsRoot 'scripts\windows-wsl.ps1'
        $scriptSources += Join-Path $PSScriptRoot 'windows-vscode.ps1'
    }
    if ($Capabilities -contains 'debloat') {
        $scriptSources += Join-Path $SourceWindowsRoot 'scripts\windows-debloat.ps1'
    }
    foreach ($source in $scriptSources) {
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "Required Windows capability helper is missing: $source"
        }
        Copy-Item -LiteralPath $source -Destination $StagedScriptsRoot -Force
    }
}

try {
    if ($Check -and $Prepare) {
        throw 'Choose either -Check or -Prepare, not both.'
    }

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

    # WSL paths are UNC paths from Windows. Move to a native working directory
    # before launching WinGet and stage all inputs locally.
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
    if ($winGetVersion -ge [version]'1.29.0' -and $winGetVersion -lt [version]'1.29.280') {
        throw "WinGet $winGetVersion contains a known DSC v3 elevation regression. Update to WinGet 1.29.280 or later."
    }

    if ($Check) {
        $missingPrerequisites = @()
        if (-not (Test-VCRedistInstalled)) {
            $missingPrerequisites += 'Microsoft.VCRedist.2015+.x64'
        }
        if (-not (Test-StableDscInstalled)) {
            $missingPrerequisites += "Microsoft.DSC $MinimumDscVersion+ (stable)"
        }
        if ($missingPrerequisites.Count -gt 0) {
            Write-Host "Windows configuration prerequisites are missing: $($missingPrerequisites -join ', ')"
            exit 10
        }
    }
    else {
        if (-not (Test-VCRedistInstalled)) {
            Invoke-WinGetInstall -WinGet $winGet -Id 'Microsoft.VCRedist.2015+.x64'
        }
        if (-not (Test-StableDscInstalled)) {
            Install-StableDsc
        }
    }

    Stage-Configuration -Capabilities $capabilities
    $dsc = Get-StableDscCommand

    foreach ($capability in $capabilities) {
        $configurationPath = Join-Path $StagedCapabilitiesRoot "$capability.winget"
        Assert-WinGetConfigurationReadable `
            -WinGetCommand $winGet `
            -ConfigurationPath $configurationPath
        Assert-DscConfigurationValid `
            -DscCommand $dsc `
            -ConfigurationPath $configurationPath
    }

    if ($Prepare) {
        Write-Host "Windows profile '$Profile' prerequisites are ready and every capability document is valid."
        Write-Host 'No declared Windows state was applied.'
        exit 0
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
    Write-Host 'Sign out once (or restart Explorer) to make every Explorer and taskbar preference visible.'
    Write-Host 'Exact taskbar pin ordering remains a short manual step; see windows/README.md.'
}
catch {
    Write-Error $_
    exit 1
}
