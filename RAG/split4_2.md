---
source_url: https://gemini.google.com/app/4021e879eb4cfb02
conversation_date: 2026-08-01 (suy luận từ nội dung hội thoại)
context_week: Tuần 6
conversation_types: [LAP_KE_HOACH, TRANH_LUAN_QUYET_DINH, FIX_HA_TANG, LY_THUYET, KIEM_TRA_KIEN_THUC]
ai300_domains: ["Design and implement MLOps infrastructure", "Model lifecycle", "GenAIOps infrastructure"]
technologies: [MLflow, Azure CLI, Azure ML, Azure Container Registry (ACR), Compute Cluster, Application Insights, Bicep, Azure Kubernetes Service (AKS), Managed Identity, Private Endpoint, GitHub Actions, RAG, Microsoft Foundry]
key_decision: "Quyết định loại bỏ hoàn toàn việc huấn luyện (training) mô hình trên Azure ML do giới hạn phần cứng (GPU) và lỗi dependency phức tạp, chuyển sang mô hình BYOM (Bring Your Own Model) để tập trung triển khai và vận hành (serving, monitoring, security)."
status: superseded_by_later_conversation
---

## Bối cảnh & Vấn đề

*   **Mục tiêu tổng thể:** Chuẩn bị cho chứng chỉ Microsoft AI-300 (Azure AI Engineer). Lộ trình 12 tuần bao gồm 10 tuần thực hành và 2 tuần ôn tập.
*   **Nguồn lực:** Tài khoản Azure Student. Hạn chế chính: **không có GPU** và có giới hạn về quota/CPU cốt lõi. Người dùng đã có kinh nghiệm triển khai endpoint (serving) và đăng ký model nhưng thiếu kinh nghiệm với MLflow và training lifecycle trên Azure.
*   **Vấn đề cốt lõi:** Cần xây dựng kế hoạch chi tiết cho Tuần 6, tập trung vào lĩnh vực "Model Lifecycle" và "MLOps Infrastructure", nhưng phải xoay xở với giới hạn tài nguyên.

## Quyết định cuối cùng & Lý do

*   **Tuần 6 (Kế hoạch gốc):**
    *   **Ngày 1:** Thực hành log metrics/parameters/artifacts với MLflow từ máy local lên Azure ML Workspace.
    *   **Ngày 2:** Đóng gói và chạy training script (Command Job) trên cloud compute (CPU).
    *   **Ngày 3:** Cấu hình monitoring (Application Insights) và data drift detection.
    *   **Ngày 4:** Làm quen với Infrastructure as Code (IaC) sử dụng Bicep.
    *   **Ngày 5:** Học và thực hành về Managed Identity, RBAC, và các khái niệm bảo mật (VNet, Private Link).

*   **Phương án KHÔNG dùng (ĐÃ LOẠI BỎ):**
    *   **Bypass hoàn toàn training trên cloud** vì thiếu GPU. **Lý do:** Đây là một lỗ hổng kiến thức lớn cho kỳ thi AI-300 (domain "Model lifecycle" chiếm 25-30%), cần thực hành dù chỉ với CPU.
    *   **Dùng `DefaultAzureCredential()` trong Command Job.** **Lý do:** Compute Node trên Azure không có bối cảnh xác thực như local, gây ra lỗi `CredentialUnavailableError`. Azure ML sử dụng cơ chế Context Injection để tự động cấp token. Việc hardcode sẽ phá vỡ tính di động của mã nguồn và CI/CD.

*   **Quyết định cuối cùng (Sau khi thực tế gặp nhiều lỗi dependency và cache):**
    *   **QUYẾT ĐỊNH CẮT LỖ (CUT-LOSS):** Dừng toàn bộ tác vụ huấn luyện (training) trên Azure ML. Lý do: Chi phí cơ hội của việc gỡ lỗi (dependency hell, cache invalidation) quá cao so với lợi ích thu được.
    *   **Kiến trúc mới: BYOM (Bring Your Own Model):** Huấn luyện mô hình cục bộ hoặc trên Colab, sau đó **đăng ký trực tiếp** trọng số (`.pt`, `.onnx`) lên Azure ML Registry. Azure ML chỉ đóng vai trò là trung tâm lưu trữ và phục vụ mô hình (Serving & Registry).
    *   **Điều chỉnh lộ trình:** Tập trung 3 ngày còn lại của Tuần 6 vào các domain khả thi và quan trọng khác: Observability (Ngày 3), Infrastructure as Code (Ngày 4), và Security/Governance (Ngày 5).
    *   **Lấp lỗ hổng lý thuyết:** Bù đắp phần thực hành còn thiếu bằng cách học kỹ cấu trúc YAML (Command/Sweep/Pipeline jobs) từ tài liệu Microsoft Learn trong giai đoạn ôn thi (Tuần 11-12).

## Lệnh và Cấu hình cụ thể đã dùng

### a. Script huấn luyện (cho mục đích test, **không sử dụng**)
```python
# File: src/train_cloud.py (KHÔNG SỬ DỤNG do lỗi)
# Đã được refactor để loại bỏ DefaultAzureCredential
import mlflow
import time
import random
import os
import argparse

parser = argparse.ArgumentParser()
parser.add_argument("--epochs", type=int, default=5)
parser.add_argument("--learning_rate", type=float, default=0.001)
args = parser.parse_args()

with mlflow.start_run() as run:
    mlflow.log_param("epochs", args.epochs)
    mlflow.log_param("learning_rate", args.learning_rate)
    for epoch in range(args.epochs):
        loss = 1.0 / (epoch + 1) + (random.random() * 0.1)
        accuracy = 1.0 - loss
        mlflow.log_metric("train_loss", loss, step=epoch)
        mlflow.log_metric("val_accuracy", accuracy, step=epoch)
        time.sleep(1)
    dummy_model_path = "dummy_weights.pt"
    with open(dummy_model_path, "w") as f:
        f.write("cloud_tensor_weights_data")
    mlflow.log_artifact(dummy_model_path, artifact_path="model_weights")
    os.remove(dummy_model_path)
```

### b. Cấu hình môi trường (Conda) (KHÔNG SỬ DỤNG)
```yaml
# File: src/conda.yml (KHÔNG SỬ DỤNG do lỗi cache)
name: mlflow-env
channels:
  - conda-forge
dependencies:
  - python=3.10
  - pip
  - pip:
    - mlflow==2.13.2
    - azureml-mlflow==1.50.0
```

### c. Cấu hình Job YAML (KHÔNG SỬ DỤNG)

**Phiên bản lỗi (Serverless compute):**
```yaml
# File: job.yml (lỗi: Unknown compute target 'serverless')
$schema: https://azuremlschemas.azureedge.net/latest/commandJob.schema.json
# ...
compute: azureml:serverless
```

**Phiên bản đã sửa (Compute Cluster):**
```yaml
# File: job.yml
$schema: https://azuremlschemas.azureedge.net/latest/commandJob.schema.json
experiment_name: cloud-mlflow-training

code: ./src

command: >-
  python train_cloud.py
  --epochs ${inputs.epochs}
  --learning_rate ${inputs.learning_rate}

inputs:
  epochs: 5
  learning_rate: 0.001

environment:
  name: strict-mlflow-env-v2
  version: 2
  image: mcr.microsoft.com/azureml/openmpl4.1.0-ubuntu20.04:latest
  conda_file: ./conda.yml

compute: azureml:cpu-cluster
```

### d. Cấu hình Job YAML (Giải pháp thực dụng, ĐƯỢC ĐỀ XUẤT)
```yaml
# File: job.yml (Giải pháp cuối cùng được đề xuất để chạy job)
$schema: https://azuremlschemas.azureedge.net/latest/commandJob.schema.json
experiment_name: cloud-mlflow-training-runtime-override

code: ./src

# Ghi đề hệ thống bằng cách ép pip install TRƯỚC KHI chạy python
command: >
  pip install mlflow==2.13.2 azureml-mlflow==1.50.0 &&
  python train_cloud.py
  --epochs ${inputs.epochs}
  --learning_rate ${inputs.learning_rate}

inputs:
  epochs: 5
  learning_rate: 0.001

# Sử dụng một môi trường có sẵn của Azure
environment: azureml://registries/azureml/environments/sklearn-1.5/versions/1

compute: azureml:cpu-cluster
```

### e. Lệnh Azure CLI

**Tạo Compute Cluster:**
```bash
az ml compute create --name cpu-cluster \
    --size Standard_DS11_v2 \
    --min-instances 0 \
    --max-instances 1 \
    --type amlcompute \
    --workspace-name <ten-workspace> \
    --resource-group <ten-resource-group>
```

**Bật quyền Admin cho ACR:**
```bash
az acr update --name acrthngoc17cv --resource-group <ten-resource-group> --admin-enabled true
```

**Đồng bộ khóa workspace với ACR:**
```bash
az ml workspace sync-keys --name <ten-workspace> --resource-group <ten-resource-group>
```

**Submit Job:**
```bash
az ml job create -f job.yml --workspace-name <ten-workspace> --resource-group <ten-resource-group>
```

## Lỗi gặp phải và Cách khắc phục

| Lỗi / Vấn đề | Nguyên nhân gốc rễ | Cách khắc phục / Quy tắc |
| :--- | :--- | :--- |
| `UnsupportedModelRegistryStoreURIException` | Thiếu plugin `azureml-mlflow`. MLflow không hiểu giao thức `azureml://`. | Cài đặt thư viện `azureml-mlflow`. **Quy tắc:** Đảm bảo cài đặt plugin tương thích với phiên bản MLflow. |
| `TypeError: azureml_artifacts_builder() got an unexpected keyword argument 'tracking_uri'` | Xung đột version giữa `mlflow` (>=2.15.0) và `azureml-mlflow`. Plugin chưa cập nhật kịp. | Hạ cấp `mlflow` về phiên bản ổn định: `pip install mlflow==2.13.2`. <br><br> **Quy tắc:** Xác định version cụ thể trong `requirements.txt`/`conda.yml`. |
| `Unknown compute target 'serverless'` | Tài khoản Student không có quota cho serverless compute pool. | Tạo và chỉ định một `AmlCompute Cluster` cụ thể. |
| `Failed to pull Docker image ... This error may occur because the compute could not authenticate with the Docker registry` | Compute Cluster không có quyền kéo image từ ACR. | **Cách 1 (Chuẩn):** Gán System-Assigned Managed Identity cho compute và cấp quyền `AcrPull`.<br><br>**Cách 2 (Thực dụng):** Bật Admin User trên ACR và chạy `az ml workspace sync-keys` để workspace cấp thông tin đăng nhập mới cho compute. |
| Job vẫn chạy Python 3.11 dù `conda.yml` chỉ định Python 3.10 | **Cache Invalidation**: Azure sử dụng lại Docker image cũ từ registry để tiết kiệm thời gian. | **Quy tắc:** Thay đổi `version` hoặc `name` của `environment` trong file `job.yml` để ép Azure build image mới. |
| Lỗi `CredentialUnavailableError` (suy luận) | Sử dụng `DefaultAzureCredential()` trong script chạy trên compute node. | **Quy tắc:** KHÔNG khởi tạo `MLClient` hay `DefaultAzureCredential` trong script chạy trên Azure ML. Sử dụng cơ chế Context Injection (Azure tự động cấp token). |

## Lộ trình chi tiết (Tuần 6)

| Ngày | Mục tiêu chính | Chi tiết công việc | Chỉ tiêu hoàn thành |
| :--- | :--- | :--- | :--- |
| **Ngày 1** (Đã làm) | Tracking cục bộ với MLflow | - Viết script training CPU.<br>- Cấu hình MLflow trỏ đến Azure Workspace.<br>- Chạy script local và log params/metrics/artifacts lên Azure. | - (Chưa hoàn thành) Bị lỗi version, đã được hướng dẫn fix. |
| **Ngày 2** (Đã bỏ) | Đóng gói và Thực thi Cloud Training (Command Job) | - Viết `job.yml` định nghĩa code, command, environment.<br>- Chạy job trên Azure CLI. | - (Đã bỏ) Bị lỗi RBAC và cache, gây mất thời gian. **Quyết định dừng.** |
| **Ngày 3** (Chuyển hướng) | Observability & Monitoring | - Bật Application Insights cho endpoint đã triển khai.<br>- Gửi request và log latency, errors.<br>- Cấu hình Data Drift detection. | - (Chưa làm) Sẵn sàng thực hiện. |
| **Ngày 4** (Chuyển hướng) | Infrastructure as Code (Bicep) | - Viết `main.bicep` khai báo Workspace, Storage, Key Vault, App Insights.<br>- Triển khai bằng `az deployment group create`. | - (Chưa làm) Sẵn sàng thực hiện. |
| **Ngày 5** (Chuyển hướng) | Security & Governance (RBAC) | - Tạo và gán Managed Identity cho compute.<br>- Đọc và hiểu kiến trúc VNet/Private Link (lý thuyết). | - (Chưa làm) Sẵn sàng thực hiện. |

## Khái niệm & Định nghĩa

*   **Managed Identity:**
    *   **Định nghĩa:** Một danh tính tự động được Azure quản lý, dùng để xác thực các dịch vụ Azure với nhau mà không cần lưu trữ thông tin đăng nhập (credentials) trong code.
    *   **Ví dụ:** Gán System-Assigned Managed Identity cho `cpu-cluster` để nó có thể kéo (pull) image từ ACR mà không cần username/password.

*   **Cache Invalidation (và Environment Versioning):**
    *   **Định nghĩa:** Quá trình làm mới hoặc vô hiệu hóa bộ nhớ đệm (cache) để buộc hệ thống tạo lại các thành phần từ đầu.
    *   **Ví dụ:** Azure ML sử dụng cache để tối ưu hóa việc build Docker image. Nếu không thay đổi `name` hoặc `version` của `environment` trong `job.yml`, nó sẽ tái sử dụng image cũ, dẫn đến việc các thay đổi trong `conda.yml` không được áp dụng. Do đó, `version: 2` được thêm vào để phá cache.

*   **Infrastructure as Code (IaC):**
    *   **Định nghĩa:** Quản lý và cung cấp hạ tầng (máy chủ, mạng, cơ sở dữ liệu, v.v.) thông qua mã nguồn (configuration files) thay vì các quy trình thủ công (click chuột trên portal).
    *   **Ví dụ:** Viết một file `main.bicep` để khai báo tất cả tài nguyên Azure ML (Workspace, Storage, Cluster, Endpoint) và triển khai chúng bằng một lệnh CLI duy nhất.

## Các phương án đã cân nhắc

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
| :--- | :--- | :--- | :--- |
| **A. Training trên Cloud (Command Job)** | - Bám sát domain "Model lifecycle" của kỳ thi.<br>- Tự động hóa và tái tạo được. | - Tốn thời gian cấu hình, debug dependency.<br>- Gặp nhiều lỗi (RBAC, cache, version).<br>- Không có GPU cho training thực tế. | **KHÔNG** (Đã loại bỏ sau khi quá nhiều lỗi phát sinh) |
| **B. BYOM (Bring Your Own Model)** | - Nhanh, thực dụng.<br>- Tận dụng tài nguyên local/Colab.<br>- Vẫn được thực hành serving và monitoring. | - Không thực hành được training pipeline.<br>- Tạo lỗ hổng kiến thức cho kỳ thi. | **CÓ** (Quyết định cuối cùng để tối ưu thời gian) |
| **C. Hardcode `tracking_uri` và `DefaultAzureCredential`** | - Giải pháp "chữa cháy" nhanh cho lỗi current. | - Sẽ gây lỗi `CredentialUnavailableError` trên compute node.<br>- Phá vỡ tính di động và bảo mật.<br>- **KHÔNG BAO GIỜ DÙNG TRONG SẢN PHẨM.** | **KHÔNG** (Bị phản biện và loại bỏ ngay lập tức) |

## Nhật ký câu hỏi – trả lời – đánh giá

**Câu hỏi:** Trong kế hoạch MLOps, nếu tài khoản Azure Student không hỗ trợ GPU, có nên bypass việc training mô hình trên cloud hay không?

**Câu trả lời của người dùng (ngầm định):** Đề xuất bypass để tiết kiệm thời gian.

**Verdict:** **SAI.**

**Đánh giá:** Đây là một sai lầm chiến lược. Mục tiêu của kỳ thi AI-300 không phải là train một model state-of-the-art, mà là hiểu và xây dựng quy trình MLOps. Việc bypass sẽ khiến ứng viên mất cơ hội thực hành cách cấu hình Command Job, Environment, và Compute Target - những phần chiếm tỷ trọng lớn trong đề thi. Thay vào đó, nên dùng mô hình CPU đơn giản để học luồng kiến trúc.

**Câu hỏi:** Khi chạy Command Job trên Azure ML, có nên dùng `DefaultAzureCredential()` trong script để xác thực với MLflow hay không?

**Câu trả lời của người dùng (ngầm định):** Có thể dùng lại cách đã làm ở local.

**Verdict:** **SAI.**

**Đánh giá:** Compute Node hoạt động trong môi trường headless và không có bối cảnh `az login` từ local. `DefaultAzureCredential()` sẽ tìm kiếm token nhưng không tìm thấy, dẫn đến lỗi `CredentialUnavailableError`. Azure ML tự động tiêm token và tracking URI vào biến môi trường (Context Injection), do đó script phải được viết để không cần cấu hình thủ công.
