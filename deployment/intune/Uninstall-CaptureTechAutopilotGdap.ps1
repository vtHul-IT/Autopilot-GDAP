[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$installRoot = Join-Path $env:ProgramFiles 'CaptureTech\Autopilot GDAP'
$registryPath = 'HKLM:\SOFTWARE\CaptureTech\Autopilot GDAP'
$shortcutPath = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\CaptureTech\CaptureTech Autopilot GDAP.lnk'

if (Test-Path -LiteralPath $shortcutPath) {
    Remove-Item -LiteralPath $shortcutPath -Force
}
if (Test-Path -LiteralPath $installRoot) {
    Remove-Item -LiteralPath $installRoot -Recurse -Force
}
if (Test-Path -LiteralPath $registryPath) {
    Remove-Item -LiteralPath $registryPath -Recurse -Force
}

exit 0
