---
source_url: "[https://gemini.google.com/app/97b5b225d24adfcc](https://gemini.google.com/app/97b5b225d24adfcc)"
conversation_date: "2026-07-30"
context_week: "Tuần 1"
conversation_types: [LAP_KE_HOACH, TRANH_LUAN_QUYET_DINH, FIX_HA_TANG, LY_THUYET]
ai300_domains:
* "Design and implement MLOps infrastructure"
* "Model lifecycle"
technologies:
* "Azure"
* "Azure CLI"
* "WSL2"
* "Ubuntu"
* "Azure Portal"
* "Azure Resource Group"
* "Azure Storage Account"
* "Blob Storage"
* "Azure Container Registry (ACR)"
* "RBAC"
* "Managed Identity"
* "Bash"
* "Azure for Students"
* "Pay-As-You-Go (PAYG)"
* "AI-300 Study Guide"
key_decision: "Tuần 1 phải được triển khai theo mô hình WSL2 + Azure CLI First, mọi tài nguyên tạo/sửa/xóa bằng CLI và phải áp dụng Cost Governance cùng chiến lược tạo lúc học - xóa lúc nghỉ khi dùng PAYG."
status: open_question
---

## Bối cảnh & Vấn đề

Hội thoại bắt đầu từ việc xây dựng roadmap AI-300 kéo dài 12 tuần. Tuần 1 được xác định là **Nhập môn Azure + CLI**, tập trung vào nền tảng MLOps: Azure account, Azure CLI, Resource Group, Subscription, Storage Account, Container Registry và RBAC. Đây là phần nền tảng cho các tuần sau về Azure ML, Docker, deployment, CI/CD, Bicep và security. 

Mục tiêu cụ thể của Tuần 1 được định hướng không phải train model mà là xây dựng tư duy Cloud/MLOps Engineer, làm quen CLI và quản lý tài nguyên hạ tầng. 

Môi trường phát triển là Windows. Kiến trúc được yêu cầu chuyển sang WSL2 Ubuntu thay vì làm MLOps trực tiếp trên PowerShell/CMD. Đồng thời đặt nguyên tắc **"CLI First"**: tạo, chỉnh sửa và xóa resource phải qua Azure CLI; Azure Portal chỉ dùng để verify kết quả. 

Một vấn đề phát sinh sau đó là tài khoản Azure cá nhân không nhận được Free Account và phải dùng **Pay-As-You-Go (PAYG)**. Cuộc trao đổi chuyển sang bài toán Cost Governance và kiểm soát chi phí. 

Cuối phase, xuất hiện lỗi hạ tầng:

`(SubscriptionNotFound) Subscription f6b812fd-ef94-4ce1-948f-ea652339a497 was not found.`

`Code: SubscriptionNotFound`

`Message: Subscription f6b812fd-ef94-4ce1-948f-ea652339a497 was not found.` 

## Quyết định cuối cùng & Lý do

### Kiến trúc/môi trường được chọn

**WSL2 Ubuntu + Azure CLI First** được chọn làm môi trường thực hành.

Lý do:

* Không dùng PowerShell/CMD thuần cho MLOps.
* Các container, CI/CD pipeline và automation script trong roadmap sẽ chạy trên Linux.
* Dùng WSL2 từ đầu nhằm tránh các vấn đề path/environment khi chuyển sang Docker ở Tuần 3. 

### Quy tắc thao tác resource

Mọi thao tác:

* tạo resource,
* chỉnh sửa resource,
* xóa resource

đều phải thực hiện qua Azure CLI.

Azure Portal chỉ là công cụ kiểm tra lại kết quả. 

### RBAC thay vì shared credential

Thiết kế security ưu tiên **RBAC + Managed Identity** thay vì dùng chung Access Key/Connection String. RBAC được phân tích theo ba thành phần:

* Security Principal: Ai/Cái gì?
* Role Definition: Được làm gì?
* Scope: Ở đâu? 

Một điểm kiến thức được thiết lập rõ: quyền `Owner` ở Resource Group **không mặc nhiên đồng nghĩa** với quyền đọc/ghi data trong Blob Storage; cần role về Data riêng biệt. 

### Tài khoản Azure: phương án được cân nhắc

**Ưu tiên 1: Azure for Students**

Tài khoản Free Trial bị từ chối thì trước tiên thử Azure for Students. Nguồn hội thoại nêu chương trình này cung cấp `100 USD credit` trong `12 tháng` và không yêu cầu thẻ tín dụng/thẻ ghi nợ; cần email học tập được Microsoft xác thực. 

**Phương án dự phòng: PAYG**

Nếu bắt buộc phải dùng PAYG bằng tiền cá nhân thì phải chuyển trọng tâm sang Cost Governance, theo dõi cách tính phí và dọn resource thường xuyên. 

### Các phương án bị loại bỏ / không ưu tiên

**KHÔNG dùng PowerShell/CMD thuần cho MLOps** vì môi trường MLOps/Docker/CI-CD/automation được định hướng Linux, và WSL2 giúp tránh xung đột path/environment về sau. 

**KHÔNG tiếp tục coi Azure Portal là giao diện chính để provision resource**; Portal chỉ dùng để verify, còn thao tác thật phải đi qua Azure CLI. 

**KHÔNG dùng Access Key/Connection String làm mô hình quyền truy cập chính**; hướng được chốt là RBAC và Managed Identity. 

## Lệnh và Cấu hình cụ thể đã dùng

### Phase: Ngày 1 - Identity & Authentication

```bash
apt-get install azure-cli
```

```bash
az login
```

```bash
az account show
```

Chỉ tiêu là đọc được:

* Tenant ID
* Subscription ID
* User 

### Phase: Ngày 2 - Resource Group

```bash
az group create --name mlogs-week1-rg --location southeastasia
```

```bash
az group list --output table
```

Region fallback khi gặp hạn chế quota:

```text
--location eastus
```

hoặc:

```text
--location westus2
```

Nguồn cũng yêu cầu gắn tag cho RG, ví dụ `Environment=Dev`, `Project=TelegramBot`. 

### Phase: Ngày 3 - Storage Account / Blob

```bash
az storage account create --name <tên_unique> --resource-group mlogs-week1-rg --sku
Standard_LRS
```

Thực hành upload:

```bash
az storage blob upload
```

Tên Storage Account phải viết liền, không dấu, chữ thường và unique toàn cầu. 

### Phase: Ngày 4 - Azure Container Registry

```bash
az acr create --resource-group mlogs-week1-rg --name <tên_acr_unique> --sku Basic
```

```bash
az acr login --name <tên_acr_unique>
```

Điều kiện hoàn thành: terminal báo `Login Succeeded`. 

### Phase: Ngày 5 - RBAC

```bash
az role assignment create
```

Role được yêu cầu là `Storage Blob Data Contributor` trên scope là Storage Account tạo ở Ngày 3. 

### Phase: Ngày 6 - Bash automation

Tạo file:

```text
setup.sh
```

Script phải ghép tuần tự các thao tác:

```text
Tạo RG -> Tạo Storage -> Tạo ACR
```

và sử dụng biến môi trường để tái sử dụng. 

### Phase: Ngày 7 - Cleanup

```bash
az group delete --name mlogs-week1-rg --no-wait --yes
```

Cơ chế dọn dẹp cuối mỗi buổi trong tài khoản PAYG:

```bash
az group delete --name mlogs-week1-rg --yes --no-wait
```

Hai lệnh cùng phục vụ mục tiêu xóa toàn bộ Resource Group và resource bên trong.  

### Phase: Cost Governance - Budget Alert

```bash
az monitor budget create \
  --name "Week1CostBudget" \
  --amount 5 \
  --time-grain Monthly \
  --start-date "2026-07-01" \
  --end-date "2026-12-31" \
  --resource-group "mlogs-week1-rg" \
  --notifications "ContactEmail=<email_cua_ban>,Threshold=80,NotificationType=Actual"
```

Ngưỡng được mô tả là cảnh báo khi chi phí thực tế đạt 80% của budget `5 USD`, tức `4 USD`. 

### Cấu hình/chi phí được nêu

| Thành phần               | Thiết lập/note trong hội thoại              |
| ------------------------ | ------------------------------------------- |
| Resource Group           | Miễn phí                                    |
| Storage Account          | `Standard_LRS`, chỉ upload file nhỏ để test |
| Azure Container Registry | `Basic`                                     |
| RBAC / Identity          | Miễn phí                                    |
| PAYG budget alert        | `5 USD`/tháng                               |
| Alert threshold          | `80%`                                       |
| Cleanup strategy         | Tạo lúc học - xóa lúc nghỉ                  |

Các mức chi phí ước tính trong hội thoại cho Storage là `< $0.01`, ACR khoảng `$0.16 - $0.32`, tổng Tuần 1 được ước tính `chưa tới 0.50 USD` nếu cleanup nghiêm ngặt. 

## Lỗi gặp phải và Cách khắc phục

### `SubscriptionNotFound`

Lỗi xuất hiện:

```text
(SubscriptionNotFound) Subscription f6b812fd-ef94-4ce1-948f-ea652339a497 was not found. Code: SubscriptionNotFound
Message: Subscription f6b812fd-ef94-4ce1-948f-ea652339a497 was not found.
```

Nguồn hội thoại chỉ ghi nhận lỗi và kết thúc tại đó; **chưa có response tiếp theo chứa nguyên nhân hoặc cách khắc phục**. Vì vậy trạng thái của lỗi này là **chưa được giải quyết trong nguồn**. 

### Quota / Region

Risk được nhận diện: tài khoản Free có thể bị giới hạn resource ở một số region. Quy tắc xử lý trong hội thoại là thử region khác, cụ thể:

```text
eastus
```

hoặc:

```text
westus2
```



### Độ trễ RBAC

Azure có thể mất `1-5 phút` để RBAC assignment có hiệu lực. Nếu gặp `Access Denied` ngay sau khi cấp role, quy tắc trong hội thoại là **không vội sửa code**, mà đợi vài phút rồi thử lại. 

### Anti-pattern chi phí

Quên xóa resource trên PAYG được xem là lỗi vận hành nghiêm trọng. Quy tắc được thiết lập là:

**"Tạo lúc học - Xóa lúc nghỉ"**

Cuối mỗi buổi phải xóa Resource Group để đưa chi phí về `0` ngay lập tức theo chiến lược đã nêu. 

## Lộ trình chi tiết

### Ngày 1 - Identity & Authentication

* Đăng ký Azure account.
* Cài Azure CLI trong WSL2.
* `az login`.
* Chạy `az account show`.
* Hiểu Tenant ID, Subscription ID và User.

**Chỉ tiêu hoàn thành:** xác định đúng ba thông số identity/subscription/user. 

### Ngày 2 - Resource Group

* Tạo `mlogs-week1-rg`.
* Chọn region.
* Gắn tag.
* Kiểm tra bằng `az group list --output table`.
* Verify trên Azure Portal.

**Chỉ tiêu hoàn thành:** quan sát được RG qua CLI và Portal. 

### Ngày 3 - Storage

* Tạo Storage Account.
* Tạo Blob Container.
* Upload file nhỏ từ Telegram Chatbot Qwen.
* Download lại về WSL2.

**Chỉ tiêu hoàn thành:** phân biệt Storage Account và Blob Container. 

### Ngày 4 - ACR

* Tạo ACR `Basic`.
* `az acr login`.
* Chuẩn bị hạ tầng cho Qwen/YOLO ở các tuần tiếp theo.

**Chỉ tiêu hoàn thành:** terminal báo `Login Succeeded`. 

### Ngày 5 - RBAC

* Xác định Object ID.
* Dùng `az role assignment create`.
* Cấp `Storage Blob Data Contributor` trên Storage Account.

**Chỉ tiêu hoàn thành:** hiểu mô hình Security Principal + Role Definition + Scope và hiểu Owner không thay thế Data role. 

### Ngày 6 - Infrastructure automation

* Viết `setup.sh`.
* Ghép tạo RG -> Storage -> ACR.
* Dùng variables.
* Chạy script một lần để provision toàn bộ hạ tầng.

**Chỉ tiêu hoàn thành:** provision tự động mà không cần thao tác thủ công. 

### Ngày 7 - Cleanup & AI-300 mapping

* Xóa `mlogs-week1-rg`.
* Review AI-300 Study Guide, Domain `Design and implement MLOps infrastructure`.
* Đối chiếu Identity, RBAC, Storage và ACR.

**Chỉ tiêu hoàn thành:** Azure bill = `$0.00`. 

## Khái niệm & Định nghĩa

### Resource Group

**Định nghĩa:** logical boundary dùng để gom và quản lý vòng đời resource; xóa RG sẽ xóa các resource bên trong.

**Ví dụ trong hội thoại:** `mlogs-week1-rg`. 

### RBAC

**Định nghĩa:** mô hình cấp quyền dựa trên ba thành phần Security Principal + Role Definition + Scope.

**Ví dụ trong hội thoại:** cấp `Storage Blob Data Contributor` cho chính tài khoản trên Storage Account. 

### Storage Account

**Định nghĩa:** dịch vụ storage tổng được dùng trong bối cảnh Azure ML để lưu dataset, model artifacts và log.

**Ví dụ:** Storage Account chứa Blob Container. 

### Blob Container

**Định nghĩa:** vùng chứa file nằm bên trong Storage Account.

**Ví dụ:** upload một đoạn text dataset hoặc log của Telegram Chatbot Qwen vào Container. 

### Azure Container Registry

**Định nghĩa:** registry dùng để lưu Docker Image, được chuẩn bị cho Qwen và YOLO ở các tuần sau.

**Ví dụ:** tạo ACR SKU `Basic` rồi `az acr login`. 

### CLI First

**Định nghĩa:** tất cả provision/change/delete resource đều phải thực hiện qua Azure CLI; Portal chỉ dùng để verify.

**Ví dụ:** tạo RG bằng `az group create`, sau đó kiểm tra trên Azure Portal. 

### Cost Governance

**Định nghĩa:** quản trị chi phí bằng budget, alert và cleanup tài nguyên để tránh billing surprise trên PAYG.

**Ví dụ:** budget `5 USD`, alert tại `80%`, kết hợp `az group delete`. 

## Các phương án đã cân nhắc

| Phương án                      | Ưu điểm                                                                            | Nhược điểm / ràng buộc                                                                                      | Được chọn?                              |
| ------------------------------ | ---------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- | --------------------------------------- |
| WSL2 Ubuntu + Azure CLI        | Phù hợp Linux-based container/CI-CD/script; giảm nguy cơ path/environment mismatch | Phải thiết lập WSL2 trước                                                                                   | **Có**                                  |
| PowerShell/CMD thuần           | Có sẵn trên Windows                                                                | Không phù hợp định hướng môi trường MLOps được đặt ra trong roadmap; có nguy cơ khác biệt môi trường về sau | **KHÔNG dùng**                          |
| Azure Portal để provision      | Giao diện trực quan                                                                | Vi phạm nguyên tắc CLI First đã đặt ra                                                                      | **KHÔNG dùng làm phương thức chính**    |
| Access Key / Connection String | Cách tiếp cận credential trực tiếp                                                 | Bị xem là anti-pattern security trong thiết kế này                                                          | **KHÔNG ưu tiên**                       |
| RBAC + Managed Identity        | Phân quyền theo principal/role/scope                                               | Cần hiểu mô hình permission                                                                                 | **Có**                                  |
| Azure Free Trial               | Có thể giảm chi phí                                                                | Tài khoản cá nhân hiện không được Free                                                                      | **Không khả dụng trong tình huống này** |
| Azure for Students             | Có credit cho sinh viên; được đặt làm lựa chọn ưu tiên                             | Phụ thuộc điều kiện xác thực email học tập                                                                  | **Ưu tiên kiểm tra**                    |
| PAYG                           | Dùng được khi Free/Students không khả dụng                                         | Phải kiểm soát chi phí nghiêm ngặt                                                                          | **Phương án dự phòng / đang dùng**      |

Tiêu chí quyết định chủ yếu là **khả năng thực hành đúng định hướng MLOps, tính nhất quán môi trường, security model và kiểm soát chi phí**.  
