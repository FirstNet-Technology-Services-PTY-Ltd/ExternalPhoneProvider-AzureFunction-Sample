#Requires -Version 7.0
<#
.SYNOPSIS
    Turn on FirstNet SMS MFA, and optionally voice call MFA (Microsoft Entra ID external phone provider), in your
    tenant.
.DESCRIPTION
    Run in Azure Cloud Shell (PowerShell) as your tenant's administrator. Four steps, each a separate run:

      ./Enable-FirstNetSms.ps1                 Check prerequisites, deploy Microsoft's Function with the FirstNet
                                               adapter (Setup-Epp.ps1), keep one instance warm, print a setup code.
                                               Email the setup code to FirstNet.
      ./Enable-FirstNetSms.ps1 -Activate       After FirstNet confirms: back up the SMS policy and send SMS codes
                                               through FirstNet for a pilot group.
      ./Enable-FirstNetSms.ps1 -Expand -Percent 100 [-AllUsers]
                                               Widen the rollout.
      ./Enable-FirstNetSms.ps1 -Rollback <backup.json>
                                               Put the policy saved in that backup back exactly as it was.

    Add -Channel Voice (or -Channel Both) to -Activate and -Expand to do the same for voice calls. The same Function
    serves both channels, so voice needs no second deployment or setup code:

      ./Enable-FirstNetSms.ps1 -Activate -Channel Voice [-Evaluate]
      ./Enable-FirstNetSms.ps1 -Expand -Channel Voice -Percent 100 [-AllUsers]

    ./Enable-FirstNetSms.ps1 -SetupCode prints the setup code again.

    Nothing here needs FirstNet to have access to your tenant. The setup code holds identifiers only (tenant ID,
    endpoint application ID, Function URL, organisation name and your contact address), no secrets.
.PARAMETER Channel
    Which authentication method policy -Activate and -Expand change: Sms (the default, as before), Voice (the voice
    call policy) or Both. Each channel is backed up to its own file (sms-policy-backup-*.json,
    voice-policy-backup-*.json), and -Rollback reads the channel from the backup, so it needs no -Channel.
    With Both, both channels use the same pilot group and -Percent. The voice policy's office phone setting
    (isOfficePhoneAllowed) is left as it is. Voice calls through FirstNet need FirstNet to have switched voice on for
    your organisation; -Evaluate tests the voice path without that, because Microsoft still makes the call.
.PARAMETER Percent
    Share of the channel's sign-ins routed to FirstNet (migrationPercentage). With -Activate it is required only when
    the channel is already in use in the tenant: the script then keeps the existing users and routes this share to
    FirstNet, instead of narrowing the channel to the pilot group (which would switch it off for everyone else).
    Set it to 100 well before 1 February 2027, when Microsoft retires its own SMS codes and voice calls: sign-ins
    not routed through FirstNet don't fall back to it.
#>
[CmdletBinding(DefaultParameterSetName = 'Deploy')]
param(
    [Parameter(ParameterSetName = 'Deploy')] [string] $TenantId,
    [Parameter(ParameterSetName = 'Deploy')] [string] $SubscriptionId,
    [Parameter(ParameterSetName = 'Deploy')] [string] $Location = 'southafricanorth',
    [Parameter(ParameterSetName = 'Deploy')] [ValidatePattern('^[a-z][a-z0-9]{1,7}$')] [string] $ResourcePrefix = 'fnetsms',
    [Parameter(ParameterSetName = 'Deploy')] [string] $ApplicationId,
    [Parameter(ParameterSetName = 'Deploy')] [switch] $SkipChecks,

    [Parameter(ParameterSetName = 'Code', Mandatory)] [switch] $SetupCode,

    [Parameter(ParameterSetName = 'Activate', Mandatory)] [switch] $Activate,
    [Parameter(ParameterSetName = 'Activate')] [string] $PilotGroup = 'FirstNet-SMS-Pilot',
    [Parameter(ParameterSetName = 'Activate')] [string[]] $PilotUsers = @(),
    [Parameter(ParameterSetName = 'Activate')] [switch] $Evaluate,

    [Parameter(ParameterSetName = 'Expand', Mandatory)] [switch] $Expand,
    [Parameter(ParameterSetName = 'Expand')] [switch] $AllUsers,

    [Parameter(ParameterSetName = 'Activate')]
    [Parameter(ParameterSetName = 'Expand')]
    [ValidateRange(1, 100)] [int] $Percent,

    [Parameter(ParameterSetName = 'Activate')]
    [Parameter(ParameterSetName = 'Expand')]
    [ValidateSet('Sms', 'Voice', 'Both')] [string] $Channel = 'Sms',

    [Parameter(ParameterSetName = 'Rollback', Mandatory)] [string] $Rollback,

    [string] $OutputDirectory = (Join-Path $HOME 'firstnet-sms'),
    [string] $SourceRepository = 'FirstNet-Technology-Services-PTY-Ltd/ExternalPhoneProvider-AzureFunction-Sample',
    [string] $SourceRef = '5f2ea2847e693622f1e56e7af44c7b7f5d0aadfd',
    [string] $PackageReleaseTag = 'epp-packages-1-1-javascript'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:PolicyBaseUri = 'https://graph.microsoft.com/beta/policies/authenticationMethodsPolicy/authenticationMethodConfigurations'
# One entry per authentication method policy this script can route through FirstNet (both take telecomProviderSettings).
$script:FirstNetChannels = @{
    Sms = @{
        Label = 'SMS'; Noun = 'SMS'; Own = 'SMS'; MicrosoftSends = 'Microsoft sends SMS'
        Uri = "$script:PolicyBaseUri/Sms"; ODataType = '#microsoft.graph.smsAuthenticationMethodConfiguration'
        BackupPrefix = 'sms-policy-backup'; Flag = ''
    }
    Voice = @{
        Label = 'Voice'; Noun = 'voice'; Own = 'voice calls'; MicrosoftSends = 'Microsoft makes voice calls'
        Uri = "$script:PolicyBaseUri/voice"; ODataType = '#microsoft.graph.voiceAuthenticationMethodConfiguration'
        BackupPrefix = 'voice-policy-backup'; Flag = ' -Channel Voice'
    }
}
$script:SetupCodePrefix = 'FNSMS1.'
$script:ProviderId = 'firstnet'

# ------------------------------------------------------------------------------------------------ pure helpers
# (no Azure or Graph calls; covered by tests/FirstNet.Tests.ps1)

function ConvertTo-FirstNetSetupCode {
    param([Parameter(Mandatory)] $Deployment, [string] $Organization, [string] $Contact, [string] $Region)
    $value = [ordered]@{
        v = 1
        tenantId = [string]$Deployment.tenantId
        appId = [string]$Deployment.applicationId
        endpoint = [string]$Deployment.endpointUrl
        org = $Organization
        contact = $Contact
        resourceGroup = [string]$Deployment.resources.resourceGroup
        functionApp = [string]$Deployment.resources.functionApp
        region = $Region
        createdAt = [DateTime]::UtcNow.ToString('o')
    }
    $json = $value | ConvertTo-Json -Compress
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    return $script:SetupCodePrefix + $b64
}

function Get-FirstNetLatestFile {
    param([string] $Directory, [string] $Pattern, [string] $TenantId)
    if (-not (Test-Path -LiteralPath $Directory)) { return $null }
    foreach ($file in Get-ChildItem -LiteralPath $Directory -Filter $Pattern -File | Sort-Object LastWriteTimeUtc -Descending) {
        $data = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
        if ($data.PSObject.Properties['provider'] -and $data.provider -ne $script:ProviderId) { continue }
        if ($TenantId -and $data.tenantId -ne $TenantId) { continue }
        return $data
    }
    return $null
}

function Get-FirstNetRoleCheck {
    <# Returns @{ Ok; Missing; Warnings } from the display names of the signed-in user's active directory roles. #>
    param([string[]] $RoleNames)
    $has = { param($n) $RoleNames -contains $n }
    $ga = & $has 'Global Administrator'
    $canCreateApps = $ga -or (& $has 'Application Administrator') -or (& $has 'Cloud Application Administrator') -or (& $has 'Application Developer')
    $canGrant = $ga -or (& $has 'Privileged Role Administrator')
    $missing = @()
    if (-not $canGrant) { $missing += 'Privileged Role Administrator (to let Microsoft read the endpoint app''s encryption key)' }
    if (-not $canCreateApps) { $missing += 'Application Administrator (to create the endpoint app registration)' }
    $warnings = @()
    if (-not ($ga -or (& $has 'Authentication Policy Administrator'))) {
        $warnings += 'You will also need Authentication Policy Administrator for the -Activate step.'
    }
    return @{ Ok = -not $missing; Missing = $missing; Warnings = $warnings }
}

function Get-FirstNetOwnerCheck {
    <# Owner on the subscription, at least one assignment without an ABAC condition (Setup-Epp assigns roles). #>
    param([object[]] $OwnerAssignments)
    $all = @($OwnerAssignments | Where-Object { $null -ne $_ })
    if (-not $all) { return @{ Ok = $false; Reason = 'You are not Owner of this subscription.' } }
    if (-not @($all | Where-Object { -not $_.condition })) {
        return @{ Ok = $false; Reason = 'Your Owner role has a condition that limits which roles you can assign. Re-add Owner with "Allow user to assign all roles (highly privileged)".' }
    }
    return @{ Ok = $true; Reason = $null }
}

function Get-FirstNetRegionCheck {
    param([object[]] $Regions, [string] $Location)
    $wanted = $Location.ToLowerInvariant().Replace(' ', '')
    return [bool](@($Regions) | Where-Object { "$_".ToLowerInvariant().Replace(' ', '') -eq $wanted })
}

function Get-FirstNetLicenceCheck {
    param([object[]] $Skus)
    foreach ($sku in @($Skus)) {
        if ($sku.capabilityStatus -ne 'Enabled') { continue }
        foreach ($plan in @($sku.servicePlans)) {
            if ($plan.servicePlanName -in @('AAD_PREMIUM', 'AAD_PREMIUM_P2') -and $plan.provisioningStatus -ne 'Disabled') { return $true }
        }
    }
    return $false
}

function Get-FirstNetChannels {
    <# The policies a -Channel value covers, SMS first. #>
    param([ValidateSet('Sms', 'Voice', 'Both')] [string] $Channel = 'Sms')
    if ($Channel -eq 'Both') { return @('Sms', 'Voice') }
    return @($Channel)
}

function Test-FirstNetPolicyInUse {
    param([Parameter(Mandatory)] [hashtable] $Current)
    return $Current['state'] -eq 'enabled' -and @($Current['includeTargets'] | Where-Object { $_ }).Count -gt 0
}

function New-FirstNetTarget {
    <# An includeTargets entry. isUsableForSignIn exists only on SMS targets (SMS sign-in); voice targets don't have it. #>
    param([Parameter(Mandatory)] [string] $Channel, [Parameter(Mandatory)] [string] $Id)
    $target = @{ targetType = 'group'; id = $Id; isRegistrationRequired = $false }
    if ($Channel -eq 'Sms') { $target.isUsableForSignIn = $true }
    return $target
}

function Get-FirstNetActivation {
    <#
    Works out one channel's policy change for -Activate from its current policy. Returns @{ Body; Mode; Summary }.
      pilot-group       The channel was off (or had no targets): enable it for the pilot group only, 100% through FirstNet.
      existing-targets  The channel is already in use: keep its targets and route -Percent of its sign-ins through FirstNet.
    #>
    param([Parameter(Mandatory)] [hashtable] $Current, [Parameter(Mandatory)] [string] $AppId,
          [Parameter(Mandatory)] [string] $EndpointUrl, [string] $GroupId, [int] $Percent, [switch] $Evaluate,
          [ValidateSet('Sms', 'Voice')] [string] $Channel = 'Sms')
    $c = $script:FirstNetChannels[$Channel]
    $existing = $Current['telecomProviderSettings']
    if ($existing -and $existing['url'] -and ($existing['url'] -ne $EndpointUrl -or $existing['appId'] -ne $AppId)) {
        throw "$($c.Label) is already routed to another provider ($($existing['url'])). Roll that back first; nothing was changed."
    }
    $targets = @($Current['includeTargets'] | Where-Object { $_ })
    $provider = @{ url = $EndpointUrl; appId = $AppId; isEvaluationModeEnabled = [bool]$Evaluate; migrationPercentage = 100 }
    $body = @{ '@odata.type' = $c.ODataType; telecomProviderSettings = $provider }
    if (-not (Test-FirstNetPolicyInUse $Current)) {
        if (-not $GroupId) { throw 'A pilot group ID is required.' }
        if ($Percent) { $provider.migrationPercentage = $Percent }
        $body.state = 'enabled'
        $body.includeTargets = @(New-FirstNetTarget $Channel $GroupId)
        return @{ Body = $body; Mode = 'pilot-group'; Summary = "$($c.Label) enabled for the pilot group only; $($provider.migrationPercentage)% of its $($c.Noun) sign-ins go through FirstNet." }
    }
    if (-not $Percent) {
        $who = ($targets | ForEach-Object { if ($_['targetType'] -eq 'group' -and $_['id'] -eq 'all_users') { 'all users' } else { "$($_['targetType']) $($_['id'])" } }) -join ', '
        throw "$($c.Label) sign-in is already in use here ($who). Narrowing it to a pilot group would switch $($c.Noun) off for everyone else, so this script keeps those users and routes a share of their $($c.Noun) sign-ins to FirstNet instead. Rerun with -Percent (for example -Percent 5)."
    }
    $provider.migrationPercentage = $Percent
    return @{ Body = $body; Mode = 'existing-targets'; Summary = "$($c.Label) users unchanged; $Percent% of $($c.Noun) sign-ins go through FirstNet, the rest through Microsoft's own $($c.Own), which it retires on 1 February 2027. Widen to 100% before then." }
}

function Get-FirstNetExpansion {
    param([Parameter(Mandatory)] [hashtable] $Current, [int] $Percent, [switch] $AllUsers,
          [ValidateSet('Sms', 'Voice')] [string] $Channel = 'Sms')
    $c = $script:FirstNetChannels[$Channel]
    $provider = $Current['telecomProviderSettings']
    if (-not $provider -or -not $provider['url']) { throw "FirstNet is not active for $($c.Noun) yet. Run -Activate$($c.Flag) first." }
    if (-not $Percent -and -not $AllUsers) { throw 'Say what to widen: -Percent <1-100>, -AllUsers, or both.' }
    $settings = @{
        url = $provider['url']; appId = $provider['appId']; isEvaluationModeEnabled = $false
        migrationPercentage = $(if ($Percent) { $Percent } else { [int]$provider['migrationPercentage'] })
    }
    $body = @{ '@odata.type' = $c.ODataType; telecomProviderSettings = $settings }
    if ($AllUsers) {
        $body.state = 'enabled'
        $body.includeTargets = @(New-FirstNetTarget $Channel 'all_users')
    }
    return $body
}

function Get-FirstNetBackupChannel {
    <# Which policy a backup holds: from its @odata.type or id. Backups made before -Channel existed are SMS. #>
    param([Parameter(Mandatory)] [hashtable] $Backup)
    $type = [string]$Backup['@odata.type']
    if ($type -match 'voiceAuthenticationMethodConfiguration$' -or (-not $type -and $Backup['id'] -eq 'Voice')) { return 'Voice' }
    if ($type -and $type -notmatch 'smsAuthenticationMethodConfiguration$') {
        throw "This backup is not an SMS or voice policy ($type). Nothing was changed."
    }
    return 'Sms'
}

function Get-FirstNetRollbackBody {
    <# The PATCH that restores a policy saved by this script (state, includeTargets, telecomProviderSettings). #>
    param([Parameter(Mandatory)] [hashtable] $Backup)
    $targets = @(foreach ($t in @($Backup['includeTargets'] | Where-Object { $_ })) {
        $item = @{ targetType = $t['targetType']; id = $t['id'] }
        foreach ($k in 'isRegistrationRequired', 'isUsableForSignIn') { if ($t.ContainsKey($k)) { $item[$k] = $t[$k] } }
        $item
    })
    return @{
        '@odata.type' = $script:FirstNetChannels[(Get-FirstNetBackupChannel $Backup)].ODataType
        state = $Backup['state']
        includeTargets = $targets
        telecomProviderSettings = $Backup['telecomProviderSettings']
    }
}

# ------------------------------------------------------------------------------------------------ Azure / Graph

function Invoke-FirstNetAz {
    $output = & az @args -o json 2>$null
    if ($LASTEXITCODE -ne 0) { throw "az $($args[0..1] -join ' ') failed. Run it by hand to see why." }
    if (-not $output) { return $null }
    return ($output -join "`n") | ConvertFrom-Json -AsHashtable
}

function Write-FirstNetCheck {
    param([bool] $Ok, [string] $Text, [string] $Fix)
    if ($Ok) { Write-Host "  [ OK ] $Text" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Text" -ForegroundColor Red; if ($Fix) { Write-Host "         $Fix" -ForegroundColor Yellow } }
    return $Ok
}

function Connect-FirstNetGraph {
    param([string] $Tenant)
    if (-not (Get-Command Connect-MgGraph -ErrorAction SilentlyContinue)) {
        throw 'Microsoft Graph PowerShell is not available. Use Azure Cloud Shell (PowerShell), or Install-Module Microsoft.Graph.Authentication.'
    }
    $context = Get-MgContext
    if (-not $context -or $context.TenantId -ne $Tenant -or $context.Scopes -notcontains 'Policy.ReadWrite.AuthenticationMethod') {
        Connect-MgGraph -TenantId $Tenant -Scopes 'Policy.ReadWrite.AuthenticationMethod' -UseDeviceCode -NoWelcome
    }
}

function Get-FirstNetPolicy {
    param([string] $Channel = 'Sms')
    return (Invoke-MgGraphRequest -Method GET -Uri $script:FirstNetChannels[$Channel].Uri -OutputType Json) | ConvertFrom-Json -AsHashtable
}

function Save-FirstNetPolicyBackup {
    param([string] $Channel = 'Sms', [hashtable] $Policy)
    $c = $script:FirstNetChannels[$Channel]
    $path = Join-Path $OutputDirectory "$($c.BackupPrefix)-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')).json"
    $Policy | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    Write-Host "$($c.Label) policy backup: $path" -ForegroundColor Cyan
    Write-Host '  Keep a copy outside Cloud Shell (Manage files > Download). To undo later:'
    Write-Host "  ./Enable-FirstNetSms.ps1 -Rollback '$path'"
    return $path
}

function Set-FirstNetPolicy {
    param([string] $Channel = 'Sms', [hashtable] $Body)
    $c = $script:FirstNetChannels[$Channel]
    Invoke-MgGraphRequest -Method PATCH -Uri $c.Uri -Body ($Body | ConvertTo-Json -Depth 10) -ContentType 'application/json' | Out-Null
    $after = Get-FirstNetPolicy $Channel
    $p = $after['telecomProviderSettings']
    Write-Host "`n$($c.Label) policy now: state $($after['state']); targets $((@($after['includeTargets'] | ForEach-Object { $_['id'] }) -join ', '))"
    if ($p) { Write-Host "  provider $($p['url']); evaluation $($p['isEvaluationModeEnabled']); $($p['migrationPercentage'])%" }
    else { Write-Host "  no external provider ($($c.MicrosoftSends))" }
    Write-Host 'Changes can take a few minutes (Microsoft says up to an hour) to reach sign-ins.'
}

function Confirm-FirstNet {
    param([string] $Question)
    return (Read-Host "$Question [y/N]") -match '^(y|yes)$'
}

# ------------------------------------------------------------------------------------------------ steps

function Invoke-FirstNetDeploy {
    $account = Invoke-FirstNetAz account show
    if (-not $TenantId) {
        $script:TenantId = $account['tenantId']
        $tenantName = $account['tenantDisplayName']
        if (-not $tenantName) { $tenantName = (Invoke-FirstNetAz rest --method GET --url 'https://graph.microsoft.com/v1.0/organization?$select=displayName')['value'][0]['displayName'] }
        Write-Host "Tenant: $tenantName ($TenantId)"
        if (-not (Confirm-FirstNet 'Turn on FirstNet SMS for this tenant?')) { return }
    }
    elseif ($account['tenantId'] -ne $TenantId) {
        az login --tenant $TenantId --use-device-code | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Azure CLI sign-in failed.' }
    }
    if (-not $SubscriptionId) {
        $subs = @(Invoke-FirstNetAz account list --query "[?tenantId=='$TenantId' && state=='Enabled'].{id:id,name:name}")
        if (-not $subs) { throw 'No enabled Azure subscription in this tenant. Create one (or ask your Microsoft partner for an Azure plan), then rerun.' }
        if ($subs.Count -eq 1) { $script:SubscriptionId = $subs[0]['id'] }
        else {
            for ($i = 0; $i -lt $subs.Count; $i++) { Write-Host "  [$($i + 1)] $($subs[$i]['name']) ($($subs[$i]['id']))" }
            $pick = [int](Read-Host 'Subscription number')
            if ($pick -lt 1 -or $pick -gt $subs.Count) { throw 'No subscription chosen.' }
            $script:SubscriptionId = $subs[$pick - 1]['id']
        }
    }
    az account set --subscription $SubscriptionId | Out-Null

    if (-not $SkipChecks) {
        Write-Host "`nChecking prerequisites" -ForegroundColor Cyan
        $ok = $true
        $skus = (Invoke-FirstNetAz rest --method GET --url 'https://graph.microsoft.com/v1.0/subscribedSkus?$select=skuPartNumber,capabilityStatus,servicePlans')['value']
        $ok = (Write-FirstNetCheck (Get-FirstNetLicenceCheck $skus) 'Microsoft Entra ID P1 or P2' 'Users who get SMS or voice MFA through FirstNet need Entra ID P1 or P2.') -and $ok
        $roles = @((Invoke-FirstNetAz rest --method GET --url 'https://graph.microsoft.com/v1.0/me/memberOf/microsoft.graph.directoryRole?$select=displayName')['value'] | ForEach-Object { $_['displayName'] })
        $roleCheck = Get-FirstNetRoleCheck $roles
        $ok = (Write-FirstNetCheck $roleCheck.Ok 'Directory roles' "Missing: $($roleCheck.Missing -join '; '). If you use PIM, activate the roles first.") -and $ok
        foreach ($w in $roleCheck.Warnings) { Write-Host "         $w" -ForegroundColor Yellow }
        $me = (Invoke-FirstNetAz ad signed-in-user show --query '{id:id}')['id']
        $owners = @(Invoke-FirstNetAz role assignment list --assignee $me --scope "/subscriptions/$SubscriptionId" --include-inherited --include-groups --query "[?roleDefinitionName=='Owner'].{condition:condition}")
        $ownerCheck = Get-FirstNetOwnerCheck $owners
        $ok = (Write-FirstNetCheck $ownerCheck.Ok 'Owner of the subscription' $ownerCheck.Reason) -and $ok
        $regions = @(Invoke-FirstNetAz functionapp list-flexconsumption-locations --query '[].name')
        $ok = (Write-FirstNetCheck (Get-FirstNetRegionCheck $regions $Location) "Flex Consumption available in $Location" 'Pick another region with -Location (az functionapp list-flexconsumption-locations).') -and $ok
        foreach ($ns in 'Microsoft.Web', 'Microsoft.Storage', 'Microsoft.KeyVault', 'Microsoft.Insights', 'Microsoft.OperationalInsights', 'Microsoft.ManagedIdentity') {
            if ((az provider show -n $ns --query registrationState -o tsv 2>$null) -ne 'Registered') {
                Write-Host "  Registering resource provider $ns ..."
                az provider register -n $ns --wait | Out-Null
            }
        }
        if (-not $ok) { throw 'Fix the items marked FAIL, then rerun. Nothing was created.' }
    }

    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    # A previous run that created the app but stopped later: reuse that app and prefix (no second app).
    $previous = Get-FirstNetLatestFile $OutputDirectory 'application-*.json' $TenantId
    $setupArgs = @{
        TenantId = $TenantId; SubscriptionId = $SubscriptionId; Location = $Location; Language = 'javascript'
        ServicePlan = 'FC1'; Provider = $script:ProviderId; ResourcePrefix = $ResourcePrefix; InstallPrerequisites = $true
        SourceRepository = $SourceRepository; SourceRef = $SourceRef; PackageReleaseTag = $PackageReleaseTag
        OutputDirectory = $OutputDirectory
    }
    if ($ApplicationId) { $setupArgs.ApplicationId = $ApplicationId }
    elseif ($previous) {
        Write-Host "Reusing the endpoint app from the previous run: $($previous.applicationId)" -ForegroundColor Yellow
        $setupArgs.ApplicationId = $previous.applicationId; $setupArgs.ResourcePrefix = $previous.resourcePrefix
    }
    $setupPath = Join-Path $OutputDirectory 'Setup-Epp.ps1'
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/$SourceRepository/$SourceRef/setup/Setup-Epp.ps1" -OutFile $setupPath
    Write-Host "`nRunning Microsoft's setup with FirstNet's settings. Review its plan and answer Y to deploy." -ForegroundColor Cyan
    Write-Host 'If it asks which application to use, press Enter to create a new one.'
    try { & $setupPath @setupArgs | Out-Null }
    catch {
        Write-Host "`nSetup stopped: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'Fix the cause and run ./Enable-FirstNetSms.ps1 again. It reuses the app this run created, so no second app is made.' -ForegroundColor Yellow
        throw
    }

    $deployment = Get-FirstNetLatestFile $OutputDirectory 'deployment-*.json' $TenantId
    if (-not $deployment) { throw 'Setup did not finish, so there is no deployment summary. Fix the error above and rerun this script.' }
    Write-Host "`nKeeping one Function instance warm (avoids a slow first sign-in)" -ForegroundColor Cyan
    az functionapp scale config always-ready set -g $deployment.resources.resourceGroup -n $deployment.resources.functionApp --settings http=1 -o none
    if ($LASTEXITCODE -ne 0) { Write-Warning 'Could not set always-ready. Ask FirstNet; sign-ins still work but the first one after a quiet period may fail.' }
    Show-FirstNetSetupCode $deployment -Region $Location
}

function Show-FirstNetSetupCode {
    param($Deployment, [string] $Region)
    if (-not $Deployment) { $Deployment = Get-FirstNetLatestFile $OutputDirectory 'deployment-*.json' $null }
    if (-not $Deployment) { throw "No FirstNet deployment found in $OutputDirectory. Run ./Enable-FirstNetSms.ps1 first." }
    $org = (Invoke-FirstNetAz rest --method GET --url 'https://graph.microsoft.com/v1.0/organization?$select=displayName')['value'][0]['displayName']
    $contact = (Invoke-FirstNetAz ad signed-in-user show --query '{c: mail || userPrincipalName}')['c']
    $code = ConvertTo-FirstNetSetupCode $Deployment -Organization $org -Contact $contact -Region $Region
    Write-Host "`nSetup finished. Email this setup code to FirstNet (it contains no secrets):" -ForegroundColor Green
    Write-Host "`n$code`n"
    Write-Host "It holds: tenant $($Deployment.tenantId), app $($Deployment.applicationId), $($Deployment.endpointUrl), $org, $contact."
    Write-Host 'When FirstNet confirms, run: ./Enable-FirstNetSms.ps1 -Activate'
}

function Invoke-FirstNetActivate {
    $deployment = Get-FirstNetLatestFile $OutputDirectory 'deployment-*.json' $null
    if (-not $deployment) { throw "No FirstNet deployment found in $OutputDirectory. Run ./Enable-FirstNetSms.ps1 first." }
    $channels = @(Get-FirstNetChannels $Channel)
    if (-not (Confirm-FirstNet 'Has FirstNet confirmed that your setup code is approved?')) {
        Write-Host "Wait for FirstNet's confirmation first: until then FirstNet would refuse your sign-ins' $(if ($channels -contains 'Sms') { 'SMS' } else { 'voice calls' })."; return
    }
    if ($channels -contains 'Voice' -and -not $Evaluate -and -not (Confirm-FirstNet 'Has FirstNet confirmed that voice calls are switched on for your organisation?')) {
        Write-Host 'Ask FirstNet to switch voice on first: until then FirstNet would refuse your sign-ins'' voice calls. -Evaluate tests voice without it.'; return
    }
    Connect-FirstNetGraph $deployment.tenantId
    $current = @{}
    foreach ($ch in $channels) { $current[$ch] = Get-FirstNetPolicy $ch }
    $groupId = $null
    if (@($channels | Where-Object { -not (Test-FirstNetPolicyInUse $current[$_]) })) {
        $groupId = (az ad group show --group $PilotGroup --query id -o tsv 2>$null)
        if (-not $groupId) {
            Write-Host "Creating security group $PilotGroup"
            $groupId = az ad group create --display-name $PilotGroup --mail-nickname ($PilotGroup -replace '[^A-Za-z0-9]', '') --query id -o tsv
            if (-not $groupId) { throw "Could not create group $PilotGroup." }
        }
        foreach ($upn in $PilotUsers) {
            $uid = az ad user show --id $upn --query id -o tsv 2>$null
            if (-not $uid) { Write-Warning "User $upn not found; skipped."; continue }
            az ad group member check --group $groupId --member-id $uid --query value -o tsv | ForEach-Object {
                if ($_ -ne 'true') { az ad group member add --group $groupId --member-id $uid | Out-Null; Write-Host "  added $upn" }
            }
        }
        $members = @(Invoke-FirstNetAz ad group member list --group $groupId --query '[].userPrincipalName')
        if (-not $members) { throw "The pilot group $PilotGroup has no members. Add one or two test users (-PilotUsers user@yourdomain) and rerun." }
        Write-Host "Pilot group $PilotGroup ($groupId): $($members -join ', ')"
    }
    # Work out every channel's change before touching any, so a refusal leaves both policies as they are.
    $changes = [ordered]@{}
    foreach ($ch in $channels) {
        $changes[$ch] = Get-FirstNetActivation -Channel $ch -Current $current[$ch] -AppId $deployment.applicationId `
            -EndpointUrl $deployment.endpointUrl -GroupId $groupId -Percent $Percent -Evaluate:$Evaluate
        Write-Host "`nPlan: $($changes[$ch].Summary)" -ForegroundColor Cyan
    }
    if ($Evaluate -and $channels -contains 'Sms') { Write-Host 'Evaluation mode: Microsoft still sends the SMS. In new tenants Microsoft''s own SMS may be blocked (error 399287).' -ForegroundColor Yellow }
    if ($Evaluate -and $channels -contains 'Voice') { Write-Host 'Evaluation mode: Microsoft still makes the voice call.' -ForegroundColor Yellow }
    if (-not (Confirm-FirstNet $(if ($channels.Count -gt 1) { 'Apply these changes?' } else { 'Apply this change?' }))) { return }
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    foreach ($ch in $channels) { Save-FirstNetPolicyBackup $ch $current[$ch] | Out-Null }
    foreach ($ch in $channels) { Set-FirstNetPolicy $ch $changes[$ch].Body }
    $seen = @($(if ($channels -contains 'Sms') { 'SMS' }), $(if ($channels -contains 'Voice') { 'call' })) -join ' and '
    Write-Host "`nNext: make sure pilot users have a mobile number registered (or a Conditional Access policy requiring MFA for the group), sign in, and tell FirstNet the time. FirstNet sees each $seen in its console." -ForegroundColor Green
    Write-Host "Widen later with: ./Enable-FirstNetSms.ps1 -Expand$(if ($Channel -ne 'Sms') { " -Channel $Channel" }) -Percent 100 [-AllUsers]"
    foreach ($ch in $channels) { if ($changes[$ch].Body.telecomProviderSettings.migrationPercentage -lt 100) { Write-FirstNetRetirementNote $ch } }
}

function Write-FirstNetRetirementNote {
    param([string] $Channel = 'Sms')
    $text = if ($Channel -eq 'Voice') { 'Reach 100% for voice well before 1 February 2027, when Microsoft retires its own voice calls' }
            else { 'Reach 100% well before 1 February 2027, when Microsoft retires its own SMS codes' }
    Write-Host "$($text): sign-ins not routed through FirstNet don't fall back to it." -ForegroundColor Yellow
}

function Invoke-FirstNetExpand {
    $deployment = Get-FirstNetLatestFile $OutputDirectory 'deployment-*.json' $null
    if (-not $deployment) { throw "No FirstNet deployment found in $OutputDirectory." }
    $channels = @(Get-FirstNetChannels $Channel)
    Connect-FirstNetGraph $deployment.tenantId
    $current = @{}; $bodies = [ordered]@{}
    foreach ($ch in $channels) {
        $current[$ch] = Get-FirstNetPolicy $ch
        $bodies[$ch] = Get-FirstNetExpansion -Channel $ch -Current $current[$ch] -Percent $Percent -AllUsers:$AllUsers
    }
    $names = @($channels | ForEach-Object { $script:FirstNetChannels[$_].Noun }) -join ' and '
    $policies = if ($channels.Count -gt 1) { "the $names policies" } else { "the $names policy" }
    $what = @($(if ($AllUsers) { "$names for all users" }), $(if ($Percent) { "$Percent% through FirstNet" })) -join ', '
    if (-not (Confirm-FirstNet "Change $($policies): $what?")) { return }
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    foreach ($ch in $channels) { Save-FirstNetPolicyBackup $ch $current[$ch] | Out-Null }
    foreach ($ch in $channels) {
        Set-FirstNetPolicy $ch $bodies[$ch]
        if ($bodies[$ch].telecomProviderSettings.migrationPercentage -lt 100) { Write-FirstNetRetirementNote $ch }
    }
}

function Invoke-FirstNetRollback {
    $backup = Get-Content -LiteralPath $Rollback -Raw | ConvertFrom-Json -AsHashtable
    $ch = Get-FirstNetBackupChannel $backup
    $c = $script:FirstNetChannels[$ch]
    $deployment = Get-FirstNetLatestFile $OutputDirectory 'deployment-*.json' $null
    $tenant = if ($deployment) { $deployment.tenantId } else { Read-Host 'Tenant ID' }
    Connect-FirstNetGraph $tenant
    $body = Get-FirstNetRollbackBody $backup
    $provider = if ($body.telecomProviderSettings) { $body.telecomProviderSettings['url'] } else { "none ($($c.MicrosoftSends))" }
    if (-not (Confirm-FirstNet "Restore the $($c.Noun) policy to: state $($body.state), provider $($provider)?")) { return }
    Set-FirstNetPolicy $ch $body
}

# Dot-sourcing (tests) loads the functions only.
if ($MyInvocation.InvocationName -eq '.') { return }

switch ($PSCmdlet.ParameterSetName) {
    'Deploy' { Invoke-FirstNetDeploy }
    'Code' { Show-FirstNetSetupCode $null }
    'Activate' { Invoke-FirstNetActivate }
    'Expand' { Invoke-FirstNetExpand }
    'Rollback' { Invoke-FirstNetRollback }
}
