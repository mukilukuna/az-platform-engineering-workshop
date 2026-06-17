// ═══════════════════════════════════════════════════════════════════════════
// ACR Role Assignment Module
// ═══════════════════════════════════════════════════════════════════════════
// Purpose: Assign AcrPull role to a managed identity on a shared ACR
// Scope: Must be deployed at the same scope as the ACR (shared RG)

targetScope = 'resourceGroup'

@description('Resource ID of the Azure Container Registry')
param acrResourceId string

@description('Principal ID of the managed identity')
param principalId string

@description('Principal type')
@allowed(['ServicePrincipal', 'User', 'Group'])
param principalType string = 'ServicePrincipal'

// ───────────────────────────────────────────────────────────────────────────
// Resources
// ───────────────────────────────────────────────────────────────────────────

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: split(acrResourceId, '/')[8]
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acrResourceId, principalId, 'AcrPull')
  scope: acr
  properties: {
    principalId: principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')  // AcrPull
    principalType: principalType
  }
}

// ───────────────────────────────────────────────────────────────────────────
// Outputs
// ───────────────────────────────────────────────────────────────────────────

@description('Role assignment resource ID')
output roleAssignmentId string = roleAssignment.id
