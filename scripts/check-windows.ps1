#Requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Parent $PSScriptRoot
$WindowsRoot = Join-Path $RepositoryRoot 'windows'
$CapabilitiesRoot = Join-Path $WindowsRoot 'capabilities'
$ProfilesRoot = Join-Path $WindowsRoot 'profiles'

$powerShellFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot 'bootstrap') -Filter '*.ps1' -File
    Get-ChildItem -LiteralPath (Join-Path $WindowsRoot 'scripts') -Filter '*.ps1' -File
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

. (Join-Path $RepositoryRoot 'bootstrap\windows-dsc-validation.ps1')

$winGetDocument = @"
`$schema: https://raw.githubusercontent.com/PowerShell/DSC/main/schemas/2023/08/config/document.json
resources: []
"@
$dscValidationDocument = ConvertTo-DscValidationDocument `
    -Content $winGetDocument `
    -ConfigurationPath 'intentional-schema-normalization-test.winget'
if ($dscValidationDocument -notmatch [regex]::Escape('https://aka.ms/dsc/schemas/v3/bundled/config/document.json')) {
    throw 'The DSC validation copy did not receive the bundled DSC schema URI.'
}
if ($dscValidationDocument -match [regex]::Escape('raw.githubusercontent.com/PowerShell/DSC/main/schemas/2023/08')) {
    throw 'The DSC validation copy retained WinGet''s operational schema URI.'
}

$nonWinGetSchemaRejected = $false
try {
    $null = ConvertTo-DscValidationDocument `
        -Content $dscValidationDocument `
        -ConfigurationPath 'intentional-winget-incompatible-schema-test.winget'
}
catch {
    $nonWinGetSchemaRejected = $true
}
if (-not $nonWinGetSchemaRejected) {
    throw 'The schema normalizer accepted a document WinGet cannot dispatch as DSC v3.'
}

Assert-DscValidationResult `
    -Output '{"valid":true,"reason":null}' `
    -ExitCode 0 `
    -ConfigurationPath 'intentional-valid-test.winget'

$falseResultRejected = $false
try {
    Assert-DscValidationResult `
        -Output '{"valid":false,"reason":"intentional regression test"}' `
        -ExitCode 0 `
        -ConfigurationPath 'intentional-invalid-test.winget'
}
catch {
    $falseResultRejected = $true
}
if (-not $falseResultRejected) {
    throw 'The DSC validation wrapper accepted valid=false.'
}

& (Join-Path $RepositoryRoot 'bootstrap\windows-font.ps1') -SelfTest

$fontHelper = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'bootstrap\windows-font.ps1') -Raw
if ($fontHelper -match '\bGet-ItemPropertyValue\b') {
    throw 'The font helper must inspect optional registry values without Get-ItemPropertyValue, which emits errors for missing properties.'
}

$jsonFiles = @(Get-ChildItem -LiteralPath $WindowsRoot -Filter '*.json' -File -Recurse)
foreach ($file in $jsonFiles) {
    $null = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
}

$capabilityFiles = @(Get-ChildItem -LiteralPath $CapabilitiesRoot -Filter '*.winget' -File)
$capabilityNames = @($capabilityFiles | ForEach-Object BaseName)
if ($capabilityNames.Count -eq 0 -or $capabilityNames -notcontains 'base') {
    throw 'Windows capabilities must contain base.winget.'
}
foreach ($file in $capabilityFiles) {
    $null = ConvertTo-DscValidationDocument `
        -Content (Get-Content -LiteralPath $file.FullName -Raw) `
        -ConfigurationPath $file.FullName
}

$baseCapabilityPath = Join-Path $CapabilitiesRoot 'base.winget'
$baseCapability = Get-Content -LiteralPath $baseCapabilityPath -Raw
$spotifyResource = [regex]::Match(
    $baseCapability,
    '(?ms)^\s{2}- type: Microsoft\.WinGet/Package\s+name: Spotify\s+.*?(?=^\s{2}- type:|\z)'
)
if (-not $spotifyResource.Success) {
    throw 'The base capability must declare Spotify.'
}
if ($spotifyResource.Value -match '(?m)^\s+useLatest:') {
    throw 'Spotify must not useLatest because its evergreen installer URL can temporarily disagree with the community manifest hash.'
}
if ($baseCapability -match '(?m)^\s+name: DisableRecallForUser\s*$') {
    throw 'The base capability must not duplicate the device-wide Recall policy in the access-controlled per-user Policies subtree.'
}
if ($baseCapability -notmatch '(?m)^\s+name: DisableRecallForMachine\s*$') {
    throw 'The base capability must retain the device-wide Recall policy.'
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

    $selectsDebloat = $selected -contains 'debloat'
    $advertisesDebloat = $file.BaseName.EndsWith('-debloated')
    if ($selectsDebloat -ne $advertisesDebloat) {
        throw "Windows profile '$($file.BaseName)' must advertise destructive debloat selection with a -debloated suffix."
    }
}

Write-Host "Validated $($powerShellFiles.Count) PowerShell files, $($jsonFiles.Count) JSON files, $($capabilityFiles.Count) capabilities, and $($profiles.Count) profiles."
