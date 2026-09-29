$script:PublicClientId = "6a87f18c-ab0a-4ef9-bb1c-587ae884b8e0"
$script:PartnerTenantId = "26aaae92-5737-48a2-b00c-27aff5b013e7"
$script:MinimumGraphAuthenticationVersion = [version]"2.38.0"
$script:PartnerCenterScope = "https://api.partnercenter.microsoft.com/user_impersonation"
$script:GraphScopes = @(
    "DeviceManagementServiceConfig.ReadWrite.All",
    "DeviceManagementServiceConfig.Read.All",
    "Group.Read.All",
    "GroupMember.ReadWrite.All",
    "Directory.Read.All"
)

function Get-AutopilotGdapDataPath {
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { return $env:LOCALAPPDATA }
    if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) { return $env:TEMP }
    return [IO.Path]::GetTempPath()
}

function Test-OobeEnvironment {
    if ([Environment]::UserName -match '^defaultuser') { return $true }
    foreach ($path in @("HKLM:\SYSTEM\Setup", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State")) {
        try {
            $setup = Get-ItemProperty -Path $path -ErrorAction Stop
            foreach ($name in @("OOBEInProgress", "SystemSetupInProgress", "SetupInProgress")) {
                $property = $setup.PSObject.Properties[$name]
                if ($property -and [int]$property.Value -eq 1) { return $true }
            }
            $imageState = [string]$setup.ImageState
            if ($imageState -match 'OOBE') { return $true }
        }
        catch { }
    }
    return $false
}

function Resolve-AuthenticationMode {
    param([AllowNull()][object]$IsOobe)
    if ($null -eq $IsOobe) { $IsOobe = Test-OobeEnvironment }
    if ([bool]$IsOobe) { return "browserOobe" }
    return "wam"
}

function Test-WamInteractiveSession {
    param([AllowNull()][object]$IsOobe)
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return $false }
    if ($null -eq $IsOobe) { $IsOobe = Test-OobeEnvironment }
    if ([bool]$IsOobe) { return $false }
    return ([string]$env:CAPTURETECH_PARENT_HWND -match '^\d+$')
}

function New-AutopilotGdapState {
    param([Parameter(Mandatory = $true)][scriptblock]$Emitter)

    $localDataPath = Get-AutopilotGdapDataPath
    $tokenFolder = Join-Path $localDataPath "CaptureTech\AutopilotGDAP"
    $customerCachePath = [string]$env:CAPTURETECH_CUSTOMER_CACHE_PATH
    if ([string]::IsNullOrWhiteSpace($customerCachePath)) {
        $customerCachePath = Join-Path $tokenFolder "partner-center-customers.ndjson"
    }
    $isOobe = Test-OobeEnvironment
    [pscustomobject]@{
        Emitter = $Emitter
        PublicClientId = $script:PublicClientId
        PartnerTenantId = $script:PartnerTenantId
        AuthMode = Resolve-AuthenticationMode -IsOobe $isOobe
        IsOobe = $isOobe
        WamAvailable = Test-WamInteractiveSession -IsOobe $isOobe
        PartnerCenterTokenPath = Join-Path $tokenFolder "partnercenter.v1.token"
        PartnerCenterAccessToken = $null
        GraphAccessToken = $null
        BrowserCancellationPath = Join-Path $tokenFolder "browser-auth.cancel"
        BrowserInteractiveCompleted = $false
        WamBridgeReady = $false
        SessionAccount = ""
        SessionHomeAccountId = ""
        LegacyPartnerCenterTokenRetired = $false
        CustomerCachePath = $customerCachePath
        Customers = @()
        Profiles = @()
        TargetTenantId = ""
        # The partner session can use WAM while a specific GDAP customer
        # needs the browser's role-bearing SSO token. Keep that distinction
        # in worker memory only, so the UI can accurately describe it.
        CustomerAuthMode = ""
        ConnectedAccount = ""
        RegistrationCompleted = $false
    }
}

function Throw-AutopilotGdapError {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Details
    )
    $exception = [System.InvalidOperationException]::new($Message)
    $exception.Data["capturetechErrorCode"] = $Code
    $exception.Data["capturetechErrorMessage"] = $Message
    if (-not [string]::IsNullOrWhiteSpace($Details)) { $exception.Data["capturetechErrorDetails"] = $Details }
    throw $exception
}

function Get-AutopilotGdapError {
    param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $exception = $ErrorRecord.Exception
    $exceptionDetails = [System.Collections.Generic.List[string]]::new()
    while ($exception) {
        if ($exception.Data -and $exception.Data.Contains("capturetechErrorCode")) {
            return [pscustomobject]@{
                code = [string]$exception.Data["capturetechErrorCode"]
                message = [string]$exception.Data["capturetechErrorMessage"]
                details = [string]$exception.Data["capturetechErrorDetails"]
            }
        }
        $typeName = [string]$exception.GetType().FullName
        if (-not [string]::IsNullOrWhiteSpace($typeName)) { [void]$exceptionDetails.Add($typeName) }
        if (-not [string]::IsNullOrWhiteSpace([string]$exception.Message)) { [void]$exceptionDetails.Add([string]$exception.Message) }
        $exception = $exception.InnerException
    }

    $details = (@($exceptionDetails | Select-Object -Unique) -join " | ")
    if ([string]::IsNullOrWhiteSpace($details)) { $details = ($ErrorRecord | Out-String).Trim() }
    $code = "operationFailed"
    $message = $details
    if ($details -match 'api\.partnercenter\.microsoft\.com.*(consent|AADSTS65001)|Partner Center.*(consent|AADSTS65001)') {
        $code = "partnerCenterConsentRequired"
        $message = "Partner Center-consent ontbreekt voor deze app. Voer de partner-inrichting opnieuw uit met een bevoegd account."
    }
    elseif ($details -match 'AADSTS90099|AADSTS700016|AADSTS65001|not been authorized|application.*not found') {
        $code = "customerConsentRequired"
        $message = "De CaptureTech-app is nog niet geautoriseerd in deze klanttenant. Laat een Global Administrator eerst klant-appconsent verlenen."
    }
    elseif ($details -match '401|Unauthorized|InvalidAuthenticationToken') {
        $code = "gdapPimDenied"
        $message = "Microsoft Graph accepteert het GDAP/PIM-token voor deze klant niet. Controleer je actieve GDAP/PIM-rollen en probeer de klantverbinding opnieuw."
    }
    elseif ($details -match '403|Forbidden|Authorization_RequestDenied') {
        $code = "gdapPimDenied"
        $message = "Toegang geweigerd. Controleer of je actieve GDAP/PIM-rollen voor deze klant voldoende zijn."
    }
    elseif ($details -match 'canceled|cancelled|user_cancelled|authentication_canceled') {
        $code = "authCancelled"
        $message = "De aanmelding is geannuleerd."
    }
    elseif ($details -match '(netstandard.*(not referenced|assembly)|(not referenced|assembly).*netstandard)|System\.Windows\.Forms.*not referenced') {
        $code = "wamUnavailable"
        $message = "De .NET-onderdelen voor Windows Web Account Manager kunnen niet worden geladen. Herstel .NET Framework 4.8 en start de app opnieuw."
    }
    elseif ($details -match 'WAM|Web Account Manager|BrokerPlugin|Parent.*window|interactive Windows user') {
        $code = "wamUnavailable"
        $message = "Windows Web Account Manager kan niet worden gestart. Controleer de technische uitvoer voor de exacte Windows- of brokerfout."
    }
    elseif ($details -match 'MsalUiRequiredException|interaction_required|login_required|claims challenge|conditional access|AADSTS50076|AADSTS50079|AADSTS50158') {
        $code = "authenticationRequired"
        $message = "Extra verificatie is nodig voor het geselecteerde account."
    }
    [pscustomobject]@{ code = $code; message = $message; details = $details }
}

function Test-GraphAuthorizationFailure {
    param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    # Invoke-MgGraphRequest wraps HTTP response details differently between
    # Graph SDK releases. Inspect the complete exception chain plus PowerShell
    # rendering so a rejected silent customer-tenant token reliably gets one
    # WAM refresh attempt.
    $details = [System.Collections.Generic.List[string]]::new()
    $exception = $ErrorRecord.Exception
    while ($exception) {
        if (-not [string]::IsNullOrWhiteSpace([string]$exception.Message)) {
            [void]$details.Add([string]$exception.Message)
        }
        $exception = $exception.InnerException
    }
    try {
        $rendered = ($ErrorRecord | Out-String).Trim()
        if (-not [string]::IsNullOrWhiteSpace($rendered)) { [void]$details.Add($rendered) }
    }
    catch { }
    return [bool](($details -join " | ") -match '(?i)(\b401\b|\b403\b|Unauthorized|Forbidden|InvalidAuthenticationToken|Authorization_RequestDenied)')
}

function Test-WamCustomerBrowserFallbackRequired {
    param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    # The partner WAM session can be healthy while tenant-specific WAM token
    # acquisition fails inside the broker. In particular, WAM error 0xCAA20003
    # (decimal 3399614467) has been observed for GDAP B2B customer contexts.
    # This is distinct from a missing broker/runtime and is safe to route to
    # the targeted browser SSO flow for the selected customer only.
    $details = [System.Collections.Generic.List[string]]::new()
    $exception = $ErrorRecord.Exception
    while ($exception) {
        if (-not [string]::IsNullOrWhiteSpace([string]$exception.GetType().FullName)) {
            [void]$details.Add([string]$exception.GetType().FullName)
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$exception.Message)) {
            [void]$details.Add([string]$exception.Message)
        }
        $exception = $exception.InnerException
    }
    try {
        $rendered = ($ErrorRecord | Out-String).Trim()
        if (-not [string]::IsNullOrWhiteSpace($rendered)) { [void]$details.Add($rendered) }
    }
    catch { }
    $text = $details -join " | "
    return [bool]($text -match '(?i)WAM Error Error Code:\s*(3399614467|0xCAA20003)|WAM Error.*Internal Error Code')
}

function Get-GraphResponseDiagnostic {
    param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $response = $null
    $exception = $ErrorRecord.Exception
    while ($exception -and $null -eq $response) {
        $responseProperty = $exception.PSObject.Properties["Response"]
        if ($responseProperty -and $null -ne $responseProperty.Value) { $response = $responseProperty.Value }
        $exception = $exception.InnerException
    }

    $statusCode = ""
    $reasonPhrase = ""
    $serviceCode = ""
    $serviceMessage = ""
    if ($response) {
        try { $statusCode = [string][int]$response.StatusCode } catch { }
        try { $reasonPhrase = [string]$response.ReasonPhrase } catch { }
        try {
            $body = ""
            $contentProperty = $response.PSObject.Properties["Content"]
            if ($contentProperty -and $null -ne $contentProperty.Value) {
                $body = [string]$contentProperty.Value.ReadAsStringAsync().GetAwaiter().GetResult()
            }
            elseif ($response.PSObject.Methods["GetResponseStream"]) {
                $stream = $response.GetResponseStream()
                if ($stream) {
                    $reader = [System.IO.StreamReader]::new($stream)
                    try { $body = $reader.ReadToEnd() }
                    finally { $reader.Dispose() }
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($body)) {
                try {
                    $parsed = $body | ConvertFrom-Json -ErrorAction Stop
                    $serviceCode = [string]$parsed.error.code
                    $serviceMessage = [string]$parsed.error.message
                }
                catch {
                    $serviceMessage = $body
                }
            }
        }
        catch { }
    }
    if ([string]::IsNullOrWhiteSpace($serviceMessage)) { $serviceMessage = [string]$ErrorRecord.Exception.Message }
    if ($serviceMessage.Length -gt 500) { $serviceMessage = $serviceMessage.Substring(0, 500) }
    [pscustomobject]@{
        statusCode = $statusCode
        reasonPhrase = $reasonPhrase
        serviceCode = $serviceCode
        serviceMessage = $serviceMessage
    }
}

function Get-GraphTokenDiagnostic {
    param([Parameter(Mandatory = $true)][string]$AccessToken)

    # Only parse non-secret metadata from the JWT payload. The access token,
    # user ID and username are deliberately never written to the event log.
    try {
        $segments = $AccessToken.Split('.')
        if ($segments.Count -lt 2) { throw "Geen JWT-payload gevonden." }
        $payload = $segments[1].Replace('-', '+').Replace('_', '/')
        switch ($payload.Length % 4) {
            2 { $payload += "==" }
            3 { $payload += "=" }
            1 { throw "Ongeldige JWT-payloadlengte." }
        }
        $claims = ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json -ErrorAction Stop)
        $scope = [string]$claims.scp
        if ($scope.Length -gt 500) { $scope = $scope.Substring(0, 500) }
        $claimNames = @($claims.PSObject.Properties.Name | Sort-Object) -join ','
        if ($claimNames.Length -gt 500) { $claimNames = $claimNames.Substring(0, 500) }
        $cnfProperty = $claims.PSObject.Properties['cnf']
        $cnfKeys = ''
        if ($cnfProperty -and $null -ne $cnfProperty.Value) {
            try { $cnfKeys = @($cnfProperty.Value.PSObject.Properties.Name | Sort-Object) -join ',' } catch { $cnfKeys = 'aanwezig' }
        }
        $clientCapabilities = ''
        $xmsCcProperty = $claims.PSObject.Properties['xms_cc']
        if ($xmsCcProperty -and $null -ne $xmsCcProperty.Value) {
            try { $clientCapabilities = ($xmsCcProperty.Value | ConvertTo-Json -Compress -Depth 4) } catch { $clientCapabilities = 'aanwezig' }
        }
        if ($clientCapabilities.Length -gt 200) { $clientCapabilities = $clientCapabilities.Substring(0, 200) }
        $authMethods = ''
        $amrProperty = $claims.PSObject.Properties['amr']
        if ($amrProperty -and $null -ne $amrProperty.Value) { $authMethods = @($amrProperty.Value) -join ',' }
        $widsProperty = $claims.PSObject.Properties['wids']
        $rolesProperty = $claims.PSObject.Properties['roles']
        $directoryRoleClaimCount = if ($widsProperty -and $null -ne $widsProperty.Value) { @($widsProperty.Value).Count } else { 0 }
        $appRoleClaimCount = if ($rolesProperty -and $null -ne $rolesProperty.Value) { @($rolesProperty.Value).Count } else { 0 }
        return [pscustomobject]@{
            available = $true
            tenantId = [string]$claims.tid
            audience = [string]$claims.aud
            issuer = [string]$claims.iss
            tokenVersion = [string]$claims.ver
            applicationId = if (-not [string]::IsNullOrWhiteSpace([string]$claims.appid)) { [string]$claims.appid } else { [string]$claims.azp }
            scopes = $scope
            identityType = [string]$claims.idtyp
            claimNames = $claimNames
            proofOfPossession = [bool]($cnfProperty -and $null -ne $cnfProperty.Value)
            proofOfPossessionKeys = $cnfKeys
            clientCapabilities = $clientCapabilities
            authMethods = $authMethods
            directoryRoleClaimCount = $directoryRoleClaimCount
            appRoleClaimCount = $appRoleClaimCount
        }
    }
    catch {
        return [pscustomobject]@{
            available = $false
            tenantId = ""
            audience = ""
            issuer = ""
            tokenVersion = ""
            applicationId = ""
            scopes = ""
            identityType = ""
            claimNames = ""
            proofOfPossession = $false
            proofOfPossessionKeys = ""
            clientCapabilities = ""
            authMethods = ""
            directoryRoleClaimCount = 0
            appRoleClaimCount = 0
        }
    }
}

function Write-GraphTokenDiagnostic {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Token,
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][string]$RequestedTenantId
    )

    $diagnostic = Get-GraphTokenDiagnostic -AccessToken ([string]$Token.accessToken)
    $contextScopes = (@($Context.Scopes) -join ",")
    if ($contextScopes.Length -gt 500) { $contextScopes = $contextScopes.Substring(0, 500) }
    $message = "Graph-tokencontrole (geen tokeninhoud): aangevraagdTid=$RequestedTenantId; tokenTid=$($diagnostic.tenantId); contextTid=$($Context.TenantId); iss=$($diagnostic.issuer); ver=$($diagnostic.tokenVersion); aud=$($diagnostic.audience); appId=$($diagnostic.applicationId); scp=$($diagnostic.scopes); idtyp=$($diagnostic.identityType); pop=$($diagnostic.proofOfPossession); popKeys=$($diagnostic.proofOfPossessionKeys); xmsCc=$($diagnostic.clientCapabilities); amr=$($diagnostic.authMethods); claimNames=$($diagnostic.claimNames); wids=$($diagnostic.directoryRoleClaimCount); roles=$($diagnostic.appRoleClaimCount); contextScopes=$contextScopes"
    Write-EngineEvent -State $State -Message $message -Level info -Technical $true
}

function Test-GraphTokenHasDirectoryRoleContext {
    param([Parameter(Mandatory = $true)][string]$AccessToken)

    if ([string]::IsNullOrWhiteSpace($AccessToken)) { return $false }
    $diagnostic = Get-GraphTokenDiagnostic -AccessToken $AccessToken
    # A GDAP customer token that works with Intune contains the customer-side
    # directory-role context in `wids`. WAM can instead issue a structurally
    # valid B2B guest token without that context; that token is rejected by
    # both Graph's directory endpoints and Intune.
    return [bool]($diagnostic.available -and [int]$diagnostic.directoryRoleClaimCount -gt 0)
}

function Test-CurrentGraphGroupAccess {
    param([Parameter(Mandatory = $true)][object]$State)

    try {
        if ([string]::IsNullOrWhiteSpace([string]$State.GraphAccessToken)) {
            throw "De directe Graph-tokencontrole mist een actieve klanttenanttoken."
        }
        $headers = @{ Authorization = "Bearer $($State.GraphAccessToken)"; Accept = "application/json" }
        [void](Invoke-WebRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups?%24top=1&%24select=id" -Headers $headers -UseBasicParsing -ErrorAction Stop)
        Write-EngineEvent -State $State -Message "Graph-toegangscontrole met directe Bearer-token: de klanttenanttoken werkt voor de standaard groeps-API." -Level info -Technical $true
        return [pscustomobject]@{ succeeded = $true; diagnostic = $null }
    }
    catch {
        $diagnostic = Get-GraphResponseDiagnostic -ErrorRecord $_
        Write-EngineEvent -State $State -Message "Graph-toegangscontrole met directe Bearer-token: HTTP $($diagnostic.statusCode) $($diagnostic.reasonPhrase); code=$($diagnostic.serviceCode); bericht=$($diagnostic.serviceMessage)" -Level warning -Technical $true
        return [pscustomobject]@{ succeeded = $false; diagnostic = $diagnostic }
    }
}

function Write-EngineEvent {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [ValidateSet("log", "status", "progress")][string]$Event = "log",
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("info", "success", "warning", "error")][string]$Level = "info",
        [bool]$Technical = $false,
        [ValidateSet("login", "customer", "configure", "register", "complete")][string]$Step
    )
    $payload = [ordered]@{
        message = $Message
        level = $Level
        technical = $Technical
    }
    if ($Step) { $payload.step = $Step }
    & $State.Emitter $Event $payload
}

function Ensure-GraphAuthenticationModule {
    param([Parameter(Mandatory = $true)][object]$State)

    $available = @(Get-Module -ListAvailable -Name Microsoft.Graph.Authentication | Where-Object { $_.Version -ge $script:MinimumGraphAuthenticationVersion })
    if ($available.Count -eq 0) {
        Write-EngineEvent -State $State -Message "Microsoft Graph-module wordt geïnstalleerd voor de huidige Windows-gebruiker." -Level info
        Install-Module -Name Microsoft.Graph.Authentication -MinimumVersion $script:MinimumGraphAuthenticationVersion -Scope CurrentUser -Force -AllowClobber -Repository PSGallery -ErrorAction Stop | Out-Null
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop -Verbose:$false | Out-Null
    $module = Get-Module -Name Microsoft.Graph.Authentication | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $module -or $module.Version -lt $script:MinimumGraphAuthenticationVersion) {
        Throw-AutopilotGdapError -Code "wamUnavailable" -Message "Microsoft Graph Authentication $($script:MinimumGraphAuthenticationVersion) of hoger is vereist voor WAM."
    }
    return $module
}

function Retire-LegacyPartnerCenterToken {
    param([Parameter(Mandatory = $true)][object]$State)
    if ($State.LegacyPartnerCenterTokenRetired) { return }
    $State.LegacyPartnerCenterTokenRetired = $true
    if (Test-Path -LiteralPath $State.PartnerCenterTokenPath) {
        Remove-Item -LiteralPath $State.PartnerCenterTokenPath -Force -ErrorAction SilentlyContinue
        Write-EngineEvent -State $State -Message "De oude lokale Partner Center-token-cache is verwijderd; deze app bewaart geen eigen refresh-tokenbestand meer." -Level info -Technical $true
    }
}

function Test-BrowserAuthorizationCallback {
    param(
        [AllowEmptyString()][string]$Code,
        [AllowEmptyString()][string]$Error,
        [AllowEmptyString()][string]$ErrorDescription
    )

    # HttpListener receives every request below the localhost prefix. Edge can
    # ask for a favicon or another browser resource before the actual OAuth
    # redirect arrives. Such a request must never consume the one callback
    # listener that is waiting for the authorization result.
    return (
        -not [string]::IsNullOrWhiteSpace($Code) -or
        -not [string]::IsNullOrWhiteSpace($Error) -or
        -not [string]::IsNullOrWhiteSpace($ErrorDescription)
    )
}

function Invoke-BrowserAuthorizationCodeFlow {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$AuthorizeUri,
        [Parameter(Mandatory = $true)][string]$RedirectUri,
        [Parameter(Mandatory = $true)][scriptblock]$ExchangeCode,
        [Parameter(Mandatory = $true)][string]$Purpose
    )

    $listener = New-Object System.Net.HttpListener
    $cancellationPath = [string]$State.BrowserCancellationPath
    try {
        # A separate, native Tauri command can place this marker when the
        # operator chooses to open the customer-specific admin-consent page.
        # Remove an old marker before every browser flow so a previous action
        # can never cancel a new login.
        if (-not [string]::IsNullOrWhiteSpace($cancellationPath)) {
            Remove-Item -LiteralPath $cancellationPath -Force -ErrorAction SilentlyContinue
        }
        $listener.Prefixes.Add($RedirectUri)
        $listener.Start()
    }
    catch {
        $listener.Close()
        throw "$Purpose kan de lokale callback niet starten op $RedirectUri. Sluit een andere appinstantie en probeer opnieuw. Details: $($_.Exception.Message)"
    }

    try {
        Write-EngineEvent -State $State -Message "$Purpose opent in je standaardbrowser. Meld aan met je IT-Hulp-account." -Level info
        Start-Process $AuthorizeUri -ErrorAction Stop
        $timeoutAt = [DateTime]::UtcNow.AddMinutes(5)
        while ($true) {
            $result = $listener.BeginGetContext($null, $null)
            while (-not $result.AsyncWaitHandle.WaitOne(250)) {
                if (-not [string]::IsNullOrWhiteSpace($cancellationPath) -and (Test-Path -LiteralPath $cancellationPath)) {
                    Remove-Item -LiteralPath $cancellationPath -Force -ErrorAction SilentlyContinue
                    throw "$Purpose is onderbroken om de klant-app in te stellen. Voltooi de eenmalige admin consent en kies daarna opnieuw Verbinden."
                }
                if ([DateTime]::UtcNow -ge $timeoutAt) {
                    throw "De browseraanmelding duurde langer dan vijf minuten."
                }
            }

            $context = $listener.EndGetContext($result)
            $query = $context.Request.QueryString
            $code = [string]$query["code"]
            $error = [string]$query["error"]
            $description = [string]$query["error_description"]
            if (-not (Test-BrowserAuthorizationCallback -Code $code -Error $error -ErrorDescription $description)) {
                # A browser resource request (for example /favicon.ico) is not
                # an OAuth callback. Reply cleanly and remain available for
                # the actual ?code= or ?error= redirect on this same port.
                try {
                    $context.Response.StatusCode = 204
                    $context.Response.Close()
                }
                catch {
                    # The browser may already have abandoned an auxiliary
                    # request. It still must not affect the OAuth callback.
                }
                Write-EngineEvent -State $State -Message "$Purpose negeert een lokale browserrequest zonder OAuth-callback." -Level info -Technical $true
                continue
            }

            $success = -not [string]::IsNullOrWhiteSpace($code)
            $html = if ($success) {
                "<html><body><h2>Aanmelding voltooid</h2><p>U kunt dit venster sluiten en teruggaan naar CaptureTech Autopilot GDAP.</p></body></html>"
            } else {
                "<html><body><h2>Aanmelding niet voltooid</h2><p>U kunt dit venster sluiten.</p></body></html>"
            }
            $bytes = [Text.Encoding]::UTF8.GetBytes($html)
            $context.Response.ContentType = "text/html; charset=utf-8"
            $context.Response.ContentLength64 = $bytes.Length
            $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $context.Response.OutputStream.Close()
            if (-not $success) {
                if ([string]::IsNullOrWhiteSpace($description)) { $description = $error }
                throw "$Purpose is afgebroken: $description"
            }
            return & $ExchangeCode $code
        }
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($cancellationPath)) {
            Remove-Item -LiteralPath $cancellationPath -Force -ErrorAction SilentlyContinue
        }
        if ($listener.IsListening) { $listener.Stop() }
        $listener.Close()
    }
}

function Get-BrowserGraphAccessToken {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$TenantId,
        [Parameter(Mandatory = $true)][string[]]$Scopes
    )
    $scope = (($Scopes + @("openid", "profile", "offline_access")) | Select-Object -Unique) -join " "
    $authority = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0"
    $redirectUri = "http://localhost:8766/"
    # For a desktop WAM session this preserves the selected IT-Hulp account
    # when a customer needs browser SSO for its GDAP role context. It is only
    # a hint: Conditional Access and account selection still stay in Entra.
    $loginHint = [string]$State.SessionAccount
    $loginHintParameter = if ([string]::IsNullOrWhiteSpace($loginHint)) { "" } else { "&login_hint=$([uri]::EscapeDataString($loginHint))" }
    # In OOBE a failed prompt=none can produce a second redirect while Edge is
    # still handling the first localhost callback. Use one ordinary browser
    # SSO request for a subsequent customer tenant instead: browser cookies
    # are reused silently where possible, while Entra can still request MFA or
    # account selection in the same flow.
    $prompts = if ([bool]$State.IsOobe -and [bool]$State.BrowserInteractiveCompleted) {
        @("default")
    }
    elseif ($State.BrowserInteractiveCompleted) {
        @("none", "select_account")
    }
    else {
        @("select_account")
    }
    foreach ($prompt in $prompts) {
        $promptParameter = if ($prompt -eq "default") { "" } else { "&prompt=$prompt" }
        $authorizeUri = "$authority/authorize?client_id=$([uri]::EscapeDataString($State.PublicClientId))&response_type=code&redirect_uri=$([uri]::EscapeDataString($redirectUri))&response_mode=query&scope=$([uri]::EscapeDataString($scope))$promptParameter$loginHintParameter"
        $exchange = {
            param([string]$Code)
            try {
                Invoke-RestMethod -Method POST -Uri "$authority/token" -Body @{
                    grant_type = "authorization_code"
                    client_id = $State.PublicClientId
                    code = $Code
                    redirect_uri = $redirectUri
                    scope = $scope
                } -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
            }
            catch {
                $detail = $_.ErrorDetails.Message
                if ([string]::IsNullOrWhiteSpace($detail)) { $detail = $_.Exception.Message }
                throw "Graph-token ophalen mislukt: $detail"
            }
        }.GetNewClosure()
        try {
            $token = Invoke-BrowserAuthorizationCodeFlow -State $State -AuthorizeUri $authorizeUri -RedirectUri $redirectUri -ExchangeCode $exchange -Purpose "Microsoft Graph-aanmelding"
            $State.BrowserInteractiveCompleted = $true
            return [pscustomobject]@{ accessToken = [string]$token.access_token; account = ""; homeAccountId = ""; tenantId = $TenantId }
        }
        catch {
            if ($prompt -eq "none" -and $_.Exception.Message -match 'login_required|interaction_required|AADSTS50058') { continue }
            throw
        }
    }
    Throw-AutopilotGdapError -Code "authenticationRequired" -Message "De browser-SSO-sessie kon niet worden hergebruikt."
}

function Get-MsalAssemblyPath {
    param(
        [Parameter(Mandatory = $true)][object]$Module,
        [Parameter(Mandatory = $true)][string]$FileName
    )
    $matches = @(Get-ChildItem -LiteralPath $Module.ModuleBase -Filter $FileName -File -Recurse -ErrorAction SilentlyContinue)
    if ($matches.Count -eq 0) { return $null }
    $desktopMatch = @($matches | Where-Object { $_.FullName -match '[\\/]Dependencies[\\/]Desktop[\\/]' } | Select-Object -First 1)
    if ($desktopMatch.Count -gt 0) { return [string]$desktopMatch[0].FullName }
    return [string]$matches[0].FullName
}

function Get-WamBridgeReferenceAssemblies {
    param(
        [Parameter(Mandatory = $true)][string]$MsalPath,
        [Parameter(Mandatory = $true)][string]$BrokerPath
    )

    # Microsoft.Identity.Client.Broker exposes a Windows Forms overload for
    # WithParentActivityOrWindow. Add-Type in Windows PowerShell 5.1 does not
    # automatically reference either Windows Forms or the .NET Framework
    # netstandard facade used by the MSAL assemblies. Include both explicitly.
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $formsAssemblyPath = [string][System.Windows.Forms.IWin32Window].Assembly.Location
        if ([string]::IsNullOrWhiteSpace($formsAssemblyPath) -or -not (Test-Path -LiteralPath $formsAssemblyPath)) {
            throw "System.Windows.Forms kon niet als WAM-bridgeverwijzing worden gevonden."
        }

        $netstandardCandidates = [System.Collections.Generic.List[string]]::new()
        try {
            $loadedNetstandard = @([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object {
                try { $_.GetName().Name -eq "netstandard" -and -not [string]::IsNullOrWhiteSpace([string]$_.Location) }
                catch { $false }
            } | Select-Object -First 1)
            if ($loadedNetstandard.Count -gt 0) { [void]$netstandardCandidates.Add([string]$loadedNetstandard[0].Location) }
        }
        catch { }
        try {
            $runtimeDirectory = [System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
            if (-not [string]::IsNullOrWhiteSpace($runtimeDirectory)) {
                [void]$netstandardCandidates.Add((Join-Path $runtimeDirectory "Facades\\netstandard.dll"))
            }
        }
        catch { }
        foreach ($frameworkPath in @(
            (Join-Path $env:WINDIR "Microsoft.NET\\Framework64\\v4.0.30319\\Facades\\netstandard.dll"),
            (Join-Path $env:WINDIR "Microsoft.NET\\Framework\\v4.0.30319\\Facades\\netstandard.dll")
        )) {
            if (-not [string]::IsNullOrWhiteSpace([string]$frameworkPath)) { [void]$netstandardCandidates.Add($frameworkPath) }
        }
        try {
            $referenceAssembliesRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)) "Reference Assemblies\\Microsoft\\Framework\\.NETFramework"
            if (Test-Path -LiteralPath $referenceAssembliesRoot) {
                foreach ($candidate in @(Get-ChildItem -LiteralPath $referenceAssembliesRoot -Filter "netstandard.dll" -File -Recurse -ErrorAction SilentlyContinue)) {
                    [void]$netstandardCandidates.Add([string]$candidate.FullName)
                }
            }
        }
        catch { }

        $netstandardAssemblyPath = @($netstandardCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)
        if ($netstandardAssemblyPath.Count -eq 0) {
            throw "netstandard.dll kon niet als .NET Framework-facade voor de WAM-bridge worden gevonden."
        }
        $references = @($MsalPath, $BrokerPath, $formsAssemblyPath, [string]$netstandardAssemblyPath[0])
        return @($references | Select-Object -Unique)
    }
    catch {
        Throw-AutopilotGdapError -Code "wamUnavailable" -Message "De vereiste .NET-onderdelen voor Windows Web Account Manager ontbreken. Herstel .NET Framework 4.8 en start de app opnieuw." -Details $_.Exception.Message
    }
}

function Initialize-WamBroker {
    param([Parameter(Mandatory = $true)][object]$State)
    if ($State.AuthMode -ne "wam") { return }
    if ($State.WamBridgeReady) { return }
    if (-not (Test-WamInteractiveSession -IsOobe $State.IsOobe)) {
        Throw-AutopilotGdapError -Code "wamUnavailable" -Message "WAM is alleen beschikbaar in een normale interactieve Windows-sessie. Start deze app via OOBE voor de browserflow."
    }
    $module = Ensure-GraphAuthenticationModule -State $State
    $msalPath = Get-MsalAssemblyPath -Module $module -FileName "Microsoft.Identity.Client.dll"
    $brokerPath = Get-MsalAssemblyPath -Module $module -FileName "Microsoft.Identity.Client.Broker.dll"
    $nativeInteropPath = Get-MsalAssemblyPath -Module $module -FileName "Microsoft.Identity.Client.NativeInterop.dll"
    foreach ($assemblyPath in @($msalPath, $brokerPath, $nativeInteropPath)) {
        if ([string]::IsNullOrWhiteSpace([string]$assemblyPath) -or -not (Test-Path -LiteralPath $assemblyPath)) {
            Throw-AutopilotGdapError -Code "wamUnavailable" -Message "De geïnstalleerde Graph-module bevat niet alle WAM-onderdelen. Installeer Microsoft.Graph.Authentication opnieuw." -Details $assemblyPath
        }
        $loaded = @([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object {
            try { $_.Location -eq $assemblyPath }
            catch { $false }
        })
        if ($loaded.Count -eq 0) { [void][System.Reflection.Assembly]::LoadFrom($assemblyPath) }
    }
    if (-not ("CaptureTech.AutopilotGdap.WamBroker" -as [type])) {
        $bridgeSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Microsoft.Identity.Client;
using Microsoft.Identity.Client.Broker;

namespace CaptureTech.AutopilotGdap
{
    public sealed class WamToken
    {
        public string AccessToken { get; set; }
        public string Account { get; set; }
        public string HomeAccountId { get; set; }
        public string TenantId { get; set; }
    }

    public static class WamBroker
    {
        private static readonly object Gate = new object();
        private static IPublicClientApplication application;
        private static readonly Dictionary<string, IPublicClientApplication> customerApplications = new Dictionary<string, IPublicClientApplication>(StringComparer.OrdinalIgnoreCase);
        private static IAccount sessionAccount;
        private static string configuredClientId;
        private static long configuredParentWindowHandle;
        private const uint GA_ROOT = 2;

        [DllImport("user32.dll")]
        private static extern IntPtr GetAncestor(IntPtr hwnd, uint gaFlags);

        private static IntPtr GetTopLevelWindow(long parentWindowHandle)
        {
            var suppliedWindow = new IntPtr(parentWindowHandle);
            var topLevelWindow = GetAncestor(suppliedWindow, GA_ROOT);
            return topLevelWindow == IntPtr.Zero ? suppliedWindow : topLevelWindow;
        }

        private static IPublicClientApplication CreateApplication(string authorityTenant)
        {
            var brokerOptions = new BrokerOptions(BrokerOptions.OperatingSystems.Windows);
            brokerOptions.Title = "CaptureTech Autopilot GDAP";
            var builder = PublicClientApplicationBuilder.Create(configuredClientId)
                .WithAuthority(AzureCloudInstance.AzurePublic, authorityTenant)
                // The ms-appx-web BrokerPlugin redirect must be registered
                // in Entra, but must not be forced here. MSAL chooses the
                // correct WAM redirect through WithDefaultRedirectUri().
                .WithDefaultRedirectUri()
                // Tauri exposes a webview HWND. WAM must be parented to
                // the top-level app window so its native chooser returns
                // to this app rather than appearing behind it.
                .WithParentActivityOrWindow(() => GetTopLevelWindow(configuredParentWindowHandle));
            return BrokerExtension.WithBroker(builder, brokerOptions).Build();
        }

        private static IPublicClientApplication GetCustomerApplication(string tenantId)
        {
            if (String.IsNullOrWhiteSpace(tenantId)) throw new ArgumentException("De klanttenant ontbreekt.", "tenantId");
            lock (Gate)
            {
                IPublicClientApplication customerApplication;
                if (!customerApplications.TryGetValue(tenantId, out customerApplication))
                {
                    // GDAP calls are evaluated in the customer tenant. Keep
                    // a tenant-specific broker application so WAM uses the
                    // same authority as the proven browser tenant flow.
                    customerApplication = CreateApplication(tenantId);
                    customerApplications[tenantId] = customerApplication;
                }
                return customerApplication;
            }
        }

        public static void Initialize(string clientId, long parentWindowHandle)
        {
            lock (Gate)
            {
                if (application != null) return;
                configuredClientId = clientId;
                configuredParentWindowHandle = parentWindowHandle;
                // Partner Graph and Partner Center start with organizations
                // so Windows presents exactly one initial account picker.
                application = CreateApplication("organizations");
            }
        }

        public static WamToken Acquire(string tenantId, string[] scopes, bool interactive, bool selectAccount, bool forceCustomerAccountSelection, bool useTenantSpecificAuthority)
        {
            if (application == null) throw new InvalidOperationException("WAM is niet geïnitialiseerd.");
            var requestApplication = useTenantSpecificAuthority ? GetCustomerApplication(tenantId) : application;
            // Partner Center continues using the base organizations authority.
            // Customer Graph calls deliberately use the explicit customer
            // tenant authority, matching the established browser GDAP flow.
            AuthenticationResult result;
            if (interactive)
            {
                var request = requestApplication.AcquireTokenInteractive(scopes);
                if (!selectAccount || forceCustomerAccountSelection) request = request.WithTenantId(tenantId);
                if (forceCustomerAccountSelection)
                {
                    // A customer tenant can contain both a B2B guest object
                    // and a GDAP-derived role context for the same UPN. Do
                    // not silently reuse the cached guest session: force WAM
                    // to authenticate the selected IT-Hulp account again in
                    // the customer authority.
                    if (sessionAccount != null && !String.IsNullOrWhiteSpace(sessionAccount.Username)) request = request.WithLoginHint(sessionAccount.Username);
                    request = request.WithPrompt(Prompt.ForceLogin);
                }
                else
                {
                    if (sessionAccount != null && !selectAccount) request = request.WithAccount(sessionAccount);
                    if (selectAccount) request = request.WithPrompt(Prompt.SelectAccount);
                }
                result = request.ExecuteAsync().GetAwaiter().GetResult();
            }
            else
            {
                if (sessionAccount == null) throw new MsalUiRequiredException("no_session_account", "Er is geen IT-Hulp-account geselecteerd in deze appsessie.");
                result = requestApplication.AcquireTokenSilent(scopes, sessionAccount).WithTenantId(tenantId).ExecuteAsync().GetAwaiter().GetResult();
            }
            sessionAccount = result.Account;
            return new WamToken
            {
                AccessToken = result.AccessToken,
                Account = result.Account == null ? String.Empty : result.Account.Username,
                HomeAccountId = result.Account == null || result.Account.HomeAccountId == null ? String.Empty : result.Account.HomeAccountId.Identifier,
                TenantId = result.TenantId
            };
        }

        public static void ResetSession()
        {
            lock (Gate) { sessionAccount = null; }
        }
    }
}
'@
        try {
            $bridgeReferences = @(Get-WamBridgeReferenceAssemblies -MsalPath $msalPath -BrokerPath $brokerPath)
            Add-Type -TypeDefinition $bridgeSource -ReferencedAssemblies $bridgeReferences -Language CSharp -ErrorAction Stop
        }
        catch {
            Throw-AutopilotGdapError -Code "wamUnavailable" -Message "Windows Web Account Manager kon niet worden geladen. Controleer .NET Framework 4.8 en start de app opnieuw." -Details ($_ | Out-String).Trim()
        }
    }
    try {
        [CaptureTech.AutopilotGdap.WamBroker]::Initialize($State.PublicClientId, [int64]$env:CAPTURETECH_PARENT_HWND)
    }
    catch {
        Throw-AutopilotGdapError -Code "wamUnavailable" -Message "Windows Web Account Manager kon niet worden voorbereid. Voer de partner-appinrichting opnieuw uit en controleer de broker redirect URI." -Details $_.Exception.Message
    }
    $State.WamBridgeReady = $true
}

function ConvertTo-MsalScopes {
    param([Parameter(Mandatory = $true)][string[]]$Scopes)

    # MSAL expects Microsoft Graph delegated permissions in their canonical
    # short form (for example Directory.Read.All). Prefixing them with the
    # Graph URL yields a URL-audience token on some WAM paths. That token is
    # structurally valid but Intune's GDAP service rejects it as unsupported.
    # Non-Graph resources, notably Partner Center, must retain their full URI.
    return @($Scopes | ForEach-Object {
        $scope = [string]$_
        if ($scope -match '^https://graph\.microsoft\.com/(.+)$') { return [string]$Matches[1] }
        return $scope
    })
}

function Get-WamAccessToken {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$TenantId,
        [Parameter(Mandatory = $true)][string[]]$Scopes,
        [switch]$Interactive,
        [switch]$SelectAccount,
        [switch]$ForceCustomerAccountSelection,
        [switch]$AllowInteractiveFallback
    )
    Initialize-WamBroker -State $State
    $msalScopes = [string[]](ConvertTo-MsalScopes -Scopes $Scopes)
    $previousHomeAccountId = [string]$State.SessionHomeAccountId
    # The partner token starts at the organizations authority. Every customer
    # Graph token is acquired through an explicitly customer-tenant-bound WAM
    # application so its issuer and broker authorization context match the
    # browser GDAP flow.
    $useTenantSpecificAuthority = -not [string]::Equals([string]$TenantId, [string]$State.PartnerTenantId, [System.StringComparison]::OrdinalIgnoreCase)
    try {
        $token = [CaptureTech.AutopilotGdap.WamBroker]::Acquire($TenantId, $msalScopes, [bool]$Interactive, [bool]$SelectAccount, [bool]$ForceCustomerAccountSelection, [bool]$useTenantSpecificAuthority)
    }
    catch {
        $errorInfo = Get-AutopilotGdapError -ErrorRecord $_
        if ($errorInfo.code -ne "authenticationRequired" -or -not $AllowInteractiveFallback -or $Interactive) { throw }
        Write-EngineEvent -State $State -Message "Windows vraagt aanvullende verificatie voor het eerder gekozen IT-Hulp-account." -Level info -Step login
        try {
            $token = [CaptureTech.AutopilotGdap.WamBroker]::Acquire($TenantId, $msalScopes, $true, $false, $false, [bool]$useTenantSpecificAuthority)
        }
        catch { throw }
    }
    if ($ForceCustomerAccountSelection -and -not [string]::IsNullOrWhiteSpace($previousHomeAccountId) -and $previousHomeAccountId -ne [string]$token.HomeAccountId) {
        Throw-AutopilotGdapError -Code "authenticationRequired" -Message "Kies voor de klanttenant dezelfde IT-Hulp-account als waarmee de Partner Center-sessie is gestart."
    }
    $State.SessionAccount = [string]$token.Account
    $State.SessionHomeAccountId = [string]$token.HomeAccountId
    return [pscustomobject]@{ accessToken = [string]$token.AccessToken; account = [string]$token.Account; homeAccountId = [string]$token.HomeAccountId; tenantId = [string]$token.TenantId }
}

function Get-GraphAccessToken {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$TenantId,
        [Parameter(Mandatory = $true)][string[]]$Scopes,
        [switch]$Interactive,
        [switch]$SelectAccount,
        [switch]$ForceCustomerAccountSelection,
        [switch]$BrowserSso
    )
    if ($BrowserSso) {
        return Get-BrowserGraphAccessToken -State $State -TenantId $TenantId -Scopes $Scopes
    }
    if ($State.AuthMode -eq "wam") {
        return Get-WamAccessToken -State $State -TenantId $TenantId -Scopes $Scopes -Interactive:$Interactive -SelectAccount:$SelectAccount -ForceCustomerAccountSelection:$ForceCustomerAccountSelection -AllowInteractiveFallback:(-not $Interactive)
    }
    return Get-BrowserGraphAccessToken -State $State -TenantId $TenantId -Scopes $Scopes
}

function Connect-GraphTenant {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$TenantId,
        [Parameter(Mandatory = $true)][string[]]$Scopes,
        [switch]$Interactive,
        [switch]$SelectAccount,
        [switch]$ForceCustomerAccountSelection,
        [switch]$BrowserSso
    )
    # The module descriptor returned by the installer/import helper contains
    # deep PowerShell metadata. It is not workflow output and must never leak
    # into a caller's result stream.
    [void](Ensure-GraphAuthenticationModule -State $State)
    $token = Get-GraphAccessToken -State $State -TenantId $TenantId -Scopes $Scopes -Interactive:$Interactive -SelectAccount:$SelectAccount -ForceCustomerAccountSelection:$ForceCustomerAccountSelection -BrowserSso:$BrowserSso
    $State.GraphAccessToken = [string]$token.accessToken
    $secureToken = ConvertTo-SecureString $token.accessToken -AsPlainText -Force
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    Connect-MgGraph -AccessToken $secureToken -ErrorAction Stop -NoWelcome | Out-Null
    $context = Get-MgContext
    if (-not $context -or [string]$context.TenantId -ne [string]$TenantId) {
        throw "Graph heeft de verkeerde tenantcontext geopend. Verwacht: $TenantId."
    }
    $State.ConnectedAccount = if (-not [string]::IsNullOrWhiteSpace([string]$token.account)) {
        [string]$token.account
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$State.SessionAccount)) {
        [string]$State.SessionAccount
    }
    else {
        [string]$context.Account
    }
    Write-GraphTokenDiagnostic -State $State -Token $token -Context $context -RequestedTenantId $TenantId
    Write-EngineEvent -State $State -Message "Graph-verbinding met tenant $TenantId is actief." -Level success
}

function Invoke-BrowserCustomerGraphFallback {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$TenantId,
        [Parameter(Mandatory = $true)][string]$CustomerName,
        [ValidateSet("missingRoleContext", "tokenAcquisition", "desktopCustomerSso")][string]$Reason = "missingRoleContext"
    )

    if ($State.AuthMode -ne "wam") {
        throw "Browser-SSO-fallback is alleen nodig vanuit een Windows WAM-sessie."
    }

    # WAM is retained for the partner login and Partner Center. Some GDAP
    # relationships, however, are represented as a B2B guest in WAM and the
    # resulting token has no customer directory-role (`wids`) context. The
    # established auth-code browser flow obtains the role-bearing token for
    # that one customer without device code or persistent refresh tokens.
    $fallbackMessage = if ($Reason -eq "desktopCustomerSso") {
        "Voor $CustomerName wordt de klanttenant direct via browser-SSO geopend met hetzelfde IT-Hulp-account. Windows WAM blijft actief voor Partner Center."
    }
    elseif ($Reason -eq "tokenAcquisition") {
        "Windows WAM kon voor $CustomerName geen bruikbare klanttenanttoken ophalen. De browser opent voor SSO met hetzelfde IT-Hulp-account."
    }
    else {
        "Windows WAM heeft voor $CustomerName geen GDAP-rolcontext ontvangen. De browser opent voor SSO met hetzelfde IT-Hulp-account."
    }
    Write-EngineEvent -State $State -Message $fallbackMessage -Level info -Step customer
    Connect-GraphTenant -State $State -TenantId $TenantId -Scopes $script:GraphScopes -BrowserSso
    $State.CustomerAuthMode = "browserSsoFallback"

    if (Test-GraphTokenHasDirectoryRoleContext -AccessToken ([string]$State.GraphAccessToken)) {
        Write-EngineEvent -State $State -Message "Browser-SSO heeft de GDAP-rolcontext voor $CustomerName bevestigd. Deze klantcontext wordt hergebruikt voor profielen en registratie." -Level success -Step customer
    }
    else {
        # Do not reject a browser token purely on this diagnostic. The
        # subsequent Graph/Intune calls remain the authority and yield the
        # existing typed GDAP/PIM error when the customer truly denies access.
        Write-EngineEvent -State $State -Message "Browser-SSO is voor $CustomerName ingesteld. De klanttoegang wordt nu bij het laden van de Autopilot-profielen bevestigd." -Level info -Step customer
    }
}

function Get-BrowserPartnerCenterAccessToken {
    param([Parameter(Mandatory = $true)][object]$State)
    $resource = "https://api.partnercenter.microsoft.com"
    $tokenUri = "https://login.microsoftonline.com/common/oauth2/token"
    $redirectUri = "http://localhost:8765/"
    $prompts = if ($State.BrowserInteractiveCompleted) { @("none", "select_account") } else { @("select_account") }
    foreach ($prompt in $prompts) {
        $authorizeUri = "https://login.microsoftonline.com/common/oauth2/authorize?client_id=$([uri]::EscapeDataString($State.PublicClientId))&response_type=code&redirect_uri=$([uri]::EscapeDataString($redirectUri))&response_mode=query&resource=$([uri]::EscapeDataString($resource))&prompt=$prompt"
        $exchange = {
            param([string]$Code)
            try {
                Invoke-RestMethod -Method POST -Uri $tokenUri -Body @{
                    grant_type = "authorization_code"
                    client_id = $State.PublicClientId
                    code = $Code
                    redirect_uri = $redirectUri
                    resource = $resource
                } -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
            }
            catch {
                $detail = $_.ErrorDetails.Message
                if ([string]::IsNullOrWhiteSpace($detail)) { $detail = $_.Exception.Message }
                throw "Partner Center-token ophalen mislukt: $detail"
            }
        }.GetNewClosure()
        try {
            $token = Invoke-BrowserAuthorizationCodeFlow -State $State -AuthorizeUri $authorizeUri -RedirectUri $redirectUri -ExchangeCode $exchange -Purpose "Partner Center-aanmelding"
            $State.BrowserInteractiveCompleted = $true
            return [string]$token.access_token
        }
        catch {
            if ($prompt -eq "none" -and $_.Exception.Message -match 'login_required|interaction_required|AADSTS50058') { continue }
            throw
        }
    }
    Throw-AutopilotGdapError -Code "authenticationRequired" -Message "Partner Center kon de browser-SSO-sessie niet hergebruiken."
}

function Get-PartnerCenterAccessToken {
    param([Parameter(Mandatory = $true)][object]$State)
    if (-not [string]::IsNullOrWhiteSpace([string]$State.PartnerCenterAccessToken)) { return [string]$State.PartnerCenterAccessToken }
    try {
        if ($State.AuthMode -eq "wam") {
            Write-EngineEvent -State $State -Message "Partner Center-token wordt stil opgehaald met hetzelfde IT-Hulp-account." -Level info -Step customer
            $token = Get-WamAccessToken -State $State -TenantId $State.PartnerTenantId -Scopes @($script:PartnerCenterScope) -AllowInteractiveFallback
            $State.PartnerCenterAccessToken = [string]$token.accessToken
        }
        else {
            $State.PartnerCenterAccessToken = Get-BrowserPartnerCenterAccessToken -State $State
        }
    }
    catch {
        $details = $_.Exception.Message
        if ($details -match 'consent|AADSTS65001|AADSTS700016') {
            Throw-AutopilotGdapError -Code "partnerCenterConsentRequired" -Message "Partner Center-consent ontbreekt voor de CaptureTech-app. Voer Setup-AutopilotApp.ps1 opnieuw uit met een bevoegd partneraccount." -Details $details
        }
        throw
    }
    Retire-LegacyPartnerCenterToken -State $State
    return [string]$State.PartnerCenterAccessToken
}

function Get-PartnerCenterCustomers {
    param([Parameter(Mandatory = $true)][object]$State)
    if ([string]::IsNullOrWhiteSpace([string]$State.PartnerCenterAccessToken)) {
        $State.PartnerCenterAccessToken = Get-PartnerCenterAccessToken -State $State
    }
    $headers = @{
        Authorization = "Bearer $($State.PartnerCenterAccessToken)"
        Accept = "application/json"
        "MS-RequestId" = [guid]::NewGuid().ToString()
        "MS-CorrelationId" = [guid]::NewGuid().ToString()
        "MS-Contract-Version" = "v1"
    }
    $customers = [System.Collections.Generic.List[object]]::new()
    $uri = "https://api.partnercenter.microsoft.com/v1/customers"
    do {
        $page = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers -ErrorAction Stop
        foreach ($customer in @($page.items)) {
            $name = [string]$customer.companyProfile.companyName
            if ([string]::IsNullOrWhiteSpace($name)) { $name = [string]$customer.companyProfile.domain }
            $domain = [string]$customer.companyProfile.domain
            $tenantId = [string]$customer.id
            if ([string]::IsNullOrWhiteSpace($tenantId)) { continue }
            [void]$customers.Add([pscustomobject]@{
                tenantId = $tenantId
                customerName = $name
                tenantDomain = $domain
                displayName = "$name [$domain]"
            })
        }
        $next = [string]$page.links.next.uri
        if ([string]::IsNullOrWhiteSpace($next)) { $uri = $null }
        elseif ($next -match "^https?://") { $uri = $next }
        else { $uri = "https://api.partnercenter.microsoft.com$next" }
    } while ($uri)
    return @($customers | Sort-Object tenantId -Unique)
}

function Clear-PartnerCenterCustomerCache {
    param([Parameter(Mandatory = $true)][object]$State)

    $path = [string]$State.CustomerCachePath
    if (-not [string]::IsNullOrWhiteSpace($path)) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Write-PartnerCenterCustomerCache {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Customers
    )

    # The stdout pipe is reserved for small worker events. A Partner Center
    # list can contain hundreds of tenants, so transfer only four plain fields
    # through a session-local NDJSON cache. Rust reads it in bounded batches.
    $path = [string]$State.CustomerCachePath
    if ([string]::IsNullOrWhiteSpace($path)) {
        throw "Het tijdelijke Partner Center-klantenpad ontbreekt."
    }
    $directory = Split-Path -Parent $path
    if ([string]::IsNullOrWhiteSpace($directory)) {
        throw "Het tijdelijke Partner Center-klantenpad is ongeldig."
    }
    New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
    $temporaryPath = "$path.$PID.tmp"
    $encoding = [System.Text.UTF8Encoding]::new($false)
    $writer = $null
    $count = 0
    try {
        $writer = [System.IO.StreamWriter]::new($temporaryPath, $false, $encoding)
        foreach ($customer in $Customers) {
            if ($null -eq $customer) { continue }
            $record = [ordered]@{
                tenantId = [string]$customer.tenantId
                customerName = [string]$customer.customerName
                tenantDomain = [string]$customer.tenantDomain
                displayName = [string]$customer.displayName
            }
            $writer.WriteLine(($record | ConvertTo-Json -Depth 4 -Compress))
            $count++
        }
    }
    finally {
        if ($null -ne $writer) { $writer.Dispose() }
    }
    Move-Item -LiteralPath $temporaryPath -Destination $path -Force -ErrorAction Stop
    return [int]$count
}

function Get-GraphCollection {
    param([Parameter(Mandatory = $true)][string]$Uri)
    $items = @()
    $next = $Uri
    while ($next) {
        $page = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType PSObject -ErrorAction Stop
        $items += @($page.value)
        $next = $page.'@odata.nextLink'
    }
    return @($items)
}

function Get-GroupInfo {
    param([Parameter(Mandatory = $true)][string]$GroupId)
    $select = '$select=id,displayName,groupTypes,membershipRule,membershipRuleProcessingState,securityEnabled,mailEnabled'
    $groupUri = "https://graph.microsoft.com/v1.0/groups/{0}?{1}" -f $GroupId, $select
    $group = Invoke-MgGraphRequest -Method GET -Uri $groupUri -OutputType PSObject -ErrorAction Stop
    $isDynamic = @($group.groupTypes) -contains "DynamicMembership"
    $escapedName = ([string]$group.displayName).Replace("'", "''")
    $encodedFilter = [uri]::EscapeDataString("displayName eq '$escapedName'")
    $sameNameGroups = @(Get-GraphCollection -Uri ("https://graph.microsoft.com/v1.0/groups?%24filter={0}&%24select=id,displayName" -f $encodedFilter))
    $children = @()
    $parents = @()
    try { $children = @(Get-GraphCollection -Uri "https://graph.microsoft.com/v1.0/groups/$GroupId/members/microsoft.graph.group") } catch { }
    try { $parents = @(Get-GraphCollection -Uri "https://graph.microsoft.com/v1.0/groups/$GroupId/transitiveMemberOf/microsoft.graph.group") } catch { }
    [pscustomobject]@{
        id = [string]$group.id
        name = [string]$group.displayName
        type = if ($isDynamic) { "Dynamisch" } else { "Statisch" }
        isDynamic = $isDynamic
        isExclusion = $false
        membershipRule = [string]$group.membershipRule
        membershipRuleProcessingState = [string]$group.membershipRuleProcessingState
        securityEnabled = [bool]$group.securityEnabled
        mailEnabled = [bool]$group.mailEnabled
        matchingGroupCount = @($sameNameGroups).Count
        childGroups = @($children)
        parentGroups = @($parents)
        hasNested = (@($children).Count -gt 0 -or @($parents).Count -gt 0)
    }
}

function Get-ProfileAssignments {
    param([Parameter(Mandatory = $true)][object]$Profile)
    $assignments = Get-GraphCollection -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles/$($Profile.id)/assignments"
    $groups = @()
    foreach ($assignment in @($assignments)) {
        $target = $assignment.target
        $groupId = [string]$target.groupId
        if ([string]::IsNullOrWhiteSpace($groupId)) { continue }
        $info = Get-GroupInfo -GroupId $groupId
        $info.isExclusion = ([string]$target.'@odata.type' -match "exclusion")
        $groups += $info
    }
    return @($groups)
}

function Get-ProfileGroupCandidates {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object[]]$Groups
    )
    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($group in @($Groups | Where-Object { -not $_.isDynamic -and -not $_.isExclusion })) {
        if ($group.matchingGroupCount -ne 1) {
            Write-EngineEvent -State $State -Message "Statische groep '$($group.name)' is niet uniek en wordt niet als -AddToGroup-kandidaat gebruikt." -Level warning
            continue
        }
        if (-not $group.securityEnabled) {
            Write-EngineEvent -State $State -Message "Statische groep '$($group.name)' is geen beveiligingsgroep en wordt niet als -AddToGroup-kandidaat gebruikt." -Level warning
            continue
        }
        [void]$candidates.Add([pscustomobject]@{
            id = [string]$group.id
            name = [string]$group.name
            displayName = "$($group.name) - direct statisch"
            source = "Direct toegewezen statische groep"
        })
    }
    foreach ($dynamicGroup in @($Groups | Where-Object { $_.isDynamic -and -not $_.isExclusion })) {
        foreach ($child in @($dynamicGroup.childGroups)) {
            if (@($child.groupTypes) -contains "DynamicMembership") { continue }
            if ([string]::IsNullOrWhiteSpace([string]$child.id)) { continue }
            $childInfo = Get-GroupInfo -GroupId ([string]$child.id)
            if ($childInfo.isDynamic -or -not $childInfo.securityEnabled -or $childInfo.matchingGroupCount -ne 1) { continue }
            [void]$candidates.Add([pscustomobject]@{
                id = [string]$childInfo.id
                name = [string]$childInfo.name
                displayName = "$($childInfo.name) - nested statisch onder $($dynamicGroup.name)"
                source = "Nested onder dynamische groep '$($dynamicGroup.name)'"
            })
        }
    }
    return @($candidates | Group-Object id | ForEach-Object { $_.Group[0] } | Sort-Object displayName)
}

function Resolve-AutopilotOrderIdGroupTag {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Groups)

    # Intune represents the Autopilot Group Tag in devicePhysicalIds as
    # [OrderID]:<tag>. Only infer a value when all applicable dynamic profile
    # assignments point to one unique tag. A profile can contain unrelated
    # dynamic rules, or conflicting tags, and guessing in either case would
    # put a device in the wrong Entra group.
    $tags = [System.Collections.Generic.List[string]]::new()
    foreach ($group in @($Groups | Where-Object { $_.isDynamic -and -not $_.isExclusion })) {
        $rule = [string]$group.membershipRule
        if ([string]::IsNullOrWhiteSpace($rule)) { continue }
        $matches = [regex]::Matches($rule, '(?i)\[OrderID\]\s*:\s*(?<tag>[^"\r\n]+)')
        foreach ($match in $matches) {
            $tag = [string]$match.Groups["tag"].Value.Trim()
            if ([string]::IsNullOrWhiteSpace($tag)) { continue }
            [void]$tags.Add($tag)
        }
    }

    $uniqueTags = @($tags | Sort-Object -Unique)
    if ($uniqueTags.Count -eq 1) {
        return [pscustomobject]@{
            status = "resolved"
            groupTag = [string]$uniqueTags[0]
            candidates = @($uniqueTags)
        }
    }
    if ($uniqueTags.Count -gt 1) {
        return [pscustomobject]@{
            status = "ambiguous"
            groupTag = $null
            candidates = @($uniqueTags)
        }
    }
    return [pscustomobject]@{
        status = "none"
        groupTag = $null
        candidates = @()
    }
}

function Get-CommunityScriptPath {
    param([Parameter(Mandatory = $true)][object]$State)
    $command = Get-Command Get-WindowsAutopilotInfoCommunity.ps1 -ErrorAction SilentlyContinue
    if (-not $command) { $command = Get-Command Get-WindowsAutopilotInfoCommunity -ErrorAction SilentlyContinue }
    if (-not $command) {
        Write-EngineEvent -State $State -Message "Community-script ontbreekt en wordt vanuit PSGallery geïnstalleerd." -Level info
        Install-Script -Name Get-WindowsAutopilotInfoCommunity -Scope CurrentUser -Force -ErrorAction Stop | Out-Null
        $command = Get-Command Get-WindowsAutopilotInfoCommunity.ps1 -ErrorAction SilentlyContinue
        if (-not $command) { $command = Get-Command Get-WindowsAutopilotInfoCommunity -ErrorAction Stop }
    }
    return [string]$command.Source
}

function Test-TechnicalCommunityOutput {
    param([Parameter(Mandatory = $true)][string]$Text)
    return $Text -match '^(Loading module from path|Importing (cmdlet|function|alias)|Version \d+ module detected|GET https://graph\.microsoft\.com/|POST https://graph\.microsoft\.com/|PUT https://graph\.microsoft\.com/|PATCH https://graph\.microsoft\.com/|received \d+-byte response|Perform operation |Operation ''.*'' (complete|with following parameters)|\s*ClientId\s+:|\{\s*$)'
}

function Write-CommunityRecord {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Record,
        [bool]$IncludeTechnicalOutput
    )
    $text = ($Record | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return }
    $technical = Test-TechnicalCommunityOutput -Text $text
    if ($technical -and -not $IncludeTechnicalOutput) { return }
    $level = if ($Record -is [System.Management.Automation.ErrorRecord]) { "error" } else { "info" }
    Write-EngineEvent -State $State -Message $text -Level $level -Technical $technical
}

function New-CommunityOnlineParameters {
    param(
        [Parameter(Mandatory = $true)][string]$TenantId,
        [AllowNull()][object]$SelectedAddToGroup,
        [string]$GroupTag,
        [string]$Hostname,
        [bool]$IncludeTechnicalOutput
    )

    $parameters = @{ Online = $true; TenantId = $TenantId; Assign = $true }
    if ($IncludeTechnicalOutput) { $parameters.Verbose = $true }
    if (-not [string]::IsNullOrWhiteSpace($Hostname)) { $parameters.AssignedComputerName = $Hostname.Trim() }
    if ($SelectedAddToGroup) { $parameters.AddToGroup = [string]$SelectedAddToGroup.name }
    if (-not [string]::IsNullOrWhiteSpace($GroupTag)) { $parameters.GroupTag = $GroupTag.Trim() }
    return $parameters
}

function Invoke-CommunityOnline {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$TenantId,
        [Parameter(Mandatory = $true)][object]$Profile,
        [AllowNull()][object]$SelectedAddToGroup,
        [string]$GroupTag,
        [string]$Hostname,
        [bool]$IncludeTechnicalOutput
    )
    $context = Get-MgContext
    if (-not $context -or [string]$context.TenantId -ne [string]$TenantId) {
        throw "De actieve Graph-sessie hoort niet bij klanttenant $TenantId."
    }
    $source = Get-CommunityScriptPath -State $State
    $tempPath = Join-Path $env:TEMP ("Get-WindowsAutopilotInfoCommunity-{0}.ps1" -f ([guid]::NewGuid()))
    $scriptText = Get-Content -LiteralPath $source -Raw -ErrorAction Stop
    $reuseBlock = @'
                    $existingContext = Get-MgContext
                    if ($existingContext) {
                        $graph = $existingContext
                        Write-Host "Using existing Graph session for tenant $($existingContext.TenantId)"
                    }
                    else {
                        throw "No existing Graph session is available for the Community script."
                    }
'@
    $connectRegex = [regex]::new('(?m)^\s*\$graph\s*=\s*Connect-MgGraph\s+-Scopes\s+\$scopes\s*$')
    $patchedText = $connectRegex.Replace($scriptText, $reuseBlock.TrimEnd(), 1)
    if ($patchedText -eq $scriptText) {
        throw "De actuele Community-scriptversie heeft een onbekende Graph-loginstructuur. Er is niet naar WAM teruggevallen."
    }
    $scriptText = $patchedText.Replace('setx MSAL_FORCE_WAM 0', '# Existing Graph session is reused')
    $scriptText = $scriptText.Replace('setx MSAL_FORCE_WAM 1', '# WAM setting is not changed by this tool')
    Set-Content -LiteralPath $tempPath -Value $scriptText -Encoding UTF8 -ErrorAction Stop
    try {
        $communityCommand = Get-Command -Name $tempPath -ErrorAction Stop
        $requiredParameters = @("Online", "TenantId", "Assign")
        if (-not [string]::IsNullOrWhiteSpace($GroupTag)) { $requiredParameters += "GroupTag" }
        $missingParameters = @($requiredParameters | Where-Object { -not $communityCommand.Parameters.ContainsKey($_) })
        if ($missingParameters.Count -gt 0) {
            throw "De actuele Community-scriptversie ondersteunt niet de vereiste parameter(s): $($missingParameters -join ', ')."
        }
        $parameters = New-CommunityOnlineParameters -TenantId $TenantId -SelectedAddToGroup $SelectedAddToGroup -GroupTag $GroupTag -Hostname $Hostname -IncludeTechnicalOutput $IncludeTechnicalOutput
        if ($SelectedAddToGroup) {
            Write-EngineEvent -State $State -Message "Statische groepsactie: -AddToGroup '$($SelectedAddToGroup.name)'." -Level info
        }
        if (-not [string]::IsNullOrWhiteSpace($GroupTag)) {
            Write-EngineEvent -State $State -Message "Dynamische OrderID-regel: -GroupTag '$($parameters.GroupTag)' wordt automatisch aan het Community-script meegegeven." -Level info
        }
        foreach ($group in @($Profile.groups | Where-Object { $_.isDynamic -and -not $_.isExclusion })) {
            if (-not [string]::IsNullOrWhiteSpace($GroupTag) -and [string]$group.membershipRule -match [regex]::Escape("[OrderID]:$($parameters.GroupTag)")) {
                Write-EngineEvent -State $State -Message "Dynamische groep '$($group.name)': Group Tag '$($parameters.GroupTag)' wordt ingesteld; Entra beoordeelt de membership-regel automatisch." -Level info
            }
            else {
                Write-EngineEvent -State $State -Message "Dynamische groep '$($group.name)': geen handmatige toevoeging. Entra beoordeelt de membership-regel automatisch." -Level info
            }
        }
        $errors = [System.Collections.Generic.List[string]]::new()
        $parameterSummary = @("-Online", "-TenantId", "-Assign")
        if ($parameters.ContainsKey("GroupTag")) { $parameterSummary += "-GroupTag" }
        if ($parameters.ContainsKey("AddToGroup")) { $parameterSummary += "-AddToGroup" }
        Write-EngineEvent -State $State -Message "Community-script wordt gestart met $($parameterSummary -join ', ')." -Level info -Step register
        & $tempPath @parameters *>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { [void]$errors.Add(($_ | Out-String).Trim()) }
            Write-CommunityRecord -State $State -Record $_ -IncludeTechnicalOutput $IncludeTechnicalOutput
        }
        if ($errors.Count -gt 0) { throw ($errors -join "`n") }
    }
    finally {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
}

function Test-IsAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

function Invoke-AutopilotPreflight {
    param([Parameter(Mandatory = $true)][object]$State)
    [pscustomobject]@{
        isAdministrator = Test-IsAdministrator
        powershellVersion = $PSVersionTable.PSVersion.ToString()
        graphModuleInstalled = [bool](Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)
        authMode = [string]$State.AuthMode
        isOobe = [bool]$State.IsOobe
        wamAvailable = [bool]$State.WamAvailable
    }
}

function Invoke-PartnerLogin {
    param([Parameter(Mandatory = $true)][object]$State)
    $State.PartnerCenterAccessToken = $null
    $State.GraphAccessToken = $null
    if ($State.AuthMode -eq "wam") {
        Write-EngineEvent -State $State -Message "Windows opent de accountkiezer voor je IT-Hulp-account." -Level info -Step login
        Connect-GraphTenant -State $State -TenantId $State.PartnerTenantId -Scopes $script:GraphScopes -Interactive -SelectAccount
    }
    else {
        Write-EngineEvent -State $State -Message "OOBE is actief: de browser wordt gebruikt voor de IT-Hulp-aanmelding." -Level info -Step login
        Connect-GraphTenant -State $State -TenantId $State.PartnerTenantId -Scopes $script:GraphScopes -Interactive
    }
    Write-EngineEvent -State $State -Message "IT-Hulp-account is aangemeld. De Partner Center-klantenlijst wordt nu met dezelfde sessie opgehaald." -Level success -Step customer
    $State.Customers = @(Get-PartnerCenterCustomers -State $State)
    Write-EngineEvent -State $State -Message "$($State.Customers.Count) klant(en) zijn geladen vanuit Partner Center." -Level success -Step customer
    [void](Write-PartnerCenterCustomerCache -State $State -Customers $State.Customers)
    return [ordered]@{
        tenantId = [string]$State.PartnerTenantId
        account = [string]$State.ConnectedAccount
        authMode = [string]$State.AuthMode
        isOobe = [bool]$State.IsOobe
        customerCount = [int]$State.Customers.Count
    }
}

function Invoke-LoadCustomers {
    param([Parameter(Mandatory = $true)][object]$State)
    Write-EngineEvent -State $State -Message "Partner Center-klantenlijst wordt opgehaald." -Level info
    $State.Customers = @(Get-PartnerCenterCustomers -State $State)
    [void](Write-PartnerCenterCustomerCache -State $State -Customers $State.Customers)
    [ordered]@{ customerCount = [int]$State.Customers.Count }
}

function Invoke-ConnectCustomer {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$TenantId
    )
    $customer = @($State.Customers | Where-Object { $_.tenantId -eq $TenantId } | Select-Object -First 1)
    if ($customer.Count -ne 1) { throw "De gekozen klanttenant komt niet uit de actieve Partner Center-klantenlijst." }
    $State.CustomerAuthMode = ""
    if ($State.AuthMode -eq "wam") {
        # WAM remains the preferred partner-tenant and Partner Center session,
        # but GDAP customer contexts are B2B. The browser authorization-code
        # flow is the proven OOBE path and consistently carries that tenant's
        # active role context, so use it directly for a selected customer.
        Invoke-BrowserCustomerGraphFallback -State $State -TenantId $TenantId -CustomerName ([string]$customer[0].customerName) -Reason desktopCustomerSso
    }
    else {
        Connect-GraphTenant -State $State -TenantId $TenantId -Scopes $script:GraphScopes
        $State.CustomerAuthMode = "browserOobe"
    }
    $State.TargetTenantId = $TenantId
    $State.RegistrationCompleted = $false
    Write-EngineEvent -State $State -Message "Verbonden met $($customer[0].customerName)." -Level success
    [pscustomobject]@{ tenantId = $TenantId; account = $State.ConnectedAccount; authMode = $State.AuthMode; customerAuthMode = $State.CustomerAuthMode }
}

function Invoke-ResetSession {
    param([Parameter(Mandatory = $true)][object]$State)
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    if ("CaptureTech.AutopilotGdap.WamBroker" -as [type]) {
        [CaptureTech.AutopilotGdap.WamBroker]::ResetSession()
    }
    $State.PartnerCenterAccessToken = $null
    $State.GraphAccessToken = $null
    $State.BrowserInteractiveCompleted = $false
    $State.SessionAccount = ""
    $State.SessionHomeAccountId = ""
    $State.ConnectedAccount = ""
    $State.Customers = @()
    Clear-PartnerCenterCustomerCache -State $State
    $State.Profiles = @()
    $State.TargetTenantId = ""
    $State.CustomerAuthMode = ""
    $State.RegistrationCompleted = $false
    Write-EngineEvent -State $State -Message "De appsessie is gewist. Windows-accounts en WAM-tokens van andere apps zijn niet gewijzigd." -Level info -Step login
    [pscustomobject]@{ authMode = $State.AuthMode; sessionReset = $true }
}

function Get-AutopilotProfilesForCurrentTenant {
    param([Parameter(Mandatory = $true)][object]$State)

    $response = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles" -ErrorAction Stop
    $profiles = [System.Collections.Generic.List[object]]::new()
    foreach ($profile in @($response.value)) {
        $groups = @(Get-ProfileAssignments -Profile $profile)
        $candidates = if ($groups.Count -gt 0) { @(Get-ProfileGroupCandidates -State $State -Groups $groups) } else { @() }
        $groupTagResolution = Resolve-AutopilotOrderIdGroupTag -Groups $groups
        [void]$profiles.Add([pscustomobject]@{
            profileId = [string]$profile.id
            displayName = [string]$profile.displayName
            groups = @($groups | ForEach-Object {
                [pscustomobject]@{
                    id = $_.id; name = $_.name; type = $_.type; isDynamic = $_.isDynamic; isExclusion = $_.isExclusion
                    membershipRule = $_.membershipRule; membershipRuleProcessingState = $_.membershipRuleProcessingState; hasNested = $_.hasNested
                    securityEnabled = $_.securityEnabled; mailEnabled = $_.mailEnabled
                }
            })
            groupCandidates = @($candidates)
            orderIdGroupTag = [string]$groupTagResolution.groupTag
            orderIdGroupTagStatus = [string]$groupTagResolution.status
            orderIdGroupTagCandidates = @($groupTagResolution.candidates)
        })
    }
    return $profiles.ToArray()
}

function Invoke-LoadProfiles {
    param([Parameter(Mandatory = $true)][object]$State)
    if ([string]::IsNullOrWhiteSpace($State.TargetTenantId)) { throw "Kies eerst een klanttenant." }
    $context = Get-MgContext
    if (-not $context -or [string]$context.TenantId -ne [string]$State.TargetTenantId) { throw "De Graph-sessie hoort niet bij de geselecteerde klanttenant." }
    Write-EngineEvent -State $State -Message "Autopilot-profielen en groepsassignments worden opgehaald." -Level info

    # A WAM token can be tenant-correct while still representing only a B2B
    # guest, without the customer-side GDAP directory-role context. In that
    # case the browser auth-code flow is the supported targeted fallback. A
    # WAM token that does contain the context still gets one native refresh
    # before browser SSO is considered for a later authorization failure.
    $refreshedCustomerToken = $false
    while ($true) {
        try {
            $State.Profiles = @(Get-AutopilotProfilesForCurrentTenant -State $State)
            return [pscustomobject]@{ profiles = @($State.Profiles) }
        }
        catch {
            $authorizationFailure = Test-GraphAuthorizationFailure -ErrorRecord $_
            if ($authorizationFailure -and $State.AuthMode -eq "wam" -and $State.CustomerAuthMode -eq "wam" -and -not (Test-GraphTokenHasDirectoryRoleContext -AccessToken ([string]$State.GraphAccessToken))) {
                Invoke-BrowserCustomerGraphFallback -State $State -TenantId $State.TargetTenantId -CustomerName "de geselecteerde klant"
                continue
            }
            if ($refreshedCustomerToken -and $authorizationFailure) {
                $autopilotDiagnostic = Get-GraphResponseDiagnostic -ErrorRecord $_
                Write-EngineEvent -State $State -Message "Intune/Autopilot-response: HTTP $($autopilotDiagnostic.statusCode) $($autopilotDiagnostic.reasonPhrase); code=$($autopilotDiagnostic.serviceCode); bericht=$($autopilotDiagnostic.serviceMessage)" -Level warning -Technical $true
                $groupAccess = Test-CurrentGraphGroupAccess -State $State
                if ($groupAccess.succeeded) {
                    Throw-AutopilotGdapError -Code "gdapPimDenied" -Message "Je klanttenanttoken werkt voor Microsoft Graph, maar de Intune/Autopilot-service weigert de GDAP/PIM-rechten. Controleer in Partner Center de actieve relatie én de Intune Administrator-rol voor jouw PIM-groep." -Details "Autopilot HTTP $($autopilotDiagnostic.statusCode) $($autopilotDiagnostic.reasonPhrase); serviceCode=$($autopilotDiagnostic.serviceCode)"
                }
                Throw-AutopilotGdapError -Code "gdapPimDenied" -Message "Microsoft Graph wijst de klanttenanttoken ook buiten Intune af. Controleer klanttenanttoegang, Conditional Access en de actieve GDAP/PIM-rol." -Details "Autopilot HTTP $($autopilotDiagnostic.statusCode) $($autopilotDiagnostic.reasonPhrase); groepscontrole HTTP $($groupAccess.diagnostic.statusCode) $($groupAccess.diagnostic.reasonPhrase)"
            }
            if ($refreshedCustomerToken -or $State.AuthMode -ne "wam" -or $State.CustomerAuthMode -eq "browserSsoFallback" -or -not $authorizationFailure) {
                throw
            }
            $refreshedCustomerToken = $true
            Write-EngineEvent -State $State -Message "Microsoft Graph accepteert het stille GDAP-token niet. Windows ververst nu één keer de klanttenantaanmelding voor hetzelfde IT-Hulp-account." -Level info -Step customer
            try {
                Connect-GraphTenant -State $State -TenantId $State.TargetTenantId -Scopes $script:GraphScopes -Interactive -ForceCustomerAccountSelection
            }
            catch {
                if ($State.AuthMode -eq "wam" -and (Test-WamCustomerBrowserFallbackRequired -ErrorRecord $_)) {
                    Invoke-BrowserCustomerGraphFallback -State $State -TenantId $State.TargetTenantId -CustomerName "de geselecteerde klant" -Reason tokenAcquisition
                }
                else {
                    throw
                }
            }
            if (-not (Test-GraphTokenHasDirectoryRoleContext -AccessToken ([string]$State.GraphAccessToken))) {
                Invoke-BrowserCustomerGraphFallback -State $State -TenantId $State.TargetTenantId -CustomerName "de geselecteerde klant"
            }
            Write-EngineEvent -State $State -Message "De klanttenanttoken is vernieuwd. Autopilot-profielen worden opnieuw opgehaald." -Level info -Step customer
        }
    }
}

function Invoke-RegisterDevice {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$ProfileId,
        [string]$StaticGroupId,
        [string]$Hostname,
        [bool]$IncludeTechnicalOutput
    )
    $profile = @($State.Profiles | Where-Object { $_.profileId -eq $ProfileId } | Select-Object -First 1)
    if ($profile.Count -ne 1) { throw "Het gekozen profiel is niet meer actief in deze sessie. Laad de profielen opnieuw." }
    $candidates = @($profile[0].groupCandidates)
    $selectedGroup = $null
    if ($candidates.Count -eq 1) { $selectedGroup = $candidates[0] }
    elseif ($candidates.Count -gt 1) {
        if ([string]::IsNullOrWhiteSpace($StaticGroupId)) { throw "Kies eerst een statische groep voor -AddToGroup." }
        $matchingCandidates = @($candidates | Where-Object { $_.id -eq $StaticGroupId })
        if ($matchingCandidates.Count -ne 1) { throw "De gekozen groep is geen geldige statische kandidaat voor dit profiel." }
        $selectedGroup = $matchingCandidates[0]
    }
    if (-not [string]::IsNullOrWhiteSpace($Hostname) -and $Hostname -notmatch '^[A-Za-z0-9-]{1,15}$') {
        throw "De apparaatnaam mag maximaal 15 tekens bevatten: letters, cijfers en streepjes."
    }
    $serial = [string](Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop).SerialNumber
    Write-EngineEvent -State $State -Message "Hardwaregegevens verzameld voor serienummer $serial." -Level info -Step register
    $State.RegistrationCompleted = $false
    $groupTagResolution = Resolve-AutopilotOrderIdGroupTag -Groups @($profile[0].groups)
    $groupTag = [string]$groupTagResolution.groupTag
    if ([string]$groupTagResolution.status -eq "ambiguous") {
        Write-EngineEvent -State $State -Message "Meerdere verschillende dynamische OrderID-tags gevonden ($($groupTagResolution.candidates -join ', ')). Er wordt uit veiligheid geen -GroupTag meegegeven." -Level warning
    }
    elseif (-not [string]::IsNullOrWhiteSpace($groupTag)) {
        Write-EngineEvent -State $State -Message "Dynamische OrderID-tag '$groupTag' wordt tijdens registratie automatisch ingesteld." -Level info
    }
    Invoke-CommunityOnline -State $State -TenantId $State.TargetTenantId -Profile $profile[0] -SelectedAddToGroup $selectedGroup -GroupTag $groupTag -Hostname $Hostname -IncludeTechnicalOutput $IncludeTechnicalOutput
    $dynamicGroups = @($profile[0].groups | Where-Object { $_.isDynamic -and -not $_.isExclusion })
    foreach ($group in $dynamicGroups) {
        Write-EngineEvent -State $State -Message "Dynamische groep '$($group.name)' wordt door Entra verwerkt; dit kan enige tijd duren." -Level info
    }
    $State.RegistrationCompleted = $true
    [pscustomobject]@{
        serialNumber = $serial
        staticGroupName = if ($selectedGroup) { [string]$selectedGroup.name } else { $null }
        orderIdGroupTag = if ([string]::IsNullOrWhiteSpace($groupTag)) { $null } else { $groupTag }
        dynamicGroups = @($dynamicGroups)
        importCompleted = $true
        assigned = $true
    }
}

function Invoke-AppRestart {
    param([Parameter(Mandatory = $true)][object]$State)
    if (-not $State.RegistrationCompleted) { throw "Herstart is pas beschikbaar nadat import, profieltoewijzing en een eventuele statische groepsactie zijn afgerond." }
    if (-not (Test-IsAdministrator)) { throw "De computer kan alleen als administrator worden herstart." }
    Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-Command", "Start-Sleep -Seconds 2; Restart-Computer -Force") -WindowStyle Hidden -ErrorAction Stop
    Write-EngineEvent -State $State -Message "Herstart is ingepland." -Level success
    [pscustomobject]@{ restarting = $true }
}

Export-ModuleMember -Function @(
    "New-AutopilotGdapState",
    "Get-AutopilotGdapError",
    "Invoke-AutopilotPreflight",
    "Invoke-PartnerLogin",
    "Invoke-LoadCustomers",
    "Invoke-ConnectCustomer",
    "Invoke-ResetSession",
    "Invoke-LoadProfiles",
    "Invoke-RegisterDevice",
    "Invoke-AppRestart"
)
