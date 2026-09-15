#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Load only the pure parsing/configuration functions. Never run the bootstrap,
# install a driver, elevate, or touch the test machine's real display settings.
$source = Join-Path (Split-Path -Parent $PSScriptRoot) 'bootstrap\windows-game-stream.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
foreach ($name in @('Get-VirtualDisplayIdFromLog', 'Add-VirtualDisplayModes')) {
    $functionAst = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    . ([scriptblock]::Create($functionAst.Extent.Text))
}

function Assert-Rejected {
    param([string]$Content, [DateTime]$Since = [DateTime]::MinValue)
    $rejected = $false
    try { $null = Get-VirtualDisplayIdFromLog -Content $Content -Since $Since }
    catch { $rejected = $true }
    if (-not $rejected) { throw 'Unsafe or incomplete display enumeration was accepted.' }
}

$displayId = '{11111111-2222-3333-4444-555555555555}'
$enumeration = @'
[2026-09-15 12:00:01.100]: Info: Currently available display devices:
[
  {
    "device_id": "{aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee}",
    "display_name": "\\\\.\\DISPLAY1",
    "friendly_name": "Living room TV",
    "info": { "primary": true }
  },
  {
    "device_id": "{11111111-2222-3333-4444-555555555555}",
    "display_name": "",
    "friendly_name": "VDD by MTT",
    "info": null
  }
]
[2026-09-15 12:00:01.200]: Info: More startup output
'@
$actual = Get-VirtualDisplayIdFromLog -Content $enumeration -Since ([DateTime]'2026-09-15T12:00:01')
if ($actual -ne $displayId) { throw 'Failed to select the inactive virtual monitor instead of the active TV.' }
Assert-Rejected -Content $enumeration -Since ([DateTime]'2026-09-15T12:00:02')
Assert-Rejected -Content ($enumeration + "`nCurrently available display devices:`n[")
Assert-Rejected -Content ($enumeration + "`nCurrently available display devices:`n[]")
Assert-Rejected -Content ($enumeration.Replace('Living room TV', 'VDD by MTT'))
Assert-Rejected -Content ($enumeration.Replace($displayId, '\\.\DISPLAY2'))
Assert-Rejected -Content ''

$configuration = [xml]@'
<vdd_settings>
  <monitors><count>1</count></monitors>
  <gpu><friendlyname>Example GPU</friendlyname></gpu>
  <resolutions>
    <resolution><width>1920</width><height>1080</height><refresh_rate>120</refresh_rate></resolution>
  </resolutions>
  <options><CustomEdid>false</CustomEdid></options>
</vdd_settings>
'@
if (-not (Add-VirtualDisplayModes -Configuration $configuration)) { throw 'Missing display modes were not added.' }
foreach ($size in @('1280x720', '1280x800', '1920x1080', '1920x1200', '2560x1440', '2560x1600')) {
    $width, $height = $size -split 'x'
    foreach ($rate in @('30', '60')) {
        $node = $configuration.SelectSingleNode(
            "/vdd_settings/resolutions/resolution[width='$width' and height='$height']/refresh_rate[text()='$rate']"
        )
        if ($null -eq $node) { throw "Missing requested mode: $size at $rate Hz." }
    }
}
if ($configuration.vdd_settings.gpu.friendlyname -ne 'Example GPU') { throw 'GPU selection was overwritten.' }
if ($null -eq $configuration.SelectSingleNode('//refresh_rate[text()="120"]')) { throw 'An existing mode was removed.' }
if ($configuration.vdd_settings.options.CustomEdid -ne 'false') { throw 'Driver options were overwritten.' }
$before = $configuration.OuterXml
if (Add-VirtualDisplayModes -Configuration $configuration) { throw 'A repeated configuration was not idempotent.' }
if ($configuration.OuterXml -ne $before) { throw 'A repeated configuration changed the XML.' }

$globalConfiguration = [xml]'<vdd_settings><global><g_refresh_rate>30</g_refresh_rate><g_refresh_rate>60</g_refresh_rate></global><resolutions /></vdd_settings>'
$null = Add-VirtualDisplayModes -Configuration $globalConfiguration
foreach ($resolution in $globalConfiguration.SelectNodes('//resolution')) {
    if ($resolution.FirstChild.LocalName -ne 'width' -or $resolution.FirstChild.NextSibling.LocalName -ne 'height') {
        throw 'Display dimensions are not ordered for the released driver parser.'
    }
}
if ($globalConfiguration.SelectNodes('//resolution/refresh_rate').Count -ne 0) {
    throw 'Global refresh rates were duplicated in individual resolutions.'
}

Write-Host 'Validated virtual-display discovery, stale/incomplete log rejection, mode preservation, and idempotence.'
