#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$setupDirectory = Split-Path -Parent $PSScriptRoot
$module = Import-Module (Join-Path $setupDirectory 'support' 'Epp.Setup.psm1') -Force -PassThru
$directory = Join-Path ([IO.Path]::GetTempPath()) "epp-provider-tests-$([Guid]::NewGuid().ToString('N'))"
try {
    $assets = Join-Path $directory 'assets'
    New-Item -ItemType Directory -Path (Join-Path $assets 'providers') -Force | Out-Null
    foreach ($file in @('catalog.json', 'telesign.json', 'soprano.json', 'infobip.json', 'firstnet.json')) {
        Copy-Item -LiteralPath (Join-Path $setupDirectory 'providers' $file) -Destination (Join-Path $assets 'providers' $file)
    }
    & $module {
        param($SetupDirectory, $Directory)

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
        $script:SetupDirectory = $SetupDirectory
        $assets = Join-Path $Directory 'assets'
        $script:Messages = [Collections.Generic.List[string]]::new()
        $script:Prompts = [Collections.Generic.List[string]]::new()
        $script:Answers = [Collections.Generic.Queue[string]]::new()
        $script:Warnings = [Collections.Generic.List[string]]::new()
        $script:Highlights = [Collections.Generic.List[string]]::new()
        function script:Write-Host {
            param([Parameter(ValueFromPipeline)] $Object, $ForegroundColor, [switch] $NoNewline)
            process {
                $script:Messages.Add([string]$Object)
                if ($ForegroundColor -eq 'Yellow') { $script:Highlights.Add([string]$Object) }
            }
        }
        function script:Write-Warning { param($Message); $script:Warnings.Add($Message) }
        function script:Read-Host {
            param($Prompt)
            $script:Prompts.Add($Prompt)
            Assert ($script:Answers.Count -gt 0) "Unexpected prompt: $Prompt"
            return $script:Answers.Dequeue()
        }
        function script:Invoke-WebRequest { throw 'Unexpected download (providers must be bundled).' }
        function script:Invoke-EppAz { throw 'Unexpected Azure call (no network allowed).' }

        $packageCases = @(
            @{ Id = 'javascript'; File = 'released-package.zip'; Strategy = 'ready' }
            @{ Id = 'dotnet'; File = 'released-package.zip'; Strategy = 'ready' }
            @{ Id = 'python'; File = 'released-package.zip'; Strategy = 'ready' }
        )
        $script:PackageRelease = [pscustomobject]@{
            tag_name = 'epp-packages-42-1-javascript'; draft = $false; prerelease = $false
            assets = @('released-package.zip', 'SHA256SUMS.txt' | ForEach-Object { [pscustomobject]@{ name = $_ } })
        }
        $script:ReleaseCalls = 0
        function script:Invoke-RestMethod {
            param($Uri, $Headers, $TimeoutSec)
            $script:ReleaseCalls++
            Assert ($Uri -ceq $script:ExpectedReleaseUri) 'Resolve only the selected repository and release.'
            if ($Uri.Contains('?per_page=100')) {
                return @(
                    [pscustomobject]@{ tag_name = 'unrelated-43-1'; draft = $false; prerelease = $false }
                    [pscustomobject]@{ tag_name = 'epp-packages-43-1'; draft = $false; prerelease = $false }
                    [pscustomobject]@{ tag_name = "epp-packages-43-1-$script:OtherLanguage"; draft = $false; prerelease = $false }
                    [pscustomobject]@{ tag_name = $script:PackageRelease.tag_name; draft = $true; prerelease = $false }
                    [pscustomobject]@{ tag_name = $script:PackageRelease.tag_name; draft = $false; prerelease = $true }
                    $script:PackageRelease
                )
            }
            return $script:PackageRelease
        }
        foreach ($repository in @('Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample', 'unit/epp-fork')) {
            foreach ($case in $packageCases) {
                $script:PackageRelease.tag_name = "epp-packages-42-1-$($case.Id)"
                $script:OtherLanguage = if ($case.Id -eq 'python') { 'javascript' } else { 'python' }
                foreach ($tag in @('', $script:PackageRelease.tag_name)) {
                    $script:ExpectedReleaseUri = if ($tag) {
                        "https://api.github.com/repos/$repository/releases/tags/$tag"
                    }
                    else { "https://api.github.com/repos/$repository/releases?per_page=100&page=1" }
                    $script:ReleaseCalls = 0
                    $selection = Get-EppLanguage -AssetDirectory $SetupDirectory -Language $case.Id `
                        -SourceRepository $repository -PackageReleaseTag $tag -NonInteractive
                    $releaseUrl = "https://github.com/$repository/releases/download/$($script:PackageRelease.tag_name)"
                    Assert ($selection.Id -ceq $case.Id -and $selection.BuildStrategy -ceq $case.Strategy) 'Preserve each language and its build strategy.'
                    Assert ($selection.Url -ceq "$releaseUrl/$($case.File)" -and
                        $selection.ChecksumsUrl -ceq "$releaseUrl/SHA256SUMS.txt" -and
                        $selection.ReleaseTag -ceq $script:PackageRelease.tag_name) 'Resolve concrete package and checksum URLs from the matching language release.'
                    Assert ($script:ReleaseCalls -eq 1) 'Resolve the language release directly.'
                }
                $script:PackageRelease.tag_name = 'epp-packages-42-1-javascript'
                $script:ExpectedReleaseUri = 'https://api.github.com/repos/unit/epp-fork/releases/tags/epp-packages-42-1-javascript'
            }
        }
        foreach ($noninteractive in @($false, $true)) {
            $selection = Get-EppLanguage -AssetDirectory $SetupDirectory -SourceRepository 'unit/epp-fork' `
                -PackageReleaseTag $script:PackageRelease.tag_name -NonInteractive:$noninteractive
            Assert ($selection.Id -ceq 'javascript' -and $selection.DisplayName -ceq 'JavaScript') 'Default to JavaScript without asking in either mode.'
        }
        $script:PackageRelease.tag_name = 'epp-packages-42-1-dotnet'
        $script:ExpectedReleaseUri = 'https://api.github.com/repos/unit/epp-fork/releases/tags/epp-packages-42-1-dotnet'
        foreach ($name in @('csharp', 'CSharp', 'C#', 'dotnet', '.NET')) {
            $selection = Get-EppLanguage -AssetDirectory $SetupDirectory -Language $name -SourceRepository 'unit/epp-fork' `
                -PackageReleaseTag $script:PackageRelease.tag_name
            Assert ($selection.Id -ceq 'dotnet' -and $selection.DisplayName -ceq 'C#') 'Expose C# while preserving the existing .NET package/runtime and legacy aliases.'
            Assert ($selection.ReleaseTag -ceq 'epp-packages-42-1-dotnet') 'C# aliases must resolve the dotnet release.'
        }
        $script:PackageRelease.tag_name = 'epp-packages-42-1-javascript'
        $script:ExpectedReleaseUri = 'https://api.github.com/repos/unit/epp-fork/releases/tags/epp-packages-42-1-javascript'
        foreach ($invalidTag in @('epp-packages-42-1', 'epp-packages-42-1-python', 'unrelated', 'EPP-packages-42-1-javascript', "epp-packages-42-1-javascript`n")) {
            $script:ReleaseCalls = 0
            Assert-Throws {
                Get-EppLanguage -AssetDirectory $SetupDirectory -SourceRepository 'unit/epp-fork' -PackageReleaseTag $invalidTag
            } 'must match.*selected language'
            Assert ($script:ReleaseCalls -eq 0) 'Reject wrong-language or malformed pins before requesting GitHub.'
        }
        foreach ($property in @('draft', 'prerelease')) {
            $script:PackageRelease.$property = $true
            Assert-Throws {
                Get-EppLanguage -AssetDirectory $SetupDirectory -SourceRepository 'unit/epp-fork' -PackageReleaseTag 'epp-packages-42-1-javascript'
            } 'not the requested stable CI package release'
            $script:PackageRelease.$property = $false
        }
        foreach ($wrongTag in @('epp-packages-41-1-javascript', 'epp-packages-42-1-python')) {
            $script:PackageRelease.tag_name = $wrongTag
            Assert-Throws {
                Get-EppLanguage -AssetDirectory $SetupDirectory -SourceRepository 'unit/epp-fork' -PackageReleaseTag 'epp-packages-42-1-javascript'
            } 'not the requested stable CI package release'
        }
        $script:PackageRelease.tag_name = 'epp-packages-42-1-javascript'
        $validAssets = $script:PackageRelease.assets
        foreach ($names in @(
            @('SHA256SUMS.txt'),
            @('released-package.zip'),
            @('Released-package.zip', 'SHA256SUMS.txt'),
            @('released-package.zip', 'released-package.zip', 'SHA256SUMS.txt'),
            @('released-package.zip', 'SHA256SUMS.txt', 'SHA256SUMS.txt'),
            @('released-package.zip', 'SHA256SUMS.txt', 'other.zip')
        )) {
            $script:PackageRelease.assets = @($names | ForEach-Object { [pscustomobject]@{ name = $_ } })
            Assert-Throws {
                Get-EppLanguage -AssetDirectory $SetupDirectory -SourceRepository 'unit/epp-fork' -PackageReleaseTag 'epp-packages-42-1-javascript'
            } 'must contain exactly one|must contain only'
        }
        $script:PackageRelease.assets = $validAssets
        Assert-Throws {
            Get-EppLanguage -AssetDirectory $SetupDirectory -Language unknown -SourceRepository 'unit/epp-fork'
        } 'Use javascript, csharp, or python'
        foreach ($emptyLanguage in @('', ' ')) {
            Assert-Throws {
                Get-EppLanguage -AssetDirectory $SetupDirectory -Language $emptyLanguage -SourceRepository 'unit/epp-fork'
            } 'Language must not be empty'
        }
        foreach ($url in @(
            'http://github.com/unit/epp-fork/releases/download/epp-packages-42-1/epp-javascript.zip',
            'https://github.com/unrelated/repository/releases/download/epp-packages-42-1/epp-javascript.zip'
        )) {
            Assert-Throws {
                Read-EppInput -Name PackageUrl -Value $url -Kind PackageUrl -SourceRepository 'unit/epp-fork' -NonInteractive
            } 'Invalid -PackageUrl'
        }
        Assert ($script:Prompts.Count -eq 0) 'Package resolution must not ask for raw URLs or checksums.'
        $script:ReleaseCalls = 0
        function script:Invoke-RestMethod {
            param($Uri, $Headers, $TimeoutSec)
            $script:ReleaseCalls++
            Assert ($Uri -ceq "https://api.github.com/repos/unit/epp-fork/releases?per_page=100&page=$script:ReleaseCalls") 'Follow release list pagination.'
            if ($script:ReleaseCalls -eq 1) {
                return @(1..100 | ForEach-Object { [pscustomobject]@{ tag_name = "unrelated-$_"; draft = $false; prerelease = $false } })
            }
            return @($script:PackageRelease)
        }
        $selection = Get-EppLanguage -AssetDirectory $SetupDirectory -SourceRepository 'unit/epp-fork'
        Assert ($script:ReleaseCalls -eq 2 -and $selection.ReleaseTag -ceq $script:PackageRelease.tag_name) 'Discover the language release beyond the first page.'
        function script:Invoke-RestMethod {
            return @(
                [pscustomobject]@{ tag_name = 'epp-packages-43-1-python'; draft = $false; prerelease = $false }
                [pscustomobject]@{ tag_name = 'epp-packages-43-1-javascript'; draft = $true; prerelease = $false }
                [pscustomobject]@{ tag_name = 'epp-packages-43-1-javascript'; draft = $false; prerelease = $true }
            )
        }
        Assert-Throws {
            Get-EppLanguage -AssetDirectory $SetupDirectory -SourceRepository 'unit/epp-fork'
        } 'No stable CI package release'
        function script:Invoke-RestMethod { throw 'not found' }
        Assert-Throws {
            Get-EppLanguage -AssetDirectory $SetupDirectory -SourceRepository 'unit/epp-fork' -PackageReleaseTag 'epp-packages-42-1-javascript'
        } 'Could not resolve.*not found'
        function script:Invoke-RestMethod { throw 'Unexpected REST call (no network allowed).' }

        $profile = Read-EppJson (Join-Path $SetupDirectory 'providers' 'telesign.json')
        Assert ($profile.deployment.authentication.mode -ceq 'oauth') 'Telesign deployments must select OAuth.'
        foreach ($region in @('global', 'eu')) {
            $configuration = Get-EppProvider -AssetDirectory $SetupDirectory -Provider telesign -EndpointRegion $region -NonInteractive
            Assert ($configuration.TenantId -ceq 'd818b557-ea1c-4070-a3f1-928330b7a30c' -and
                $configuration.Settings.EPP_PROVIDER_TENANT_ID -ceq 'd818b557-ea1c-4070-a3f1-928330b7a30c') 'Keep the Telesign provider and access-token tenants unchanged.'
            Assert ($configuration.Settings.EPP_PROVIDER_APP_ID -ceq 'f1117a41-5e56-48d1-836a-1313846d1610' -and
                $configuration.Settings.EPP_PROVIDER_SCOPE -ceq 'api://f1117a41-5e56-48d1-836a-1313846d1610/.default') 'Both Telesign routes must emit the confirmed API application and scope.'
        }
        $profile.deployment.AccessTokenScopeTenant = '<telesign-access-token-tenant-id>'
        Assert-Throws {
            ConvertTo-EppProviderSettings -Profile $profile -Id telesign -DisplayName Telesign -EndpointRegion global -NonInteractive
        } 'deployment.AccessTokenScopeTenant.*access-token tenant'
        $profile.deployment.AccessTokenScopeTenant = '11111111-1111-1111-1111-111111111111'
        foreach ($region in @('global', 'eu')) {
            $profile.deployment.routes[$region].appId = '22222222-2222-2222-2222-222222222222'
            $profile.deployment.routes[$region].scope = 'api://22222222-2222-2222-2222-222222222222/.default'
        }
        $profile | ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath (Join-Path $assets 'providers' 'telesign.json') -Encoding utf8NoBOM

        foreach ($id in @('telesign', 'soprano', 'infobip')) {
            foreach ($region in @('global', 'eu')) {
                $configuration = Get-EppProvider -AssetDirectory $assets `
                    -Provider $id -EndpointRegion $region -NonInteractive
                $route = $configuration.Manifest.deployment.routes[$region]
                $settings = $configuration.Settings
                Assert ($configuration.Id -ceq $id -and $configuration.EndpointRegion -ceq $region) 'Provider and region selection must be preserved.'
                Assert ($configuration.PSObject.Properties.Name -notcontains 'Channel') 'Provider metadata must not select a channel.'
                Assert (-not $settings.ContainsKey('EPP_PROVIDER_CHANNEL')) 'Setup must not emit a channel app setting.'
                Assert (-not $settings.ContainsKey('EPP_PROVIDER_ENDPOINT')) 'Setup must not emit a shared endpoint setting.'
                Assert ($settings.EPP_PROVIDER_SMS_ENDPOINT -ceq $route.smsEndpoint) 'Use the complete regional SMS endpoint.'
                Assert ($settings.EPP_PROVIDER_VOICE_ENDPOINT -ceq $route.voiceEndpoint) 'Use the complete regional voice endpoint.'
                Assert ($settings.EPP_PROVIDER_TIMEOUT_MS -ceq [string]$route.timeoutMilliseconds) 'Preserve the provider timeout.'
                Assert ($settings.EPP_PROVIDER_RETRY_INTERVAL_MS -ceq [string]([long]$route.retryIntervalSeconds * 1000)) 'Preserve retry interval metadata.'
                Assert ($settings.EPP_PROVIDER_AUTH_MODE -ceq $configuration.Manifest.deployment.authentication.mode) 'Preserve provider authentication.'
                Assert ($configuration.TenantId -ceq $configuration.Manifest.deployment.tenantId) 'Keep the Security Store tenant separate from token acquisition.'
                $tokenTenant = if ($configuration.Manifest.deployment.Contains('AccessTokenScopeTenant')) {
                    $configuration.Manifest.deployment.AccessTokenScopeTenant
                } else { $configuration.TenantId }
                Assert ($configuration.AccessTokenScopeTenant -ceq $tokenTenant -and
                    $settings.EPP_PROVIDER_TENANT_ID -ceq $configuration.AccessTokenScopeTenant) 'Configure the Function OAuth authority from AccessTokenScopeTenant, retaining the tenantId default for older profiles.'
                if ($configuration.AuthenticationMode -eq 'oauth') {
                    Assert ($settings.EPP_PROVIDER_APP_ID -ceq $route.appId -and $settings.EPP_PROVIDER_SCOPE -ceq $route.scope) 'Preserve regional OAuth settings.'
                }
                if ($id -eq 'infobip') {
                    Assert ($settings.EPP_PROVIDER_AUTH_MODE -ceq 'oauth' -and
                        $settings.EPP_PROVIDER_TENANT_ID -ceq 'a7d072c3-504e-4385-9029-89283084be5d' -and
                        $settings.EPP_PROVIDER_APP_ID -ceq 'd1131a30-5ed5-49b7-8602-d978c8eb1677' -and
                        $settings.EPP_PROVIDER_SCOPE -ceq 'd1131a30-5ed5-49b7-8602-d978c8eb1677/.default') 'Use the Infobip manifest tenant/API application and its default scope for OAuth.'
                    Assert (-not $configuration.Manifest.deployment.authentication.ContainsKey('keyVaultSecretName')) 'Infobip OAuth must not require an API-key secret.'
                }
                if ($id -eq 'telesign') {
                    Assert ($configuration.TenantId -cne $settings.EPP_PROVIDER_TENANT_ID) 'The token tenant must be independently configurable.'
                }
            }
        }
        Assert ($script:Prompts.Count -eq 0) 'Complete provider inputs must not prompt for a channel.'

        $profile = Read-EppJson (Join-Path $SetupDirectory 'providers' 'soprano.json')
        $profile.deployment.routes.eu.smsEndpoint = 'https://sms.eu.provider.contoso.com/send'
        $profile.deployment.routes.eu.voiceEndpoint = 'https://voice.eu.provider.contoso.com/send'
        $configuration = ConvertTo-EppProviderSettings -Profile $profile -Id soprano -DisplayName Soprano -EndpointRegion eu -NonInteractive
        Assert ($configuration.Settings.EPP_PROVIDER_SMS_ENDPOINT -ceq $profile.deployment.routes.eu.smsEndpoint) 'EU selection must preserve its distinct SMS endpoint.'
        Assert ($configuration.Settings.EPP_PROVIDER_VOICE_ENDPOINT -ceq $profile.deployment.routes.eu.voiceEndpoint) 'EU selection must preserve its distinct voice endpoint.'
        Assert-Throws { ConvertTo-EppProviderSettings -Profile $profile -Id soprano -DisplayName Soprano -NonInteractive } '\-EndpointRegion is required'
        Assert-Throws { ConvertTo-EppProviderSettings -Profile $profile -Id soprano -DisplayName Soprano -EndpointRegion invalid -NonInteractive } 'Unknown EndpointRegion'

        $profile.deployment.Remove('AccessTokenScopeTenant')
        $configuration = ConvertTo-EppProviderSettings -Profile $profile -Id soprano -DisplayName Soprano -EndpointRegion eu -NonInteractive
        Assert ($configuration.Settings.EPP_PROVIDER_TENANT_ID -ceq $profile.deployment.tenantId) 'Legacy profiles without AccessTokenScopeTenant must keep their original OAuth authority.'
        foreach ($value in @($null, '', ' ', 'invalid', '<telesign-access-token-tenant-id>', [Guid]::Empty.ToString())) {
            $profile.deployment.AccessTokenScopeTenant = $value
            Assert-Throws {
                ConvertTo-EppProviderSettings -Profile $profile -Id soprano -DisplayName Soprano -EndpointRegion eu -NonInteractive
            } 'deployment.AccessTokenScopeTenant'
        }
        $profile.deployment.AccessTokenScopeTenant = ' AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA '
        $configuration = ConvertTo-EppProviderSettings -Profile $profile -Id soprano -DisplayName Soprano -EndpointRegion eu -NonInteractive
        Assert ($configuration.Settings.EPP_PROVIDER_TENANT_ID -ceq 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') 'Normalize the token tenant independently of the Security Store tenant.'
        $profile.deployment.tenantId = 'invalid'
        Assert-Throws {
            ConvertTo-EppProviderSettings -Profile $profile -Id soprano -DisplayName Soprano -EndpointRegion eu -NonInteractive
        } 'deployment.tenantId'

        foreach ($region in @('global', 'eu')) {
            $profile = Read-EppJson (Join-Path $SetupDirectory 'providers' 'soprano.json')
            $profile.deployment.routes.Remove($region)
            Assert-Throws {
                ConvertTo-EppProviderSettings -Profile $profile -Id soprano -DisplayName Soprano -EndpointRegion global -NonInteractive
            } "deployment\.routes\.$region is missing"
            foreach ($case in @(
                @{ Field = 'smsEndpoint'; Value = 'http://provider.contoso.com/send' }
                @{ Field = 'voiceEndpoint'; Value = 'http://provider.contoso.com/send' }
                @{ Field = 'smsEndpoint'; Value = $null }
                @{ Field = 'voiceEndpoint'; Value = $null }
                @{ Field = 'timeoutMilliseconds'; Value = 2501 }
                @{ Field = 'retryIntervalSeconds'; Value = -1 }
                @{ Field = 'appId'; Value = 'invalid' }
                @{ Field = 'scope'; Value = 'api://provider/not-default' }
            )) {
                $profile = Read-EppJson (Join-Path $SetupDirectory 'providers' 'soprano.json')
                $profile.deployment.routes[$region][$case.Field] = $case.Value
                Assert-Throws {
                    ConvertTo-EppProviderSettings -Profile $profile -Id soprano -DisplayName Soprano -EndpointRegion global -NonInteractive
                } "deployment\.routes\.$region\.$($case.Field)"
            }
        }

        $tokens = $null
        $parseErrors = $null
        $launcher = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $SetupDirectory 'Setup-Epp.ps1'), [ref]$tokens, [ref]$parseErrors)
        Assert ($parseErrors.Count -eq 0) 'The launcher must parse successfully.'
        Assert ($launcher.ParamBlock.Parameters.Name.VariablePath.UserPath -notcontains 'Channel') 'The launcher must not expose a Channel parameter.'
        foreach ($name in @('Invoke-EppSetup', 'Get-EppProvider', 'ConvertTo-EppProviderSettings')) {
            Assert (-not (Get-Command $name).Parameters.ContainsKey('Channel')) "$name must not expose a Channel parameter."
        }

        function script:Get-EppLanguage {
            param($AssetDirectory, $Language, $SourceRepository, $PackageReleaseTag, [switch] $NonInteractive)
            $script:SelectedLanguage = $Language
            return @{
                Id = 'javascript'; DisplayName = 'JavaScript'; BuildStrategy = 'ready'
                Url = 'https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/releases/download/epp-packages-1-1/epp-javascript.zip'
                ReleaseTag = 'epp-packages-1-1'
            }
        }
        function script:Connect-EppContext {
            param($Inputs, $Names, [switch] $NonInteractive, [switch] $InstallPrerequisites, [switch] $ForceAuthentication)
            $script:PreflightInputs = @{} + $Inputs
            throw 'preflight-reached'
        }
        $script:TenantScope = 'NA'
        function script:Get-EppTenantRegionScope { param($TenantId); return $script:TenantScope }
        function script:Select-EppLocation {
            param($Inputs, $Location, [switch] $NonInteractive, [switch] $ForceAuthentication)
            return Read-EppInput -Name Location -Value $Location -Kind Location -NonInteractive
        }
        $script:GraphConnections = 0
        function script:Connect-EppGraphAccount {
            param($Inputs, [switch] $NonInteractive, [switch] $ForceAuthentication)
            $script:GraphConnections++
            $Inputs.AzureSelectionAuthenticated = $true
            return @{ Context = @{}; Operator = @{ Id = $inputs.TenantId; Account = 'operator@contoso.test' } }
        }
        function script:Get-EppApplication {
            param($Inputs, $ClientId, $ObjectId)
            return @{ Id = '44444444-4444-4444-4444-444444444444'; SignInAudience = 'AzureADMyOrg' }
        }
        function script:Get-EppSignInAudienceRestrictions { param($Inputs, $ApplicationObjectId); return $null }
        $inputs = @{
            TenantId = '11111111-1111-1111-1111-111111111111'
            SubscriptionId = '22222222-2222-2222-2222-222222222222'
            ApplicationId = '33333333-3333-3333-3333-333333333333'
            Location = 'westus2'; ResourcePrefix = 'unit'; Language = 'javascript'; ServicePlan = 'FC1'
            AssetDirectory = $assets
            SourceBaseUri = "https://raw.githubusercontent.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/$('a' * 40)/setup"
        }
        foreach ($id in @('telesign', 'soprano', 'infobip')) {
            foreach ($region in @('global', 'eu')) {
                $script:TenantScope = if ($region -eq 'eu') { 'EU' } else { 'NA' }
                Assert-Throws {
                    Invoke-EppSetup @inputs -Provider $id -EndpointRegion $region -OutputDirectory $Directory -NonInteractive
                } '^preflight-reached$'
                $profile = Read-EppJson (Join-Path $assets 'providers' "$id.json")
                $tokenTenant = if ($profile.deployment.Contains('AccessTokenScopeTenant')) {
                    $profile.deployment.AccessTokenScopeTenant
                } else { $profile.deployment.tenantId }
                Assert ($script:PreflightInputs.ProviderTenantId -ceq $profile.deployment.tenantId -and
                    $script:PreflightInputs.AccessTokenScopeTenant -ceq $tokenTenant -and
                    $script:PreflightInputs.ProviderAuthentication -ceq 'oauth') 'Preflight must receive both tenant identities and the chosen authentication mode.'
            }
        }
        Assert ($script:Prompts.Count -eq 0) 'Unattended setup must reach preflight without any channel input.'
        $script:TenantScope = 'NA'
        Assert-Throws {
            Invoke-EppSetup @inputs -EndpointRegion global -OutputDirectory $Directory -NonInteractive
        } '\-Provider is required'
        Assert ($script:GraphConnections -eq 0) 'Reject a missing unattended provider before contacting Graph.'
        $script:Answers.Enqueue('soprano')
        Assert-Throws {
            Invoke-EppSetup @inputs -OutputDirectory $Directory
        } '^preflight-reached$'
        Assert (($script:Prompts -join ',') -ceq 'Provider name') 'Detect tenant scope without a picker; provider selection must use a name.'
        Assert ($script:Answers.Count -eq 0) 'All expected prompt answers must be consumed.'

        $defaults = @{} + $inputs
        $defaults.Remove('ResourcePrefix')
        $defaults.Remove('Language')
        $script:Answers.Enqueue('')
        Assert-Throws { Invoke-EppSetup @defaults -Provider telesign -OutputDirectory $Directory } '^preflight-reached$'
        Assert ($script:PreflightInputs.ResourcePrefix -ceq 'epp' -and $script:SelectedLanguage -ceq 'javascript') 'The setup entry point must use the agreed prefix and language defaults.'
        Assert ($script:Prompts[-1] -ceq 'Resource name prefix [epp]') 'Show the prefix default with a customer-facing label.'
        foreach ($prefix in @('epp', 'contoso')) {
            Assert ((Read-EppInput -Name ResourcePrefix -Value $prefix -Kind Prefix -DefaultValue epp -NonInteractive) -ceq $prefix) 'Preserve explicitly supplied prefixes.'
        }
        Assert-Throws { Read-EppInput -Name ResourcePrefix -Kind Prefix -DefaultValue epp -NonInteractive } 'ResourcePrefix is required'
        Assert-Throws { Read-EppInput -Name ResourcePrefix -Value 'Bad-Prefix' -Kind Prefix -DefaultValue epp } 'Invalid -ResourcePrefix'
        $script:Answers.Enqueue('bad-prefix'); $script:Answers.Enqueue('myapp')
        Assert ((Read-EppInput -Name ResourcePrefix -Kind Prefix -DefaultValue epp) -ceq 'myapp') 'Reprompt invalid interactive prefixes instead of silently using the default.'
        foreach ($answer in @('Yes', 'yes', 'Y', ' y ')) {
            $script:Answers.Enqueue($answer)
            Assert (Confirm-EppDeployment) 'Accept the documented case-insensitive approval responses.'
        }
        foreach ($answer in @('No', 'no', 'N', ' n ', '', '  ')) {
            $script:Answers.Enqueue($answer)
            Assert (-not (Confirm-EppDeployment)) 'Accept cancellation aliases and keep Enter as cancel.'
        }
        $script:Warnings.Clear()
        $script:Answers.Enqueue('continue'); $script:Answers.Enqueue('n')
        Assert (-not (Confirm-EppDeployment) -and $script:Warnings.Count -eq 1) 'Invalid confirmation responses must reprompt.'
        Assert-Throws { Confirm-EppDeployment -NonInteractive } 'requires -ApproveDeployment'
        Assert (Confirm-EppDeployment -NonInteractive -ApproveDeployment) 'Keep explicit unattended approval.'
        foreach ($answer in @('Yes', 'y', ' YES ')) {
            $script:Answers.Enqueue($answer)
            Confirm-EppPrerequisiteInstall -Description Bicep
        }
        foreach ($answer in @('No', 'n', '')) {
            $script:Answers.Enqueue($answer)
            Assert-Throws { Confirm-EppPrerequisiteInstall -Description Bicep } 'Bicep is required'
        }
        Assert ($script:Answers.Count -eq 0) 'Consume every expected input without adding language or save-output prompts.'

        $names = Get-EppResourceNames -SubscriptionId $inputs.SubscriptionId -ApplicationId $inputs.ApplicationId -ResourcePrefix $inputs.ResourcePrefix
        $configuration = Get-EppProvider -AssetDirectory $assets -Provider telesign -EndpointRegion global -NonInteractive
        $script:Messages.Clear()
        Show-EppDeploymentResult -Inputs $inputs -Names $names -ProviderConfiguration $configuration `
            -EndpointUrl 'https://unit.azurewebsites.net/api/SendOtp' -ResultPath (Join-Path $Directory 'deployment.json')
        $result = $script:Messages -join "`n"
        foreach ($method in @('Sms', 'Voice')) {
            Assert ($result.Contains("https://graph.microsoft.com/beta/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/$method")) 'The handoff must show both policy targets.'
        }
        Assert ($result.Contains('each channel you intend to enable')) 'Policy activation must remain an explicit per-channel choice.'
        Assert ($result.Contains('did not change the External Phone Provider policy')) 'Setup must not claim policy activation.'
        Assert ($script:Highlights -contains 'IMPORTANT: Save this output. The endpoint URL and Application (client) ID are required for policy updates.') 'Highlight the save-output reminder in yellow.'
        Assert ($result.Contains('docs/GETTING-STARTED.md#4-connect-your-provider-and-test')) 'Link the existing provider, policy, and testing guidance from the completion output.'
        Assert ($result.Contains("access-token tenant '$($configuration.AccessTokenScopeTenant)'") -and
            $result.Contains($configuration.Settings.EPP_PROVIDER_SCOPE)) 'OAuth handoff must name the target tenant and scope.'
    } $setupDirectory $directory
    Write-Host 'Provider profiles, channel-independent setup, prompts, and policy handoff checks passed.'
}
finally {
    Remove-Module -ModuleInfo $module -Force
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}
