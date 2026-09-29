[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$PackageFolder,

    [Parameter(Mandatory)]
    [string]$Username,

    [string]$TenantId,

    [string[]]$AvailableFor,

    [string[]]$RequiredFor,

    [string]$LogoPath
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name WinTuner)) {
    throw 'WinTuner ontbreekt. Installeer eerst: Install-Module WinTuner -Scope CurrentUser'
}

Import-Module WinTuner -ErrorAction Stop
$connectParameters = @{ Username = $Username }
if ($TenantId) { $connectParameters.TenantId = $TenantId }
Connect-WtWinTuner @connectParameters

$deployParameters = @{ PackageFolder = $PackageFolder }
if ($AvailableFor) { $deployParameters.AvailableFor = $AvailableFor }
if ($RequiredFor) { $deployParameters.RequiredFor = $RequiredFor }
if ($LogoPath) { $deployParameters.LogoPath = $LogoPath }

if ($PSCmdlet.ShouldProcess($PackageFolder, 'Publiceer CaptureTech Autopilot GDAP als Intune Win32-app')) {
    Deploy-WtWin32App @deployParameters
}
