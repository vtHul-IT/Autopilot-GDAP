# Intune Win32-deployment

De release-EXE wordt als een **systeemcontext** Win32-app beheerd. Hij wordt geïnstalleerd in:

`C:\Program Files\CaptureTech\Autopilot GDAP\capturetech-autopilot-gdap.exe`

De installatie maakt ook een snelkoppeling in **Start > CaptureTech > CaptureTech Autopilot GDAP** en schrijft een log naar `C:\Program Files\CaptureTech\Autopilot GDAP\install.log`. Intune-installaties tonen geen popup: deze draaien als `SYSTEM` en een interactieve prompt zou niet betrouwbaar bij de aangemelde gebruiker komen.

## Een pakket maken

Download eerst de Microsoft Win32 Content Prep Tool (`IntuneWinAppUtil.exe`) vanaf de officiële Microsoft-repository. Voer vervolgens in PowerShell op een beheerwerkplek uit:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
& .\deployment\intune\Build-CaptureTechAutopilotGdapIntunePackage.ps1 `
  -ReleaseTag tauri-v0.1.5 `
  -IntuneWinAppUtilPath C:\Tools\IntuneWinAppUtil.exe
```

Het script downloadt precies die publieke release, controleert de gepubliceerde SHA-256 én de geldige Authenticode-handtekening van `CaptureTech IT-Services BV`. Daarna maakt het onder `deployment\intune\out` een `.intunewin` plus `win32LobApp.json`.

## Publiceren met WinTuner

Installeer WinTuner eenmalig en publiceer het gemaakte pakket. Gebruik eerst een testgroep; kies bewust tussen beschikbare en verplichte installatie.

```powershell
Install-Module WinTuner -Scope CurrentUser

& .\deployment\intune\Publish-CaptureTechAutopilotGdapWinTuner.ps1 `
  -PackageFolder .\deployment\intune\out\CaptureTech-Autopilot-GDAP-0.1.5 `
  -Username beheerder@capturetech.com `
  -TenantId 2fa1f708-9c18-4add-88b7-d761eac5c493 `
  -AvailableFor '<Entra-groep-object-id>'
```

Voor een verplichte installatie vervang je `-AvailableFor` door `-RequiredFor`. WinTuner accepteert ook meerdere groep-object-ID's. Gebruik geen `AllDevices` of `AllUsers` totdat de testgroep de installatie, de Startmenu-snelkoppeling en de detectie heeft bevestigd.

De detectieregel controleert de registry-informatie, het daadwerkelijke EXE-bestand én opnieuw de geldige CaptureTech-signatuur. De uninstaller verwijdert zowel de app als de Startmenu-snelkoppeling.
