---
source_url: https://gemini.google.com/app/272ae9644d5c222c
conversation_date: 2026-07-30
context_week: "Tuần 1"
conversation_types: [FIX_HA_TANG, TRANH_LUAN_QUYET_DINH]
ai300_domains: ["Design and implement MLOps infrastructure"]
technologies: ["Azure CLI", "Azure Storage Account", "Azure Resource Group", "Azure Policy", "Entra ID", "WSL"]
key_decision: "Xác định nguyên nhân lỗi Storage Account là do chưa đăng ký Resource Provider Microsoft.Storage và chính sách vùng của tài khoản Azure for Students yêu cầu chỉ định region eastus; cần khai báo tường minh tham số --location và --subscription để tránh lỗi."
status: resolved
---

## Bối cảnh & Vấn đề

Người dùng (root@thngoc) gặp lỗi `SubscriptionNotFound` liên tục khi cố gắng tạo Storage Account trên Azure CLI.

- **Vấn đề 1:** Lệnh `az storage account create` ban đầu thất bại với lỗi: `(SubscriptionNotFound) Subscription f6b812fd-ef94-4ce1-948f-ea652339a497 was not found.`
- **Vấn đề 2:** Mặc dù `az account list` cho thấy Subscription `f6b812fd-ef94-4ce1-948f-ea652339a497` ở trạng thái `Enabled`, và `az account set` thành công, lỗi SubscriptionNotFound vẫn tiếp diễn ngay cả khi thêm cờ `--subscription`.
- **Vấn đề 3:** Sau khi thêm cờ `--debug`, log cho thấy lệnh `GET` tới Resource Group thành công (mã 200), nhưng lệnh `POST` tới `Microsoft.Storage/checkNameAvailability` lại thất bại với mã 404 và lỗi SubscriptionNotFound.

## Quyết định cuối cùng & Lý do

1.  **Xác thực và làm sạch cache:** Hệ thống khuyến nghị xóa cache xác thực (`az account clear`) và đăng nhập lại với tenant ID cụ thể (`az login --tenant 40127cd4-45f3-49a3-b05d-315a43a9f033`) để giải quyết lỗi token không đồng bộ.
2.  **Đăng ký Resource Provider:** Nguyên nhân chính của lỗi `SubscriptionNotFound` ẩn là do `Microsoft.Storage` chưa được đăng ký. Cần chạy `az provider register --namespace Microsoft.Storage --wait`.
3.  **Tường minh hóa vùng (Region):** Lỗi cuối cùng (HTTP 403 - `RequestDisallowedByAzure`) là do chính sách của gói "Azure for Students" hạn chế vùng triển khai. Phải khai báo rõ ràng tham số `--location eastus` trong lệnh tạo Storage Account.
4.  **KHÔNG dùng Azure Portal (ClickOps) để triển khai sản xuất:** Mặc dù portal có vẻ dễ dàng hơn, nhưng nó thiếu khả năng tự động hóa, quản lý phiên bản và dễ gây lỗi do con người. CLI/IaC là bắt buộc cho các pipeline CI/CD và môi trường sản xuất.

## Lệnh và Cấu hình cụ thể đã dùng

**Lệnh chẩn đoán và khắc phục:**

```bash
# Xóa cache xác thực
az account clear

# Đăng nhập lại với tenant chính xác
az login --tenant 40127cd4-45f3-49a3-b05d-315a43a9f033

# Đặt lại subscription
az account set --subscription f6b812fd-ef94-4ce1-948f-ea652339a497

# Kiểm tra trạng thái Resource Provider
az provider show --namespace Microsoft.Storage --query "registrationState" -o tsv

# Đăng ký Resource Provider (nếu chưa đăng ký)
az provider register --namespace Microsoft.Storage --wait

# Lệnh thành công cuối cùng (đã thêm --location)
az storage account create \
  --name thngoc17 \
  --resource-group mlogs-week1-rg \
  --sku Standard_LRS \
  --location eastus

# Lệnh đẩy dữ liệu lên blob (đã sửa tham số)
az storage blob upload-batch \
  --account-name thngoc17 \
  --destination xv6-data \
  --source xv6-labs-2024/ \
  --auth-mode login
```

## Lỗi gặp phải và Cách khắc phục

| Lỗi | Nguyên nhân | Cách khắc phục |
| :--- | :--- | :--- |
| `(SubscriptionNotFound) Subscription ... was not found.` | Token xác thực bị hỏng hoặc cache cục bộ không đồng bộ. | `az account clear` và `az login --tenant <TenantId>`. |
| `(SubscriptionNotFound) ... POST ... checkNameAvailability ... 404` | Resource Provider `Microsoft.Storage` chưa được đăng ký. | `az provider register --namespace Microsoft.Storage --wait`. |
| `(RequestDisallowedByAzure) Resource 'thngoc17' was disallowed by Azure...` | Chính sách Azure Policy (tài khoản Student) cấm triển khai ở region `southeastasia`. | Khai báo tham số `--location eastus` (hoặc region được hỗ trợ) một cách tường minh. |
| `Failed to resolve 'thngoc17.blob.core.windows.net'` | Storage Account chưa được tạo thành công do các lỗi trên. | Giải quyết các lỗi trước và đảm bảo Storage Account đã được cấp phát. |
| Tham số `--destination mlogs-week1-rg` trong lệnh upload | Nhầm lẫn giữa Resource Group và Blob Container. | Sửa thành tên Container, ví dụ: `--destination xv6-data`. |

## Các phương án đã cân nhắc

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
| :--- | :--- | :--- | :--- |
| **Sử dụng Azure Portal (GUI)** | Trực quan, dễ thao tác với menu thả xuống. | Không thể tự động hóa (CI/CD), không quản lý phiên bản, dễ sai sót do con người. | **KHÔNG**. Bị loại bỏ cho mục đích triển khai (Provisioning) và vận hành (Operations). |
| **Sử dụng Azure CLI (với tham số tường minh)** | Tự động hóa, quản lý phiên bản (Git), nhất quán, mở rộng dễ dàng. | Yêu cầu nhập lệnh, đôi khi lỗi mơ hồ cần debug sâu. | **CÓ**. Là lựa chọn bắt buộc. Yêu cầu khai báo rõ `--subscription` và `--location`. |

