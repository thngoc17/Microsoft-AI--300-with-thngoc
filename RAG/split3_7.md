---
source_url: https://gemini.google.com/app/ee6840b23c523bf2
conversation_date: 2026-08-10
context_week: N/A
conversation_types: [FIX_HA_TANG, FIX_CODE, TRANH_LUAN_QUYET_DINH, LY_THUYET]
ai300_domains: [Design and implement MLOps infrastructure, Model lifecycle]
technologies: [Azure ML Managed Online Endpoint, Docker, Custom Container Image, ACR, Ultralytics YOLO, PyTorch, OpenCV, NumPy, FastAPI, Uvicorn, azureml-inference-server-http, Gunicorn]
key_decision: "Khắc phục lỗi triển khai Azure ML Online Endpoint bằng cách: (1) sử dụng azureml-inference-server-http để bọc code thay vì FastAPI tự build, (2) đổi WORKDIR khỏi thư mục bảo lưu /var/azureml-app, (3) cài đặt thư viện hệ thống cho OpenCV và downgrade NumPy<2.0.0, (4) đảm bảo cấu trúc thư mục model trên Azure khớp tuyệt đối với mã nguồn."
status: resolved
---

## Bối cảnh & Vấn đề

*   **User prompt:** Báo lỗi `Code: InternalServerError Message: Internal error` khi triển khai Azure ML deployment.
*   **Vấn đề cốt lõi:** Container custom không chạy được web server, thiếu thư viện hệ thống, xung đột phiên bản NumPy và sai cấu trúc thư mục model khiến container bị sập ngay sau khi khởi tạo.
*   **Giới hạn:** Bỏ qua nguyên nhân máy ảo yếu; tập trung vào cấu hình hạ tầng và mã nguồn container.
*   **Quy trình triển khai:** Sử dụng Azure CLI với lệnh `az ml online-deployment create` và file YAML cấu hình.

## Quyết định cuối cùng & Lý do

### Phương án được chọn: Sử dụng Native Azure ML Inference Server (`azureml-inference-server-http`)

*   **Lý do:** Tận dụng đúng cơ chế HTTP server chuẩn của Azure ML, tự động mapping các route `/score` và `/docs` mà không cần viết lại logic FastAPI.
*   **Cấu hình Dockerfile cuối cùng:**
    *   `WORKDIR /app` (KHÔNG dùng `/var/azureml-app` vì thư mục này bị Azure mount đè lên, gây che khuất file).
    *   `ENV AZUREML_ENTRY_SCRIPT=online_score.py`
    *   `CMD ["azmlinfsrv", "--entry_script", "online_score.py", "--port", "31311"]`

### Phương án bị loại bỏ: Tự build Web Server bằng FastAPI/Uvicorn

*   **KHÔNG dùng FastAPI** vì Azure ML đã có server chuẩn; việc tự build gây dư thừa và phức tạp hóa kiến trúc.

### Phương án bị loại bỏ: Sửa file `inference.py` để chứa logic HTTP

*   **KHÔNG sửa `inference.py`** (logic AI) vì vi phạm Separation of Concerns; chỉ nên sửa file `online_score.py` (scoring script) hoặc cấu hình Docker.

## Lệnh và Cấu hình cụ thể đã dùng

### File `requirements-serving.txt` (phiên bản cuối cùng)

```txt
azureml-inference-server-http
fastapi>=0.100.0
uvicorn>=0.20.0
opencv-python-headless
torch
torchvision
ultralytics
numpy<2.0.0
```

### File `Dockerfile` (phiên bản cuối cùng)

```dockerfile
FROM python:3.10-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# TUYỆT ĐỐI KHÔNG DÙNG /var/azureml-app
WORKDIR /app

# Cài thư viện hệ thống cho OpenCV (fix lỗi libxcb.so.1)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgomp1 \
    libgl1 \
    libglib2.0-0 \
    libxcb1 \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir --upgrade pip

COPY requirements-serving.txt ./
RUN pip install --no-cache-dir -r requirements-serving.txt

COPY src/inference ./

ENV AZUREML_ENTRY_SCRIPT=online_score.py

EXPOSE 31311

CMD ["azmlinfsrv", "--entry_script", "online_score.py", "--port", "31311"]
```

### File `deployment.yml` (trích đoạn)

```yaml
image: acrthngoc17cv.azurecr.io/tracking-api:v5  # Cập nhật tag mới
instance_type: Standard_B2ms  # Cần kiểm tra RAM
model: azureml:football-tracking-ensemble:1
```

### Lệnh Docker chạy test local (thành công)

```powershell
docker run -it --rm -p 31311:31311 -v "E:\PyCharm\YOLO_football_for_github\config\models:/var/models" -e AZUREML_MODEL_DIR="/var/models" yolo-local-test:v1
```

### Lệnh Push Image lên ACR

```bash
docker build -t acrthngoc17cv.azurecr.io/tracking-api:v5 .
docker push acrthngoc17cv.azurecr.io/tracking-api:v5
```

### Lệnh Azure CLI để lấy log container

```bash
az ml online-deployment get-logs --name yolo-deployment-ver1 --endpoint-name yolo-endpoint-ver1
```

## Lỗi gặp phải và Cách khắc phục

| Lỗi | Nguyên nhân | Cách khắc phục |
| :--- | :--- | :--- |
| **InternalServerError** (CLI timeout ~90s) | Container crash ngay khi khởi động do thiếu web server hoặc lỗi import. | Kiểm tra log container bằng `az ml online-deployment get-logs`. |
| **ImportError: libxcb.so.1: cannot open shared object file** | Base image `python:3.10-slim` thiếu thư viện hệ thống GUI; `opencv-python` yêu cầu libxcb. | Cài đặt `libxcb1`, `libgl1`, `libglib2.0-0` trong Dockerfile (Phương án A) hoặc dùng `opencv-python-headless` (Phương án B). |
| **A module compiled with NumPy 1.x cannot be run in NumPy 2.2.6** | `pip` tự động kéo NumPy 2.x, xung đột ABI với PyTorch/Ultralytics. | Khóa phiên bản `numpy<2.0.0` trong `requirements-serving.txt`. |
| **FileNotFoundError: online_score.py** | Azure mount volume đè lên `/var/azureml-app`. | Đổi `WORKDIR` sang `/app` và update CMD. |
| **FileNotFoundError: .../best.pt** (sau khi fix path) | Cấu trúc thư mục model trên Azure không khớp với code. | **Giải pháp A (Vá code):** Sửa `init()` để trỏ vào `models/best.pt`.<br>**Giải pháp B (Tái cấu trúc):** Đăng ký model lại với cấu trúc thư mục đúng. |

## Khái niệm & Định nghĩa

*   **Custom Container Image trong Azure ML:** Khi dùng image tự build, Azure ML không tự động xử lý HTTP request. Phải có web server (hoặc `azureml-inference-server-http`) lắng nghe cổng `31311` và implement các route `/score` (POST) và `/docs` (GET health check).
*   **Reserved Directory (`/var/azureml-app`):** Thư mục bị Azure ML chiếm dụng để mount log/model. Việc copy code vào đây sẽ bị che khuất khi chạy trên cloud. **Bắt buộc phải dùng thư mục khác** (ví dụ `/app`).
*   **Volume Shadowing:** Khi host mount một volume vào thư mục đã có dữ liệu trong container, dữ liệu cũ bị ẩn đi (shadowed).
*   **Azure ML Inference Server (`azmlinfsrv`):** Server HTTP chính thức của Azure, đọc file scoring script (chứa `init()` và `run()`) và tự động tạo API endpoint.

## Các phương án đã cân nhắc

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
| :--- | :--- | :--- | :--- |
| **FastAPI/Uvicorn tự build** | Linh hoạt, kiểm soát code. | Dư thừa; không tận dụng cơ chế sẵn của Azure. | **KHÔNG** (loại bỏ vì phức tạp hóa) |
| **Sửa file inference.py** | Nhanh chóng. | Vi phạm Separation of Concerns, code rối, khó test. | **KHÔNG** (loại bỏ vì kém maintain) |
| **Sửa WORKDIR** (từ `/var/azureml-app` sang `/app`) | Giải quyết triệt để lỗi FileNotFoundException. | Phải build lại image. | **CÓ** (chốt cuối cùng) |
| **Vá OpenCV (cài libxcb)** | Giữ base image đơn giản. | Tăng size image (~50-80MB). | **CÓ** (chọn apt-get install) |
| **Downgrade NumPy** (`numpy<2.0.0`) | Ổn định ABI, tránh crash. | Phải khóa cứng version. | **CÓ** (bắt buộc) |
| **Sửa code init() để match model path** (models/best.pt) | Không cần đăng ký lại model. | Sai logic thiết kế (spaghetti code). | **Vá tạm thời** (ưu tiên Tái cấu trúc) |
| **Tái cấu trúc Model Artifact** (yolo-detector/best.pt) | Đúng kiến trúc, maintain tốt. | Phải xóa model cũ, đăng ký lại. | **CÓ** (Khuyến nghị để bền vững) |

**Quyết định:** Áp dụng đồng thời các fix: Đổi WORKDIR -> Cài libxcb -> Downgrade NumPy -> (Sửa code hoặc Tái cấu trúc Model tùy chọn).