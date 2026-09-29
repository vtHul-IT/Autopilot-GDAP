# OOBE: apparaat registreren

Open tijdens Windows Setup een verhoogde PowerShell met `Shift + F10`.

## Tauri-app (aanbevolen)

```powershell
$exe = Join-Path $env:TEMP "CaptureTech-Autopilot-GDAP.exe"
irm "https://github.com/vtHul-IT/Autopilot-GDAP-Downloads/releases/latest/download/capturetech-autopilot-gdap.exe" -OutFile $exe
Start-Process -FilePath $exe
```

De portable app heeft Windows 10/11 x64, PowerShell 5.1+ en WebView2 Evergreen
nodig. Meld aan in de browser met het IT-Hulp-account; device code en WAM worden
niet gebruikt. Voor een klanttenant hergebruikt de browser dezelfde SSO-sessie
in één flow. De EXE bevat een administrator-manifest. Verschijnt de
administratorwaarschuwing toch in de app, kies dan **Start opnieuw als
administrator**; Windows opent vervolgens de normale UAC-bevestiging.

## WPF-fallback

Gebruik deze route wanneer WebView2 ontbreekt of wanneer gerichte diagnose nodig
is:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
irm "https://raw.githubusercontent.com/vtHul-IT/Autopilot-GDAP/refs/heads/master/Get-AutopilotGDAP.ps1" | iex
```

## Daarna

1. Kies de klant uit Partner Center.
2. Verbind met de klanttenant. Bij `AADSTS90099` of ontbrekende consent kies je
   **Klantinstelling starten** in de dialoog, laat een klant-Global Administrator
   accepteren en kies daarna **Opnieuw verbinden**.
3. Kies een Autopilot-profiel.
4. Kies alleen een statische groepskandidaat wanneer de tool daarom vraagt.
5. Registreer het apparaat en wacht op import en profieltoewijzing.
6. Herstart pas wanneer de app dat na succesvolle afronding toestaat.
