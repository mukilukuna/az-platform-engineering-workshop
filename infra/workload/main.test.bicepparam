using './main.bicep'

// ============================================================================
// Hotel Booking Workload — Test Environment Parameters
// ============================================================================
// This parameter file configures the workload infrastructure for TEST:
// - Scale-to-zero (min 0 replicas) for cost optimization
// - No zone redundancy (single AZ)
// - SQL Serverless with auto-pause (60 minutes)
// - Spoke VNet: 10.0.0.0/16
// ============================================================================

// Environment identity
param environmentName = 'test'
param workloadName = 'hotelbooking'
param location = 'swedencentral'
param regionShortName = 'swedencentral'
param regionCode = 'swc'

// ────────────────────────────────────────────────────────────────────────────
// Network Parameters (Deploy-Workload.ps1 retrieves these dynamically)
// Placeholders below — the deployment script resolves actual subscription IDs.
// ────────────────────────────────────────────────────────────────────────────
param spokeVnetId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-workload-test/providers/Microsoft.Network/virtualNetworks/vnet-workload-test'
param privateEndpointSubnetId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-workload-test/providers/Microsoft.Network/virtualNetworks/vnet-workload-test/subnets/snet-private-endpoints'
param containerAppsSubnetId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-workload-test/providers/Microsoft.Network/virtualNetworks/vnet-workload-test/subnets/snet-container-apps'
param hubVnetId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-platform/providers/Microsoft.Network/virtualNetworks/vnet-hub'

// Container Apps scaling (TEST: scale-to-zero for cost optimization)
param containerAppsMinReplicas = 0  // Scale to zero when idle
param containerAppsMaxReplicas = 10  // Match original test deployment
param containerAppsZoneRedundant = false  // Single AZ (cost optimization)

// SQL Database configuration (TEST: serverless with auto-pause)
param sqlDatabaseSku = 'Basic'  // Could also use 'GP_S_Gen5_1' for serverless
param sqlDatabaseName = 'hoteldb'
param sqlZoneRedundant = false  // No zone redundancy
param sqlAutoPauseDelayMinutes = 60  // Auto-pause after 1 hour idle

// SQL Private DNS zone (TEST: creates the zone)
param createSqlPrivateDnsZone = true

// Container images (placeholder until real images built)
param backendImageName = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
param frontendImageName = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

// Tags
param tags = {
  workload: 'hotelbooking'
  environment: 'test'
  managedBy: 'bicep'
}
