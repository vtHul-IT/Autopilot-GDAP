# Installatie en releases

## Eenmalige partnerinrichting

Voer op een beheerpc met Azure CLI en Global Administrator-rechten uit:

```powershell
irm "https://raw.githubusercontent.com/vtHul-IT/Autopilot-GDAP/refs/heads/master/Setup-AutopilotApp.ps1" -OutFile .\Setup-AutopilotApp.ps1
.\Setup-AutopilotApp.ps1 -PartnerTenantId "<PARTNER-TENANT-ID>"
```

Geef daarna klantconsent per klanttenant en controleer de GDAP/PIM-activatie.

## Portable Tauri-release

Een tag in de vorm `tauri-v*` start de Windows x64-build. De workflow publiceert
de portable `capturetech-autopilot-gdap.exe` uitsluitend nadat Azure Artifact
Signing een geldige Authenticode-handtekening en timestamp heeft geplaatst.
Zonder signingconfiguratie faalt de release bewust; een nieuwe unsigned EXE
wordt niet gepubliceerd. Zie [Azure Artifact Signing](Azure-Artifact-Signing)
voor de eenmalige OIDC- en GitHub Environment-inrichting.

## Ontwikkelen

```powershell
cd .\tauri-app
npm install
npm run tauri dev
```

De browserpreview gebruikt demodata. Alleen de Tauri-desktopapp start de
PowerShell-worker en de echte Microsoft-aanmeldingen.
