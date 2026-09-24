---
source_url: https://gemini.google.com/app/20455db138087d5b
conversation_date: 2026-01-09
context_week: Tuần 6
conversation_types: [LAP_KE_HOACH, TRANH_LUAN_QUYET_DINH, LY_THUYET]
ai300_domains: ["Design and implement MLOps infrastructure", "Model lifecycle"]
technologies: [Azure Machine Learning, Bicep, Azure CLI, MLflow, Managed Identity, Private Endpoint, Managed Virtual Network, Azure Container Registry, Azure Storage, RBAC]
key_decision: "Tập trung vào nửa đầu vòng đời mô hình (tracking/training với MLflow và Command Job) trong tuần 6 để bù đắp lỗ hổng kiến thức, đồng thời sử dụng Bicep cho IaC và thiết kế bảo mật với Managed Identity cho endpoint, thay vì bypass việc training trên cloud."
status: resolved
---

## Bối cảnh & Vấn đề

Người dùng đang lên kế hoạch ôn tập cho chứng chỉ AI-300, đặc biệt là cho Tuần 6 trong lộ trình 3 tháng. Các vấn đề kỹ thuật chính được đặt ra:
- Thiếu kinh nghiệm thực hành với nửa đầu vòng đời mô hình (MLflow tracking, training jobs trên cloud).
- Ràng buộc phần cứng: Azure for Students không cung cấp GPU, không thể huấn luyện YOLO trên cloud.
- Đã có kinh nghiệm với nửa sau vòng đời (deploy endpoint, register model).
- Cần quyết định chiến lược xử lý việc thiếu GPU.
- Cần hiểu và áp dụng đúng các khái niệm bảo mật nâng cao như Managed Identity, Datastore credential-less, và Managed Virtual Network cho MLOps.

## Quyết định cuối cùng & Lý do

1.  **KHÔNG bypass việc training trên cloud:** Việc huấn luyện trên cloud là cốt lõi của MLOps để xây dựng pipeline tự động. Bỏ qua nó sẽ tạo ra lỗ hổng kiến thức nghiêm trọng cho kỳ thi.
2.  **Sử dụng mô hình CPU (Scikit-learn, XGBoost) để thực hành:** Giải pháp thay thế cho việc không có GPU. Tập trung vào việc học cú pháp, luồng công việc (Command Job, Sweep Job), logging, và quản lý dữ liệu thay vì chất lượng mô hình.
3.  **Tách biệt Training và Inference cho YOLO:**
    - Training: Huấn luyện trên máy cá nhân hoặc Google Colab, sau đó upload trọng số lên Azure ML Model Registry.
    - Inference: Deploy mô hình với trọng số đã train lên Online/Batch Endpoint sử dụng CPU compute. Tốc độ chậm nhưng quy trình là chính xác.
4.  **Tuần 6 tập trung vào IaC và Security:** Dành thời gian để lắp lỗ hổng MLflow và các yếu tố hạ tầng, bảo mật thay vì lặp lại các tác vụ đã quen thuộc.
5.  **Tách bạch IaC (Bicep) và ML Assets (CLI/YAML):**
    - **Bicep được dùng để cấp phát hạ tầng nền tảng (Workspace, Storage, ACR, Compute Cluster).** Đây là lớp tài nguyên tĩnh, ít thay đổi.
    - **Azure ML CLI v2 + YAML được dùng để quản lý các tài sản và tác vụ ML (Environment, Model, Endpoint, Job).** Đây là lớp động, thay đổi thường xuyên theo vòng đời của model.
    - **Lý do:** Tránh tạo ra Configuration Drift. Việc trộn lẫn sẽ khiến file code không phản ánh đúng thực tế hạ tầng, phá vỡ tính chất luỹ đẳng (Idempotency) của IaC và gây khó khăn trong quản lý phiên bản (versioning).
6.  **Sử dụng Managed Identity (User-assigned) cho Endpoint:** Thay vì sử dụng identity của Workspace (quyền quá mức) hoặc System-assigned (gây ra Race Condition trong CI/CD), sử dụng User-assigned để cấp quyền tối thiểu (Least Privilege) cho Endpoint, đảm bảo tính cô lập và bảo mật.

## Lệnh và Cấu hình cụ thể đã dùng

### Bicep template cho Infrastructure as Code (Tuần 6 - Ngày 4)

File `main.bicep` dùng để cấp phát toàn bộ hạ tầng cho một dự án MLOps.

```bicep
@description('The core name of the project. Must be globally unique, lowercase, no spaces, max 14 characters.')
@minLength(4)
@maxLength(14)
param projectName string

@description('The region for all resources. Defaults to the resource group location.')
param location string = resourceGroup().location

// - - - - - - - - - - - - - - - - - - - -
// VARIABLES: Deterministic Naming Convention
// - - - - - - - - - - - - - - - - - - - -
// Standard Azure prefixes applied to the base project name.
// Storage & ACR require alphanumeric only. KeyVault requires hyphens.
var storageAccountName = 'st${projectName}'
var keyVaultName = 'kv-${projectName}'
var appInsightsName = 'appi-${projectName}'
var acrName = 'cr${projectName}'
var workspaceName = 'mlw-${projectName}'

// - - - - - - - - - - - - - - - - - - - -
// RESOURCES
// - - - - - - - - - - - - - - - - - - - -

// 1. Storage Account (Required for ML Workspace to store artifacts and data)
resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS' // Locally Redundant Storage is sufficient for student/dev
  }
  kind: 'StorageV2'
  properties: {
    encryption: {
      services: {
        blob: { enabled: true }
        file: { enabled: true }
      }
      keySource: 'Microsoft.Storage'
    }
    supportsHttpsTrafficOnly: true
  }
}

// 2. Key Vault (Required for ML Workspace to store secrets and credentials)
resource keyVault 'Microsoft.KeyVault/vaults@2022-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: {
      name: 'standard'
      family: 'A'
    }
    accessPolicies: [] // Empty by default; ML Workspace MSI will populate or RBAC will be used
    enableSoftDelete: true
  }
}

// 3. Application Insights (Required for Endpoint monitoring and observability)
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
  }
}

// 4. Azure Container Registry (Strictly linked to ML Workspace)
resource containerRegistry 'Microsoft.ContainerRegistry/registries@2022-12-01' = {
  name: acrName
  location: location
  sku: {
    name: 'Basic' // Basic SKU is mandatory for student budget to avoid high daily costs
  }
  properties: {
    adminUserEnabled: false // Best practice: Use Managed Identities instead of admin credentials
  }
}

// 5. Azure Machine Learning Workspace
resource mlWorkspace 'Microsoft.MachineLearningServices/workspaces@2023-10-01' = {
  name: workspaceName
  location: location
  identity: {
    type: 'SystemAssigned' // Generates an Entra ID Service Principal for the Workspace
  }
  properties: {
    friendlyName: workspaceName
    storageAccount: storageAccount.id
    keyVault: keyVault.id
    applicationInsights: appInsights.id
    containerRegistry: containerRegistry.id // DIRECT LINKAGE AS REQUESTED
  }
}

// 6. OUTPUTS
output workspaceId string = mlWorkspace.id
output workspacePrincipalId string = mlWorkspace.identity.principalId
```

### Lệnh thực thi Bicep

```bash
# Tạo Resource Group
az group create --name rg-mlops-dev --location southeastasia

# Triển khai Bicep
az deployment group create \
  --resource-group rg-mlops-dev \
  --template-file main.bicep \
  --parameters projectName=ltngoc26
```

### Cấu hình Managed Identity cho Endpoint (YAML)

#### Ví dụ 1: System-assigned Identity (Định danh cấp hệ thống)

```yaml
$schema: https://azuremlschemas.azureedge.net/latest/managedOnlineEndpoint.schema.json
name: yolo-endpoint-ver1
auth_mode: key
identity:
  type: system_assigned
```

#### Ví dụ 2: User-assigned Identity (Chuẩn mực doanh nghiệp / IaC)

```yaml
$schema: https://azuremlschemas.azureedge.net/latest/managedOnlineEndpoint.schema.json
name: yolo-endpoint-ver1
auth_mode: key
identity:
  type: user_assigned
  user_assigned_identities:
    - "/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/<RESOURCE_GROUP_NAME>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<IDENTITY_NAME>"
```

### Thiết kế Datastore Credential-less (YAML)

File `datastore.yml` dùng để tạo một Datastore không sử dụng mật khẩu (access key), mà dùng Identity-based access.

```yaml
$schema: https://azuremlschemas.azureedge.net/latest/azureBlobDatastore.schema.json
name: cv_training_datastore
description: "Credential-less datastore for computer vision raw datasets."
type: azure_blob
account_name: stlntgoc26
container_name: yolo-dataset
credentials:
  type: none
```

### Lệnh thực thi Datastore

```bash
# Cấp phát Datastore
az ml datastore create --file datastore.yml
```

## Lỗi gặp phải và Cách khắc phục

1.  **Tư tưởng "Bypass training trên cloud":**
    - **Vấn đề:** Do không có GPU, người dùng ban đầu đề xuất bỏ qua việc học training jobs.
    - **Khắc phục:** Sử dụng mô hình CPU nhẹ để học luồng công việc, tách biệt training (trên máy cá nhân) và inference (trên Azure) cho YOLO. Điều này đảm bảo nắm vững kiến thức MLOps mà không cần GPU.

2.  **Trộn lẫn IaC (Bicep) và CLI để thêm tài nguyên:**
    - **Vấn đề:** Nguy cơ tạo Configuration Drift, khiến code không còn phản ánh đúng thực tế hạ tầng.
    - **Khắc phục:** Thiết lập ranh giới rõ ràng: **Bicep** cho Base Infrastructure (Workspace, Storage, Key Vault, Compute), **Azure ML CLI v2 + YAML** cho ML Assets (Environments, Models, Endpoints, Jobs).

3.  **Nhầm lẫn giữa `auth_mode: key` (Inbound) và `identity` block (Outbound) trong YAML Endpoint:**
    - **Vấn đề:** Nhầm lẫn giữa xác thực chiều vào (client gọi API) và xác thực chiều ra (Endpoint truy cập ACR, Storage).
    - **Khắc phục:** Hiểu rõ `identity` block quyết định cách Endpoint lấy quyền để kéo image và tải model, không liên quan đến cách client xác thực.

4.  **Lỗ hổng bảo mật "Đặc quyền quá mức" (Over-Privilege) khi dùng Workspace Identity cho Endpoint:**
    - **Vấn đề:** Workspace Identity có quyền đọc/ghi trên toàn bộ Storage và ACR. Nếu Endpoint bị tấn công, kẻ xấu sẽ có quyền truy cập vào tất cả dữ liệu khác.
    - **Khắc phục:** Sử dụng User-assigned Identity với quyền hạn tối thiểu (ví dụ: chỉ đọc model YOLO trong một container cụ thể) để cô lập rủi ro.

5.  **Race Condition trong CI/CD khi dùng System-assigned Identity:**
    - **Vấn đề:** Endpoint bắt đầu chạy trước khi RBAC cho System-assigned Identity kịp có hiệu lực, gây lỗi timeout khi kéo image hoặc tải model.
    - **Khắc phục:** Tạo và gán quyền cho User-assigned Identity trước khi triển khai, đảm bảo quy trình CI/CD chạy liền mạch.

## Lộ trình chi tiết (Tuần 6)

| Ngày | Mục tiêu | Hoạt động cụ thể | Chỉ tiêu hoàn thành |
| :--- | :--- | :--- | :--- |
| **Ngày 1** | **Tracking cục bộ với MLflow (Không cần GPU)** | Viết script Python train mô hình CPU đơn giản, log parameters, metrics, artifacts lên Azure ML Workspace từ máy local. | Có thể log thành công lên Azure ML Studio và xem được các thông số từ máy local. |
| **Ngày 2** | **Đóng gói và Thực thi Cloud Training (Command Job)** | Viết file `job.yml` định nghĩa code, command, environment, compute. Chạy `az ml job create -f job.yml`. | Job chạy thành công trên cloud, tự động log và tắt node để tiết kiệm chi phí. |
| **Ngày 3** | **Observability & Giám sát (Monitoring)** | 1. Bật Application Insights cho một Endpoint đã tạo, đọc log để phân tích latency, status codes. <br> 2. Tìm hiểu và cấu hình Data Drift detection. | Có thể đọc log từ Application Insights và hiểu được quy trình thiết lập Data Drift. |
| **Ngày 4** | **Infrastructure as Code (Bicep)** | Viết file `main.bicep` khai báo ML Workspace, Storage, Key Vault, Application Insights. Triển khai bằng CLI. | Có thể deploy thành công hạ tầng từ file Bicep. |
| **Ngày 5** | **Bảo mật & Quản lý danh tính (Security)** | 1. Phân tích và viết file YAML cấu hình Managed Identity (User-assigned) cho Endpoint. <br> 2. Tìm hiểu về Datastore credential-less. <br> 3. Đọc lý thuyết về Managed Virtual Network của Azure ML. | Có thể thiết kế cấu hình YAML cho User-assigned Identity và giải thích các chế độ của Managed VNet. |

## Khái niệm & Định nghĩa

### 1. Managed Identity (Định danh quản lý)
- **Định nghĩa:** Cơ chế ủy quyền của Microsoft Entra ID, cung cấp một danh tính phi tín chỉ (credential-less) cho các tài nguyên trên đám mây. Loại bỏ việc lưu trữ mật khẩu trong mã nguồn.
- **Phân loại:**
    - **System-assigned:** Định danh được tạo và gắn chặt với vòng đời của tài nguyên (ví dụ: Endpoint). Xóa tài nguyên là xóa định danh.
    - **User-assigned:** Một tài nguyên độc lập. Có thể tạo trước, gán quyền trước và gán cho nhiều tài nguyên khác nhau.
- **Ví dụ:** Sử dụng User-assigned Identity cho Online Endpoint để nó có quyền kéo image từ ACR và tải model từ Storage mà không cần access key.

### 2. Datastore trong Azure ML
- **Định nghĩa:** Một lớp trừu tượng để tham chiếu đến các dịch vụ lưu trữ dữ liệu (ví dụ: Azure Blob Storage). Cho phép script truy cập dữ liệu qua URI chuẩn hóa (`azureml://datastores/<tên>/paths/<đường-dẫn>`) thay vì hardcode connection string.
- **Credential-less Datastore:** Không lưu trữ mật khẩu. Thay vào đó, sử dụng Managed Identity để xác thực qua RBAC. Cấu hình bằng `credentials: type: none`.

### 3. Managed Virtual Network
- **Định nghĩa:** Một giải pháp mạng do Azure Machine Learning quản lý, tự động cấu hình và bảo mật luồng outbound từ workspace và các compute resources.
- **Các chế độ:**
    1.  **Allow internet outbound:** Cho phép luồng truy cập Internet tự do.
    2.  **Allow only approved outbound:** Chỉ cho phép các kết nối đã được phê duyệt qua Private Endpoint, Service Tag, hoặc FQDN. Giảm thiểu rủi ro rò rỉ dữ liệu.
    3.  **Disabled:** Không áp dụng Managed VNet (sử dụng Custom VNet hoặc không có isolation).

## Các phương án đã cân nhắc

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
| :--- | :--- | :--- | :--- |
| **Huấn luyện YOLO trên cloud bằng GPU Cluster** | Chính xác, đúng quy trình chuẩn. | Azure for Students không hỗ trợ GPU. Chi phí cao. | **KHÔNG** (do giới hạn phần cứng) |
| **Bypass hoàn toàn việc training trên cloud** | Tiết kiệm thời gian, không lo về GPU. | **Lỗ hổng kiến thức lớn:** Không hiểu về Command Job, Job lifecycle, là nội dung cốt lõi của AI-300. | **KHÔNG** (ảnh hưởng nghiêm trọng đến kết quả thi) |
| **Dùng mô hình CPU (Scikit-learn) để thực hành training job** | Nắm được luồng công việc, cú pháp, logging, quản lý job. **KHÔNG TỐN CHI PHÍ GPU.** | Không trực tiếp train được mô hình YOLO mong muốn. | **CÓ** (giải pháp tối ưu cho việc học) |
| **Train YOLO ngoài (Colab/máy cá nhân) + Upload model lên Azure để deploy** | Tiết kiệm chi phí, tận dụng được sức mạnh của GPU ngoài cloud. | Quy trình không hoàn toàn tự động trên cloud. | **CÓ** (kết hợp với phương án trên) |
| **Trộn lẫn Bicep và CLI để quản lý tài nguyên** | Dễ dàng, nhanh chóng cho dự án nhỏ. | Tạo ra Configuration Drift, IaC không còn giá trị. | **KHÔNG** (vi phạm nguyên tắc IaC) |
| **Sử dụng Workspace Identity để gán quyền cho Endpoint** | Đơn giản, ít cấu hình. | **Rủi ro bảo mật:** Đặc quyền quá mức, bán kính sát thương lớn. | **KHÔNG** (không an toàn cho hệ thống chuyên nghiệp) |
| **Sử dụng User-assigned Identity cho Endpoint** | **Tối ưu:** Tuân thủ Least Privilege, cô lập quyền, an toàn cho CI/CD. | Cần tạo thêm tài nguyên và cấu hình thêm bước. | **CÓ** (tiêu chuẩn doanh nghiệp và được khuyến nghị) |
