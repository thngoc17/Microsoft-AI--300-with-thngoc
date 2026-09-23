// =============================================================================
// Deploy ở RESOURCE GROUP SCOPE (mặc định của Bicep)
// Resource Group phải được tạo sẵn từ trước bởi infra/bootstrap.sh
//
// PHIÊN BẢN NÀY THAY THẾ HOÀN TOÀN kiến trúc Hub/Project cũ
// (Microsoft.MachineLearningServices/workspaces) bằng kiến trúc Foundry
// project MỚI (Microsoft.CognitiveServices/accounts + .../projects). Hai
// kiến trúc KHÔNG tương thích — SDK azure-ai-projects hiện tại (dùng trong
// src/agent/core.py và evals/run_eval.py) chỉ đọc được project kiểu mới.
// Nguồn xác nhận: Microsoft Learn ghi rõ "az ml CLI và azure-ai-ml Python SDK
// dùng Microsoft.MachineLearningServices, KHÔNG hỗ trợ new Foundry projects
// (Microsoft.CognitiveServices)".
// =============================================================================
targetScope = 'resourceGroup'

@description('Vùng Azure triển khai')
param location string = resourceGroup().location

@description('Tên tiền tố cho các tài nguyên')
param prefix string = 'foundry'

@description('Tên Foundry resource (Microsoft.CognitiveServices/accounts, kind AIServices) — nơi chứa CẢ model deployment lẫn project, không còn tách riêng "Azure OpenAI account" như bicep cũ')
param foundryAccountName string = '${prefix}-aiservices-${uniqueString(resourceGroup().id)}'

@description('Tên Foundry Project — child resource của foundryAccount. Agent thật sự chạy ở đây.')
param foundryProjectName string = '${prefix}-project-${uniqueString(resourceGroup().id)}'

@description('Tên Azure AI Search Service')
param searchServiceName string = '${prefix}-search-${uniqueString(resourceGroup().id)}'

@description('Tên DEPLOYMENT cho model reasoning của Agent. Đổi ở đây nếu đổi model, không cần sửa code.')
param agentModelDeploymentName string = 'gpt-5.6-luna'

@description('Model name theo đúng tên trong Model Catalog của Foundry')
param agentModelName string = 'gpt-5.6-luna'

@description('Model version — copy đúng từ tab "Models + endpoints" khi deploy thử trên portal, vì Microsoft có thể phát hành version mới cho cùng một model name')
param agentModelVersion string = '2026-07-09'

@description('SKU deployment cho model. Kiểm tra đúng loại được phép trong vùng/region đã chọn trên Model Catalog trước khi deploy (GlobalStandard không sẵn có ở mọi vùng).')
param agentModelSkuName string = 'GlobalStandard'

@description('Capacity (đơn vị nghìn TPM) cho model deployment')
param agentModelCapacity int = 10

@description('Tên PROJECT CONNECTION nối Foundry Project với Azure AI Search — PHẢI khớp chính xác AZURE_SEARCH_CONNECTION_NAME trong src/agent/config.py')
param searchConnectionName string = 'SearchServiceConnection'

// ==========================================
// 1. Azure AI Search
//    (không đổi so với bản cũ — resource type này độc lập với kiến trúc
//    Foundry project, vẫn dùng Microsoft.Search/searchServices như trước)
// ==========================================
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

// ==========================================
// 2. FOUNDRY RESOURCE MỚI (Microsoft.CognitiveServices, kind AIServices)
//    allowProjectManagement: true là cờ BẮT BUỘC để bật kiến trúc project
//    mới trên resource này — thiếu cờ này, resource vẫn là AIServices
//    account thường nhưng KHÔNG tạo được child resource "projects" bên dưới.
// ==========================================
resource foundryAccount 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: foundryAccountName
  location: location
  sku: { name: 'S0' }
  kind: 'AIServices'
  identity: { type: 'SystemAssigned' }
  properties: {
    allowProjectManagement: true
    customSubDomainName: foundryAccountName
    disableLocalAuth: false
    publicNetworkAccess: 'Enabled'
  }
}

// ==========================================
// 3. MODEL DEPLOYMENT — gpt-5.6-luna
//    Nằm NGAY trên foundryAccount (không còn resource "Azure OpenAI" tách
//    riêng như trong bicep cũ). agent.py trỏ FOUNDRY_AGENT_MODEL_DEPLOYMENT
//    tới đúng name của resource này.
// ==========================================
resource agentModelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: foundryAccount
  name: agentModelDeploymentName
  sku: {
    name: agentModelSkuName
    capacity: agentModelCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: agentModelName
      version: agentModelVersion
    }
  }
}

// ==========================================
// 4. FOUNDRY PROJECT — child resource của foundryAccount
//    Endpoint của resource này (xem output bên dưới) chính là giá trị đưa
//    vào FOUNDRY_PROJECT_ENDPOINT trong .env, dùng bởi AIProjectClient.
// ==========================================
resource foundryProject 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: foundryAccount
  name: foundryProjectName
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    displayName: 'AI-300 GenAIOps Agent Project'
    description: 'Project chứa Agent RAG tra cứu ai300-notes-index, code-hoá từ ClickOps'
  }
}

// ==========================================
// 5. PROJECT CONNECTION tới Azure AI Search
//    Thay thế thao tác bấm "Add connection" trên Foundry portal. Resource
//    type này (accounts/projects/connections) khác với resource type của
//    connection cũ (workspaces/connections) — connection cũ KHÔNG được SDK
//    mới nhìn thấy dù cùng tên, phải tạo lại ở đây.
// ==========================================
resource searchConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01' = {
  parent: foundryProject
  name: searchConnectionName
  properties: {
    category: 'CognitiveSearch'
    target: 'https://${aiSearch.name}.search.windows.net'
    authType: 'AAD'
  }
}

// ==========================================
// 6. RBAC — gán cho Managed Identity của PROJECT (không phải account)
//    Role ID dưới đây đã được đối chiếu lại với Microsoft Learn tại thời
//    điểm viết file này; bản main.bicep cũ trước đó dùng 2 GUID SAI cho
//    "Search Index Data Contributor" và "Cognitive Services OpenAI User".
// ==========================================
var cognitiveServicesOpenAiUserRoleId = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'  // Cognitive Services OpenAI User
var searchIndexDataContributorRoleId  = '8ebe5a00-799e-43f5-93ac-243d3dce84a7'  // Search Index Data Contributor
var searchServiceContributorRoleId    = '7ca78c08-252a-4471-8644-bb5ff32d4ba0'  // Search Service Contributor

// Agent cần gọi model deployment để reasoning/generation
resource assignOpenAiRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundryProject.id, foundryAccount.id, cognitiveServicesOpenAiUserRoleId)
  scope: foundryAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesOpenAiUserRoleId)
    principalId: foundryProject.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// AzureAISearchTool cần CẢ 2 role này theo tài liệu Foundry hiện hành —
// khác với bản cũ chỉ gán "Search Index Data Reader" (không đủ quyền cho
// project connection kiểu mới).
resource assignSearchIndexRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundryProject.id, aiSearch.id, searchIndexDataContributorRoleId)
  scope: aiSearch
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', searchIndexDataContributorRoleId)
    principalId: foundryProject.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource assignSearchServiceRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundryProject.id, aiSearch.id, searchServiceContributorRoleId)
  scope: aiSearch
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', searchServiceContributorRoleId)
    principalId: foundryProject.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ==========================================
// OUTPUTS — CI/CD (deploy.yml) và src/agent/config.py cần các giá trị này
// ==========================================
output resourceGroupName string = resourceGroup().name
output foundryAccountName string = foundryAccount.name
output foundryProjectName string = foundryProject.name
// Format endpoint theo đúng convention đã dùng sẵn trong evals/run_eval.py
output foundryProjectEndpoint string = 'https://${foundryAccount.properties.customSubDomainName}.services.ai.azure.com/api/projects/${foundryProject.name}'
output searchServiceName string = aiSearch.name
output agentModelDeploymentName string = agentModelDeployment.name
