---
source_url: https://gemini.google.com/app/f5dfdc8818965d83
conversation_date: 2026-09-01
context_week: N/A
conversation_types: [FIX_CODE, TRANH_LUAN_QUYET_DINH, LY_THUYET]
ai300_domains: ["Design and implement MLOps infrastructure", "Model lifecycle"]
technologies: [YOLO, ONNX, OpenCV, NumPy, Python, ThreadPoolExecutor, ResNet, Base64]
key_decision: "Chuyển logic tiền xử lý letterbox từ client sang server-side trong HybridInferenceEngine để đảm bảo tính đóng gói và chính xác tọa độ."
status: resolved
---

## Bối cảnh & Vấn đề

Hệ thống inference gồm ba thành phần chính:

- **Client** (`[source: 1]`): đọc nguyên bản file ảnh (raw bytes) và mã hóa Base64 để gửi đi. **Không thực hiện bất kỳ tiền xử lý kích thước nào.**
- **Server Wrapper** (`[source: 3]`): giải mã Base64 thành mảng NumPy nguyên bản, gọi `engine.process_frame(frame, player_class_id=0)` mà không truyền tham số `scale` hay `pad`.
- **HybridInferenceEngine** (`[source: 2]`): được thiết kế với giả định sai lầm rằng client đã thực hiện letterboxing trước khi gửi.

**Hậu quả cụ thể:**
- Thiếu tham số `scale` và `pad` trong lệnh gọi `engine.process_frame` → `TypeError` hoặc pipeline vỡ.
- Nếu bỏ qua tham số, mô hình YOLO ONNX nhận tensor sai kích thước chuẩn (không phải 640×640) → kết quả rác.
- Logic cắt ảnh (cropping) sử dụng `bbox_raw` (hệ quy chiếu 640×640) trên `frame` nguyên bản → toạ độ lệch, crop sai vùng.

## Quyết định cuối cùng & Lý do

**Quyết định:**
- **Không sửa client** để thực hiện tiền xử lý (vì phá vỡ tính đóng gói của API).
- **Kéo toàn bộ logic letterbox, tính scale/pad vào trong `HybridInferenceEngine`**, xử lý động ngay tại server.

**Lý do:**
- Đảm bảo tính độc lập của client, wrapper chỉ đóng vai trò I/O router.
- Tránh sai lệch toạ độ do bất đồng bộ giữa ảnh gốc và tensor đầu vào.
- Chi phí CPU thêm (cv2.resize, copyMakeBorder) chỉ ~2‑3ms, chấp nhận được trong kiến trúc 2‑stage.

**Phương án bị loại bỏ:**
| Phương án | Lý do loại bỏ |
|-----------|---------------|
| Yêu cầu client thực hiện letterbox trước khi gửi | Phá vỡ tính đóng gói của API, không kiểm soát được chất lượng ảnh đầu vào, không tái sử dụng được cho các client khác. |

## Lệnh và Cấu hình cụ thể đã dùng

**Bổ sung phương thức `_letterbox` vào class `HybridInferenceEngine`:**
```python
def _letterbox(self, img: np.ndarray, new_shape: Tuple[int, int] = (640, 640), color: Tuple[int, int, int] = (114, 114, 114)):
    """
    Tiền xử lý ảnh theo chuẩn YOLO: Đổi kích thước giữ nguyên tỷ lệ (Aspect Ratio)
    và đệm viền (Padding) để đạt kích thước yêu cầu của ONNX model.
    """
    shape = img.shape[:2]  # [height, width]
    
    # Tính toán tỷ lệ thu phóng (Scale)
    r = min(new_shape[0] / shape[0], new_shape[1] / shape[1])
    new_unpad = int(round(shape[1] * r)), int(round(shape[0] * r))
    
    # Tính toán phần bù (Padding)
    dw, dh = new_shape[1] - new_unpad[0], new_shape[0] - new_unpad[1]
    dw, dh = dw / 2, dh / 2  # Chia đều 2 bên
    
    if shape[::-1] != new_unpad:
        img = cv2.resize(img, new_unpad, interpolation=cv2.INTER_LINEAR)
    
    top, bottom = int(round(dh - 0.1)), int(round(dh + 0.1))
    left, right = int(round(dw - 0.1)), int(round(dw + 0.1))
    
    img = cv2.copyMakeBorder(img, top, bottom, left, right, cv2.BORDER_CONSTANT, value=color)
    
    return img, r, (left, top)
```

**Viết lại `_prepare_yolo_input` (tích hợp letterbox động):**
```python
def _prepare_yolo_input(self, frame: np.ndarray) -> Tuple[np.ndarray, float, Tuple[int, int]]:
    """
    Thực hiện chuẩn hóa ảnh động từ frame gốc: Letterbox -> RGB -> Normalize -> CHW -> Batch.
    Trả về tensor, tỷ lệ scale và thông số pad để phục vụ post-processing.
    """
    # 1. Thực hiện chuẩn hóa kích thước động
    img_letterbox, scale, pad = self._letterbox(frame, new_shape=(640, 640))
    
    # 2. BGR to RGB conversion
    rgb_frame = cv2.cvtColor(img_letterbox, cv2.COLOR_BGR2RGB)
    # 3. Ép kiểu float32 và normalize [0, 255] -> [0.0, 1.0]
    tensor = rgb_frame.astype(np.float32) / 255.0
    # 4. HWC (Height, Width, Channels) to CHW (Channels, Height, Width)
    tensor = tensor.transpose((2, 0, 1))
    # 5. Expand batch shape (1, C, H, W)
    batch_tensor = np.expand_dims(tensor, axis=0)
    
    return batch_tensor, scale, pad
```

**Thay đổi chữ ký và logic điều phối của `process_frame` (loại bỏ tham số scale/pad đầu vào):**
```python
def process_frame(self, frame: np.ndarray, player_class_id: int = 0) -> Dict[str, Any]:
    """
    Main execution pipeline. Xử lý ảnh gốc nguyên bản, tự động tính toán không gian tọa độ.
    """
    t0 = time.perf_counter()
    
    # --- STAGE 1: Object Detection (Sequential) ---
    input_tensor, scale, pad = self._prepare_yolo_input(frame)
    yolo_outputs = self.yolo_session.run(None, {self.yolo_input_name: input_tensor})
    detections = self._postprocess_yolo(yolo_outputs, scale, pad)
    
    t1 = time.perf_counter()
    logger.debug(f"Stage 1 (YOLO) completed in {(t1 - t0) * 1000:.2f} ms")
    
    # Cắt ảnh cầu thủ sử dụng tọa độ RAW từ frame gốc
    crops = []
    valid_detections = []
    frame_h, frame_w = frame.shape[:2]
    
    for det in detections:
        if det["class_id"] == player_class_id:
            # SỬ DỤNG TỌA ĐỘ MAPPED (đã loại bỏ padding/scale) để crop ảnh gốc
            mx1, my1, mx2, my2 = det["bbox_mapped"]
            # Clamp strict bounds
            mx1, my1 = max(0, mx1), max(0, my1)
            mx2, my2 = min(frame_w, mx2), min(frame_h, my2)
            
            crop = frame[my1:my2, mx1:mx2]
            if crop.size > 0:
                crops.append(crop)
                valid_detections.append(det)
    
    if not crops:
        return {"status": "success", "detections": [], "compute_ms": (time.perf_counter() - t0) * 1000}
    
    # Prepare Batch for ResNets
    batch_tensor = self._preprocess_resnet_batch(crops)
    
    # --- STAGE 2: Parallel Classification (Thread Pool) ---
    t2 = time.perf_counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        future_color = executor.submit(self._run_classifier, self.color_session, self.color_input_name, batch_tensor)
        future_vis = executor.submit(self._run_classifier, self.vis_session, self.vis_input_name, batch_tensor)
        color_results = future_color.result()
        vis_results = future_vis.result()
    
    t3 = time.perf_counter()
    logger.debug(f"Stage 2 (ResNets Parallel) completed in {(t3 - t2) * 1000:.2f} ms")
    
    # Construct final output
    final_detections = []
    for idx, det in enumerate(valid_detections):
        final_detections.append({
            "bbox": det["bbox_mapped"],
            "confidence": det["confidence"],
            "color_class": color_results[idx][0],
            "color_conf": color_results[idx][1],
            "vis_class": vis_results[idx][0],
            "vis_conf": vis_results[idx][1]
        })
    
    total_time_ms = (time.perf_counter() - t0) * 1000
    logger.info(f"Frame processed entirely in {total_time_ms:.2f} ms")
    
    return {
        "status": "success",
        "detections": final_detections,
        "compute_ms": round(total_time_ms, 2)
    }
```

## Lỗi gặp phải và Cách khắc phục

| Lỗi / Anti‑pattern | Cách khắc phục |
|--------------------|----------------|
| Thiếu tham số `scale`, `pad` trong lệnh gọi `process_frame` từ wrapper | Loại bỏ `scale` và `pad` khỏi tham số đầu vào, tự tính toán bên trong engine. |
| Giả định sai rằng client đã letterbox ảnh | Thực hiện letterbox động trong `_prepare_yolo_input` thông qua `_letterbox`. |
| Sử dụng `bbox_raw` (hệ quy chiếu 640x640) để crop ảnh gốc | Chuyển sang sử dụng `bbox_mapped` (toạ độ đã ánh xạ về hệ quy chiếu gốc) trong lệnh `crop = frame[my1:my2, mx1:mx2]`. |
| Quy trình preprocessing phân tán, không đóng gói | Tập trung mọi logic tiền xử lý trong `HybridInferenceEngine`, wrapper chỉ gọi API duy nhất. |

**Quy tắc mới được thiết lập:**  
- **Không được để client hay wrapper tham gia vào bất kỳ phép biến đổi hình học hay chuẩn hóa kích thước nào.**  
- Mọi tính toán về tỷ lệ (scale), phần bù (pad) và letterbox **bắt buộc** phải nằm trong engine inference.

## Khái niệm & Định nghĩa

| Thuật ngữ | Định nghĩa | Ví dụ trong ngữ cảnh |
|-----------|------------|----------------------|
| **Letterboxing** | Kỹ thuật thay đổi kích thước ảnh trong khi vẫn giữ nguyên tỷ lệ khung hình bằng cách thêm viền đen (hoặc màu) vào các cạnh thiếu để đạt được kích thước mong muốn. | Ảnh gốc 1920×1080 được resize thành 640×360, sau đó pad thêm viền trên/dưới để thành 640×640. |
| **Scale & Pad** | Tỷ lệ co dãn (`scale`) và tọa độ viền (`pad`) dùng để ánh xạ ngược bounding box từ ảnh đã xử lý về ảnh gốc. | `r = min(640/h, 640/w)`, `left, top` là offset viền; khi post‑processing, dùng các giá trị này để chuyển `bbox_raw` → `bbox_mapped`. |
| **HWC ↔ CHW** | Chuyển đổi thứ tự chiều của tensor: từ `(Height, Width, Channels)` sang `(Channels, Height, Width)` – định dạng đầu vào chuẩn của các mô hình deep learning. | `tensor.transpose((2, 0, 1))` sau khi đọc ảnh BGR dạng HWC. |

## Các phương án đã cân nhắc

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
|-----------|---------|------------|------------|
| **A – Client thực hiện letterbox trước khi gửi** | Giảm tải CPU server, server chỉ nhận tensor đã chuẩn. | Phá vỡ tính đóng gói API; khó đồng bộ giữa các client; không tái sử dụng cho các ứng dụng khác. | **KHÔNG** (bị loại bỏ) |
| **B – Server wrapper thực hiện tiền xử lý** | Tách biệt logic preprocessing khỏi engine. | Wrapper trở nên quá nặng, không đúng vai trò I/O router; vẫn cần truyền scale/pad sang engine. | **KHÔNG** (bị loại bỏ) |
| **C – Engine tự xử lý letterbox động** (phương án chọn) | Đóng gói hoàn toàn; wrapper chỉ gọi `process_frame(frame)`; giảm thiểu sai lệch toạ độ; dễ bảo trì. | Tăng nhẹ CPU (2‑3ms/frame) do phải resize và pad tại server. | **CÓ** (chọn) |

**Tiêu chí quyết định:** Tính đóng gói, khả năng tái sử dụng, độ chính xác của bounding box, và chi phí CPU thêm là chấp nhận được.
