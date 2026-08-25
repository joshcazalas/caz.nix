#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ExtensionsFile,

    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# WSL starts Windows processes from a UNC working directory. Batch launchers
# such as code.cmd reject that location even though their absolute paths work.
Set-Location -LiteralPath $env:SystemRoot

$PackageId = 'Microsoft.VisualStudioCode'
$ExtensionIdPattern = '^[A-Za-z0-9][A-Za-z0-9-]*\.[A-Za-z0-9][A-Za-z0-9.-]*$'

function Get-VSCodeCommand {
    $pathCommand = Get-Command 'code.cmd' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $pathCommand -and (Test-Path -LiteralPath $pathCommand.Source)) {
        return $pathCommand.Source
    }

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'),
        (Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd')
    )
    $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) {
        $candidates += Join-Path $programFilesX86 'Microsoft VS Code\bin\code.cmd'
    }

    return ($candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)
}

function Install-VSCode {
    $wingetCommand = Get-Command 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $wingetCommand) {
        throw 'WinGet is required to install Windows VS Code. Install or repair Microsoft App Installer, then reapply the Windows profile.'
    }

    Write-Host 'Installing the Windows user-scoped Visual Studio Code client with WinGet...'
    & $wingetCommand.Source install `
        --id $PackageId `
        --exact `
        --source winget `
        --scope user `
        --silent `
        --accept-package-agreements `
        --accept-source-agreements `
        --disable-interactivity
    if ($LASTEXITCODE -ne 0) {
        throw "WinGet failed to install $PackageId (exit $LASTEXITCODE)."
    }
}

function Get-RequestedExtensions {
    if (-not (Test-Path -LiteralPath $ExtensionsFile)) {
        throw "The Windows extension declaration is missing at $ExtensionsFile."
    }

    $parsed = Get-Content -LiteralPath $ExtensionsFile -Raw | ConvertFrom-Json
    $extensions = @($parsed)
    foreach ($extension in $extensions) {
        if ($extension -isnot [string] -or $extension -notmatch $ExtensionIdPattern) {
            throw "Invalid VS Code extension identifier in ${ExtensionsFile}: $extension"
        }
    }

    return @($extensions | Sort-Object -Unique)
}

function Get-InstalledExtensions {
    param([Parameter(Mandatory)][string]$CodeCommand)

    $output = @(& $CodeCommand --list-extensions)
    if ($LASTEXITCODE -ne 0) {
        throw "VS Code could not list its Windows-side extensions (exit $LASTEXITCODE)."
    }
    return @($output | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

$codeCommand = Get-VSCodeCommand
if ([string]::IsNullOrWhiteSpace($codeCommand)) {
    if ($Check) {
        Write-Host 'Windows VS Code is not installed.'
        exit 10
    }
    Install-VSCode
    $codeCommand = Get-VSCodeCommand
}
if ([string]::IsNullOrWhiteSpace($codeCommand)) {
    throw 'Windows VS Code was installed, but its code.cmd launcher could not be found.'
}

$requestedExtensions = @(Get-RequestedExtensions)
$installedExtensions = @(Get-InstalledExtensions -CodeCommand $codeCommand)
$missingExtensions = @($requestedExtensions | Where-Object { $installedExtensions -notcontains $_ })

if ($Check) {
    if ($missingExtensions.Count -gt 0) {
        Write-Host "Windows VS Code is missing declared extensions: $($missingExtensions -join ', ')"
        exit 10
    }
    Write-Host "Windows VS Code is configured at $codeCommand."
    exit 0
}

foreach ($extension in $missingExtensions) {
    Write-Host "Installing Windows VS Code extension: $extension"
    & $codeCommand --install-extension $extension --force
    if ($LASTEXITCODE -ne 0) {
        throw "VS Code failed to install extension $extension (exit $LASTEXITCODE)."
    }
}

$installedExtensions = @(Get-InstalledExtensions -CodeCommand $codeCommand)
$missingExtensions = @($requestedExtensions | Where-Object { $installedExtensions -notcontains $_ })
if ($missingExtensions.Count -gt 0) {
    throw "Windows VS Code did not report these extensions as installed: $($missingExtensions -join ', ')"
}

Write-Host "Windows VS Code is configured at $codeCommand."
