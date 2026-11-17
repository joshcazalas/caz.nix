#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$bootstrap = Join-Path (Split-Path -Parent $PSScriptRoot) 'bootstrap'
$fixture = Join-Path ([IO.Path]::GetTempPath()) "caz bootstrap $([guid]::NewGuid())"
$localAppData = $env:LOCALAPPDATA
$programFiles = $env:ProgramFiles

function Get-TestGroups {
    Set-Variable -Scope 1 -Name LASTEXITCODE -Value $whoamiExit
    $whoamiRows
}
Set-Alias -Name (Join-Path $env:SystemRoot 'System32\whoami.exe') -Value Get-TestGroups
$whoamiExit = 0
$adminRow = '"Administrateurs","Alias","S-1-5-32-544","Deny only"'
$otherRow = '"S-1-5-32-544","Alias","S-1-5-32-5440","Enabled"'

try {
    $null = New-Item -ItemType Directory -Path $fixture
    $env:LOCALAPPDATA = $fixture
    $env:ProgramFiles = $fixture

    & {
        . (Join-Path $bootstrap 'windows-common.ps1')
        $whoamiRows = @($otherRow, $adminRow)
        if (-not (Test-CurrentUserCanSelfElevate)) { throw 'Filtered administrator membership was missed.' }
        $whoamiRows = @($otherRow)
        if (Test-CurrentUserCanSelfElevate) { throw 'A different SID was accepted as an administrator.' }
        $whoamiRows = @()
        if (Test-CurrentUserCanSelfElevate) { throw 'Empty group output was accepted as an administrator.' }
        $whoamiExit = 1
        try {
            $null = Test-CurrentUserCanSelfElevate
            throw 'A failed group lookup was accepted.'
        }
        catch { if ($_.Exception.Message -notlike '*with whoami.exe.*') { throw } }

        $appFolder = Join-Path $fixture 'App Installer'
        $null = New-Item -ItemType Directory -Path $appFolder
        $appExe = (New-Item -ItemType File -Path (Join-Path $appFolder 'winget.exe')).FullName
        $pathExe = (New-Item -ItemType File -Path (Join-Path $fixture 'winget.exe')).FullName
        function Get-Command { [pscustomobject]@{ Source = $pathExe } }
        function Get-AppxPackage {
            [pscustomobject]@{ Version = [version]'1.2'; InstallLocation = $fixture }
            [pscustomobject]@{ Version = [version]'1.10'; InstallLocation = $appFolder }
        }

        if ((Get-WinGetCommand) -ne $pathExe) { throw 'The WinGet executable on PATH should win.' }
        Remove-Item -LiteralPath $pathExe
        if ((Get-WinGetCommand) -ne $appExe) { throw 'Failed to find the newest App Installer executable.' }
        Remove-Item -LiteralPath $appExe
        if ($null -ne (Get-WinGetCommand)) { throw 'A missing executable was returned.' }
    }

    # Run each entry point with a synthetic Windows build and account.
    function Get-ItemPropertyValue { return 22621 }
    $whoamiRows = @($otherRow)
    try {
        & (Join-Path $bootstrap 'windows.ps1') -Check
        throw 'The workstation bootstrap accepted a standard user.'
    }
    catch { if ($_.Exception.Message -notlike 'Run this profile from a Windows account*') { throw } }

    $source = (New-Item -ItemType Directory -Path (Join-Path $fixture 'source')).FullName
    Copy-Item -LiteralPath (Join-Path $bootstrap 'windows-game-stream.ps1') -Destination $source
    $common = Join-Path $source 'windows-common.ps1'
    Copy-Item -LiteralPath (Join-Path $bootstrap 'windows-common.ps1') -Destination $common
    # Simulate a filtered parent and an elevated child in the test copy.
    Add-Content -LiteralPath $common -Value 'function Test-IsAdministrator { return [bool]$ResultPath }'
    function Start-Process {
        param($FilePath, $ArgumentList, $Verb, [switch]$Wait, [switch]$PassThru)
        if ($FilePath -ne 'powershell.exe' -or $Verb -ne 'RunAs' -or -not ($Wait -and $PassThru)) {
            throw 'Unexpected game-stream elevation request.'
        }
        if ($ArgumentList -notmatch '-File "([^"]+)" -Role Client -ResultPath "([^"]+)" -Check$') {
            throw 'The staged check arguments were lost.'
        }
        $entry = $Matches[1]
        $result = $Matches[2]
        if ((Split-Path -Parent $entry) -eq $source) { throw 'Expected a staged entry point.' }
        & $entry -Role Client -ResultPath $result -Check
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE }
    }
    $whoamiRows = @($adminRow)
    $output = & (Join-Path $source 'windows-game-stream.ps1') -Role Client -Check 6>&1
    if ($LASTEXITCODE -ne 1 -or "$output" -notmatch 'Moonlight is not installed' -or
        "$output" -notmatch 'WireGuard is not installed') {
        throw "The staged client check did not return the missing packages: $output"
    }
}
finally {
    $env:LOCALAPPDATA = $localAppData
    $env:ProgramFiles = $programFiles
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}

Write-Host 'Validated Windows bootstrap discovery, administrator membership, and the staged game-stream check.'
# The staged check deliberately exits 1 for missing packages. Report the fixture result to CI.
exit 0
