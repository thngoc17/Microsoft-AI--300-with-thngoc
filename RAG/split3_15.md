---
source_url: https://gemini.google.com/app/0232f2afcc1b250d
conversation_date: 2020-01-01
context_week: N/A
conversation_types: [TRANH_LUAN_QUYET_DINH, FIX_CODE, LY_THUYET, LAP_KE_HOACH]
ai300_domains: [Optimize generative AI systems and model performance, Design and implement MLOps infrastructure]
technologies: [Azure, ONNX, OpenVINO, PyTorch, YOLO, ResNet50, OpenCV, NumPy, ThreadPoolExecutor, Azure Blob Storage, Vercel, Canvas API]
key_decision: "Quyết định dời toàn bộ bước xử lý letterbox (resize + padding) từ server CPU sang client-side Canvas API, buộc client gửi kèm metadata scale/pad để server chỉ tập trung vào inference, cắt giảm tải CPU và loại bỏ nút thắt pre-processing."
status: resolved
---

## Bối cảnh & Vấn đề

- Hệ thống AI-core xử lý ảnh trên Azure đang có thời gian xử lý (end-to-end) lên tới 44 giây, quá chậm cho một hệ thống tracking real-time.
- User nhầm tưởng nguyên nhân là do độ trễ mạng (network latency) của Azure lên tới hàng chục nghìn ms. Tuy nhiên, sau phản biện, nguyên nhân thực tế được xác định là do:
  - **Payload quá lớn**: Gửi ảnh dạng Base64 qua JSON, làm tăng kích thước và thời gian truyền.
  - **Cấu hình máy ảo yếu**: `Standard_F2s_v2` chỉ có 2 vCPU và 4GB RAM.
  - **Pipeline AI đơn luồng, tuần tự**: Xử lý YOLO → ResNet50 (màu) → ResNet50 (visibility) lần lượt.
  - **ResNet50 quá nặng**: 25 triệu tham số, chạy trên CPU không hiệu quả.
  - **Pre-processing (resize, padding) trên server tốn CPU**: Đặc biệt khi ảnh đầu vào có kích thước lớn.
- Ngoài ra, thời gian hiển thị trên frontend (`Total Latency`) là thời gian bao gồm cả network + compute, không chỉ riêng network.

## Quyết định cuối cùng & Lý do

1.  **Quyết định 1: Tái cấu trúc pipeline AI.**
    - **Nội dung**: Chuyển toàn bộ model sang ONNX Runtime để chạy trên CPU, loại bỏ PyTorch và ultralytics khỏi serving container.
    - **Lý do**: ONNX Runtime được viết bằng C++, giải phóng GIL của Python, tối ưu instruction set x86/x64 cho CPU. Việc loại bỏ PyTorch giảm dung lượng container, tăng tốc cold-start.
    - **Phương án bị loại bỏ**: Giữ nguyên PyTorch để chạy inference vì chậm và tốn tài nguyên.

2.  **Quyết định 2: Áp dụng đa luồng Stage-based cho Stage 2.**
    - **Nội dung**: Sử dụng `ThreadPoolExecutor` (max_workers=2) để chạy song song 2 model ResNet (Color và Visibility).
    - **Lý do**: Hai model này độc lập về dữ liệu đầu vào (cùng batch crops) và không có phụ thuộc lẫn nhau, do đó có thể chạy song song. Với 2 vCPU, việc chạy song song giúp tận dụng tối đa tài nguyên.
    - **Ràng buộc**: Mỗi ResNet được cấu hình `intra_op_num_threads = 1` để tránh tạo quá nhiều sub-threads gây ra context-switching overhead trên máy ảo 2 vCPU.

3.  **Quyết định cuối cùng (Quan trọng nhất): Dời letterbox preprocessing từ Server sang Client (Canvas API).**
    - **Nội dung**: Client (app.js) sẽ thực hiện resize ảnh theo tỷ lệ và pad về kích thước chuẩn (640x640) với nền xám (114,114,114). Sau đó gửi ảnh đã xử lý lên server, kèm theo metadata là `scale` và `pad`.
    - **Lý do**: Bước `_preprocess_yolo` trên server đang tự động resize + letterbox, gây tốn CPU. Dời bước này sang client (dùng Canvas API được hardware-accelerated) giúp giảm tải CPU trên Azure.
    - **Hậu quả và cách giải quyết**:
        - Server không còn biết tỉ lệ gốc của ảnh để "gỡ" letterbox khi trả `bbox` cho client.
        - **Giải pháp**: Server phụ thuộc hoàn toàn vào `scale` và `pad` do client gửi lên. `_postprocess_yolo` sẽ tính toán 2 loại tọa độ:
            - `bbox_raw`: Tọa độ trên ảnh 640x640 (dùng để crop cho ResNet).
            - `bbox_mapped`: Tọa độ đã được "gỡ" letterbox (trả về cho client).
        - **Rủi ro**: Nếu client gửi sai metadata, server sẽ không detect đúng.
    - **Phương án bị loại bỏ**: Giữ fallback letterbox ở server để tương thích ngược. **Lý do**: Tuân thủ nguyên tắc `Fail-Fast`, tránh che giấu lỗi và lãng phí CPU.

## Lệnh và Cấu hình cụ thể đã dùng

### Cấu hình ONNX Sessions (inference.py)

```python
# STAGE 1 OPTIONS: YOLO
yolo_options = ort.SessionOptions()
yolo_options.intra_op_num_threads = 2
yolo_options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL

# STAGE 2 OPTIONS: ResNets (Strict Constraint)
resnet_options = ort.SessionOptions()
resnet_options.intra_op_num_threads = 1
resnet_options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL

# Load Sessions
self.yolo_session = ort.InferenceSession(yolo_onnx_path, yolo_options, providers=['CPUExecutionProvider'])
self.color_session = ort.InferenceSession(color_onnx_path, resnet_options, providers=['CPUExecutionProvider'])
self.vis_session = ort.InferenceSession(vis_onnx_path, resnet_options, providers=['CPUExecutionProvider'])
```

### Export Model sang ONNX

```python
# 1. Export YOLO
from ultralytics import YOLO
model = YOLO("models/best.pt")
model.export(format="onnx", dynamic=True)

# 2. Export ResNet (Color & Visibility)
import torch
import torchvision.models as models
model = models.resnet50()
model.fc = torch.nn.Linear(model.fc.in_features, num_classes)
model.load_state_dict(torch.load("models/jersey_color_model.pt")['model_state_dict'])
model.eval()
dummy_input = torch.randn(1, 3, 224, 224)
torch.onnx.export(model, dummy_input, "models/color.onnx",
                  input_names=['input'], output_names=['output'],
                  dynamic_axes={'input': {0: 'batch_size'}, 'output': {0: 'batch_size'}})
```

### Client-side Letterbox (app.js)

```javascript
function letterboxToCanvas(sourceCanvas, targetSize = 640) {
    const w = sourceCanvas.width;
    const h = sourceCanvas.height;
    const scale = targetSize / Math.max(w, h);
    const new_w = Math.round(w * scale);
    const new_h = Math.round(h * scale);
    const pad_w = targetSize - new_w;
    const pad_h = targetSize - new_h;
    const left = Math.floor(pad_w / 2);
    const top = Math.floor(pad_h / 2);

    const canvas = document.createElement('canvas');
    canvas.width = targetSize;
    canvas.height = targetSize;
    const ctx = canvas.getContext('2d');
    ctx.fillStyle = 'rgb(114, 114, 114)';
    ctx.fillRect(0, 0, targetSize, targetSize);
    ctx.drawImage(sourceCanvas, left, top, new_w, new_h);
    return {
        base64: canvas.toDataURL('image/jpeg', 0.7),
        scale: scale,
        pad: [left, top]
    };
}
```

### Server-side Preprocessing (inference.py)

```python
def _prepare_yolo_input(self, frame: np.ndarray) -> np.ndarray:
    """
    Ultra-lightweight input preparation. Bypasses resizing and padding.
    Strictly assumes the client has already formatted the letterbox (e.g., 640x640).
    """
    rgb_frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
    tensor = rgb_frame.astype(np.float32) / 255.0
    tensor = tensor.transpose((2, 0, 1))
    return np.expand_dims(tensor, axis=0)
```

### Dual Bounding Box Calculation (inference.py)

```python
def _postprocess_yolo(self, outputs: np.ndarray, scale: float, pad: Tuple[int, int], ...):
    # ...
    # 1. RAW COORDINATES (Relative to 640x640 letterbox)
    raw_x1 = int(cx - w / 2)
    raw_y1 = int(cy - h / 2)
    raw_w = int(w)
    raw_h = int(h)

    # 2. MAPPED COORDINATES (Un-letterboxed)
    map_x1 = int((raw_x1 - left) / scale)
    map_y1 = int((raw_y1 - top) / scale)
    map_w = int(w / scale)
    map_h = int(h / scale)
    # ...
```

### JSON Contract Validation (online_score.py)

```python
# CONTRACT VALIDATION: Fail-fast if metadata is missing
if not raw_b64 or scale is None or pad is None:
    error_msg = "Strict Contract Violation: Payload MUST contain 'image', 'scale', and 'pad' attributes."
    logger.error(error_msg)
    return {"status": "error", "message": error_msg}
```

## Lỗi gặp phải và Cách khắc phục

- **Lỗi 1**: Nhầm lẫn giữa `Total Request Duration` và `Network Latency`.
    - **Nguyên nhân**: Đo thời gian từ lúc gửi request đến lúc nhận response và gán nhãn là latency.
    - **Cách khắc phục**: Tách bạch metrics. Thêm `compute_ms` trong response từ server. `Total Latency = compute_ms + network_overhead`. Từ đó mới xác định đúng bottleneck.
- **Lỗi 2 (Anti-pattern)**: Gửi file ảnh Base64 qua JSON.
    - **Nguyên nhân**: Base64 làm tăng kích thước payload (~33%).
    - **Cách khắc phục (Đề xuất)**: Chuyển sang gửi `multipart/form-data` hoặc `application/octet-stream` (binary) để tối ưu upload. Tuy nhiên, quyết định cuối cùng vẫn giữ Base64 nhưng ảnh đã được resize và compress từ client.
- **Lỗi 3**: `_postprocess_yolo` dùng `bbox_mapped` để crop ảnh (sai vị trí).
    - **Nguyên nhân**: Sau khi dời letterbox sang client, `frame` trên server là ảnh đã qua padding. Nếu dùng `bbox_mapped` (tọa độ gốc) để crop sẽ lấy sai vùng.
    - **Cách khắc phục**: Tách biệt `bbox_raw` (dùng để crop trên ảnh 640x640) và `bbox_mapped` (dùng để trả về client). Đây là lỗi ngầm dễ mắc phải nhất và đã được đề cập kỹ trong phản hồi.
- **Lỗi 4 (Potential)**: Client-side letterbox có thể không khớp với Python implementation.
    - **Cách khắc phục**: Đảm bảo logic letterbox ở JS (dùng `Math.floor` cho pad) khớp hoàn toàn với Python (dùng `// 2`). Sự khác biệt vài pixel có thể ảnh hưởng đến độ chính xác của YOLO.

## Lộ trình chi tiết

1.  **Bước 1 (Research)**: Xác định đúng nguyên nhân gây chậm. (Hoàn thành)
2.  **Bước 2 (Refactor Server)**:
    - Chuyển đổi 3 model PyTorch sang ONNX.
    - Sửa `inference.py` để dùng ONNX Runtime.
    - Áp dụng ThreadPoolExecutor cho Stage 2 (ResNets).
    - Loại bỏ bước pre-processing YOLO (resize/pad) ở server.
3.  **Bước 3 (Refactor Client)**:
    - Viết hàm `letterboxToCanvas` trong `app.js`.
    - Sửa `fetchInferenceData` để gửi kèm `scale` và `pad` trong payload.
    - Cập nhật `drawBoundingBoxes` để dùng `scale` mới (thay vì tính toán lại).
4.  **Bước 4 (Enforce Contract)**:
    - Cập nhật `online_score.py` để validate `scale` và `pad` bắt buộc có trong payload. Loại bỏ fallback server-side.
5.  **Bước 5 (Test)**:
    - So sánh `compute_ms` trước và sau khi refactor.
    - Kiểm tra độ chính xác với các case player ở gần viền frame (ảnh hưởng của viền xám).

## Các phương án đã cân nhắc

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
| :--- | :--- | :--- | :--- |
| **Giữ nguyên PyTorch, tăng cấp VM** | Đơn giản, ít thay đổi code. | Tốn kém chi phí, không giải quyết được bottleneck kiến trúc (vd: pre-processing, ResNet50 nặng). | KHÔNG (vì không giải quyết triệt để và tốn kém) |
| **Dùng OpenVINO thay vì ONNX** | Tối ưu hơn cho CPU Intel. | Phức tạp hơn trong cài đặt và triển khai so với ONNX. | KHÔNG (vì ONNX đủ mạnh và đơn giản hơn) |
| **Giữ letterbox ở server nhưng dùng ONNX** | Không cần thay đổi client. | Vẫn tốn CPU cho bước resize/padding trên server, đặc biệt khi có nhiều request. | KHÔNG (vì chưa tối ưu triệt để) |
| **Dời hoàn toàn letterbox sang client** | Giảm tải CPU server đáng kể. Client dùng Canvas API (hardware-accelerated). | Phức tạp hóa logic client-server. Server phụ thuộc vào metadata từ client. Rủi ro nếu client gửi sai. | **CÓ** (đây là quyết định tối ưu nhất về hiệu năng CPU) |
| **Không dùng ResNet50 mà dùng MobileNet** | Nhẹ hơn, inference nhanh hơn. | Có thể giảm độ chính xác. | ĐÃ ĐỀ XUẤT, nhưng quyết định cuối cùng vẫn là tối ưu pipeline hơn là thay đổi kiến trúc model nếu chưa cần thiết. |
```