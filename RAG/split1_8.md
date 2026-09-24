---
source_url: https://gemini.google.com/app/7195bd2588281e6e
conversation_date: 2026-07-17
context_week: Tuần 1
conversation_types: [LAP_KE_HOACH, TRANH_LUAN_QUYET_DINH, FIX_HA_TANG, FIX_CODE, LY_THUYET, KIEM_TRA_KIEN_THUC]
ai300_domains: [Design and implement MLOps infrastructure]
technologies: [Azure CLI, WSL2, Azure Portal, Azure Free Account, Resource Group, Storage Account, Azure Container Registry, RBAC, Managed Identity, Bash, GitHub Actions]
key_decision: "Vận hành trên Azure phải tuân theo nguyên tắc 'CLI First' và 'Least Privilege': tương tác với data plane bắt buộc dùng role thuộc data plane (ví dụ `Storage Blob Data Contributor`), không dùng account key; mã nguồn IaC phải đảm bảo tính luỹ đẳng (idempotent)."
status: resolved
---

## Bối cảnh & Vấn đề
Hội thoại diễn ra trong khuôn khổ lộ trình tự học 12 tuần cho chứng chỉ AI-300 (Microsoft Azure AI and Machine Learning). Người dùng bắt đầu Tuần 1 với mục tiêu làm quen với Azure CLI và các dịch vụ hạ tầng cốt lõi (Resource Group, Storage Account, Container Registry). Thách thức đặt ra là chuyển đổi tư duy từ việc sử dụng GUI (Azure Portal) sang CLI, đồng thời nắm vững các nguyên tắc bảo mật RBAC và Infrastructure as Code (IaC) để tránh các lỗi thường gặp về phân quyền và chi phí.

## Quyết định cuối cùng & Lý do
- **Decision:** Áp dụng nguyên tắc "CLI First" (mọi thao tác đều qua CLI, Portal chỉ dùng để kiểm tra lại).
- **Decision:** Sử dụng **WSL2 (Ubuntu)** làm môi trường làm việc thay vì PowerShell/CMD thuần để tránh lỗi xung đột đường dẫn (path) và tương thích với môi trường Linux của pipeline CI/CD.
- **Decision:** **KHÔNG** sử dụng Account Key để xác thực truy cập dữ liệu từ ứng dụng. Thay vào đó, **bắt buộc** dùng **RBAC** và **Managed Identity** để đảm bảo an toàn bảo mật (passwordless).
- **Decision:** Với pipeline CI/CD (GitHub Actions), **KHÔNG** dùng role `Contributor` hoặc `ACR Contributor` mà chỉ dùng role **`AcrPush`** (cho phép push/pull image) ở Scope đích danh là ACR.
- **Decision:** Với Data Scientist chỉ cần tải về phân tích dữ liệu, **KHÔNG** dùng role `Storage Blob Data Contributor` (cho phép ghi/xóa) mà dùng role **`Storage Blob Data Reader`** (chỉ đọc).
- **Decision:** Nếu là một máy ảo/ứng dụng cần truy cập dịch vụ Azure AI Search, **KHÔNG** hard-code key, **KHÔNG** dùng biến môi trường lưu key tĩnh. **BẮT BUỘC** dùng **System-assigned Managed Identity** và cấp role **`Search Index Data Reader`** cho máy ảo/ứng dụng đó.

## Lệnh và Cấu hình cụ thể đã dùng

### Các lệnh Azure CLI cơ bản
```bash
# Đăng nhập
az login

# Kiểm tra account
az account show

# Tạo Resource Group
az group create --name mlogs-week1-rg --location southeastasia

# Liệt kê Resource Group
az group list --output table

# Tạo Storage Account
az storage account create --name <tên_unique> --resource-group mlogs-week1-rg --sku Standard_LRS

# Tạo ACR
az acr create --resource-group mlogs-week1-rg --name <tên_acr_unique> --sku Basic
az acr login --name <tên_acr_unique>

# Xóa Resource Group (và toàn bộ tài nguyên bên trong)
az group delete --name mlogs-week1-rg --no-wait --yes
```

### Script thực hành RBAC
```bash
# Lấy Object ID của tài khoản hiện tại
USER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)
echo "My Object ID is: $USER_OBJECT_ID"

# Lấy Resource ID của Storage Account
RG_NAME="mlogs-week1-rg"
STORAGE_NAME="<ten_storage_account_cua_ban>"
STORAGE_SCOPE=$(az storage account show --name $STORAGE_NAME --resource-group $RG_NAME --query id -o tsv)
echo "Scope is: $STORAGE_SCOPE"

# Gán quyền Storage Blob Data Contributor cho tài khoản của bạn
az role assignment create --assignee $USER_OBJECT_ID --role "Storage Blob Data Contributor" --scope $STORAGE_SCOPE

# Lệnh upload file sử dụng xác thực Entra ID (--auth-mode login)
echo "Test connection for chatbot system" > system_log.txt
az storage container create --name system-data --account-name $STORAGE_NAME --auth-mode login
az storage blob upload --account-name $STORAGE_NAME --container-name system-data --name system_log.txt --file system_log.txt --auth-mode login
```

### Script audit quyền hạn RBAC
```bash
USER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)
az role assignment list --assignee $USER_OBJECT_ID --all --query "[].{Role:roleDefinitionName, Scope:scope}" --output table
```

### Script `deploy.sh` ban đầu (bị lỗi)
```bash
#!/bin/bash

# FAIL-FAST CONFIGURATION
set -euo pipefail

# PARAMETERIZATION
RG_LOCATION="eastasia"
SA_LOCATION="eastasia"
RESOURCE_GROUP_NAME="my-app-rg-2"

# Storage Account Configuration
STORAGE_ACCOUNT_NAME="myapps$RANDOM" # <--- LỖI: Dùng RANDOM làm hỏng tính đẳng trị
STORAGE_ACCOUNT_SKU="Standard_LRS"

# ACR Configuration
ACR_NAME="myappac$RANDOM" # <--- LỖI: Dùng RANDOM làm hỏng tính đẳng trị
ACR_SKU="Basic"

# MAIN EXECUTION FLOW
echo "Starting Azure infrastructure deployment..."
echo "---"

echo "[1/3] Creating Resource Group: $RESOURCE_GROUP_NAME in $RG_LOCATION..."
az group create --name "$RESOURCE_GROUP_NAME" --location "$RG_LOCATION" --output none
echo "> Resource Group created successfully!"

echo "[2/3] Creating Storage Account: $STORAGE_ACCOUNT_NAME in $SA_LOCATION (SKU: $STORAGE_ACCOUNT_SKU)..."
az storage account create --name "$STORAGE_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP_NAME" --location "$SA_LOCATION" --sku "$STORAGE_ACCOUNT_SKU" --output none
echo "> Storage Account created successfully!"

echo "[3/3] Creating Azure Container Registry: $ACR_NAME in $RG_LOCATION (SKU: $ACR_SKU)..."
az acr create --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP_NAME" --location "$RG_LOCATION" --sku "$ACR_SKU" --output none
echo "> ACR created successfully!"
```

### Script `deploy.sh` đã refactor (đúng chuẩn)
```bash
#!/bin/bash

# Cấu hình Fail-fast
set -euo pipefail

# =====================================================================
# PARAMETERIZATION
# =====================================================================
RG_LOCATION="southeastasia"
SA_LOCATION="southeastasia"
RESOURCE_GROUP_NAME="mlops-week1-rg"

# Sử dụng chuỗi tắt định (Deterministic suffix) để đảm bảo tính luỹ đẳng
UNIQUE_SUFFIX="thngoc17" # THAY THẾ BẰNG ĐỊNH DANH CỦA BẠN

STORAGE_ACCOUNT_NAME="mlopssast${UNIQUE_SUFFIX}"
STORAGE_ACCOUNT_SKU="Standard_LRS"
ACR_NAME="mlopsacr${UNIQUE_SUFFIX}"
ACR_SKU="Basic"

# ==============================================================================
# PRE-FLIGHT CHECKS
# ==============================================================================
echo "Checking Azure authentication..."
if ! az account show >/dev/null 2>&1; then
 echo "[ERROR] You are not logged in. Run 'az login' first."
 exit 1
fi
echo "-> Authentication verified."

# ==============================================================================
# MAIN EXECUTION FLOW
# ==============================================================================
echo "Starting Azure infrastructure deployment..."
echo "--------------------------------------------------"

echo "[1/3] Creating/Updating Resource Group: $RESOURCE_GROUP_NAME..."
az group create --name "$RESOURCE_GROUP_NAME" --location "$RG_LOCATION" --query "properties.provisioningState" -o tsv

echo "[2/3] Creating/Updating Storage Account: $STORAGE_ACCOUNT_NAME..."
STORAGE_ID=$(az storage account create --name "$STORAGE_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP_NAME" --location "$SA_LOCATION" --sku "$STORAGE_ACCOUNT_SKU" --query id -o tsv)
echo "-> Storage Account ready. ID: $STORAGE_ID"

echo "[3/3] Creating/Updating Azure Container Registry: $ACR_NAME..."
ACR_ID=$(az acr create --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP_NAME" --location "$RG_LOCATION" --sku "$ACR_SKU" --query id -o tsv)
echo "-> ACR ready. ID: $ACR_ID"

echo "--------------------------------------------------"
echo "Deployment complete! Idempotent execution verified."
```

## Lỗi gặp phải và Cách khắc phục

### Lỗi 1: Hard-code Account Key / Admin Key
- **Mô tả:** Copy key từ Azure Portal và dán trực tiếp (hard-code) vào file cấu hình mã nguồn.
- **Tại sao sai:** Vi phạm nguyên tắc bảo mật chuẩn mực. Key có thể bị lộ nếu mã nguồn bị rò rỉ. Khó khăn trong việc xoay vòng (rotation) key khi hết hạn.
- **Khắc phục:** Sử dụng **Managed Identity** (cho máy ảo/App Service) hoặc **Service Principal** (cho CI/CD). Trong code, dùng `DefaultAzureCredential` để lấy token tự động.

### Lỗi 2: Dùng role Contributor cho GitHub Actions để push image lên ACR
- **Mô tả:** Cấp quyền `Contributor` cho Service Principal ở Scope là Subscription hoặc Resource Group.
- **Tại sao sai:** Vi phạm Least Privilege. Kẻ tấn công chiếm được GitHub Repo có thể xóa sổ toàn bộ hạ tầng ACR hoặc các tài nguyên khác trong RG.
- **Khắc phục:** Chỉ cấp role **`AcrPush`** (hoặc `AcrPull` nếu chỉ cần kéo) cho Service Principal tại Scope đúng là **tài nguyên ACR**.
    ```bash
    az role assignment create --assignee <service-principal-id> --role "AcrPush" --scope /subscriptions/.../resourceGroups/.../providers/Microsoft.ContainerRegistry/registries/<tên_acr>
    ```

### Lỗi 3: Gán role Storage Blob Data Contributor cho Data Scientist chỉ cần tải dữ liệu
- **Mô tả:** Người dùng chỉ cần tải dữ liệu về máy tính cá nhân để phân tích.
- **Tại sao sai:** `Storage Blob Data Contributor` bao gồm quyền Write và Delete. Data Scientist có thể vô tình hoặc cố ý xóa hoặc ghi đè dữ liệu gốc.
- **Khắc phục:** Cấp role **`Storage Blob Data Reader`** (chỉ cho phép List và Read).

### Lỗi 4: Script IaC thiếu tính luỹ đẳng (Idempotency) do dùng $RANDOM
- **Mô tả:** Sử dụng `$RANDOM` trong tên Storage Account và ACR (script ban đầu).
- **Tại sao sai:** Mỗi lần chạy script đều tạo ra tài nguyên mới, không thể chạy lại script (re-run) để kiểm tra hay cập nhật trạng thái (state) mà không sinh ra tài nguyên rác.
- **Khắc phục:** Sử dụng tên tài nguyên có tính **tất định (Deterministic)** bằng một hậu tố cố định (ví dụ tên người dùng) hoặc hash từ Resource Group Name.

### Lỗi 5: Triệt tiêu đầu ra (--output none) của lệnh CLI
- **Mô tả:** Sử dụng `--output none` cho mọi lệnh az để terminal sạch (script ban đầu).
- **Tại sao sai:** ID tài nguyên (Resource ID) cần thiết để sử dụng cho các bước tiếp theo (ví dụ gán RBAC).
- **Khắc phục:** Không dùng `--output none` với các lệnh khởi tạo. Dùng `--query id -o tsv` để lưu Resource ID vào biến, tái sử dụng cho các thao tác sau.

## Lộ trình chi tiết (Tuần 1)

| Ngày | Nhiệm vụ | Chỉ tiêu hoàn thành |
| :--- | :--- | :--- |
| **1** | Tạo Azure Free Account (có thẻ Visa/Mastercard xác minh). Cài đặt **WSL2 (Ubuntu)**, cài Azure CLI (`apt-get install azure-cli`). Đăng nhập `az login`. | Chạy `az account show`, hiểu được Tenant ID, Subscription ID, User. |
| **2** | Tạo Resource Group (RG) với tag. | `az group list --output table` và đối chiếu trên Portal. |
| **3** | Tạo Storage Account. | Hiểu được sự khác biệt giữa Storage Account (dịch vụ) và Blob Container (thư mục). |
| **4** | Tạo Azure Container Registry (ACR), đăng nhập. | Terminal báo `Login Succeeded`. |
| **5** | **Nghiên cứu RBAC (3 thành phần, Control Plane vs Data Plane).** Thực hành gán role `Storage Blob Data Contributor` cho bản thân trên Storage Account. | **Hiểu rõ:** quyền `Owner` trên RG không tự cho phép đọc/ghi Blob. Upload file thành công với `--auth-mode login`. |
| **6** | Viết bash script `deploy.sh` (IaC) tự động hóa các tác vụ Ngày 2-4. | Script phải **Idempotent** (có thể chạy lại nhiều lần không tạo tài nguyên mới), có **Pre-flight check** và **Fail-fast** (`set -e`). |
| **7** | **Dọn dẹp**: Xóa Resource Group (`az group delete`). Đọc lại Study Guide AI-300 (Domain MLOps Infrastructure) đối chiếu lý thuyết. | Bill Azure = $0.00. |

## Khái niệm & Định nghĩa

### RBAC (Role-Based Access Control)
- **Định nghĩa:** Hệ thống kiểm soát truy cập dựa trên vai trò. Xác định **Ai** (Principal) được phép **làm gì** (Role) ở **đâu** (Scope).
- **Ví dụ:** Gán role `Reader` cho User A tại Scope Resource Group X => User A chỉ có quyền xem mọi tài nguyên trong RG X.

### Three Components of RBAC
- **Security Principal (Chủ thể):** Đối tượng yêu cầu quyền (User, Group, Service Principal, Managed Identity).
- **Role Definition (Định nghĩa vai trò):** Tập hợp các quyền (Actions/NotActions). Vd: `Reader`, `Contributor`, `Owner`, `Storage Blob Data Reader`.
- **Scope (Phạm vi):** Ranh giới áp dụng quyền (Management Group, Subscription, Resource Group, Resource).

### Control Plane vs Data Plane
- **Control Plane (Mặt phẳng điều khiển):** Quản lý **"vỏ"** của tài nguyên. Tạo, xóa, cấu hình tài nguyên. Role: `Contributor`, `Owner`, `Reader`.
- **Data Plane (Mặt phẳng dữ liệu):** Tương tác với **dữ liệu bên trong** tài nguyên. Đọc/ghi file trong Blob, truy vấn database. Role: `Storage Blob Data Contributor`, `Cognitive Services OpenAI User`.
- **Ví dụ:** Người có quyền `Owner` trên Storage Account có thể xóa cái Storage Account đó, nhưng **KHÔNG** có quyền upload file vào bên trong Blob Container.

### Nguyên tắc Đặc quyền tối thiểu (Least Privilege)
- **Định nghĩa:** Chỉ cấp cho một thực thể (Principal) những quyền hạn tối thiểu cần thiết để thực hiện công việc của nó.
- **Ví dụ:** Nếu chỉ cần upload file lên Blob, chỉ cấp `Storage Blob Data Contributor` (Data Plane) cho Storage Account đó, không cấp `Contributor` (Control Plane).

### Tính luỹ đẳng (Idempotency) trong IaC
- **Định nghĩa:** Một thao tác có thể được thực thi nhiều lần nhưng kết quả cuối cùng (state) của hệ thống là không đổi.
- **Ví dụ:** Script `deploy.sh` chạy lần 1 tạo RG `mlops-week1-rg`. Chạy lần 2, script không tạo RG mới mà kiểm tra RG đã tồn tại và bỏ qua.

### Managed Identity
- **Định nghĩa:** Một danh tính tự động được Azure quản lý, gắn liền với một tài nguyên Azure (VD: Máy ảo, App Service). Giúp ứng dụng xác thực với các dịch vụ Azure khác mà không cần lưu trữ thông tin đăng nhập (key/secret) trong code.
- **Ví dụ:** Bật Managed Identity cho VM Ubuntu, gán role `Search Index Data Reader` cho VM đó. Code Python dùng `DefaultAzureCredential` sẽ tự động lấy token từ VM để gọi Azure AI Search.

## Nhật ký câu hỏi – trả lời – đánh giá

### Case Study 1: Tự động hoá CI/CD
- **Câu hỏi:** Để GitHub Actions push Docker image lên ACR, bạn gán quyền `Contributor` cho Service Principal ở cấp độ Subscription. Điều này đúng hay sai? Tại sao? Giải pháp đúng là gì?
- **Câu trả lời của người dùng:** Sai, vi phạm Least Privilege. Cần cấp role `ACR Contributor`.
- **Đánh giá:** **Sai một phần.**
    - **Điểm đúng:** Phát hiện sai `Contributor` ở Subscription. Hiểu về Least Privilege.
    - **Điểm sai:** `Contributor` là role Control Plane. Cần role **`AcrPush`** (chỉ push/pull) hoặc `AcrPull`.
- **Đáp án chuẩn:** Gán role **`AcrPush`** cho Service Principal tại Scope là **tài nguyên ACR**.

### Case Study 2: Cấp quyền cho Data Scientist
- **Câu hỏi:** Data Scientist mới cần tải dữ liệu từ Storage Account về máy. Bạn tuyệt đối không muốn họ xóa hay sửa dữ liệu. Bạn gán quyền `Reader` cho họ. Người đó có tải được file không? Giải pháp đúng là gì?
- **Câu trả lời của người dùng:** Không tải được vì `Reader` chỉ xem. Cần cấp role `Storage Blob Data Contributor`.
- **Đánh giá:** **Sai.**
    - **Điểm đúng:** Phát hiện `Reader` (Control Plane) không đọc được data.
    - **Điểm sai:** `Storage Blob Data Contributor` cho phép **Ghi và Xóa**, vi phạm yêu cầu "không xóa". Người dùng chỉ cần **Đọc**.
- **Đáp án chuẩn:** Cấp role **`Storage Blob Data Reader`** (chỉ List và Read).

### Case Study 3: Tích hợp RAG cho Telegram Chatbot
- **Câu hỏi:** Bạn hard-code Admin Key của Azure AI Search vào file `config.py` và push lên private GitHub. Có 2 lỗ hổng chí mạng là gì? Giải pháp chuẩn mực?
- **Câu trả lời của người dùng:** Không được hard-code key mà phải mã hóa key trong biến môi trường (Environment Variables) rồi mới đăng lên GitHub.
- **Đánh giá:** **Sai.**
    - **Điểm đúng:** Phát hiện hard-code key là tối kỳ.
    - **Điểm sai:** Biến môi trường vẫn là giải pháp dùng key tĩnh, không phải Cloud-native. Rủi ro key bị leak vẫn cao. Code trên GitHub sẽ không an toàn nếu ai đó dump ENV.
- **Đáp án chuẩn:**
    1.  **Bảo mật mã nguồn:** Tuyệt đối không lưu bất kỳ key nào (dù là hard-code hay ENV).
    2.  **Kiến trúc xác thực:** Bật **System-assigned Managed Identity** cho máy ảo. Gán role **`Search Index Data Reader`** cho Managed Identity đó tại Scope là dịch vụ Azure AI Search.
    3.  **Code:** Dùng `DefaultAzureCredential` trong Python SDK để lấy token xác thực tự động.