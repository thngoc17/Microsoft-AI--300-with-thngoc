---
source_url: https://gemini.google.com/app/3743e7d65b135054
conversation_date: Không xác định
context_week: Tuần 4-5
conversation_types: [LAP_KE_HOACH, TRANH_LUAN_QUYET_DINH, FIX_HA_TANG, FIX_CODE]
ai300_domains: [Design and implement MLOps infrastructure, Model lifecycle]
technologies: [Azure ML, YOLO, ResNet, PyTorch, Ultralytics, Docker, ACR, Batch Endpoint, Online Endpoint, GitHub Actions]
key_decision: "Đóng gói 3 checkpoint (YOLO + 2 ResNet) thành một thư mục và đăng ký dưới dạng một custom model duy nhất trên Azure ML, sử dụng AZUREML_MODEL_DIR trong score.py để tải cả ba, thay vì đăng ký riêng lẻ hoặc dùng data asset."
status: resolved
---

## Bối cảnh & Vấn đề

Hội thoại xoay quanh việc triển khai một hệ thống Model Ensemble gồm 3 mô hình:
- **YOLO11** (detection, file `best.pt`)
- **ResNet50** cho màu áo (`jersey_color_model.pth`)
- **ResNet50** cho khả năng hiển thị số áo (`jersey_visibility_model.pth`)

Các mô hình này có quan hệ chặt chẽ: YOLO cắt bounding box, hai ResNet nhận input từ box đó. Người dùng đang có kế hoạch triển khai lên Azure ML với các yêu cầu:
- Chạy trên CPU (do quota sinh viên)
- Phục vụ đồng thời cho Online Endpoint (xử lý từng ảnh) và Batch Endpoint (xử lý video)
- Tích hợp CI/CD với GitHub Actions

Trong quá trình lập kế hoạch, người dùng phát hiện một số lỗi hạ tầng và code:
- `train_detection.sh` gọi sai tên file `src/trainer/train_detection.py` trong khi file thực tế có tên `train_detection(!).py`.
- `requirements.txt` chứa `torch--=2.2.0.dev20231211+cu121` – bản nightly CUDA, không cài được trên CPU và đã bị gỡ khỏi index.
- `src/inference/inference.py` gọi `play_video()` hiển thị cửa sổ GUI (cv2.imshow) – sẽ treo/crash trong container headless.
- File `dummy_clip_1.json` có lỗi cú pháp JSON (dấu phẩy thừa ở annotation cuối, thiếu key attributes).

Người dùng đặt câu hỏi: *"Làm thế nào để mở rộng file này cho 3 models khác nhau (ngày 4)? Hay nên push lần lượt từng model 1?"*

## Quyết định cuối cùng & Lý do

**Không sử dụng cách 1:** Mở rộng file model.schema.json bằng cách khai báo mảng các đường dẫn.
- *Lý do:* Schema không hỗ trợ mảng, thuộc tính `path` chỉ chấp nhận một file hoặc một thư mục.

**Không sử dụng cách 2:** Push từng model riêng lẻ lên Azure ML Registry (3 model riêng biệt).
- *Lý do:* Ba mô hình phụ thuộc chặt chẽ (tightly coupled). Việc version riêng lẻ gây ra rủi ro lệch pha (YOLO v2 với ResNet v1), phức tạp hóa việc mount nhiều model vào cùng endpoint, và khó quản lý.

**Quyết định cuối cùng:** Đóng gói cả 3 checkpoint vào một thư mục và đăng ký dưới dạng **một model duy nhất** (type `custom_model`, path là thư mục). Azure ML sẽ tự động tải toàn bộ thư mục đó khi deploy và gán đường dẫn vào biến môi trường `AZUREML_MODEL_DIR`. Trong `score.py`, dùng `os.getenv("AZUREML_MODEL_DIR")` để xác định vị trí và load từng checkpoint.

Lý do chọn cách này:
- Đảm bảo đồng bộ version: một version của ensemble bao gồm đúng bộ 3 checkpoint đã được kiểm tra cùng nhau.
- Đơn giản hóa endpoint: chỉ cần mount một model, không cần phức tạp hóa với data_bindings.
- Dễ dàng cập nhật: CI/CD thay đổi một model asset version duy nhất.

## Lệnh và Cấu hình cụ thể đã dùng

### Tổ chức thư mục local trước khi push

```
/your_project
  /model_payload
    best.pt
    jersey_color_model.pt
    jersey_visibility_model.pt
    ensemble_model.yml
```

### File YAML đăng ký model ensemble (`ensemble_model.yml`)

```yaml
$schema: https://azuremlschemas.azureedge.net/latest/model.schema.json
name: football-tracking-ensemble
version: 1
path: ./model_payload/
type: custom_model
description: "Ensemble 3 models (YOLO11, ResNet Color, ResNet Visibility) phục vụ tracking cầu thủ bóng đá. Các mode"
```

### Lệnh đăng ký model (đúng)

```bash
az ml model create -f ensemble_model.yml
```

### Lệnh đăng ký data asset (đã bị loại bỏ – không dùng cho serving)

```bash
az ml data create --name yolo-detector-raw --version 11 --path ./config/outputs/best.pt --type uri_file
az ml data create --name jersey-color-raw --version 1 --path ./config/outputs/jersey_color_model.pt --type uri_file
```

### `requirements-inference-cpu.txt` (thay thế requirements.txt gốc)

```
torch==2.2.2+cpu --index-url https://download.pytorch.org/whl/cpu
torchvision==0.17.2+cpu --index-url https://download.pytorch.org/whl/cpu
ultralytics==8.3.189
opencv-python-headless
pillow
pyyaml
numpy
```

*Loại bỏ khỏi container:* matplotlib, seaborn, scikit-learn, tqdm (chỉ dùng cho training).

### Code trong `score.py` – hàm `init()` (sử dụng `AZUREML_MODEL_DIR`)

```python
import os
import torch
from ultralytics import YOLO

def init():
    global detector, color_classifier, vis_classifier

    model_dir = os.getenv("AZUREML_MODEL_DIR")
    # defensive: nếu file nằm trực tiếp trong model_dir
    if os.path.exists(os.path.join(model_dir, "best.pt")):
        base_path = model_dir
    else:
        # nếu Azure tạo thư mục con mang tên model
        base_path = os.path.join(model_dir, "football-tracking-ensemble")

    yolo_path = os.path.join(base_path, "best.pt")
    color_path = os.path.join(base_path, "jersey_color_model.pt")
    vis_path = os.path.join(base_path, "jersey_visibility_model.pt")

    assert os.path.exists(yolo_path), f"Không tìm thấy YOLO tại {yolo_path}"
    assert os.path.exists(color_path), f"Không tìm thấy Color model tại {color_path}"
    assert os.path.exists(vis_path), f"Không tìm thấy Visibility model tại {vis_path}"

    detector = YOLO(yolo_path)
    # Load ResNet với map_location='cpu' vì container CPU
    # color_classifier = ...
    # color_classifier.load_state_dict(torch.load(color_path, map_location=torch.device('cpu')))
    # Tương tự cho visibility
```

### Các lệnh CI/CD dự kiến (trích dẫn từ kế hoạch)

```bash
az ml job create -f job.yml --stream
az ml online-endpoint update
az ml batch-endpoint update
```

## Lỗi gặp phải và Cách khắc phục

| Lỗi / Vấn đề | Cách khắc phục |
|---|---|
| `train_detection.sh` gọi `src/trainer/train_detection.py` nhưng file thực tế tên `train_detection(!).py` | Đổi tên file thành `train_detection.py` và cập nhật script. |
| `requirements.txt` chứa `torch--=2.2.0.dev20231211+cu121` – không cài được trên CPU và đã bị gỡ khỏi index | Tạo file `requirements-inference-cpu.txt` riêng với các phiên bản CPU ổn định, chỉ giữ các gói cần cho inference. |
| `src/inference/inference.py` có gọi `play_video()` (cv2.imshow) – container headless sẽ crash | Tách logic core thành `inference_core.py`, xây dựng `score.py` cho online và batch endpoint, bỏ toàn bộ GUI. |
| `dummy_clip_1.json` có dấu phẩy thừa và thiếu key attributes trong annotation | Viết code phòng thủ khi đọc JSON, xử lý lỗi nhẹ để vẫn parse được. |
| **Thiết kế sai:** Đăng ký 3 model riêng lẻ hoặc dùng data asset cho serving | **Đã sửa:** Đóng gói tất cả vào một thư mục và đăng ký một model duy nhất (xem mục 2). |

## Lộ trình chi tiết (Sprint 1 tuần)

Dưới đây là kế hoạch ban đầu (được giữ nguyên nhưng điều chỉnh cách đăng ký model theo quyết định ở mục 2):

| Thứ | Công việc | Ghi chú |
|---|---|---|
| Thứ 2 | – Viết requirements CPU riêng<br>– Đổi tên `train_detection(!).py` → `train_detection.py`, sửa `train_detection.sh`<br>– Đặt 3 checkpoint vào `config/outputs/`<br>– Viết `requirements-inference-cpu.txt`<br>– Test load 3 checkpoint local | Không dùng Azure, test trên máy cá nhân. |
| Thứ 3 | – Tách `inference.py` thành `inference_core.py` (logic detect/classify) và hai `score.py` (online & batch)<br>– Online: nhận base64 ảnh, trả bbox + color + visibility<br>– Batch: nhận danh sách video, xử lý tuần tự, ghi JSON, không gọi `play_video()` | Giữ nguyên logic tracking trong batch. |
| Thứ 4 | – Dockerize với Dockerfile CPU, build/push lên ACR<br>– **Đẩy 3 checkpoint lên Datastore dưới dạng Model Asset (không phải Data Asset)**: dùng `az ml model create -f ensemble_model.yml` | Thay vì `az ml data create` như kế hoạch cũ. |
| Thứ 5 | – Trích 1 frame từ video test, deploy Managed Online Endpoint (Standard_DS2_v2)<br>– Gọi REST API với ảnh base64, kiểm tra response | Latency vài trăm ms – vài giây trên CPU. |
| Thứ 6 | – Upload video test lên Blob Storage, cấu hình Batch Endpoint trỏ tới `batch/score.py`<br>– Chạy batch job, kiểm tra output JSON | Đầu ra là detections theo từng frame. |
| Thứ 7 | – Fix lỗi JSON trong `dummy_clip_1.json` (dấu phẩy thừa, thiếu key)<br>– Viết `validate_and_register.py` chạy trên CommandJob: tính recall IoU và accuracy cho 17 annotation, log metrics, register model nếu đạt ngưỡng<br>– Thiết lập GitHub Actions workflow: `on: push` path score.py, inference_core.py, job.yml → chạy job → nếu pass thì update online và batch endpoint | Lưu ý: N=17 là smoke test, không phải benchmark. |

## Các phương án đã cân nhắc

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
|---|---|---|---|
| **A. Mở rộng file YAML để khai báo nhiều paths** | Đơn giản, giữ nguyên cấu trúc cũ | Schema không hỗ trợ mảng; không khả thi. | ❌ Không |
| **B. Push từng model riêng lẻ lên Registry (3 models)** | Tuân thủ tư duy model đơn lẻ, dễ dùng cho từng model độc lập | Gây lệch version (YOLO v2 với ResNet v1); phức tạp mount nhiều model vào endpoint; khó quản lý; không đảm bảo tính nhất quán của ensemble. | ❌ Không |
| **C. Đóng gói 3 checkpoint vào một thư mục, đăng ký một model duy nhất** | Đồng bộ version, dễ triển khai endpoint, đơn giản hóa CI/CD, tận dụng `AZUREML_MODEL_DIR` | Yêu cầu thay đổi cách tổ chức code và load model trong `score.py`; nhưng là cách chuẩn cho ensemble. | ✅ **Có** |

**Tiêu chí quyết định:** Tính đồng bộ version, dễ duy trì, khả năng triển khai endpoint không phức tạp, và phù hợp với thực tế các mô hình có quan hệ chặt chẽ.
