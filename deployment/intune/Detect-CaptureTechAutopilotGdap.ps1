$registryPath = 'HKLM:\SOFTWARE\CaptureTech\Autopilot GDAP'
$expectedPublisher = 'CN=CaptureTech IT-Services BV'

if (-not (Test-Path -LiteralPath $registryPath)) { exit 1 }

$installation = Get-ItemProperty -LiteralPath $registryPath
if ([string]::IsNullOrWhiteSpace($installation.ExecutablePath) -or -not (Test-Path -LiteralPath $installation.ExecutablePath -PathType Leaf)) {
    exit 1
}

$signature = Get-AuthenticodeSignature -LiteralPath $installation.ExecutablePath
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notlike "*$expectedPublisher*") {
    exit 1
}

Write-Output "CaptureTech Autopilot GDAP is installed: $($installation.ExecutablePath)"
exit 0
