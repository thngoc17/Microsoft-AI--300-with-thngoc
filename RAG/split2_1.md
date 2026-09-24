---
source_url: https://gemini.google.com/app/d7ceb683c2147ee6
conversation_date: 2026-09-03
context_week: Tuần 2
conversation_types: [LAP_KE_HOACH, LY_THUYET]
ai300_domains: [Design and implement MLOps infrastructure, Model lifecycle]
technologies: [Azure CLI, VS Code Remote-SSH, MLflow, Azure Blob Storage, Compute Instance, Environment (azure-ai-ml), Datastore]
key_decision: "Xác định lộ trình cụ thể cho tuần 2: chuyển môi trường dev từ máy cá nhân lên Azure ML Workspace, thiết lập kết nối SSH, cấu hình Datastore và Environment, tích hợp MLflow, và lưu ý cấm dùng SDK v1 (azureml-core) mà phải dùng v2 (azure-ai-ml) để tương thích với AI-300."
status: resolved
---

## Bối cảnh & Vấn đề

Hội thoại vạch ra kế hoạch chi tiết cho Tuần 2 của lộ trình 3 tháng ôn thi AI-300, tập trung vào việc thiết lập môi trường làm việc trên Azure Machine Learning.

**Mục tiêu cốt lõi**:
- Chuyển dịch môi trường phát triển từ máy cá nhân lên cloud.
- Thiết lập thói quen theo dõi thử nghiệm (experiment tracking) bằng MLflow.
- Xử lý các vấn đề về tương thích môi trường.

## Quyết định cuối cùng & Lý do

**Kiến trúc lựa chọn**:
- Workspace Azure ML + Compute Instance (Standard_DS3_v2 cho CPU, NC/ND cho GPU nếu cần)
- Kết nối từ máy cá nhân bằng VS Code Remote-SSH
- Datastore: Sử dụng Azure Blob Storage (tạo mặc định cùng Workspace)
- Environment: Tạo từ `requirements.txt` hoặc `conda.yaml` bằng SDK v2
- Tracking: MLflow tích hợp sẵn trong Workspace
- **KHÔNG dùng SDK v1 (`azureml-core`)** vì gây vỡ kiến trúc pipeline (Azure ML SDK v2 bắt buộc cho AI-300)
- **KHÔNG dùng dấu `\` trong đường dẫn file** — chuyển sang `os.path` hoặc `pathlib` để tương thích Linux

## Lệnh và Cấu hình cụ thể đã dùng

### CLI tạo Workspace
```bash
az ml workspace create \
  --name <workspace_name> \
  --resource-group <resource_group> \
  --location <region> \
  --subscription <subscription_id>
```

### Tạo Compute Instance (có SSH)
- Qua Azure Portal: bật SSH access ngay trong quá trình tạo (không thể bật sau).
- Qua CLI v2:
```yaml
# compute-instance.yaml
$schema: https://azuremlschemas.azureedge.net/latest/computeInstance.schema.json
name: my-compute-instance
type: computeinstance
size: Standard_DS3_v2
ssh_settings:
  admin_username: azureuser
  ssh_key_value: <public_ssh_key>
```

### Tạo SSH Key (Windows → Linux)
```powershell
ssh-keygen -t rsa -b 4096
```

### Cấu hình VS Code Remote-SSH
```text
# ~/.ssh/config
Host azure-ml-instance
    HostName <public_ip_or_dns>
    User azureuser
    Port 50000
    IdentityFile C:\Users\<User>\.ssh\id_rsa
```

### Đăng ký Datastore
```yaml
# datastore.yaml
$schema: https://azuremlschemas.azureedge.net/latest/datastore.schema.json
name: my_blob_store
type: azure_blob
account_name: <storage_account>
container_name: <container>
credentials:
  account_key: <key_or_sas>
```

### Tạo Environment từ `requirements.txt`
```yaml
# environment.yaml
$schema: https://azuremlschemas.azureedge.net/latest/environment.schema.json
name: nlp-env
image: mcr.microsoft.com/azureml/openmpi4.1.0-ubuntu20.04:latest
conda_file: conda.yaml
```
Trong `conda.yaml`:
```yaml
name: nlp-env
dependencies:
  - python=3.8
  - pip
  - pip:
      - -r requirements.txt
```

### MLflow Tracking Setup
```python
import mlflow
mlflow.set_tracking_uri(workspace.get_mlflow_tracking_uri())
mlflow.autolog()  # Tự log cho các framework chuẩn
# Hoặc:
with mlflow.start_run():
    mlflow.log_param("chunk_size", 512)
    mlflow.log_metric("accuracy", 0.92)
```

### Auto-shutdown Configuration (qua CLI v2)
```yaml
# schedule.yaml
$schema: https://azuremlschemas.azureedge.net/latest/computeInstanceSchedule.schema.json
name: shutdown-schedule
compute: my-compute-instance
start_time: "2026-09-10T18:00:00"
time_zone: "SE Asia Standard Time"
```

## Lỗi gặp phải và Cách khắc phục

| Lỗi / Anti-pattern | Cách khắc phục |
|---|---|
| **SSH không bật sau khi tạo Compute Instance** | Phải bật SSH ngay từ lúc tạo, không thể sửa sau. |
| **Đường dẫn `\` trong code chạy trên Linux Compute** | Dùng `os.path.join()` hoặc `pathlib.Path` để tương thích cả Windows/Linux. |
| **Vector DB (Chroma) lưu cục bộ bị mất khi restart Instance** | Trỏ đường dẫn lưu vào thư mục được mount với Datastore (thường nằm ở `/mnt/batch/tasks/shared/...`). |
| **Nhầm lẫn SDK v1 và v2** | Chỉ dùng thư viện `azure-ai-ml` (SDK v2). Bỏ mọi tham chiếu đến `azureml-core`. |
| **OOM khi chạy inference Qwen trên CPU instance** | Chuyển sang GPU instance (dòng NC/ND) nếu cần; kiểm tra quota account trước. |
| **Quota GPU không đủ** | Ưu tiên CPU cho test code logic, GPU chỉ dùng khi cần run thực tế. |

## 5. Lộ trình chi tiết

### Ngày 1: Thiết lập Azure ML Workspace & Compute
- **Mục tiêu**: Xây dựng nền tảng hạ tầng cơ bản.
- Tạo Workspace (Portal hoặc CLI).
- Tạo Compute Instance: CPU (Standard_DS3_v2) cho dev, GPU (NC/ND) nếu cần inference Qwen.
- **Lưu ý**: Bật SSH ngay khi tạo.

### Ngày 2: Cấu hình VS Code Remote-SSH (Từ Windows lên Linux)
- **Mục tiêu**: Môi trường code liền mạch trên máy cá nhân nhưng thực thi trên cloud.
- Tạo SSH Key trên Windows.
- Cấu hình VS Code Remote-SSH và test kết nối.

### Ngày 3: Xử lý Dữ liệu (Datastore) & Biến Môi trường
- **Mục tiêu**: Tách biệt dữ liệu khỏi mã nguồn và giải quyết đường dẫn.
- Upload dữ liệu lên Blob Storage → đăng ký Datastore.
- **Bắt buộc**: Chuyển toàn bộ xử lý file sang `os.path` hoặc `pathlib`.
- Vector DB lưu trỏ vào thư mục được mount với Datastore.

### Ngày 4: Định nghĩa Environment & Dependencies
- **Mục tiêu**: Đóng gói môi trường Python chuẩn bị cho Docker hóa.
- Xuất `requirements.txt` (PyTorch, transformers, vector DB, API clients...).
- Tạo Environment từ file bằng Azure ML SDK v2 hoặc CLI v2.

### Ngày 5: Tích hợp MLflow vào Pipeline
- **Mục tiêu**: Giám sát và ghi nhận các thông số huấn luyện hoặc cấu hình sinh văn bản.
- Thiết lập tracking URI trỏ về Workspace.
- Chèn `mlflow.log_param()` và `mlflow.log_metric()` vào script.
- Kiểm tra log trong Azure ML Studio.

### Ngày 6: Chạy thử nghiệm & Gỡ lỗi (Debugging)
- **Mục tiêu**: Hoàn thiện luồng thực thi trực tiếp trên Compute.
- Chạy script qua terminal SSH.
- Kiểm tra MLflow đã log thành công chưa.
- Xử lý lỗi: đọc `std_log.txt` nếu có OOM hoặc sai đường dẫn.

### Ngày 7: Tổng kết & Tối ưu Chi phí
- **Mục tiêu**: Hoàn tất tuần và tối ưu chi phí.
- Cấu hình **auto-shutdown** để tránh phát sinh chi phí.
- Ôn tập Study Guide: đọc về "Workspaces", "Compute Targets" (Instance vs Cluster), "Datastores".
- Hệ thống hóa kiến thức.

## Khái niệm & Định nghĩa

| Thuật ngữ | Định nghĩa | Ví dụ / Lưu ý |
|---|---|---|
| **Workspace** | Tài nguyên top-level trong Azure ML, chứa toàn bộ artifacts, compute, và dữ liệu. | Tạo 1 Workspace duy nhất cho lộ trình 12 tuần. |
| **Compute Instance** | VM dùng để dev/interactive, có thể SSH và cài IDE. | Dùng cho dev (mã nguồn, debug). |
| **Compute Cluster** | Cluster VM dùng để chạy batch job/training quy mô lớn. | Tự động scale; dùng cho training chính thức. |
| **Datastore** | Trừu tượng hóa storage (Blob, ADLS) để lưu dữ liệu huấn luyện. | Đăng ký Blob chứa dữ liệu. |
| **Environment** | Container base định nghĩa dependencies và runtime. | Dùng để Docker hóa ở Tuần 3. |
| **MLflow** | Framework theo dõi experiment, log params/metrics, và quản lý model. | Azure ML tích hợp sẵn MLflow tracking URI. |
| **Remote-SSH** | Giao thức kết nối từ máy cá nhân vào Compute Instance. | Dùng VS Code để code trên cloud. |
| **SDK v2 (azure-ai-ml)** | SDK chính thức mới nhất của Azure ML, bắt buộc cho AI-300. | Định nghĩa tài nguyên bằng YAML hoặc Python. |
| **SDK v1 (azureml-core)** | SDK cũ, không được dùng. | KHÔNG dùng; gây vỡ pipeline ở các tuần sau. |

