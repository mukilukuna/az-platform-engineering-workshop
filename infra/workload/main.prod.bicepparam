using './main.bicep'

// ============================================================================
// Hotel Booking Workload — Production Environment Parameters
// ============================================================================
// This parameter file configures the workload infrastructure for PROD:
// - Always-on (min 3 replicas) for high availability
// - Zone redundancy enabled (multi-AZ for 99.99% SLA)
// - SQL Provisioned with no auto-pause (always-on)
// - Spoke VNet: 10.1.0.0/16 (non-overlapping with test)
// ============================================================================

// Environment identity
param environmentName = 'prod'
param workloadName = 'hotelbooking'
param location = 'swedencentral'
param regionShortName = 'swedencentral'
param regionCode = 'swc'

// ────────────────────────────────────────────────────────────────────────────
// Network Parameters (Deploy-Workload.ps1 retrieves these dynamically)
// Placeholders below — the deployment script resolves actual subscription IDs.
// ────────────────────────────────────────────────────────────────────────────
param spokeVnetId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-workload-prod/providers/Microsoft.Network/virtualNetworks/vnet-workload-prod'
param privateEndpointSubnetId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-workload-prod/providers/Microsoft.Network/virtualNetworks/vnet-workload-prod/subnets/snet-private-endpoints'
param containerAppsSubnetId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-workload-prod/providers/Microsoft.Network/virtualNetworks/vnet-workload-prod/subnets/snet-container-apps'
param hubVnetId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-platform/providers/Microsoft.Network/virtualNetworks/vnet-hub'

// Container Apps scaling (PROD: always-on with zone redundancy)
param containerAppsMinReplicas = 3  // Always-on, minimum 3 for zone spread
param containerAppsMaxReplicas = 10  // Production scale limit
param containerAppsZoneRedundant = true  // Multi-AZ for 99.99% SLA

// SQL Database configuration (PROD: provisioned with zone redundancy)
param sqlDatabaseSku = 'GP_Gen5_2'  // General Purpose provisioned, 2 vCores
param sqlDatabaseName = 'hoteldb'
param sqlZoneRedundant = true  // Zone-redundant for high availability
param sqlAutoPauseDelayMinutes = -1  // Disabled for provisioned SKU

// SQL Private DNS zone (PROD: references existing zone from test)
param createSqlPrivateDnsZone = false
param sqlPrivateDnsZoneResourceGroupName = 'rg-hotelbooking-test-swedencentral-001'

// Container images (placeholder until real images built)
// NOTE: Update these with real image references after build
param backendImageName = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
param frontendImageName = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

// Tags
param tags = {
  workload: 'hotelbooking'
  environment: 'prod'
  managedBy: 'bicep'
}
