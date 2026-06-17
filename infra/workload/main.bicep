targetScope = 'resourceGroup'

// ============================================================================
// Hotel Booking Workload Infrastructure — Multi-Environment
// ============================================================================
// This template deploys the complete workload infrastructure for test or prod:
// - User-assigned managed identities (runtime + CI/CD)
// - Azure Container Registry (public, workshop requirement)
// - Log Analytics + Application Insights (public, workshop requirement)
// - Azure SQL with private endpoint + Entra-only auth
// - Container Apps Environment with VNET integration
// - Backend container app (internal ingress)
// - Frontend container app (external ingress)
// - Private DNS zones (distributed model)
// - RBAC assignments (passwordless architecture)
//
// Environment-specific differences controlled via parameter files:
//   - main.test.bicepparam: scale-to-zero, no zone redundancy, serverless SQL
//   - main.prod.bicepparam: min 3 replicas, zone redundancy, provisioned SQL

// ============================================================================
// Parameters
// ============================================================================

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Environment token for naming (e.g., test, prod).')
@minLength(2)
@maxLength(10)
param environmentName string = 'test'

@description('Workload name for naming resources.')
@minLength(2)
@maxLength(15)
param workloadName string = 'hotelbooking'

@description('Region short name for globally unique resources.')
param regionShortName string = 'swedencentral'

@description('Region code for length-constrained resource names (3-4 chars max).')
@minLength(2)
@maxLength(4)
param regionCode string = 'swc'

@description('Resource ID of the spoke VNet.')
param spokeVnetId string

@description('Resource ID of the private endpoint subnet in the spoke.')
param privateEndpointSubnetId string

@description('Resource ID of the hub VNet for Private DNS zone linking.')
param hubVnetId string

@description('Resource ID of the Container Apps subnet (must be delegated to Microsoft.App/environments, /23 or larger).')
param containerAppsSubnetId string

@description('SQL Database SKU (Basic, S0, S1, etc.).')
param sqlDatabaseSku string = 'Basic'

@description('SQL Database name.')
param sqlDatabaseName string = 'hoteldb'

@description('Backend container image (e.g., crswedencentral001.azurecr.io/hotelbooking-backend:latest).')
param backendImageName string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('Frontend container image (e.g., crswedencentral001.azurecr.io/hotelbooking-frontend:latest).')
param frontendImageName string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('Minimum number of container replicas (test: 0 for scale-to-zero, prod: 3 for HA).')
@minValue(0)
@maxValue(30)
param containerAppsMinReplicas int = 0

@description('Maximum number of container replicas (test: 3, prod: 10).')
@minValue(1)
@maxValue(30)
param containerAppsMaxReplicas int = 10

@description('Enable zone redundancy for Container Apps Environment (test: false, prod: true).')
param containerAppsZoneRedundant bool = false

@description('Enable zone redundancy for SQL Database (test: false, prod: true).')
param sqlZoneRedundant bool = false

@description('SQL Database auto-pause delay in minutes for serverless SKUs (test: 60, prod: -1 to disable).')
param sqlAutoPauseDelayMinutes int = 60

@description('Create SQL Private DNS zone (true for test, false for prod to reference existing).')
param createSqlPrivateDnsZone bool = true

@description('Resource group name where SQL Private DNS zone exists (required if createSqlPrivateDnsZone is false).')
param sqlPrivateDnsZoneResourceGroupName string = resourceGroup().name

@description('Tags applied to all resources.')
param tags object = {
  workload: workloadName
  environment: environmentName
  managedBy: 'bicep'
}

// ============================================================================
// Variables
// ============================================================================

var resourceToken = '${workloadName}-${environmentName}-${regionShortName}'
var acrName = 'cr${regionShortName}${environmentName}001'  // Environment-specific: crswedencentraltest001, crswedencentralprod001
// Generate unique suffix for globally unique resources (SQL Server)
var uniqueSuffix = uniqueString(subscription().subscriptionId, resourceGroup().id)
var sqlServerName = 'sql-${resourceToken}-${uniqueSuffix}'

// ============================================================================
// Managed Identities
// ============================================================================

@description('Backend runtime managed identity')
module backendIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.5.0' = {
  name: 'backend-identity-deployment'
  params: {
    name: 'id-hotelapi-${environmentName}-${regionShortName}-001'
    location: location
    tags: tags
  }
}

@description('Frontend runtime managed identity')
module frontendIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.5.0' = {
  name: 'frontend-identity-deployment'
  params: {
    name: 'id-hotelspa-${environmentName}-${regionShortName}-001'
    location: location
    tags: tags
  }
}

@description('CI/CD deploy managed identity (for GitHub Actions OIDC)')
module deployIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.5.0' = {
  name: 'deploy-identity-deployment'
  params: {
    name: 'id-${workloadName}-deploy-${environmentName}-001'
    location: location
    tags: tags
  }
}

// ============================================================================
// Log Analytics Workspace (Public — workshop requirement)
// ============================================================================

module logAnalytics 'br/public:avm/res/operational-insights/workspace:0.11.0' = {
  name: 'loganalytics-deployment'
  params: {
    name: 'log-${resourceToken}-001'
    location: location
    tags: tags
    skuName: 'PerGB2018'
    dataRetention: 30
    // Public network access (workshop requirement — Monitor stack stays public)
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// ============================================================================
// Application Insights (Public — workshop requirement)
// ============================================================================

module appInsights 'br/public:avm/res/insights/component:0.4.2' = {
  name: 'appinsights-deployment'
  params: {
    name: 'appi-${resourceToken}-001'
    location: location
    tags: tags
    workspaceResourceId: logAnalytics.outputs.resourceId
    kind: 'web'
    applicationType: 'web'
    // Public network access (workshop requirement — Monitor stack stays public)
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// ============================================================================
// Azure Container Registry (Public — workshop requirement, per-environment)
// ============================================================================

module containerRegistry 'br/public:avm/res/container-registry/registry:0.9.0' = {
  name: 'acr-deployment'
  params: {
    name: acrName
    location: location
    tags: tags
    acrSku: 'Basic'
    // Admin user DISABLED (managed identity pull only)
    acrAdminUserEnabled: false
    // Public network access ENABLED (workshop requirement)
    // "Allow All Networks" — no ipRules, no virtualNetworkRules, no service-endpoint-only access
    publicNetworkAccess: 'Enabled'
    // Do NOT add networkRuleSet / networkAcls / ipRules — workshop requires unrestricted public access
    // Grant AcrPull to runtime identities (done via roleAssignments)
    roleAssignments: [
      {
        principalId: backendIdentity.outputs.principalId
        roleDefinitionIdOrName: 'AcrPull'
        principalType: 'ServicePrincipal'
      }
      {
        principalId: frontendIdentity.outputs.principalId
        roleDefinitionIdOrName: 'AcrPull'
        principalType: 'ServicePrincipal'
      }
    ]
  }
}

// ============================================================================
// Azure SQL Server + Database (Private endpoint, Entra-only auth)
// ============================================================================

module sqlServer 'br/public:avm/res/sql/server:0.10.0' = {
  name: 'sql-server-deployment'
  params: {
    name: sqlServerName
    location: location
    tags: tags
    // Entra admin = backend managed identity (declarative, no post-deploy scripts)
    administrators: {
      azureADOnlyAuthentication: true
      login: backendIdentity.outputs.name
      sid: backendIdentity.outputs.principalId
      principalType: 'Application'
      tenantId: tenant().tenantId
    }
    // Public network access DISABLED (private endpoint only)
    publicNetworkAccess: 'Disabled'
    // Databases
    databases: [
      {
        name: sqlDatabaseName
        sku: {
          name: sqlDatabaseSku
        }
        maxSizeBytes: 2147483648 // 2 GB
        autoPauseDelay: sqlAutoPauseDelayMinutes
        zoneRedundant: sqlZoneRedundant
      }
    ]
    // Private endpoint
    privateEndpoints: [
      {
        name: 'pep-sql-${workloadName}-${environmentName}-001'
        subnetResourceId: privateEndpointSubnetId
        privateDnsZoneGroup: {
          name: 'default'
          privateDnsZoneGroupConfigs: [
            {
              name: 'sqlServer'
              privateDnsZoneResourceId: sqlPrivateDnsZoneId
            }
          ]
        }
      }
    ]
  }
}

// ============================================================================
// Private DNS Zone for SQL (Distributed model — in workload RG, shared across environments)
// ============================================================================

// Reference existing SQL Private DNS zone (for prod) if not creating
resource existingSqlPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' existing = if (!createSqlPrivateDnsZone) {
  name: 'privatelink.database.windows.net'
  scope: resourceGroup(sqlPrivateDnsZoneResourceGroupName)
}

// Create new SQL Private DNS zone (for test) only if creating
module sqlPrivateDnsZone 'br/public:avm/res/network/private-dns-zone:0.7.0' = if (createSqlPrivateDnsZone) {
  name: 'sql-private-dns-zone-deployment'
  params: {
    name: 'privatelink.database.windows.net'
    tags: tags
    // Link to spoke VNet (registration)
    virtualNetworkLinks: [
      {
        name: 'link-to-spoke'
        virtualNetworkResourceId: spokeVnetId
        registrationEnabled: false
      }
      {
        name: 'link-to-hub'
        virtualNetworkResourceId: hubVnetId
        registrationEnabled: false
      }
    ]
  }
}

// Add VNet link for prod spoke to existing DNS zone (if not creating new zone)
module prodSqlDnsVnetLink './modules/dns-vnet-link.bicep' = if (!createSqlPrivateDnsZone) {
  name: 'prod-sql-dns-vnet-link-deployment'
  scope: resourceGroup(sqlPrivateDnsZoneResourceGroupName)
  params: {
    privateDnsZoneName: 'privatelink.database.windows.net'
    vnetLinkName: 'link-to-spoke-${environmentName}'
    vnetId: spokeVnetId
  }
}

// SQL Private DNS zone ID helper - use either created or existing
var sqlPrivateDnsZoneId = createSqlPrivateDnsZone ? sqlPrivateDnsZone.outputs.resourceId : existingSqlPrivateDnsZone.id

// ============================================================================
// Container Apps Environment
// ============================================================================

module containerAppsEnvironment 'br/public:avm/res/app/managed-environment:0.10.0' = {
  name: 'container-apps-environment-deployment'
  params: {
    name: 'cae-${resourceToken}-001'
    location: location
    tags: tags
    logAnalyticsWorkspaceResourceId: logAnalytics.outputs.resourceId
    // VNET integration (internal environment)
    internal: false // Set to false to allow external ingress for frontend
    infrastructureSubnetId: containerAppsSubnetId
    // Public network access enabled (frontend needs public ingress)
    publicNetworkAccess: 'Enabled'
    // Zone redundancy (test: disabled for cost, prod: enabled for HA)
    zoneRedundant: containerAppsZoneRedundant
    // Workload profiles (Consumption for scale-to-zero)
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

// ============================================================================
// Backend Container App (Internal ingress)
// ============================================================================

module backendContainerApp 'br/public:avm/res/app/container-app:0.12.0' = {
  name: 'backend-container-app-deployment'
  params: {
    name: 'ca-hotelapi-${environmentName}-${regionCode}-001'
    location: location
    tags: tags
    environmentResourceId: containerAppsEnvironment.outputs.resourceId

    // Managed identity
    managedIdentities: {
      userAssignedResourceIds: [
        backendIdentity.outputs.resourceId
      ]
    }

    // Container configuration
    containers: [
      {
        name: 'hotelapi'
        image: backendImageName
        resources: {
          cpu: json('0.5')
          memory: '1Gi'
        }
        env: [
          {
            name: 'ASPNETCORE_ENVIRONMENT'
            value: 'Production'
          }
          {
            name: 'ConnectionStrings__HotelDb'
            value: 'Server=tcp:${sqlServer.outputs.name}.${environment().suffixes.sqlServerHostname},1433;Database=${sqlDatabaseName};Authentication=Active Directory Default;Encrypt=True;'
          }
          {
            name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
            value: appInsights.outputs.connectionString
          }
          {
            name: 'AZURE_CLIENT_ID'
            value: backendIdentity.outputs.clientId
          }
        ]
      }
    ]

    // Ingress (internal only)
    ingressTargetPort: 8080
    ingressExternal: false
    ingressTransport: 'http'

    // Scale rules
    scaleMinReplicas: containerAppsMinReplicas
    scaleMaxReplicas: containerAppsMaxReplicas
    scaleRules: [
      {
        name: 'http-rule'
        http: {
          metadata: {
            concurrentRequests: '50'
          }
        }
      }
    ]

    // ACR pull with managed identity
    registries: [
      {
        server: containerRegistry.outputs.loginServer
        identity: backendIdentity.outputs.resourceId
      }
    ]

    // Workload profile
    workloadProfileName: 'Consumption'
  }
}

// ============================================================================
// Frontend Container App (External/Public ingress)
// ============================================================================

module frontendContainerApp 'br/public:avm/res/app/container-app:0.12.0' = {
  name: 'frontend-container-app-deployment'
  params: {
    name: 'ca-hotelspa-${environmentName}-${regionCode}-001'
    location: location
    tags: tags
    environmentResourceId: containerAppsEnvironment.outputs.resourceId

    // Managed identity
    managedIdentities: {
      userAssignedResourceIds: [
        frontendIdentity.outputs.resourceId
      ]
    }

    // Container configuration
    containers: [
      {
        name: 'hotelspa'
        image: frontendImageName
        resources: {
          cpu: json('0.25')
          memory: '0.5Gi'
        }
        env: [
          {
            name: 'BACKEND_URL'
            value: 'https://${backendContainerApp.outputs.fqdn}'
          }
        ]
      }
    ]

    // Ingress (external/public)
    ingressTargetPort: 80
    ingressExternal: true
    ingressTransport: 'http'
    ingressAllowInsecure: false

    // Scale rules
    scaleMinReplicas: containerAppsMinReplicas
    scaleMaxReplicas: containerAppsMaxReplicas
    scaleRules: [
      {
        name: 'http-rule'
        http: {
          metadata: {
            concurrentRequests: '100'
          }
        }
      }
    ]

    // ACR pull with managed identity
    registries: [
      {
        server: containerRegistry.outputs.loginServer
        identity: frontendIdentity.outputs.resourceId
      }
    ]

    // Workload profile
    workloadProfileName: 'Consumption'
  }
}

// ============================================================================
// Outputs
// ============================================================================

@description('Backend managed identity resource ID')
output backendIdentityResourceId string = backendIdentity.outputs.resourceId

@description('Backend managed identity principal ID')
output backendIdentityPrincipalId string = backendIdentity.outputs.principalId

@description('Backend managed identity client ID')
output backendIdentityClientId string = backendIdentity.outputs.clientId

@description('Frontend managed identity resource ID')
output frontendIdentityResourceId string = frontendIdentity.outputs.resourceId

@description('Frontend managed identity principal ID')
output frontendIdentityPrincipalId string = frontendIdentity.outputs.principalId

@description('Frontend managed identity client ID')
output frontendIdentityClientId string = frontendIdentity.outputs.clientId

@description('Deploy managed identity resource ID (for CI/CD)')
output deployIdentityResourceId string = deployIdentity.outputs.resourceId

@description('Deploy managed identity principal ID')
output deployIdentityPrincipalId string = deployIdentity.outputs.principalId

@description('Deploy managed identity client ID')
output deployIdentityClientId string = deployIdentity.outputs.clientId

@description('Log Analytics workspace ID')
output logAnalyticsWorkspaceId string = logAnalytics.outputs.resourceId

@description('Application Insights resource ID')
output appInsightsResourceId string = appInsights.outputs.resourceId

@description('Application Insights connection string')
output appInsightsConnectionString string = appInsights.outputs.connectionString

@description('Container Registry name')
output containerRegistryName string = containerRegistry.outputs.name

@description('Container Registry login server')
output containerRegistryLoginServer string = containerRegistry.outputs.loginServer

@description('SQL Server name')
output sqlServerName string = sqlServer.outputs.name

@description('SQL Server FQDN')
output sqlServerFqdn string = '${sqlServer.outputs.name}.${environment().suffixes.sqlServerHostname}'

@description('SQL Database name')
output sqlDatabaseName string = sqlDatabaseName

@description('Container Apps Environment name')
output containerAppsEnvironmentName string = containerAppsEnvironment.outputs.name

@description('Container Apps Environment resource ID')
output containerAppsEnvironmentResourceId string = containerAppsEnvironment.outputs.resourceId

@description('Backend container app name')
output backendContainerAppName string = backendContainerApp.outputs.name

@description('Backend container app FQDN')
output backendContainerAppFqdn string = backendContainerApp.outputs.fqdn

@description('Frontend container app name')
output frontendContainerAppName string = frontendContainerApp.outputs.name

@description('Frontend container app FQDN')
output frontendContainerAppFqdn string = frontendContainerApp.outputs.fqdn

@description('Frontend container app URL')
output frontendUrl string = 'https://${frontendContainerApp.outputs.fqdn}'
