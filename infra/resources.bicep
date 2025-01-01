@description('The location used for all deployed resources')
param location string = resourceGroup().location

@description('Tags that will be applied to all resources')
param tags object = {}


param nodeExists bool
@secure()
param nodeDefinition object
param pythonExists bool
@secure()
param pythonDefinition object
param nodeExists bool
@secure()
param nodeDefinition object
param pythonExists bool
@secure()
param pythonDefinition object

@description('Id of the user or app to assign application roles')
param principalId string

var abbrs = loadJsonContent('./abbreviations.json')
var resourceToken = uniqueString(subscription().id, resourceGroup().id, location)

// Monitor application with Azure Monitor
module monitoring 'br/public:avm/ptn/azd/monitoring:0.1.0' = {
  name: 'monitoring'
  params: {
    logAnalyticsName: '${abbrs.operationalInsightsWorkspaces}${resourceToken}'
    applicationInsightsName: '${abbrs.insightsComponents}${resourceToken}'
    applicationInsightsDashboardName: '${abbrs.portalDashboards}${resourceToken}'
    location: location
    tags: tags
  }
}

// Container registry
module containerRegistry 'br/public:avm/res/container-registry/registry:0.1.1' = {
  name: 'registry'
  params: {
    name: '${abbrs.containerRegistryRegistries}${resourceToken}'
    location: location
    acrAdminUserEnabled: true
    tags: tags
    publicNetworkAccess: 'Enabled'
    roleAssignments:[
      {
        principalId: nodeIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
      }
      {
        principalId: pythonIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
      }
      {
        principalId: nodeIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
      }
      {
        principalId: pythonIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
      }
    ]
  }
}

// Container apps environment
module containerAppsEnvironment 'br/public:avm/res/app/managed-environment:0.4.5' = {
  name: 'container-apps-environment'
  params: {
    logAnalyticsWorkspaceResourceId: monitoring.outputs.logAnalyticsWorkspaceResourceId
    name: '${abbrs.appManagedEnvironments}${resourceToken}'
    location: location
    zoneRedundant: false
  }
}

module nodeIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.2.1' = {
  name: 'nodeidentity'
  params: {
    name: '${abbrs.managedIdentityUserAssignedIdentities}node-${resourceToken}'
    location: location
  }
}

module nodeFetchLatestImage './modules/fetch-container-image.bicep' = {
  name: 'node-fetch-image'
  params: {
    exists: nodeExists
    name: 'node'
  }
}

var nodeAppSettingsArray = filter(array(nodeDefinition.settings), i => i.name != '')
var nodeSecrets = map(filter(nodeAppSettingsArray, i => i.?secret != null), i => {
  name: i.name
  value: i.value
  secretRef: i.?secretRef ?? take(replace(replace(toLower(i.name), '_', '-'), '.', '-'), 32)
})
var nodeEnv = map(filter(nodeAppSettingsArray, i => i.?secret == null), i => {
  name: i.name
  value: i.value
})

module node 'br/public:avm/res/app/container-app:0.8.0' = {
  name: 'node'
  params: {
    name: 'node'
    ingressTargetPort: 80
    scaleMinReplicas: 1
    scaleMaxReplicas: 10
    secrets: {
      secureList:  union([
      ],
      map(nodeSecrets, secret => {
        name: secret.secretRef
        value: secret.value
      }))
    }
    containers: [
      {
        image: nodeFetchLatestImage.outputs.?containers[?0].?image ?? 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
        name: 'main'
        resources: {
          cpu: json('0.5')
          memory: '1.0Gi'
        }
        env: union([
          {
            name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
            value: monitoring.outputs.applicationInsightsConnectionString
          }
          {
            name: 'AZURE_CLIENT_ID'
            value: nodeIdentity.outputs.clientId
          }
          {
            name: 'PORT'
            value: '80'
          }
        ],
        nodeEnv,
        map(nodeSecrets, secret => {
            name: secret.name
            secretRef: secret.secretRef
        }))
      }
    ]
    managedIdentities:{
      systemAssigned: false
      userAssignedResourceIds: [nodeIdentity.outputs.resourceId]
    }
    registries:[
      {
        server: containerRegistry.outputs.loginServer
        identity: nodeIdentity.outputs.resourceId
      }
    ]
    environmentResourceId: containerAppsEnvironment.outputs.resourceId
    location: location
    tags: union(tags, { 'azd-service-name': 'node' })
  }
}

module pythonIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.2.1' = {
  name: 'pythonidentity'
  params: {
    name: '${abbrs.managedIdentityUserAssignedIdentities}python-${resourceToken}'
    location: location
  }
}

module pythonFetchLatestImage './modules/fetch-container-image.bicep' = {
  name: 'python-fetch-image'
  params: {
    exists: pythonExists
    name: 'python'
  }
}

var pythonAppSettingsArray = filter(array(pythonDefinition.settings), i => i.name != '')
var pythonSecrets = map(filter(pythonAppSettingsArray, i => i.?secret != null), i => {
  name: i.name
  value: i.value
  secretRef: i.?secretRef ?? take(replace(replace(toLower(i.name), '_', '-'), '.', '-'), 32)
})
var pythonEnv = map(filter(pythonAppSettingsArray, i => i.?secret == null), i => {
  name: i.name
  value: i.value
})

module python 'br/public:avm/res/app/container-app:0.8.0' = {
  name: 'python'
  params: {
    name: 'python'
    ingressTargetPort: 80
    scaleMinReplicas: 1
    scaleMaxReplicas: 10
    secrets: {
      secureList:  union([
      ],
      map(pythonSecrets, secret => {
        name: secret.secretRef
        value: secret.value
      }))
    }
    containers: [
      {
        image: pythonFetchLatestImage.outputs.?containers[?0].?image ?? 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
        name: 'main'
        resources: {
          cpu: json('0.5')
          memory: '1.0Gi'
        }
        env: union([
          {
            name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
            value: monitoring.outputs.applicationInsightsConnectionString
          }
          {
            name: 'AZURE_CLIENT_ID'
            value: pythonIdentity.outputs.clientId
          }
          {
            name: 'PORT'
            value: '80'
          }
        ],
        pythonEnv,
        map(pythonSecrets, secret => {
            name: secret.name
            secretRef: secret.secretRef
        }))
      }
    ]
    managedIdentities:{
      systemAssigned: false
      userAssignedResourceIds: [pythonIdentity.outputs.resourceId]
    }
    registries:[
      {
        server: containerRegistry.outputs.loginServer
        identity: pythonIdentity.outputs.resourceId
      }
    ]
    environmentResourceId: containerAppsEnvironment.outputs.resourceId
    location: location
    tags: union(tags, { 'azd-service-name': 'python' })
  }
}

module nodeIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.2.1' = {
  name: 'nodeidentity'
  params: {
    name: '${abbrs.managedIdentityUserAssignedIdentities}node-${resourceToken}'
    location: location
  }
}

module nodeFetchLatestImage './modules/fetch-container-image.bicep' = {
  name: 'node-fetch-image'
  params: {
    exists: nodeExists
    name: 'node'
  }
}

var nodeAppSettingsArray = filter(array(nodeDefinition.settings), i => i.name != '')
var nodeSecrets = map(filter(nodeAppSettingsArray, i => i.?secret != null), i => {
  name: i.name
  value: i.value
  secretRef: i.?secretRef ?? take(replace(replace(toLower(i.name), '_', '-'), '.', '-'), 32)
})
var nodeEnv = map(filter(nodeAppSettingsArray, i => i.?secret == null), i => {
  name: i.name
  value: i.value
})

module node 'br/public:avm/res/app/container-app:0.8.0' = {
  name: 'node'
  params: {
    name: 'node'
    ingressTargetPort: 80
    scaleMinReplicas: 1
    scaleMaxReplicas: 10
    secrets: {
      secureList:  union([
      ],
      map(nodeSecrets, secret => {
        name: secret.secretRef
        value: secret.value
      }))
    }
    containers: [
      {
        image: nodeFetchLatestImage.outputs.?containers[?0].?image ?? 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
        name: 'main'
        resources: {
          cpu: json('0.5')
          memory: '1.0Gi'
        }
        env: union([
          {
            name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
            value: monitoring.outputs.applicationInsightsConnectionString
          }
          {
            name: 'AZURE_CLIENT_ID'
            value: nodeIdentity.outputs.clientId
          }
          {
            name: 'PORT'
            value: '80'
          }
        ],
        nodeEnv,
        map(nodeSecrets, secret => {
            name: secret.name
            secretRef: secret.secretRef
        }))
      }
    ]
    managedIdentities:{
      systemAssigned: false
      userAssignedResourceIds: [nodeIdentity.outputs.resourceId]
    }
    registries:[
      {
        server: containerRegistry.outputs.loginServer
        identity: nodeIdentity.outputs.resourceId
      }
    ]
    environmentResourceId: containerAppsEnvironment.outputs.resourceId
    location: location
    tags: union(tags, { 'azd-service-name': 'node' })
  }
}

module pythonIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.2.1' = {
  name: 'pythonidentity'
  params: {
    name: '${abbrs.managedIdentityUserAssignedIdentities}python-${resourceToken}'
    location: location
  }
}

module pythonFetchLatestImage './modules/fetch-container-image.bicep' = {
  name: 'python-fetch-image'
  params: {
    exists: pythonExists
    name: 'python'
  }
}

var pythonAppSettingsArray = filter(array(pythonDefinition.settings), i => i.name != '')
var pythonSecrets = map(filter(pythonAppSettingsArray, i => i.?secret != null), i => {
  name: i.name
  value: i.value
  secretRef: i.?secretRef ?? take(replace(replace(toLower(i.name), '_', '-'), '.', '-'), 32)
})
var pythonEnv = map(filter(pythonAppSettingsArray, i => i.?secret == null), i => {
  name: i.name
  value: i.value
})

module python 'br/public:avm/res/app/container-app:0.8.0' = {
  name: 'python'
  params: {
    name: 'python'
    ingressTargetPort: 80
    scaleMinReplicas: 1
    scaleMaxReplicas: 10
    secrets: {
      secureList:  union([
      ],
      map(pythonSecrets, secret => {
        name: secret.secretRef
        value: secret.value
      }))
    }
    containers: [
      {
        image: pythonFetchLatestImage.outputs.?containers[?0].?image ?? 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
        name: 'main'
        resources: {
          cpu: json('0.5')
          memory: '1.0Gi'
        }
        env: union([
          {
            name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
            value: monitoring.outputs.applicationInsightsConnectionString
          }
          {
            name: 'AZURE_CLIENT_ID'
            value: pythonIdentity.outputs.clientId
          }
          {
            name: 'PORT'
            value: '80'
          }
        ],
        pythonEnv,
        map(pythonSecrets, secret => {
            name: secret.name
            secretRef: secret.secretRef
        }))
      }
    ]
    managedIdentities:{
      systemAssigned: false
      userAssignedResourceIds: [pythonIdentity.outputs.resourceId]
    }
    registries:[
      {
        server: containerRegistry.outputs.loginServer
        identity: pythonIdentity.outputs.resourceId
      }
    ]
    environmentResourceId: containerAppsEnvironment.outputs.resourceId
    location: location
    tags: union(tags, { 'azd-service-name': 'python' })
  }
}
// Create a keyvault to store secrets
module keyVault 'br/public:avm/res/key-vault/vault:0.6.1' = {
  name: 'keyvault'
  params: {
    name: '${abbrs.keyVaultVaults}${resourceToken}'
    location: location
    tags: tags
    enableRbacAuthorization: false
    accessPolicies: [
      {
        objectId: principalId
        permissions: {
          secrets: [ 'get', 'list' ]
        }
      }
      {
        objectId: nodeIdentity.outputs.principalId
        permissions: {
          secrets: [ 'get', 'list' ]
        }
      }
      {
        objectId: pythonIdentity.outputs.principalId
        permissions: {
          secrets: [ 'get', 'list' ]
        }
      }
      {
        objectId: nodeIdentity.outputs.principalId
        permissions: {
          secrets: [ 'get', 'list' ]
        }
      }
      {
        objectId: pythonIdentity.outputs.principalId
        permissions: {
          secrets: [ 'get', 'list' ]
        }
      }
    ]
    secrets: [
    ]
  }
}
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = containerRegistry.outputs.loginServer
output AZURE_KEY_VAULT_ENDPOINT string = keyVault.outputs.uri
output AZURE_KEY_VAULT_NAME string = keyVault.outputs.name
output AZURE_RESOURCE_NODE_ID string = node.outputs.resourceId
output AZURE_RESOURCE_PYTHON_ID string = python.outputs.resourceId
output AZURE_RESOURCE_NODE_ID string = node.outputs.resourceId
output AZURE_RESOURCE_PYTHON_ID string = python.outputs.resourceId
