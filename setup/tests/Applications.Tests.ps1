#Requires -Version 7.0
param([string] $ModulePath = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$module = Import-Module (Join-Path $ModulePath 'support\Epp.Setup.psm1') -Force -PassThru
$directory = Join-Path ([IO.Path]::GetTempPath()) "epp-application-tests-$([Guid]::NewGuid().ToString('N'))"
try {
    & $module {
        param($ModulePath, $Directory)

        function script:Assert($Condition, [string] $Message) {
            if (-not $Condition) { throw $Message }
        }
        function script:Assert-Throws([scriptblock] $Action, [string] $Pattern) {
            try { $null = & $Action }
            catch {
                Assert ($_.Exception.Message -match $Pattern) "Unexpected failure: $($_.Exception.Message)"
                return
            }
            throw "Expected failure matching '$Pattern'."
        }
        $script:Tenant = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        $script:Subscription = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        $script:Operator = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
        $script:AppId = '11111111-1111-1111-1111-111111111111'
        $script:ObjectId = '22222222-2222-2222-2222-222222222222'
        $script:ExistingAppId = '33333333-3333-3333-3333-333333333333'
        $script:ApplicationName = 'Contoso EPP'
        $script:TokenTenant = '44444444-4444-4444-4444-444444444444'
        $script:OriginalReadJson = ${function:Read-EppJson}
        function script:Read-EppJson {
            param([string] $Path)
            $value = & $script:OriginalReadJson $Path
            if ([IO.Path]::GetFileName($Path) -ceq 'telesign.json') {
                $value.deployment.AccessTokenScopeTenant = $script:TokenTenant
                foreach ($region in @('global', 'eu')) {
                    $value.deployment.routes[$region].appId = '55555555-5555-5555-5555-555555555555'
                    $value.deployment.routes[$region].scope = 'api://55555555-5555-5555-5555-555555555555/.default'
                }
            }
            return $value
        }
        $script:GraphAccess = @{
            EndpointPrincipalId = $script:ObjectId; CallerPrincipalId = $script:Operator; GraphPrincipalId = $script:Tenant
        }
        $script:Answers = [Collections.Generic.Queue[string]]::new()
        $script:Calls = [Collections.Generic.List[string]]::new()
        $script:Prompts = [Collections.Generic.List[string]]::new()
        $script:Messages = [Collections.Generic.List[string]]::new()
        $script:Warnings = [Collections.Generic.List[string]]::new()
        function script:Reset-TestState([string[]] $Answers = @()) {
            $script:Answers.Clear(); $script:Calls.Clear(); $script:Prompts.Clear(); $script:Messages.Clear(); $script:Warnings.Clear()
            foreach ($answer in $Answers) { $script:Answers.Enqueue($answer) }
            $script:Approved = $false; $script:EmptyApplications = $false; $script:ChangedOperator = $false
            $script:CreationFailure = ''; $script:PackageFailure = ''; $script:GroupExists = $false
            $script:Creates = 0; $script:ApplicationReads = 0; $script:RestrictionReads = 0
            $script:GroupChecks = 0; $script:Initializations = 0
            $script:PlanInputs = $null; $script:PlanNames = $null; $script:PlanKeyId = $null
            $script:DeploymentInputs = $null; $script:DeploymentContext = $null
            $script:StopAtInitialization = $true; $script:DeploymentParameters = $null; $script:CertificateDisposed = $false
        }
        function script:Write-Host {
            param([Parameter(ValueFromPipeline)] $Object, $ForegroundColor, [switch] $NoNewline)
            process { $script:Messages.Add([string]$Object) }
        }
        function script:Write-Warning {
            [CmdletBinding()]
            param([string] $Message)
            $script:Warnings.Add($Message)
        }
        function script:Read-Host {
            param($Prompt)
            $script:Prompts.Add($Prompt)
            Assert ($script:Answers.Count -gt 0) "Unexpected prompt: $Prompt"
            $answer = $script:Answers.Dequeue()
            if ($Prompt -like 'Proceed with deployment?*') {
                $script:Calls.Add('approval')
                $script:Approved = $answer.Trim() -in @('Yes', 'Y')
            }
            return $answer
        }
        function script:Get-Command { param($Name, $ErrorAction); return @{ Name = $Name } }
        function script:Connect-EppAzureAccount {
            param($Inputs, [switch] $NonInteractive, [switch] $ForceAuthentication)
            return @{ id = $Inputs.SubscriptionId; tenantId = $Inputs.TenantId }
        }
        function script:Get-EppArmOperatorObjectId { param($Inputs); return $script:Operator }
        function script:Get-EppGraphOperator {
            param($Inputs)
            $id = if ($script:Approved -and $script:ChangedOperator) { $script:Tenant } else { $script:Operator }
            return @{ Id = $id; Account = 'operator@contoso.test' }
        }
        function script:Get-EppTenantRegionScope { param($TenantId); return 'NA' }
        function script:New-TestApplication([string] $ClientId, [string] $DisplayName = $script:ApplicationName) {
            return @{
                id = $script:ObjectId; appId = $ClientId; displayName = $DisplayName
                signInAudience = 'AzureADMyOrg'; api = @{ requestedAccessTokenVersion = $null }
                appRoles = @(); identifierUris = @(); keyCredentials = @(); tokenEncryptionKeyId = $null
            }
        }
        function script:Invoke-EppGraphRequest {
            param($Inputs, $Path, $Query, $Method = 'GET', $Body)
            Assert ($Path -ceq '/v1.0/applications') "Unexpected Graph path: $Path"
            if ($Method -eq 'GET') {
                $script:Calls.Add('list')
                return @{ value = @(if (-not $script:EmptyApplications) { New-TestApplication $script:ExistingAppId }) }
            }
            Assert ($Method -ceq 'POST' -and $script:Approved) 'Application creation requires final deployment approval.'
            Assert ($Body.displayName -ceq $script:PlanInputs.NewApplicationDisplayName -and $Body.signInAudience -ceq 'AzureADMyOrg') 'Create the exact approved application.'
            $script:Calls.Add('create'); $script:Creates++
            if ($script:CreationFailure) { throw $script:CreationFailure }
            return New-TestApplication -ClientId $script:AppId -DisplayName $Body.displayName
        }
        function script:Get-EppApplication {
            param($Inputs, $ClientId, $ObjectId)
            $script:ApplicationReads++
            Assert ($ClientId -ceq $script:ExistingAppId) 'Preflight may only read a selected existing application.'
            return ConvertFrom-EppGraphApplication (New-TestApplication $ClientId)
        }
        function script:Get-EppSignInAudienceRestrictions {
            param($Inputs, $ApplicationObjectId)
            $script:RestrictionReads++
            return $null
        }
        function script:Get-EppServicePrincipal {
            param($Inputs, $AppId, $Description)
            $null = ConvertTo-EppGuid $AppId
            if ($AppId -eq $script:MicrosoftGraphAppId) {
                return @{
                    Id = $script:Tenant
                    AppRoles = @(@{
                        Id = $script:MicrosoftGraphApplicationReadAllRoleId; Value = 'Application.Read.All'
                        IsEnabled = $true; AllowedMemberTypes = @('Application')
                    })
                }
            }
        }
        function script:Get-EppResourceProviders {
            param($SubscriptionId)
            return @([pscustomobject]@{ Namespace = 'Microsoft.Web'; RegistrationState = 'NotRegistered' })
        }
        function script:Assert-EppProviderLocations { param($Providers, $Location); Assert ($Location -ceq 'westus2') 'Check the selected region.' }
        function script:Get-EppLanguage {
            param($AssetDirectory, $Language, $SourceRepository, $PackageReleaseTag, [switch] $NonInteractive)
            return @{
                Id = 'javascript'; DisplayName = 'JavaScript'; BuildStrategy = 'ready'
                Url = 'https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/releases/download/epp-packages-1-1/epp-javascript.zip'
                ReleaseTag = 'epp-packages-1-1'
            }
        }
        function script:Get-EppPackage {
            param($Selection, $Directory)
            if ($script:PackageFailure) { throw $script:PackageFailure }
            return @{ Sha256 = 'a' * 64; SourceSha256 = 'a' * 64; RequiresRemoteBuild = $false }
        }
        function script:Invoke-EppAz {
            [CmdletBinding(PositionalBinding = $false)]
            param([Parameter(Position = 0, ValueFromRemainingArguments)][string[]] $Arguments, [string] $Activity)
            $command = $Arguments -join ' '
            if ($command -ceq 'version --output json') { return '{"azure-cli":"2.60.0"}' }
            if ($command -ceq 'bicep version --output none' -or $command -like 'bicep build *') { return '' }
            if ($command -like 'group exists *') {
                Assert ($command -notmatch '<|>') 'Never query resources using placeholder names.'
                $script:GroupChecks++; $script:Calls.Add('group-check')
                return $script:GroupExists.ToString().ToLowerInvariant()
            }
            if ($command -like 'group show *') {
                return @{ managedBy = 'other'; eppApplicationId = $script:ExistingAppId } | ConvertTo-Json
            }
            if ($command -like 'deployment sub create *') {
                Assert ($script:Approved -and $script:Creates -eq 1 -and $script:GroupChecks -eq 1) 'Deploy Azure only after application creation and real-name ownership checks.'
                $path = $Arguments[[Array]::IndexOf($Arguments, '--parameters') + 1].Substring(1)
                $script:DeploymentParameters = (Read-EppJson $path).parameters
                $names = $script:DeploymentParameters.resourceNames.value
                $expectedNames = Get-EppResourceNames -SubscriptionId $script:Subscription -ApplicationId $script:AppId -ResourcePrefix unit
                Assert ($script:DeploymentParameters.applicationId.value -ceq $script:AppId) 'Pass the actual new client ID to Bicep.'
                foreach ($key in $expectedNames.Keys) {
                    Assert ($names[$key] -ceq $expectedNames[$key]) 'Pass final names, never placeholders, to Bicep.'
                }
                return @{
                    functionAppName = @{ value = $names.functionApp }; storageAccountName = @{ value = $names.storageAccount }
                    keyVaultName = @{ value = $names.keyVault }; resourceGroupName = @{ value = $names.resourceGroup }
                    outboundPrincipalId = @{ value = $script:Operator }
                    endpointUrl = @{ value = "https://$($names.functionApp).azurewebsites.net/api/SendOtp" }
                    identifierUri = @{ value = "api://$script:AppId" }
                } | ConvertTo-Json -Depth 4
            }
            throw "Unexpected Azure call (no network allowed): $command"
        }
        function script:Invoke-WebRequest { throw 'Unexpected download.' }
        function script:Invoke-RestMethod { throw 'Unexpected network call.' }
        $script:OriginalShowPlan = ${function:Show-EppPlan}
        function script:Show-EppPlan {
            param($Inputs, $Names, $ProviderConfiguration, $Context)
            $script:PlanInputs = @{} + $Inputs; $script:PlanNames = @{} + $Names
            $script:PlanKeyId = $Context.CertificatePlan.KeyId
            $script:Calls.Add('plan')
            & $script:OriginalShowPlan -Inputs $Inputs -Names $Names -ProviderConfiguration $ProviderConfiguration -Context $Context
        }
        function script:Initialize-EppGraphAccess {
            param($Inputs, $Context)
            Assert ($script:Approved) 'Configure the application only after approval.'
            $script:Initializations++; $script:Calls.Add('initialize')
            $script:DeploymentInputs = @{} + $Inputs; $script:DeploymentContext = $Context
            Assert ($Context.CertificatePlan.KeyId -ceq $script:PlanKeyId) 'Keep the encryption key ID reviewed before approval.'
            Assert ($Context.CertificatePlan.VaultName -notmatch '<|>' -and
                $Context.CertificatePlan.VaultResourceId -notmatch '<|>') 'Resolve every certificate vault reference before deployment.'
            if ($script:StopAtInitialization) { throw 'application-deployment-boundary' }
            return $script:GraphAccess
        }
        function script:Initialize-EppResourceProviders {
            param($Inputs)
            Assert ($script:Approved -and $Inputs.ApplicationId -ceq $script:AppId) 'Register resource providers only after the new app exists.'
        }
        function script:Get-EppEncryptionCertificate {
            param($Inputs, $VaultName, $CertificateName, $OutputDirectory, $Directory)
            $certificate = [pscustomobject]@{ Thumbprint = 'A' * 40; NotAfter = [DateTime]::UtcNow.AddYears(1) }
            $certificate | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $script:CertificateDisposed = $true }
            return @{
                Certificate = $certificate
                CertificateId = "https://$VaultName.vault.azure.net/certificates/$CertificateName/$('a' * 32)"
                SecretId = "https://$VaultName.vault.azure.net/secrets/$CertificateName/$('b' * 32)"
            }
        }
        function script:Initialize-EppCertificateAccess {
            param($Inputs, $Names, $Plan, $Directory)
            Assert ($Plan.VaultName -ceq $Names.keyVault) 'Use the finalized vault in the approved certificate plan.'
        }
        function script:Set-EppEncryptionSettings {
            param($Inputs, $Names, $SecretId, $KeyId, $Directory)
            Assert ($SecretId.StartsWith("https://$($Names.keyVault).vault.azure.net/secrets/")) 'Bind decryption to the real vault.'
        }
        function script:Assert-EppEncryptionReference { param($Inputs, $Names, $SecretId, $KeyId) }
        function script:Set-EppApplicationEndpoint {
            param($Inputs, $Context, $Outputs, $Certificate, $KeyId, [switch] $ConfigureFederation)
            Assert ($Context.Application.AppId -ceq $script:AppId -and $Inputs.ApplicationId -ceq $script:AppId) 'Register the endpoint against the new app.'
            Assert ($ConfigureFederation -eq ($Inputs.ProviderAuthentication -eq 'oauth')) 'Keep the selected provider authentication behavior.'
        }
        function script:Assert-EppGraphAccess {
            param($Inputs, $Certificate, $KeyId, $IdentifierUri, $CertificatePlan)
            return $script:GraphAccess
        }
        function script:Publish-EppFunction {
            param($Inputs, $Names, $Context, $Outputs, $SiteId, $Package, $Directory)
            Assert ($SiteId -ceq "/subscriptions/$script:Subscription/resourceGroups/$($Names.resourceGroup)/providers/Microsoft.Web/sites/$($Names.functionApp)") 'Publish to the finalized Function App.'
            return 'b' * 64
        }
        $setup = @{
            TenantId = $script:Tenant; SubscriptionId = $script:Subscription
            Location = 'westus2'; ServicePlan = 'FC1'; ResourcePrefix = 'unit'
            AssetDirectory = $ModulePath; OutputDirectory = $Directory
            SourceBaseUri = "https://raw.githubusercontent.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/$('a' * 40)/setup"
        }

        $preview = Get-EppResourceNames -SubscriptionId $script:Subscription -ResourcePrefix unit -PendingApplication
        Assert (@($preview.Values | Where-Object { -not $_.Contains('<app-id-hash>') }).Count -eq 0) 'Preview all resource names with an explicit placeholder, not a fabricated client ID.'
        Assert-Throws { Get-EppResourceNames -SubscriptionId $script:Subscription -ResourcePrefix unit } 'nonempty GUID'
        Assert-Throws {
            Get-EppResourceNames -SubscriptionId $script:Subscription -ApplicationId $script:AppId -ResourcePrefix unit -PendingApplication
        } 'Pending application names'

        foreach ($answer in @('No', 'n', '')) {
            Reset-TestState @('create', $script:ApplicationName, 'soprano', $answer)
            Assert ($null -eq (Invoke-EppSetup @setup -PassThru)) 'Cancellation must not return a successful deployment.'
            Assert ($script:Creates -eq 0 -and $script:Initializations -eq 0 -and $script:GroupChecks -eq 0) 'Cancel without creating an app or looking up placeholder resource names.'
            Assert ($script:ApplicationReads -eq 0 -and $script:RestrictionReads -eq 0) 'A planned new application has no existing Graph configuration to read.'
            Assert ($script:PlanInputs.NewApplicationDisplayName -ceq $script:ApplicationName -and -not $script:PlanInputs.ApplicationId) 'Carry the requested name, not a fake client ID, through preflight.'
            Assert ($script:PlanNames.keyVault -ceq 'unit-epp-kv-<app-id-hash>') 'Disclose pending names in the approval plan.'
            Assert ($script:Messages -contains 'Provider names: FirstNet, Infobip, Soprano, Telesign') 'Offer all guided providers alphabetically for a new app.'
            Assert (($script:Messages -join "`n").Contains("Create '$script:ApplicationName' after approval")) 'Show the exact application creation action in the final plan.'
            Assert ($script:Answers.Count -eq 0 -and -not (Test-Path -LiteralPath $Directory)) 'Do not write deployment output before approval.'
        }
        Reset-TestState @('0')
        Assert ($null -eq (Invoke-EppSetup @setup)) 'Allow cancellation in the application picker.'
        Assert ($null -eq $script:PlanInputs -and $script:Creates -eq 0) 'Early cancellation must stop before plan approval or creation.'
        foreach ($blank in @('', '  ')) {
            Reset-TestState @($blank, $blank, '', '  ', 'soprano', 'No')
            $null = Invoke-EppSetup @setup
            Assert ($script:Prompts -contains 'Application number or name [5]') 'Enter at the application picker must choose the displayed create-new default.'
            Assert ($script:PlanInputs.NewApplicationDisplayName -ceq 'EPP Application') 'Blank application names must accept the displayed default instead of canceling.'
            Assert ($script:Prompts -contains 'New application display name [EPP Application]') 'Display the application-name default without a cancellation hint.'
            Assert (@($script:Prompts | Where-Object { $_ -ceq 'Provider name' }).Count -eq 3 -and
                $script:Warnings.Count -eq 2) 'Blank provider input must prompt again until a provider is selected.'
            Assert ($script:Answers.Count -eq 0 -and $script:Creates -eq 0) 'Continue to the final approval without creating an app early.'
        }
        Reset-TestState @('create', ('x' * 257), "bad`nname", $script:ApplicationName, '1', 'TELESIGN', 'No')
        $null = Invoke-EppSetup @setup
        Assert ($script:Warnings.Count -eq 3 -and $script:Answers.Count -eq 0) 'Reprompt invalid names and provider numbers without selecting defaults.'
        Reset-TestState @('create', $script:ApplicationName, 'soprano', 'No')
        $script:EmptyApplications = $true
        $null = Invoke-EppSetup @setup
        Assert ($script:Creates -eq 0 -and $null -ne $script:PlanInputs) 'Offer creation even when the tenant has no matching applications.'
        Reset-TestState @('create', $script:ApplicationName, 'soprano')
        $script:PackageFailure = 'package-preflight-failed'
        Assert-Throws { Invoke-EppSetup @setup } '^package-preflight-failed$'
        Assert ($script:Creates -eq 0 -and -not (Test-Path -LiteralPath $Directory)) 'Preflight failure must not leave a new application behind.'
        Reset-TestState @('create', $script:ApplicationName, 'soprano')
        Assert-Throws { Invoke-EppSetup @setup -CertificateAction Reuse } 'No encryption certificate is registered'
        Assert ($script:Creates -eq 0) 'Reject incompatible certificate choices before creating an app.'

        foreach ($explicitApproval in @($false, $true)) {
            Reset-TestState @('create', $script:ApplicationName, 'soprano')
            if ($explicitApproval) { $script:Approved = $true }
            else { $script:Answers.Enqueue('y') }
            $setup.OutputDirectory = Join-Path $Directory "approved-$explicitApproval"
            Assert-Throws { Invoke-EppSetup @setup -ApproveDeployment:$explicitApproval } '^application-deployment-boundary$'
            Assert ($script:Creates -eq 1 -and $script:Initializations -eq 1 -and $script:GroupChecks -eq 1) 'Create once, resolve resource ownership, then configure the endpoint.'
            Assert ($script:Calls.IndexOf('create') -gt $script:Calls.IndexOf('plan') -and
                $script:Calls.IndexOf('group-check') -gt $script:Calls.IndexOf('create') -and
                $script:Calls.IndexOf('initialize') -gt $script:Calls.IndexOf('group-check')) 'Keep creation and resolved-name checks inside the approved deployment phase.'
            if (-not $explicitApproval) {
                Assert ($script:Calls.IndexOf('create') -gt $script:Calls.IndexOf('approval')) 'Wait for the final affirmative response before creation.'
            }
            Assert ($script:DeploymentInputs.ApplicationId -ceq $script:AppId -and
                $script:DeploymentContext.Application.Id -ceq $script:ObjectId) 'Use the returned client and object IDs, never an existing app with the same display name.'
            $recordPath = Join-Path $setup.OutputDirectory "application-$script:AppId.json"
            $record = Read-EppJson $recordPath
            $expectedNames = Get-EppResourceNames -SubscriptionId $script:Subscription -ApplicationId $script:AppId -ResourcePrefix unit
            Assert ($record.applicationId -ceq $script:AppId -and $record.applicationObjectId -ceq $script:ObjectId -and
                $record.provider -ceq 'soprano' -and $record.displayName -ceq $script:ApplicationName) 'Persist creation details for recovery before later deployment steps can fail.'
            foreach ($key in $expectedNames.Keys) {
                Assert ($record.resources[$key] -ceq $expectedNames[$key]) 'New registrations and later client-ID reruns must use identical resource names.'
            }
            Assert ($script:DeploymentContext.CertificatePlan.VaultName -ceq $expectedNames.keyVault) 'Bind certificate creation to the final vault name.'
            Assert (($script:Warnings -join "`n").Contains("-ApplicationId '$script:AppId'")) 'Failures must identify the app to reuse rather than encourage duplicate creation.'
            Assert ($script:Answers.Count -eq 0) 'Do not introduce a second deployment approval.'
        }

        Reset-TestState @('Yes')
        $setup.OutputDirectory = Join-Path $Directory 'existing'
        Assert-Throws {
            Invoke-EppSetup @setup -ApplicationId $script:ExistingAppId -Provider telesign
        } '^application-deployment-boundary$'
        Assert ($script:Creates -eq 0 -and $script:GroupChecks -eq 1 -and
            $script:DeploymentInputs.ApplicationId -ceq $script:ExistingAppId) 'Preserve supplied-client-ID setup and its preapproval resource checks.'

        Reset-TestState @('create', $script:ApplicationName, 'Yes')
        $setup.OutputDirectory = Join-Path $Directory 'explicit-provider'
        Assert-Throws { Invoke-EppSetup @setup -Provider TELESIGN } '^application-deployment-boundary$'
        $record = Read-EppJson (Join-Path $setup.OutputDirectory "application-$script:AppId.json")
        Assert ($record.provider -ceq 'telesign' -and $script:Answers.Count -eq 0) 'Respect an explicit provider without another provider prompt.'

        Reset-TestState @('create', $script:ApplicationName, 'soprano', 'Yes')
        $setup.OutputDirectory = Join-Path $Directory 'changed-user'
        $script:ChangedOperator = $true
        Assert-Throws { Invoke-EppSetup @setup } 'user changed after the plan'
        Assert ($script:Creates -eq 0 -and -not (Test-Path -LiteralPath $setup.OutputDirectory)) 'Revalidate the operator before creating the application.'

        Reset-TestState @('create', $script:ApplicationName, 'soprano', 'Yes')
        $setup.OutputDirectory = Join-Path $Directory 'creation-failed'
        $script:CreationFailure = 'Authorization_RequestDenied: cannot create application'
        Assert-Throws { Invoke-EppSetup @setup } 'Authorization_RequestDenied'
        Assert ($script:Creates -eq 1 -and $script:GroupChecks -eq 0 -and $script:Initializations -eq 0) 'Do not retry an uncertain create or continue deployment after failure.'
        Assert (-not (Test-Path -LiteralPath (Join-Path $setup.OutputDirectory "application-$script:AppId.json"))) 'Do not write success-shaped creation output after a failed request.'

        Reset-TestState @('create', $script:ApplicationName, 'soprano', 'Yes')
        $setup.OutputDirectory = Join-Path $Directory 'resource-collision'
        $script:GroupExists = $true
        Assert-Throws { Invoke-EppSetup @setup } 'not owned by this EPP application'
        Assert ($script:Creates -eq 1 -and $script:Initializations -eq 0) 'Check final resource ownership before mutating app configuration or deploying Azure resources.'
        Assert (Test-Path -LiteralPath (Join-Path $setup.OutputDirectory "application-$script:AppId.json")) 'Keep the new client ID available if resolved resource names conflict.'

        foreach ($provider in @('soprano', 'telesign', 'infobip')) {
            $nameAnswer = if ($provider -eq 'soprano') { '' } else { $script:ApplicationName }
            $expectedName = if ($provider -eq 'soprano') { 'EPP Application' } else { $script:ApplicationName }
            $applicationAnswer = if ($provider -eq 'soprano') { '' } else { 'create' }
            Reset-TestState @($applicationAnswer, $nameAnswer, $provider, 'Yes')
            $setup.OutputDirectory = Join-Path $Directory "complete-$provider"
            $script:StopAtInitialization = $false
            $result = Invoke-EppSetup @setup -PassThru
            Assert ($result.applicationId -ceq $script:AppId -and $result.provider -ceq $provider -and
                $result.policyChanged -eq $false -and $script:Creates -eq 1) 'Complete the existing deployment flow with the new app and chosen provider.'
            $summaries = @(Get-ChildItem -LiteralPath $setup.OutputDirectory -Filter 'deployment-*.json')
            Assert ($summaries.Count -eq 1) 'Persist a separate deployment success summary.'
            $summary = Read-EppJson $summaries[0].FullName
            $record = Read-EppJson (Join-Path $setup.OutputDirectory "application-$script:AppId.json")
            Assert ($record.displayName -ceq $expectedName) 'Create and persist either the accepted default name or the supplied custom name.'
            $expectedAuth = 'oauth'
            Assert ($summary.providerAuthentication -ceq $expectedAuth -and
                $script:DeploymentParameters.providerSettings.value.EPP_PROVIDER_AUTH_MODE -ceq $expectedAuth) 'Carry the selected authentication mode through deployment and the success summary.'
            if ($provider -eq 'infobip') {
                Assert (($script:Messages -join "`n").Contains('Infobip OAuth: add a federated credential')) 'The approval plan must identify Infobip federation rather than another provider.'
            }
            if ($provider -eq 'telesign') {
                Assert ($summary.accessTokenScopeTenant -ceq $script:TokenTenant -and
                    $summary.providerTenantId -cne $script:TokenTenant -and
                    $script:DeploymentParameters.providerSettings.value.EPP_PROVIDER_TENANT_ID -ceq $script:TokenTenant) 'New applications must retain the Security Store tenant and use the separate token authority.'
                Assert ($script:PlanInputs.ProviderAllowedTenantIds -contains $script:TokenTenant -and
                    $summary.allowedProviderTenantIds -contains $summary.providerTenantId -and
                    $summary.allowedProviderTenantIds -contains $script:TokenTenant) 'Review and persist both tenant identities for newly created applications.'
            }
            Assert ($summary.applicationId -ceq $record.applicationId -and $summary.provider -ceq $provider -and
                $summary.packageSha256 -ceq ('b' * 64)) 'Record the deployed client ID, provider, and final package hash.'
            foreach ($key in $record.resources.Keys) {
                Assert ($summary.resources[$key] -ceq $record.resources[$key] -and
                    $result.resources[$key] -ceq $script:DeploymentParameters.resourceNames.value[$key]) 'Keep registration, deployment, return value, and summary resource names consistent.'
            }
            Assert ($summary.encryptionKeyId -ceq $script:PlanKeyId -and
                $summary.certificateSecretId.StartsWith("https://$($record.resources.keyVault).vault.azure.net/secrets/")) 'Persist the reviewed key ID and finalized certificate location.'
            Assert ($script:CertificateDisposed -and $script:Warnings.Count -eq 0) 'Complete cleanup without a failure warning.'
        }
    } $ModulePath $directory
    Write-Host 'New application planning, alphabetized providers, approval, creation, deterministic names, recovery, and existing-app checks passed.'
}
finally {
    Remove-Module -ModuleInfo $module -Force
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}
