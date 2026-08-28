#Requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent $PSScriptRoot
$WindowsRoot = Join-Path $RepositoryRoot 'windows'
$CapabilitiesRoot = Join-Path $WindowsRoot 'capabilities'
$ProfilesRoot = Join-Path $WindowsRoot 'profiles'
$ExpectedSchema = '$schema: https://raw.githubusercontent.com/PowerShell/DSC/main/schemas/2023/08/config/document.json'

$powerShellFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot 'bootstrap') -Filter '*.ps1' -File
)
foreach ($file in $powerShellFiles) {
    $tokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) {
        $messages = @($parseErrors | ForEach-Object { $_.Message }) -join '; '
        throw "PowerShell syntax errors in $($file.FullName): $messages"
    }
}

$jsonFiles = @(Get-ChildItem -LiteralPath $WindowsRoot -Filter '*.json' -File -Recurse)
foreach ($file in $jsonFiles) {
    $null = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
}

$capabilityFiles = @(Get-ChildItem -LiteralPath $CapabilitiesRoot -Filter '*.winget' -File)
$capabilityNames = @($capabilityFiles | ForEach-Object BaseName)
$requiredCapabilities = @('base', 'development', 'gaming', 'preferences')
foreach ($required in $requiredCapabilities) {
    if ($capabilityNames -notcontains $required) {
        throw "Windows capabilities are missing '$required.winget'."
    }
}
if ($capabilityNames.Count -ne $requiredCapabilities.Count) {
    throw "Unexpected Windows capabilities are present: $($capabilityNames -join ', ')."
}

foreach ($file in $capabilityFiles) {
    $content = Get-Content -LiteralPath $file.FullName -Raw
    $schemaLines = @($content -split "`r?`n" | Where-Object { $_ -match '^\$schema:' })
    if ($schemaLines.Count -ne 1 -or $schemaLines[0] -ne $ExpectedSchema) {
        throw "Windows capability '$($file.Name)' must contain exactly '$ExpectedSchema'."
    }
    if ($content -notmatch '(?m)^resources:\s*$') {
        throw "Windows capability '$($file.Name)' does not declare resources."
    }
    if ($content -match '(?m)^\s+useLatest:') {
        throw "Windows capability '$($file.Name)' must declare package presence without useLatest."
    }

    $resourceNames = @(
        [regex]::Matches($content, '(?m)^\s{4}name:\s*(\S+)\s*$') |
            ForEach-Object { $_.Groups[1].Value }
    )
    $duplicateNames = @(
        $resourceNames |
            Group-Object |
            Where-Object Count -GT 1 |
            Select-Object -ExpandProperty Name
    )
    if ($duplicateNames.Count -gt 0) {
        throw "Windows capability '$($file.Name)' repeats resource names: $($duplicateNames -join ', ')."
    }
}

$base = Get-Content -LiteralPath (Join-Path $CapabilitiesRoot 'base.winget') -Raw
if ($base -match 'Microsoft\.Windows/Registry|Microsoft\.DSC\.Transitional') {
    throw 'The base capability must remain package-only.'
}

$preferences = Get-Content -LiteralPath (Join-Path $CapabilitiesRoot 'preferences.winget') -Raw
if ($preferences -match 'ClassicContextMenu|86ca1aa0-34aa-4e8b-a509-50c905bae2a2') {
    throw 'The preferences capability must not restore the undocumented classic context-menu hack.'
}
if ($preferences -notmatch '(?m)^\s+name: DisableRecallForMachine\s*$') {
    throw 'The optional preferences capability must retain the device-wide Recall policy.'
}

$development = Get-Content -LiteralPath (Join-Path $CapabilitiesRoot 'development.winget') -Raw
if ($development -match 'WindowsWSL|Microsoft\.WSL|windows-wsl\.ps1') {
    throw 'WSL installation is a documented prerequisite and must not return to Windows desired state.'
}
if ($development -notmatch '(?m)^\s+name: WindowsVSCode\s*$') {
    throw 'The development capability must retain Windows VS Code integration.'
}

$profiles = @(Get-ChildItem -LiteralPath $ProfilesRoot -Filter '*.json' -File)
if ($profiles.Count -eq 0) {
    throw 'At least one Windows profile must be declared.'
}
foreach ($file in $profiles) {
    if ($file.BaseName -notmatch '^[a-z0-9][a-z0-9-]*$') {
        throw "Invalid Windows profile filename: $($file.Name)"
    }

    $profile = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
    $selected = @($profile.capabilities)
    if ($selected.Count -eq 0 -or $selected[0] -ne 'base') {
        throw "Windows profile '$($file.BaseName)' must select base first."
    }

    $duplicates = @(
        $selected |
            Group-Object |
            Where-Object Count -GT 1 |
            Select-Object -ExpandProperty Name
    )
    if ($duplicates.Count -gt 0) {
        throw "Windows profile '$($file.BaseName)' repeats capabilities: $($duplicates -join ', ')."
    }
    foreach ($capability in $selected) {
        if ($capability -isnot [string] -or $capabilityNames -notcontains $capability) {
            throw "Windows profile '$($file.BaseName)' selects missing capability '$capability'."
        }
    }
    if (($selected -contains 'preferences') -and $selected[-1] -ne 'preferences') {
        throw "Windows profile '$($file.BaseName)' must select optional preferences last."
    }
}

Write-Host "Validated $($powerShellFiles.Count) PowerShell files, $($jsonFiles.Count) JSON files, $($capabilityFiles.Count) capabilities, and $($profiles.Count) profiles."
