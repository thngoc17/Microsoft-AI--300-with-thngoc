---
source_url: https://gemini.google.com/app/bb8236fe192e0858
conversation_date: N/A
context_week: Tuần 2
conversation_types: [LAP_KE_HOACH, TRANH_LUAN_QUYET_DINH, FIX_HA_TANG, LY_THUYET]
ai300_domains: [Design and implement MLOps infrastructure]
technologies: [Azure Machine Learning, Azure CLI v2, PyTorch, CUDA, Docker, MLflow, Compute Instance, Compute Cluster, Command Job, Curated Environment]
key_decision: "Từ bỏ việc test bằng Compute Instance CPU để tránh dependency hell, chuyển sang sử dụng Compute Cluster GPU không trạng thái (ephemeral) kết hợp với Command Job và Curated Environments trên Azure ML, đảm bảo tính end-to-end và tiết kiệm chi phí."
status: resolved
---

## Bối cảnh & Vấn đề
Kế hoạch ban đầu cho Tuần 2 của lộ trình AI-300 đề xuất tạo một **Compute Instance (CPU)** để test code NLP/RAG. Tuy nhiên, phương án này bị người dùng bác bỏ vì hai lý do cốt lõi:
1.  Thư viện PyTorch và các thư viện khác trên môi trường CPU gây **xung đột cực mạnh** (dependency hell), dẫn đến mất thời gian sửa lỗi vô ích.
2.  Code test thành công trên CPU **không thể bảo đảm** sẽ chạy trên môi trường GPU thực tế khi deploy, vi phạm nguyên tắc MLOps.
Người dùng đề xuất một hướng thay thế: đóng gói Docker trên Windows để test. Tuy nhiên, phương án này cũng bị đánh giá là tốn kém thời gian nếu phải thiết lập GPU passthrough qua WSL2.

## Quyết định cuối cùng & Lý do
**Quyết định được chốt:** Sử dụng **Azure ML Curated Environments** kết hợp với **Compute Cluster (ephemeral)** và **Command Job** để thực thi mã nguồn.

**Lý do:**
- **Tách biệt hoàn toàn:** Mã nguồn (code) nằm trên máy cá nhân, môi trường (environment) được quản lý trên cloud, tính toán (compute) được cấp phát động. Đây là kiến trúc "Decoupled Architecture" chuẩn MLOps.
- **Tránh dependency hell:** Sử dụng Curated Environment có sẵn của Azure ML (đã được tối ưu với CUDA, PyTorch) để không phải tự cài đặt driver hay xử lý xung đột.
- **Tối ưu chi phí:** Compute Cluster cấu hình `Minimum nodes = 0` sẽ tự động scale về 0 sau khi job chạy xong, chỉ tính phí trong thời gian thực thi.

**Phương án bị loại bỏ (đã ghi nhận để RAG không tái đề xuất):**
1.  **KHÔNG dùng Compute Instance (CPU) để test code có dependency GPU** vì gây xung đột thư viện và không đảm bảo tính nhất quán của môi trường thực thi.
2.  **KHÔNG dùng Docker để test trên Windows** vì việc thiết lập GPU passthrough qua WSL2 là một "hố đen thời gian" đối với người chưa có kinh nghiệm sâu về Docker.

## Lệnh và Cấu hình cụ thể đã dùng
**Curated Environment làm base image:**
```yaml
# Định danh Environment do Microsoft cung cấp, đã cài sẵn CUDA 12.1 và PyTorch 2.2
azureml://registries/azureml/environments/actp-pytorch-2.2-cuda12.1/versions/1
```

**Cấu hình Compute Cluster tối ưu chi phí:**
```yaml
# Loại VM GPU giá rẻ cho test NLP/CV
vm_size: Standard_NC4as_T4_v3
# Không giữ máy chạy 24/7, chỉ cấp phát khi có job
minimum_nodes: 0
maximum_nodes: 1
# Tự động tắt máy sau 2 phút kể từ khi job kết thúc để tiết kiệm tiền
idle_time_before_scale_down: 120 seconds
```

**Nguyên tắc code để tương thích trên Linux:**
```python
# Sử dụng os.path hoặc pathlib để xử lý đường dẫn, không hardcode dấu \
# Và truyền tham số bằng argparse, không dùng đường dẫn cục bộ
import argparse
parser = argparse.ArgumentParser()
parser.add_argument("--data_dir", type=str, help="Path to data on Datastore")
args = parser.parse_args()
```

## Lỗi gặp phải và Cách khắc phục
| Anti-pattern / Bug | Cách khắc phục / Quy tắc |
| :--- | :--- |
| **Sử dụng thư viện `azureml-core` (SDK v1)** | **Tuyệt đối không dùng.** Chỉ sử dụng `azure-ai-ml` (SDK v2) cho mọi thao tác. Nhầm lẫn hai phiên bản này sẽ phá vỡ pipeline. |
| **Hardcode đường dẫn file kiểu Windows (`C:\...`)** | Code phải sử dụng `os.path.join` hoặc `pathlib`. Dữ liệu đọc/ghi phải được truyền vào dưới dạng argument (argparse) từ Datastore. |
| **Cài đặt thủ công dependencies lên Compute Instance** | Định nghĩa môi trường (conda.yaml) và để Azure ML tự động build khi chạy Command Job. |
| **Test trên CPU rồi deploy lên GPU** | Luôn test trên môi trường có GPU (ephemeral cluster) để đảm bảo không có lỗi dependency. |

## Lộ trình chi tiết (Tuần 2 - Cập nhật từ Ngày 3)

Đây là kế hoạch được điều chỉnh từ Ngày 3 trở đi, bỏ qua Compute Instance CPU và đi thẳng vào luồng MLOps chuẩn.

**Ngày 3: Định nghĩa Môi trường GPU chuẩn (Azure ML Environment)**
- **Mục tiêu:** Đóng gói dependency trên nền tảng Linux/CUDA.
- **Hành động:** Khai báo `conda.yaml` chứa các thư viện bổ sung (transformers, chromadb...). Tạo Custom Environment từ Curated Image làm base.

**Ngày 4: Thiết lập Compute Cluster (Ephemeral GPU)**
- **Mục tiêu:** Cung cấp tài nguyên GPU để test nhưng không mất tiền khi rảnh rỗi.
- **Hành động:** Tạo Compute Cluster với `min_nodes=0`, chọn VM GPU (Standard_NC4as_T4_v3). Xử lý Quota (Spot Instance hoặc request tăng quota).

**Ngày 5: Đóng gói và Thực thi với Command Job**
- **Mục tiêu:** Tách biệt code khỏi môi trường cục bộ.
- **Hành động:** Gom code vào thư mục `src/`. Viết cấu hình Job (YAML/SDK) để submit code lên cloud, kết nối Compute Cluster và Environment, chạy lệnh `python src/train.py`.

**Ngày 6: Tích hợp MLflow và Giám sát Remote Job**
- **Mục tiêu:** Tracking tiến trình khi mã đang chạy headless.
- **Hành động:** Gọi `mlflow.autolog()` trong script. Học cách đọc log lỗi từ Azure ML Studio (tab Outputs + Logs).

**Ngày 7: Local Docker Foundations (Cho Tuần 3)**
- **Mục tiêu:** Làm quen với Docker để chuẩn bị deploy API, không dùng để test training.
- **Hành động:** Cài Docker Desktop (WSL2 backend). Viết Dockerfile tối giản cho inference (`python:3.10-slim`). Thực hành `build`, `run`, `push` lên ACR.

## Khái niệm & Định nghĩa
- **Decoupled Architecture (Kiến trúc tách rời):** Mô hình thiết kế trong MLOps nơi mã nguồn (Code), môi trường thực thi (Environment/Docker) và tài nguyên tính toán (Compute) được quản lý độc lập. Thay đổi một thành phần không ảnh hưởng đến thành phần khác. **Ví dụ:** Code nằm trên máy tính của bạn, môi trường được lưu trên Azure Container Registry, và khi chạy, Azure sẽ lấy code + môi trường để thực thi trên một Compute Cluster có sẵn, sau đó giải phóng compute.
- **Ephemeral Compute (Tài nguyên tính toán không trạng thái):** Tài nguyên (máy ảo, cluster) chỉ được khởi tạo để phục vụ một tác vụ cụ thể và bị phá hủy ngay sau khi tác vụ hoàn thành. Điều này giúp tối ưu chi phí vì bạn chỉ trả tiền cho thời gian sử dụng thực tế. **Ví dụ:** Compute Cluster với `minimum_nodes = 0` trong Azure ML.

## Các phương án đã cân nhắc

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
| :--- | :--- | :--- | :--- |
| **A. Compute Instance CPU** | Dễ tạo, có thể SSH để debug. | Dependency hell (xung đột PyTorch CPU), không đảm bảo tương thích GPU. Tốn thời gian sửa lỗi. | **KHÔNG** |
| **B. Docker trên Windows** | Có thể test offline, mô phỏng môi trường Linux. | Thiết lập GPU passthrough qua WSL2 rất phức tạp, mất nhiều thời gian. | **KHÔNG** |
| **C. Azure ML Command Job + Compute Cluster GPU** | Tự động loại bỏ dependency hell (dùng Curated Env). Tiết kiệm chi phí (ephemeral). Sát với bài thi AI-300. | Cần làm quen với khái niệm Job/logging từ xa (không có console trực tiếp). | **CÓ (Được chọn)** |