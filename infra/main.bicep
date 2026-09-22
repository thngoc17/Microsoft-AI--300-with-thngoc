// Deploy ở RESOURCE GROUP SCOPE (mặc định của Bicep)
// Resource Group phải được tạo sẵn từ trước bởi infra/bootstrap.sh
targetScope = 'resourceGroup'

@description('Vùng Azure triển khai')
param location string = resourceGroup().location

@description('Tên tiền tố cho các tài nguyên')
param prefix string = 'foundry'

@description('Tên Azure AI Foundry Hub')
param hubName string = '${prefix}-hub-${uniqueString(resourceGroup().id)}'

@description('Tên Azure AI Foundry Project')
param projectName string = '${prefix}-project-${uniqueString(resourceGroup().id)}'

@description('Tên Azure AI Search Service')
param searchServiceName string = '${prefix}-search-${uniqueString(resourceGroup().id)}'

@description('Tên Azure OpenAI Service')
param openAiAccountName string = '${prefix}-aoai-${uniqueString(resourceGroup().id)}'

// 1. Hạ tầng cơ sở cho Foundry Hub (Storage + KeyVault)
resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: take('${prefix}st${uniqueString(resourceGroup().id)}', 24)
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: take('${prefix}-kv-${uniqueString(resourceGroup().id)}', 24)
  location: location
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: subscription().tenantId
    enableSoftDelete: true
    accessPolicies: []
  }
}

// 2. Azure AI Search (Bật Semantic Search)
resource aiSearch 'Microsoft.Search/searchServices@2023-11-01' = {
  name: searchServiceName
  location: location
  sku: { name: 'standard' }
  properties: {
    replicaCount: 1
    partitionCount: 1
    semanticSearch: 'free'
    authOptions: {
      aadOrApiKey: { aadAuthFailureMode: 'http401WithBearerChallenge' }
    }
  }
}

// 3. Azure OpenAI Account & GPT-4o Model Deployment
resource openAi 'Microsoft.CognitiveServices/accounts@2023-05-01' = {
  name: openAiAccountName
  location: location
  kind: 'OpenAI'
  sku: { name: 'S0' }
  properties: {
    customSubDomainName: openAiAccountName
    publicNetworkAccess: 'Enabled'
  }
}

resource gptDeployment 'Microsoft.CognitiveServices/accounts/deployments@2023-05-01' = {
  parent: openAi
  name: 'gpt-4o'
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-4o'
      version: '2024-05-13'
    }
  }
}

// 4. Azure AI Foundry HUB
resource foundryHub 'Microsoft.MachineLearningServices/workspaces@2024-04-01-preview' = {
  name: hubName
  location: location
  kind: 'Hub'
  identity: { type: 'SystemAssigned' }
  properties: {
    friendlyName: 'Foundry Management Hub'
    storageAccount: storage.id
    keyVault: keyVault.id
  }
}

// 5. Azure AI Foundry PROJECT (Nơi Agent hoạt động)
resource foundryProject 'Microsoft.MachineLearningServices/workspaces@2024-04-01-preview' = {
  name: projectName
  location: location
  kind: 'Project'
  identity: { type: 'SystemAssigned' }
  properties: {
    friendlyName: 'Foundry Agent Workspace Project'
    hubResourceId: foundryHub.id
  }
}

// 6. Khởi tạo Workspace Connections (Thay thế click chuột trên giao diện)
resource searchConnection 'Microsoft.MachineLearningServices/workspaces/connections@2024-04-01-preview' = {
  parent: foundryProject
  name: 'SearchServiceConnection'
  properties: {
    category: 'CognitiveSearch'
    target: 'https://${aiSearch.name}.search.windows.net'
    authType: 'AAD'
    isSharedToAll: true
    metadata: {
      ApiType: 'Azure'
      ResourceId: aiSearch.id
    }
  }
}

resource openAiConnection 'Microsoft.MachineLearningServices/workspaces/connections@2024-04-01-preview' = {
  parent: foundryProject
  name: 'OpenAIServiceConnection'
  properties: {
    category: 'AzureOpenAI'
    target: openAi.properties.endpoint
    authType: 'AAD'
    isSharedToAll: true
    metadata: {
      ApiType: 'Azure'
      ResourceId: openAi.id
    }
  }
}

// 7. Gán quyền RBAC (Project Managed Identity -> AI Search & Azure OpenAI)
var searchIndexContributorRoleId = '8ebe5a00-7179-4914-ab5b-38824f479995'
var cognitiveServicesUserRoleId = '5e0bd9e4-295b-43ac-997d-abac4bfb5173'

resource assignSearchRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundryProject.id, aiSearch.id, searchIndexContributorRoleId)
  scope: aiSearch
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', searchIndexContributorRoleId)
    principalId: foundryProject.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource assignOpenAiRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundryProject.id, openAi.id, cognitiveServicesUserRoleId)
  scope: openAi
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
    principalId: foundryProject.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// OUTPUTS để CI/CD Workflow tự động bắt (Dynamic Discovery)
output resourceGroupName string = resourceGroup().name
output hubName string = foundryHub.name
output projectName string = foundryProject.name
output searchServiceName string = aiSearch.name
output openAiAccountName string = openAi.name