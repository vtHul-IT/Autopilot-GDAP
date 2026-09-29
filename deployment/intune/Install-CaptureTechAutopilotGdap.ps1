[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$productName = 'CaptureTech Autopilot GDAP'
$publisherSubject = 'CN=CaptureTech IT-Services BV'
$exeName = 'capturetech-autopilot-gdap.exe'
# Intune Management Extension can launch PowerShell in a 32-bit host. ProgramW6432
# keeps the application in the native Program Files location on x64 Windows.
$programFiles64 = [Environment]::GetEnvironmentVariable('ProgramW6432')
if ([string]::IsNullOrWhiteSpace($programFiles64)) { $programFiles64 = $env:ProgramFiles }
$installRoot = Join-Path $programFiles64 'CaptureTech\Autopilot GDAP'
$targetExe = Join-Path $installRoot $exeName
$registryPath = 'HKLM:\SOFTWARE\CaptureTech\Autopilot GDAP'
$shortcutDirectory = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\CaptureTech'
$shortcutPath = Join-Path $shortcutDirectory "$productName.lnk"

function Write-InstallLog {
    param([Parameter(Mandatory)][string]$Message)

    $line = "{0:u} {1}" -f (Get-Date), $Message
    Write-Output $line
    if (Test-Path -LiteralPath $installRoot) {
        Add-Content -LiteralPath (Join-Path $installRoot 'install.log') -Value $line -Encoding utf8
    }
}

$sourceExe = Join-Path $PSScriptRoot $exeName
if (-not (Test-Path -LiteralPath $sourceExe -PathType Leaf)) {
    throw "Installatiebestand ontbreekt: $sourceExe"
}

$signature = Get-AuthenticodeSignature -LiteralPath $sourceExe
if ($signature.Status -ne 'Valid') {
    throw "De meegeleverde EXE heeft geen geldige Authenticode-handtekening. Status: $($signature.Status)"
}
if ($signature.SignerCertificate.Subject -notlike "*$publisherSubject*") {
    throw "De EXE is niet ondertekend door de verwachte uitgever. Gevonden: $($signature.SignerCertificate.Subject)"
}

New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
Write-InstallLog 'Geldige CaptureTech-handtekening gecontroleerd.'

$temporaryExe = "$targetExe.new"
Copy-Item -LiteralPath $sourceExe -Destination $temporaryExe -Force
Move-Item -LiteralPath $temporaryExe -Destination $targetExe -Force

New-Item -ItemType Directory -Path $shortcutDirectory -Force | Out-Null
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $targetExe
$shortcut.WorkingDirectory = $installRoot
$shortcut.Description = 'CaptureTech Autopilot GDAP device provisioning'
$shortcut.IconLocation = "$targetExe,0"
$shortcut.Save()

$fileVersion = (Get-Item -LiteralPath $targetExe).VersionInfo.ProductVersion
if ([string]::IsNullOrWhiteSpace($fileVersion)) { $fileVersion = 'Onbekend' }
New-Item -Path $registryPath -Force | Out-Null
New-ItemProperty -Path $registryPath -Name DisplayName -Value $productName -PropertyType String -Force | Out-Null
New-ItemProperty -Path $registryPath -Name DisplayVersion -Value $fileVersion -PropertyType String -Force | Out-Null
New-ItemProperty -Path $registryPath -Name InstallLocation -Value $installRoot -PropertyType String -Force | Out-Null
New-ItemProperty -Path $registryPath -Name ExecutablePath -Value $targetExe -PropertyType String -Force | Out-Null

Write-InstallLog "Installatie voltooid. Programma: $targetExe"
exit 0
