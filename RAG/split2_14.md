---
source_url: https://gemini.google.com/app/2cb448991ef7dece
conversation_date: 2026-08-06
context_week: N/A
conversation_types: [LY_THUYET, FIX_HA_TANG, TRANH_LUAN_QUYET_DINH]
ai300_domains: [Design and implement MLOps infrastructure, GenAIOps infrastructure]
technologies: [Azure CLI, Azure Container Registry, RBAC, Entra ID, Docker, AKS, Terraform, OAuth 2.0, OCI]
key_decision: "Phân biệt rõ Authentication (xác thực Docker client với ACR) và Authorization (RBAC gán quyền); phải thực hiện `az acr login` để cấp token cho Docker trước khi push/pull, và luôn scope quyền ở cấp ACR, không ở Resource Group hay Subscription."
status: resolved
---

## Bối cảnh & Vấn đề

- **Vấn đề 1:** Cần gán quyền `AcrPull` (hoặc `AcrPush`) cho một định danh (Service Principal, Managed Identity, User) để cho phép kéo/đẩy image từ/đến Azure Container Registry (ACR).
- **Vấn đề 2:** Sau khi gán quyền RBAC thành công, lệnh `docker push` vẫn báo lỗi `authentication required` dù đã có quyền `AcrPush`. Người dùng thắc mắc tại sao đã có AuthZ mà vẫn cần đăng nhập, và cơ chế đăng nhập hoạt động ra sao.

## Quyết định cuối cùng & Lý do

- **Quyết định chính:** Sử dụng cơ chế RBAC với scope ở cấp tài nguyên ACR (không phải Resource Group hay Subscription), kết hợp với `az acr login` để xác thực Docker client trước khi push/pull. **Không sử dụng Admin User** của ACR.
- **Lý do:**
  - RBAC giải quyết Authorization (có được phép làm gì) nhưng không giải quyết Authentication (Docker client phải chứng minh danh tính).
  - Docker Daemon độc lập với Azure CLI, không tự động đọc token từ `~/.azure/`.
  - Scope ở cấp ACR tuân thủ nguyên tắc quyền tối thiểu (least privilege), tránh rò rỉ quyền sang các registry khác.
  - Admin User tạo rủi ro bảo mật, khuyến nghị dùng Entra ID + RBAC.

- **Phương án bị loại bỏ:**
  - **KHÔNG dùng** scope ở Resource Group hoặc Subscription vì gán quyền `AcrPull` ở cấp đó sẽ cấp quyền kéo image cho **tất cả** ACR trong scope, vi phạm nguyên tắc tối thiểu.
  - **KHÔNG dùng** Admin User (username + password) của ACR vì kém an toàn, thay vào đó duy trì xác thực bằng Entra ID.

## Lệnh và Cấu hình cụ thể đã dùng

### Lệnh gán quyền (đã thực thi thành công)
```bash
az role assignment create \
  --assignee 835b3045-d807-4e8c-a3da-b88772366817 \
  --role "AcrPush" \
  --scope /subscriptions/f6b812fd-ef94-4ce1-948f-ea652339a497/resourceGroups/mlops-rg/providers/Microsoft.ContainerRegistry/registries/63b2ec7eba0d44ea9a68fb9ece0790a2
```

### Lệnh khắc phục lỗi xác thực (thành công)
```bash
az acr login --name 63b2ec7eba0d44ea9a68fb9ece0790a2
```
Sau đó push lại:
```bash
docker push 63b2ec7eba0d44ea9a68fb9ece0790a2.azurecr.io/qwen-rag-api:v1
```

### Phương án dự phòng (dùng token trực tiếp, ổn định cho CI/CD)
```bash
USER_NAME="00000000-0000-0000-0000-000000000000"
PASSWORD=$(az acr login --name 63b2ec7eba0d44ea9a68fb9ece0790a2 --expose-token --output tsv --query accessToken)
docker login 63b2ec7eba0d44ea9a68fb9ece0790a2.azurecr.io --username $USER_NAME --password-stdin <<< $PASSWORD
```

### Các lệnh hướng dẫn khác (trích từ phản hồi)

- Lấy Resource ID của ACR:
```bash
ACR_NAME="<tên_acr>"
RG_NAME="<tên_resource_group>"
ACR_ID=$(az acr show --name $ACR_NAME --resource-group $RG_NAME --query id --output tsv)
```

- Gán quyền với scope là `$ACR_ID`:
```bash
ASSIGNE_ID="<object_id_hoặc_app_id>"
az role assignment create --assignee $ASSIGNE_ID --role "AcrPull" --scope $ACR_ID
```

- Gán quyền cho AKS (shorthand):
```bash
az aks update --name $AKS_NAME --resource-group $AKS_RG --attach-acr $ACR_NAME
```

- Kiểm tra role assignment:
```bash
az role assignment list --scope $ACR_ID --role "AcrPull" --output table
```

### Cấu hình Terraform (IaC)
```hcl
data "azurerm_container_registry" "acr" {
  name                = "exampleAcr"
  resource_group_name = "example-rg"
}

data "azurerm_user_assigned_identity" "identity" {
  name                = "example-identity"
  resource_group_name = "example-rg"
}

resource "azurerm_role_assignment" "acrpull_role" {
  scope                = data.azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = data.azurerm_user_assigned_identity.identity.principal_id
}
```

## Lỗi gặp phải và Cách khắc phục

- **Lỗi (logs):**
```
error from registry: authentication required, visit https://aka.ms/acr/authorization for more information. CorrelationId: f961e281-5e6c-42bd-8ab1-d435d9b7fc57
```
- **Nguyên nhân:** Docker Daemon chưa được xác thực với ACR. Mặc dù đã gán RBAC (Authorization), nhưng Docker không biết danh tính của người dùng, do đó bị từ chối ở lớp Authentication.
- **Cách khắc phục:** Chạy `az acr login --name <tên_acr>` để lấy token và inject vào `~/.docker/config.json`. Nếu môi trường pipeline hoặc WSL gặp vấn đề, dùng phương án dự phòng với `--expose-token` như trên.

## Khái niệm & Định nghĩa

| Thuật ngữ | Định nghĩa | Ví dụ minh hoạ |
|---|---|---|
| **Authentication (Xác thực)** | Quá trình chứng minh danh tính (bạn là ai). | Docker client gửi token hoặc username/password lên ACR. |
| **Authorization (Ủy quyền)** | Quá trình kiểm tra quyền hạn (bạn được phép làm gì). | RBAC kiểm tra role `AcrPush` đã được gán cho định danh `835b3045...` trên scope ACR đó. |
| **Control Plane (Mặt phẳng điều khiển)** | Các API quản lý tài nguyên Azure (ARM), thao tác như tạo ACR, gán RBAC. | Lệnh `az role assignment create` gọi ARM để thiết lập quyền. |
| **Data Plane (Mặt phẳng dữ liệu)** | Các API tương tác trực tiếp với dữ liệu (ví dụ: push/pull image, gọi REST API của ACR). | Lệnh `docker push` gọi API OCI Distribution của ACR. |
| **Cơ chế login của ACR** | Chuỗi OAuth 2.0 + OCI: 1) Azure CLI lấy Access Token từ Entra ID. 2) Gửi token đến endpoint `/oauth2/exchange` của ACR để đổi lấy ACR Refresh Token. 3) Azure CLI ghi Refresh Token vào `~/.docker/config.json`. 4) Docker client dùng token này trong Header `Authorization: Bearer <token>` khi gọi Data Plane API. | `az acr login` thực hiện toàn bộ quy trình này. |

## Các phương án đã cân nhắc

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
|---|---|---|---|
| Scope RBAC ở cấp Resource Group hoặc Subscription | Dễ quản lý, chỉ cần gán 1 lần cho nhiều ACR. | Cấp quyền `AcrPull` cho mọi registry trong scope, vi phạm least privilege, rủi ro bảo mật cao. | **Không** |
| Scope RBAC ở cấp ACR | An toàn, chỉ cấp đúng quyền cho đúng registry. | Quản lý nhiều assignment hơn nếu có nhiều registry. | **Có** |
| Sử dụng Admin User (username/password) | Đơn giản, không cần Entra ID. | Kém an toàn, dễ bị lộ, khó xoay vòng, không tích hợp với Managed Identity. | **Không** |
| Sử dụng Entra ID + RBAC + `az acr login` | Bảo mật cao, tích hợp với Managed Identity, tuân thủ OAuth2. | Cần thêm bước xác thực Docker client trước khi push/pull. | **Có** |

