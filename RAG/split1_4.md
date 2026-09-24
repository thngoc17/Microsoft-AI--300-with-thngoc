---
source_url: "https://gemini.google.com/app/fc207a488077901d"
conversation_date: "2026-07-16"
context_week: "Tuần 1"
conversation_types: [FIX_HA_TANG, LY_THUYET, TRANH_LUAN_QUYET_DINH, LAP_KE_HOACH]
ai300_domains: ["Thiết kế và triển khai hạ tầng MLOps", "GenAIOps infrastructure"]
technologies: ["Azure CLI", "Azure Resource Manager (ARM)", "Entra ID", "Storage Account", "Blob Storage", "WSL2", "Azure for Students", "RBAC"]
key_decision: "Dùng CLI + IaC thay vì ClickOps để cấp phát và vận hành hạ tầng Azure; khi gặp lỗi cần dọn sạch cache xác thực, đăng ký Resource Provider, và luôn khai báo tham số `--subscription` và `--auth-mode login` để tránh sai lệch context."
status: "resolved"
---

## Bối cảnh & Vấn đề

- **Lỗi xác thực & không tìm thấy Subscription:**
  - Lệnh `az storage account create` báo `SubscriptionNotFound` dù `az account list` hiển thị subscription đang ở trạng thái `Enabled`.
  - Debug log cho thấy API GET đến Resource Group thành công (mã 200), nhưng API POST đến Microsoft.Storage để kiểm tra tên trả về mã 404 cùng lỗi `SubscriptionNotFound`.
- **Lỗi tải lên Blob:**
  - Lệnh `az storage blob upload` không hỗ trợ thư mục; cần dùng `upload-batch`.
  - Lỗi DNS `[Errno -2] Name or service not known` do Storage Account chưa được tạo thành công.
  - Nhầm lẫn tham số `--destination`: đưa Resource Group vào thay vì Blob Container.
- **Tranh luận chiến lược:**
  - Người dùng đề xuất dùng giao diện web (Azure Portal) để "trực quan và tốt hơn" sau khi gặp nhiều lỗi CLI.
- **Yêu cầu lý thuyết:**
  - Người dùng yêu cầu tóm tắt chi tiết các điểm lý thuyết từ các thao tác dòng lệnh đã thực hiện.

## Quyết định cuối cùng & Lý do

- **KHÔNG dùng Azure Portal (ClickOps) để cấp phát hạ tầng**, vì:
  - Không thể tự động hóa, đưa vào CI/CD pipeline.
  - Không quản lý phiên bản (version control) được.
  - Không mở rộng (scalability) khi cần tạo nhiều tài nguyên.
  - Rủi ro sai sót do con người (human error) cao.
- **Dùng Azure CLI + tư duy Infrastructure as Code (IaC)**: đảm bảo tính nhất quán, tái sử dụng, và chính xác.
- **Khi tải dữ liệu lên Blob**: bắt buộc tạo Blob Container trước, dùng `upload-batch` với `--destination` là container, và luôn thêm `--auth-mode login`.
- **Với lỗi SubscriptionNotFound dù subscription hiển thị Enabled**:
  - Nguyên nhân 1 (nhiều khả năng nhất): Resource Provider `Microsoft.Storage` chưa được đăng ký (NotRegistered).
  - Nguyên nhân 2: Tài khoản Azure for Students đã hết credit hoặc ở trạng thái Read-Only Lock (vẫn cho GET, nhưng chặn POST/PUT/DELETE).
- **Giải pháp xác thực triệt để**: dọn sạch cache (`az account clear`), đăng nhập lại với đúng Tenant (`az login --tenant <TenantId>`), và luôn khai báo `--subscription` trong mọi lệnh.

## Lệnh và Cấu hình cụ thể đã dùng

### Lệnh xác thực và kiểm tra subscription
```bash
# Đăng nhập Azure
az login

# (Trên headless) az login --use-device-code

# Liệt kê subscription đang Enabled
az account list --query "[?state=='Enabled'].{Name:name, ID:id, TenantId:tenantId}" --output table

# Đặt subscription làm context (gây ra lỗi do cache hỏng)
az account set --subscription "f6b812fd-ef94-4ce1-948f-ea652339a497"

# Kiểm tra context hiện tại
az account show --query "id" -o tsv
```

### Dọn sạch cache và đăng nhập lại
```bash
# Dọn sạch cache xác thực cục bộ
az account clear

# Đăng nhập với Tenant cụ thể (ép token đúng ngữ cảnh)
az login --tenant 40127cd4-45f3-49a3-b05d-315a43a9f033

# Đặt lại subscription
az account set --subscription f6b812fd-ef94-4ce1-948f-ea652339a497
```

### Kiểm tra và đăng ký Resource Provider
```bash
# Kiểm tra trạng thái Microsoft.Storage
az provider show --namespace Microsoft.Storage --query "registrationState" -o tsv

# Nếu là NotRegistered, đăng ký (mất 1-3 phút)
az provider register --namespace Microsoft.Storage --wait

# Kiểm tra trạng thái subscription (có bị khóa ghi không?)
az account show --query "state" -o tsv
```

### Tạo Storage Account và Blob Container (đã sửa lỗi)
```bash
# Tạo Storage Account (bắt buộc thêm --subscription nếu cần)
az storage account create --name thngoc17 --resource-group mlogs-week1-rg --sku Standard_LRS

# Hoặc với --subscription rõ ràng
az storage account create --name thngoc17 --resource-group mlogs-week1-rg --sku Standard_LRS --subscription f6b812fd-ef94-4ce1-948f-ea652339a497

# Kiểm tra trạng thái cấp phát
az storage account show --name thngoc17 --resource-group mlogs-week1-rg --query "provisioningState" -o tsv

# Tạo Blob Container
az storage container create --account-name thngoc17 --name xv6-data --auth-mode login
```

### Upload dữ liệu đúng cách (upload-batch)
```bash
# Upload toàn bộ thư mục (recursive)
az storage blob upload-batch \
  --account-name thngoc17 \
  --destination xv6-data \
  --source xv6-labs-2024/ \
  --auth-mode login
```

### Debug lệnh để phân tích sâu
```bash
# Gắn cờ --debug để xem HTTP request/response
az storage account create --name thngoc17 --resource-group mlogs-week1-rg --sku Standard_LRS --debug
```

## Lỗi gặp phải và Cách khắc phục

| Lỗi / Vấn đề | Nguyên nhân gốc | Cách khắc phục / Quy tắc thiết lập |
| :--- | :--- | :--- |
| `(SubscriptionNotFound) Subscription f6b812fd... was not found.` | Cache token bị hỏng hoặc Resource Provider `Microsoft.Storage` chưa đăng ký; hoặc tài khoản bị khóa ghi (hết credit). | 1. `az account clear` + `az login --tenant <TenantId>`.<br>2. Kiểm tra và đăng ký provider: `az provider register --namespace Microsoft.Storage --wait`.<br>3. Kiểm tra trạng thái subscription: `az account show --query "state" -o tsv`. |
| **DNS lỗi** `Failed to resolve 'thngoc17.blob.core.windows.net'` | Storage Account chưa được tạo thành công; CLI gọi đến subdomain chưa tồn tại. | Khắc phục lỗi SubscriptionNotFound trước, tạo Storage Account thành công, rồi mới thao tác upload. |
| **Tham số sai** `--destination mlogs-week1-rg` | Nhầm lẫn Resource Group (ranh giới logic) với Blob Container (ranh giới lưu trữ). | **Quy tắc:** Tạo Blob Container trước, dùng tên container làm `--destination`. Không bao giờ đưa Resource Group vào tham số này. |
| **Lệnh `az storage blob upload` không chạy** | Lệnh này chỉ hỗ trợ tải file đơn lẻ, không hỗ trợ thư mục. | **Quy tắc:** Dùng `az storage blob upload-batch` cho thư mục, có cờ `--auth-mode login` để bảo mật. |
| **Thiếu tham số bảo mật** | Thiếu `--auth-mode login` khi thao tác với storage. | **Quy tắc:** Luôn thêm `--auth-mode login` để dùng token Entra ID thay vì truyền Account Key/SAS Token dạng plaintext. |

## Khái niệm & Định nghĩa

| Thuật ngữ | Định nghĩa | Ví dụ / Minh hoạ |
| :--- | :--- | :--- |
| **Resource Group** | Ranh giới logic (logical boundary) dùng để gom nhóm tài nguyên cho mục đích quản lý vòng đời, tính cước, phân quyền. | `mlogs-week1-rg` - nhóm chứa các tài nguyên, nhưng **không** phải nơi lưu trữ dữ liệu (không thể đẩy blob vào). |
| **Sub-resource / Blob Container** | Ranh giới lưu trữ (storage boundary) trong Storage Account. Dữ liệu bắt buộc phải nằm trong container. | `xv6-data` là container; dùng `--destination xv6-data` khi upload. |
| **Azure Resource Manager (ARM)** | Lớp điều phối trung tâm; nhận request từ CLI/Portal, định tuyến đến đúng Resource Provider (Microsoft.Storage, Microsoft.Compute...). | ARM là "cổng" duy nhất để giao tiếp với hạ tầng Azure; CLI chỉ là HTTP Client gói gọn REST API gửi đến ARM. |
| **Resource Provider** | Dịch vụ backend riêng biệt quản lý từng loại tài nguyên (Storage, Compute, Network...). | `Microsoft.Storage` - nếu chưa đăng ký (NotRegistered), ARM không thể định tuyến request, dẫn đến lỗi 404 / SubscriptionNotFound. |
| **Lazy Loading** | Cơ chế không tự động kích hoạt mọi Provider cho subscription mới để tiết kiệm tài nguyên. | Khi mới tạo subscription, `Microsoft.Storage` có thể ở trạng thái `NotRegistered`; cần đăng ký thủ công trước khi tạo Storage Account. |
| **Read-Only Lock (Billing Lock)** | Khóa ngầm kích hoạt khi tài khoản học thuật (Azure for Students) hết credit; vẫn cho GET (đọc), nhưng chặn POST/PUT/DELETE (ghi). | `az account show` vẫn trả về `Enabled`; nhưng `az storage account create` (POST) báo lỗi do bị chặn ở tầng thanh toán. |
| **ClickOps** | Thao tác quản trị hạ tầng qua giao diện đồ họa (Azure Portal) bằng click chuột. | **Hạn chế:** Không tự động hóa, không quản lý phiên bản, khó mở rộng, rủi ro sai sót cao. |
| **Infrastructure as Code (IaC)** | Quản lý hạ tầng bằng code (CLI script, Bicep, Terraform); mọi thay đổi được ghi nhận, lặp lại chính xác. | Dùng `az storage account create` trong script; nếu chạy lại 100 lần, vẫn cùng một trạng thái hạ tầng mong muốn (idempotency). |
| **Local Cache (MSAL Token)** | Tệp tin lưu token xác thực cục bộ (`~/.azure/msal_token_cache.json`) để giảm số lần gọi Entra ID. | `az account list` đọc từ cache, **không** phản ánh trạng thái thực tế theo thời gian thực; cần `az account clear` để làm sạch. |

## Các phương án đã cân nhắc

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
| :--- | :--- | :--- | :--- |
| Dùng Azure Portal (ClickOps) để tạo resource và upload | Trực quan, dễ dùng cho người mới; validator UI ngăn lỗi syntax. | Không auto, không version control, khó scale, lệ thuộc 100% vào sự chú ý của con người. | KHÔNG chọn (bị loại bỏ vì thiếu chuyên nghiệp và không phù hợp với CI/CD). |
| Dùng Azure CLI với context mặc định | Nhanh, ít tham số. | Dễ xảy ra lỗi sai lệch context (SubscriptionNotFound) khi đa tài khoản/tenant. | KHÔNG chọn (bị loại bỏ vì gây lỗi không mong muốn). |
| Dùng Azure CLI + khai báo tường minh `--subscription` và `--auth-mode login` | Chính xác, bảo mật, tránh context sai, phù hợp pipeline. | Yêu cầu tham số dài hơn, khó nhớ hơn một chút. | **ĐƯỢC CHỌN** - là khuyến nghị kiến trúc chuẩn để tránh lỗi vĩnh viễn. |
| Xóa cache thủ công thay vì `az account clear` | Có thể xóa chọn lọc một số file. | Rủi ro cao (xóa nhầm), không được khuyến cáo. | KHÔNG chọn (chỉ là fallback nếu `az account clear` không giải quyết triệt để). |