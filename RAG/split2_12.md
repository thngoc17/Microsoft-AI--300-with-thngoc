---
source_url: https://gemini.google.com/app/21f28f697e80c294
conversation_date: 2026-08-06
context_week: N/A
conversation_types: [TRANH_LUAN_QUYET_DINH, FIX_HA_TANG, FIX_CODE, LY_THUYET]
ai300_domains: ["Thiết kế và triển khai hạ tầng MLOps", "Quản lý vòng đời model"]
technologies: [Azure RBAC, Azure CLI, Azure Resource Manager (ARM), Azure Container Registry (ACR), Azure Machine Learning Workspace, Azure Storage Account, Azure Entra ID (Azure AD)]
key_decision: "Không gán quyền Contributor cấp Subscription để quản lý model, thay vào đó tạo Azure ML Workspace và gán quyền AzureML Data Scientist ở scope Workspace để đẩy model và data asset, tuân thủ nguyên tắc đặc quyền tối thiểu."
status: resolved
---

## Bối cảnh & Vấn đề
* **Mục tiêu**: Tài khoản `23122012@student.hcmus.edu.vn` cần quyền để thêm/xóa/sửa Resource Group (RG) và tạo chỗ lưu model trên Azure.
* **Lỗi cụ thể**: Sau khi gán quyền `Contributor` cấp Subscription, lệnh `az ml model create --registry-name mlopsacrthngoc17 --resource-group mlops-rg --file model.yml` vẫn báo lỗi `(UserError) User/tenant/subscription is not allowed to access registry mlopsacrthngoc17`.
* **Nguyên nhân ban đầu**: RBAC propagation (5-15 phút) và stale token. Tuy nhiên, sau khi phân tích sâu, nguyên nhân cốt lõi là **kiến trúc sai**: `mlopsacrthngoc17` là ACR, không phải Azure ML Registry, và chưa có Azure ML Workspace.

## Quyết định cuối cùng & Lý do
* **Quyết định kiến trúc cuối cùng**:
  * **Tạo Azure Machine Learning Workspace** (`mlops-workspace`) để quản lý model và data assets.
  * Sử dụng `Storage Account` (`mlopssastthngoc17` và `mlopsworstoragecc10dc663`) làm backend lưu trữ vật lý.
  * **Phân quyền**: Gán role `AzureML Data Scientist` ở **scope Workspace**, không gán `Contributor` cấp Subscription hay ACR.
* **Lý do**: Tuân thủ nguyên tắc đặc quyền tối thiểu (PoLP), giảm blast radius, và đảm bảo Azure ML tracking/versioning.
* **Phương án bị loại bỏ (ĐÃ LOẠI BỎ)**:
  * **KHÔNG dùng** `Contributor` cấp Subscription: Vi phạm PoLP, mở toàn quyền trên toàn bộ tài nguyên (VM, DB, Network...), rủi ro bảo mật cao.
  * **KHÔNG dùng** `AcrPush` trên ACR: Vì lệnh `az ml model create` không hoạt động với ACR; ACR chỉ dùng để lưu Docker images, không phải model registry.
  * **KHÔNG dùng** `AzureML Registry Contributor` (không tồn tại) hoặc gán scope sai Provider (`Microsoft.ContainerRegistry` thay vì `Microsoft.MachineLearningServices`).

## Lệnh và Cấu hình cụ thể đã dùng
### Tạo Azure ML Workspace
```bash
az ml workspace create \
 --name "mlops-workspace" \
 --resource-group "mlops-rg" \
 --location "eastasia"
```

### Gán quyền AzureML Data Scientist (Scope Workspace)
```bash
az role assignment create \
 --assignee "23122012@student.hcmus.edu.vn" \
 --role "AzureML Data Scientist" \
 --scope "/subscriptions/f6b812fd-ef94-4ce1-948f-ea652339a497/resourceGroups/mlops-rg/providers/Microsoft.MachineLearningServices/workspaces/mlops-workspace"
```

### Lệnh đăng ký model (sửa đúng tham số)
```bash
az ml model create \
 --workspace-name "mlops-workspace" \
 --resource-group "mlops-rg" \
 --file model.yml
```

### Cấu hình Data Asset (upload vector DB)
* File `data.yml`:
```yaml
$schema: https://azuremlschemas.azureedge.net/latest/data.schema.json
type: uri_folder
name: personal_knowledge_vector_db
description: "Vector database chứa dữ liệu cá nhân"
path: ./my_data/knowledge_db/
```
* Lệnh tạo Data Asset:
```bash
az ml data create \
 --file data.yml \
 --resource-group mlops-rg \
 --workspace-name mlops-workspace
```

### Lệnh kiểm tra tài nguyên trong RG
```bash
az resource list -g mlops-rg -o table
```
Kết quả:
```
Name                     ResourceGroup    Location    Type                                    Status
-----------------------  ---------------  ----------  --------------------------------------  ---------
mlopssastthngoc17        mlops-rg         eastasia    Microsoft.Storage/storageAccounts       Succeeded
mlopsacrthngoc17         mlops-rg         eastasia    Microsoft.ContainerRegistry/registries  Succeeded
```

## Lỗi gặp phải và Cách khắc phục
### Lỗi RBAC propagation và stale token
* **Lỗi**: Sau khi gán quyền, lệnh `az ml` vẫn báo lỗi truy cập.
* **Cách khắc phục**: Chờ 5-15 phút, sau đó chạy:
```bash
az account clear
az login
az account set --subscription f6b812fd-ef94-4ce1-948f-ea652339a497
```

### Lỗi role không tồn tại
* **Lỗi**: `Role 'AzureML Registry Contributor' doesn't exist.`
* **Nguyên nhân**: Role này không có sẵn; tên đúng là `AzureML Data Scientist` hoặc `Machine Learning Contributor`.
* **Cách khắc phục**: Sử dụng đúng tên role `AzureML Data Scientist`.

### Sai kiến trúc: Gán quyền trên ACR để dùng `az ml model create`
* **Lỗi**: Gán quyền `AcrPush` trên ACR nhưng lệnh `az ml model create` vẫn lỗi.
* **Nguyên nhân**: `az ml model create` chỉ hoạt động với Azure ML Workspace hoặc Registry (`Microsoft.MachineLearningServices`), không phải ACR (`Microsoft.ContainerRegistry`).
* **Cách khắc phục**: Tạo Azure ML Workspace và gán quyền đúng scope.

### Upload dữ liệu sai cách (dùng `az storage blob` thay vì `az ml data`)
* **Anti-pattern**: Dùng lệnh `az storage blob upload-batch` để đẩy dữ liệu vào container mặc định của Storage Account.
* **Hậu quả**: Azure ML không tracking được data asset, mất lineage và versioning.
* **Cách khắc phục**: Đăng ký data asset bằng `az ml data create` với file YAML schema.


## Khái niệm & Định nghĩa
* **Azure Machine Learning Workspace**: "Trái tim" của hệ thống quản lý model. Là tài nguyên cấp cao nhất để quản lý vòng đời ML (models, environments, data assets, pipelines). Tự động tạo và liên kết các tài nguyên vệ tinh: Storage Account, Key Vault, Application Insights, Container Registry.
* **Azure Container Registry (ACR)**: Dùng để lưu trữ Docker images và OCI artifacts. Trong MLOps, ACR là nơi chứa images cho môi trường chạy training/inference, KHÔNG phải là model registry.
* **Azure ML Data Asset**: Cách đăng ký dữ liệu (file, folder, table) vào Workspace để tracking version, lineage, và dễ dàng truy xuất qua SDK/CLI. Dữ liệu vật lý vẫn nằm trên Storage Account, nhưng được AML quản lý metadata.
* **RBAC (Role-Based Access Control)**: Hệ thống phân quyền trên Azure. Quyền được gán tại một scope (Subscription, Resource Group, hoặc resource cụ thể). Nguyên tắc quan trọng: **Đặc quyền tối thiểu (Principle of Least Privilege)** – chỉ cấp quyền tối thiểu cần thiết.
* **AzureML Data Scientist**: Built-in role cho phép đọc/ghi dữ liệu, tạo model, environment, pipeline trong Workspace. Không có quyền xóa Workspace hay thay đổi RBAC.

## Các phương án đã cân nhắc
| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
|---|---|---|---|
| **Contributor (Subscription)** | Dễ dùng, có sẵn, giải quyết ngay lập tức mọi lỗi truy cập. | Vi phạm PoLP, blast radius lớn (toàn bộ Subscription). Rủi ro xóa/sửa tài nguyên ngoài ý muốn. | **KHÔNG** (đã loại bỏ) |
| **AcrPush (ACR scope)** | Chỉ cho quyền push/pull ACR. | Không giải quyết được lệnh `az ml model create`, vì lệnh này không dùng ACR trực tiếp. | **KHÔNG** (đã loại bỏ) |
| **AzureML Data Scientist (Workspace scope)** | Tuân thủ PoLP, chỉ cấp quyền trong Workspace. Đủ để đăng ký model và data asset. | Cần tạo Workspace trước, thao tác phức tạp hơn một chút. | **CÓ** |

