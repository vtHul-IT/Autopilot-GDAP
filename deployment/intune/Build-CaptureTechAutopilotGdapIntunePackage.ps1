[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^tauri-v\d+\.\d+\.\d+$')]
    [string]$ReleaseTag,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$IntuneWinAppUtilPath,

    [string]$Repository = 'vtHul-IT/Autopilot-GDAP',

    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'out')
)

$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') { throw 'Dit script moet op Windows worden uitgevoerd.' }

$exeName = 'capturetech-autopilot-gdap.exe'
$publisherSubject = 'CN=CaptureTech IT-Services BV'
$version = $ReleaseTag -replace '^tauri-v', ''
$releaseBaseUrl = "https://github.com/$Repository/releases/download/$ReleaseTag"
$packageRoot = Join-Path $OutputDirectory "CaptureTech-Autopilot-GDAP-$version"
$sourceDirectory = Join-Path $packageRoot 'source'
$contentDirectory = Join-Path $packageRoot 'content'
$intuneWinPath = Join-Path $packageRoot 'CaptureTech-Autopilot-GDAP.intunewin'

Remove-Item -LiteralPath $packageRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $sourceDirectory, $contentDirectory -Force | Out-Null

Invoke-WebRequest -Uri "$releaseBaseUrl/$exeName" -OutFile (Join-Path $sourceDirectory $exeName)
Invoke-WebRequest -Uri "$releaseBaseUrl/$exeName.sha256" -OutFile (Join-Path $sourceDirectory "$exeName.sha256")

$expectedHash = ((Get-Content -LiteralPath (Join-Path $sourceDirectory "$exeName.sha256") -Raw).Trim() -split '\s+')[0].ToUpperInvariant()
$actualHash = (Get-FileHash -LiteralPath (Join-Path $sourceDirectory $exeName) -Algorithm SHA256).Hash.ToUpperInvariant()
if ($actualHash -ne $expectedHash) { throw "SHA-256 controle mislukt. Verwacht $expectedHash, ontvangen $actualHash." }

$signature = Get-AuthenticodeSignature -LiteralPath (Join-Path $sourceDirectory $exeName)
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notlike "*$publisherSubject*") {
    throw "De release-EXE is niet geldig ondertekend door CaptureTech. Status: $($signature.Status); uitgever: $($signature.SignerCertificate.Subject)"
}

Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Install-CaptureTechAutopilotGdap.ps1') -Destination $sourceDirectory
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Uninstall-CaptureTechAutopilotGdap.ps1') -Destination $sourceDirectory

$detectionScript = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Detect-CaptureTechAutopilotGdap.ps1') -Raw)))
$appDefinition = [ordered]@{
    '@odata.type' = '#microsoft.graph.win32LobApp'
    displayName = 'CaptureTech Autopilot GDAP'
    description = 'Ondertekende tool voor Autopilot-registratie via CaptureTech GDAP.'
    publisher = 'CaptureTech IT-Services BV'
    displayVersion = $version
    developer = 'CaptureTech IT-Services BV'
    owner = 'CaptureTech IT-Services BV'
    notes = "Release $ReleaseTag, geleverd via $Repository."
    fileName = [IO.Path]::GetFileName($intuneWinPath)
    setupFilePath = 'Install-CaptureTechAutopilotGdap.ps1'
    installCommandLine = 'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\Install-CaptureTechAutopilotGdap.ps1'
    uninstallCommandLine = 'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-CaptureTechAutopilotGdap.ps1'
    applicableArchitectures = 'x64'
    minimumSupportedWindowsRelease = '2004'
    minimumSupportedOperatingSystem = @{ '@odata.type' = '#microsoft.graph.windowsMinimumOperatingSystem'; v10_2004 = $true }
    installExperience = @{ '@odata.type' = '#microsoft.graph.win32LobAppInstallExperience'; runAsAccount = 'system'; deviceRestartBehavior = 'basedOnReturnCode' }
    allowAvailableUninstall = $true
    returnCodes = @(
        @{ '@odata.type' = '#microsoft.graph.win32LobAppReturnCode'; returnCode = 0; type = 'success' },
        @{ '@odata.type' = '#microsoft.graph.win32LobAppReturnCode'; returnCode = 3010; type = 'softReboot' },
        @{ '@odata.type' = '#microsoft.graph.win32LobAppReturnCode'; returnCode = 1641; type = 'hardReboot' },
        @{ '@odata.type' = '#microsoft.graph.win32LobAppReturnCode'; returnCode = 1618; type = 'retry' }
    )
    detectionRules = @(
        @{ '@odata.type' = '#microsoft.graph.win32LobAppPowerShellScriptDetection'; scriptContent = $detectionScript; enforceSignatureCheck = $false; runAs32Bit = $false }
    )
}

& $IntuneWinAppUtilPath -c $sourceDirectory -s 'Install-CaptureTechAutopilotGdap.ps1' -o $contentDirectory -q
if ($LASTEXITCODE -ne 0) { throw "IntuneWinAppUtil is geëindigd met exitcode $LASTEXITCODE." }

$generatedPackage = Get-ChildItem -LiteralPath $contentDirectory -Filter '*.intunewin' -File | Select-Object -First 1
if (-not $generatedPackage) { throw 'IntuneWinAppUtil heeft geen .intunewin-bestand gemaakt.' }
Move-Item -LiteralPath $generatedPackage.FullName -Destination $intuneWinPath -Force
$appDefinition | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $packageRoot 'win32LobApp.json') -Encoding utf8

[pscustomobject]@{
    ReleaseTag = $ReleaseTag
    PackageFolder = $packageRoot
    IntuneWinFile = $intuneWinPath
    Sha256 = $actualHash
    ExecutablePublisher = $signature.SignerCertificate.Subject
}
