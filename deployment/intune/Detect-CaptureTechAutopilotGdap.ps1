$expectedPublisher = 'CN=CaptureTech IT-Services BV'
$exeName = 'capturetech-autopilot-gdap.exe'

$candidatePaths = @(
    'C:\Program Files\CaptureTech\Autopilot GDAP\capturetech-autopilot-gdap.exe',
    'C:\Program Files (x86)\CaptureTech\Autopilot GDAP\capturetech-autopilot-gdap.exe'
)

foreach ($executablePath in $candidatePaths) {
    if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) { continue }

    $signature = Get-AuthenticodeSignature -LiteralPath $executablePath
    if ($signature.Status -eq 'Valid' -and $signature.SignerCertificate.Subject -like "*$expectedPublisher*") {
        Write-Output "CaptureTech Autopilot GDAP is installed: $executablePath"
        exit 0
    }
}

exit 1
