targetScope = 'resourceGroup'

@description('Azure region for the spoke resources.')
param location string = resourceGroup().location

@description('Name of the spoke virtual network.')
param spokeVnetName string = 'vnet-workload-test'

@description('Address space for the spoke VNet (must not overlap with hub).')
param spokeVnetAddressPrefix string = '10.0.0.0/16'

@description('Resource ID of the hub virtual network to peer with.')
param hubVnetId string

@description('Tags applied to all resources.')
param tags object = {
  workload: 'hotelbooking'
  environment: 'test'
  role: 'spoke'
}

// Dynamic subnet calculation: Extract first two octets from address prefix
// Example: '10.0.0.0/16' -> '10.0', '10.1.0.0/16' -> '10.1'
var vnetOctets = split(split(spokeVnetAddressPrefix, '/')[0], '.')
var subnetPrefix = '${vnetOctets[0]}.${vnetOctets[1]}'

// Subnet layout (dynamic based on address prefix):
//   snet-private-endpoints  {prefix}.0.0/24   - subnet for private endpoints
//   snet-container-apps     {prefix}.2.0/23   - subnet for Container Apps Environment (delegated, /23 minimum)
//   ({prefix}.4.0/22 - {prefix}.255.0/24 reserved for future app/data subnets)

module spokeVnet 'br/public:avm/res/network/virtual-network:0.7.2' = {
  name: 'spoke-vnet-deployment'
  params: {
    name: spokeVnetName
    location: location
    tags: tags
    addressPrefixes: [
      spokeVnetAddressPrefix
    ]
    subnets: [
      {
        name: 'snet-private-endpoints'
        addressPrefix: '${subnetPrefix}.0.0/24'
      }
      {
        name: 'snet-container-apps'
        addressPrefix: '${subnetPrefix}.2.0/23'
        delegation: 'Microsoft.App/environments'
      }
    ]
    peerings: [
      {
        name: 'peer-spoke-to-hub'
        remoteVirtualNetworkResourceId: hubVnetId
        allowForwardedTraffic: true
        allowGatewayTransit: false
        allowVirtualNetworkAccess: true
        useRemoteGateways: false
        remotePeeringEnabled: true
        remotePeeringName: 'peer-hub-to-${spokeVnetName}'
        remotePeeringAllowForwardedTraffic: true
        remotePeeringAllowGatewayTransit: false
        remotePeeringAllowVirtualNetworkAccess: true
        remotePeeringUseRemoteGateways: false
      }
    ]
  }
}

output spokeVnetId string = spokeVnet.outputs.resourceId
output spokeVnetName string = spokeVnet.outputs.name
output spokeVnetAddressSpace string = spokeVnetAddressPrefix
output privateEndpointsSubnetId string = spokeVnet.outputs.subnetResourceIds[0]
output containerAppsSubnetId string = spokeVnet.outputs.subnetResourceIds[1]
