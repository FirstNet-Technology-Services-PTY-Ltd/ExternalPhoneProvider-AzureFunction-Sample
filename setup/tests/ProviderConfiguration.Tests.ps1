#Requires -Version 7.0
param([string] $ModulePath = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$module = Import-Module (Join-Path $ModulePath 'support\Epp.Setup.psm1') -Force -PassThru
try {
    & $module {
        param($ModulePath)

        $script:AssetDirectory = $ModulePath
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
        $script:AppId = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
        $script:ObjectId = 'dddddddd-dddd-dddd-dddd-dddddddddddd'
        $telesign = Get-EppProviderDefinition -AssetDirectory $script:AssetDirectory -Provider Telesign
        $soprano = Get-EppProviderDefinition -AssetDirectory $script:AssetDirectory -Provider Soprano
        $infobip = Get-EppProviderDefinition -AssetDirectory $script:AssetDirectory -Provider Infobip
        $unknownTenant = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'
        $unconfiguredRestrictions = @(
            $null
            @{ kind = 'unrestricted' }
            @{ '@odata.type' = '#microsoft.graph.unrestrictedAudience'; kind = 'unrestricted' }
            @{ '@odata.type' = '#microsoft.graph.unrestrictedAudience' }
        )
        $script:Answers = [Collections.Generic.Queue[string]]::new()
        $script:Prompts = [Collections.Generic.List[string]]::new()
        $script:Messages = [Collections.Generic.List[string]]::new()
        $script:Warnings = [Collections.Generic.List[string]]::new()
        $script:Patches = [Collections.Generic.List[object]]::new()
        function script:New-TestInputs {
            @{
                TenantId = $script:Tenant; SubscriptionId = $script:Subscription; ApplicationId = $script:AppId
                ProviderTenantId = $telesign.TenantId; ServicePlan = 'FC1'
            }
        }
        function script:New-TestRestriction([string[]] $Ids) {
            @{ kind = 'allowedTenants'; isHomeTenantAllowed = $true; allowedTenantIds = @($Ids) }
        }
        function script:Reset-TestState([string[]] $Answers = @()) {
            $script:Answers.Clear(); $script:Prompts.Clear(); $script:Messages.Clear(); $script:Warnings.Clear(); $script:Patches.Clear()
            foreach ($answer in $Answers) { $script:Answers.Enqueue($answer) }
            $script:Restriction = $null
            $script:ApplicationReads = 0; $script:RestrictionReads = 0; $script:EnsureCalls = 0
            $script:ApplicationReadErrors = [Collections.Generic.Queue[string]]::new()
            $script:Sleeps = 0
            $script:Application = [pscustomobject]@{
                Id = $script:ObjectId; AppId = $script:AppId; SignInAudience = 'AzureADMyOrg'
                TokenEncryptionKeyId = $null; KeyCredentials = @(); IdentifierUris = @()
                Api = @{ RequestedAccessTokenVersion = 2 }
                AppRoles = @(@{
                    Id = $script:EppInvokeAppRoleId; Value = 'Epp.Invoke'; IsEnabled = $true
                    AllowedMemberTypes = @('Application')
                })
            }
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
            return $script:Answers.Dequeue()
        }
        function script:Get-EppApplication {
            param($Inputs, $ClientId, $ObjectId)
            $script:ApplicationReads++
            if ($script:ApplicationReadErrors.Count) { throw $script:ApplicationReadErrors.Dequeue() }
            return $script:Application
        }
        function script:Get-EppSignInAudienceRestrictions {
            param($Inputs, $ApplicationObjectId)
            $script:RestrictionReads++
            return $script:Restriction
        }
        function script:Invoke-EppGraphRequest {
            param($Inputs, $Method, $Path, $Body, $Query)
            Assert ($Method -ceq 'PATCH' -and $Path -ceq "/beta/applications/$script:ObjectId") 'Provider configuration must be one scoped beta application PATCH.'
            $script:Patches.Add($Body)
        }
        function script:Ensure-EppServicePrincipal {
            param($Inputs, $AppId, $Description)
            $script:EnsureCalls++
            throw 'provider-configuration-finished'
        }
        function script:Invoke-EppAz { throw 'Unexpected Azure operation.' }
        function script:Start-Sleep {
            param($Seconds)
            Assert ($Seconds -eq 5) 'Use a bounded app-registration propagation delay.'
            $script:Sleeps++
        }

        foreach ($restriction in $unconfiguredRestrictions) {
            Assert ($null -eq (Get-EppProviderRestrictionState -Restriction $restriction)) 'Null and unrestricted audiences must normalize to the same unconfigured state.'
            Assert (-not (Test-EppProviderTenantRestriction -Restriction $restriction -ProviderTenantId $telesign.TenantId)) 'An unrestricted audience must never satisfy provider-restriction readback.'
            foreach ($audience in @('AzureADMyOrg', 'AzureADMultipleOrgs')) {
                Reset-TestState @('Telesign')
                $script:Restriction = $restriction
                $script:Application.SignInAudience = $audience
                $selected = Resolve-EppApplicationProvider -Inputs (New-TestInputs) -AssetDirectory $script:AssetDirectory
                Assert ($selected -ceq 'telesign' -and $script:Prompts[0] -ceq 'Provider name') 'No configuration must prompt for a provider name.'
                Assert (($script:Messages -join "`n").Contains('configuration is included in the deployment approval')) 'Do not configure an existing app before deployment approval.'
                Assert ($script:Messages -contains 'Provider names: FirstNet, Infobip, Soprano, Telesign') 'List provider names alphabetically, independently of catalog order.'
                Assert ($script:Patches.Count -eq 0) 'Provider resolution is read-only.'
            }
        }
        Reset-TestState @('1', 'soprano')
        Assert ((Resolve-EppApplicationProvider -Inputs (New-TestInputs) -AssetDirectory $script:AssetDirectory) -ceq 'soprano') 'Reject a provider number, then accept a name.'
        Assert ($script:Warnings.Count -eq 1 -and -not (($script:Messages -join "`n") -match '\[\d+\]')) 'Do not number or rank provider choices.'
        Reset-TestState @('', '  ', 'telesign')
        Assert ((Resolve-EppApplicationProvider -Inputs (New-TestInputs) -AssetDirectory $script:AssetDirectory) -ceq 'telesign') 'Blank provider input must prompt again, not cancel or select a default.'
        Assert ($script:Warnings.Count -eq 2 -and $script:Prompts.Count -eq 3 -and $script:Patches.Count -eq 0) 'Require a provider choice without changing application configuration.'

        foreach ($answer in @('Yes', 'y', ' YES ', 'No', 'n', '')) {
            Reset-TestState @($answer)
            $script:Application.SignInAudience = 'AzureADMultipleOrgs'
            $script:Restriction = New-TestRestriction @($telesign.TenantId)
            $selected = Resolve-EppApplicationProvider -Inputs (New-TestInputs) -AssetDirectory $script:AssetDirectory
            if ($answer.Trim() -in @('Yes', 'Y')) { Assert ($selected -ceq 'telesign') 'Confirm the single configured provider.' }
            else { Assert ($null -eq $selected) 'Do not silently accept the single configured provider.' }
            Assert ($script:Prompts[0] -match 'configured for Telesign.*Yes or Y.*No or N') 'Show the configured provider and accepted responses in the confirmation.'
        }
        Reset-TestState @('', 'Soprano')
        $script:Application.SignInAudience = 'AzureADMultipleOrgs'
        $script:Restriction = New-TestRestriction @($telesign.TenantId, $soprano.TenantId)
        $selected = Resolve-EppApplicationProvider -Inputs (New-TestInputs) -AssetDirectory $script:AssetDirectory
        Assert ($selected -ceq 'soprano' -and $script:Prompts.Count -eq 2 -and $script:Warnings.Count -eq 1 -and
            $script:Prompts[0] -ceq 'Provider name') 'Require a name when choosing among multiple configured providers.'
        Assert (-not (($script:Messages -join "`n") -match '\[\d+\]')) 'Configured providers must not be numbered.'
        Reset-TestState @('Yes')
        $script:Application.SignInAudience = 'AzureADMultipleOrgs'
        $script:Restriction = New-TestRestriction @($infobip.TenantId)
        Assert ((Resolve-EppApplicationProvider -Inputs (New-TestInputs) -AssetDirectory $script:AssetDirectory) -ceq 'infobip') 'Recognize an existing Infobip tenant restriction and confirm its provider by name.'
        Assert ($script:Prompts[0] -match 'configured for Infobip' -and $script:Patches.Count -eq 0) 'Infobip provider discovery must remain read-only.'
        Reset-TestState
        $selected = Resolve-EppApplicationProvider -Inputs (New-TestInputs) -AssetDirectory $script:AssetDirectory -Provider ' TELESIGN ' -NonInteractive
        Assert ($selected -ceq 'telesign' -and $script:ApplicationReads -eq 0 -and $script:Prompts.Count -eq 0) 'An explicit provider is an explicit choice; preflight validates the actual app configuration later.'
        Assert-Throws { Resolve-EppApplicationProvider -Inputs (New-TestInputs) -AssetDirectory $script:AssetDirectory -NonInteractive } '\-Provider is required'
        Assert-Throws { Resolve-EppApplicationProvider -Inputs (New-TestInputs) -AssetDirectory $script:AssetDirectory -Provider '2' } 'provider name, not a selection number'

        $both = New-TestRestriction @($soprano.TenantId, $telesign.TenantId)
        Assert (Test-EppProviderTenantRestriction -Restriction $both -ProviderTenantId $telesign.TenantId) 'A configured provider can coexist with other allowed providers.'
        Assert (Test-EppProviderTenantRestriction -Restriction $both -ProviderTenantId $telesign.TenantId -ExpectedAllowedTenantIds @($telesign.TenantId, $soprano.TenantId)) 'Compare allowed tenants independently of ordering.'
        Assert (-not (Test-EppProviderTenantRestriction -Restriction $both -ProviderTenantId $telesign.TenantId -ExpectedAllowedTenantIds @($telesign.TenantId))) 'Readback must match the complete approved allowlist.'
        $typedAllowlist = @{
            '@odata.type' = '#microsoft.graph.allowedTenantsAudience'
            isHomeTenantAllowed = $true; allowedTenantIds = @($telesign.TenantId)
        }
        Assert (Test-EppProviderTenantRestriction -Restriction $typedAllowlist -ProviderTenantId $telesign.TenantId) 'Recognize the documented type when the optional kind is omitted.'
        Assert-Throws { Get-EppProviderRestrictionState (New-TestRestriction @($telesign.TenantId, $telesign.TenantId)) } 'duplicate allowed'
        foreach ($invalid in @(
            'unrestricted'
            @{}
            @{ kind = 'unknownFutureValue' }
            @{ kind = 'Unrestricted' }
            @{ kind = @('unrestricted') }
            @{ '@odata.type' = @('#microsoft.graph.unrestrictedAudience') }
            @{ '@odata.type' = '#microsoft.graph.unknownAudience' }
            @{ '@odata.type' = '#microsoft.graph.unknownAudience'; kind = 'unrestricted' }
            @{ '@odata.type' = '#microsoft.graph.allowedTenantsAudience'; kind = 'unrestricted' }
            @{ '@odata.type' = '#microsoft.graph.unrestrictedAudience'; kind = 'allowedTenants'; isHomeTenantAllowed = $true; allowedTenantIds = @($telesign.TenantId) }
            @{ kind = 'unrestricted'; allowedTenantIds = @($telesign.TenantId) }
            @{ kind = 'unrestricted'; isHomeTenantAllowed = $false }
            @{ kind = 'unexpected'; isHomeTenantAllowed = $true; allowedTenantIds = @() }
            @{ kind = 'allowedTenants'; isHomeTenantAllowed = 'true'; allowedTenantIds = @($telesign.TenantId) }
            @{ kind = 'allowedTenants'; isHomeTenantAllowed = $true; allowedTenantIds = $telesign.TenantId }
        )) {
            Assert-Throws { Get-EppProviderRestrictionState -Restriction $invalid } 'unsupported provider-tenant restriction'
        }
        Assert-Throws { Get-EppProviderRestrictionState (New-TestRestriction @('invalid')) } 'nonempty GUID'

        function script:Get-Command { param($Name, $ErrorAction); return @{ Name = $Name } }
        function script:Connect-EppAzureAccount { param($Inputs, [switch] $NonInteractive, [switch] $ForceAuthentication); return @{} }
        function script:Get-EppArmOperatorObjectId { param($Inputs); return $script:Tenant }
        function script:Connect-EppGraphAccount {
            param($Inputs, [switch] $NonInteractive, [switch] $ForceAuthentication)
            return @{ Context = @{}; Operator = @{ Id = $script:Tenant; Account = 'operator@contoso.test' } }
        }
        function script:Get-EppServicePrincipal {
            param($Inputs, $AppId, $Description)
            if ($AppId -eq $script:MicrosoftGraphAppId) {
                return @{
                    Id = $script:Tenant
                    AppRoles = @(@{ Id = $script:MicrosoftGraphApplicationReadAllRoleId; Value = 'Application.Read.All'; IsEnabled = $true; AllowedMemberTypes = @('Application') })
                }
            }
        }
        function script:Invoke-EppAz {
            param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments)
            if (($Arguments -join ' ') -eq 'version --output json') { return '{"azure-cli":"2.60.0"}' }
            if (($Arguments -join ' ') -eq 'bicep version --output none') { return '' }
            if ($Arguments[0] -eq 'group') { throw 'provider-preflight-boundary' }
            throw 'Unexpected Azure operation.'
        }
        foreach ($existing in @(@(), @($soprano.TenantId), @($soprano.TenantId, $unknownTenant))) {
            Reset-TestState
            if ($existing.Count) { $script:Restriction = New-TestRestriction $existing }
            $inputs = New-TestInputs
            Assert-Throws { Connect-EppContext -Inputs $inputs -Names @{ resourceGroup = 'unit' } -NonInteractive } '^provider-preflight-boundary$'
            $expected = @((@($existing) + @($telesign.TenantId)) | Sort-Object -Unique)
            Assert (($inputs.ProviderAllowedTenantIds -join ',') -ceq ($expected -join ',')) 'Preflight must preserve existing known and unknown allowed tenants while adding the selected provider.'
        }
        foreach ($restriction in $unconfiguredRestrictions) {
            Reset-TestState
            $script:Restriction = $restriction
            $inputs = New-TestInputs
            Assert-Throws { Connect-EppContext -Inputs $inputs -Names @{ resourceGroup = 'unit' } -NonInteractive } '^provider-preflight-boundary$'
            Assert ($inputs.ProviderAllowedTenantIds.Count -eq 1 -and $inputs.ProviderAllowedTenantIds[0] -ceq $telesign.TenantId) 'Preflight must plan the selected provider allowlist for an unrestricted application.'
            Assert ($script:Patches.Count -eq 0) 'Preflight must not change an unrestricted application.'
            $context = @{
                Application = @{ Id = $script:ObjectId; SignInAudience = $script:Application.SignInAudience }
                CertificatePlan = @{ Snapshot = Get-EppKeyCredentialSnapshot @() }
                ProviderRestrictionState = $null
            }
            foreach ($newApplication in @($false, $true)) {
                $script:Patches.Clear()
                if ($newApplication) { $inputs.NewApplicationDisplayName = 'New EPP application' }
                Assert-Throws { Initialize-EppGraphAccess -Inputs $inputs -Context $context } '^provider-configuration-finished$'
                Assert ($script:Patches.Count -eq 1) 'Configure both existing and newly created unrestricted applications after approval.'
                $patch = $script:Patches[0]
                Assert ($patch.signInAudience -ceq 'AzureADMultipleOrgs' -and
                    $patch.signInAudienceRestrictions.kind -ceq 'allowedTenants' -and
                    $patch.signInAudienceRestrictions.isHomeTenantAllowed -eq $true -and
                    $patch.signInAudienceRestrictions.allowedTenantIds.Count -eq 1 -and
                    $patch.signInAudienceRestrictions.allowedTenantIds[0] -ceq $telesign.TenantId) 'Replace the unrestricted audience with only the approved provider tenant plus the home tenant.'
            }
            $script:Patches.Clear(); $script:EnsureCalls = 0
            $script:Restriction = New-TestRestriction @($unknownTenant)
            Assert-Throws { Initialize-EppGraphAccess -Inputs $inputs -Context $context } 'provider configuration changed'
            Assert ($script:Patches.Count -eq 0 -and $script:EnsureCalls -eq 0) 'Do not overwrite an allowlist added after approval, including on a newly created app.'
        }
        foreach ($tokenTenant in @($telesign.TenantId, 'ffffffff-ffff-ffff-ffff-ffffffffffff')) {
            Reset-TestState
            $script:Restriction = New-TestRestriction @($soprano.TenantId, $unknownTenant)
            $inputs = New-TestInputs
            $inputs.ProviderAuthentication = 'oauth'
            $inputs.AccessTokenScopeTenant = $tokenTenant
            Assert-Throws { Connect-EppContext -Inputs $inputs -Names @{ resourceGroup = 'unit' } -NonInteractive } '^provider-preflight-boundary$'
            $expected = @($soprano.TenantId, $unknownTenant, $telesign.TenantId, $tokenTenant) | Sort-Object -Unique
            Assert (($inputs.ProviderAllowedTenantIds -join ',') -ceq ($expected -join ',')) 'OAuth must allow both the Security Store and token tenants, deduplicate them, and preserve existing allowed tenants.'
            Assert ($inputs.ProviderTenantId -ceq $telesign.TenantId) 'The token tenant must not replace the provider identity used for Security Store discovery.'
        }
        foreach ($alreadyConfigured in @($false, $true)) {
            Reset-TestState
            $script:Application.SignInAudience = 'AzureADMultipleOrgs'
            $script:Restriction = if ($alreadyConfigured) { New-TestRestriction @($soprano.TenantId, $telesign.TenantId) } else { New-TestRestriction @($soprano.TenantId) }
            $inputs = New-TestInputs
            $inputs.ProviderAllowedTenantIds = @($soprano.TenantId, $telesign.TenantId)
            $context = @{
                Application = @{ Id = $script:ObjectId; SignInAudience = $script:Application.SignInAudience }
                CertificatePlan = @{ Snapshot = Get-EppKeyCredentialSnapshot @() }
                ProviderRestrictionState = Get-EppProviderRestrictionState $script:Restriction
            }
            Assert-Throws { Initialize-EppGraphAccess -Inputs $inputs -Context $context } '^provider-configuration-finished$'
            if ($alreadyConfigured) { Assert ($script:Patches.Count -eq 0) 'Do not collapse or rewrite an already matching multi-provider allowlist.' }
            else {
                Assert ($script:Patches.Count -eq 1) 'Add a missing provider with one approved restriction update.'
                $allowed = @($script:Patches[0].signInAudienceRestrictions.allowedTenantIds | Sort-Object)
                Assert (($allowed -join ',') -ceq (@($inputs.ProviderAllowedTenantIds | Sort-Object) -join ',')) 'Keep the existing provider when adding another.'
            }
            $script:Patches.Clear(); $script:EnsureCalls = 0
            foreach ($changedRestriction in (@((New-TestRestriction @($soprano.TenantId, $unknownTenant))) + $unconfiguredRestrictions)) {
                $script:Restriction = $changedRestriction
                Assert-Throws { Initialize-EppGraphAccess -Inputs $inputs -Context $context } 'provider configuration changed'
                Assert ($script:Patches.Count -eq 0 -and $script:EnsureCalls -eq 0) 'Reject a changed or removed allowlist before any application or service-principal mutation.'
            }
            $script:Application.SignInAudience = 'AzureADMyOrg'
            Assert-Throws { Initialize-EppGraphAccess -Inputs $inputs -Context $context } 'changed after preflight'
            Assert ($script:Patches.Count -eq 0) 'Do not re-expose an app whose sign-in audience changed after review.'
        }

        foreach ($case in @(
            @{ New = $true; Error = 'Request_ResourceNotFound'; Failures = 2; Reads = 3; Sleeps = 2; Expected = '^provider-configuration-finished$' },
            @{ New = $true; Error = 'Request_ResourceNotFound'; Failures = 12; Reads = 12; Sleeps = 11; Expected = 'Request_ResourceNotFound' },
            @{ New = $true; Error = 'Authorization_RequestDenied'; Failures = 1; Reads = 1; Sleeps = 0; Expected = 'Authorization_RequestDenied' },
            @{ New = $false; Error = 'Request_ResourceNotFound'; Failures = 1; Reads = 1; Sleeps = 0; Expected = 'Request_ResourceNotFound' }
        )) {
            Reset-TestState
            $inputs = New-TestInputs
            $inputs.ProviderAllowedTenantIds = @($telesign.TenantId)
            if ($case.New) { $inputs.NewApplicationDisplayName = 'New EPP application' }
            for ($index = 0; $index -lt $case.Failures; $index++) { $script:ApplicationReadErrors.Enqueue($case.Error) }
            $context = @{
                Application = @{ Id = $script:ObjectId; SignInAudience = $script:Application.SignInAudience }
                CertificatePlan = @{ Snapshot = Get-EppKeyCredentialSnapshot @() }
                ProviderRestrictionState = $null
            }
            Assert-Throws { Initialize-EppGraphAccess -Inputs $inputs -Context $context } $case.Expected
            Assert ($script:ApplicationReads -eq $case.Reads -and $script:Sleeps -eq $case.Sleeps) 'Retry only bounded new-application read propagation, not permission errors or existing-app failures.'
            if ($case.Expected -ne '^provider-configuration-finished$') {
                Assert ($script:Patches.Count -eq 0 -and $script:EnsureCalls -eq 0) 'Failed readback must stop before any application configuration.'
            }
        }
    } $ModulePath
    Write-Host 'Named provider input, zero/one/multiple app configurations, confirmation, preservation, and stale-plan checks passed.'
}
finally { Remove-Module -ModuleInfo $module -Force }
