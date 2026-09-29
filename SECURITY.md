# Security policy

## Ondersteunde versies

| Onderdeel | Ondersteund |
| --- | --- |
| CaptureTech Tauri-app | De meest recente `tauri-v*`-release |
| PowerShell/WPF fallback | De meest recente `v1.*`-release |
| `master` | Onder actieve ontwikkeling; niet bedoeld als productie-download |

## Een kwetsbaarheid melden

Meld beveiligingsproblemen **niet** via een publiek issue en plaats geen tokens,
hardwarehashes, serienummers, klanttenant-ID's of Graph-loguitvoer in een issue.

Gebruik in plaats daarvan een private GitHub Security Advisory:

<https://github.com/mvthul/Autopilot-GDAP/security/advisories/new>

Vermeld minimaal:

- een duidelijke omschrijving en mogelijke impact;
- reproduceerstappen of een minimale proof of concept;
- betrokken versie, Windows-versie en of Tauri of de WPF-fallback is gebruikt;
- eventueel relevante foutcodes, ontdaan van klant- en accountgegevens.

We bevestigen ontvangst zo snel mogelijk en stemmen de oplossing en publicatie
van een advisory met de melder af. Bij vermoeden van een gelekt token of ongewenste
tenanttoegang: trek de sessie of consent direct in via Entra en meld het daarna
privé.

## Security-grenzen van de tool

- De app gebruikt alleen delegated Graph-permissies; er zijn geen client secrets
  of app-only credentials.
- GDAP- en PIM-rollen blijven leidend en worden niet door de tool gewijzigd.
- De Tauri-app gebruikt op een gewone desktop Windows Web Account Manager (WAM)
  en houdt tokens uitsluitend in de actieve workercontext. Er wordt geen eigen
  Partner Center-refresh-tokenbestand aangemaakt; een oude DPAPI-cache wordt na
  een succesvolle WAM-sessie verwijderd. Tijdens OOBE wordt browser-SSO gebruikt.
- Nieuwe Tauri-releases vereisen Azure Artifact Signing via een protected GitHub
  Environment en GitHub OIDC. De signing private key verlaat Azure nooit en
  GitHub bevat geen PFX of client secret. Controleer alsnog release, tag,
  Authenticode-publisher en checksum vóór distributie. `tauri-v0.1.4` is een
  historische unsigned release.

## Geautomatiseerde controles

GitHub Advanced Security scant geheimen en pushen van bekende geheimen wordt
geblokkeerd. De CodeQL-workflow scant de TypeScript- en Rust-code bij pushes,
pull requests, handmatige runs en wekelijks volgens schema. Dependabot houdt
GitHub Actions, npm- en Cargo-afhankelijkheden bij.
