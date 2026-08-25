#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$AppListPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'debloat-appx.json'
$ProtectedExactIds = @(
    'Microsoft.DesktopAppInstaller',
    'Microsoft.GamingApp',
    'Microsoft.GetHelp',
    'Microsoft.StorePurchaseApp',
    'Microsoft.Windows.Photos',
    'Microsoft.WindowsCalculator',
    'Microsoft.WindowsNotepad',
    'Microsoft.WindowsStore',
    'Microsoft.WindowsTerminal',
    'Microsoft.XboxIdentityProvider',
    'Microsoft.XboxSpeechToTextOverlay',
    'MicrosoftWindows.Client.WebExperience'
)

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-RemovalState {
    param([Parameter(Mandatory)][object[]]$Apps)

    $installed = @(Get-AppxPackage -AllUsers -ErrorAction Stop)
    $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop)
    $state = @()

    foreach ($app in $Apps) {
        $installedMatches = @(
            $installed |
                Where-Object {
                    $_.Name -eq $app.id -and $_.NonRemovable -ne $true
                }
        )
        $provisionedMatches = @(
            $provisioned | Where-Object DisplayName -EQ $app.id
        )

        if ($installedMatches.Count -gt 0 -or $provisionedMatches.Count -gt 0) {
            $state += [pscustomobject]@{
                App = $app
                Installed = $installedMatches
                Provisioned = $provisionedMatches
            }
        }
    }

    return @($state)
}

if (-not (Test-Path -LiteralPath $AppListPath)) {
    throw "The curated Appx removal list is missing at $AppListPath."
}
if (-not (Test-Administrator)) {
    throw 'The Windows debloat helper must run as Administrator so it can reconcile provisioned and all-user Appx packages.'
}

$apps = @(Get-Content -LiteralPath $AppListPath -Raw | ConvertFrom-Json)
if ($apps.Count -eq 0) {
    throw "The curated Appx removal list at $AppListPath is empty."
}

$duplicateIds = @(
    $apps |
        Group-Object id |
        Where-Object Count -GT 1 |
        Select-Object -ExpandProperty Name
)
if ($duplicateIds.Count -gt 0) {
    throw "The Appx removal list contains duplicate identifiers: $($duplicateIds -join ', ')"
}

foreach ($app in $apps) {
    if ([string]::IsNullOrWhiteSpace($app.id) -or [string]::IsNullOrWhiteSpace($app.name)) {
        throw 'Every debloat entry must contain non-empty id and name fields.'
    }
    if ($ProtectedExactIds -contains $app.id -or $app.id -like 'Microsoft.Xbox*') {
        throw "The curated debloat list attempts to remove protected gaming or Windows package '$($app.id)'."
    }
}

$remaining = @(Get-RemovalState -Apps $apps)
if ($Check) {
    if ($remaining.Count -eq 0) {
        Write-Host 'Curated Windows Appx bloat is absent.'
        exit 0
    }

    Write-Host 'Curated Windows Appx packages still present:'
    foreach ($entry in $remaining) {
        Write-Host "  $($entry.App.name) [$($entry.App.id)]"
    }
    exit 10
}

foreach ($entry in $remaining) {
    foreach ($package in @($entry.Installed | Sort-Object PackageFullName -Unique)) {
        Write-Host "Removing installed Appx package: $($entry.App.name) [$($package.Name)]"
        Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop
    }

    foreach ($package in @($entry.Provisioned | Sort-Object PackageName -Unique)) {
        Write-Host "Removing provisioned Appx package: $($entry.App.name) [$($package.DisplayName)]"
        $result = Remove-AppxProvisionedPackage `
            -Online `
            -PackageName $package.PackageName `
            -AllUsers `
            -ErrorAction Stop
        if (-not $result.Online) {
            throw "Windows did not confirm online removal of $($package.PackageName)."
        }
    }
}

$remaining = @(Get-RemovalState -Apps $apps)
if ($remaining.Count -gt 0) {
    $names = @($remaining | ForEach-Object { $_.App.name }) -join ', '
    throw "These curated Appx packages remain after removal: $names"
}

Write-Host 'Curated Windows Appx bloat is absent.'
