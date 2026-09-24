---
source_url: "https://gemini.google.com/app/dc4cc14fd2518a92"
conversation_date: "2026-01-09"
context_week: "N/A"
conversation_types: [LY_THUYET, TRANH_LUAN_QUYET_DINH, FIX_HA_TANG]
ai300_domains: ["Design and implement MLOps infrastructure", "GenAIOps infrastructure"]
technologies: [Docker, Azure CLI, Azure Container Registry, RBAC, Terraform, Bicep, BuildKit, Git, PowerShell, Bash]
key_decision: "Không build Docker image trên máy local để push lên ACR; thay vào đó dùng ACR Tasks và tag image bằng Git commit hash để đảm bảo traceability và môi trường nhất quán."
status: resolved
---

## Bối cảnh & Vấn đề

Cuộc hội thoại xoay quanh quy trình xây dựng và đẩy Docker image lên Azure Container Registry (ACR), bao gồm các kỹ thuật cụ thể: cách dùng lệnh `docker build` với các tham số nâng cao, cách gán quyền RBAC (AcrPush) cho ACR, và cách đẩy image lên ACR. Đồng thời, có các phê phán về anti-pattern trong vận hành và khuyến nghị các giải pháp thay thế tối ưu hơn cho môi trường production.

## Quyết định cuối cùng & Lý do

**Quyết định then chốt:**  
- Không build Docker image trên máy tính cá nhân rồi đẩy lên ACR.  
- Thay vào đó, sử dụng **ACR Tasks** (`az acr build`) để build trên cloud, đảm bảo môi trường build nhất quán, tận dụng băng thông nội bộ Azure và không phụ thuộc Docker Desktop local.  
- **Tag image** bắt buộc phải sử dụng **Git commit hash** (hoặc Semantic Versioning có liên kết với mã nguồn) thay vì tag thủ công, để dễ dàng truy xuất nguồn gốc và rollback.  
- Đối với RBAC, **không gán quyền thủ công bằng CLI ở production**; phải khai báo qua Infrastructure as Code (Terraform/Bicep). Sử dụng **Workload Identity Federation** thay vì Service Principal secret.

**Các phương án bị loại bỏ (ĐÃ LOẠI BỎ):**  
- **Dùng tag `latest`** → LOẠI BỎ vì phá vỡ tính bất biến (immutability) của hạ tầng, không thể trace được version chính xác.  
- **Gán `AcrPush` cho ứng dụng chỉ cần kéo image** → LOẠI BỎ vì vi phạm nguyên tắc đặc quyền tối thiểu; chỉ nên gán `AcrPull`.  
- **Tạo Service Principal với Client Secret tĩnh** → LOẠI BỎ vì secret có vòng đời cố định, dễ rò rỉ và khó luân chuyển; thay bằng OIDC/Workload Identity.  
- **Build image trên local Windows rồi push lên ACR** → LOẠI BỎ vì môi trường local không đảm bảo nhất quán, upload chậm, và không traceable.

## Lệnh và Cấu hình cụ thể đã dùng

### Lệnh Docker Build cơ bản
```bash
docker build -t <tên_image>:<tag> <đường_dẫn_context>
# Ví dụ:
docker build -t core-api-service:v1.2.0 .
```

### Các tham số nâng cao cho `docker build`

- **Chỉ định Dockerfile khác tên/thư mục (`-f`)**  
  ```bash
  docker build -f docker/production.Dockerfile -t core-api:prod .
  ```

- **Truyền build-arg**  
  ```bash
  docker build --build-arg NODE_ENV=production -t web-app:prod .
  ```

- **Vô hiệu hóa cache (`--no-cache`)**  
  ```bash
  docker build --no-cache -t secure-image:latest .
  ```

- **Build một stage cụ thể trong multi-stage (`--target`)**  
  ```bash
  docker build --target builder -t app-builder:local .
  ```

### Lấy Resource ID của ACR (Bash và PowerShell)

**Bash / WSL / Cloud Shell:**
```bash
ACR_NAME="<tên_acr>"
ASSIGNEE_ID="<object_id_hoặc_email>"
ACR_ID=$(az acr show --name $ACR_NAME --query id --output tsv)
```

**PowerShell:**
```powershell
$AcrName = "<tên_acr>"
$AssigneeId = "<object_id_hoặc_email>"
$AcrId = az acr show --name $AcrName --query id --output tsv
```

### Gán quyền RBAC AcrPush

**Bash:**
```bash
az role assignment create \
  --assignee $ASSIGNEE_ID \
  --role AcrPush \
  --scope $ACR_ID
```

**PowerShell:**
```powershell
az role assignment create \
  --assignee $AssigneeId \
  --role AcrPush \
  --scope $AcrId
```

**Tối ưu dùng Object ID (Bash):**
```bash
az role assignment create \
  --assignee-object-id <Object_ID> \
  --assignee-principal-type <User|ServicePrincipal|Group> \
  --role AcrPush \
  --scope $ACR_ID
```

### Đẩy image lên ACR (PowerShell)

```powershell
# Khai báo biến
$AcreName = "<tên_acr>"
$LocalImage = "<tên_image_local>:<tag>"
$TargetImageName = "<tên_repo_trên_acr>"

# Lấy Login Server
$LoginServer = az acr show --name $AcreName --query loginServer --output tsv

# Xác thực
az acr login --name $AcreName

# Tag và Push
$TargetTag = "$LoginServer/$TargetImageName:v1.2.0"
docker tag $LocalImage $TargetTag
docker push $TargetTag
```

### Giải pháp thay thế: ACR Tasks (build trên cloud)

```bash
az acr build --registry $AcreName --image $TargetImageName:v1.2.0 .
```

### Tag với Git commit hash (PowerShell)

```powershell
$GitHash = git rev-parse --short HEAD
$TargetTag = "$LoginServer/$TargetImageName:$GitHash"
```

### Build với FQDN ngay từ đầu

```bash
docker build -t acrthngoc17cv.azurecr.io/tracking-api:v1 .
```

## Lỗi gặp phải và Cách khắc phục

| Lỗi / Anti-pattern | Cách khắc phục / Quy tắc |
| --- | --- |
| Build context chứa quá nhiều file không cần thiết (như `.git/`, `node_modules/`) gây chậm và rủi ro bảo mật | **Bắt buộc** có file `.dockerignore` loại bỏ các thư mục không cần thiết ra khỏi context. |
| Dùng tag `latest` trong production, không traceable | Dùng Semantic Versioning (`v1.2.0`) hoặc Git commit hash. |
| Gán RBAC bằng CLI thủ công ở production, không thể kiểm soát drift | Khai báo RBAC bằng Terraform hoặc Bicep (IaC). |
| Gán `AcrPush` cho ứng dụng chỉ cần pull | Chỉ gán `AcrPull` cho các workload (AKS, App Service). |
| Sử dụng Service Principal với secret tĩnh để xác thực | Chuyển sang Workload Identity Federation (OIDC) không cần secret. |
| Build image trên máy local Windows rồi push lên ACR (môi trường không nhất quán, upload chậm) | Dùng `az acr build` (ACR Tasks) để build ngay trên cloud, không cần Docker local. |
| Tag image thủ công không liên kết với mã nguồn | Tự động lấy Git commit hash (`git rev-parse --short HEAD`) và dùng làm tag. |

## Khái niệm & Định nghĩa

| Thuật ngữ | Định nghĩa | Ví dụ minh hoạ |
| --- | --- | --- |
| **Build context** | Thư mục được Docker CLI đóng gói và gửi tới Docker Daemon khi build. | `.` là thư mục hiện tại. Nếu chứa nhiều file không cần thiết, build sẽ chậm. |
| **Tag image** | Tên định danh cho image, thường có dạng `[registry/]repo:tag`. | `core-api-service:v1.2.0` hoặc `myregistry.azurecr.io/app:abc123` (commit hash). |
| **Resource ID (ARM ID)** | Định danh tuyệt đối của tài nguyên Azure trong hệ thống ARM. | `/subscriptions/.../resourceGroups/.../providers/Microsoft.ContainerRegistry/registries/myregistry` |
| **ACR Tasks** | Dịch vụ build image trên Azure, không cần Docker Desktop local. | `az acr build --registry myregistry --image app:v1 .` |
| **Workload Identity Federation** | Cơ chế xác thực không dùng secret, cho phép workload (VD: GitHub Actions) nhận token từ Azure AD thông qua OIDC. | Thay vì tạo Client Secret, cấu hình federated credential để GitHub Actions có thể `az login` mà không cần secret. |
| **BuildKit** | Hệ thống build mới của Docker (bật mặc định từ Docker 23.0), cho phép build song song, bỏ qua stage không dùng. | Dùng `docker buildx build` thay vì `docker build` để tận dụng BuildKit và hỗ trợ đa kiến trúc. |

## Các phương án đã cân nhắc

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
| --- | --- | --- | --- |
| Build local → push lên ACR | Đơn giản, quen thuộc | Không nhất quán môi trường, upload chậm, không traceable | ❌ **Không** (bị loại bỏ) |
| ACR Tasks (build trên cloud) | Môi trường build nhất quán, tốc độ nhanh, không cần Docker local, dễ tích hợp CI/CD | Tốn chi phí compute nhỏ trong lúc build | ✅ **Có** |
| Tag image bằng tay (vd: v1.2.0) | Dễ nhớ, có thể quản lý version | Dễ sai sót, không gắn với mã nguồn cụ thể | ❌ **Không** (chỉ dùng khi có quy trình tự động) |
| Tag image bằng Git commit hash | Gắn chính xác với mã nguồn, dễ rollback, traceable | Khó nhớ nhưng có thể lấy từ Git | ✅ **Có** |
| Gán RBAC bằng CLI (imperative) | Nhanh, tiện cho POC | Phá vỡ IaC, khó quản lý drift, khó thu hồi | ❌ **Không** (chỉ dùng cho thử nghiệm) |
| Gán RBAC bằng Terraform/Bicep | IaC, kiểm soát phiên bản, dễ rollback | Cần thêm công sức thiết lập | ✅ **Có** |
| Dùng Service Principal secret để xác thực | Được hỗ trợ rộng rãi | Secret có vòng đời, rò rỉ nguy hiểm, khó rotate | ❌ **Không** |
| Dùng Workload Identity Federation | Không cần secret, an toàn, tự động luân chuyển | Cần cấu hình federated credential, hỗ trợ giới hạn | ✅ **Có** |

