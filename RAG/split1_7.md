---
source_url: https://gemini.google.com/app/10804c29d1fdd8ff
conversation_date: N/A
context_week: N/A
conversation_types: [FIX_HA_TANG, LY_THUYET]
ai300_domains: [Thiết kế và triển khai hạ tầng MLOps, Hạ tầng GenAIOps]
technologies: [Azure CLI, Azure Container Registry (ACR), Azure Storage Account, Azure Resource Manager (ARM)]
key_decision: "Khi tạo tài nguyên Azure, cần xác định đúng Resource Provider (namespace) cần đăng ký (Microsoft.ContainerRegistry cho ACR, Microsoft.Storage cho Blob Storage) do các dịch vụ này vận hành độc lập; việc nhầm lẫn từ khóa 'container' là nguyên nhân gây lỗi MissingSubscriptionRegistration."
status: resolved
---

## Bối cảnh & Vấn đề
Người dùng gặp lỗi **`MissingSubscriptionRegistration`** khi thực hiện lệnh tạo Azure Container Registry (ACR) bằng Azure CLI:
```bash
az acr create --resource-group mlogs-week1-rg --name chatbottom --sku Basic --location "eastasia"
```
Lỗi cho biết subscription chưa được đăng ký để sử dụng namespace `Microsoft.ContainerRegistry`.

Sau đó, người dùng thắc mắc vì sao dù đã đăng ký Resource Provider cho "blob container" trước đó, nhưng cùng một phiên lại yêu cầu đăng ký lại cho ACR.

## Quyết định cuối cùng & Lý do
- **Quyết định:** Thực hiện đăng ký Resource Provider `Microsoft.ContainerRegistry` cho Subscription và kiểm tra trạng thái.
- **Lý do:** Resource Provider cần được đăng ký rõ ràng trước khi có thể tạo tài nguyên thuộc namespace đó. Quá trình này là bất đồng bộ và cần được xác nhận hoàn tất.

- **Điểm phản biện quan trọng:** KHÔNG nhầm lẫn Resource Provider của **Azure Container Registry** (`Microsoft.ContainerRegistry`) với Resource Provider của **Azure Storage Account/Blob Container** (`Microsoft.Storage`). Đây là hai dịch vụ và hai namespace hoàn toàn khác nhau, mặc dù đều sử dụng từ khóa "container". Việc hiểu sai là một lỗ hổng nhận thức về kiến trúc Azure Resource Manager (ARM).

## Lệnh và Cấu hình cụ thể đã dùng
**Đăng ký Resource Provider:**
```bash
az provider register --namespace Microsoft.ContainerRegistry
```

**Kiểm tra trạng thái đăng ký:**
```bash
az provider show --namespace Microsoft.ContainerRegistry --query "registrationState" --output tsv
```
*Cần đợi đến khi trạng thái chuyển từ `Registering` thành `Registered`.*

**Lệnh tạo ACR sau khi đăng ký thành công:**
```bash
az acr create --resource-group mlogs-week1-rg --name chatbotwin --sku Basic --location "eastasia"
```

**Đăng ký Resource Provider cho Azure Storage (nếu cần):**
```bash
az provider register --namespace Microsoft.Storage
az provider show --namespace Microsoft.Storage --query "registrationState" --output tsv
```

## Lỗi gặp phải và Cách khắc phục

| Lỗi / Vấn đề | Nguyên nhân | Cách khắc phục |
| :--- | :--- | :--- |
| **Lỗi `MissingSubscriptionRegistration`** với namespace `Microsoft.ContainerRegistry` | Subscription chưa được đăng ký Resource Provider để sử dụng dịch vụ ACR. | Thực hiện lệnh `az provider register --namespace Microsoft.ContainerRegistry`. Đây là một thao tác cần thiết và không thể bỏ qua. |
| **Quy trình Provisioning thủ công bị gián đoạn** | Thiếu bước pre-flight check để kiểm tra và tự động đăng ký Resource Provider trong quy trình IaC hoặc CI/CD. | Nên tích hợp bước kiểm tra và tự động đăng ký Resource Provider vào pipeline (ví dụ: bằng Terraform, Bicep, hoặc script Bash/PowerShell). |
| **Nhầm lẫn khái niệm "container"** | Người dùng nhầm lẫn `Microsoft.ContainerRegistry` (lưu trữ Docker images) với `Microsoft.Storage` (lưu trữ Blob). | Phân biệt rõ ràng các namespace theo từng dịch vụ. Mỗi loại tài nguyên (Compute, Storage, Container Registry...) thuộc về một Resource Provider độc lập và cần đăng ký riêng. |
| **Lỗi `AuthorizationFailed` khi đăng ký RP** (đề cập trong phân tích) | Tài khoản hoặc Service Principal không có quyền ghi ở cấp Subscription (ví dụ: chỉ có quyền ở Resource Group). | Yêu cầu người quản trị Subscription gán quyền `Contributor` hoặc `Owner` ở cấp Subscription hoặc thực hiện đăng ký Resource Provider. |

## Khái niệm & Định nghĩa

### Resource Provider (Nhà cung cấp tài nguyên)
- **Định nghĩa:** Là một dịch vụ trong Azure cung cấp các API để quản lý một loại tài nguyên cụ thể (ví dụ: `Microsoft.Compute` cho VM, `Microsoft.Storage` cho Storage Account). Mỗi Resource Provider có một tập hợp các loại tài nguyên (resource types) riêng.
- **Ví dụ:**
    - **`Microsoft.ContainerRegistry`**: Cung cấp và quản lý tài nguyên **Azure Container Registry** (dùng để lưu trữ Docker images).
    - **`Microsoft.Storage`**: Cung cấp và quản lý tài nguyên **Storage Account** (dùng để lưu trữ dữ liệu như Blob, File, Table).

### Azure Resource Manager (ARM)
- **Định nghĩa:** Là tầng quản lý và triển khai dịch vụ chính của Azure. Nó cung cấp một khuôn khổ thống nhất để quản lý, bảo mật và giám sát tất cả tài nguyên trong một subscription. Các Resource Provider hoạt động dưới sự quản lý của ARM.
- **Ví dụ:** Khi bạn chạy `az acr create`, CLI sẽ gửi yêu cầu đến ARM, sau đó ARM định tuyến yêu cầu đó đến API của Resource Provider `Microsoft.ContainerRegistry` để tạo tài nguyên.

### Namespace (Không gian tên)
- **Định nghĩa:** Là định danh duy nhất cho một Resource Provider trong hệ thống Azure. Mỗi lệnh tạo tài nguyên (như `az acr create`) sẽ chỉ định một namespace (ngầm định hoặc tường minh) để xác định đúng Resource Provider cần gọi.
- **Ví dụ:** Trong lệnh `az acr create`, namespace là `Microsoft.ContainerRegistry`. Trong lệnh `az storage account create`, namespace là `Microsoft.Storage`.