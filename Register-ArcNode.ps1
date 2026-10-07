<#
.SYNOPSIS
    Registers an Azure Local (build 2609 / 23H2) node into the Azure portal via
    Azure Arc, using the Arc initialization workflow.

.DESCRIPTION
    Run this ON the node in an elevated PowerShell session, after the OS is
    installed and the node has a working NIC and outbound internet connectivity.

    The script:
      1. Verifies it is elevated and the node can reach Azure.
      2. Installs the required PowerShell modules (Az.Accounts,
         Az.Resources, Az.ConnectedMachine, AzsHci.ARCinstaller).
      3. Registers the Azure resource providers needed by Azure Local.
      4. Interactively signs in to Azure and runs
         Invoke-AzStackHciArcInitialization to connect the node to Arc.

    After this completes, the node appears in the Azure portal and you can
    continue with cluster/deployment validation.

.PARAMETER SubscriptionId
    The Azure subscription GUID the node will register into.

.PARAMETER ResourceGroup
    The resource group that will hold the Arc machine resource. Created if
    it does not already exist (during initialization).

.PARAMETER TenantId
    The Azure Entra (AAD) tenant GUID.

.PARAMETER Region
    The Azure region for the Arc resources, e.g. 'eastus', 'westeurope',
    'australiaeast'. Must be a region supported by Azure Local.

.PARAMETER Cloud
    The Azure cloud environment. Defaults to 'AzureCloud'.

.PARAMETER ProxyServer
    Optional. HTTP(S) proxy URL (e.g. 'http://proxy.contoso.com:8080') if the
    node reaches the internet through a proxy.

.PARAMETER ApplicationId
    Optional. The app (client) ID of a service principal. When supplied, the
    script signs in non-interactively with the service principal instead of the
    interactive device-code flow. Use this on locked-down nodes where the
    device-code login is blocked (e.g. behind corporate proxy/TLS inspection).

.PARAMETER ClientSecret
    Optional. The service principal client secret as a SecureString. Required
    when -ApplicationId is supplied. If omitted, the script prompts for it
    securely at runtime.

.EXAMPLE
    .\Register-ArcNode.ps1 -SubscriptionId '00000000-0000-0000-0000-000000000000' `
        -ResourceGroup 'rg-azurelocal' `
        -TenantId '11111111-1111-1111-1111-111111111111' `
        -Region 'eastus'

.EXAMPLE
    .\Register-ArcNode.ps1 -SubscriptionId $sub -ResourceGroup 'rg-azurelocal' `
        -TenantId $tenant -Region 'westeurope' -ProxyServer 'http://10.0.0.5:8080'

.EXAMPLE
    # Non-interactive service principal sign-in (no device-code login):
    .\Register-ArcNode.ps1 -SubscriptionId $sub -ResourceGroup 'rg-azurelocal' `
        -TenantId $tenant -Region 'westus2' `
        -ApplicationId '22222222-2222-2222-2222-222222222222'

.NOTES
    Required outbound endpoints and the full Arc prerequisites are documented at:
    https://learn.microsoft.com/azure-stack/hci/deploy/deployment-arc-register-server-permissions
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Region,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Cloud = 'AzureCloud',

    [Parameter()]
    [string]$ProxyServer,

    [Parameter()]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$ApplicationId,

    [Parameter()]
    [securestring]$ClientSecret
)

$ErrorActionPreference = 'Stop'

function Assert-Administrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must be run from an elevated (Administrator) PowerShell session.'
    }
}

function Assert-AzureConnectivity {
    Write-Host 'Checking outbound connectivity to Azure...' -ForegroundColor Cyan
    if (-not (Test-Connection -ComputerName 'login.microsoftonline.com' -Count 1 -Quiet)) {
        Write-Warning 'Could not reach login.microsoftonline.com. If this node uses a proxy, pass -ProxyServer. Arc registration requires outbound internet access.'
    }
}

$requiredProviders = @(
    'Microsoft.HybridCompute'
    'Microsoft.GuestConfiguration'
    'Microsoft.HybridConnectivity'
    'Microsoft.AzureStackHCI'
)

Assert-Administrator
Assert-AzureConnectivity

# TLS 1.2 is required by the PowerShell Gallery.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host "`nInstalling required PowerShell modules..." -ForegroundColor Cyan
$modules = 'Az.Accounts', 'Az.Resources', 'Az.ConnectedMachine', 'AzsHci.ARCinstaller'
foreach ($module in $modules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Host "  Installing $module" -ForegroundColor Green
        Install-Module -Name $module -Force -AllowClobber -Repository PSGallery
    }
    else {
        Write-Host "  $module already present" -ForegroundColor DarkGray
    }
}

if ($ApplicationId) {
    Write-Host "`nSigning in to Azure (service principal)..." -ForegroundColor Cyan
    if (-not $ClientSecret) {
        $ClientSecret = Read-Host -AsSecureString -Prompt 'Enter the service principal client secret'
    }
    $spCredential = [System.Management.Automation.PSCredential]::new($ApplicationId, $ClientSecret)
    Connect-AzAccount -ServicePrincipal -Credential $spCredential -TenantId $TenantId -SubscriptionId $SubscriptionId
}
else {
    Write-Host "`nSigning in to Azure (device/interactive)..." -ForegroundColor Cyan
    Connect-AzAccount -SubscriptionId $SubscriptionId -TenantId $TenantId -UseDeviceAuthentication
}

Write-Host "`nRegistering required resource providers on the subscription..." -ForegroundColor Cyan
foreach ($provider in $requiredProviders) {
    Write-Host "  Registering $provider" -ForegroundColor Green
    Register-AzResourceProvider -ProviderNamespace $provider | Out-Null
}

# An ARM access token and the signed-in account ID are handed to the installer
# so it can register the node without a second interactive sign-in.
$armToken  = (Get-AzAccessToken).Token
$accountId = (Get-AzContext).Account.Id

Write-Host "`nRunning Arc initialization for this node..." -ForegroundColor Cyan
$arcArgs = @{
    SubscriptionID = $SubscriptionId
    ResourceGroup  = $ResourceGroup
    TenantID       = $TenantId
    Region         = $Region
    Cloud          = $Cloud
    ArmAccessToken = $armToken
    AccountID      = $accountId
}
if ($ProxyServer) {
    $arcArgs['ArcProxyOverride'] = $true
    $arcArgs['ArcProxy']         = $ProxyServer
}

Invoke-AzStackHciArcInitialization @arcArgs

Write-Host "`nDone. Check the Azure portal (resource group '$ResourceGroup') - the node should appear as an Arc-enabled machine. Continue with cluster deployment/validation once all nodes are registered." -ForegroundColor Yellow
