// ═══════════════════════════════════════════════════════════════════════════
// Shared Infrastructure Template
// ═══════════════════════════════════════════════════════════════════════════
// Purpose: Deploy shared resources used by both test and prod environments
// Lifecycle: Deployed once, updated rarely, referenced by all environments

targetScope = 'resourceGroup'

// ───────────────────────────────────────────────────────────────────────────
// Parameters
// ───────────────────────────────────────────────────────────────────────────

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Short region name (max 13 chars for ACR naming)')
@maxLength(13)
param regionShortName string = 'swedencentral'

@description('Workload name for resource naming')
param workloadName string = 'hotelbooking'

@description('Tags for all resources')
param tags object = {
  workload: 'hotelbooking'
  'managed-by': 'bicep'
  environment: 'shared'
}

// ───────────────────────────────────────────────────────────────────────────
// Variables
// ───────────────────────────────────────────────────────────────────────────

var acrName = 'cr${replace(regionShortName, '-', '')}shared001'

// ───────────────────────────────────────────────────────────────────────────
// Modules - Shared Container Registry
// ───────────────────────────────────────────────────────────────────────────

module acr 'br/public:avm/res/container-registry/registry:0.9.0' = {
  name: '${deployment().name}-acr'
  params: {
    name: acrName
    location: location
    acrSku: 'Basic'
    acrAdminUserEnabled: false
    publicNetworkAccess: 'Enabled' // Required per workload-network-exposure.instructions.md
    tags: tags
  }
}

// ───────────────────────────────────────────────────────────────────────────
// Outputs
// ───────────────────────────────────────────────────────────────────────────

@description('Shared ACR resource ID')
output acrResourceId string = acr.outputs.resourceId

@description('Shared ACR login server')
output acrLoginServer string = acr.outputs.loginServer

@description('Shared ACR name')
output acrName string = acr.outputs.name
