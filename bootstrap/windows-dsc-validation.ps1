#Requires -Version 5.1

Set-StrictMode -Version Latest

$script:WinGetDscSchemaUri = 'https://raw.githubusercontent.com/PowerShell/DSC/main/schemas/2023/08/config/document.json'
$script:BundledDscSchemaUri = 'https://aka.ms/dsc/schemas/v3/bundled/config/document.json'

function ConvertTo-DscValidationDocument {
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$ConfigurationPath
    )

    $schemaLines = @(
        $Content -split "`r?`n" |
            Where-Object { $_ -match '^\$schema:' }
    )
    $expectedSchemaLine = "`$schema: $script:WinGetDscSchemaUri"
    if ($schemaLines.Count -ne 1 -or $schemaLines[0] -ne $expectedSchemaLine) {
        throw "WinGet configuration '$ConfigurationPath' must contain exactly '$expectedSchemaLine'."
    }

    # WinGet uses the raw 2023/08 URI as its hard-coded DSC v3 / version 0.3
    # discriminator. Stable DSC 3.2.3 accepts the same document model only under
    # its canonical bundled URI, so normalize an ephemeral validation copy.
    # The deployable document is never rewritten or replaced with this copy.
    $validationSchemaLine = "`$schema: $script:BundledDscSchemaUri"
    return $Content.Replace($expectedSchemaLine, $validationSchemaLine)
}

function Assert-DscValidationResult {
    param(
        [Parameter(Mandatory)][string[]]$Output,
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][string]$ConfigurationPath
    )

    if ($ExitCode -ne 0) {
        throw "Microsoft DSC could not validate '$ConfigurationPath' (exit $ExitCode)."
    }

    $rawResult = $Output -join "`n"
    try {
        $result = $rawResult | ConvertFrom-Json
    }
    catch {
        throw "Microsoft DSC returned an unreadable validation result for '$ConfigurationPath': $rawResult"
    }

    if ($null -eq $result) {
        throw "Microsoft DSC returned an empty validation result for '$ConfigurationPath'."
    }
    $validProperty = $result.PSObject.Properties['valid']
    if ($null -eq $validProperty -or $validProperty.Value -isnot [bool]) {
        throw "Microsoft DSC returned a validation result without a Boolean 'valid' field for '$ConfigurationPath': $rawResult"
    }
    if (-not $validProperty.Value) {
        $reasonProperty = $result.PSObject.Properties['reason']
        $reason = if ($null -ne $reasonProperty -and -not [string]::IsNullOrWhiteSpace($reasonProperty.Value)) {
            $reasonProperty.Value
        }
        else {
            'DSC reported valid=false; review the validation errors above.'
        }
        throw "Microsoft DSC rejected '$ConfigurationPath': $reason"
    }
}

function Assert-DscConfigurationValid {
    param(
        [Parameter(Mandatory)][string]$DscCommand,
        [Parameter(Mandatory)][string]$ConfigurationPath
    )

    $content = Get-Content -LiteralPath $ConfigurationPath -Raw
    $validationContent = ConvertTo-DscValidationDocument `
        -Content $content `
        -ConfigurationPath $ConfigurationPath

    $tempRoot = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        "caz-nix-dsc-validation-$PID-$([guid]::NewGuid().ToString('N'))"
    $validationPath = Join-Path $tempRoot ([System.IO.Path]::GetFileName($ConfigurationPath))
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($validationPath, $validationContent, $utf8NoBom)

        $output = @(
            & $DscCommand config validate `
                --file $validationPath `
                --output-format json
        )
        $exitCode = $LASTEXITCODE
        Assert-DscValidationResult `
            -Output $output `
            -ExitCode $exitCode `
            -ConfigurationPath $ConfigurationPath
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

function Assert-WinGetConfigurationReadable {
    param(
        [Parameter(Mandatory)][string]$WinGetCommand,
        [Parameter(Mandatory)][string]$ConfigurationPath
    )

    $output = @(& $WinGetCommand configure show --file $ConfigurationPath)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        if ($output.Count -gt 0) {
            Write-Host ($output -join "`n")
        }
        throw "WinGet could not parse and resolve configuration '$ConfigurationPath' (exit $exitCode)."
    }
}
