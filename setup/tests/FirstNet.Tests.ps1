#Requires -Version 7.0
# Tests for Enable-FirstNetSms.ps1's decision logic (no Azure or Graph calls).
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\Enable-FirstNetSms.ps1')

function Assert($Condition, [string] $Message) { if (-not $Condition) { throw "FAILED: $Message" } }
function Assert-Throws([scriptblock] $Action, [string] $Pattern) {
    try { $null = & $Action } catch { Assert ($_.Exception.Message -match $Pattern) "Unexpected failure: $($_.Exception.Message)"; return }
    throw "FAILED: expected an error matching '$Pattern'"
}

$app = '77777777-7777-7777-7777-777777777777'
$url = 'https://fnetsms-epp-func-1a2b3c4d.azurewebsites.net/api/SendOtp'
$group = 'd36eb061-3b4c-4d09-a2ab-abeb0a4295d3'

# --- setup code: FNSMS1. + base64url(JSON), decodable by the FirstNet console
$deployment = [pscustomobject]@{
    tenantId = '66666666-6666-6666-6666-666666666666'; applicationId = $app; endpointUrl = $url
    resources = [pscustomobject]@{ resourceGroup = 'fnetsms-epp-rg-1a2b3c4d'; functionApp = 'fnetsms-epp-func-1a2b3c4d' }
}
$code = ConvertTo-FirstNetSetupCode $deployment -Organization 'Contoso Ltd' -Contact 'it@contoso.example' -Region 'southafricanorth'
Assert ($code -cmatch '^FNSMS1\.[A-Za-z0-9_-]+$') 'setup code is prefix + base64url without padding'
$b64 = $code.Substring(7).Replace('-', '+').Replace('_', '/')
$b64 += '=' * ((4 - $b64.Length % 4) % 4)
$decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) | ConvertFrom-Json
Assert ($decoded.v -eq 1 -and $decoded.appId -eq $app -and $decoded.tenantId -eq $deployment.tenantId) 'setup code carries the IDs'
Assert ($decoded.endpoint -eq $url -and $decoded.resourceGroup -eq 'fnetsms-epp-rg-1a2b3c4d' -and $decoded.org -eq 'Contoso Ltd') 'setup code carries endpoint, RG, org'

# --- prerequisite checks
Assert (Get-FirstNetRoleCheck @('Global Administrator')).Ok 'Global Administrator is enough'
$r = Get-FirstNetRoleCheck @('Application Administrator')
Assert (-not $r.Ok -and ($r.Missing -join ' ') -match 'Privileged Role Administrator') 'Application Administrator alone misses the Graph grant'
$r = Get-FirstNetRoleCheck @('Application Administrator', 'Privileged Role Administrator')
Assert ($r.Ok -and ($r.Warnings -join ' ') -match 'Authentication Policy Administrator') 'App Admin + PRA is enough, with a warning for -Activate'
Assert (-not (Get-FirstNetOwnerCheck @()).Ok) 'no Owner fails'
$o = Get-FirstNetOwnerCheck @(@{ condition = "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})))" })
Assert (-not $o.Ok -and $o.Reason -match 'assign all roles') 'a constrained Owner fails with the fix (31 Oct finding)'
Assert (Get-FirstNetOwnerCheck @(@{ condition = 'x' }, @{ condition = $null })).Ok 'one unconstrained Owner is enough'
Assert (Get-FirstNetLicenceCheck @(@{ capabilityStatus = 'Enabled'; servicePlans = @(@{ servicePlanName = 'EXCHANGE_S_STANDARD'; provisioningStatus = 'Success' }, @{ servicePlanName = 'AAD_PREMIUM'; provisioningStatus = 'Success' }) })) 'P1 inside a suite counts'
Assert (-not (Get-FirstNetLicenceCheck @(@{ capabilityStatus = 'Suspended'; servicePlans = @(@{ servicePlanName = 'AAD_PREMIUM_P2'; provisioningStatus = 'Success' }) }))) 'a suspended SKU does not count'
Assert (Get-FirstNetRegionCheck @('East US', 'South Africa North') 'southafricanorth') 'region names match without spaces or case'
Assert (Get-FirstNetRegionCheck @('southafricanorth') 'southafricanorth') 'region matches as one value (1 Nov live run: a string reached [bool])'
Assert (-not (Get-FirstNetRegionCheck @('eastus') 'southafricanorth')) 'missing region fails'
Assert (-not (Get-FirstNetRegionCheck @() 'southafricanorth')) 'no regions fails'

# --- activation: SMS off -> pilot group only
$off = @{ state = 'disabled'; includeTargets = @(@{ targetType = 'group'; id = 'all_users'; isRegistrationRequired = $false; isUsableForSignIn = $true }); telecomProviderSettings = $null }
$a = Get-FirstNetActivation -Current $off -AppId $app -EndpointUrl $url -GroupId $group
Assert ($a.Mode -eq 'pilot-group' -and $a.Body.state -eq 'enabled') 'SMS off: enable it'
Assert (@($a.Body.includeTargets).Count -eq 1 -and $a.Body.includeTargets[0].id -eq $group) 'SMS off: pilot group only'
Assert ($a.Body.telecomProviderSettings.migrationPercentage -eq 100 -and -not $a.Body.telecomProviderSettings.isEvaluationModeEnabled) 'live, 100%'
Assert ((Get-FirstNetActivation -Current $off -AppId $app -EndpointUrl $url -GroupId $group -Evaluate).Body.telecomProviderSettings.isEvaluationModeEnabled) '-Evaluate sets evaluation mode'

# --- activation: SMS already in use -> never narrow it; require -Percent
$inUse = @{ state = 'enabled'; includeTargets = @(@{ targetType = 'group'; id = 'all_users' }); telecomProviderSettings = $null }
Assert-Throws { Get-FirstNetActivation -Current $inUse -AppId $app -EndpointUrl $url -GroupId $group } 'switch SMS off for everyone else.*-Percent'
$a = Get-FirstNetActivation -Current $inUse -AppId $app -EndpointUrl $url -Percent 5
Assert ($a.Mode -eq 'existing-targets' -and -not $a.Body.ContainsKey('includeTargets') -and -not $a.Body.ContainsKey('state')) 'existing targets untouched'
Assert ($a.Body.telecomProviderSettings.migrationPercentage -eq 5) '5% through FirstNet'
Assert ($a.Summary -match '1 February 2027.*100%') 'the plan tells them to reach 100% before Microsoft retires its SMS'

# --- another provider already configured: refuse
$other = @{ state = 'enabled'; includeTargets = @(@{ targetType = 'group'; id = $group }); telecomProviderSettings = @{ url = 'https://other.example/api/SendOtp'; appId = $app } }
Assert-Throws { Get-FirstNetActivation -Current $other -AppId $app -EndpointUrl $url -Percent 5 } 'another provider'
$same = @{ state = 'enabled'; includeTargets = @(@{ targetType = 'group'; id = $group }); telecomProviderSettings = @{ url = $url; appId = $app } }
Assert ((Get-FirstNetActivation -Current $same -AppId $app -EndpointUrl $url -Percent 50).Mode -eq 'existing-targets') 'rerun against our own provider is fine'

# --- expand
$live = @{ state = 'enabled'; includeTargets = @(@{ targetType = 'group'; id = $group }); telecomProviderSettings = @{ url = $url; appId = $app; isEvaluationModeEnabled = $true; migrationPercentage = 25 } }
Assert-Throws { Get-FirstNetExpansion -Current $off -Percent 50 } 'Run -Activate first'
Assert-Throws { Get-FirstNetExpansion -Current $live } 'Say what to widen'
$e = Get-FirstNetExpansion -Current $live -Percent 100
Assert ($e.telecomProviderSettings.migrationPercentage -eq 100 -and -not $e.telecomProviderSettings.isEvaluationModeEnabled -and -not $e.ContainsKey('includeTargets')) 'percent only'
$e = Get-FirstNetExpansion -Current $live -AllUsers
Assert ($e.includeTargets[0].id -eq 'all_users' -and $e.telecomProviderSettings.migrationPercentage -eq 25) 'all users keeps the percentage'

# --- rollback restores exactly the saved state, without read-only fields
$backup = @{
    '@odata.context' = 'x'; id = 'Sms'; state = 'disabled'; excludeTargets = @()
    includeTargets = @(@{ targetType = 'group'; id = 'all_users'; isRegistrationRequired = $false; isUsableForSignIn = $true; '@odata.type' = '#x' })
    telecomProviderSettings = $null
}
$rb = Get-FirstNetRollbackBody $backup
Assert ($rb.state -eq 'disabled' -and $null -eq $rb.telecomProviderSettings) 'state and provider restored'
Assert ($rb.includeTargets[0].Keys.Count -eq 4 -and -not $rb.ContainsKey('id')) 'only writable target fields'

Write-Host 'FirstNet enablement tests passed.' -ForegroundColor Green
