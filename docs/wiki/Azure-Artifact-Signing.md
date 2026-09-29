# Azure Artifact Signing

CaptureTech Autopilot GDAP gebruikt Azure Artifact Signing met GitHub OpenID
Connect (OIDC). Er wordt geen PFX, private key of client secret in GitHub
opgeslagen.

## CaptureTech signing-account

| Onderdeel | Waarde |
| --- | --- |
| CaptureTech Entra-tenant | `2fa1f708-9c18-4add-88b7-d761eac5c493` |
| Azure-subscriptie | `CaptureTech IT-Services` (`4d4f4a31-2d9b-4b7e-bf40-8e151c714f33`) |
| Signing endpoint | `https://weu.codesigning.azure.net/` |
| Signing account | `ctsigningcert` |
| Certificate profile | `CISIT` (Public Trust) |
| Verwachte publisher | `CN=CaptureTech IT-Services BV` |
| Private bronrepository | `vtHul-IT/Autopilot-GDAP` |
| Publieke downloads | `vtHul-IT/Autopilot-GDAP-Downloads` |

Artifact Signing gebruikt kortlevende certificaten. De release-workflow voegt
daarom verplicht een RFC3161-timestamp toe; een correct ondertekende EXE blijft
ook na het verstrijken van het tijdelijke leaf-certificaat geldig.

## Eenmalig: GitHub OIDC-identiteit in Entra

Voer deze stap uit in de CaptureTech Entra-tenant met een account dat
appregistraties en roltoewijzingen mag beheren.

1. Maak een single-tenant appregistratie, bijvoorbeeld
   `CaptureTech Autopilot GDAP Release Signing`.
2. Maak voor de service principal een federated credential met de GitHub
   Actions-scenario in de Azure-portal:

   | Veld | Waarde |
   | --- | --- |
   | Issuer | `https://token.actions.githubusercontent.com` |
   | Audience | `api://AzureADTokenExchange` |
   | Organization | `vtHul-IT` |
   | Organization ID | `188970125` |
   | Repository | `Autopilot-GDAP` |
   | Repository ID | `1381417667` |
   | Entity type | `Environment` |
   | Environment | `release-signing` |

3. Open signing-account `ctsigningcert` en wijs aan deze service principal
   uitsluitend de rol **Artifact Signing Certificate Profile Signer** toe,
   bij voorkeur op het `CISIT` certificate profile.
4. Bewaar de **Application (client) ID**. Een client secret is niet nodig en
   mag niet worden aangemaakt voor deze GitHub-integratie.

## Eenmalig: protected GitHub Environment

Maak in de private bronrepository via **Settings > Environments** de environment
`release-signing` en stel minimaal één CaptureTech releasebeheerder in als
required reviewer. GitHub Free ondersteunt required reviewers niet voor een
private organisatierepository; hiervoor is GitHub Team of Enterprise nodig.
Voeg daarna onderstaande **environment variables** toe:

| Variabele | Waarde |
| --- | --- |
| `AZURE_CLIENT_ID` | Application (client) ID van de OIDC-appregistratie |
| `AZURE_TENANT_ID` | `2fa1f708-9c18-4add-88b7-d761eac5c493` |
| `AZURE_SUBSCRIPTION_ID` | `4d4f4a31-2d9b-4b7e-bf40-8e151c714f33` |
| `AZURE_ARTIFACT_SIGNING_ENDPOINT` | `https://weu.codesigning.azure.net/` |
| `AZURE_ARTIFACT_SIGNING_ACCOUNT` | `ctsigningcert` |
| `AZURE_ARTIFACT_SIGNING_PROFILE` | `CISIT` |
| `AZURE_SIGNING_PUBLISHER_SUBJECT` | `CN=CaptureTech IT-Services BV` |
| `RELEASE_PUBLISHER_APP_ID` | App ID van de GitHub App voor publicatie naar `Autopilot-GDAP-Downloads` |

Deze identifiers zijn geen geheimen. Configureer nadrukkelijk geen
`AZURE_CLIENT_SECRET`, certificaatbestand of PFX in GitHub. Voeg alleen de
private key van de release-GitHub-App toe als environment secret
`RELEASE_PUBLISHER_APP_PRIVATE_KEY`.

## Releaseflow

- Pull requests bouwen en testen alleen; ze kunnen Azure nooit benaderen.
- Een handmatige workflowrun met **sign_test** ondertekent een testartifact,
  controleert de Authenticode-publisher en maakt een signed checksum. Er wordt
  geen GitHub Release aangemaakt.
- Een `tauri-v*` tag bouwt eerst de EXE en wacht daarna op goedkeuring van
  `release-signing`. Pas na een geldige handtekening en timestamp wordt de
  release gepubliceerd in `vtHul-IT/Autopilot-GDAP-Downloads`.
- Ontbreekt een vereiste GitHub-variable of faalt signing, dan faalt de run en
  wordt geen unsigned release gepubliceerd.

Controleer een test- of releaseartifact op Windows met:

```powershell
$signature = Get-AuthenticodeSignature -LiteralPath .\capturetech-autopilot-gdap.exe
$signature | Format-List Status, StatusMessage, SignerCertificate, TimeStamperCertificate
```

Verwacht `Status : Valid`, publisher `CaptureTech IT-Services BV` en een
ingevulde `TimeStamperCertificate`.

## Repositoryzichtbaarheid en publieke downloads

De bronrepository is privé. De workflow gebruikt een GitHub App met uitsluitend
`Contents: Read and write`, geïnstalleerd op de publieke downloadrepository,
om releases over repositories heen te publiceren. Gebruik geen persoonlijke
PAT voor deze koppeling.
