#Requires -Version 5.1

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-CurrentUserCanSelfElevate {
    $whoAmI = Join-Path $env:SystemRoot 'System32\whoami.exe'
    $groups = @(& $whoAmI /groups /fo csv /nh 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not inspect the current Windows security groups with whoami.exe.'
    }

    # A filtered administrator token still lists the group as deny-only.
    $groupSids = $groups | ConvertFrom-Csv -Header Name, Type, Sid, Attributes |
        Select-Object -ExpandProperty Sid
    return $groupSids -contains 'S-1-5-32-544'
}

function Get-WinGetCommand {
    $command = Get-Command 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $command -and (Test-Path -LiteralPath $command.Source -PathType Leaf)) {
        return $command.Source
    }

    $appInstaller = Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if ($null -ne $appInstaller) {
        $candidate = Join-Path $appInstaller.InstallLocation 'winget.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    return $null
}
