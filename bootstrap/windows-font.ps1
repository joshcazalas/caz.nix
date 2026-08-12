#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$ConfigureWindowsTerminal,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$FontFamily = 'MesloLGL Nerd Font'
$FontVersion = '3.4.0'
$ArchiveUri = "https://github.com/ryanoasis/nerd-fonts/releases/download/v$FontVersion/Meslo.zip"
$ArchiveSha256 = '13b502ac8c2bd9d3161018064560e23cd42b175bb730780a270975265a19ad57'
$FontFiles = @(
    [pscustomobject]@{
        File = 'MesloLGLNerdFont-Regular.ttf'
        RegistryName = 'MesloLGL Nerd Font Regular (TrueType)'
    },
    [pscustomobject]@{
        File = 'MesloLGLNerdFont-Bold.ttf'
        RegistryName = 'MesloLGL Nerd Font Bold (TrueType)'
    },
    [pscustomobject]@{
        File = 'MesloLGLNerdFont-Italic.ttf'
        RegistryName = 'MesloLGL Nerd Font Italic (TrueType)'
    },
    [pscustomobject]@{
        File = 'MesloLGLNerdFont-BoldItalic.ttf'
        RegistryName = 'MesloLGL Nerd Font Bold Italic (TrueType)'
    }
)

function Get-ObjectProperty {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Set-ObjectProperty {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        $InputObject | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
    else {
        $property.Value = $Value
    }
}

function Test-MesloInstalled {
    Add-Type -AssemblyName System.Drawing
    $collection = New-Object System.Drawing.Text.InstalledFontCollection
    try {
        return $null -ne ($collection.Families | Where-Object Name -EQ $FontFamily | Select-Object -First 1)
    }
    finally {
        $collection.Dispose()
    }
}

function Get-WindowsTerminalSettingsPaths {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
    )

    return @($candidates | Where-Object { Test-Path -LiteralPath $_ })
}

function Test-TerminalFont {
    param([Parameter(Mandatory)][string]$Path)

    try {
        $settings = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $profiles = Get-ObjectProperty -InputObject $settings -Name 'profiles'
        if ($null -eq $profiles -or $profiles -is [System.Array]) {
            return $false
        }
        $defaults = Get-ObjectProperty -InputObject $profiles -Name 'defaults'
        if ($null -eq $defaults) {
            return $false
        }
        $font = Get-ObjectProperty -InputObject $defaults -Name 'font'
        if ($null -eq $font) {
            return $false
        }
        return (Get-ObjectProperty -InputObject $font -Name 'face') -eq $FontFamily
    }
    catch {
        Write-Warning "Could not inspect Windows Terminal settings at ${Path}: $($_.Exception.Message)"
        return $false
    }
}

function Install-MesloFont {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "caz-nix-meslo-$PID"
    $archivePath = Join-Path $tempRoot 'Meslo.zip'
    $extractPath = Join-Path $tempRoot 'fonts'
    $fontDirectory = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    $fontRegistry = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'

    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Write-Host "Downloading official Nerd Fonts Meslo $FontVersion archive..."
        Invoke-WebRequest -Uri $ArchiveUri -OutFile $archivePath -UseBasicParsing

        $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $ArchiveSha256) {
            throw "Meslo archive checksum mismatch. Expected $ArchiveSha256, received $actualHash."
        }

        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath
        New-Item -ItemType Directory -Path $fontDirectory -Force | Out-Null
        New-Item -Path $fontRegistry -Force | Out-Null

        if (-not ('CazNix.FontInstaller.NativeMethods' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace CazNix.FontInstaller {
    public static class NativeMethods {
        [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
        public static extern int AddFontResource(string fileName);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern IntPtr SendMessageTimeout(
            IntPtr hWnd,
            uint message,
            IntPtr wParam,
            IntPtr lParam,
            uint flags,
            uint timeout,
            out IntPtr result
        );
    }
}
'@
        }

        foreach ($font in $FontFiles) {
            $sourcePath = Join-Path $extractPath $font.File
            $destinationPath = Join-Path $fontDirectory $font.File
            if (-not (Test-Path -LiteralPath $sourcePath)) {
                throw "The verified archive did not contain $($font.File)."
            }

            Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
            New-ItemProperty -Path $fontRegistry -Name $font.RegistryName -Value $destinationPath -PropertyType String -Force | Out-Null
            if ([CazNix.FontInstaller.NativeMethods]::AddFontResource($destinationPath) -eq 0) {
                Write-Warning "Windows copied $($font.File), but did not load it into the current session. A sign-out may be required."
            }
        }

        $broadcast = [IntPtr]::Zero
        [void][CazNix.FontInstaller.NativeMethods]::SendMessageTimeout(
            [IntPtr]0xffff,
            0x001D,
            [IntPtr]::Zero,
            [IntPtr]::Zero,
            0x0002,
            1000,
            [ref]$broadcast
        )
        Write-Host "Installed $FontFamily $FontVersion for the current Windows user."
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

function Set-TerminalFont {
    param([Parameter(Mandatory)][string]$Path)

    if (Test-TerminalFont -Path $Path) {
        Write-Host "Windows Terminal already uses $FontFamily by default."
        return
    }

    $settings = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $profiles = Get-ObjectProperty -InputObject $settings -Name 'profiles'
    if ($profiles -is [System.Array]) {
        throw "The legacy Windows Terminal profile-array format at $Path is not changed automatically."
    }
    if ($null -eq $profiles) {
        $profiles = [pscustomobject]@{
            defaults = [pscustomobject]@{}
            list = @()
        }
        Set-ObjectProperty -InputObject $settings -Name 'profiles' -Value $profiles
    }

    $defaults = Get-ObjectProperty -InputObject $profiles -Name 'defaults'
    if ($null -eq $defaults) {
        $defaults = [pscustomobject]@{}
        Set-ObjectProperty -InputObject $profiles -Name 'defaults' -Value $defaults
    }

    $font = Get-ObjectProperty -InputObject $defaults -Name 'font'
    if ($null -eq $font) {
        $font = [pscustomobject]@{}
        Set-ObjectProperty -InputObject $defaults -Name 'font' -Value $font
    }
    Set-ObjectProperty -InputObject $font -Name 'face' -Value $FontFamily

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupPath = "$Path.pre-caz-nix-$timestamp"
    $tempPath = "$Path.caz-nix-tmp"
    Copy-Item -LiteralPath $Path -Destination $backupPath

    try {
        $json = $settings | ConvertTo-Json -Depth 100
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tempPath, "$json`r`n", $utf8)
        Move-Item -LiteralPath $tempPath -Destination $Path -Force
    }
    catch {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force
        }
        throw
    }

    Write-Host "Set the Windows Terminal default font to $FontFamily."
    Write-Host "Preserved the prior settings at $backupPath."
}

$fontReady = (Test-MesloInstalled) -and (-not $Force)
$terminalPaths = @(Get-WindowsTerminalSettingsPaths)
$terminalReady = -not $ConfigureWindowsTerminal -or $terminalPaths.Count -eq 0
if ($ConfigureWindowsTerminal -and $terminalPaths.Count -gt 0) {
    $terminalReady = @($terminalPaths | Where-Object { -not (Test-TerminalFont -Path $_) }).Count -eq 0
}

if ($Check) {
    Write-Host "Windows font installed: $fontReady"
    if ($ConfigureWindowsTerminal) {
        if ($terminalPaths.Count -eq 0) {
            Write-Host 'Windows Terminal settings: not found (nothing to configure)'
        }
        else {
            Write-Host "Windows Terminal configured: $terminalReady"
        }
    }

    if ($fontReady -and $terminalReady) {
        exit 0
    }
    exit 10
}

if ($fontReady) {
    Write-Host "$FontFamily is already installed; skipping download."
}
else {
    Install-MesloFont
}

if ($ConfigureWindowsTerminal) {
    if ($terminalPaths.Count -eq 0) {
        Write-Warning 'Windows Terminal settings were not found. Select MesloLGL Nerd Font manually after installing Windows Terminal.'
    }
    else {
        foreach ($path in $terminalPaths) {
            Set-TerminalFont -Path $path
        }
    }
}
