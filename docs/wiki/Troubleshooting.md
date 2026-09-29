# Troubleshooting

## `AADSTS90099`

De Enterprise Application is nog niet in de klanttenant geautoriseerd. Laat een
Global Administrator van de klanttenant de consentflow afronden. De Tauri-app
toont hiervoor **Klant-app instellen**; de knop **Klantinstelling starten** opent
de vaste tenant-specifieke Microsoft admin-consentpagina. Kies na acceptatie
**Opnieuw verbinden**.

## `403 Forbidden` bij profielen of groepen

Controleer of de GDAP-relatie actief is en of het IT-Hulp-account de juiste
PIM-activatie heeft: minimaal Intune Administrator en, voor groepen, Groups
Administrator.

## Klanttenant opent in de browser

Windows WAM wordt gebruikt voor de partnertenant en Partner Center. Iedere
geselecteerde GDAP-klanttenant opent vervolgens direct browser-SSO met een
login-hint voor hetzelfde IT-Hulp-account. Daarmee voorkomen we dat WAM voor
een B2B-klantcontext een token zonder directoryrolcontext (`wids`) teruggeeft
of in de broker faalt. Dit is geen device code-flow en de browser-token blijft
alleen in het geheugen van de actieve appsessie. Na een succesvolle
browseraanmelding toont het sessieoverzicht **Browser-SSO (GDAP)** als
klantcontext.

## WAM kan niet starten

Op een normale Windows-desktop gebruikt de Tauri-app Windows Web Account Manager
(WAM). Controleer dat de app in een interactieve Windows-sessie draait en voer
`Setup-AutopilotApp.ps1` opnieuw uit als de broker redirect URI
`ms-appx-web://Microsoft.AAD.BrokerPlugin/<CLIENT-ID>` ontbreekt. Kies
**Wissel account** om alleen de appsessie te wissen; Windows-accounts worden
niet afgemeld.

## Browsercallback werkt niet tijdens OOBE

Sluit andere toolinstanties en controleer of poort `8765` (Partner Center) of
`8766` (Graph) niet door een ander proces wordt gebruikt. Tijdens OOBE gebruikt
de tool de systeembrowser en geen device code; buiten OOBE gebruikt de Tauri-app
WAM voor de partner-sessie en browser-SSO voor de GDAP-klantcontext.
De app houdt de callbacklistener open wanneer Edge eerst een extra lokaal verzoek
zoals een favicon doet. Verschijnt alsnog `ERR_CONNECTION_REFUSED` op een
`localhost`-callback, sluit dan oude toolinstanties en start de app opnieuw.

## Tauri-app start niet in OOBE

Controleer Windows x64, PowerShell 5.1+, internettoegang en WebView2 Evergreen.
Gebruik anders de WPF-fallback uit de [OOBE-pagina](OOBE).

## Administratorwaarschuwing in de Tauri-app

De EXE bevat een UAC-manifest. Als Windows de app toch zonder verhoogd token
start, kies je **Start opnieuw als administrator** in de gele waarschuwing. De
app start dan dezelfde portable EXE via Windows UAC opnieuw; er is geen apart
installatieprogramma nodig.

## Registratie lijkt mislukt na een succesvolle import

Controleer de Autopilot-import en profilestatus in Intune. Bij dynamische groepen
kan Entra tijd nodig hebben om de membership-regel opnieuw te evalueren. De tool
voegt een apparaat nooit handmatig toe aan een dynamische groep, maar stelt bij
een eenduidige `[OrderID]:tag`-regel wel automatisch de bijbehorende Group Tag
in tijdens de Autopilot-import.
