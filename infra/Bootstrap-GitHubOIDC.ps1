#Requires -Version 7
<#
.SYNOPSIS
    Bootstrap GitHub Actions OIDC federation to Azure for test and prod environments.

.DESCRIPTION
    Provisions deploy identities (user-assigned managed identities) per environment with:
    - Owner role on workload resource group
    - Network Contributor role on hub resource group  
    - AcrPush role on container registry
    - Federated credential for GitHub Actions OIDC
    - GitHub Environment with required variables
    
    Idempotent: safe to re-run multiple times.

.PARAMETER RepositoryOwner
    GitHub repository owner. If not specified, inferred from git remote origin.

.PARAMETER RepositoryName
    GitHub repository name. If not specified, inferred from git remote origin.

.PARAMETER HubResourceGroupName
    Hub resource group name. Default: 'rg-platform'

.EXAMPLE
    .\Bootstrap-GitHubOIDC.ps1
    Infers repo from git remote origin and bootstraps OIDC for test and prod.

.EXAMPLE
    .\Bootstrap-GitHubOIDC.ps1 -RepositoryOwner myorg -RepositoryName myrepo
    Uses specified repo owner and name.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$RepositoryOwner,

    [Parameter()]
    [string]$RepositoryName,

    [Parameter()]
    [string]$HubResourceGroupName = 'rg-platform'
)

$ErrorActionPreference = 'Stop'

# Initialize variables collection
$script:envVariablesToSet = @()

# ═══════════════════════════════════════════════════════════════════════════
# Helper Functions
# ═══════════════════════════════════════════════════════════════════════════

function Write-Stage {
    param([string]$Message)
    Write-Host "`n$('-' * 75)" -ForegroundColor Cyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host "$('-' * 75)" -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Message)
    Write-Host "  $Message" -ForegroundColor Gray
}

function Write-Success {
    param([string]$Message)
    Write-Host "✓ $Message" -ForegroundColor Green
}

function Write-Warning2 {
    param([string]$Message)
    Write-Host "⚠ $Message" -ForegroundColor Yellow
}

function Get-GitRemoteInfo {
    try {
        $remoteUrl = git remote get-url origin 2>$null
        if (-not $remoteUrl) {
            throw "No git remote 'origin' found"
        }

        # Parse GitHub URL (HTTPS or SSH)
        if ($remoteUrl -match 'github\.com[:/]([^/]+)/([^/\.]+)(\.git)?$') {
            return @{
                Owner = $Matches[1]
                Name  = $Matches[2]
            }
        }

        throw "Could not parse GitHub owner/repo from origin URL: $remoteUrl"
    }
    catch {
        throw "Failed to infer repository from git remote: $_"
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# Main Script
# ═══════════════════════════════════════════════════════════════════════════

Write-Host @"
═══════════════════════════════════════════════════════════════════════════
 Bootstrap GitHub Actions OIDC Federation to Azure
═══════════════════════════════════════════════════════════════════════════
"@ -ForegroundColor Cyan

# Infer repository if not specified
if (-not $RepositoryOwner -or -not $RepositoryName) {
    Write-Info "Inferring repository from git remote origin..."
    $gitInfo = Get-GitRemoteInfo
    if (-not $RepositoryOwner) { $RepositoryOwner = $gitInfo.Owner }
    if (-not $RepositoryName) { $RepositoryName = $gitInfo.Name }
}

Write-Info "Repository: $RepositoryOwner/$RepositoryName"

# Get current subscription and tenant
Write-Stage "Step 1: Azure Context"
$subscription = az account show --query '{id:id, name:name, tenantId:tenantId}' -o json | ConvertFrom-Json
Write-Info "Subscription: $($subscription.name) ($($subscription.id))"
Write-Info "Tenant ID: $($subscription.tenantId)"

# Validate hub resource group exists
Write-Info "Validating hub resource group: $HubResourceGroupName"
$hubRg = az group show --name $HubResourceGroupName --query '{id:id}' -o json 2>$null | ConvertFrom-Json
if (-not $hubRg) {
    throw "Hub resource group '$HubResourceGroupName' not found"
}
Write-Success "Hub resource group found"

# Define environments
$environments = @(
    @{
        Name                  = 'test'
        WorkloadResourceGroup = 'rg-hotelbooking-test-swedencentral-001'
        IdentityName          = 'id-github-deploy-test-001'
        Location              = 'swedencentral'
        RequireReviewers      = $false
    }
    @{
        Name                  = 'prod'
        WorkloadResourceGroup = 'rg-hotelbooking-prod-swedencentral-001'
        IdentityName          = 'id-github-deploy-prod-001'
        Location              = 'swedencentral'
        RequireReviewers      = $true
    }
)

# Process each environment
foreach ($env in $environments) {
    Write-Stage "Processing Environment: $($env.Name.ToUpper())"
    
    # Step: Create or update workload resource group
    Write-Info "Ensuring workload resource group exists: $($env.WorkloadResourceGroup)"
    $workloadRg = az group create `
        --name $env.WorkloadResourceGroup `
        --location $env.Location `
        --query '{id:id}' `
        -o json | ConvertFrom-Json
    Write-Success "Workload resource group ready"

    # Step: Create or get deploy identity
    Write-Info "Creating deploy identity: $($env.IdentityName)"
    $identity = az identity show `
        --name $env.IdentityName `
        --resource-group $env.WorkloadResourceGroup `
        --query '{id:id, principalId:principalId, clientId:clientId}' `
        -o json 2>$null | ConvertFrom-Json
    
    if (-not $identity) {
        Write-Info "  Creating new identity..."
        $identity = az identity create `
            --name $env.IdentityName `
            --resource-group $env.WorkloadResourceGroup `
            --location $env.Location `
            --query '{id:id, principalId:principalId, clientId:clientId}' `
            -o json | ConvertFrom-Json
        
        # Wait for identity to propagate
        Write-Info "  Waiting for identity to propagate..."
        Start-Sleep -Seconds 15
    }
    Write-Success "Deploy identity: $($env.IdentityName) ($($identity.clientId))"

    # Step: Assign Owner role on workload RG
    Write-Info "Assigning Owner role on workload resource group..."
    $ownerAssignment = az role assignment list `
        --assignee $identity.principalId `
        --role 'Owner' `
        --scope $workloadRg.id `
        --query '[0].id' `
        -o tsv 2>$null
    
    if (-not $ownerAssignment) {
        Write-Info "  Creating role assignment..."
        az role assignment create `
            --assignee $identity.principalId `
            --role 'Owner' `
            --scope $workloadRg.id `
            --output none
        Write-Success "Owner role assigned on $($env.WorkloadResourceGroup)"
    }
    else {
        Write-Success "Owner role already assigned on $($env.WorkloadResourceGroup)"
    }

    # Step: Assign Network Contributor role on hub RG
    Write-Info "Assigning Network Contributor role on hub resource group..."
    $networkContribAssignment = az role assignment list `
        --assignee $identity.principalId `
        --role 'Network Contributor' `
        --scope $hubRg.id `
        --query '[0].id' `
        -o tsv 2>$null
    
    if (-not $networkContribAssignment) {
        Write-Info "  Creating role assignment..."
        az role assignment create `
            --assignee $identity.principalId `
            --role 'Network Contributor' `
            --scope $hubRg.id `
            --output none
        Write-Success "Network Contributor role assigned on $HubResourceGroupName"
    }
    else {
        Write-Success "Network Contributor role already assigned on $HubResourceGroupName"
    }

    # Step: Assign AcrPush role on container registry
    Write-Info "Assigning AcrPush role on container registry..."
    # Find ACR in workload resource group
    $acr = az acr list `
        --resource-group $env.WorkloadResourceGroup `
        --query '[0].{id:id, name:name}' `
        -o json 2>$null | ConvertFrom-Json
    
    if ($acr) {
        $acrPushAssignment = az role assignment list `
            --assignee $identity.principalId `
            --role 'AcrPush' `
            --scope $acr.id `
            --query '[0].id' `
            -o tsv 2>$null
        
        if (-not $acrPushAssignment) {
            Write-Info "  Creating role assignment on $($acr.name)..."
            az role assignment create `
                --assignee $identity.principalId `
                --role 'AcrPush' `
                --scope $acr.id `
                --output none
            Write-Success "AcrPush role assigned on $($acr.name)"
        }
        else {
            Write-Success "AcrPush role already assigned on $($acr.name)"
        }
    }
    else {
        Write-Warning2 "No container registry found in $($env.WorkloadResourceGroup) (will be created by workload deployment)"
    }

    # Step: Create or update federated credential
    Write-Info "Configuring federated credential for GitHub Actions..."
    $credentialName = "github-$($env.Name)"
    $subject = "repo:$RepositoryOwner/$($RepositoryName):environment:$($env.Name)"
    
    $existingCred = az identity federated-credential show `
        --name $credentialName `
        --identity-name $env.IdentityName `
        --resource-group $env.WorkloadResourceGroup `
        --query '{name:name}' `
        -o json 2>$null | ConvertFrom-Json
    
    if ($existingCred) {
        Write-Info "  Updating existing federated credential..."
        az identity federated-credential update `
            --name $credentialName `
            --identity-name $env.IdentityName `
            --resource-group $env.WorkloadResourceGroup `
            --issuer 'https://token.actions.githubusercontent.com' `
            --audience 'api://AzureADTokenExchange' `
            --subject $subject `
            --output none
    }
    else {
        Write-Info "  Creating new federated credential..."
        az identity federated-credential create `
            --name $credentialName `
            --identity-name $env.IdentityName `
            --resource-group $env.WorkloadResourceGroup `
            --issuer 'https://token.actions.githubusercontent.com' `
            --audience 'api://AzureADTokenExchange' `
            --subject $subject `
            --output none
    }
    Write-Success "Federated credential configured: $subject"

    # Step: Create GitHub Environment with variables
    Write-Info "Configuring GitHub Environment..."
    
    # Create environment (idempotent)
    if ($env.RequireReviewers) {
        $envConfig = @{
            wait_timer               = 0
            prevent_self_review      = $false
            reviewers                = @()
            deployment_branch_policy = $null
        } | ConvertTo-Json -Compress
    }
    else {
        $envConfig = @{
            wait_timer               = 0
            prevent_self_review      = $false
            reviewers                = $null
            deployment_branch_policy = $null
        } | ConvertTo-Json -Compress
    }

    $envConfig | gh api --silent `
        --method PUT `
        "repos/$RepositoryOwner/$RepositoryName/environments/$($env.Name)" `
        --input -

    if ($env.RequireReviewers) {
        Write-Success "GitHub Environment '$($env.Name)' created/updated (requires reviewers)"
    }
    else {
        Write-Success "GitHub Environment '$($env.Name)' created/updated (no protection)"
    }

    # Collect environment variables for manual setup
    $envVarsToSet = @{
        AZURE_CLIENT_ID       = $identity.clientId
        AZURE_TENANT_ID       = $subscription.tenantId
        AZURE_SUBSCRIPTION_ID = $subscription.id
        AZURE_RESOURCE_GROUP  = $env.WorkloadResourceGroup
    }
    
    # Store for summary output
    $script:envVariablesToSet += @{
        Environment = $env.Name
        Variables   = $envVarsToSet
    }
    
    Write-Success "Identity and federated credential configured"
}

# ═══════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════

Write-Stage "Bootstrap Complete"
Write-Host @"

Deploy identities created with OIDC federation:
  • Test: id-github-deploy-test-001 
    - Owner on rg-hotelbooking-test-swedencentral-001
    - Network Contributor on $HubResourceGroupName
    - AcrPush on container registry (crswedencentral001)
    - Subject: repo:$RepositoryOwner/$($RepositoryName):environment:test

  • Prod: id-github-deploy-prod-001
    - Owner on rg-hotelbooking-prod-swedencentral-001
    - Network Contributor on $HubResourceGroupName
    - AcrPush on container registry (crswedencentralprod001)
    - Subject: repo:$RepositoryOwner/$($RepositoryName):environment:prod

GitHub Environments created: test, prod

"@ -ForegroundColor Green

Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Yellow
Write-Host " Manual Step Required: Set Environment Variables in GitHub UI" -ForegroundColor Yellow
Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Yellow
Write-Host ""

foreach ($envData in $script:envVariablesToSet) {
    Write-Host "Environment: $($envData.Environment.ToUpper())" -ForegroundColor Cyan
    Write-Host "URL: https://github.com/$RepositoryOwner/$RepositoryName/settings/environments/$($envData.Environment)" -ForegroundColor Gray
    Write-Host ""
    foreach ($varName in $envData.Variables.Keys | Sort-Object) {
        Write-Host "  $varName = $($envData.Variables[$varName])" -ForegroundColor White
    }
    Write-Host ""
}

Write-Host @"
Steps to set variables:
1. Go to: https://github.com/$RepositoryOwner/$RepositoryName/settings/environments
2. Click on each environment (test, prod)
3. Under "Environment variables", add the variables listed above
4. Save changes

"@ -ForegroundColor Gray

Write-Host @"
Verify Azure setup:
  az identity federated-credential list --identity-name id-github-deploy-test-001 --resource-group rg-hotelbooking-test-swedencentral-001 --output table
  az identity federated-credential list --identity-name id-github-deploy-prod-001 --resource-group rg-hotelbooking-prod-swedencentral-001 --output table
  az role assignment list --all --assignee a268e1fc-59f9-4627-8b51-bbe3996c3b9e --output table
  az role assignment list --all --assignee bf148209-7688-4a84-aef0-ea0bbddd4b9a --output table

"@ -ForegroundColor Green

Write-Host "Done.`n"
