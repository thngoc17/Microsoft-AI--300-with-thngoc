---
source_url: "https://gemini.google.com/app/6f56cc3100d935e7"
conversation_date: "2026-07-30"
context_week: "N/A"
conversation_types: [FIX_HA_TANG, LY_THUYET, TRANH_LUAN_QUYET_DINH]
ai300_domains: ["Design and implement MLOps infrastructure"]
technologies: [Azure CLI, Microsoft Entra ID, Azure Resource Manager, Azure for Students, WSL, RBAC, Azure Lighthouse, Terraform, Docker, Python, GitHub Actions]
key_decision: "Azure CLI đã xác thực đúng vào Subscription Azure for Students nằm trực tiếp trong Tenant VNU-HCMUS, nhưng môi trường CLI vẫn phải được vận hành bằng standard user thay vì root trong WSL để tuân thủ Principle of Least Privilege."
status: resolved
---

## Bối cảnh & Vấn đề

Hội thoại bắt đầu với lỗi Azure CLI sau khi chạy `az login --use-device-code`: CLI truy vấn các tenant/subscription nhưng tenant `VNU-HCMUS` bị báo không có subscription khả dụng, mặc dù tài khoản đã có gói `Azure for Students`. 

Ban đầu response đưa ra giả thuyết rằng Subscription có thể nằm ở một Microsoft Account (MSA) hoặc Default Directory khác với tenant của trường và đề xuất xác định `Tenant ID` chứa Subscription rồi ép CLI đăng nhập vào tenant đó. 

Sau đó, `az account show` cho thấy giả thuyết trên **không còn đúng**: Subscription `Azure for Students` thực tế có `tenantId` và `homeTenantId` đều bằng Tenant VNU-HCMUS. Vì vậy lỗi ban đầu được quy về khả năng cache token cũ/hỏng hoặc độ trễ đồng bộ Entra ID. 

Một vấn đề kiến trúc khác được phát hiện: toàn bộ phiên Azure CLI đang chạy dưới `root@thngoc:~#`, được nhận định là WSL trên Windows. Điều này tạo vấn đề về Principle of Least Privilege và quyền sở hữu credential cache trong `~/.azure`. 

---

## Quyết định cuối cùng & Lý do

Azure CLI đã được xác nhận đang hoạt động đúng với Subscription:

* `name`: `Azure for Students`
* `state`: `Enabled`
* `id`: `f6b812fd-ef94-4ce1-948f-ea652339a497`
* `tenantId`: `40127cd4-45f3-49a3-b05d-315a43a9f033`
* `homeTenantId`: `40127cd4-45f3-49a3-b05d-315a43a9f033`
* `isDefault`: `true`

Điều này xác nhận CLI đã nhận diện đúng Subscription và mặc định sử dụng Subscription đó cho các lệnh Azure tiếp theo.  

**Phương án bị loại bỏ — ĐÃ LOẠI BỎ:** giả thuyết rằng Subscription `Azure for Students` nằm ngoài tenant `VNU-HCMUS`. Kết quả `az account show` chứng minh `tenantId == homeTenantId == VNU-HCMUS`, nên Subscription thực tế được liên kết trực tiếp với tenant của trường. 

**Quyết định môi trường vận hành:** không tiếp tục sử dụng `root` cho Azure CLI trong WSL. Credential cache nằm dưới `/root/.azure/`, khiến user thường có thể không đọc được token và đồng thời mở rộng blast radius nếu một dependency bị compromise. Chuẩn được đề xuất là standard user, chỉ dùng `sudo` khi thực sự cần quyền hệ điều hành. 

Định hướng cho automation/CI-CD: không sử dụng `user` interactive để tự động hóa; thay vào đó dùng `servicePrincipal` với RBAC giới hạn. 

---

## Lệnh và Cấu hình cụ thể đã dùng

Khắc phục/cache:

```bash
az account clear
```

Đăng nhập cưỡng chế theo tenant:

```bash
az login --tenant <TENANT_ID_CUA_BAN> --use-device-code
```

Kiểm tra Subscription:

```bash
az account list --output table
```

Lệnh kiểm tra trạng thái cuối cùng:

```bash
az account show
```

Output JSON được ghi nhận trong hội thoại:

```json
{ "environmentName": "AzureCloud", 
  "homeTenantId": "40127cd4-45f3-49a3-b05d-315a43a9f033", 
  "id": "f6b812fd-ef94-4ce1-948f-ea652339a497", 
  "isDefault": true, 
  "managedByTenants": [], 
  "name": "Azure for Students", 
  "state": "Enabled", 
  "tenantId": "40127cd4-45f3-49a3-b05d-315a43a9f033", 
  "user": { 
    "name": "23122012@student.hcmus.edu.vn", 
    "type": "user" } }
```

Bối cảnh shell:

```text
root@thngoc:~#
```

Khuyến nghị chuyển khỏi root:

```bash
exit
```

hoặc:

```bash
su - <tên_user_của_bạn>
```

Các artifact/lệnh trên được trích từ các phase xử lý lỗi tenant và xác minh Subscription.   

---

## Lỗi gặp phải và Cách khắc phục

**Lỗi 1 — Azure CLI không tìm thấy Subscription**

Thông báo:

```text
The following tenants don't contain accessible subscriptions. Use `az login --allow-no-subscriptions` to have tenant level access.
```

và:

```text
40127cd4-45f3-49a3-b05d-315a43a9f033 'VNU-HCMUS' No subscriptions found for
23122012@student.hcmus.edu.vn.
```

Khắc phục được đề xuất ban đầu: `az account clear` để loại bỏ cache đăng nhập, xác định Tenant ID thực tế của Subscription trong Azure Portal, sau đó dùng `az login --tenant ... --use-device-code`. 

**Điều chỉnh chẩn đoán:** sau khi chạy `az account show`, phát hiện Subscription thực tế nằm ngay trong tenant `VNU-HCMUS`. Vì vậy không thể giữ giả thuyết "Subscription nằm ở tenant khác"; lỗi trước đó phù hợp hơn với cache token hoặc propagation delay. 

**Lỗi/anti-pattern 2 — Chạy Azure CLI dưới root**

Credential cache bị gắn với `/root/.azure/`; các ứng dụng chạy bằng non-root user có thể gặp `Access Denied` khi truy cập credential của root. Ngoài ra việc để dependency chạy dưới root làm tăng blast radius khi có compromise.  

**Quy tắc phòng ngừa:** dùng standard user trong WSL; chỉ dùng `sudo` cho tác vụ thực sự yêu cầu đặc quyền hệ điều hành. 

**Lỗi/anti-pattern 3 — Dùng interactive user cho automation**

Hội thoại xác lập rằng các workload Docker/API/CI-CD như GitHub Actions không nên dùng `type: "user"`; cần dùng machine identity dạng `servicePrincipal` với RBAC giới hạn. 

---

## Khái niệm & Định nghĩa

**AzureCloud** → môi trường Azure public cloud mà CLI đang tương tác; giá trị này quyết định các API endpoint tương ứng. 

**Subscription ID (`id`)** → định danh của Azure Subscription; trong hội thoại được mô tả là billing boundary và resource-management boundary, nơi các resource như Virtual Machine, Storage Account hoặc Machine Learning Workspace được gắn vào. 

**Tenant ID / `homeTenantId`** → định danh Microsoft Entra ID Directory. Khi hai giá trị bằng nhau trong output này, tài khoản đang hoạt động trong home tenant của chính nó thay vì một tenant B2B guest khác. 

**`isDefault: true`** → Subscription này là context mặc định của Azure CLI; các lệnh Azure tiếp theo có thể sử dụng Subscription này mà không cần truyền thêm `--subscription`. 

**`state: "Enabled"`** → Subscription hiện ở trạng thái hoạt động và có thể tiếp tục provision resource theo diễn giải của hội thoại. 

**`managedByTenants: []`** → không có delegated management tenant nào được liệt kê trong output; hội thoại liên hệ trường này với Azure Lighthouse và mô hình quản trị chéo tenant. 

**`user.type: "user"`** → token hiện tại thuộc về interactive user. Định hướng automation là chuyển sang `servicePrincipal` với RBAC hạn chế. 

**Principle of Least Privilege (PoLP)** → không cấp quyền cao hơn mức cần thiết; trong case này dẫn đến yêu cầu không vận hành Azure CLI thường xuyên dưới `root`. 


