[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$enginePath = Join-Path $PSScriptRoot "AutopilotGdap.Engine.psm1"
$module = Import-Module -Name $enginePath -Force -PassThru -ErrorAction Stop
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)][object]$Actual,
        [Parameter(Mandatory = $true)][object]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($Actual -ne $Expected) {
        [void]$failures.Add("$Name. Verwacht: '$Expected'. Ontvangen: '$Actual'.")
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if (-not $Condition) { [void]$failures.Add($Name) }
}

function New-TestErrorRecord {
    param([Parameter(Mandatory = $true)][string]$Message)
    $exception = [System.InvalidOperationException]::new($Message)
    return [System.Management.Automation.ErrorRecord]::new($exception, "AutopilotGdapTest", [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
}

$oobeMode = & $module { Resolve-AuthenticationMode -IsOobe $true }
$desktopMode = & $module { Resolve-AuthenticationMode -IsOobe $false }
Assert-Equal -Actual $oobeMode -Expected "browserOobe" -Name "OOBE gebruikt browser-SSO"
Assert-Equal -Actual $desktopMode -Expected "wam" -Name "Desktop gebruikt WAM"

$emptyBrowserRequestIsCallback = & $module {
    Test-BrowserAuthorizationCallback -Code "" -Error "" -ErrorDescription ""
}
Assert-True -Condition (-not [bool]$emptyBrowserRequestIsCallback) -Name "Een browserresource zonder OAuth-resultaat verbruikt de callback niet"
$codeBrowserRequestIsCallback = & $module {
    Test-BrowserAuthorizationCallback -Code "authorization-code" -Error "" -ErrorDescription ""
}
Assert-True -Condition ([bool]$codeBrowserRequestIsCallback) -Name "Een OAuth-code wordt als callback herkend"
$errorBrowserRequestIsCallback = & $module {
    Test-BrowserAuthorizationCallback -Code "" -Error "login_required" -ErrorDescription ""
}
Assert-True -Condition ([bool]$errorBrowserRequestIsCallback) -Name "Een OAuth-fout wordt als callback herkend"

$resolvedOrderIdTag = & $module {
    Resolve-AutopilotOrderIdGroupTag -Groups @(
        [pscustomobject]@{ isDynamic = $true; isExclusion = $false; membershipRule = '(device.devicePhysicalIds -any (_ -eq "[OrderID]:JHZH"))' },
        [pscustomobject]@{ isDynamic = $true; isExclusion = $false; membershipRule = '(device.devicePhysicalIds -any _ -eq "[OrderID]:JHZH")' },
        [pscustomobject]@{ isDynamic = $false; isExclusion = $false; membershipRule = $null }
    )
}
Assert-Equal -Actual $resolvedOrderIdTag.status -Expected "resolved" -Name "Een eenduidige dynamische OrderID-regel wordt herkend"
Assert-Equal -Actual $resolvedOrderIdTag.groupTag -Expected "JHZH" -Name "De Group Tag wordt uit de dynamische regel gehaald"

$ambiguousOrderIdTag = & $module {
    Resolve-AutopilotOrderIdGroupTag -Groups @(
        [pscustomobject]@{ isDynamic = $true; isExclusion = $false; membershipRule = '(device.devicePhysicalIds -any _ -eq "[OrderID]:Blue")' },
        [pscustomobject]@{ isDynamic = $true; isExclusion = $false; membershipRule = '(device.devicePhysicalIds -any _ -eq "[OrderID]:Red")' },
        [pscustomobject]@{ isDynamic = $true; isExclusion = $true; membershipRule = '(device.devicePhysicalIds -any _ -eq "[OrderID]:Ignored")' }
    )
}
Assert-Equal -Actual $ambiguousOrderIdTag.status -Expected "ambiguous" -Name "Tegenstrijdige dynamische OrderID-tags worden niet gegokt"
Assert-True -Condition ([string]::IsNullOrEmpty([string]$ambiguousOrderIdTag.groupTag)) -Name "Een dubbelzinnige OrderID-regel levert geen Group Tag op"
$noOrderIdTag = & $module { Resolve-AutopilotOrderIdGroupTag -Groups @() }
Assert-Equal -Actual $noOrderIdTag.status -Expected "none" -Name "Een profiel zonder OrderID-regel krijgt geen Group Tag"

$communityParameters = & $module {
    New-CommunityOnlineParameters -TenantId "00000000-0000-0000-0000-000000000001" -SelectedAddToGroup ([pscustomobject]@{ name = "Statische-groep" }) -GroupTag "JHZH" -Hostname "CT-LAP-001" -IncludeTechnicalOutput $true
}
Assert-Equal -Actual $communityParameters["GroupTag"] -Expected "JHZH" -Name "De afgeleide OrderID-tag wordt als GroupTag gesplat"
Assert-Equal -Actual $communityParameters["AddToGroup"] -Expected "Statische-groep" -Name "De statische groepsactie blijft een aparte AddToGroup-splat"
Assert-Equal -Actual $communityParameters["AssignedComputerName"] -Expected "CT-LAP-001" -Name "GroupTag behoudt de optionele apparaatnaam"
Assert-True -Condition ([bool]$communityParameters["Verbose"]) -Name "De technische-loginstelling blijft aan het Community-script gekoppeld"

$scopes = @(& $module { ConvertTo-MsalScopes -Scopes @("Directory.Read.All", "https://api.partnercenter.microsoft.com/user_impersonation") })
Assert-True -Condition ($scopes -contains "Directory.Read.All") -Name "Graph-scope blijft een canonieke delegated scope voor WAM"
Assert-True -Condition ($scopes -notcontains "https://graph.microsoft.com/Directory.Read.All") -Name "WAM vraagt geen URL-audience Graph-scope aan"
Assert-True -Condition ($scopes -contains "https://api.partnercenter.microsoft.com/user_impersonation") -Name "Partner Center-scope blijft ongewijzigd"

$engineText = Get-Content -LiteralPath $enginePath -Raw -ErrorAction Stop
Assert-True -Condition ($engineText -match '\.WithDefaultRedirectUri\(\)') -Name "WAM gebruikt de standaard broker-redirect in MSAL"
Assert-True -Condition ($engineText -notmatch '\.WithRedirectUri\("ms-appx-web://') -Name "WAM forceert de BrokerPlugin-redirect niet in MSAL"
Assert-True -Condition ($engineText -match 'if \(!selectAccount \|\| forceCustomerAccountSelection\) request = request\.WithTenantId\(tenantId\);') -Name "WAM gebruikt tenant-ID in plaats van de verouderde request-authority"
Assert-True -Condition ($engineText -match 'AcquireTokenSilent\(scopes, sessionAccount\)\.WithTenantId\(tenantId\)') -Name "Stille WAM-tokens blijven tenantgebonden"
Assert-True -Condition ($engineText -notmatch '\.WithAuthority\(authority\)') -Name "WAM gebruikt geen verouderde request-authority"
Assert-True -Condition ($engineText -match 'GetCustomerApplication\(string tenantId\)') -Name "WAM kan een expliciete klanttenant-applicatie opbouwen"
Assert-True -Condition ($engineText -match 'CreateApplication\("organizations"\)') -Name "De eerste Partner Center-sessie behoudt de organizations-authority"
Assert-True -Condition ($engineText -match 'useTenantSpecificAuthority \? GetCustomerApplication\(tenantId\) : application') -Name "Klanttokens gebruiken een eigen tenant-authority"
Assert-True -Condition ($engineText -match '\$useTenantSpecificAuthority = -not \[string\]::Equals') -Name "De engine kiest alleen voor klanttenants een specifieke authority"
Assert-True -Condition ($engineText -match '\$State\.Customers = @\(Get-PartnerCenterCustomers -State \$State\)') -Name "Partnerlogin levert de klantenlijst in dezelfde WAM-sessie"
Assert-True -Condition ($engineText -match '\[void\]\(Ensure-GraphAuthenticationModule -State \$State\)') -Name "Graph-modulemetadata lekt niet naar workflowresultaten"
Assert-True -Condition ($engineText -match 'function Write-PartnerCenterCustomerCache') -Name "Partner Center-klanten worden via een tijdelijke cache overgedragen"
Assert-True -Condition ($engineText -match 'customerCount = \[int\]\$State\.Customers\.Count') -Name "Partnerlogin geeft een compact eindresultaat terug"
Assert-True -Condition ($engineText -match '\$context\.Response\.StatusCode = 204') -Name "Niet-OAuth localhost-verzoeken worden afgehandeld zonder de listener te sluiten"
Assert-True -Condition ($engineText -match '\[bool\]\$State\.IsOobe -and \[bool\]\$State\.BrowserInteractiveCompleted') -Name "OOBE gebruikt na de eerste login één gewone browser-SSO-flow per klanttenant"
Assert-True -Condition ($engineText -match '@\("default"\)') -Name "OOBE stuurt geen prompt=none gevolgd door een tweede callback"
Assert-True -Condition ($engineText -match 'function Resolve-AutopilotOrderIdGroupTag') -Name "Dynamische OrderID-regels worden veilig geanalyseerd"
Assert-True -Condition ($engineText -match '\$parameters\.GroupTag = \$GroupTag\.Trim\(\)') -Name "Een eenduidige OrderID-tag wordt als GroupTag aan het Community-script doorgegeven"
Assert-True -Condition ($engineText -match 'if \(\$parameters\.ContainsKey\("AddToGroup"\)\)') -Name "AddToGroup blijft een afzonderlijke statische groepsactie"

$customerCachePath = Join-Path ([IO.Path]::GetTempPath()) ("autopilot-gdap-customers-{0}.ndjson" -f ([guid]::NewGuid()))
$chunkState = [pscustomobject]@{
    CustomerCachePath = $customerCachePath
    Emitter = { param($event, $payload) }
}
$manyCustomers = 1..41 | ForEach-Object {
    [pscustomobject]@{
        tenantId = "00000000-0000-0000-0000-{0:D12}" -f $_
        customerName = "Klant $_"
        tenantDomain = "klant$_.example"
        displayName = "Klant $_ [klant$_.example]"
    }
}
& $module {
    param($state, $customers)
    [void](Write-PartnerCenterCustomerCache -State $state -Customers $customers)
} $chunkState $manyCustomers
$cachedCustomerLines = @(Get-Content -LiteralPath $customerCachePath -ErrorAction Stop)
Assert-Equal -Actual $cachedCustomerLines.Count -Expected 41 -Name "Klantenlijst wordt volledig in de tijdelijke cache geschreven"
Assert-True -Condition (($cachedCustomerLines[0] | ConvertFrom-Json).tenantId -match '^[0-9a-f-]{36}$') -Name "Tijdelijke klantenrecords bevatten uitsluitend platte overdrachtsvelden"
Remove-Item -LiteralPath $customerCachePath -Force -ErrorAction SilentlyContinue

if ($env:OS -eq "Windows_NT") {
    $wamReferences = @(& $module { Get-WamBridgeReferenceAssemblies -MsalPath "msal-test.dll" -BrokerPath "broker-test.dll" })
    $hasFormsReference = (@($wamReferences | Where-Object { $_ -match 'System\.Windows\.Forms\.dll$' })).Count -eq 1
    Assert-True -Condition $hasFormsReference -Name "WAM-bridge verwijst naar System.Windows.Forms"
    $hasNetstandardReference = (@($wamReferences | Where-Object { $_ -match 'netstandard\.dll$' })).Count -eq 1
    Assert-True -Condition $hasNetstandardReference -Name "WAM-bridge verwijst naar de netstandard-facade"
}

Assert-True -Condition ($engineText -match 'GetTopLevelWindow') -Name "WAM wordt aan het hoofdvenster van de app gekoppeld"

$customerError = & $module {
    param($record)
    Get-AutopilotGdapError -ErrorRecord $record
} (New-TestErrorRecord -Message "AADSTS90099: application has not been authorized in the tenant")
Assert-Equal -Actual $customerError.code -Expected "customerConsentRequired" -Name "Klantconsentfout is getypeerd"

$partnerError = & $module {
    param($record)
    Get-AutopilotGdapError -ErrorRecord $record
} (New-TestErrorRecord -Message "Partner Center https://api.partnercenter.microsoft.com returned AADSTS65001 consent required")
Assert-Equal -Actual $partnerError.code -Expected "partnerCenterConsentRequired" -Name "Partner Center-consentfout is getypeerd"

$pimError = & $module {
    param($record)
    Get-AutopilotGdapError -ErrorRecord $record
} (New-TestErrorRecord -Message "HTTP/1.1 403 Forbidden")
Assert-Equal -Actual $pimError.code -Expected "gdapPimDenied" -Name "GDAP/PIM-fout is getypeerd"

$unauthorizedErrorRecord = New-TestErrorRecord -Message "Response status code does not indicate success: Unauthorized (Unauthorized)."
$unauthorizedError = & $module {
    param($record)
    Get-AutopilotGdapError -ErrorRecord $record
} $unauthorizedErrorRecord
Assert-Equal -Actual $unauthorizedError.code -Expected "gdapPimDenied" -Name "Een afgewezen stil GDAP-token is getypeerd"
$isGraphAuthorizationFailure = & $module {
    param($record)
    Test-GraphAuthorizationFailure -ErrorRecord $record
} $unauthorizedErrorRecord
Assert-True -Condition $isGraphAuthorizationFailure -Name "401 activeert een eenmalige klanttenant-tokenverversing"
$wamCustomerBrokerErrorRecord = New-TestErrorRecord -Message "Exception calling 'Acquire' with '6' argument(s): 'WAM Error Error Code: 3399614467 Error Message: (pii) Internal Error Code: 558133256'"
$requiresCustomerBrowserFallback = & $module {
    param($record)
    Test-WamCustomerBrowserFallbackRequired -ErrorRecord $record
} $wamCustomerBrokerErrorRecord
Assert-True -Condition $requiresCustomerBrowserFallback -Name "Een tenant-specifieke WAM-brokerfout activeert browser-SSO voor de klant"
$wamRuntimeErrorRecord = New-TestErrorRecord -Message "System.Windows.Forms is not referenced"
$requiresCustomerBrowserFallbackForRuntimeError = & $module {
    param($record)
    Test-WamCustomerBrowserFallbackRequired -ErrorRecord $record
} $wamRuntimeErrorRecord
Assert-True -Condition (-not $requiresCustomerBrowserFallbackForRuntimeError) -Name "Een ontbrekende WAM-runtime wordt niet als klantbrowserfallback behandeld"
Assert-True -Condition ($engineText -match 'function Get-AutopilotProfilesForCurrentTenant') -Name "Profielen kunnen na een tokenverversing opnieuw worden opgehaald"
Assert-True -Condition ($engineText -match 'function Invoke-BrowserCustomerGraphFallback') -Name "WAM kan gericht naar browser-SSO voor een GDAP-klant terugvallen"
Assert-True -Condition ($engineText -match 'Windows WAM heeft voor .* geen GDAP-rolcontext ontvangen') -Name "De browserfallback meldt duidelijk waarom deze nodig is"
Assert-True -Condition ($engineText -match 'WAM kon voor .* geen bruikbare klanttenanttoken ophalen') -Name "Een WAM-brokerfout krijgt een klantgerichte browser-SSO-melding"
Assert-True -Condition ($engineText -match 'desktopCustomerSso') -Name "Desktop gebruikt voor iedere klanttenant de bewezen browser-SSO-route"
Assert-True -Condition ($engineText -match 'Test-WamCustomerBrowserFallbackRequired') -Name "Klanttenant-WAM-brokerfouten worden vóór een foutmelding onderschept"
Assert-True -Condition ($engineText -match 'BrowserSso') -Name "De browserfallback kan WAM uitsluitend voor de klantcontext omzeilen"
Assert-True -Condition ($engineText -match 'Connect-GraphTenant -State \$State -TenantId \$State\.TargetTenantId -Scopes \$script:GraphScopes -Interactive -ForceCustomerAccountSelection') -Name "WAM vraagt alleen bij een afgewezen token klanttenantbevestiging"
Assert-True -Condition ($engineText -match 'request = request\.WithTenantId\(tenantId\);') -Name "De WAM-klanttenantbevestiging vraagt altijd een tenantgebonden token"
Assert-True -Condition ($engineText -match 'Prompt\.SelectAccount') -Name "De eerste WAM-aanmelding gebruikt een accountkiezer"
Assert-True -Condition ($engineText -match 'Prompt\.ForceLogin') -Name "De WAM-klanttenantverversing hergebruikt geen cached guest-context"
Assert-True -Condition ($engineText -match 'request\.WithLoginHint\(sessionAccount\.Username\)') -Name "De WAM-klanttenantverversing houdt hetzelfde IT-Hulp-account aan"
Assert-True -Condition ($engineText -match 'De klanttenanttoken is vernieuwd\. Autopilot-profielen worden opnieuw opgehaald\.') -Name "Tokenverversing geeft duidelijke voortgang terug"

$claimPayloadJson = '{"tid":"customer-tenant","iss":"https://login.microsoftonline.com/customer-tenant/v2.0","ver":"2.0","aud":"https://graph.microsoft.com","appid":"capturetech-app","scp":"Group.Read.All"}'
$claimPayload = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($claimPayloadJson)).TrimEnd("=").Replace("+", "-").Replace("/", "_")
$claimsDiagnostic = & $module {
    param($token)
    Get-GraphTokenDiagnostic -AccessToken $token
} ("header.$claimPayload.signature")
Assert-True -Condition ([bool]$claimsDiagnostic.available) -Name "Graph-tokenmetadata kan zonder tokenuitvoer worden gelezen"
Assert-Equal -Actual $claimsDiagnostic.tenantId -Expected "customer-tenant" -Name "Graph-tokenmetadata bevat de doeltenant"
Assert-Equal -Actual $claimsDiagnostic.audience -Expected "https://graph.microsoft.com" -Name "Graph-tokenmetadata bevat de resource"
Assert-Equal -Actual $claimsDiagnostic.issuer -Expected "https://login.microsoftonline.com/customer-tenant/v2.0" -Name "Graph-tokenmetadata bevat de issuer zonder tokeninhoud te tonen"
Assert-Equal -Actual $claimsDiagnostic.tokenVersion -Expected "2.0" -Name "Graph-tokenmetadata bevat de tokenversie"
$guestHasDirectoryRoleContext = & $module {
    param($token)
    Test-GraphTokenHasDirectoryRoleContext -AccessToken $token
} ("header.$claimPayload.signature")
Assert-True -Condition (-not $guestHasDirectoryRoleContext) -Name "Een B2B-token zonder wids activeert de klantbrowserfallback"
$rolePayloadJson = '{"tid":"customer-tenant","wids":["role-id"]}'
$rolePayload = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($rolePayloadJson)).TrimEnd("=").Replace("+", "-").Replace("/", "_")
$roleHasDirectoryRoleContext = & $module {
    param($token)
    Test-GraphTokenHasDirectoryRoleContext -AccessToken $token
} ("header.$rolePayload.signature")
Assert-True -Condition $roleHasDirectoryRoleContext -Name "Een GDAP-token met wids behoudt de WAM-klantcontext"
Assert-True -Condition ($engineText -match 'Test-CurrentGraphGroupAccess') -Name "Een tweede Intune-fout controleert de standaard Graph-toegang"
Assert-True -Condition ($engineText -match 'Invoke-WebRequest -Method GET -Uri "https://graph\.microsoft\.com/v1\.0/groups\?%24top=1&%24select=id"') -Name "De Graph-toegangscontrole gebruikt de ruwe Bearer-token"

$netstandardError = & $module {
    param($record)
    Get-AutopilotGdapError -ErrorRecord $record
} (New-TestErrorRecord -Message "The type System.Object is defined in an assembly that is not referenced: netstandard, Version=2.0.0.0")
Assert-Equal -Actual $netstandardError.code -Expected "wamUnavailable" -Name "Ontbrekende netstandard-facade is een WAM-fout"

$legacyTokenPath = Join-Path ([IO.Path]::GetTempPath()) ("autopilot-gdap-legacy-{0}.token" -f ([guid]::NewGuid()))
[IO.File]::WriteAllText($legacyTokenPath, "legacy-token")
$legacyState = [pscustomobject]@{
    LegacyPartnerCenterTokenRetired = $false
    PartnerCenterTokenPath = $legacyTokenPath
    Emitter = { param($event, $payload) }
}
& $module {
    param($state)
    Retire-LegacyPartnerCenterToken -State $state
} $legacyState
Assert-True -Condition (-not (Test-Path -LiteralPath $legacyTokenPath)) -Name "Legacy Partner Center-token wordt verwijderd"
Assert-True -Condition ([bool]$legacyState.LegacyPartnerCenterTokenRetired) -Name "Legacy-tokenmigratie wordt gemarkeerd"

$resetState = [pscustomobject]@{
    PartnerCenterAccessToken = "token"
    GraphAccessToken = "graph-token"
    BrowserInteractiveCompleted = $true
    SessionAccount = "it-hulp@capturetech.example"
    SessionHomeAccountId = "account-id"
    ConnectedAccount = "it-hulp@capturetech.example"
    Customers = @([pscustomobject]@{ tenantId = "tenant" })
    Profiles = @([pscustomobject]@{ profileId = "profile" })
    TargetTenantId = "tenant"
    CustomerAuthMode = "browserSsoFallback"
    RegistrationCompleted = $true
    AuthMode = "wam"
    Emitter = { param($event, $payload) }
}
$resetResult = & $module {
    param($state)
    function Disconnect-MgGraph { [CmdletBinding()] param() }
    Invoke-ResetSession -State $state
} $resetState
Assert-True -Condition ([bool]$resetResult.sessionReset) -Name "Sessie-reset geeft een expliciet resultaat"
Assert-Equal -Actual $resetState.SessionAccount -Expected "" -Name "Sessie-reset wist het account"
Assert-Equal -Actual $resetState.TargetTenantId -Expected "" -Name "Sessie-reset wist de klanttenant"
Assert-Equal -Actual $resetState.CustomerAuthMode -Expected "" -Name "Sessie-reset wist de bron van de klantcontext"
Assert-True -Condition ([string]::IsNullOrEmpty([string]$resetState.GraphAccessToken)) -Name "Sessie-reset wist de Graph-token uit het workergeheugen"
Assert-True -Condition (-not [bool]$resetState.RegistrationCompleted) -Name "Sessie-reset blokkeert herstart opnieuw"

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
}

Write-Host "Autopilot GDAP engine-contracttests geslaagd." -ForegroundColor Green
