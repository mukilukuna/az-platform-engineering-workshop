targetScope = 'resourceGroup'

// ============================================================================
// Private DNS Zone VNet Link Module
// ============================================================================
// Simple module to add a VNet link to an existing Private DNS zone
// Used for prod to link to the test-owned SQL Private DNS zone

@description('Name of the existing Private DNS zone')
param privateDnsZoneName string

@description('Name for the VNet link')
param vnetLinkName string

@description('Resource ID of the VNet to link')
param vnetId string

// ============================================================================
// Resources
// ============================================================================

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' existing = {
  name: privateDnsZoneName
}

resource vnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: vnetLinkName
  location: 'global'
  properties: {
    virtualNetwork: {
      id: vnetId
    }
    registrationEnabled: false
  }
}

// ============================================================================
// Outputs
// ============================================================================

@description('Resource ID of the VNet link')
output resourceId string = vnetLink.id

@description('Name of the VNet link')
output name string = vnetLink.name
