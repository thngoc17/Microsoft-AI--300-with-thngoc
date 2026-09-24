---
source_url: "https://gemini.google.com/app/Oea4fd310ce8cf2b"
conversation_date: "2026-08-19"
context_week: "N/A"
conversation_types: ["FIX_CODE", "FIX_HA_TANG", "TRANH_LUAN_QUYET_DINH", "LY_THUYET"]
ai300_domains: ["Optimize generative AI systems and model performance", "Model lifecycle"]
technologies: ["YOLO", "ONNX", "ONNX Runtime", "Ultralytics", "PyTorch", "OpenVINO", "Azure", "Vercel", "CI/CD"]
key_decision: "Quyết định từ bỏ lượng tử hóa INT8 toàn phần trên ONNX Runtime CPU do mAP suy giảm nghiêm trọng, chọn giải pháp đánh đổi: xuất mô hình ONNX FP32, scale về độ phân giải 960x960 để giữ cân bằng giữa mAP và hiệu năng, sau đó nâng cấp kiến trúc lên cloud với cơ chế buffer để đạt tiệm cận real-time."
status: "resolved"
---

## Bối cảnh & Vấn đề
- **Mục tiêu ban đầu**: Tối ưu hóa mô hình YOLO11n (phát hiện cầu thủ bóng đá) bằng phương pháp lượng tử hóa INT8 (Quantization) để giảm kích thước và tăng tốc độ suy luận (inference) trên CPU x86 (AMD Ryzen 5 6600H).
- **Thách thức**: Đường dẫn dữ liệu (dataset) bị sai do cơ chế phân giải tương đối (relative path) của Ultralytics, xung đột thư viện OpenMP giữa PyTorch và ONNX Runtime, và vấn đề mAP tụt về 0 sau lượng tử hóa.

## Quyết định cuối cùng & Lý do
- **Quyết định**: Loại bỏ hoàn toàn kỹ thuật lượng tử hóa (Quantization) trong pipeline hiện tại. Quay về sử dụng mô hình FP32 (Full Precision) với đầu ra ONNX.
- **Lý do**: Quá trình lượng tử hóa tĩnh (Static Quantization) đã phá hủy hoàn toàn các tầng hồi quy (Regression Heads) của YOLO, khiến mAP tụt từ 0.4244 xuống 0.0000 (bão hòa). Tốc độ tăng không đáng kể (1.5x) so với mức suy hao chất lượng. Đây là một "Architectural Trade-off" bắt buộc.
- **Phương án bị loại bỏ (Negative Knowledge)**:
    - **KHÔNG** tiếp tục tối ưu INT8 trên ONNX Runtime CPU vì gây "Integer Saturation" phá vỡ tọa độ box. Đã có cảnh báo rủi ro từ đầu: "YOLO regression heads are highly sensitive to INT8 saturation without QAT".
    - **KHÔNG** chạy ở độ phân giải 640x640 vì mAP giảm quá sâu (0.4244 -> 0.2563), mất đặc trưng vật thể nhỏ (bóng đá).
    - **KHÔNG** tiếp tục tối ưu trên local nữa, mà chuyển sang thiết kế hệ thống phân tán (Cloud) để đạt "tiệm cận real-time".

## Lệnh và Cấu hình cụ thể đã dùng

### A. Khắc phục xung đột OpenMP (DLL Collision)
*Chèn vào đầu file `yolo-export-quantize.py` trước mọi câu lệnh import.*

```python
import os

# 0. KERNEL & THREADING OVERRIDES
# Bỏ qua xung đột OpenMP giữa PyTorch (Intel MKL) và ONNX Runtime
os.environ['KMP_DUPLICATE_LIB_OK'] = 'TRUE'
# Giới hạn luồng OpenMP toàn cục để tránh Thread Thrashing do có 2 thư viện OpenMP chạy song song
os.environ['OMP_NUM_THREADS'] = '1'
```

### B. Hàm đánh giá mAP (Absolute Path Injection)
*Thay thế hàm `evaluate_model_map` để ép Ultralytics đọc đúng đường dẫn tuyệt đối.*

```python
import tempfile
import copy

def evaluate_model_map(model_path, data_yaml, logger, imgsz=640):
    logger.info(f"Evaluating mAP for: {Path(model_path).name} (Resolution: {imgsz}x{imgsz})")
    try:
        # 1. Path Injection: Ép cứng khóa 'path' thành thư mục chứa file YAML
        with open(data_yaml, 'r', encoding='utf-8') as f:
            yaml_data = yaml.safe_load(f)
        yaml_dir = Path(data_yaml).parent.resolve()
        yaml_data['path'] = str(yaml_dir)

        # 2. Tạo file YAML tạm thời để đánh giá
        with tempfile.NamedTemporaryFile(mode='w', suffix='.yaml', delete=False, encoding='utf-8') as tmp_yaml:
            yaml.dump(yaml_data, tmp_yaml)
            tmp_yaml_path = tmp_yaml.name

        # 3. Thực thi Validation
        model = YOLO(str(model_path), task='detect')
        results = model.val(data=tmp_yaml_path, imgsz=imgsz, split='val', device='cpu', verbose=False)

        # Dọn dẹp
        os.remove(tmp_yaml_path)

        if results is None or not hasattr(results, 'box') or results.box is None:
            return 0.0
        return results.box.map
    except Exception as e:
        logger.error(f"Critical error: {e}")
        return 0.0
```

### C. Pipeline xuất mô hình cuối cùng (Bỏ Lượng tử hóa)
*Định tuyến pipeline chỉ còn `Export -> Evaluate -> Benchmark`.*

```python
# Trong hàm main()
imgsz = 640  # Hoặc 960 sau khi đã test các mức scale

# 1. Export ONNX FP32 (Tắt dynamic để fix shape)
model = YOLO(str(pt_weights))
model.export(format='onnx', imgsz=imgsz, dynamic=False, simplify=True)

# 2. Đánh giá mAP
map_fp32 = evaluate_model_map(onnx_fp32, dataset_yaml, logger, imgsz=imgsz)

# 3. Benchmark Latency
def benchmark_latency(model_path, logger, imgsz=640, num_threads=2, iterations=50):
    sess_options = ort.SessionOptions()
    sess_options.intra_op_num_threads = num_threads
    session = ort.InferenceSession(model_path, sess_options, providers=['CPUExecutionProvider'])
    dummy_input = {session.get_inputs()[0].name: np.random.randn(1, 3, imgsz, imgsz).astype(np.float32)}
    # Warm-up + Đo thời gian...
```

## Lỗi gặp phải và Cách khắc phục

| Lỗi / Vấn đề | Mô tả | Cách khắc phục / Quy tắc |
| :--- | :--- | :--- |
| **Ultralytics Path Resolution** | Lỗi `Dataset '...' images not found` do Ultralytics nối đường dẫn `path: .` với `cwd` hiện tại thay vì thư mục chứa YAML. | **Fix**: Sử dụng kỹ thuật "Absolute Path Injection". Đọc file YAML, ghi đè `path` bằng đường dẫn tuyệt đối và lưu vào file tạm thời trước khi chạy `model.val()`. |
| **OMP Error #15 (DLL Collision)** | Lỗi xung đột `libomp.dll` và `libiomp5md.dll` khi chạy đồng thời PyTorch và ONNX Runtime. | **Fix**: Thiết lập biến môi trường ngay đầu file: `os.environ['KMP_DUPLICATE_LIB_OK'] = 'TRUE'` và `os.environ['OMP_NUM_THREADS'] = '1'` để kiểm soát luồng. |
| **mAP INT8 tụt về 0** | Lượng tử hóa tĩnh (Static Quantization) làm "saturation" (tràn số) tại các tầng Regression / DFL Head của YOLO. | **Fix**: **Từ bỏ** phương án INT8 trên ONNX CPU. Quay về FP32 và chỉ tập trung tối ưu phần cứng hoặc kiến trúc khác (OpenVINO). |
| **Shape Mismatch khi Inference** | Mô hình ONNX xuất ra với `dynamic=False` yêu cầu đầu vào cố định `(1, 3, 640, 640)`; ném ảnh khác size sẽ bị lỗi. | **Quy tắc**: Bắt buộc phải tiền xử lý (preprocess) bằng thuật toán **Letterbox** (padding giữ tỷ lệ) trước khi đưa vào ONNX, **KHÔNG** dùng `cv2.resize()` thông thường vì phá vỡ tỷ lệ vật thể. |

## Lộ trình chi tiết (Kiến trúc hướng tới Real-time)
*(Dựa trên quyết định chuyển sang Cloud)*

1. **Đóng gói Inference Server**: Container hóa mô hình ONNX FP32 thành API service (dự kiến gRPC/WebSocket) và deploy lên Azure.
2. **Tối ưu mạng**: Sử dụng WebRTC hoặc gRPC để giảm độ trễ khứ hồi (RTT) thay vì HTTP REST + Base64.
3. **Thiết kế Buffer**: Triển khai cơ chế **Ring Buffer (Drop-oldest)** để xử lý bất đồng bộ giữa tốc độ camera (30 FPS) và model (3.8 FPS), tránh tràn bộ nhớ.
4. **CI/CD**: Thiết lập GitHub Actions workflow tự động build và deploy lên Azure Container Instances (ACI) hoặc Azure Functions.

## Khái niệm & Định nghĩa

| Thuật ngữ | Định nghĩa | Ví dụ / Giải thích từ hội thoại |
| :--- | :--- | :--- |
| **Static Quantization** | Phương pháp lượng tử hóa (INT8) trong đó dải giá trị động (dynamic range) của weights và activations được xác định trước bằng cách chạy một tập Calibration. | Trong log, Static QAT đã làm "Saturation" ở các tầng Regression Head, dẫn đến mAP = 0.0. |
| **Letterbox (Preprocessing)** | Kỹ thuật resize ảnh về đúng kích thước đầu vào của mô hình nhưng giữ nguyên tỷ lệ khung hình (aspect ratio), phần thừa được lấp đầy bằng pixel tối màu (padding). | Bắt buộc phải dùng Letterbox cho ảnh 1920x1080 để đưa vào model 640x640, tránh làm bóng đá bị méo thành bầu dục. |
| **Absolute Path Injection** | Kỹ thuật trong lập trình để ép một thư viện (library) phải đọc một đường dẫn tuyệt đối thay vì đường dẫn tương đối mặc định. | Được sử dụng để sửa lỗi Ultralytics khi không tìm thấy thư mục `images/val` do phân giải sai đường dẫn. |
| **Iron Triangle (Tam giác sắt)** | Trong Edge AI, mối quan hệ đánh đổi (trade-off) giữa 3 yếu tố: Độ phân giải (Resolution), Tốc độ (Speed) và Độ chính xác (Accuracy). | Khi giảm resolution từ 1280 xuống 640, Speed tăng 5 lần (430ms -> 85ms) nhưng Accuracy (mAP) giảm mạnh từ 0.4244 xuống 0.2563. |

## Các phương án đã cân nhắc

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
| :--- | :--- | :--- | :--- |
| **ONNX FP32 (640x640)** | Cực nhanh (85ms), nhẹ (10MB). | mAP rất thấp (0.2563), mất dấu bóng đá. | ❌ Không |
| **ONNX FP32 (960x960)** | Cân bằng tốt (mAP 0.3484, 260ms). | Vẫn chưa đạt tốc độ real-time (<100ms). Gây gián đoạn tracking. | ❌ Không (chỉ là điểm dừng tạm thời) |
| **ONNX FP32 (1280x1280) + OpenVINO** | Giữ độ chính xác cao (mAP 0.4244). | Hiện tại chưa triển khai, cần thay đổi engine. | ⏳ Kế hoạch tương lai |
| **Lượng tử hóa INT8 (PTSQ)** | Tiết kiệm bộ nhớ, tăng tốc lý thuyết. | **Phá hủy hoàn toàn mAP (0.0000)**. | ❌ **ĐÃ LOẠI BỎ** |
| **Cloud + Buffer (3 FPS)** | Cho phép đóng dự án, đáp ứng yêu cầu tối thiểu. | Độ trễ đầu cuối (End-to-end) cao, tracking bị gãy (ID Switching). | ✅ **Chọn tạm thời cho MVP** |
| **SAHI (Slicing Aided Inference)** | Giữ tốc độ matrix nhỏ nhưng đạt accuracy cao. | Tăng overhead tính toán do chồng lấp (tiling). | ⏳ Chưa thử nghiệm |

