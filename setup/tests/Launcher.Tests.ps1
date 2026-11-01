#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$setupDirectory = Split-Path -Parent $PSScriptRoot
$launcher = Join-Path $setupDirectory 'Setup-Epp.ps1'
$state = @{
    Revision = 'a' * 40
    Repository = 'Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample'
    Requests = [Collections.Generic.List[string]]::new()
}
$requiredAssets = @(
    'support/Epp.Setup.psm1', 'support/Epp.Packages.ps1', 'support/Epp.Graph.ps1'
    'providers/catalog.json', 'packages/catalog.json', 'infra/main.bicep', 'infra/resources.bicep'
    'providers/telesign.json', 'providers/soprano.json', 'providers/infobip.json', 'providers/firstnet.json'
)

function Assert($Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Throws([scriptblock] $Action, [string] $Pattern) {
    try { $null = & $Action }
    catch {
        Assert ($_.Exception.Message -match $Pattern) "Unexpected failure: $($_.Exception.Message)"
        return
    }
    throw "Expected failure matching '$Pattern'."
}
function Reset-TestState {
    $state.Requests.Clear()
    $state.Lookups = 0; $state.Imports = 0; $state.Unloads = 0
    $state.AssetDirectory = ''; $state.SetupArguments = $null
    $state.Catalog = $null; $state.FailDownload = ''; $state.EmptyDownload = ''
    $state.SetupError = ''
}
function Invoke-RestMethod {
    param($Uri, $Headers, $TimeoutSec)
    Assert ($Uri -ceq "https://api.github.com/repos/$($state.Repository)/commits/review-probe") "Unexpected API request: $Uri"
    $state.Lookups++
    return @{ sha = $state.Revision }
}
function Invoke-WebRequest {
    param($Uri, $OutFile, $TimeoutSec, $MaximumRedirection)
    $prefix = "https://raw.githubusercontent.com/$($state.Repository)/$($state.Revision)/setup/"
    Assert ($Uri.StartsWith($prefix, [StringComparison]::Ordinal)) 'Pin every download to the same resolved commit.'
    Assert ($MaximumRedirection -eq 0) 'Do not follow setup asset redirects.'
    $relative = $Uri.Substring($prefix.Length)
    Assert ($requiredAssets -ccontains $relative) "Unexpected asset request: $relative"
    $state.Requests.Add($relative)
    if ($relative -ceq 'support/Epp.Setup.psm1') {
        $state.AssetDirectory = Split-Path -Parent (Split-Path -Parent $OutFile)
    }
    if ($relative -ceq $state.FailDownload) { throw 'offline-download-failure' }
    if ($relative -ceq $state.EmptyDownload) {
        [IO.File]::WriteAllText($OutFile, '')
    }
    elseif ($relative -ceq 'providers/catalog.json' -and $null -ne $state.Catalog) {
        $state.Catalog | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutFile -Encoding utf8NoBOM
    }
    else {
        Copy-Item -LiteralPath (Join-Path $setupDirectory $relative) -Destination $OutFile
    }
}
function Import-Module {
    param($Name, [switch] $PassThru, [switch] $Force)
    $state.Imports++
    Assert ($Name -ceq (Join-Path $state.AssetDirectory 'support/Epp.Setup.psm1')) 'Import only the downloaded setup helper.'
    foreach ($asset in $requiredAssets) {
        Assert (Test-Path -LiteralPath (Join-Path $state.AssetDirectory $asset)) "Missing launcher asset: $asset"
    }
    return [pscustomobject]@{ Name = 'OfflineSetupProbe' }
}
function Remove-Module {
    param($ModuleInfo, $ErrorAction)
    Assert ($ModuleInfo.Name -ceq 'OfflineSetupProbe') 'Only unload the temporary setup helper.'
    $state.Unloads++
}
function Invoke-EppSetup {
    [CmdletBinding()]
    param(
        $TenantId, $SubscriptionId, $ApplicationId, $Provider, $OutputDirectory,
        $SourceRepository, $AssetDirectory, $SourceBaseUri, [switch] $PassThru
    )
    $state.SetupArguments = @{} + $PSBoundParameters
    Assert ($SourceRepository -ceq $state.Repository -and $AssetDirectory -ceq $state.AssetDirectory) 'Preserve the selected source repository and downloaded assets.'
    Assert ($SourceBaseUri -ceq "https://raw.githubusercontent.com/$($state.Repository)/$($state.Revision)/setup") 'Forward the resolved commit to the helper.'
    if ($state.SetupError) { throw $state.SetupError }
    if ($PassThru) { return [pscustomobject]@{ Marker = 'completed' } }
}
function Assert-Cleanup {
    Assert (-not (Test-Path -LiteralPath $state.AssetDirectory)) 'Remove temporary assets on success or failure.'
    Assert ($state.Unloads -eq $state.Imports) 'Unload the helper whenever it was imported.'
}

$parameters = @{
    TenantId = '11111111-1111-1111-1111-111111111111'
    SubscriptionId = '22222222-2222-2222-2222-222222222222'
    ApplicationId = '33333333-3333-3333-3333-333333333333'
}
try {
    foreach ($repository in @('Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample', 'unit/epp-fork')) {
        $state.Repository = $repository
        Reset-TestState
        $result = & $launcher @parameters -SourceRepository $repository -SourceRef review-probe -Provider Telesign -PassThru
        Assert ($result.Marker -ceq 'completed' -and $state.SetupArguments.PassThru) 'Forward PassThru and return the helper result.'
        foreach ($name in $parameters.Keys) {
            Assert ($state.SetupArguments[$name] -ceq $parameters[$name]) "Forward $name unchanged."
        }
        Assert ($state.SetupArguments.Provider -ceq 'Telesign') 'Do not overwrite the supplied provider while downloading profiles.'
        Assert ($state.Lookups -eq 1 -and $state.Requests.Count -eq $requiredAssets.Count) 'Resolve the branch once and download every required asset.'
        Assert-Cleanup

        Reset-TestState
        $result = & $launcher @parameters -SourceRepository $repository -SourceRef $state.Revision
        Assert ($null -eq $result -and -not $state.SetupArguments.ContainsKey('Provider')) 'Preserve omitted provider selection without emitting a default result.'
        Assert ($state.Lookups -eq 0 -and $state.Requests.Count -eq $requiredAssets.Count) 'Skip commit lookup for a pinned revision without skipping provider profiles.'
        Assert-Cleanup
    }

    foreach ($files in @(@('../escape.json'), @('Telesign.json'), @('telesign.json', 'telesign.json'))) {
        Reset-TestState
        $state.Catalog = @{
            schemaVersion = 1
            providers = @($files | ForEach-Object { @{ file = $_ } })
        }
        Assert-Throws {
            & $launcher @parameters -SourceRepository $state.Repository -SourceRef $state.Revision
        } 'invalid or duplicate file'
        Assert ($state.Imports -eq 0) 'Reject invalid catalog filenames before importing executable helpers.'
        Assert-Cleanup
    }
    foreach ($failure in @('download', 'empty', 'setup')) {
        Reset-TestState
        switch ($failure) {
            download { $state.FailDownload = 'support/Epp.Graph.ps1'; $pattern = 'offline-download-failure' }
            empty { $state.EmptyDownload = 'providers/soprano.json'; $pattern = 'empty file' }
            setup { $state.SetupError = 'offline-setup-failure'; $pattern = 'offline-setup-failure' }
        }
        Assert-Throws {
            & $launcher @parameters -SourceRepository $state.Repository -SourceRef $state.Revision
        } $pattern
        Assert ($state.Imports -eq $(if ($failure -eq 'setup') { 1 } else { 0 })) 'Do not invoke setup after an incomplete download.'
        Assert-Cleanup
    }
    Write-Host 'Launcher pinned downloads, provider profiles, argument forwarding, PassThru, catalog guards, and cleanup checks passed.'
}
finally {
    if ($state.AssetDirectory -and (Test-Path -LiteralPath $state.AssetDirectory)) {
        Remove-Item -LiteralPath $state.AssetDirectory -Recurse -Force
    }
}
