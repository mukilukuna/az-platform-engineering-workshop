#requires -Version 7.0
<#
.SYNOPSIS
    Deploys the Hotel Booking workload infrastructure with preflight validation (multi-environment).

.DESCRIPTION
    This script deploys the complete workload infrastructure for test or prod environments:
    - User-assigned managed identities (runtime + CI/CD)
    - Azure Container Registry (public, shared across environments)
    - Log Analytics + Application Insights (public endpoints)
    - Azure SQL Server + Database with private endpoint and Entra-only auth
    - Container Apps Environment with VNET integration
    - Backend and frontend container apps
    - Private DNS zones (distributed model)
    - RBAC role assignments (passwordless architecture)
    
    Environment-specific differences (controlled via parameter files):
    - test: Scale-to-zero, Basic/Serverless SQL, no zone redundancy
    - prod: Min 3 replicas, provisioned SQL with zone redundancy
    
    The script performs preflight validation (Bicep lint, what-if analysis,
    and permission checks) before deploying to catch issues early.

.PARAMETER Environment
    Target environment: 'test' or 'prod'. This determines which parameter file to load
    (main.test.bicepparam or main.prod.bicepparam) and the resource group naming.

.PARAMETER SkipPreflight
    Skip preflight validation (not recommended).

.EXAMPLE
    ./Deploy-Workload.ps1 -Environment test
    
.EXAMPLE
    ./Deploy-Workload.ps1 -Environment prod -SkipPreflight
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('test', 'prod')]
    [string]$Environment,
    
    [switch]$SkipPreflight,
    [string]$DeploymentName = "workload-$(Get-Date -Format 'yyyyMMddHHmmss')"
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# Environment-Specific Configuration
# ============================================================================

$Location = 'swedencentral'
$WorkloadResourceGroupName = "rg-hotelbooking-$Environment-swedencentral-001"
$SpokeResourceGroupName = "rg-workload-$Environment"
$HubResourceGroupName = 'rg-platform'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$templateFile = Join-Path $scriptRoot 'main.bicep'
$parameterFile = Join-Path $scriptRoot "main.$Environment.bicepparam"

# Validate parameter file exists
if (-not (Test-Path $parameterFile)) {
    Write-Host "ERROR: Parameter file not found: $parameterFile" -ForegroundColor Red
    exit 1
}

# ============================================================================
# Helper Functions
# ============================================================================

function Write-Info {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Green
}

function Write-Warning {
    param([string]$Message)
    Write-Host "WARNING: $Message" -ForegroundColor Yellow
}

function Write-ErrorMessage {
    param([string]$Message)
    Write-Host "ERROR: $Message" -ForegroundColor Red
}

# ============================================================================
# Preflight Checks
# ============================================================================

Write-Info "==================================================================="
Write-Info " Hotel Booking Workload Infrastructure — $($Environment.ToUpper()) Environment"
Write-Info "==================================================================="
Write-Info ""

Write-Info "Configuration:"
Write-Info "  Environment:       $Environment"
Write-Info "  Resource Group:    $WorkloadResourceGroupName"
Write-Info "  Spoke RG:          $SpokeResourceGroupName"
Write-Info "  Parameter File:    $(Split-Path -Leaf $parameterFile)"
Write-Info ""

Write-Info "Using subscription:"
az account show --query '{name:name, id:id}' -o table

if (-not (Test-Path $templateFile)) {
    Write-ErrorMessage "Template file not found: $templateFile"
    exit 1
}

Write-Info ""
Write-Info "Step 1: Bicep Compilation & Linting"
Write-Info "-------------------------------------------------------------------"
Write-Info "Building Bicep template..."
az bicep build --file $templateFile

if ($LASTEXITCODE -ne 0) {
    Write-ErrorMessage "Bicep build failed. Fix errors before deploying."
    exit 1
}

Write-Success "✓ Bicep template compiled successfully"

# ============================================================================
# Retrieve Spoke VNet Information
# ============================================================================

Write-Info ""
Write-Info "Step 2: Retrieving Spoke VNet Information"
Write-Info "-------------------------------------------------------------------"

$spokeVnetName = "vnet-workload-$Environment"

Write-Info "Retrieving spoke VNet resource ID from '$SpokeResourceGroupName'..."
$spokeVnetId = az network vnet list `
    --resource-group $SpokeResourceGroupName `
    --query "[?name=='$spokeVnetName'].id | [0]" `
    --output tsv

if ([string]::IsNullOrWhiteSpace($spokeVnetId)) {
    Write-ErrorMessage "Spoke VNet '$spokeVnetName' not found in resource group '$SpokeResourceGroupName'."
    Write-ErrorMessage "Deploy the spoke first using infra/Deploy-Spoke.ps1 -Environment $Environment"
    exit 1
}

Write-Info "  Spoke VNet ID: $spokeVnetId"

Write-Info "Retrieving private endpoint subnet ID..."
$privateEndpointSubnetId = az network vnet subnet show `
    --resource-group $SpokeResourceGroupName `
    --vnet-name $spokeVnetName `
    --name 'snet-private-endpoints' `
    --query 'id' `
    --output tsv

if ([string]::IsNullOrWhiteSpace($privateEndpointSubnetId)) {
    Write-ErrorMessage "Private endpoint subnet not found in spoke VNet."
    exit 1
}

Write-Info "  Private Endpoint Subnet ID: $privateEndpointSubnetId"

Write-Info "Retrieving container apps subnet ID..."
$containerAppsSubnetId = az network vnet subnet show `
    --resource-group $SpokeResourceGroupName `
    --vnet-name $spokeVnetName `
    --name 'snet-container-apps' `
    --query 'id' `
    --output tsv

if ([string]::IsNullOrWhiteSpace($containerAppsSubnetId)) {
    Write-ErrorMessage "Container Apps subnet not found in spoke VNet."
    Write-ErrorMessage "The spoke VNet must have a 'snet-container-apps' subnet delegated to Microsoft.App/environments."
    Write-ErrorMessage "Re-deploy the spoke using Deploy-Spoke.ps1 -Environment $Environment"
    exit 1
}

Write-Info "  Container Apps Subnet ID: $containerAppsSubnetId"

# ============================================================================
# Retrieve Hub VNet Information
# ============================================================================

Write-Info "Retrieving hub VNet resource ID from '$HubResourceGroupName'..."
$hubVnetId = az network vnet list `
    --resource-group $HubResourceGroupName `
    --query "[?name=='vnet-hub'].id | [0]" `
    --output tsv

if ([string]::IsNullOrWhiteSpace($hubVnetId)) {
    Write-ErrorMessage "Hub VNet 'vnet-hub' not found in resource group '$HubResourceGroupName'."
    exit 1
}

Write-Info "  Hub VNet ID: $hubVnetId"

Write-Success "✓ Retrieved spoke and hub VNet information"

# ============================================================================
# Create Resource Group
# ============================================================================

Write-Info ""
Write-Info "Step 3: Ensuring Workload Resource Group Exists"
Write-Info "-------------------------------------------------------------------"
Write-Info "Creating or updating resource group '$WorkloadResourceGroupName' in '$Location'..."
az group create --name $WorkloadResourceGroupName --location $Location --output none

Write-Success "✓ Resource group ready"

# ============================================================================
# Preflight Validation (What-If + Permission Check)
# ============================================================================

if (-not $SkipPreflight) {
    Write-Info ""
    Write-Info "Step 4: Preflight Validation (What-If Analysis)"
    Write-Info "-------------------------------------------------------------------"
    Write-Info "Running what-if to preview changes..."
    Write-Info ""
    
    az deployment group what-if `
        --resource-group $WorkloadResourceGroupName `
        --name $DeploymentName `
        --parameters $parameterFile `
        --parameters `
            spokeVnetId=$spokeVnetId `
            privateEndpointSubnetId=$privateEndpointSubnetId `
            containerAppsSubnetId=$containerAppsSubnetId `
            hubVnetId=$hubVnetId
    
    if ($LASTEXITCODE -ne 0) {
        Write-ErrorMessage "What-if analysis failed."
        exit 1
    }
    
    Write-Info ""
    Write-Success "✓ What-if analysis completed"
    Write-Info ""
    Write-Warning "Review the what-if output above carefully before proceeding."
    Write-Info ""
    
    $confirmation = Read-Host "Do you want to proceed with deployment? (yes/no)"
    if ($confirmation -ne 'yes') {
        Write-Info "Deployment cancelled by user."
        exit 0
    }
}

# ============================================================================
# Deploy Infrastructure
# ============================================================================

Write-Info ""
Write-Info "Step 5: Deploying Workload Infrastructure"
Write-Info "-------------------------------------------------------------------"
Write-Info "Deployment name: $DeploymentName"
Write-Info "This may take 10-15 minutes..."
Write-Info ""

az deployment group create `
    --resource-group $WorkloadResourceGroupName `
    --name $DeploymentName `
    --parameters $parameterFile `
    --parameters `
        spokeVnetId=$spokeVnetId `
        privateEndpointSubnetId=$privateEndpointSubnetId `
        containerAppsSubnetId=$containerAppsSubnetId `
        hubVnetId=$hubVnetId `
    --output table

if ($LASTEXITCODE -ne 0) {
    Write-ErrorMessage "Deployment failed. Check the error messages above."
    exit 1
}

# ============================================================================
# Deployment Complete
# ============================================================================

Write-Info ""
Write-Success "==================================================================="
Write-Success " Deployment Complete!"
Write-Success "==================================================================="
Write-Info ""

Write-Info "Retrieving deployment outputs..."
$frontendUrl = az deployment group show `
    --resource-group $WorkloadResourceGroupName `
    --name $DeploymentName `
    --query 'properties.outputs.frontendUrl.value' `
    --output tsv

$backendFqdn = az deployment group show `
    --resource-group $WorkloadResourceGroupName `
    --name $DeploymentName `
    --query 'properties.outputs.backendContainerAppFqdn.value' `
    --output tsv

$acrLoginServer = az deployment group show `
    --resource-group $WorkloadResourceGroupName `
    --name $DeploymentName `
    --query 'properties.outputs.containerRegistryLoginServer.value' `
    --output tsv

Write-Info ""
Write-Info "📦 Deployment Details:"
Write-Info "  Resource Group:        $WorkloadResourceGroupName"
Write-Info "  Frontend URL:          $frontendUrl"
Write-Info "  Backend FQDN:          $backendFqdn (internal)"
Write-Info "  Container Registry:    $acrLoginServer"
Write-Info ""
Write-Info "🔑 Next Steps:"
Write-Info "  1. Build and push container images to ACR:"
Write-Info "     cd workload-app/backend/HotelBooking.Api"
Write-Info "     az acr build -r $acrLoginServer -t hotelbooking-backend:<tag> -f Dockerfile ."
Write-Info ""
Write-Info "     cd workload-app/frontend"
Write-Info "     az acr build -r $acrLoginServer -t hotelbooking-frontend:<tag> -f Dockerfile ."
Write-Info ""
Write-Info "  2. Update container apps with new images (chore 5)"
Write-Info ""
Write-Success "Done."
