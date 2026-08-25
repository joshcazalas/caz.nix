#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$ConfigureWindowsTerminal,
    [switch]$Force,
    [switch]$SelfTest
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
        Sha256 = '5343e2b5f9f0e520f6bffa58d6db13043ac7736458a1bf9aceb6a9fd94b1f0c0'
    },
    [pscustomobject]@{
        File = 'MesloLGLNerdFont-Bold.ttf'
        RegistryName = 'MesloLGL Nerd Font Bold (TrueType)'
        Sha256 = '0aa95657d97628abc3f7674080e539e89e9823c408df14ddf93ce4d11bff9c7e'
    },
    [pscustomobject]@{
        File = 'MesloLGLNerdFont-Italic.ttf'
        RegistryName = 'MesloLGL Nerd Font Italic (TrueType)'
        Sha256 = 'db6a6e72dd06cdf98bea6a0a34f28a9f241c8d16bcfe96258180904b0ed76cc0'
    },
    [pscustomobject]@{
        File = 'MesloLGLNerdFont-BoldItalic.ttf'
        RegistryName = 'MesloLGL Nerd Font Bold Italic (TrueType)'
        Sha256 = '89c063735ba98c514573b827a32c30e17b5bce45edc1ac0c5be8559a2207fb8b'
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

function ConvertFrom-TerminalSettingsJson {
    param([Parameter(Mandatory)][string]$Json)

    # Windows Terminal accepts JSON with comments and trailing commas, while
    # Windows PowerShell 5.1's ConvertFrom-Json accepts strict JSON only.
    # Parse these extensions character by character so comment-like text and
    # comma/bracket sequences inside quoted values remain untouched.
    $strictJson = New-Object System.Text.StringBuilder
    $inString = $false
    $escaped = $false
    $inLineComment = $false
    $inBlockComment = $false

    for ($index = 0; $index -lt $Json.Length; $index++) {
        $character = $Json[$index]
        $next = if ($index + 1 -lt $Json.Length) { $Json[$index + 1] } else { [char]0 }

        if ($inLineComment) {
            if ($character -eq "`r" -or $character -eq "`n") {
                $inLineComment = $false
                [void]$strictJson.Append($character)
            }
            continue
        }

        if ($inBlockComment) {
            if ($character -eq '*' -and $next -eq '/') {
                $inBlockComment = $false
                $index++
            }
            elseif ($character -eq "`r" -or $character -eq "`n") {
                [void]$strictJson.Append($character)
            }
            continue
        }

        if ($inString) {
            [void]$strictJson.Append($character)
            if ($escaped) {
                $escaped = $false
            }
            elseif ($character -eq '\') {
                $escaped = $true
            }
            elseif ($character -eq '"') {
                $inString = $false
            }
            continue
        }

        if ($character -eq '"') {
            $inString = $true
            [void]$strictJson.Append($character)
            continue
        }
        if ($character -eq '/' -and $next -eq '/') {
            $inLineComment = $true
            $index++
            continue
        }
        if ($character -eq '/' -and $next -eq '*') {
            $inBlockComment = $true
            $index++
            continue
        }
        if ($character -eq ',') {
            $lookAhead = $index + 1
            while ($lookAhead -lt $Json.Length -and [char]::IsWhiteSpace($Json[$lookAhead])) {
                $lookAhead++
            }
            if ($lookAhead -lt $Json.Length -and $Json[$lookAhead] -in @('}', ']')) {
                continue
            }
        }

        [void]$strictJson.Append($character)
    }

    if ($inBlockComment) {
        throw 'Windows Terminal settings contain an unterminated block comment.'
    }

    return $strictJson.ToString() | ConvertFrom-Json
}

function Test-MesloInstalled {
    $fontDirectory = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    $fontRegistry = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'

    foreach ($font in $FontFiles) {
        $path = Join-Path $fontDirectory $font.File
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            return $false
        }
        $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $font.Sha256) {
            return $false
        }

        $registeredPath = Get-ItemPropertyValue `
            -LiteralPath $fontRegistry `
            -Name $font.RegistryName `
            -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($registeredPath) -or $registeredPath -ne $path) {
            return $false
        }
    }

    return $true
}

function Get-WindowsTerminalSettingsPaths {
    $stablePath = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'
    $previewPath = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'
    $unpackagedPath = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json'
    $stablePackageReady = $null -ne (
        Get-AppxPackage -Name Microsoft.WindowsTerminal -ErrorAction SilentlyContinue |
            Select-Object -First 1
    )
    $previewPackageReady = $null -ne (
        Get-AppxPackage -Name Microsoft.WindowsTerminalPreview -ErrorAction SilentlyContinue |
            Select-Object -First 1
    )

    # Windows Terminal does not create settings.json until first launch. Keep a
    # candidate for each installed package so this helper can create a minimal
    # settings file during a fresh bootstrap. The unpackaged path has no package
    # identity to query, so include it only when the settings file itself exists.
    return @(
        if ($stablePackageReady -or (Test-Path -LiteralPath $stablePath)) {
            $stablePath
        }
        if ($previewPackageReady -or (Test-Path -LiteralPath $previewPath)) {
            $previewPath
        }
        if (Test-Path -LiteralPath $unpackagedPath) {
            $unpackagedPath
        }
    )
}

function Test-TerminalFont {
    param([Parameter(Mandatory)][string]$Path)

    try {
        $settingsJson = Get-Content -LiteralPath $Path -Raw
        $settings = ConvertFrom-TerminalSettingsJson -Json $settingsJson
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

    $settingsExist = Test-Path -LiteralPath $Path
    if ($settingsExist -and (Test-TerminalFont -Path $Path)) {
        Write-Host "Windows Terminal already uses $FontFamily by default."
        return
    }

    if ($settingsExist) {
        $settingsJson = Get-Content -LiteralPath $Path -Raw
        $settings = ConvertFrom-TerminalSettingsJson -Json $settingsJson
    }
    else {
        $settings = [pscustomobject]@{
            '$schema' = 'https://aka.ms/terminal-profiles-schema'
            profiles = [pscustomobject]@{
                defaults = [pscustomobject]@{}
                list = @()
            }
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    }
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
    if ($settingsExist) {
        Copy-Item -LiteralPath $Path -Destination $backupPath
    }

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
    if ($settingsExist) {
        Write-Host "Preserved the prior settings at $backupPath."
    }
    else {
        Write-Host "Created Windows Terminal settings at $Path."
    }
}

if ($SelfTest) {
    $sample = @'
{
  // a full-line comment
  "$schema": "https://aka.ms/terminal-profiles-schema", // an inline comment
  "literal": "keep // and /* and ,} text",
  "escaped": "keep \\\"// quoted text\\\"",
  /* a block
     comment */
  "profiles": {
    "defaults": {
      "font": {
        "face": "MesloLGL Nerd Font",
      },
    },
    "list": [],
  },
}
'@
    $parsed = ConvertFrom-TerminalSettingsJson -Json $sample
    if ($parsed.'$schema' -ne 'https://aka.ms/terminal-profiles-schema') {
        throw 'Terminal JSONC self-test corrupted a URL.'
    }
    if ($parsed.literal -ne 'keep // and /* and ,} text') {
        throw 'Terminal JSONC self-test corrupted comment-like string content.'
    }
    if ($parsed.escaped -ne 'keep \"// quoted text\"') {
        throw 'Terminal JSONC self-test corrupted an escaped quoted value.'
    }
    if ($parsed.profiles.defaults.font.face -ne $FontFamily) {
        throw 'Terminal JSONC self-test did not preserve the nested font value.'
    }
    Write-Host 'Windows Terminal JSONC parser self-test passed.'
    return
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
