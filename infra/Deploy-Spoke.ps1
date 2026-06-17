#requires -Version 7.0
<#
.SYNOPSIS
    Deploys the workload spoke VNet and peers it to the hub (multi-environment).

.DESCRIPTION
    Creates (or updates) the environment-specific workload resource group and deploys 
    spoke.bicep into it using the Azure CLI. Automatically retrieves the hub VNet ID 
    from the platform resource group and creates bidirectional peering.
    
    Supports multiple environments with non-overlapping address spaces:
    - test: 10.0.0.0/16
    - prod: 10.1.0.0/16
    
    Run from PowerShell 7+ with az CLI already logged in (`az login`) and the correct
    subscription selected (`az account set`).

.PARAMETER Environment
    Target environment: 'test' or 'prod'

.EXAMPLE
    .\Deploy-Spoke.ps1 -Environment test
    
.EXAMPLE
    .\Deploy-Spoke.ps1 -Environment prod -Location swedencentral
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('test', 'prod')]
    [string]$Environment,
    
    [string]$HubResourceGroupName = 'rg-platform',
    [string]$Location = 'swedencentral',
    [string]$DeploymentName = "spoke-$(Get-Date -Format 'yyyyMMddHHmmss')"
)

$ErrorActionPreference = 'Stop'

# Environment-specific configuration
$WorkloadResourceGroupName = "rg-workload-$Environment"
$VNetName = "vnet-workload-$Environment"

# Address space per environment (non-overlapping)
$AddressSpace = switch ($Environment) {
    'test' { '10.0.0.0/16' }
    'prod' { '10.1.0.0/16' }
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$templateFile = Join-Path $scriptRoot 'spoke.bicep'

Write-Host '===================================================================' -ForegroundColor Cyan
Write-Host " Deploying Workload Spoke — $($Environment.ToUpper()) Environment" -ForegroundColor Cyan
Write-Host '===================================================================' -ForegroundColor Cyan
Write-Host ''

Write-Host "Using subscription:" -ForegroundColor Cyan
az account show --query '{name:name, id:id}' -o table
Write-Host ''

Write-Host "Retrieving hub VNet information from '$HubResourceGroupName'..." -ForegroundColor Cyan
$hubVnetId = az network vnet list `
    --resource-group $HubResourceGroupName `
    --query "[?name=='vnet-hub'].id | [0]" `
    --output tsv

if ([string]::IsNullOrWhiteSpace($hubVnetId)) {
    throw "Hub VNet 'vnet-hub' not found in resource group '$HubResourceGroupName'. Deploy the hub first using mock-alz/Deploy-Hub.ps1"
}

Write-Host "  Hub VNet ID: $hubVnetId" -ForegroundColor Gray

Write-Host "Ensuring workload resource group '$WorkloadResourceGroupName' exists in '$Location'..." -ForegroundColor Cyan
az group create --name $WorkloadResourceGroupName --location $Location --output none

Write-Host "Deploying spoke VNet '$VNetName' ($AddressSpace) with bidirectional peering ($DeploymentName)..." -ForegroundColor Cyan
az deployment group create `
    --resource-group $WorkloadResourceGroupName `
    --name $DeploymentName `
    --template-file $templateFile `
    --parameters location=$Location hubVnetId=$hubVnetId spokeVnetName=$VNetName spokeVnetAddressPrefix=$AddressSpace `
    --output table

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
Write-Host 'Verify peering:' -ForegroundColor Cyan
Write-Host "  az network vnet peering list --resource-group $WorkloadResourceGroupName --vnet-name $VNetName --output table" -ForegroundColor Gray
Write-Host "  az network vnet peering list --resource-group $HubResourceGroupName --vnet-name vnet-hub --output table" -ForegroundColor Gray
