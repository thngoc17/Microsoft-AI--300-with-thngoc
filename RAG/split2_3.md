---
source_url: https://gemini.google.com/app/d2919762efb5e14d
conversation_date: N/A
context_week: "Tuần 1 → Tuần 2"
conversation_types: [FIX_CODE, FIX_HA_TANG, TRANH_LUAN_QUYET_DINH, LY_THUYET, LAP_KE_HOACH]
ai300_domains: ["Design and implement MLOps infrastructure", "GenAIOps infrastructure"]
technologies: [Azure CLI, Azure Resource Group, Azure Storage Account, Azure Container Registry, Azure ML Workspace, Compute Instance, SSH, YAML, Heredoc, PowerShell, Bash, Azure ML Data Asset, Python, pathlib, ChromaDB, VS Code, Azure Machine Learning extension]
key_decision: "Sử dụng Bash script trên Ubuntu để tạo toàn bộ hạ tầng MLOps (RG, Storage, ACR, Workspace) trước, sau đó dùng YAML + Azure CLI để tạo Compute Instance và Data Asset; khi Compute Instance không có Public IP, kết nối qua VS Code Azure ML Remote extension; lưu dữ liệu vector (ChromaDB) vào ~/cloudfiles/ để bền vững."
status: resolved
---

## Bối cảnh & Vấn đề

- Người dùng cần tự động hóa việc tạo Azure Container Registry (ACR) trước khi khởi tạo Azure ML Workspace để tránh lỗi RBAC ở giai đoạn CI/CD.
- Script Bash ban đầu (dùng `$(...)` và `\`) không tương thích với môi trường Windows PowerShell/CMD, gây lỗi cú pháp.
- Script chỉ tạo tài nguyên rời rạc, không liên kết với Workspace, dẫn đến Workspace tự tạo Storage/ACR mới.
- Người dùng chuyển sang Ubuntu CLI, nhưng gặp lỗi cú pháp do dùng backtick (`) để ngắt dòng thay vì backslash (`\`).
- YAML cấu hình Compute Instance bị lỗi parsing do thụt lề sai và đọc nhầm Private Key thay vì Public Key.
- Compute Instance không hiển thị `ssh_public_uri` do chính sách mạng doanh nghiệp (không cấp Public IP).
- Ở Ngày 3, cần đảm bảo dữ liệu và vector DB được lưu trữ bền vững, không bị mất khi Compute Instance tắt.

---

## Quyết định cuối cùng & Lý do

### Lựa chọn script cho Ubuntu (Bash) thay vì Windows PowerShell
- **Lý do:** Người dùng đang làm việc trên Ubuntu CLI (WSL hoặc Linux native). Bash là shell mặc định, tương thích với cú pháp `$(...)` và backslash.
- **Phương án bị loại:** Dùng PowerShell script ban đầu (dành cho Windows). KHÔNG dùng vì môi trường thực tế đã chuyển sang Ubuntu.

### Tạo Compute Instance bằng YAML + Azure CLI thay vì ClickOps (UI)
- **Lý do:** ClickOps không thể version-controlled, khó tích hợp SSH key đúng cách, không tái sử dụng được. YAML + CLI là IaC, có thể lưu vào Git.
- **Phương án bị loại:** Tạo bằng giao diện Azure Portal. KHÔNG dùng vì mất khả năng tự động hóa và kiểm soát SSH.

### Kết nối VS Code qua Azure Machine Learning Remote extension thay vì SSH trực tiếp
- **Lý do:** Do chính sách tổ chức không cấp Public IP cho Compute Instance, SSH trực tiếp không khả thi. Extension sử dụng Azure Relay (WebSocket bảo mật) để xuyên qua tường lửa.
- **Phương án bị loại:** Cấu hình `~/.ssh/config` với địa chỉ IP công cộng. KHÔNG dùng vì không có IP (thiếu `ssh_public_uri`).

### Lưu trữ dữ liệu bền vững
- **Data Asset:** Đăng ký thư mục dữ liệu dưới dạng `uri_folder` trên Azure ML, thực chất được đẩy lên Storage Account blob.
- **ChromaDB persistence:** Lưu vào `~/cloudfiles/code/Users/azureuser/chroma_db_store` (được mount với Azure File Share) để tồn tại qua các lần máy tắt.
- **Phương án bị loại:** Lưu file vào thư mục tạm thời của Compute Instance (ví dụ `/tmp`). KHÔNG dùng vì mất khi deallocate.

---

## Lệnh và Cấu hình cụ thể đã dùng

### Script Bash hoàn chỉnh (setup_env.sh) cho Ubuntu

```bash
#!/bin/bash
set -e

# 1. Khai báo biến môi trường
# BẮT BUỘC ĐỔI TÊN: Thay 'ltn' bằng chữ viết tắt hoặc chuỗi ngẫu nhiên.
RESOURCE_GROUP_NAME="rg-mlops-workspace"
LOCATION="eastasia"
STORAGE_ACCOUNT_NAME="stmlopscoredevltn"
ACR_NAME="acrmlopscoredevltn"
WORKSPACE_NAME="mlw-core-dev"

echo "[1/4] Khởi tạo Resource Group: $RESOURCE_GROUP_NAME..."
az group create \
  --name "$RESOURCE_GROUP_NAME" \
  --location "$LOCATION" \
  --query "properties.provisioningState" -o tsv

echo "[2/4] Khởi tạo Storage Account: $STORAGE_ACCOUNT_NAME..."
STORAGE_ID=$(az storage account create \
  --name "$STORAGE_ACCOUNT_NAME" \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  --query id -o tsv)
echo "-> Storage Account đã sẵn sàng. ID: $STORAGE_ID"

echo "[3/4] Khởi tạo Azure Container Registry: $ACR_NAME..."
ACR_ID=$(az acr create \
  --name "$ACR_NAME" \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --location "$LOCATION" \
  --sku Basic \
  --query id -o tsv)
echo "-> ACR đã sẵn sàng. ID: $ACR_ID"

echo "[4/4] Khởi tạo Azure ML Workspace và liên kết cấu hình..."
az ml workspace create \
  --name "$WORKSPACE_NAME" \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --location "$LOCATION" \
  --storage-account "$STORAGE_ID" \
  --container-registry "$ACR_ID"

echo "-----------------------------------------------"
echo "Hoàn tất triển khai hạ tầng!"
```

### Lệnh tạo Workspace (khi không dùng script)

```bash
az ml workspace create \
  --name "ml-test" \
  --resource-group "mlops-week1-rg" \
  --location "eastasia"
```

**Lưu ý:** Trong Bash, phải dùng backslash (`\`) để ngắt dòng, không dùng backtick. Không có khoảng trắng sau backslash.

### Tạo SSH Key và file YAML Compute Instance tự động

```bash
# Tạo SSH key (bỏ qua nếu đã có)
ssh-keygen -t rsa -b 4096 -f ~/.ssh/azureml_key -N ""

# Đọc Public Key (PHẢI có .pub)
PUB_KEY=$(cat ~/.ssh/azureml_key.pub)

# Tạo YAML bằng Heredoc (tránh lỗi thụt lề)
cat <<EOF > compute-instance.yml
\$schema: https://azuremlschemas.azureedge.net/latest/computeInstance.schema.json
name: ci-dev-cpu-01
type: computeinstance
size: STANDARD_DS3_V2
ssh_settings:
  admin_username: azureuser
  ssh_key_value: "${PUB_KEY}"
idle_time_before_shutdown: PT30M
EOF

echo "Tệp compute-instance.yml đã được tạo thành công!"

# Tạo Compute Instance
az ml compute create \
  --file compute-instance.yml \
  --resource-group "mlops-week1-rg" \
  --workspace-name "ml-test"
```

**Lưu ý quan trọng:** 
- Phải dùng Public Key (`azureml_key.pub`), không dùng Private Key.
- Đường dẫn key trên Ubuntu phải là `~/.ssh/` hoặc `$HOME/.ssh/`, không dùng `USERPROFILE`.
- Trong YAML, giá trị `ssh_key_value` phải được bọc trong dấu ngoặc kép `"${PUB_KEY}"` vì public key chứa khoảng trắng.

### Kiểm tra trạng thái và thông tin Compute Instance

```bash
# Xem trạng thái
az ml compute show \
  --name "ci-dev-cpu-n01" \
  --resource-group "mlops-week1-rg" \
  --workspace-name "ml-test" \
  --query "state" -o tsv

# Xem thông tin SSH (sẽ thiếu ssh_public_uri nếu không có Public IP)
az ml compute show \
  --name "ci-dev-cpu-n01" \
  --resource-group "mlops-week1-rg" \
  --workspace-name "ml-test" \
  --query "ssh_settings"
```

### Data Asset YAML (data-asset.yml) và lệnh đăng ký

```yaml
$schema: https://azuremlschemas.azureedge.net/latest/data.schema.json
name: rag-knowledge-base
type: uri_folder
description: "Tập dữ liệu tài liệu dạng PDF/TXT dùng để nhúng (embedding) cho chatbot."
path: ./local_data_folder/
```

```bash
az ml data create \
  --file data-asset.yml \
  --resource-group "mlops-week1-rg" \
  --workspace-name "ml-test"
```

### Sửa mã nguồn Python để tương thích cross-platform

**Mã sai (Anti-pattern):**
```python
data_path = "C:\\Users\\LeThaicNgoj\\project\\data\\" + filename
```

**Mã chuẩn (dùng pathlib):**
```python
from pathlib import Path
BASE_DIR = Path(__file__).resolve().parent
data_path = BASE_DIR / "data" / filename
```

### Khởi tạo ChromaDB với persistence vào cloudfiles

```python
import chromadb
from chromadb.config import Settings
import os

PERSIST_DIR = os.path.expanduser("~/cloudfiles/code/Users/azureuser/chroma_db_store")
os.makedirs(PERSIST_DIR, exist_ok=True)

client = chromadb.PersistentClient(
    path=PERSIST_DIR,
    settings=Settings(anonymized_telemetry=False)
)
```

---

## Lỗi gặp phải và Cách khắc phục

| Lỗi | Nguyên nhân | Cách khắc phục |
|---|---|---|
| `--name: command not found` | Dùng backtick (`) trong Bash để ngắt dòng, khiến shell cố chạy chuỗi `--name` như lệnh. | Dùng backslash (`\`) để ngắt dòng, đảm bảo không có khoảng trắng sau `\`. |
| `expected '<document start>', but found '<scalar>'` | YAML bị sai thụt lề do copy/paste hoặc dùng Tab thay vì khoảng trắng. | Dùng Heredoc (`cat <<EOF > file.yml`) để tạo file tự động, tránh lỗi thụt lề. |
| `ssh_key_value` chứa nhiều dòng và gây lỗi YAML | Đọc nhầm Private Key (không có `.pub`) hoặc dùng sai đường dẫn Windows (`USERPROFILE`). | Luôn đọc Public Key (`~/.ssh/azureml_key.pub`). Bọc giá trị trong dấu ngoặc kép. Dùng đường dẫn Linux (`~` hoặc `$HOME`). |
| Thiếu `ssh_public_uri` trong output `az ml compute show` | Compute Instance không được cấp Public IP do Azure Policy ở cấp tổ chức. | Không dùng SSH trực tiếp; kết nối qua VS Code Azure Machine Learning Remote extension. |
| Dữ liệu bị mất khi Compute Instance tắt | Lưu file vào thư mục tạm thời (không bền vững). | Sử dụng Data Asset cho dữ liệu thô và lưu ChromaDB vào `~/cloudfiles/` (Azure File Share). |

---

## Lộ trình chi tiết (Ngày 3)

### Tác vụ 1: Đăng ký Data Asset
- Tạo file `data-asset.yml` với thông tin thư mục dữ liệu.
- Chạy `az ml data create` để đăng ký, đẩy dữ liệu lên Storage Account blob.
- **Chỉ tiêu:** Data asset xuất hiện trong Azure ML Studio.

### Tác vụ 2: Tái cấu trúc đường dẫn mã nguồn
- Thay thế toàn bộ phép nối chuỗi đường dẫn cứng bằng `pathlib.Path`.
- **Chỉ tiêu:** Mã nguồn chạy không lỗi trên cả Windows và Linux.

### Tác vụ 3: Cấu hình ChromaDB persistent
- Đặt `persist_directory` vào `~/cloudfiles/code/Users/azureuser/chroma_db_store`.
- Chạy thử script Python tạo collection và kiểm tra file `.sqlite3` được tạo trong thư mục đó.
- **Chỉ tiêu:** Sau khi máy tắt và bật lại, dữ liệu vector vẫn tồn tại và có thể truy vấn.

---

## Khái niệm & Định nghĩa

### Bash vs PowerShell – line continuation
- **Bash:** Dùng backslash `\` để chỉ dòng tiếp theo. Không được có khoảng trắng sau `\`.
- **PowerShell:** Dùng backtick (`` ` ``) để ngắt dòng.
- **Ví dụ:** 
  - Bash: `az group create \ --name rg` (đúng)
  - PowerShell: `az group create ` --name rg` (đúng)

### 6.2. Infrastructure as Code (IaC) vs Imperative Script
- **IaC (Declarative):** Định nghĩa trạng thái cuối cùng (ví dụ Bicep, ARM). 
- **Imperative Script:** Tập hợp các lệnh thực thi tuần tự (ví dụ Bash script). 
- **Quyết định:** Script người dùng là Imperative, nhưng vẫn có thể dùng để khởi tạo tài nguyên, tuy nhiên không phải IaC thực thụ.

### Azure ML Data Asset
- Là một tài nguyên quản lý tham chiếu đến dữ liệu trong Storage Account.
- Cho phép pipeline gọi dữ liệu bằng tên logic (ví dụ `azureml:rag-knowledge-base:1`), không cần đường dẫn tuyệt đối.
- Hỗ trợ các loại: `uri_file`, `uri_folder`, `mltable`.

### Azure Relay (qua VS Code extension)
- Cơ chế cho phép kết nối bảo mật đến Compute Instance mà không cần Public IP.
- VS Code extension `Azure Machine Learning - Remote` thiết lập WebSocket mã hóa xuyên qua tường lửa, sử dụng SSH key đã tiêm khi tạo compute.

---

## Các phương án đã cân nhắc

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
|---|---|---|---|
| Dùng script PowerShell (Windows) | Tương thích với môi trường Windows ban đầu. | Không chạy trên Ubuntu (shell hiện tại). | ❌ KHÔNG |
| Dùng Bash script cho Ubuntu | Tương thích với môi trường Ubuntu. | Người dùng phải cài WSL hoặc dùng Linux. | ✅ CÓ |
| Tạo Compute bằng ClickOps (UI) | Nhanh, trực quan. | Không thể version-control, khó tích hợp SSH key. | ❌ KHÔNG |
| Tạo Compute bằng YAML + CLI | Có thể lưu vào Git, tái sử dụng, kiểm soát SSH key. | Cần viết YAML và chạy lệnh CLI. | ✅ CÓ |
| SSH trực tiếp bằng IP công cộng | Đơn giản, dùng cấu hình `~/.ssh/config`. | Yêu cầu Public IP, không có do chính sách tổ chức. | ❌ KHÔNG |
| Kết nối qua VS Code Azure Remote extension | Không cần Public IP, bảo mật. | Phải cài extension và đăng nhập Azure. | ✅ CÓ |
| Lưu ChromaDB vào thư mục tạm (`/tmp`) | Đơn giản, không cần cấu hình. | Mất dữ liệu khi compute tắt. | ❌ KHÔNG |
| Lưu ChromaDB vào `~/cloudfiles/` | Dữ liệu bền vững qua các lần tắt/bật. | Cần biết đường dẫn đặc biệt này. | ✅ CÓ |
