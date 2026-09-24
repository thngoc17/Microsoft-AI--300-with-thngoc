---
source_url: "https://gemini.google.com/app/558af373010cf330"
conversation_date: "2026-08-19"
context_week: "N/A"
conversation_types: [FIX_CODE, TRANH_LUAN_QUYET_DINH]
ai300_domains: ["Tối ưu hóa hiệu suất mô hình"]
technologies: [YOLO, ONNX, ONNX Runtime, Ultralytics, PyTorch, OpenMP]
key_decision: "Hủy bỏ hoàn toàn phương án lượng tử hóa INT8 tĩnh (PTSQ) cho mô hình YOLO trên CPU x86 do mAP tụt về 0 và tốc độ tăng không đáng kể, chuyển sang xuất trực tiếp mô hình FP32 với đầu vào 640x640."
status: resolved
---

## Bối cảnh & Vấn đề

*   **Mục tiêu ban đầu:** Tối ưu hóa mô hình YOLO bằng phương pháp lượng tử hóa tĩnh (Post-Training Static Quantization - PTSQ) sang định dạng INT8 để giảm kích thước và tăng tốc độ suy luận trên CPU.
*   **Yêu cầu kỹ thuật:** Đầu vào của mô hình phải là 640x640. Cần có chỉ số mAP trước và sau khi lượng tử hóa để đánh giá hiệu quả.
*   **Thách thức:** Lượng tử hóa toàn phần thường gây ra hiện tượng bão hòa (saturation) ở các lớp hồi quy hộp giới hạn (bounding box regression heads) của YOLO, dẫn đến mô hình trả về kết quả rỗng (zero detections) hoặc mAP suy giảm nghiêm trọng.

## Quyết định cuối cùng & Lý do

*   **Quyết định cuối cùng (CHỐT):** LOẠI BỎ HOÀN TOÀN quy trình lượng tử hóa INT8. Chỉ giữ lại pipeline xuất mô hình ONNX FP32 với kích thước đầu vào cố định 640x640.
*   **Lý do:**
    *   **Suy giảm hiệu suất:** Mô hình INT8 bị phá hủy hoàn toàn về mặt chất lượng, mAP tụt từ 0.4244 xuống 0.0000. Điều này chứng tỏ việc ép các giá trị tọa độ hồi quy vào khoảng INT8 (-128 đến 127) đã làm mất hoàn toàn thông tin.
    *   **Gia tốc không đáng kể:** Trên CPU AMD Ryzen 5 6600H, tốc độ chỉ tăng từ 429ms lên 285ms (tương đương speedup 1.5x), thấp hơn nhiều so với kỳ vọng (1.8x-2.5x).
    *   **Hiệu quả thực tế thấp:** Với tốc độ ~3.5 FPS, mô hình INT8 vẫn không đáp ứng được yêu cầu xử lý theo thời gian thực (real-time) cho bài toán tracking bóng đá.
    *   **Hạn chế phần cứng:** CPU x86 không tối ưu các tập lệnh VNNI/AVX-512 cho INT8 như trên ONNX Runtime, gây ra overhead bởi các node QDQ (Quantize/Dequantize).

**Các phương án đã LOẠI BỎ:**
*   **KHÔNG dùng Lượng tử hóa tĩnh toàn phần (Full PTSQ)** vì mAP tụt về 0.
*   **KHÔNG dùng Lượng tử hóa Động (Dynamic Quantization)** vì mức tăng tốc dự kiến thấp hơn và vẫn có thể gây ảnh hưởng đến độ chính xác.
*   **KHÔNG dùng Lượng tử hóa Bán phần (Partial Quantization)** vì quá phức tạp để triển khai và quản lý đồ thị ONNX so với lợi ích mang lại trên nền tảng CPU này.

## Lệnh và Cấu hình cụ thể đã dùng

### Mã nguồn Pipeline xuất ONNX FP32 cuối cùng

```python
import os

# ----------------------------------------------------------------------
# 0. KERNEL & THREADING OVERRIDES (Bắt buộc để tránh lỗi OMP)
# ----------------------------------------------------------------------
os.environ['KMP_DUPLICATE_LIB_OK'] = 'TRUE'
os.environ['OMP_NUM_THREADS'] = '1'

import time
import yaml
import logging
from pathlib import Path
import numpy as np
import cv2
import onnxruntime as ort
import tempfile
from ultralytics import YOLO

# ----------------------------------------------------------------------
# 1. LOGGING INFRASTRUCTURE
# ----------------------------------------------------------------------
def setup_logger(log_dir):
    """
    Initializes a standardized logging mechanism for the detection deployment pipeline.
    """
    log_dir = Path(log_dir)
    log_dir.mkdir(parents=True, exist_ok=True)
    logger = logging.getLogger("DetectionExportPipeline")
    logger.setLevel(logging.INFO)
    formatter = logging.Formatter('%(asctime)s [%(levelname)s] - %(message)s', datefmt='%Y-%m-%d %H:%M:%S')
    fh = logging.FileHandler(log_dir / 'detection_export_benchmark.log', encoding='utf-8')
    fh.setFormatter(formatter)
    ch = logging.StreamHandler()
    ch.setFormatter(formatter)
    if not logger.handlers:
        logger.addHandler(fh)
        logger.addHandler(ch)
    return logger

# ----------------------------------------------------------------------
# 2. YOLO EVALUATION MODULE
# ----------------------------------------------------------------------
def evaluate_model_map(model_path, data_yaml, logger, imgsz=640):
    """
    Executes a validation pass to compute mAP50-95.
    Includes absolute path injection to bypass Ultralytics' fragile relative path resolution.
    """
    logger.info(f"Evaluating mAP for: {Path(model_path).name} (Resolution: {imgsz}x{imgsz})")
    try:
        # 1. Path Injection: Read original YAML and force absolute paths
        with open(data_yaml, 'r', encoding='utf-8') as f:
            yaml_data = yaml.safe_load(f)
        yaml_dir = Path(data_yaml).parent.resolve()
        yaml_data['path'] = str(yaml_dir)

        # 2. Create a temporary YAML manifest for evaluation
        with tempfile.NamedTemporaryFile(mode='w', suffix='.yaml', delete=False, encoding='utf-8') as tmp_yaml:
            yaml.dump(yaml_data, tmp_yaml)
            tmp_yaml_path = tmp_yaml.name

        # 3. Execution
        model = YOLO(str(model_path), task='detect')
        results = model.val(data=tmp_yaml_path, imgsz=imgsz, split='val', device='cpu', verbose=False)

        # Cleanup temporary manifest
        os.remove(tmp_yaml_path)

        # 4. Failsafe checks
        if results is None or not hasattr(results, 'box') or results.box is None:
            logger.error(f"Validation failed or returned empty detections for {model_path}. Model may be corrupted.")
            return 0.0

        map_50_95 = results.box.map
        logger.info(f" -> Resulting mAP50-95: {map_50_95:.4f}")
        return map_50_95

    except Exception as e:
        logger.error(f"Critical error during mAP evaluation of {model_path}: {e}")
        return 0.0

# ----------------------------------------------------------------------
# 3. BENCHMARKING ENGINE
# ----------------------------------------------------------------------
def create_ort_session(model_path, num_threads=2):
    """
    Configures the ONNX Runtime execution session.
    """
    sess_options = ort.SessionOptions()
    sess_options.intra_op_num_threads = num_threads
    sess_options.inter_op_num_threads = 1
    sess_options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    session = ort.InferenceSession(model_path, sess_options, providers=['CPUExecutionProvider'])
    return session

def benchmark_latency(model_path, logger, imgsz=640, num_threads=2, iterations=50):
    """
    Executes a pure compute latency benchmark isolated from disk I/O variables.
    """
    session = create_ort_session(model_path, num_threads)
    input_name = session.get_inputs()[0].name
    dummy_input = {input_name: np.random.randn(1, 3, imgsz, imgsz).astype(np.float32)}
    latencies = []

    logger.info(f"Benchmarking Graph: {os.path.basename(model_path)} (Resolution: {imgsz}x{imgsz}, Threads: {num_threads})")
    # Warm-up phase
    for _ in range(10):
        session.run(None, dummy_input)

    # Benchmark phase
    for _ in range(iterations):
        start_time = time.perf_counter()
        session.run(None, dummy_input)
        latencies.append((time.perf_counter() - start_time) * 1000)

    avg_latency = np.mean(latencies)
    p95_latency = np.percentile(latencies, 95)
    logger.info(f" -> Mean Latency: {avg_latency:.2f} ms | P95 Latency: {p95_latency:.2f} ms")
    return avg_latency

# ----------------------------------------------------------------------
# 4. PIPELINE ORCHESTRATION
# ----------------------------------------------------------------------
def main():
    current_dir = Path(__file__).parent
    root_dir = current_dir.parent.parent
    config_dir = root_dir / "config"
    models_dir = config_dir / "models"
    logs_dir = current_dir / "logs"
    logger = setup_logger(logs_dir)

    logger.info("========== INITIALIZING YOLO DETECTION EXPORT PIPELINE ===========")
    try:
        models_dir.mkdir(parents=True, exist_ok=True)

        # Cấu hình cứng: Ép đầu vào về 640x640
        imgsz = 640
        dataset_yaml = root_dir / "data" / "detection_dataset" / "dataset.yaml"
        pt_weights = models_dir / "best.pt"
        if not pt_weights.exists():
            pt_weights = models_dir / "jersey_detection_model.pt"
        if not pt_weights.exists():
            raise FileNotFoundError(f"Trained YOLO weights missing in unified directory: {models_dir}")

        onnx_fp32 = models_dir / "yolo_detection_fp32.onnx"

        # 1. Export
        logger.info(f"Phase 1: Exporting PyTorch graph to ONNX FP32... ({pt_weights})")
        model = YOLO(str(pt_weights))
        exported_path = model.export(format='onnx', imgsz=imgsz, dynamic=False, simplify=True)
        os.rename(exported_path, onnx_fp32)
        logger.info(f"FP32 Export complete: {onnx_fp32}")

        # 2. Evaluate mAP
        logger.info("Phase 2: Validating Architecture Integrity...")
        map_fp32 = evaluate_model_map(onnx_fp32, dataset_yaml, logger, imgsz=imgsz)

        # 3. Benchmark Latency
        logger.info("Phase 3: Executing Resource Benchmarking...")
        lat_fp32 = benchmark_latency(str(onnx_fp32), logger, imgsz=imgsz, num_threads=2)
        fp32_size = os.path.getsize(onnx_fp32) / (1024 * 1024)

        # 4. Report
        logger.info("========== EXPORT & PROFILING SUMMARY ===========")
        logger.info(f"Model Path: {onnx_fp32.name}")
        logger.info(f"Input Resolution: {imgsz}x{imgsz}")
        logger.info(f"Memory Footprint: {fp32_size:.2f} MB")
        logger.info(f"Mean Latency: {lat_fp32:.2f} ms")
        logger.info(f"mAP (50-95): {map_fp32:.4f}")
        logger.info("==============================================")

    except Exception as e:
        logger.error(f"Critical execution failure: {e}", exc_info=True)

if __name__ == "__main__":
    main()
```

## Lỗi gặp phải và Cách khắc phục

### Lỗi Dataset path không tìm thấy
*   **Lỗi:** `Dataset 'E://PyCharm\YOLO_football_for_github\a-core/data/detection_dataset/dataset.yaml' images not found, missing path` và `Dataset '...\src\trainer\images\val' images not found`.
*   **Nguyên nhân:** Ultralytics sử dụng `path: .` trong file `dataset.yaml`, và dấu `.` được hiểu là **Current Working Directory (CWD)** của tiến trình (thư mục `src/trainer`) chứ không phải thư mục chứa file YAML (`data/detection_dataset`).
*   **Giải pháp:** **Absolute Path Injection**. Hàm `evaluate_model_map` tự động đọc file YAML gốc, tạo một file tạm thời với khóa `path` được ép thành đường dẫn tuyệt đối (`yaml_data['path'] = str(yaml_dir)`), sau đó đưa file tạm này vào `model.val()`.

### Lỗi xung đột thư viện OpenMP (OMP Error #15)
*   **Lỗi:** `OMP: Error #15: Initializing libomp.dll, but found libiomp5md.dll already initialized.`
*   **Nguyên nhân:** Xung đột DLL giữa OpenMP của PyTorch (`libiomp5md.dll`) và OpenMP của ONNX Runtime (`libomp.dll`) khi cả hai cùng được load trong một tiến trình.
*   **Giải pháp:** Chèn các biến môi trường ngay ở đầu script, trước khi import bất kỳ thư viện ML nào:
    ```python
    os.environ['KMP_DUPLICATE_LIB_OK'] = 'TRUE'  # Cho phép bỏ qua lỗi
    os.environ['OMP_NUM_THREADS'] = '1'          # Giới hạn OpenMP toàn cục để tránh quá tải
    ```

### Kích thước đầu vào không đúng yêu cầu (1280x1280)
*   **Lỗi:** Log hiển thị `(Resolution: 1280x1280)` mặc dù yêu cầu là `640x640`.
*   **Nguyên nhân:** Biến `imgsz` vẫn bị ghi đè bởi giá trị đọc từ file `train_detection.yaml` (`imgsz = det_config.get('training', {}).get('imgsz', 640)`).
*   **Giải pháp:** **Hard-code trực tiếp biến `imgsz`** trong hàm `main()` để chặn mọi sự rò rỉ cấu hình từ file YAML. Thay thế dòng đọc YAML bằng `imgsz = 640`.

## Các phương án đã cân nhắc (Bảng tóm tắt)

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
| :--- | :--- | :--- | :--- |
| **Lượng tử hóa tĩnh toàn phần (Full PTSQ)** | Giảm kích thước ~70%, tăng tốc lý thuyết 1.8-2.5x | mAP tụt từ 0.42 xuống 0.0, chỉ đạt speedup 1.5x trên CPU hiện tại | **KHÔNG** |
| **Lượng tử hóa động (Dynamic Quantization)** | Dễ thực hiện, không cần dữ liệu calibration, ít ảnh hưởng đến mAP hơn | Tốc độ cải thiện thấp hơn so với static | **KHÔNG** |
| **Lượng tử hóa bán phần (Partial Quantization)** | Giữ được độ chính xác các lớp nhạy cảm (Detect Head) | Cực kỳ phức tạp, yêu cầu can thiệp sâu vào đồ thị ONNX | **KHÔNG** |
| **Chuyển sang OpenVINO** | Tối ưu cao cho CPU x86, xử lý tốt các lớp nhạy cảm của YOLO | Yêu cầu thay đổi stack công nghệ | **CHƯA ĐÁNH GIÁ** |
| **Export ONNX FP32 (Giữ nguyên)** | Mô hình chính xác 100%, dễ dàng triển khai, ít phụ thuộc | Kích thước lớn, tốc độ chậm hơn so với INT8 lý tưởng | **ĐƯỢC CHỌN** |

