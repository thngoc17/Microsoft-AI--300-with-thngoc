---
source_url: https://gemini.google.com/app/4af62396e13c0abe
conversation_date: 2026-07-16
context_week: N/A
conversation_types: [FIX_HA_TANG, TRANH_LUAN_QUYET_DINH, LY_THUYET]
ai300_domains: ["Design and implement MLOps infrastructure", "Model lifecycle"]
technologies: ["Azure Storage", "Azure Blob Storage", "Azure CLI", "AzCopy", "RBAC", "Azure Entra ID (Azure AD)"]
key_decision: "Sự cố upload blob do nhầm destination (resource group thay vì container) và độ trễ RBAC được khắc phục bằng cách sử dụng `--auth-mode key` kết hợp chỉ định đúng container; download batch yêu cầu tạo thư mục đích mới; đối với file checkpoint AI dung lượng lớn, khuyến nghị dùng AzCopy thay vì CLI."
status: resolved
---

## Bối cảnh & Vấn đề

- **Tạo container thành công** nhưng lệnh `az storage blob upload-batch` liên tục thất bại do:
  - **Sai đối tượng đích**: Tham số `--destination` được truyền giá trị `mlogs-week1-rg` – đây là tên **Resource Group**, không phải **Blob Container**. Hậu tố `-rg` khẳng định đó là Resource Group, dẫn đến lỗi `ContainerNotFound`.
  - **Phân quyền RBAC chưa kịp lan tỏa**: Sau khi gán role `Storage Blob Data Contributor` cho user, lệnh upload với `--auth-mode login` vẫn báo `You do not have the required permissions...` do độ trễ nhất quán cuối (eventual consistency) của Azure Entra ID.
- **Yêu cầu tải dữ liệu từ storage về local** (download batch) và xử lý các loại file đặc thù (log, checkpoint model AI).

## Quyết định cuối cùng & Lý do

- **Sử dụng `--auth-mode key` để upload/download ngay lập tức** thay vì chờ RBAC propagate – phù hợp với môi trường cá nhân hoặc fix lỗi tạm thời.
- **Chỉ định đúng container** (`xv6-demo`) trong tham số `--destination` (upload) và `--source` (download).
- **Tạo thư mục cục bộ mới** (`xv6-labs-downloaded`) khi download để tránh ghi đè dữ liệu hiện có.
- **Đối với log file** (nhiều file nhỏ): dùng Azure CLI với tham số `--pattern` để lọc.
- **Đối với AI model checkpoint** (file dung lượng lớn, vài GB đến hàng trăm GB): **KHÔNG dùng CLI** vì giới hạn hiệu năng và khả năng phục hồi, mà dùng **AzCopy** – công cụ chuyên dụng hỗ trợ parallelism, tự động phục hồi kết nối, và tối ưu băng thông.

## Lệnh và Cấu hình cụ thể đã dùng

**Tạo container (thành công):**
```bash
az storage container create \
  --name xv6-demo \
  --account-name thngoc17
```

**Lệnh upload-batch gặp lỗi (sai destination – dùng resource group):**
```bash
az storage blob upload-batch \
  --account-name thngoc17 \
  --destination mlogs-week1-rg \
  --source xv6-labs-2024/ \
  --auth-mode login
```

**Gán role RBAC (thành công nhưng chưa hiệu lực ngay):**
```bash
az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee "23122012@student.hcmus.edu.vn" \
  --scope "subscriptions/f6b812fd-ef94-4ce1-948f-ea652339a497/resourceGroups/mlogs-week1-rg/providers/Microsoft.Storage/storageAccounts/thngoc17"
```

**Lệnh upload-batch với `--auth-mode key` nhưng vẫn sai destination (gây lỗi ContainerNotFound):**
```bash
az storage blob upload-batch \
  --account-name thngoc17 \
  --destination mlogs-week1-rg \
  --source xv6-labs-2024/ \
  --auth-mode key
```

**Lệnh upload-batch đã sửa (đúng container + dùng key):**
```bash
az storage blob upload-batch \
  --account-name thngoc17 \
  --destination xv6-demo \
  --source xv6-labs-2024/ \
  --auth-mode key
```

**Lệnh download-batch an toàn (tạo thư mục mới):**
```bash
# Tạo thư mục cách ly
mkdir -p xv6-labs-downloaded

# Thực hiện download
az storage blob download-batch \
  --account-name thngoc17 \
  --source xv6-demo \
  --destination xv6-labs-downloaded/ \
  --auth-mode key
```

## Lỗi gặp phải và Cách khắc phục

| Lỗi | Nguyên nhân | Cách khắc phục |
|-----|-------------|----------------|
| `ContainerNotFound` | `--destination` trỏ vào Resource Group (`mlogs-week1-rg`) thay vì tên container (`xv6-demo`) | Sửa tham số `--destination` (hoặc `--source` khi download) thành đúng tên container đã tạo |
| `You do not have the required permissions...` (khi dùng `--auth-mode login`) | Role assignment mới chưa được truyền bá đủ trong hệ thống Azure (eventual consistency, thường 5–30 phút) | Chờ 10–15 phút hoặc dùng `--auth-mode key` (truy vấn account key) để thực thi ngay |
| **Rủi ro ghi đè dữ liệu cục bộ** | Khi download về cùng thư mục nguồn đã tồn tại, các file sẽ bị thay thế | Tạo thư mục đích mới (ví dụ `xv6-labs-downloaded`) để cách ly |

## Khái niệm & Định nghĩa

- **RBAC (Role-Based Access Control) trong Azure Storage**: Các vai trò như `Storage Blob Data Contributor` cho phép thực hiện thao tác đọc/ghi dữ liệu blob. Khi sử dụng `--auth-mode login`, CLI yêu cầu token từ Azure AD dựa trên RBAC.
- **Eventual consistency (nhất quán cuối)**: Các thay đổi về role assignment không xuất hiện tức thời trên toàn hệ thống; cần thời gian để cập nhật token và cache, dẫn đến lỗi permission ngay sau khi gán role.
- **Container vs Resource Group**:
  - **Container** là đơn vị chứa blob bên trong Storage Account (giống như thư mục gốc).
  - **Resource Group** là nhóm logic chứa nhiều tài nguyên Azure (không phải đích của lệnh blob).
- **AzCopy**: Công cụ dòng lệnh hiệu năng cao dành riêng cho Azure Storage, hỗ trợ tải lên/tải xuống hàng loạt với parallelism, cơ chế resume, và tối ưu cho file dung lượng lớn.

## Các phương án đã cân nhắc

### Phương án xác thực cho upload/download

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
|-----------|---------|------------|------------|
| `--auth-mode login` (dùng Azure AD) | Bảo mật tốt hơn, không cần quản lý key | Phụ thuộc vào RBAC; cần thời gian propagate role; có thể thất bại nếu role chưa áp dụng | Không chọn trong tình huống khẩn cấp (fix lỗi) |
| `--auth-mode key` (dùng account key) | Thực thi ngay lập tức, không phụ thuộc RBAC | Kém bảo mật hơn; key có thể bị lộ trong log | **Được chọn** để khắc phục nhanh |

### Công cụ tải file lên/xuống

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
|-----------|---------|------------|------------|
| **Azure CLI** (`az storage blob upload-batch/download-batch`) | Tích hợp sẵn, dễ dùng với script, hỗ trợ `--pattern` lọc file | Hiệu năng kém với file lớn; không hỗ trợ resume tốt | Dùng cho log (file nhỏ, nhiều file) |
| **AzCopy** | Hiệu năng cao, parallelism, tự động resume, tối ưu băng thông | Cần cài đặt riêng; cú pháp khác CLI | **Được chọn** cho AI model checkpoint (file lớn) |

