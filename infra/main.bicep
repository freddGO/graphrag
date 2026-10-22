// GraphRAG on Azure Container Apps.
//
//   Azure OpenAI (chat + embeddings) <---+
//   Blob Storage (index output, cache) <-+-- user-assigned managed identity
//   Container Registry (image) <---------+        |
//                                           +-----+------+
//                                           | Container  |  Job: graphrag index -> blob
//                                           | Apps env   |  App: FastAPI /query (scale to zero)
//                                           +------------+
//
// No keys: every service call authenticates with the managed identity.

@description('Location for all resources.')
param location string = resourceGroup().location

@description('Container image. The first deploy uses a public placeholder until the real image is built.')
param image string = 'mcr.microsoft.com/k8se/quickstart:latest'

@secure()
@description('Shared secret clients must send in the X-API-Key header.')
param apiKey string

param chatModel string = 'gpt-4.1-mini'
param chatModelVersion string = '2025-04-14'
param chatSku string = 'GlobalStandard'
@description('Chat capacity in thousands of tokens per minute.')
param chatCapacity int = 200

param embeddingModel string = 'text-embedding-3-small'
param embeddingModelVersion string = '1'
param embeddingSku string = 'GlobalStandard'
param embeddingCapacity int = 200

param openAiApiVersion string = '2024-10-21'

@description('0 = scale to zero when idle (cheapest; first request after idle is slow).')
param minReplicas int = 0

var suffix = uniqueString(resourceGroup().id)
var usesRegistry = !startsWith(image, 'mcr.microsoft.com/')

var roles = {
  acrPull: '7f951dda-4ed3-4680-a7ca-43fe172d538d'
  storageBlobDataContributor: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
  cognitiveServicesOpenAiUser: '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
}

// ---------- identity ----------

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-graphrag-${suffix}'
  location: location
}

// ---------- Azure OpenAI ----------

resource openAi 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: 'oai-graphrag-${suffix}'
  location: location
  kind: 'OpenAI'
  sku: { name: 'S0' }
  properties: {
    customSubDomainName: 'oai-graphrag-${suffix}' // required for Entra ID auth
    disableLocalAuth: true // keys disabled: managed identity only
    publicNetworkAccess: 'Enabled'
  }
}

resource chatDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: openAi
  name: chatModel
  sku: { name: chatSku, capacity: chatCapacity }
  properties: {
    model: { format: 'OpenAI', name: chatModel, version: chatModelVersion }
  }
}

resource embeddingDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: openAi
  name: embeddingModel
  sku: { name: embeddingSku, capacity: embeddingCapacity }
  properties: {
    model: { format: 'OpenAI', name: embeddingModel, version: embeddingModelVersion }
  }
  dependsOn: [chatDeployment] // deployments on one account must be created one at a time
}

// ---------- storage ----------

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'stgraphrag${suffix}'
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false // managed identity only
    minimumTlsVersion: 'TLS1_2'
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'graphrag'
}

// ---------- registry + logs + environment ----------

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: 'crgraphrag${suffix}'
  location: location
  sku: { name: 'Basic' }
  properties: { adminUserEnabled: false }
}

resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-graphrag-${suffix}'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource environment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-graphrag-${suffix}'
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
  }
}

// ---------- role assignments for the identity ----------

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: registry
  name: guid(registry.id, identity.id, roles.acrPull)
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.acrPull)
  }
}

resource blobContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, identity.id, roles.storageBlobDataContributor)
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageBlobDataContributor)
  }
}

resource openAiUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: openAi
  name: guid(openAi.id, identity.id, roles.cognitiveServicesOpenAiUser)
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.cognitiveServicesOpenAiUser)
  }
}

// ---------- shared container settings ----------

var env = [
  { name: 'GRAPHRAG_ROOT', value: '/app/project' }
  { name: 'AZURE_CLIENT_ID', value: identity.properties.clientId } // tells DefaultAzureCredential which identity to use
  { name: 'AZURE_OPENAI_ENDPOINT', value: openAi.properties.endpoint }
  { name: 'AZURE_OPENAI_API_VERSION', value: openAiApiVersion }
  { name: 'GRAPHRAG_CHAT_MODEL', value: chatModel }
  { name: 'GRAPHRAG_CHAT_DEPLOYMENT', value: chatDeployment.name }
  { name: 'GRAPHRAG_EMBEDDING_MODEL', value: embeddingModel }
  { name: 'GRAPHRAG_EMBEDDING_DEPLOYMENT', value: embeddingDeployment.name }
  { name: 'STORAGE_ACCOUNT_URL', value: storage.properties.primaryEndpoints.blob }
  { name: 'STORAGE_CONTAINER', value: container.name }
]

var registries = usesRegistry ? [{ server: registry.properties.loginServer, identity: identity.id }] : []

// ---------- API ----------

resource api 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'ca-graphrag-api'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identity.id}': {} }
  }
  properties: {
    managedEnvironmentId: environment.id
    configuration: {
      ingress: {
        external: true
        targetPort: usesRegistry ? 8000 : 80
      }
      registries: registries
      secrets: [{ name: 'api-key', value: apiKey }]
    }
    template: {
      containers: [
        {
          name: 'api'
          image: image
          resources: { cpu: json('1.0'), memory: '2Gi' }
          env: concat(env, [{ name: 'API_KEY', secretRef: 'api-key' }])
        }
      ]
      scale: { minReplicas: minReplicas, maxReplicas: 1 }
    }
  }
  dependsOn: [acrPull, blobContributor, openAiUser]
}

// ---------- indexer job ----------

resource indexer 'Microsoft.App/jobs@2024-03-01' = {
  name: 'caj-graphrag-index'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identity.id}': {} }
  }
  properties: {
    environmentId: environment.id
    configuration: {
      triggerType: 'Manual'
      replicaTimeout: 3600
      replicaRetryLimit: 0
      manualTriggerConfig: { parallelism: 1, replicaCompletionCount: 1 }
      registries: registries
    }
    template: {
      containers: [
        {
          name: 'indexer'
          image: image
          command: usesRegistry ? ['sh', 'scripts/index.sh'] : []
          resources: { cpu: json('2.0'), memory: '4Gi' }
          env: env
        }
      ]
    }
  }
  dependsOn: [acrPull, blobContributor, openAiUser]
}

output registryName string = registry.name
output registryServer string = registry.properties.loginServer
output apiName string = api.name
output apiUrl string = 'https://${api.properties.configuration.ingress.fqdn}'
output jobName string = indexer.name
output openAiEndpoint string = openAi.properties.endpoint
