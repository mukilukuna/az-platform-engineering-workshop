<#
.SYNOPSIS
    Build and deploy Hotel Booking container images to Azure Container Apps.

.DESCRIPTION
    This script builds both backend and frontend container images using Azure Container Registry
    build (server-side), tags them with the Git SHA and 'latest', and updates the Container Apps
    to use the new images. The script is idempotent and can be run multiple times safely.

.PARAMETER WorkloadResourceGroupName
    Name of the resource group containing the workload infrastructure.
    Default: rg-hotelbooking-test-swedencentral-001

.PARAMETER EnvironmentName
    Environment name (e.g., 'test', 'prod'). Default: test

.PARAMETER SkipBuild
    Skip the image build step and only update Container Apps with existing images.

.EXAMPLE
    ./Deploy-Images.ps1
    Builds and deploys both images with default parameters.

.EXAMPLE
    ./Deploy-Images.ps1 -SkipBuild
    Updates Container Apps with existing images without rebuilding.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$WorkloadResourceGroupName = 'rg-hotelbooking-test-swedencentral-001',

    [Parameter()]
    [string]$EnvironmentName = 'test',

    [Parameter()]
    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Change to repository root
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $RepoRoot

# Script configuration
$BackendImageName = 'hotelbooking-backend'
$FrontendImageName = 'hotelbooking-frontend'
$BackendDockerfilePath = 'workload-app/backend/HotelBooking.Api'
$FrontendDockerfilePath = 'workload-app/frontend'

Write-Host '===================================================================' -ForegroundColor Cyan
Write-Host ' Hotel Booking - Container Image Build & Deployment' -ForegroundColor Cyan
Write-Host '===================================================================' -ForegroundColor Cyan
Write-Host ''

# Check if az CLI is installed
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error 'Azure CLI (az) is not installed or not in PATH. Please install it first.'
}

# Verify subscription
Write-Host 'Using subscription:' -ForegroundColor Yellow
az account show --query '[name]' --output table
Write-Host ''

# Step 1: Retrieve deployment outputs
Write-Host 'Step 1: Retrieving Infrastructure Outputs' -ForegroundColor Yellow
Write-Host '-------------------------------------------------------------------' -ForegroundColor Gray

$DeploymentName = az deployment group list `
    --resource-group $WorkloadResourceGroupName `
    --query "[?starts_with(name, 'workload-')].name | sort(@) | [-1]" `
    --output tsv

if (-not $DeploymentName) {
    Write-Error "No workload deployment found in resource group '$WorkloadResourceGroupName'"
}

Write-Host "  Latest deployment: $DeploymentName" -ForegroundColor Gray

# Get outputs from deployment
$Outputs = az deployment group show `
    --name $DeploymentName `
    --resource-group $WorkloadResourceGroupName `
    --query 'properties.outputs' `
    --output json | ConvertFrom-Json

$AcrName = $Outputs.containerRegistryName.value
$AcrLoginServer = $Outputs.containerRegistryLoginServer.value
$BackendAppName = $Outputs.backendContainerAppName.value
$FrontendAppName = $Outputs.frontendContainerAppName.value
$BackendFqdn = $Outputs.backendContainerAppFqdn.value

Write-Host "  Container Registry: $AcrName ($AcrLoginServer)" -ForegroundColor Gray
Write-Host "  Backend App: $BackendAppName" -ForegroundColor Gray
Write-Host "  Frontend App: $FrontendAppName" -ForegroundColor Gray
Write-Host "✓ Retrieved infrastructure outputs" -ForegroundColor Green
Write-Host ''

# Step 2: Get Git SHA for tagging
Write-Host 'Step 2: Determining Image Tag' -ForegroundColor Yellow
Write-Host '-------------------------------------------------------------------' -ForegroundColor Gray

if (Test-Path .git) {
    $GitSha = git rev-parse --short HEAD 2>$null
    if (-not $GitSha) {
        Write-Warning 'Failed to get Git SHA, using timestamp instead'
        $GitSha = Get-Date -Format 'yyyyMMddHHmmss'
    }
} else {
    Write-Warning 'Not a Git repository, using timestamp for tag'
    $GitSha = Get-Date -Format 'yyyyMMddHHmmss'
}

Write-Host "  Image tag: $GitSha" -ForegroundColor Gray
Write-Host "✓ Determined image tag" -ForegroundColor Green
Write-Host ''

# Step 3: Build images (if not skipped)
if ($SkipBuild) {
    Write-Host 'Step 3: Build Images' -ForegroundColor Yellow
    Write-Host '-------------------------------------------------------------------' -ForegroundColor Gray
    Write-Host '⊘ Skipping build (SkipBuild flag set)' -ForegroundColor Yellow
    Write-Host ''
} else {
    Write-Host 'Step 3: Build Images' -ForegroundColor Yellow
    Write-Host '-------------------------------------------------------------------' -ForegroundColor Gray
    
    # Build backend image
    Write-Host "Building backend image ($BackendImageName)..." -ForegroundColor Cyan
    $BackendImageTag = "$AcrLoginServer/${BackendImageName}:$GitSha"
    $BackendImageLatest = "$AcrLoginServer/${BackendImageName}:latest"
    
    az acr build `
        --registry $AcrName `
        --image "${BackendImageName}:$GitSha" `
        --image "${BackendImageName}:latest" `
        --file "$BackendDockerfilePath/Dockerfile" `
        $BackendDockerfilePath
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Backend image build failed with exit code $LASTEXITCODE"
    }
    
    Write-Host "✓ Built backend image: $BackendImageTag" -ForegroundColor Green
    Write-Host ''
    
    # Build frontend image
    Write-Host "Building frontend image ($FrontendImageName)..." -ForegroundColor Cyan
    $FrontendImageTag = "$AcrLoginServer/${FrontendImageName}:$GitSha"
    $FrontendImageLatest = "$AcrLoginServer/${FrontendImageName}:latest"
    
    az acr build `
        --registry $AcrName `
        --image "${FrontendImageName}:$GitSha" `
        --image "${FrontendImageName}:latest" `
        --file "$FrontendDockerfilePath/Dockerfile" `
        $FrontendDockerfilePath
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Frontend image build failed with exit code $LASTEXITCODE"
    }
    
    Write-Host "✓ Built frontend image: $FrontendImageTag" -ForegroundColor Green
    Write-Host ''
}

# Step 4: Update Container Apps
Write-Host 'Step 4: Update Container Apps' -ForegroundColor Yellow
Write-Host '-------------------------------------------------------------------' -ForegroundColor Gray

# Construct full image references
$BackendImageRef = "$AcrLoginServer/${BackendImageName}:$GitSha"
$FrontendImageRef = "$AcrLoginServer/${FrontendImageName}:$GitSha"

# Update backend container app
Write-Host "Updating backend container app ($BackendAppName)..." -ForegroundColor Cyan
az containerapp update `
    --name $BackendAppName `
    --resource-group $WorkloadResourceGroupName `
    --image $BackendImageRef `
    --output none

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to update backend container app"
}

Write-Host "✓ Updated backend to: $BackendImageRef" -ForegroundColor Green
Write-Host ''

# Update frontend container app with backend URL
Write-Host "Updating frontend container app ($FrontendAppName)..." -ForegroundColor Cyan

# Backend URL for nginx proxy (internal FQDN with https://)
$BackendUrl = "https://$BackendFqdn"

az containerapp update `
    --name $FrontendAppName `
    --resource-group $WorkloadResourceGroupName `
    --image $FrontendImageRef `
    --set-env-vars "BACKEND_URL=$BackendUrl" `
    --output none

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to update frontend container app"
}

Write-Host "✓ Updated frontend to: $FrontendImageRef" -ForegroundColor Green
Write-Host "  Backend URL: $BackendUrl" -ForegroundColor Gray
Write-Host ''

# Step 5: Verify deployment
Write-Host 'Step 5: Verify Deployment' -ForegroundColor Yellow
Write-Host '-------------------------------------------------------------------' -ForegroundColor Gray

Write-Host 'Waiting for Container Apps to stabilize (30 seconds)...' -ForegroundColor Gray
Start-Sleep -Seconds 30

$FrontendUrl = $Outputs.frontendUrl.value

Write-Host ''
Write-Host '===================================================================' -ForegroundColor Cyan
Write-Host ' Deployment Complete!' -ForegroundColor Cyan
Write-Host '===================================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host '📦 Deployed Images:' -ForegroundColor Yellow
Write-Host "  Backend:  $BackendImageRef" -ForegroundColor Gray
Write-Host "  Frontend: $FrontendImageRef" -ForegroundColor Gray
Write-Host ''
Write-Host '🔗 Application URLs:' -ForegroundColor Yellow
Write-Host "  Frontend: $FrontendUrl" -ForegroundColor Gray
Write-Host "  Backend:  https://$BackendFqdn (internal only)" -ForegroundColor Gray
Write-Host ''
Write-Host '✅ Next Steps:' -ForegroundColor Yellow
Write-Host '  1. Open the frontend URL in your browser' -ForegroundColor Gray
Write-Host "  2. Test the API: curl $FrontendUrl/api/hotels" -ForegroundColor Gray
Write-Host '  3. Create a booking through the UI' -ForegroundColor Gray
Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
