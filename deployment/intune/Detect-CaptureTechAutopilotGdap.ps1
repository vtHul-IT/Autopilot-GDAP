$expectedPublisher = 'CN=CaptureTech IT-Services BV'
$expectedVersion = '__EXPECTED_VERSION__'

$candidatePaths = @(
    'C:\Program Files\CaptureTech\Autopilot GDAP\capturetech-autopilot-gdap.exe',
    'C:\Program Files (x86)\CaptureTech\Autopilot GDAP\capturetech-autopilot-gdap.exe'
)

foreach ($executablePath in $candidatePaths) {
    if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) { continue }

    $signature = Get-AuthenticodeSignature -LiteralPath $executablePath
    $versionText = (Get-Item -LiteralPath $executablePath).VersionInfo.ProductVersion
    $versionMatch = [regex]::Match($versionText, '\d+\.\d+\.\d+')
    if (-not $versionMatch.Success) { continue }

    $installedVersion = [version]$versionMatch.Value
    if (
        $signature.Status -eq 'Valid' -and
        $signature.SignerCertificate.Subject -like "*$expectedPublisher*" -and
        $installedVersion -eq [version]$expectedVersion
    ) {
        Write-Output "CaptureTech Autopilot GDAP $installedVersion is installed: $executablePath"
        exit 0
    }
}

exit 1
