---
source_url: https://gemini.google.com/app/00568e340cf4778d
conversation_date: 2026-08-18
context_week: N/A
conversation_types: [TRANH_LUAN_QUYET_DINH, FIX_CODE, LY_THUYET]
ai300_domains: ["Tối ưu hóa hệ thống AI và hiệu suất mô hình", "Vòng đời mô hình"]
technologies: [ONNX, PyTorch, ONNX Runtime, Static Quantization, Dynamic Quantization, INT8, VNNI, Azure F2s_v2, Skylake]
key_decision: "Bỏ hoàn toàn Unstructured Pruning vì không cải thiện tốc độ trên CPU, tập trung vào Static Quantization (INT8) với pre-processing và cấu hình thread để tối ưu latency."
status: resolved
---

## Bối cảnh & Vấn đề

Hội thoại tập trung vào việc tối ưu hóa mô hình phân loại màu áo (Jersey Color) và hiển thị (Visibility) để triển khai trên môi trường CPU tài nguyên thấp (Azure F2s_v2 - 2 vCPU). Yêu cầu ban đầu là xuất mô hình PyTorch sang ONNX và lượng tử hóa (quantization), sau đó được mở rộng với yêu cầu cắt tia (pruning) để tăng tốc inference.

Tuy nhiên, các feedback chỉ ra rằng:
- Unstructured Pruning (cắt tia phi cấu trúc) trong PyTorch **không làm giảm FLOPs** trên ONNX Runtime vì không có sparse kernel cho CPU.
- Việc kết hợp `optimize_model=True` trong `quantize_static()` đã bị deprecated và gây lỗi.
- Cần benchmark thực tế để đo lường trade-off giữa accuracy và latency thay vì giả định.

## Quyết định cuối cùng & Lý do

- **Loại bỏ hoàn toàn Unstructured Pruning**: Không mang lại lợi ích về tốc độ, chỉ tăng thời gian huấn luyện và rủi ro giảm accuracy.
- **Tập trung vào Static Quantization (QDQ)**: Đây là đóng góp chính cho tốc độ (có thể tăng 2-4x) với mức độ mất accuracy cho phép.
- **Thực hiện pre-processing riêng biệt**: Sử dụng `quant_pre_process()` trước khi lượng tử hóa để tối ưu đồ thị (fuse Conv+BN,...) và tránh lỗi API.
- **Cấu hình thread cứng**: Ép `intra_op_num_threads=1` cho mỗi model để tránh oversubscription trên VM 2 vCPU và giảm context-switch overhead.
- **Bật `reduce_range=True`**: Bắt buộc cho CPU cũ (Skylake) không hỗ trợ VNNI để tránh lỗi tràn số INT8.

**Các phương án bị loại bỏ:**
- KHÔNG dùng Unstructured Pruning vì nó chỉ zero-mask, không thay đổi shape tensor, không giảm FLOPs trên ONNX Runtime CPU.
- KHÔNG dùng `optimize_model=True` trong `quantize_static()` vì API đã deprecated; thay vào đó dùng `quant_pre_process()`.
- KHÔNG dùng `per_channel=True` mặc định vì có thể giảm throughput; cần benchmark để quyết định (script giữ `False` để tối ưu tốc độ).
- KHÔNG sử dụng số thread mặc định của ONNX Runtime vì có thể gây CPU thrashing.

## Lệnh và Cấu hình cụ thể đã dùng

**File hoàn chỉnh: `multi_export_quantize.py`**
```python
import os
import time
import torch
import torch.nn as nn
from torchvision import models, transforms
from torch.utils.data import DataLoader, Dataset
import onnx
import onnxruntime as ort
from onnxruntime.quantization import quantize_static, CalibrationDataReader, QuantType, QuantFormat
from onnxruntime.quantization.shape_inference import quant_pre_process
from PIL import Image
import yaml
import logging
from pathlib import Path
import numpy as np

# 1. LOGGING & UTILITIES
def setup_logger(log_dir):
    log_dir = Path(log_dir)
    log_dir.mkdir(parents=True, exist_ok=True)
    logger = logging.getLogger("MultiDeployPipeline")
    logger.setLevel(logging.INFO)
    formatter = logging.Formatter('%(asctime)s [%(levelname)s] - %(message)s', datefmt='%Y-%m-%d %H:%M:%S')
    fh = logging.FileHandler(log_dir / 'multi_export_benchmark.log', encoding='utf-8')  # FIX: encoding cho Windows
    fh.setFormatter(formatter)
    ch = logging.StreamHandler()
    ch.setFormatter(formatter)
    logger.addHandler(fh)
    logger.addHandler(ch)
    return logger

def load_config(config_path):
    with open(config_path, 'r', encoding='utf-8') as f:
        return yaml.safe_load(f)

# 2. DATASET & TRANSFORMS (Dung chung cho cả 2 model)
class GenericJerseyDataset(Dataset):
    def __init__(self, data_dir, split='train', transform=None):
        self.data_dir = os.path.join(data_dir, split)
        self.transform = transform
        self.classes = sorted([d for d in os.listdir(self.data_dir)
                               if os.path.isdir(os.path.join(self.data_dir, d))])
        self.class_to_idx = {cls_name: idx for idx, cls_name in enumerate(self.classes)}
        self.samples = []
        for class_name in self.classes:
            class_dir = os.path.join(self.data_dir, class_name)
            for img_name in os.listdir(class_dir):
                if img_name.lower().endswith(('.png', '.jpg', '.jpeg')):
                    self.samples.append((os.path.join(class_dir, img_name), self.class_to_idx[class_name]))

    def __len__(self):
        return len(self.samples)

    def __getitem__(self, idx):
        img_path, label = self.samples[idx]
        try:
            image = Image.open(img_path).convert('RGB')
        except Exception as e:
            print(f"CẢNH BÁO: Lỗi đọc ảnh {img_path}: {e}. Đang dùng ảnh đen thay thế.")
            image = Image.new('RGB', (224, 224), color='black')
        if self.transform:
            image = self.transform(image)
        return image, label

def get_transforms(config):
    transform_config = config.get('transforms', {})
    val_test_transforms = [
        transforms.Resize((transform_config.get('crop_size', 224), transform_config.get('crop_size', 224))),
        transforms.ToTensor(),
        transforms.Normalize(
            mean=transform_config.get('mean', [0.485, 0.456, 0.406]),
            std=transform_config.get('std', [0.229, 0.224, 0.225])
        )
    ]
    return transforms.Compose(val_test_transforms)

class ONNXCalibrationDataReader(CalibrationDataReader):
    def __init__(self, dataloader, input_name, max_batches=50):
        self.enum_data = iter(dataloader)
        self.input_name = input_name
        self.max_batches = max_batches
        self.batch_count = 0

    def get_next(self):
        if self.batch_count >= self.max_batches:
            return None
        try:
            images, _ = next(self.enum_data)
            self.batch_count += 1
            return {self.input_name: images.numpy()}
        except StopIteration:
            return None

# 3. MODEL BUILDER
def create_model(model_name, num_classes):
    model_name = model_name.lower()
    # FIX: Thay pretrained=False bằng weights=None
    if model_name == 'resnet50':
        model = models.resnet50(weights=None)
        model.fc = nn.Linear(model.fc.in_features, num_classes)
    elif model_name == 'resnet18':
        model = models.resnet18(weights=None)
        model.fc = nn.Linear(model.fc.in_features, num_classes)
    elif model_name == 'efficientnet_b0':
        model = models.efficientnet_b0(weights=None)
        model.classifier[-1] = nn.Linear(model.classifier[-1].in_features, num_classes)
    elif model_name == 'vgg16':
        model = models.vgg16(weights=None)
        model.classifier[-1] = nn.Linear(model.classifier[-1].in_features, num_classes)
    else:
        raise ValueError(f"Kiến trúc {model_name} chưa được hỗ trợ export.")
    return model

# 4. BENCHMARKING ENGINE (Ép 1 luồng)
def create_ort_session(model_path, num_threads=1):
    sess_options = ort.SessionOptions()
    sess_options.intra_op_num_threads = num_threads  # ÉP 1 LUỒNG
    sess_options.inter_op_num_threads = 1
    sess_options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    session = ort.InferenceSession(model_path, sess_options, providers=['CPUExecutionProvider'])
    return session

def benchmark_onnx_model(model_path, dataloader, logger, num_threads=1, warmup_runs=5):
    session = create_ort_session(model_path, num_threads)
    input_name = session.get_inputs()[0].name

    correct = 0
    total = 0
    latencies = []

    # Warmup
    for i, (images, _) in enumerate(dataloader):
        if i >= warmup_runs:
            break
        _ = session.run(None, {input_name: images.numpy()})

    # Benchmark
    for images, labels in dataloader:
        input_data = {input_name: images.numpy()}
        start_time = time.perf_counter()
        outputs = session.run(None, input_data)
        end_time = time.perf_counter()

        batch_latency = (end_time - start_time) * 1000  # ms
        latencies.append(batch_latency / images.size(0))

        predictions = np.argmax(outputs[0], axis=1)
        correct += np.sum(predictions == labels.numpy())
        total += labels.size(0)

    accuracy = 100.0 * correct / total
    avg_latency = np.mean(latencies)
    return accuracy, avg_latency

# 5. ĐỘNG CƠ XỬ LÝ ĐƯỜNG ỐNG (PIPELINE ENGINE)
def process_pipeline_for_model(task_info, root_dir, logger):
    task_name = task_info['name']
    logger.info(f"\n")
    logger.info(f"BAT DAU XU LY MO HINH: {task_name.upper()}")
    logger.info(f"\n")

    data_dir = root_dir / "data" / task_info['data_folder']
    config_path = root_dir / "config" / task_info['config_file']
    models_dir = root_dir / "config" / "models"

    checkpoint_path = models_dir / task_info['model_file']
    base_name = task_info['model_file'].replace(".pth", "")
    onnx_fp32_path = models_dir / f"{base_name}_fp32.onnx"
    onnx_prep_path = models_dir / f"{base_name}_prep.onnx"
    onnx_int8_path = models_dir / f"{base_name}_int8.onnx"

    device = torch.device("cpu")

    try:
        if not checkpoint_path.exists():
            logger.error(f"X Khong tim thay checkpoint tai {checkpoint_path}. Bo qua task nay.")
            return

        config = load_config(str(config_path))
        checkpoint = torch.load(checkpoint_path, map_location=device)
        class_names = checkpoint['class_names']

        model = create_model(config['model']['name'], len(class_names))
        model.load_state_dict(checkpoint['model_state_dict'])
        model.eval()

        # 1. EXPORT FP32
        logger.info(f"{task_name} Buoc 1: Exporting PyTorch -> ONNX FP32...")
        input_size = config['transforms'].get('crop_size', 224)
        dummy_input = torch.randn(1, 3, input_size, input_size)

        torch.onnx.export(
            model, dummy_input, onnx_fp32_path,
            export_params=True, opset_version=13, do_constant_folding=True,
            input_names=["input"], output_names=["output"],
            dynamic_axes={'input': {0: 'batch_size'}, 'output': {0: 'batch_size'}}
        )
        onnx.checker.check_model(onnx.load(onnx_fp32_path))

        # 2. PRE-PROCESSING
        logger.info(f"{task_name} Buoc 2: ONNX Pre-processing (Graph Optimization)...")
        quant_pre_process(str(onnx_fp32_path), str(onnx_prep_path))

        # 3. STATIC QUANTIZATION (INT8)
        logger.info(f"{task_name} Buoc 3: Post-Training Static Quantization (QDQ)...")
        val_transform = get_transforms(config)

        calib_dataset = GenericJerseyDataset(str(data_dir), 'train', val_transform)
        calib_loader = DataLoader(calib_dataset, batch_size=16, shuffle=True, drop_last=True)
        calibration_reader = ONNXCalibrationDataReader(calib_loader, input_name="input", max_batches=50)

        quantize_static(
            model_input=onnx_prep_path,
            model_output=onnx_int8_path,
            calibration_data_reader=calibration_reader,
            quant_format=QuantFormat.QDQ,
            per_channel=False,          # Tối đa throughput, trade-off accuracy
            reduce_range=True,          # BẮT BUỘC cho Skylake CPU
            weight_type=QuantType.QInt8,
            activation_type=QuantType.QUInt8
        )

        # 4. BENCHMARK
        logger.info(f"{task_name} Buoc 4: Benchmarking (1 Luồng/Request)...")
        test_dataset = GenericJerseyDataset(str(data_dir), 'test', val_transform)
        test_loader = DataLoader(test_dataset, batch_size=1, shuffle=False)

        acc_fp32, lat_fp32 = benchmark_onnx_model(str(onnx_fp32_path), test_loader, logger, num_threads=1)
        acc_int8, lat_int8 = benchmark_onnx_model(str(onnx_int8_path), test_loader, logger, num_threads=1)

        # In Báo cáo
        logger.info(f"\n\nBÁO CÁO KẾT QUẢ CHO TÁC VỤ: {task_name.upper()}")
        logger.info(f"- Dung lượng file: {os.path.getsize(onnx_fp32_path)/(1024**2):.2f}MB (FP32) -> {os.path.getsize(onnx_int8_path)/(1024**2):.2f}MB (INT8)")
        logger.info(f"- Tốc độ (1 luồng): {lat_fp32:.2f}ms (FP32) -> {lat_int8:.2f}ms (INT8) | Nhanh hơn {lat_fp32/lat_int8:.2f}x")
        logger.info(f"- Accuracy: {acc_fp32:.2f}% (FP32) -> {acc_int8:.2f}% (INT8) | Hao hụt: {acc_fp32 - acc_int8:.2f}%")

        # Cleanup
        if os.path.exists(onnx_prep_path):
            os.remove(onnx_prep_path)

    except Exception as e:
        logger.error(f"X Lỗi nghiêm trọng khi xử lý task {task_name}: {e}", exc_info=True)

# 6. MAIN THREAD
def main():
    current_dir = Path(__file__).parent
    logs_dir = current_dir / "logs"
    logger = setup_logger(logs_dir)
    root_dir = current_dir.parent.parent

    tasks = [
        {
            'name': 'Jersey Color',
            'config_file': 'train_color.yaml',
            'data_folder': 'color_dataset',
            'model_file': 'jersey_color_model.pth'
        },
        {
            'name': 'Jersey Visibility',
            'config_file': 'train_visibility.yaml',
            'data_folder': 'visibility_dataset',
            'model_file': 'jersey_visibility_model.pth'
        }
    ]

    for task in tasks:
        process_pipeline_for_model(task, root_dir, logger)

    logger.info("HOÀN TẤT TOÀN BỘ PIPELINE CHO CÁC MÔ HÌNH!")

if __name__ == "__main__":
    main()
```

## Lỗi gặp phải và Cách khắc phục

**Lỗi 1: UnicodeEncodeError khi ghi log trên Windows**
```
UnicodeEncodeError: 'charmap' codec can't encode character '\u1ea1'
```
- **Nguyên nhân:** Windows mặc định dùng code page cp1252, không hỗ trợ ký tự tiếng Việt có dấu.
- **Cách khắc phục:** Thêm `encoding='utf-8'` vào `FileHandler`:

```python
fh = logging.FileHandler(log_dir / 'multi_export_benchmark.log', encoding='utf-8')
```

**Lỗi 2: TypeError với `optimize_model` trong `quantize_static()`**
```
TypeError: quantize_static() got an unexpected keyword argument 'optimize_model'
```
- **Nguyên nhân:** API mới của ONNX Runtime đã xóa tham số này; việc tối ưu đồ thị phải được thực hiện trước qua `quant_pre_process()`.
- **Cách khắc phục:** Xóa `optimize_model=False` khỏi `quantize_static()`. Đảm bảo gọi `quant_pre_process()` trước đó.

**Lỗi 3: Warning deprecated `pretrained` trong PyTorch**
```
UserWarning: The parameter 'pretrained' is deprecated
```
- **Nguyên nhân:** PyTorch 0.13+ đã thay đổi API.
- **Cách khắc phục:** Thay `pretrained=False` bằng `weights=None` trong tất cả model builders.

**Lỗi 4: Đánh giá sai hiệu quả của Unstructured Pruning**
- **Nguyên nhân:** `prune.global_unstructured` chỉ zero-mask, không thay đổi kích thước tensor; ONNX Runtime không có sparse kernel cho CPU nên không tăng tốc.
- **Quy tắc thiết lập:** **KHÔNG sử dụng Unstructured Pruning cho CPU** trừ khi có engine hỗ trợ sparse matrix. Thay vào đó, sử dụng Structured Pruning (cắt channel) hoặc chọn kiến trúc nhẹ hơn ngay từ đầu.

## Khái niệm & Định nghĩa

- **Static Quantization (PTSQ)**: Lượng tử hóa sau huấn luyện với dữ liệu mồi (calibration) để tính scale và zero-point cho activation layers. Được chỉ định bằng `QuantFormat.QDQ` (Quantize-Dequantize).
- **Dynamic Quantization**: Chỉ lượng tử hóa trọng số, activation được tính toán động khi inference. Phù hợp cho các mô hình Linear/RNN, không hiệu quả cho CNN vì chủ yếu là Conv layers.
- **Per-channel quantization**: Mỗi channel của filter có scale và zero-point riêng, giữ accuracy tốt hơn nhưng tốn memory bandwidth. `per_channel=True` giảm throughput so với `False`.
- **reduce_range=True**: Giới hạn dải giá trị INT8 từ [-64, 64] thay vì [-128, 127], bắt buộc cho CPU cũ không hỗ trợ VNNI để tránh tràn số.
- **VNNI (Vector Neural Network Instructions)**: Tập lệnh AVX-512 trên CPU Intel thế hệ mới, tăng tốc tính toán INT8. Nếu VM chạy trên Skylake (không có VNNI), cần `reduce_range=True`.

## Các phương án đã cân nhắc

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
|---|---|---|---|
| **Unstructured Pruning + Fine-tune** | Giảm dung lượng model (sau khi nén) | Không tăng tốc trên CPU, mất accuracy, tốn compute | ❌ **KHÔNG** |
| **Structured Pruning (cắt channel)** | Giảm FLOPs thực tế | Phức tạp, cần rebuild layer, rủi ro phá vỡ residual connections | ❌ KHÔNG (quá phức tạp) |
| **Static Quantization INT8 (QDQ)** | Tăng tốc 2-4x, dung lượng giảm 4x | Hao hụt accuracy nhỏ (có thể chấp nhận) | ✅ **CÓ** |
| **Per-channel True** | Accuracy cao hơn | Giảm throughput CPU | 🤔 Cần benchmark, script mặc định **False** để tối ưu tốc độ |
| **Pre-processing + Quantization tách biệt** | Đồ thị tối ưu, dễ debug | Tốn thêm file trung gian | ✅ **CÓ** (dùng `quant_pre_process()`) |
| **Cấu hình thread mặc định** | Đơn giản | Gây CPU thrashing, latency cao trên VM nhỏ | ❌ KHÔNG (ép `num_threads=1` để ổn định) |

**Tiêu chí quyết định:** Tối đa hóa throughput và latency ổn định trên môi trường production với tài nguyên giới hạn, ưu tiên các giải pháp đã được chứng minh (quantization) thay vì các kỹ thuật phức tạp chưa đảm bảo (pruning). Giữ accuracy ở mức chấp nhận được (<5% drop).