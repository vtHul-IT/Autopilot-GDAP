# CaptureTech Autopilot GDAP

Deze wiki beschrijft het veilig registreren van Windows-apparaten in een
klanttenant via GDAP, Microsoft Graph en Windows Autopilot.

## Snel beginnen

1. Controleer de [GDAP- en PIM-rechten](Permissions-and-GDAP).
2. Doe de eenmalige [app-inrichting](Installation-and-releases).
3. Gebruik in OOBE de [Tauri-app of WPF-fallback](OOBE).
4. Raadpleeg de [troubleshootingstappen](Troubleshooting) bij consent-, Graph-
   of groepsfouten.
5. Beheerders vinden de release-inrichting onder
   [Azure Artifact Signing](Azure-Artifact-Signing).

## Belangrijke uitgangspunten

- De tool gebruikt alleen delegated toegang van het aangemelde IT-Hulp-account.
- De app wijzigt geen GDAP- of PIM-rollen.
- `-Online`, `-TenantId` en `-Assign` zijn verplicht voor een registratie.
- Dynamische groepen worden nooit handmatig gemuteerd. Een eenduidige
  `[OrderID]:tag`-regel levert automatisch `-GroupTag tag` tijdens registratie.
- `-AddToGroup` is uitsluitend toegestaan voor een unieke, geschikte statische
  security group.

De broncode, downloads en security policy staan in de
[hoofdrepository](https://github.com/mvthul/Autopilot-GDAP).
