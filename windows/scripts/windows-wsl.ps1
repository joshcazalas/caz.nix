#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Distribution = 'Ubuntu-24.04'

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-WslComponentsReady {
    $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='vmcompute'" -ErrorAction SilentlyContinue
    return $null -ne $service
}

function Get-WslDistributions {
    $env:WSL_UTF8 = '1'
    $stdout = [System.IO.Path]::GetTempFileName()
    $stderr = [System.IO.Path]::GetTempFileName()
    try {
        $process = Start-Process `
            -FilePath 'wsl.exe' `
            -ArgumentList '--list', '--quiet' `
            -NoNewWindow `
            -Wait `
            -PassThru `
            -RedirectStandardOutput $stdout `
            -RedirectStandardError $stderr
        if ($process.ExitCode -ne 0) {
            return @()
        }

        return @(
            Get-Content -LiteralPath $stdout -Encoding UTF8 |
                ForEach-Object { ($_ -replace "`0", '').Trim() } |
                Where-Object { $_ }
        )
    }
    finally {
        Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
    }
}

function Get-WslDistributionVersion {
    $env:WSL_UTF8 = '1'
    $stdout = [System.IO.Path]::GetTempFileName()
    $stderr = [System.IO.Path]::GetTempFileName()
    try {
        $process = Start-Process `
            -FilePath 'wsl.exe' `
            -ArgumentList '--list', '--verbose' `
            -NoNewWindow `
            -Wait `
            -PassThru `
            -RedirectStandardOutput $stdout `
            -RedirectStandardError $stderr
        if ($process.ExitCode -ne 0) {
            return $null
        }

        $escapedDistribution = [regex]::Escape($Distribution)
        foreach ($line in Get-Content -LiteralPath $stdout -Encoding UTF8) {
            $normalized = ($line -replace "`0", '')
            if ($normalized -match "^\s*\*?\s*$escapedDistribution\s+.+\s+(?<version>[12])\s*$") {
                return [int]$Matches.version
            }
        }
        return $null
    }
    finally {
        Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
    }
}

$componentsReady = Test-WslComponentsReady
$distributions = if ($componentsReady) { @(Get-WslDistributions) } else { @() }
$distributionReady = $distributions -contains $Distribution
$distributionVersion = if ($distributionReady) { Get-WslDistributionVersion } else { $null }

if ($Check) {
    Write-Host "WSL 2 components active: $componentsReady"
    Write-Host "$Distribution registered: $distributionReady"
    if ($distributionReady) {
        Write-Host "$Distribution WSL version: $distributionVersion"
    }
    if ($componentsReady -and $distributionReady -and $distributionVersion -eq 2) {
        exit 0
    }
    exit 10
}

if (-not (Test-Administrator)) {
    throw 'The WSL capability must run in the elevated DSC security context.'
}

if (-not $componentsReady) {
    Write-Host 'Enabling WSL and Virtual Machine Platform without installing a distribution...'
    $process = Start-Process `
        -FilePath 'wsl.exe' `
        -ArgumentList '--install', '--no-distribution' `
        -Wait `
        -PassThru
    if ($process.ExitCode -notin @(0, 1641, 3010)) {
        throw "wsl --install --no-distribution failed with exit code $($process.ExitCode)."
    }

    if (-not (Test-WslComponentsReady)) {
        Write-Warning 'WSL components were enabled, but Windows must restart before configuration can continue.'
        exit 20
    }
}

$distributions = @(Get-WslDistributions)
if ($distributions -notcontains $Distribution) {
    Write-Host "Installing $Distribution without launching first-run setup..."
    $process = Start-Process `
        -FilePath 'wsl.exe' `
        -ArgumentList '--install', '-d', $Distribution, '--no-launch' `
        -Wait `
        -PassThru
    if ($process.ExitCode -ne 0) {
        throw "wsl --install -d $Distribution --no-launch failed with exit code $($process.ExitCode)."
    }
}

if (@(Get-WslDistributions) -notcontains $Distribution) {
    throw "$Distribution was installed, but wsl --list does not report it as registered."
}

$distributionVersion = Get-WslDistributionVersion
if ($distributionVersion -eq 1) {
    Write-Host "Converting $Distribution from WSL 1 to WSL 2. This can take several minutes..."
    $process = Start-Process `
        -FilePath 'wsl.exe' `
        -ArgumentList '--set-version', $Distribution, '2' `
        -Wait `
        -PassThru
    if ($process.ExitCode -ne 0) {
        throw "wsl --set-version $Distribution 2 failed with exit code $($process.ExitCode)."
    }
}
elseif ($distributionVersion -ne 2) {
    throw "Could not determine the WSL version registered for $Distribution."
}

if ((Get-WslDistributionVersion) -ne 2) {
    throw "$Distribution is registered, but Windows did not confirm it as WSL 2."
}

Write-Host "WSL 2 and $Distribution are ready."
