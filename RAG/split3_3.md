---
source_url: https://gemini.google.com/app/eee93d219072efc8
conversation_date: N/A
context_week: Tuần 4-5
conversation_types: [LAP_KE_HOACH, TRANH_LUAN_QUYET_DINH, FIX_HA_TANG, FIX_CODE, LY_THUYET]
ai300_domains: [Design and implement MLOps infrastructure, Model lifecycle, GenAIOps infrastructure, Optimize generative AI systems]
technologies: [Azure Machine Learning, YOLO11, ResNet50, PyTorch, Docker, Azure Container Registry, GitHub Actions, MLflow, OpenCV, Ultralytics, azureml-inference-server-http]
key_decision: "Xây dựng hệ thống serving CPU-only cho 3 model (YOLO + 2 ResNet) trên Azure ML Managed Endpoints, sử dụng cùng một Docker image cho online và batch, tách biệt logic core và scoring script, áp dụng CI/CD với validation gate để tự động cập nhật endpoint sau khi vượt ngưỡng chất lượng."
status: resolved
---

## Bối cảnh & Vấn đề

Khi phân tích mã nguồn từ repo, phát hiện 4 vấn đề chính ảnh hưởng đến kế hoạch sprint tuần 4-5:

- **3 model, không phải 1:** Config yêu cầu đồng thời `best.pt` (YOLO11 detection), `jersey_color_model.pt.hv` và `jersey_visibility_model.pth` (cả hai là ResNet50). Serving pipeline phải load cả 3.
- **Tên file lỗi:** `train_detection.sh` gọi `train_detection.py` nhưng file thực tế là `train_detection(!).py` – lệnh sẽ báo lỗi.
- **Requirements không dùng được trên CPU:** `requirements.txt` pin `torch==2.2.0.dev20231211+cu121` (bản nightly CUDA) – không có nghĩa trên CPU.
- **GUI trong inference:** `src/inference/inference.py` gọi `play_video()` (mở cửa sổ cv2) – trong container Azure không có display, sẽ treo/crash.
- **JSON ground-truth bị lỗi cú pháp:** `dummy_clip_1.json` có dấu phẩy thừa ở annotation cuối.

Cần triển khai một sprint 1 tuần để xây dựng serving CPU-only cho 3 model, kèm CI/CD.

## Quyết định cuối cùng & Lý do

**Kiến trúc tổng thể:**
- Sử dụng **Azure ML Managed Endpoint** (cả Online và Batch) với cùng một Docker image.
- **Không dùng FastAPI/Uvicorn** – lý do:
  - Azure ML cung cấp `azureml-inference-server-http` – một HTTP server tích hợp, tự động quản lý routing, telemetry (Application Insights), và hỗ trợ cả online lẫn batch endpoint.
  - Batch Endpoint hoạt động theo cơ chế MapReduce; FastAPI không hỗ trợ batch job, buộc phải tự xây dựng queue/worker – tốn thời gian không cần thiết.
  - Dùng FastAPI sẽ phá vỡ hợp đồng với Azure (không emit đúng telemetry).
- **Tách `inference.py` thành 3 file:**
  - `inference_core.py`: chứa logic chung (YOLO, JerseyClassifier, box_iou) – không có GUI.
  - `online/score.py`: dùng cho Online Endpoint, nhận base64 image, trả về detections (không tracking).
  - `batch/score.py`: dùng cho Batch Endpoint, nhận danh sách video, xử lý từng video với tracking, reset state cho mỗi video.
- **Đăng ký model dưới dạng Model asset**, không phải Data asset – để Azure mount vào `AZUREML_MODEL_DIR`.
- **Sử dụng `--extra-index-url`** cho PyTorch CPU, không dùng `--index-url` để tránh xung đột.

**Các phương án bị loại bỏ:**
- **KHÔNG dùng `az ml data create` để đăng ký checkpoint** vì sẽ không mount vào `AZUREML_MODEL_DIR` – phải dùng `az ml model create --type custom_model`.
- **KHÔNG dùng FastAPI/Uvicorn** vì không tương thích với Batch Endpoint và gây mất tích hợp telemetry (lý do chi tiết xem phần Lý thuyết).
- **KHÔNG đóng gói model vào Docker image** – giữ image nhẹ (<1.5GB), model mount động từ Azure.
- **KHÔNG để logic sửa lỗi JSON trong pipeline chính** – sửa cứng file hoặc viết tiền xử lý riêng.

## Lệnh và Cấu hình cụ thể đã dùng

### Đăng ký model (thay vì data)

```bash
az ml model create --name yolo-detector --version 1 --path ./config/outputs/best.pt --type custom_model
az ml model create --name jersey-color --version 1 --path ./config/outputs/jersey_color_model.pth --type custom_model
az ml model create --name jersey-visibility --version 1 --path ./config/outputs/jersey_visibility_model.pth --type custom_model
```

### File `requirements-serving.txt` (chuẩn, dùng `--extra-index-url`)

```text
--extra-index-url https://download.pytorch.org/whl/cpu
torch==2.2.2+cpu
torchvision==0.17.2+cpu
ultralytics==8.3.189
opencv-python-headless
pillow
pyyaml
numpy
azureml-inference-server-http
```

### Dockerfile hoàn chỉnh (dùng file requirements)

```dockerfile
# Sử dụng base image tối giản
FROM python:3.10-slim

# Cấu hình Python
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /var/azureml-app

# Cài đặt thư viện hệ thống cần thiết (libgomp1 cho PyTorch/OpenCV)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgomp1 \
    && rm -rf /var/lib/apt/lists/*

# Cập nhật pip
RUN pip install --no-cache-dir --upgrade pip

# Sao chép requirements và cài đặt
COPY requirements-serving.txt .
RUN pip install --no-cache-dir -r requirements-serving.txt

# Sao chép mã nguồn
COPY inference_core.py .
COPY online/ ./online/
COPY batch/ ./batch/

# Mở cổng mặc định của Azure ML Inference Server
EXPOSE 31311

# KHÔNG định nghĩa CMD/ENTRYPOINT – Azure sẽ tự động chèn lệnh runtime
```

### Mã nguồn `inference_core.py` (tóm tắt các lớp, giữ nguyên logic)

```python
import cv2
import torch
import torch.nn as nn
from torchvision import models, transforms
from PIL import Image
from pathlib import Path

device = torch.device('cpu')

preprocess = transforms.Compose([
    transforms.Resize(256, antialias=True),
    transforms.CenterCrop(224),
    transforms.ToTensor(),
    transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]),
])

class JerseyClassifier:
    """Trình phân loại màu áo và độ hiển thị số."""
    def __init__(self, color_model_path, visibility_model_path):
        self.device = device
        self.color_model = None
        self.color_classes = []
        self.visibility_model = None
        self.visibility_classes = []

        if color_model_path and Path(color_model_path).exists():
            color_checkpoint = torch.load(color_model_path, map_location=self.device)
            self.color_classes = color_checkpoint['class_names']
            self.color_model = models.resnet50(pretrained=False)
            self.color_model.fc = nn.Linear(self.color_model.fc.in_features, len(self.color_classes))
            self.color_model.load_state_dict(color_checkpoint['model_state_dict'])
            self.color_model.to(self.device)
            self.color_model.eval()

        if visibility_model_path and Path(visibility_model_path).exists():
            vis_checkpoint = torch.load(visibility_model_path, map_location=self.device)
            self.visibility_classes = vis_checkpoint['class_names']
            self.visibility_model = models.resnet50(pretrained=False)
            self.visibility_model.fc = nn.Linear(self.visibility_model.fc.in_features, len(self.visibility_classes))
            self.visibility_model.load_state_dict(vis_checkpoint['model_state_dict'])
            self.visibility_model.to(self.device)
            self.visibility_model.eval()

    def classify_batch(self, crop_images):
        """Phân loại batch các crop."""
        # (giữ nguyên logic xử lý batch)
        pass

def box_iou(boxA, boxB):
    """Tính IoU giữa hai bounding box."""
    # (giữ nguyên logic)
    pass
```

### Mã nguồn `online/score.py`

```python
import os
import json
import base64
import numpy as np
import cv2
from ultralytics import YOLO
from inference_core import JerseyClassifier

detector = None
classifier = None

def init():
    global detector, classifier
    model_dir = os.getenv("AZUREML_MODEL_DIR")
    yolo_path = os.path.join(model_dir, "yolo-detector", "best.pt")
    color_path = os.path.join(model_dir, "jersey-color", "jersey_color_model.pth")
    vis_path = os.path.join(model_dir, "jersey-visibility", "jersey_visibility_model.pth")
    detector = YOLO(yolo_path)
    classifier = JerseyClassifier(color_model_path=color_path, visibility_model_path=vis_path)

def run(raw_data):
    try:
        data = json.loads(raw_data)
        img_bytes = base64.b64decode(data["image"])
        np_arr = np.frombuffer(img_bytes, np.uint8)
        frame = cv2.imdecode(np_arr, cv2.IMREAD_COLOR)
        if frame is None:
            return {"error": "Invalid image payload"}
        # Thực hiện detection và classification, trả về JSON
        # ...
        return {"status": "success", "detections": []}
    except Exception as e:
        return {"error": str(e)}
```

### Mã nguồn `batch/score.py`

```python
import os
import cv2
import json
from ultralytics import YOLO
from inference_core import JerseyClassifier, box_iou

detector = None
classifier = None

def init():
    global detector, classifier
    model_dir = os.getenv("AZUREML_MODEL_DIR")
    yolo_path = os.path.join(model_dir, "yolo-detector", "best.pt")
    color_path = os.path.join(model_dir, "jersey-color", "jersey_color_model.pth")
    vis_path = os.path.join(model_dir, "jersey-visibility", "jersey_visibility_model.pth")
    detector = YOLO(yolo_path)
    classifier = JerseyClassifier(color_model_path=color_path, visibility_model_path=vis_path)

def run(mini_batch):
    batch_results = []
    for video_path in mini_batch:
        # Reset state cho mỗi video
        tracked_detections = {}
        next_detection_id = 0
        video_output = {"video": os.path.basename(video_path), "frames": []}
        cap = cv2.VideoCapture(video_path)
        if not cap.isOpened():
            batch_results.append({"video": video_path, "error": "Could not open video"})
            continue
        frame_count = 0
        while True:
            ret, orig_frame = cap.read()
            if not ret: break
            frame_count += 1
            # Xử lý frame (có skip frame)
            # ...
        cap.release()
        batch_results.append(video_output)
    return batch_results
```

## Lỗi gặp phải và Cách khắc phục

| Lỗi / Vấn đề | Cách khắc phục |
|--------------|----------------|
| `train_detection(!).py` – tên file chứa ký tự đặc biệt, script gọi sai | Đổi tên thành `train_detection.py` và sửa lại `train_detection.sh`. |
| `requirements.txt` pin torch nightly CUDA, không dùng được trên CPU | Tạo `requirements-serving.txt` riêng với `torch==2.2.2+cpu` và `--extra-index-url`. |
| `dummy_clip_1.json` bị trailing comma, gây lỗi `json.load()` | Sửa cứng file hoặc viết hàm tiền xử lý (regex) – không đưa logic sửa lỗi vào pipeline chính. |
| Global variables và state không reset gây rò rỉ giữa các video trong batch | Reset `tracked_detections` và `next_detection_id` trong vòng lặp xử lý từng video. |
| Sử dụng `az ml data create` cho checkpoint không mount vào `AZUREML_MODEL_DIR` | Dùng `az ml model create --type custom_model`. |
| `--index-url` trong pip khiến không tìm thấy ultralytics, opencv, pyyaml | Đổi sang `--extra-index-url` và tách riêng hoặc dùng file requirements như trên. |
| Container treo do `cv2.imshow()` | Loại bỏ GUI, không gọi `play_video()` trong các script serving. |

## Lộ trình chi tiết (Sprint 1 tuần)

| Ngày | Công việc | Mục tiêu / Chỉ tiêu hoàn thành |
|------|-----------|--------------------------------|
| **Thứ 2** | – Viết `requirements-serving.txt` riêng cho CPU.<br>– Đổi tên `train_detection(!).py` → `train_detection.py` và sửa script.<br>– Đặt 3 checkpoint vào `config/outputs/`.<br>– Test load 3 model local (script đơn giản). | Hoàn thiện môi trường serving, xác nhận load được state_dict. |
| **Thứ 3** | – Tách `inference.py` thành `inference_core.py` + `online/score.py` + `batch/score.py`.<br>– Viết `online/score.py` nhận base64 image, không tracking.<br>– Viết `batch/score.py` nhận danh sách video, có tracking, reset state cho mỗi video. | Có 3 file riêng biệt, logic core không phụ thuộc GUI, không dùng global variable lỏng lẻo. |
| **Thứ 4** | – Build Docker image (Dockerfile dùng `requirements-serving.txt`).<br>– Push image lên ACR.<br>– Đăng ký 3 model lên Azure ML dưới dạng Model asset (`az ml model create`). | Image sẵn sàng, model đã đăng ký đúng cách. |
| **Thứ 5** | – Deploy **Online Endpoint** (CPU instance nhỏ nhất).<br>– Trích xuất 1 frame từ video làm test, gọi REST API, xác nhận kết quả (bbox + color + visibility). | Online Endpoint hoạt động, trả về JSON đúng. |
| **Thứ 6** | – Deploy **Batch Endpoint** (cả clip).<br>– Upload `dummy_clip_1.mp4` lên Blob.<br>– Chạy batch job, kiểm tra output JSON được ghi vào Storage. | Batch Endpoint xử lý video, output đúng vị trí. |
| **Thứ 7** | – Fix lỗi JSON trong `dummy_clip_1.json`.<br>– Viết `validate_and_register.py` (CommandJob) tính recall/accuracy trên 50 frame.<br>– MLflow log metrics, register model nếu đạt ngưỡng.<br>– Thiết lập GitHub Actions workflow: `on: push` (chạy validation job, nếu pass thì update cả online và batch endpoint). | Hoàn thiện CI/CD, tự động cập nhật endpoint khi code/model pass validation. |

## Khái niệm & Định nghĩa

**Azure ML Inference Server (`azureml-inference-server-http`):**
- Là một HTTP server do Azure cung cấp, được tích hợp sẵn trong Managed Endpoint.
- Yêu cầu file `score.py` có hai hàm: `init()` (khởi tạo state) và `run()` (xử lý request).
- Tự động quản lý routing, telemetry (Application Insights), và hỗ trợ cả Online lẫn Batch Endpoint.
- **Ví dụ:** Khi triển khai, Azure sẽ chạy lệnh: `azmlinfsrv --entry_script online/score.py --port 31311` – không cần viết thêm `if __name__ == "__main__"`.

**Phân biệt Data Asset vs Model Asset trong Azure ML:**
- **Data Asset:** Dùng để lưu dữ liệu (tập tin, thư mục) cho các job huấn luyện hoặc xử lý.
- **Model Asset:** Được thiết kế cho checkpoint model, khi mount vào endpoint sẽ xuất hiện trong `AZUREML_MODEL_DIR` với tên đã đăng ký. **Phải dùng Model Asset để serving.**

**Extra-index-url trong pip:**
- Khi cài đặt các gói PyTorch, nên dùng `--extra-index-url https://download.pytorch.org/whl/cpu` thay vì `--index-url`.
- `--index-url` sẽ chỉ tìm kiếm trong kho đó, bỏ qua PyPI, khiến các gói như `ultralytics`, `opencv-python-headless` không tìm thấy.
- `--extra-index-url` cho phép pip tìm trong kho phụ trước, nhưng vẫn fallback về PyPI.

## Các phương án đã cân nhắc

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
|-----------|---------|------------|------------|
| Dùng FastAPI + Uvicorn để tự viết REST API | Quen thuộc với backend dev, linh hoạt | Không tương thích với Batch Endpoint; mất tích hợp telemetry; phải tự quản lý concurrency, health check, etc. | **KHÔNG** – vì vi phạm kiến trúc Azure ML. |
| Đóng gói model vào Docker image | Đơn giản, không cần mount động | Image lớn, khó scale; khi model cập nhật phải rebuild image | **KHÔNG** – ưu tiên image nhẹ, mount model từ Azure. |
| Sử dụng Data Asset để đăng ký checkpoint | Dễ dùng với CLI `az ml data create` | Không mount vào `AZUREML_MODEL_DIR`, không dùng được cho serving | **KHÔNG** – bắt buộc dùng Model Asset. |
| Dùng một script score.py cho cả online và batch | Ít file hơn | Không thể vì online cần xử lý từng frame, batch cần tracking và reset state | **KHÔNG** – tách thành hai script riêng. |
| Dùng `--index-url` cho PyTorch trong requirements | Ngắn gọn | Gây lỗi không tìm thấy các gói khác (ultralytics, opencv) | **KHÔNG** – dùng `--extra-index-url`. |
| Áp dụng lượng tử hóa (INT8/ONNX) để giảm tải CPU | Giảm latency, tăng throughput | Chưa có trong phạm vi sprint hiện tại; có thể cân nhắc sau | **CHƯA CHỌN** – đề xuất cho tương lai. |
