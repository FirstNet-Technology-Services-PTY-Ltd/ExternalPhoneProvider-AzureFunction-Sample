# EPP endpoint setup reference

[Documentation](../../docs/README.md) | [First deployment](../../docs/GETTING-STARTED.md) | [Troubleshooting](Troubleshooting.md)

**EPP** stands for **External Phone Provider**. This reference covers setup choices, reruns, and
maintenance. For a first deployment, follow the linked [five-step deployment guide](../../docs/GETTING-STARTED.md); it keeps preparation,
deployment, provider validation, policy activation, and handoff in order.

| Task | Section |
| --- | --- |
| Prepare access, tools, and hosting | [Prerequisites](#prerequisites-for-step-2), [permissions](#permissions-are-separate), [plans](#service-plan-selection) |
| Choose the dedicated app | [Step 1](#step-1---manually-create-the-application) |
| Run or review setup | [Step 2](#step-2---download-and-run-one-script), [certificate choice](#encryption-certificate-selection), [cancel at approval](#reviewing-the-plan-without-deploying) |
| Use known inputs and versions | [Noninteractive example](#noninteractive-example), [source versioning](#source-versioning) |
| Find deployment results | [Summary fields](#read-the-deployment-summary) |
| Validate, activate, and maintain | [Step 3](#step-3---manually-validate-and-activate-policy), [renewal](#encryption-certificate-lifecycle), [rollback](#rollback-and-decommissioning) |
| Develop setup changes | [Offline checks](#offline-setup-checks) |

Confirm [provider access and Microsoft's approved procedure](../../docs/ONBOARDING.md#before-purchasing-or-deploying)
before deployment.

Setup creates **one regional endpoint**. See [Front Door](../../docs/FRONTDOOR.md) for regional continuity.

## Availability

Choose **Infobip, Soprano, or Telesign** and **FC1/EP1** hosting. Setup detects the tenant's replication scope
and selects the **EU** provider route for EU tenants or **Global** otherwise, without a scope picker.
**JavaScript** is the default language, without a prompt. To use another language, run
`.\Setup-Epp.ps1 -Language csharp` or `.\Setup-Epp.ps1 -Language python`.
The legacy `-Language dotnet` value remains accepted for C#.
Setup selects `released-package.zip` from the matching language's stable release and verifies it
against that release's `SHA256SUMS.txt` before publishing.
See [source/package selection](#source-versioning).

Both channels are configured. Profile objects `deployment.routes.global` and
`deployment.routes.eu` define `smsEndpoint`, `voiceEndpoint`, tenant, authentication, and timing
values. Setup writes the endpoints to `EPP_PROVIDER_SMS_ENDPOINT` and
`EPP_PROVIDER_VOICE_ENDPOINT`; OAuth profiles also supply their API app ID and scope.
All guided providers use the complete HTTPS URLs from the selected profile without appending paths.

Use a package that supports channel-specific settings; neither channel uses the other channel's URL.

Soprano and Telesign currently use identical Global/EU URLs. Infobip uses the `api.infobip.com`
host for Global and `api-eu.infobip.com` for EU. Each OAuth provider uses the same API app ID/scope
across its two routes, except that Telesign's OAuth values are pending provider confirmation.
The route label is not a residency or Azure-region selection.

### Provider tenant configuration

Provider profiles distinguish these adjacent fields under `deployment`:

| Field | Purpose |
| --- | --- |
| `tenantId` | Provider's Security Store tenant; used for provider discovery and recorded as `providerTenantId` in the deployment summary |
| `AccessTokenScopeTenant` | OAuth token-issuing tenant; mapped to `EPP_PROVIDER_TENANT_ID` and recorded as `accessTokenScopeTenant` |

The token tenant can differ from the Security Store tenant. For older profiles that omit
`AccessTokenScopeTenant`, setup uses `tenantId`; explicit empty, invalid, or placeholder values
are rejected. OAuth setup adds both tenants to the reviewed application allowlist, deduplicates
equal values, and preserves existing allowed tenants. The application home tenant remains allowed.
Easy Auth still admits only the approved Microsoft caller.

Telesign's profile contains placeholders for the token tenant and regional API app IDs/scopes.
Complete [Telesign configuration](../../docs/ONBOARDING.md#telesign-oauth-configuration-and-handoff)
before deployment.

### Tenant scope and Azure region recommendations

Setup reads `tenant_region_scope` from the selected tenant's public-cloud OpenID Connect discovery
document before region selection. It does not infer replication scope from the tenant's country,
the subscription, or the chosen Azure region. Missing or invalid discovery metadata stops setup.
`-EndpointRegion` is optional in both interactive and unattended runs; an explicit value must match
the detected EU/Global provider route.

Only tenants with replication scope **EU** receive a filtered shortlist: Azure-recommended physical
regions within the [EU Data Boundary](https://learn.microsoft.com/privacy/eudb/eu-data-boundary-learn#eu-data-boundary-countries-and-datacenter-locations),
which includes EU and EFTA countries. Other scopes retain the existing shortlist and ordering.
The region catalog comes from the subscription's live location metadata, not a separately hosted
datacenter configuration file. The filter checks Azure **geography**, not the broader
`geographyGroup`: the [Europe geography](https://learn.microsoft.com/azure/reliability/regions-list)
contains North Europe (Ireland) and West Europe (Netherlands), while the Europe group also contains
the United Kingdom, which is outside the boundary.

**Show all regions**, manual entry, and explicit `-Location` remain available. For EU tenants,
an out-of-boundary selection warns; missing geography metadata produces an unverifiable-location
warning instead. The selected region remains in the deployment plan for review. An empty EU
shortlist does not silently fall back to global recommendations. Availability and quota checks
still apply. These are deployment recommendations, not enforcement or a GDPR compliance guarantee.

## Service plan selection

Setup offers these two Linux hosting plans:

Review the [Azure hosting and provider cost estimate](../../docs/COST-CALCULATOR.md), also linked
directly from the service-plan prompt.

| Option | Hosting |
| --- | --- |
| 1. Flex Consumption (FC1) | On-demand with a free usage grant; zero always-ready instances, 2048 MB, up to 40 on-demand instances |
| 2. Premium (EP1) | Existing Premium configuration with one warm instance |

FC1 on-demand compute has a
[free usage grant](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan#billing);
usage beyond the grant, Key Vault, storage, telemetry, and provider services can incur charges.
FC1 can scale to zero and cold-start.

EP1 allocates paid warm capacity without OTP traffic. Budget for the plan, storage, Key Vault,
telemetry, and provider services. Budget alerts do not stop spending.

Both plans use the same [request-time credential acquisition](../../TECHNICAL.md#provider-settings-and-credential-acquisition).
API-key secrets are read on each live request, and Azure Identity manages its own token cache.
Setup does not configure custom credential caches or refreshers.

Press Enter to accept **FC1**, or use `-ServicePlan FC1` or `-ServicePlan EP1` to skip the prompt.
Unattended setup still requires an explicit service plan.

**Use a different resource prefix to change plans.** In-place FC1/EP1 migration is not supported.
Preflight rejects a mismatch with the existing resource-group tag or actual hosting-plan SKU,
including older EP1 deployments without the new tag. Existing EP1 deployments can be rerun with
`-ServicePlan EP1`.
For an active endpoint, use a new Step 1 app or coordinate key continuity. Reusing an app still
requires reviewing the certificate action; the interactive default is replacement, which affects
every endpoint sharing the app. Select **Reuse** explicitly when keeping the current certificate.

<a id="step-1---manually-create-the-application"></a>
## Step 1 - choose an application registration

For the first deployment, use a nonproduction tenant and subscription.

**Create during guided setup:** press Enter to accept **Create a new application** in the application picker,
press Enter to accept **EPP Application** or enter a display name (1-256 characters), and choose
a provider by name from the alphabetized list (**Infobip, Soprano, Telesign**). Blank provider-name input
prompts again; there is no default provider. An explicit `-Provider` skips that provider prompt.
The new registration is only planned at this point: setup creates it after final deployment
approval, not when you choose the menu option. Canceling before approval creates nothing.
An existing app with the same display name is never adopted automatically.

**Use an existing dedicated registration:** select/search for it or supply its client ID.
To create it manually before setup:

1. In the customer tenant's **Microsoft Entra admin center > App registrations**, register a
   new application for this endpoint with **Accounts in this organizational directory only** as its initial
   supported account type; setup changes it to organizational multi-tenant after approval.
   No redirect URI, client secret, API permission, or app role is required manually.
2. Record the **Directory (tenant) ID** and **Application (client) ID**. For an existing app,
   supply its client ID, not the application's object ID. Setup never silently creates a
   replacement if an existing ID is invalid.
3. Complete provider purchase, sender registration, and API onboarding.
   Infobip, Soprano, and Telesign OAuth use client-assertion exchange with the selected access-token
   tenant/scope/application ID. Complete Telesign's profile placeholders first. Setup does not
   grant provider API consent or application roles. Finish the
   [provider authentication handoff](../../docs/ONBOARDING.md#complete-provider-authentication)
   after setup creates the vault and identity identifiers needed for those steps.

New registrations created by setup also start single-tenant, without a client secret or redirect
URI; the remaining approved configuration follows the same path as an existing app.
Creation is an interactive choice. Unattended runs still require an existing `-ApplicationId`.

Setup configures:

- Organizational multitenancy and the Microsoft Entra ID allowed-tenants preview: home tenant,
  selected provider's Security Store and OAuth token tenants, and preserved existing allowed tenants.
- The app's enterprise application with assignment required, `Epp.Invoke`, and its assignment to
  the Microsoft phone-provider service principal.
- That Microsoft principal's tenant-wide Graph `Application.Read.All`, identifier URI, public JWE certificate, and Easy Auth caller restriction.
- The disclosed outbound managed-identity federated credential for OAuth providers.

New outbound federated credentials are named using the managed identity's principal ID, so a
recreated identity does not collide with a credential for the previous identity. Exact
issuer/subject/audience matches are reused under any name, including legacy Function-based names.
Other trusts are preserved, not overwritten or automatically removed.

## Prerequisites for Step 2

- **Azure Cloud Shell in PowerShell mode, or PowerShell 7+**, with an Azure CLI user login.
  Certificate issuance stays in Key Vault; no local certificate-store cmdlets are needed.
- Azure CLI **2.60.0+ for FC1** or **2.48.1+ for EP1** on `PATH`, with GitHub, Azure,
  Microsoft Graph, Key Vault, and required SCM access. Setup can install Bicep after confirmation,
  but Azure CLI must already be installed.
- An Azure **user** allowed to deploy at subscription scope and create scoped role assignments.
  Bicep grants **Key Vault Certificates Officer** and **Key Vault Secrets Officer** on this vault.
- **Certificate reuse:** the operator needs source-vault ARM read, certificate read, and
  secret-version metadata read. A different vault also requires permission to grant the Function
  secret read through RBAC or an access policy. The vault must be in the customer tenant;
  use `-KeyVaultSubscriptionId` for another subscription. Setup never reads the private key locally.
- A Microsoft Entra **Privileged Role Administrator** for granting the Microsoft first-party service
  principal Graph `Application.Read.All`. Microsoft Graph operations use the current Azure CLI
  user session through `az ad` and `az rest`; Azure subscription roles alone do not grant these
  directory permissions.
- **New app registration:** the signed-in user must also be allowed to register applications in
  the selected tenant, and its Graph access must permit creation. If default user app creation is
  restricted, an appropriate role such as **Application Developer** can provide that permission.
  This does not replace the other setup permissions.
  See [application creation permissions](https://learn.microsoft.com/en-us/graph/api/application-post-applications?view=graph-rest-1.0#permissions).
- Microsoft Graph **beta** access for `signInAudienceRestrictions`. The Security Store and OAuth token tenants are added;
  Microsoft Entra ID always allows the home tenant.
  See the
  [allowed-tenants schema](https://learn.microsoft.com/en-us/graph/api/resources/allowedtenantsaudience?view=graph-rest-beta).
- The selected **Linux FC1 or EP1** plan available in the region with enough quota. Resolve
  [`SubscriptionIsOverQuotaForSku`](Troubleshooting.md#deployment-fails-with-subscriptionisoverquotaforsku)
  before retrying. The operator needs subscription-scoped `/register/action`.

### Permissions are separate

**Owner at the selected subscription** includes deployment, provider registration, and
role-assignment rights. Another option is
**Contributor** plus **Role Based Access Control Administrator** at the required scope, subject
to any role-assignment conditions. Setup deploys at subscription scope and creates a new resource
group, so access to an unrelated group does not cover the deployment. Activate eligible PIM roles before setup. See
[Azure roles](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles).

Azure roles do not grant Entra/Graph permissions, and Entra roles do not grant Azure/vault access.
The signed-in user needs the listed Entra roles for setup. An Authentication Policy Administrator
handles activation separately. Setup grants vault roles only to its operator and Function identity.

### Install and check workstation tools

Install missing tools using
[PowerShell installation](https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell),
[Azure CLI installation](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli?view=azure-cli-latest)
instructions.
Open a new **PowerShell 7** window after installation, then check:

```powershell
$PSVersionTable.PSVersion
az version
```

Interactive setup can install missing Bicep.

| Choice | Azure runtime | Package contents |
| --- | --- | --- |
| JavaScript | Node.js 22, Functions v4 | Application and production dependencies |
| C# | .NET 10 isolated, Functions v4 | Framework-dependent Linux x64 publish output, Function metadata, and extensions |
| Python | Python 3.11, Functions v4 | Application and Linux x64 dependencies in `.python_packages/lib/site-packages` |

Setup verifies and publishes the selected ZIP, recording its SHA-256 in the deployment summary.

For [unattended execution](#noninteractive-example), preinstall prerequisites or allow Bicep
installation with `-InstallPrerequisites`. Azure CLI must already be installed. Sign-in, MFA,
consent, and installation prompts are separate from deployment approval.

Use `-ForceAuthentication` for ambiguous cached identities. It requests device-code authentication,
does not clear shared caches, and cannot be combined with `-NonInteractive`.

## Step 2 - download and run one script

Download [Setup-Epp.ps1](../Setup-Epp.ps1) from the upstream raw URL:

```powershell
Invoke-WebRequest `
    -Uri 'https://raw.githubusercontent.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/main/setup/Setup-Epp.ps1' `
    -OutFile .\Setup-Epp.ps1
```

Review the downloaded script before running it:

```powershell
.\Setup-Epp.ps1
```

Force explicit account selection when testing on a shared or multi-account computer:

```powershell
.\Setup-Epp.ps1 -ForceAuthentication
```

Selection menus mark the default and show its number in brackets. **Enter accepts that default**;
choose **0** or **Cancel** where offered to stop instead. Required text inputs without a known
default, such as a versioned certificate URL, prompt again on blank input. Provider selection
never has a default. Installation and final deployment confirmations still default to **No**.

The flow is:

1. **Choose the customer Azure context.** Setup lists cached enabled Azure CLI user subscriptions,
   then asks for the tenant and subscription. Refresh or start device-code sign-in when the
   expected account is missing. Explicit `-TenantId` and `-SubscriptionId` values are preserved.
   Enter prefers the current CLI tenant/subscription when eligible, otherwise the first listed
   tenant/subscription within the chosen context. With no eligible entries, the displayed default
   is sign-in; a missing explicit subscription instead defaults to refreshing the list.
2. **Choose the dedicated app registration.** The application picker shows
   organizational app names and client IDs, supports bounded name-prefix search and manual client-ID
   entry, and defaults to **Create a new application** on Enter, including at the manual client-ID
   prompt. That option asks for a display name, defaulting
   to **EPP Application** on Enter, and stages creation for final deployment approval.
   The picker never substitutes an object ID.
   A supplied client ID skips this selector.
3. **Detect tenant scope and choose the Azure region.** Setup selects EU/Global provider routing
   from the tenant metadata, then uses Azure's current Recommended regions for a shortlist.
   Only EU tenants receive the [EU Data Boundary filter](#tenant-scope-and-azure-region-recommendations).
   All-region and manual-entry options remain available. `-Location` skips the picker, but EU
   tenants still receive a boundary check and a warning if appropriate.
   Enter selects the first displayed region, respecting the EU shortlist. An empty shortlist
   defaults to showing all regions, not to selecting a region outside the shortlist automatically.
4. **Choose a provider by name.** JavaScript is used unless `-Language csharp` or
   `-Language python` was supplied; there is no language prompt.
   When `-Provider` is omitted, setup reads the application's allowed-tenants configuration:
   no supported provider prompts for a name, one asks for confirmation, and several require a
   name. For a new application, it shows all supported provider names in alphabetical order,
   without reading a nonexistent registration or selecting a default.
   Blank provider-name input prompts again until a provider is selected.
   Existing allowed provider tenants are preserved; provider options are never numbered.
   The selected [profile](#availability) supplies both channel URLs and auth/timing values.
   The launcher has no endpoint/credential overrides or `PackageUrl`/`PackageSha256` inputs.
   It uses `packages/catalog.json` and the latest stable CI release for the selected language, or your
   `-PackageReleaseTag epp-packages-<run>-<attempt>-<language>`. Use `javascript`, `dotnet`, or `python`
   as the tag suffix. Malformed/disabled profiles fail before resource creation.
5. **Service plan selection:** choose **Flex Consumption FC1** (free usage grant, zero always-ready
   instances, the Enter default) or **Premium EP1** (warm instance).
   Supply `-ServicePlan FC1` or `-ServicePlan EP1` to reuse a known selection.
6. **Accept the default resource prefix `epp`, or enter your own**, such as `contoso`.
   All resources created by the script start with
   this prefix. Use 2-8 lowercase letters or digits, starting with a letter. Every top-level
   resource name then adds the meaningful `epp` marker, for example
   `contoso-epp-rg-<suffix>`. A deterministic suffix derived from the
   subscription, application ID, and prefix reduces global-name collisions. Reruns use the same names
   when given the original prefix. Unattended setup still requires `-ResourcePrefix`.
7. **Check prerequisites and revalidate authentication.** Missing Bicep can be installed after a
   separate confirmation. Graph operations reuse the selected Azure CLI user session; no Graph
   SDK installation or separate sign-in occurs.
8. **Choose encryption certificate handling.** With no registered encryption certificate, use the
   normal creation flow. Otherwise Enter defaults to **Replace**: remove the registered encryption
   credentials and create one new certificate after final approval. To keep a certificate instead,
   select **Reuse** and supply its versioned Key Vault location. Reuse of one among several also
   removes the others after approval. Use **0** or **Cancel** to stop the certificate decision.
9. **Review the complete plan**, including resource names, tenant/subscription, language, service plan,
   automatic package verification/build, provider
   settings, scoped roles, the exact encryption key IDs to keep/remove, certificate location or
   staging name, and application configuration. Bicep receives these
   exact names for existing apps; it does not independently calculate a different naming scheme.
   For a new app, the plan instead shows its requested display name and name patterns containing
   `<app-id-hash>`. After approval assigns the client ID, setup calculates and displays the final
   eight-character suffix and checks resource ownership before deploying Azure resources.
   The plan also lists the six required **Azure resource providers** and their registration states.
   These Azure service registrations are separate from your phone-provider selection.
10. **Enter `Yes` or `Y` to deploy.** `No`, `N`, or Enter cancels without Azure or app-registration changes. Responses
    are case-insensitive. Invalid answers prompt again; individual resources do not request
    additional approvals.

Azure resource deployment and Function publication can each take several minutes; sign-in
and permission propagation can add time. Keep the session open until deployment completes.
A rotating activity indicator identifies long-running deployment operations without displaying
elapsed time, a percentage, or a completion estimate. Redirected output and `-NonInteractive` runs
use static status messages.

### Encryption certificate selection

Setup reads `keyCredentials` before deployment and identifies **`type=AsymmetricX509Cert`,
`usage=Encrypt`** entries, including expired entries. `Encrypt` is the usage, not the type.
It displays each key ID, certificate thumbprint, name, and validity. Signing/verification
certificates are not encryption candidates, and unsupported encryption credential types stop setup.

| Existing encryption credentials | Choice | Result after successful deployment |
| --- | --- | --- |
| None | Creation is automatic; optional `-CertificateAction Create`. | Register one certificate from the setup vault. |
| One | Enter accepts `Replace`; select `Reuse` explicitly to provide its Key Vault certificate version. | Replace the existing credential with one new credential, or keep the existing key ID when reusing. |
| Several | Enter accepts `Replace`; select `Reuse` explicitly to choose a key ID and provide its certificate version. | Replace all encryption entries with one new credential, or remove only the other encryption entries when reusing. |

**Interactive Enter defaults to cleanup and replacement, not reuse.** This affects every endpoint
sharing the registration; coordinate maintenance for active applications. If you explicitly choose
Reuse and several credentials exist, the key picker defaults to the first displayed key, not the
newest certificate. You must still provide its exact versioned Key Vault location.
Use **0** or **Cancel** at a menu, or type **Cancel** at a text prompt, to stop.
Invalid locations can be corrected or followed by another choice; the action menu again defaults
to Replace. Selecting an action does not apply it: the complete deployment approval lists the exact
removals, and **Enter at final approval still means No**. Cleanup does not delete Key Vault objects
or signing credentials. Unattended runs with existing encryption credentials still require an
explicit `-CertificateAction`.

For reuse, open **Azure portal > Key Vault > Certificates > certificate > version** and copy
**Certificate Identifier**, of the form
`https://<vault>.vault.azure.net/certificates/<name>/<version>`. A version is required.
Do not supply a vault-only URL, `/keys/` URL, public `.cer` file, secret value, or a versionless
reference. Setup reads the public certificate and resolves the corresponding **versioned backing
secret**; the certificate and secret version identifiers need not be identical.

The certificate must exactly match the selected registered certificate, not just its display
name or RSA key. It must use exportable RSA of at least 2048 bits with an enabled,
certificate-managed PEM backing secret. Both the certificate and registered credential must be
valid now with more than 30 days remaining; any secret validity restrictions must also pass.
Existing compatible subjects and display names are preserved. A renewed certificate is not
silently appended, even if it reuses the same RSA key.

The Function uses its **system-assigned identity** for the private-key reference, not the setup
operator or the outbound provider identity. For a different vault, the plan grants **Key Vault
Secrets User at the certificate secret's scope** in RBAC mode. An access-policy vault instead
receives additive **Secrets/Get** permission while retaining existing permissions; this older
model grants secret read **vault-wide**, which is disclosed in the plan. External vault network
rules and certificate issuance policies are not modified. Provide a working network path from
the Function; operator access alone does not establish Function access.

All vaults must be in the customer tenant. The source vault defaults to the deployment
subscription; supply `-KeyVaultSubscriptionId` if it is elsewhere. Provider credentials remain
in the setup-created vault selected by `KEY_VAULT_URL`, even when the encryption certificate is
reused from another vault.

**Cleanup only removes the approved application encryption credentials.** It preserves other
application credentials and does not delete Key Vault certificates, keys, or secrets.
Replacement prepares a separate `phone-provider-encryption-<suffix>` certificate first.
If a run fails before registration, retrying the same approved replacement state reuses that
staged certificate. Setup verifies the Function's secret reference before changing the
registration, then reads back exactly one matching encryption credential.

**Coordinate maintenance for active applications.** Every endpoint sharing the registration is
affected, and cached/in-flight requests can still use retired keys. This is not zero-downtime
rotation and does not implement overlapping decryption keys. Complete the authorized evaluation
before activation or returning the endpoint to service.

### Reviewing the plan without deploying

`Setup-Epp.ps1` does not implement `-DryRun`, `-WhatIf`, or PowerShell `ShouldProcess`.
To review a real plan, run interactively, complete preflight, then answer **No**, **N**, or press Enter
at `Proceed with deployment? Enter Yes or Y to deploy, or No or N to cancel [No]`.
Do not supply `-ApproveDeployment`:
that switch authorizes the deployment phase without asking again.

This is a cancellation at the approval gate, not an offline simulation. You can select an existing
registration or plan a new one; neither is created or changed before approval.
Before the plan appears, setup can download tools and packages, request required installation,
and sign in through Azure CLI. It also checks permissions and regions, verifies package
checksums and contents, and compiles Bicep.
Installation, sign-in, and consent prompts are separate from deployment approval.
A preflight error is not a successful preview.

### After approving the plan

If you chose a new application, setup creates its registration first and saves
`application-<client-id>.json` in the output directory. This record contains its tenant, subscription,
client/object IDs, display name, provider, prefix, and resolved resource names; it is not a deployment
success summary. No secret is created with the registration. Its client ID determines the same
resource names used by later reruns with `-ApplicationId` and the original prefix.
The resolved resource-group ownership check must pass before further app configuration or Azure
deployment. If a later step fails, the app and its registration record remain; do not create another
app for the retry. An uncertain creation response is not retried automatically: inspect the selected
tenant before choosing creation again.

Setup rechecks the subscription and registers only missing `Microsoft.Web`, `Microsoft.Storage`,
`Microsoft.KeyVault`, `Microsoft.OperationalInsights`, `Microsoft.Insights`, and
`Microsoft.ManagedIdentity` providers before certificates or deployment. Preflight registers nothing.
Existing registrations are reused; `Registering` is sufficient once the requested region is exposed.
Polling/recognized propagation retries are bounded; permission and unsupported-region errors stop setup.
Subscription-wide registrations are not undone after later failures. See
[registration recovery](Troubleshooting.md#a-required-azure-resource-provider-is-not-registered).

Supply known values to shorten the prompts. Replace `<provider-id>` with your selected guided
provider's ID (`infobip`, `soprano`, or `telesign`); none is a default or recommendation:

```powershell
.\Setup-Epp.ps1 `
    -TenantId '<customer-tenant-id>' `
    -SubscriptionId '<subscription-id>' `
    -ApplicationId '<existing-client-id>' `
    -Location westus2 `
    -Language javascript `
    -ServicePlan FC1 `
    -Provider '<provider-id>' `
    -ResourcePrefix contoso
```

Replace the ID placeholders with quoted GUID strings before execution. Provider routing is detected
from the tenant; omit `-EndpointRegion` unless you need to assert an expected matching route.
The `-Channel` parameter
has been removed; omit it from existing setup commands. For an independent second provider
deployment, use a different prefix **and a dedicated app**.
The suffix does not include provider/region, so changing those inputs with the same
subscription/app/prefix can reconfigure the existing endpoint. See
[deployment separation and key constraints](../../docs/ONBOARDING.md#inputs-you-supply-to-setup).

The plan creates or updates the complete deployment. This includes a dedicated resource group,
Linux FC1 or EP1 hosting plan, Function App, storage, private package container, and Key Vault.
It also includes Log Analytics, Application Insights, an outbound managed identity, diagnostics,
Easy Auth, and scoped role assignments. Storage and package access use managed identity instead
of account keys or Azure Storage shared access signatures.
Telemetry uses the system identity; the outbound identity is selected explicitly, not through
a global `AZURE_CLIENT_ID`.

The Function starts with public ingress disabled. After Bicep creates the vault and permissions,
setup applies the [approved certificate action](#encryption-certificate-selection).
New certificates are self-signed, exportable RSA-2048 with subject/display name
**`CN=ExternalPhoneProvider`**. Initial creation uses `phone-provider-encryption`; replacement uses
a suffixed staging name; reuse preserves the selected key ID/display name.
Setup pins `EPP_DECRYPTION_KEY_PEM` to its **versioned PEM backing secret**, verifies resolution,
and registers one encryption entry without changing other credentials.
It **verifies Easy Auth before enabling ingress**.
SCM basic authentication stays disabled for both plans. FC1 uses Entra-authenticated **One Deploy**
for every language. Its `functionAppConfig` defines runtime, scaling,
and managed-identity deployment storage; setup does not write Premium-only runtime/build or
`WEBSITE_RUN_FROM_PACKAGE` settings. One Deploy handles publication and trigger synchronization.
EP1 uploads the verified ZIP to private Blob storage and uses managed-identity
run-from-package for every language. EP1 then restarts and synchronizes triggers.
Both plans verify that `SendOtp` is registered before reporting success.
On publication/startup failure it disables public ingress again; failure to close ingress is reported
explicitly rather than hidden.
Key-reference checks use bounded identity/role propagation retries. Failure stops certificate
registration, but infrastructure/settings may have changed. Metadata resolution does not replace
authorized decryption evaluation before activation.

Find the public certificate and timestamped [summary](#read-the-deployment-summary) in `epp-output`
beside the script, or `-OutputDirectory`. Service-plan fields record configuration, not verified
runtime behavior. Setup never downloads, writes, or imports the private key locally: the Function
receives it through its managed-identity reference. The certificate supplies its backing secret;
there is no separate `phone-provider-decryption-key` secret.

### Noninteractive example

Supply the required inputs, including an existing `-ApplicationId`, `-ServicePlan`, and `-ResourcePrefix`, and
**both `-NonInteractive -ApproveDeployment`**
to authorize the complete reviewed plan. `-NonInteractive` alone approves nothing; there is no
`-Stage`, `-Resume`, `-ConfigPath`, or policy-approval switch.

Replace the IDs/provider placeholder and choose an approved region, prefix, and plan.
Language defaults to JavaScript; provider routing is detected from the tenant scope.
This JavaScript example supports both channels. Establish the CLI user session for ARM and Graph
first; MFA/consent may still be required. There is no headless service-principal path.
Preinstall Bicep or explicitly allow its installation. In Cloud Shell, reuse the intended
directory's login instead of the local `az login` below; token checks select the subscription.

```powershell
$tenantId = '<customer-tenant-guid>'
$subscriptionId = '<subscription-guid>'
$applicationId = '<dedicated-app-client-guid>'

az login --tenant $tenantId
if ($LASTEXITCODE -ne 0) { throw 'Azure sign-in failed.' }
az account get-access-token --subscription $subscriptionId --output none
if ($LASTEXITCODE -ne 0) { throw 'Azure subscription token acquisition failed.' }
az account get-access-token --subscription $subscriptionId --resource-type ms-graph --output none
if ($LASTEXITCODE -ne 0) { throw 'Microsoft Graph token acquisition failed.' }

.\Setup-Epp.ps1 `
    -TenantId $tenantId `
    -SubscriptionId $subscriptionId `
    -ApplicationId $applicationId `
    -Location westus2 `
    -Provider '<provider-id>' `
    -Language javascript `
    -ServicePlan FC1 `
    -ResourcePrefix contoso `
    -OutputDirectory .\epp-output `
    -NonInteractive `
    -ApproveDeployment
```

Use `-InstallPrerequisites` only when authorizing automatic missing-dependency installation.
It installs the Azure CLI Bicep component only; the Microsoft Graph PowerShell SDK is not used.
Use the [source/version options](#source-versioning) to pin repeatable deployments.
Review the corresponding interactive plan first; `-ApproveDeployment` authorizes the complete
mutation set, not just package upload. Do not use it as a dry run.

Add `-PassThru` when automation also needs the structured deployment result. The timestamped
summary JSON is saved regardless.

The example assumes **no encryption credentials**. Otherwise choose `Reuse` or `Replace`;
approval alone never selects or replaces a certificate. Reuse requires both key ID and exact
certificate version, even with one credential. Add `@reuseCertificate` using this reviewed set:

```powershell
$reuseCertificate = @{
    CertificateAction = 'Reuse'
    EncryptionKeyId = '<key-id-to-keep-from-setup-or-the-app-manifest>'
    KeyVaultCertificateId = 'https://<vault>.vault.azure.net/certificates/<name>/<version>'
}
```

If necessary, also add `KeyVaultSubscriptionId` to that hashtable. For deliberate replacement,
use **`-CertificateAction Replace` instead of the reuse parameters**. This replaces all registered
encryption credentials, not just an expired one. Do not blindly rerun a replacement command after
a partial failure: inspect the current registration, and choose reuse if the new credential was
already registered.

### Read the deployment summary

Open the timestamped JSON under `epp-output` in a private editor. It contains identifiers and
configuration metadata, not provider credentials or private-key bytes. Keep it access-controlled.
**Save the output: the endpoint URL and Application (client) ID are required for policy updates.**

| Summary field | How to use it |
| --- | --- |
| `tenantId`, `subscriptionId`, `applicationId` | Verify the intended customer directory, Azure subscription, and endpoint **client ID**. |
| `tenantRegionScope` | Detected tenant replication scope used to select the provider route and apply EU-only region recommendations. |
| `resources.functionApp`, `resources.keyVault`, `resources.applicationInsights`, `resources.logAnalytics` | Find the exact Azure resources; do not guess names or use a different environment's vault. |
| `provider`, `endpointRegion`, `providerTenantId` | Confirm the tenant-derived provider route and Security Store tenant, separate from Azure location. Both SMS and voice use this configuration. |
| `accessTokenScopeTenant` | OAuth token-issuing tenant, matching `EPP_PROVIDER_TENANT_ID`; can differ from `providerTenantId` and is null for API-key deployments |
| `allowedProviderTenantIds` | Review the preserved allowlist, including the selected provider's Security Store and OAuth token tenants. This does not enable runtime switching between providers. |
| `providerSmsEndpoint`, `providerVoiceEndpoint` | Confirm the distinct or identical provider URLs for SMS and voice. These are outbound provider URLs, not the Function's `endpointUrl`. |
| `endpointUrl`, `identifierUri` | Exact SendOtp URL and registered app audience information for the authorized test/policy operator. |
| `encryptionKeyId`, `certificateThumbprint`, `certificateId`, `certificateSecretId`, `certificateExpiresUtc` | Public-key identification and version/renewal inventory. A secret **ID** is not its value; do not fetch its private-key contents. |
| `certificateAction`, `removedEncryptionKeyIds`, `certificateVaultSubscriptionId` | Review whether creation, reuse, or replacement occurred, the exact retired application key IDs, and the source certificate's subscription. |
| `certificateReferenceResolved` | `true` means the Function's exact secret reference resolved before registration. It is not proof of successful authorized decryption or provider delivery. |
| `endpointServicePrincipalId`, `microsoftPhoneProviderServicePrincipalId` | Tenant-local enterprise-application Object IDs; neither is the endpoint app client ID. |
| `source`, `sourceRevision`, `packageReleaseTag`, `packageUrl`, `sourcePackageSha256`, `packageSha256`, `language`, `servicePlan` | Commit-pinned setup source, package release provenance, and language/plan. C# is recorded as `csharp`; older summaries can contain `dotnet`. `sourcePackageSha256` and `packageSha256` identify the downloaded and deployed ZIP and match. |
| `policyChanged` | Expected `false`: deployment has not activated policy. |

The `provider` field must match your selected provider. For example, a record for the Global route
can contain `"endpointRegion": "global"`, `"certificateRenewal": "manual"`, and `"policyChanged": false`.
Those fields do not prove credentials, delivery, or monitoring work. Follow
[provider authentication](../../docs/ONBOARDING.md#complete-provider-authentication) next,
**even if the script's completion text does not prompt for your provider**.

### Encryption certificate lifecycle

Certificates **issued by setup** use **12-month validity, key reuse, and manual renewal**.
`EmailContacts` runs 30 days before expiry, **not `AutoRenew`**, and needs separately configured
vault contacts. Setup creates no contacts and guarantees no notifications.

In **Key Vault > Certificates > Certificate contacts**, add the approved operations/renewal
contact and verify the address and ownership. Portal labels can vary; follow
[certificate renewal and contacts](https://learn.microsoft.com/en-us/azure/key-vault/certificates/overview-renew-certificate).
Record `certificateExpiresUtc` in your inventory and create an independent scheduled reminder
before the 30-day window, with an escalation owner. EmailContacts is not an Azure Monitor alert
rule, and setup does not test email delivery. Monitor both the vault certificate's and Entra
credential's expiration; renewing one does not renew the other automatically.

Use **Reuse** for a rerun with the exact registered certificate and its versioned Key Vault
location. Reuse never issues a certificate or adds a new credential. If there are older or duplicate
encryption entries, approve which key ID to keep and which entries to retire.

For the Create/Replace paths, only a certificate-not-found response triggers issuance. Azure CLI
waits for self-signed issuance. Other errors, including pending-operation conflicts, stop setup
rather than overwriting a disabled, incompatible, or near-expiry staged certificate. Keep more than
30 days of validity remaining. No Key Vault version is deleted as part of application cleanup.

Coordinate renewal with the endpoint owner before expiry. **Replace** stages a new certificate
and switches the single-key endpoint under approved maintenance. Alternatively, synchronize the
renewed certificate in Microsoft Entra ID and Key Vault through the supported administrator
procedure, then **Reuse** that exact registered version. Setup does not append a second encryption
credential, even for the same RSA key.

**Vault renewal alone updates neither the app registration nor the pinned Function reference.**
Reuse leaves an external vault's issuance policy unchanged; automatic issuance there still
requires manual endpoint synchronization (`certificateRenewal: manual`). Account for every
endpoint sharing the key and cached/in-flight requests; decryption uses one in-process private key.

**Review the replacement default for legacy deployments.** A compatible matching Key Vault certificate
can be reused even if it has an older/custom subject. A standalone PEM secret without a Key Vault
certificate is not a reuse input: arrange an approved secure certificate import with a PEM backing
secret, or choose replacement. Setup never exports the private key locally. Do not manually delete
registered credentials merely to bypass the selection or matching checks.

Setup rechecks the application credentials against the reviewed plan before changing them.
Detected credential changes stop the run and require a new review; this is not an atomic lock.
Do not run setup concurrently against the same application. A failure after approval may
leave provisioned resources or changed app settings even when no encryption credentials were removed;
follow [safe recovery](Troubleshooting.md#recover-without-destructive-cleanup).

### Source versioning

Defaults are `-SourceRepository Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample` and
`-SourceRef main`. Setup resolves one commit for supporting PowerShell, Bicep, both catalogs,
and all catalog-listed profiles. The package catalog selects `released-package.zip` from that
repository's latest stable `epp-packages-<run>-<attempt>-<language>` release, where the suffix is
`javascript`, `dotnet`, or `python`. C# aliases select `dotnet` releases.
Each release contains only its language ZIP and `SHA256SUMS.txt`; setup verifies the ZIP using that
release's checksum. Draft, prerelease, unrelated, wrong-language, and ambiguous assets are rejected.
The plan/summary records the full resolved tag, URLs, and hashes.

For repeatable deployment, pin a reviewed full SHA **and**
`-PackageReleaseTag epp-packages-<run>-<attempt>-javascript` (or `-dotnet`/`-python` matching `-Language`).
Use the actual full tag recorded in the plan/summary. To test custom source, publish a public fork and
matching stable release; align both source options with the downloaded launcher. Local unpushed
changes are not downloadable.

Trust the selected repository: its PowerShell executes locally. Provider JSON selects data, not
another executable script. Downloads fail closed and temporary files are removed on success/failure.

### Offline setup checks

From the repository root, compile the infrastructure and run all setup regression suites without
Azure sign-in or resource changes:

```powershell
$templatePath = Join-Path ([IO.Path]::GetTempPath()) "epp-main-$([Guid]::NewGuid().ToString('N')).json"
az bicep build --file .\setup\infra\main.bicep --outfile $templatePath
if ($LASTEXITCODE -ne 0) { throw 'Bicep compilation failed.' }

$tests = @(
    'Launcher.Tests.ps1',
    'Accounts.Tests.ps1',
    'Graph.Tests.ps1',
    'ProviderConfiguration.Tests.ps1',
    'Selections.Tests.ps1',
    'Applications.Tests.ps1',
    'Progress.Tests.ps1',
    'Packages.Tests.ps1',
    'Certificates.Tests.ps1',
    'Providers.Tests.ps1'
)
foreach ($test in $tests) {
    pwsh -NoProfile -File (Join-Path '.\setup\tests' $test)
    if ($LASTEXITCODE -ne 0) { throw "$test failed." }
}

pwsh -NoProfile -File .\setup\tests\ServicePlans.Tests.ps1 `
    -TemplatePath $templatePath
if ($LASTEXITCODE -ne 0) { throw 'ServicePlans.Tests.ps1 failed.' }
Remove-Item -LiteralPath $templatePath
```

The suites cover launcher downloads and cleanup; account, subscription, application, and region
selection; approval-gated application creation and recovery; alphabetical provider choices;
Azure CLI Graph calls; provider discovery; allowlist preservation; and stale-plan
checks. They also cover tenant-scope discovery, EU-only recommendations, language and prefix
defaults, confirmation aliases, certificate choices, provider and package selection, and FC1/EP1
deployment. Progress checks use a local CLI stand-in to verify animation, output handling, and
cancellation. GitHub, Azure, Microsoft Graph, certificate, and publication calls are mocked.
Package checks also cover required runtime files, archive paths, private-key exclusion,
checksum failures, and ZIP consumption. CI runs the same eleven suites on Windows and Linux.
They do not certify live deployments, RBAC propagation,
Key Vault issuance, Entra behavior, or provider delivery.

## Step 3 - manually validate and activate policy

First complete [provider authentication and the deployed acceptance checks](../../docs/ONBOARDING.md#complete-provider-authentication).
The customer onboarding owner must arrange an authorized Microsoft EPP caller; this repository's
offline tests and an ordinary Azure CLI token do not supply that caller.

SMS and voice can share the same endpoint URL and application client ID. Setup's handoff lists
both policy targets; validate and activate only the channels you intend to enable, separately.

<a id="firstnet-enablement-script"></a>
### FirstNet: `Enable-FirstNetSms.ps1`

For FirstNet customers, [`setup/Enable-FirstNetSms.ps1`](../Enable-FirstNetSms.ps1) performs this
step. It writes only the fields that Microsoft's Graph beta reference now documents:
`telecomProviderSettings` (`url`, `appId`, `isEvaluationModeEnabled`, `migrationPercentage`) on
both the [SMS](https://learn.microsoft.com/en-us/graph/api/resources/smsauthenticationmethodconfiguration?view=graph-rest-beta)
and [voice](https://learn.microsoft.com/en-us/graph/api/resources/voiceauthenticationmethodconfiguration?view=graph-rest-beta)
method configurations (see [telecomProviderSettings](https://learn.microsoft.com/en-us/graph/api/resources/telecomprovidersettings?view=graph-rest-beta)).
It handles one channel per policy, SMS by default:

| Run | Policy changed |
| --- | --- |
| `./Enable-FirstNetSms.ps1 -Activate [-Evaluate] [-Percent <n>]` | SMS (`.../authenticationMethodConfigurations/Sms`) |
| `./Enable-FirstNetSms.ps1 -Activate -Channel Voice [-Evaluate] [-Percent <n>]` | Voice (`.../authenticationMethodConfigurations/voice`) |
| `./Enable-FirstNetSms.ps1 -Activate -Channel Both ...` | SMS, then voice |
| `./Enable-FirstNetSms.ps1 -Expand [-Channel Voice\|Both] -Percent 100 [-AllUsers]` | Same choice of channel |
| `./Enable-FirstNetSms.ps1 -Rollback <backup.json>` | The channel recorded in that backup |

Before each change the script saves the channel's current policy to its own file
(`sms-policy-backup-*.json` or `voice-policy-backup-*.json`); `-Rollback` restores that policy's
state, include targets and provider settings. Voice uses the same Function, endpoint URL and
application ID as SMS, so it needs no second deployment. The script leaves the voice policy's
`isOfficePhoneAllowed` and `callerIdNumber` unchanged. Microsoft retires its own SMS **and** voice
delivery on 1 February 2027 (1 July 2027 for Global Administrators and external users), so take
each channel you keep to 100% before then
([retirement FAQ](https://learn.microsoft.com/en-us/entra/identity/authentication/concept-sms-voice-retirement-faq)).

**Activation is an assisted, product-specific gate, not an executable public Graph recipe.**
The public beta [SMS](https://learn.microsoft.com/en-us/graph/api/resources/smsauthenticationmethodconfiguration?view=graph-rest-beta)
and [Voice](https://learn.microsoft.com/en-us/graph/api/resources/voiceauthenticationmethodconfiguration?view=graph-rest-beta)
resource definitions do **not** document the EPP extension fields or their placement. The general
method configuration APIs alone do not establish EPP feature availability or an EPP update
contract. Do not invent a PATCH payload, assume a Graph success means activation, or use the
general Delete operation as an EPP rollback.

Before a policy change, the **Authentication Policy Administrator** gets Microsoft's current
approved EPP procedure for the selected tenant and channel. It must identify the tool, API and
version, exact field placement, required consent and roles, readback steps, validation, and rollback.
The public beta update documentation lists delegated `Policy.ReadWrite.AuthenticationMethod` as
the least-privileged permission and Authentication Policy Administrator as the least-privileged
supported delegated role. Those grants allow policy management; they do not prove EPP entitlement.
If the approved EPP procedure or feature is unavailable, leave policy unchanged and record the
blocker.

Once that procedure is available:

1. Open [Graph Explorer](https://developer.microsoft.com/en-us/graph/graph-explorer), sign in, and verify
   that the tenant shown in its header matches `tenantId` in the saved deployment summary.
2. Select **beta** and choose the approved channel endpoint:
   - SMS: `GET /beta/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/sms`
   - Voice: `GET /beta/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/voice`
3. In **Modify permissions**, consent only to `Policy.ReadWrite.AuthenticationMethod` for this
   update, and confirm the operator has the Authentication Policy Administrator role.
4. Run the GET. Graph Explorer displays the response status and body; save the successful `200 OK`
   current-policy response in restricted storage with the tenant ID, UTC time, and change owner.
5. Record all current EPP settings, target groups, state, and unrelated properties. Agree on a
   maintenance window and rollback trigger. Re-run the GET immediately before changing and stop if
   another administrator changed the policy.
6. Change the method to PATCH and keep the same approved endpoint:
   - SMS: `PATCH /beta/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/sms`
   - Voice: `PATCH /beta/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/voice`
7. Build the request only from Microsoft's current approved EPP procedure. Include the documented
   `@odata.type`, use `endpointUrl` and `applicationId` from the saved deployment summary only in
   the **approved field locations**, and send no guessed or undocumented properties. Setup's
   endpoint Service Principal Object ID is not `applicationId`.
8. Preserve the existing state, targeting, and unrelated settings unless the approved change
   explicitly modifies them. When the approved procedure changes targeting, use its dedicated
   pilot group; do not replace existing targeting with all users. Public PATCH documentation says
   omitted documented properties remain unchanged or can be recalculated from other changes;
   review the channel's update documentation before omitting one.
9. Run the PATCH. The documented success response is `204 No Content`, with no response body.
   This confirms that Graph accepted the request, not that EPP is active or delivery works.
10. Immediately switch back to GET and compare the complete response with the saved snapshot.
   Confirm the approved EPP values and every setting that should have been preserved. If the
   extension values cannot be read back exactly as required by the approved procedure, stop and
   restore the prior policy.
11. Follow the approved procedure to test the pilot in evaluation first, then perform a separately
    authorized controlled live delivery. Record provider acceptance and recipient delivery
    separately, without secrets, phone data, or OTPs.
12. If any policy, readback, evaluation, or delivery check fails, execute the agreed rollback
    below. Do not leave a broken channel activated while deleting resources or changing
    authentication to debug it.

Microsoft Graph `/beta` APIs are subject to change and are not supported for production
applications. Recheck the public [SMS update](https://learn.microsoft.com/en-us/graph/api/smsauthenticationmethodconfiguration-update?view=graph-rest-beta),
[Voice update](https://learn.microsoft.com/en-us/graph/api/voiceauthenticationmethodconfiguration-update?view=graph-rest-beta),
and [Graph Explorer](https://learn.microsoft.com/en-us/graph/graph-explorer/graph-explorer-features)
documentation when performing the approved administrator procedure.

<a id="evaluation-and-percentage-rollout"></a>
### Evaluation and percentage rollout

Evaluation and migration percentage answer different questions:

- **Evaluation** checks that Microsoft Entra ID can call the endpoint and that the Function can
  authenticate, validate, and decrypt the request. The request uses evaluation mode and does not
  read provider credentials or send an SMS or voice call.
- **Migration percentage** is a Microsoft Entra rollout control for eligible production
  authentication traffic. It is not a request field, Function setting, provider setting, or
  percentage implemented by this sample.

Microsoft's public [telephony provider FAQ](https://learn.microsoft.com/entra/identity/authentication/phone-providers-faq#migration-and-evaluation)
describes evaluation as validation before production traffic is gradually enabled.
Use the exact percentage control, eligible population, and channel scope defined by Microsoft's
current approved procedure. Public Microsoft Graph SMS and voice resource definitions do not
document the EPP field placement or traffic-selection algorithm. Do not invent a Graph property or
assume a percentage guarantees an exact request count or a stable set of users.

Plan the rollout in these stages:

| Stage | Test | Evidence before continuing |
| --- | --- | --- |
| Evaluation | For each intended channel, have the authorized Microsoft caller send a valid encrypted evaluation request. | `200`, matching nonce, correlated evaluation events, and no provider credential or send events. |
| Controlled live test | Before increasing production traffic, send separately approved live requests to controlled recipients. | Provider acceptance, recipient delivery, correlated telemetry, and no unresolved timeout or duplicate-send concern. |
| Initial percentage | Apply the smallest percentage and population approved for the rollout. Hold the setting long enough to observe representative traffic. | Expected Entra routing, Function success/error/latency, provider acceptance, recipient delivery, support signals, and no rollback trigger. |
| Percentage increase | Change one rollout control at a time. Repeat the same checks at every approved increment. | Results remain within the agreed thresholds for the full observation window. |
| Full rollout | Move to the approved final percentage only after every intended channel and population passes. | Policy readback, sustained telemetry, provider capacity, operational ownership, and tested rollback readiness. |

Evaluation success is necessary but does not validate provider credentials, provider capacity,
production percentage selection, provider acceptance, or recipient delivery. A configured
percentage is also not proof that the expected requests reached this endpoint. Correlate Microsoft
Entra rollout evidence, Function telemetry, provider records, and controlled recipient results.

Before each increase, record the current policy readback, percentage, eligible population,
channels, UTC start time, observation window, owners, success thresholds, and rollback triggers.
If a threshold is breached, stop increasing traffic and restore the reviewed prior policy through
the approved procedure. Changing the percentage does not roll back the Function package,
credentials, or Azure resources.

### Rollback and decommissioning

Policy rollback, package/configuration rollback, and resource deletion are different operations.
Setup does none of them automatically.

1. The policy administrator restores only the reviewed prior EPP configuration through the
   approved procedure (or its documented removal operation if there was no prior EPP endpoint).
   Preserve unrelated settings, read back, and validate the restored authentication route.
   Keep the old endpoint available until traffic has safely moved.
2. For an endpoint release rollback, use the retained package/source version and reviewed
   settings. Do not blindly rerun setup on an active app: it can mutate Entra, reset settings,
   and disable ingress. Coordinate certificate/key continuity; never delete credentials to
   bypass a mismatch. Repeat the authorized evaluation and live checks.
3. Only after policy/traffic and rollback retention are confirmed, have the Azure owner inventory
   and retire the dedicated resource group and any separately created monitors/Front Door resources.
   Confirm exact subscription/resource IDs and dependencies before deletion. Respect vault
   soft-delete/purge protection and approved log/certificate retention; do not purge for a rerun.
4. Have the Entra/provider administrators separately review app registrations, enterprise
   applications, app-role assignments/consents, federated credentials, and provider subscriptions.
   Azure resource deletion does not remove these. The Microsoft phone-provider service principal
   and its Graph grant may be shared with other endpoints: do not delete/revoke shared objects
   without an impact review.
5. Confirm billing and provider subscription status, retain required audit evidence, and close
   alerts only after decommissioning. Stopping a Function or removing policy alone is not teardown.
