---
source_url: https://gemini.google.com/app/9fd37e77b8f6b2db
conversation_date: 2026-08-12
context_week: N/A
conversation_types: [LAP_KE_HOACH, TRANH_LUAN_QUYET_DINH, FIX_CODE, FIX_HA_TANG]
ai300_domains: ["Thiết kế và triển khai MLOps infrastructure", "Model lifecycle", "Tối ưu hệ thống GenAI và hiệu suất model"]
technologies: [YOLO, Azure ML, Vercel, GitHub Actions, Node.js, Canvas API, Python, OpenCV, PyTorch, Docker, ONNX, ResNet50, MobileNetV3, Base64, Service Principal, Environment Variables, Path Filtering, CI/CD, Serverless Functions, BFF]
key_decision: "Sử dụng kiến trúc Monorepo với path filtering để tách biệt CI/CD cho AI và Web, triển khai BFF qua Vercel Serverless Proxy, chỉ dùng endpoint ảnh đơn cho YOLO, và thiết lập cơ chế pre‑fetch 10% video đầu để giảm độ trễ mạng do định tuyến trombone giữa Việt Nam – Vercel (Mỹ) – Azure (Hong Kong)."
status: resolved
---

## Bối cảnh & Vấn đề

- Xây dựng hệ thống demo end‑to‑end cho YOLO object tracking, bao gồm frontend web, backend proxy, và CI/CD tự động cho cả model AI lên Azure ML và frontend lên Vercel.
- Lịch trình bị ép trong 5 ngày, cần cân bằng giữa việc hoàn thiện tính năng và thiết lập pipeline chuyên nghiệp.
- Phát sinh độ trễ mạng cực lớn (≥ 2680ms) mặc dù model Azure chỉ mất ~90ms để inference.
- Azure trả về response có dung lượng chỉ 20 bytes – dấu hiệu của lỗi xử lý Base64 khiến model không nhận được ảnh hợp lệ.

## Quyết định cuối cùng & Lý do

### Kiến trúc tổng thể
- **Monorepo** (gộp `/ai-core` và `/web-client`) để tạo Single Source of Truth cho nhà tuyển dụng, nhưng **bắt buộc** sử dụng **Path Filtering** trong GitHub Actions để cách ly pipeline.
- **KHÔNG dùng Polyrepo** vì sẽ làm phức tạp việc theo dõi và quản lý phiên bản, đồng thời không tận dụng được sức mạnh của monorepo trong hồ sơ ứng tuyển.
- **KHÔNG gộp chung mà không có cách ly** vì sẽ tạo ra monolithic pipeline gây lãng phí tài nguyên khi thay đổi nhỏ ở frontend (kích hoạt deploy model nặng).

## Lựa chọn endpoint cho YOLO
- **Chỉ sử dụng endpoint ảnh đơn** (Real‑time inference). Đây là endpoint duy nhất cần thiết cho demo tracking, client tự chia video thành từng frame và gọi API.
- **KHÔNG dùng endpoint video đồng bộ** (HTTP POST toàn bộ file MP4) vì vi phạm nguyên tắc timeout HTTP, gây tắc nghẽn băng thông và bộ nhớ, không phù hợp với thời gian thực.
- Endpoint video chỉ có giá trị nếu xử lý bất đồng bộ (Async Batch) – nhưng không phù hợp với mục tiêu sprint hiện tại.

### Xử lý độ trễ mạng (Trombone Effect)
- Nguyên nhân: Client ở Việt Nam → Vercel Serverless (mặc định vùng `iad1` – Bờ Đông Mỹ) → Azure ML (Hong Kong/Tokyo) → ngược lại. Hành trình zigzag khiến latency lên tới 2680ms.
- **Giải pháp:**
  1. Ép Vercel deploy tại Singapore (`sin1`) bằng file `vercel.json`.
  2. Resize ảnh xuống 640x640 (đúng input YOLO) và nén JPEG chất lượng 0.6 trước khi gửi, giảm payload từ 500KB–1.5MB xuống ~30–50KB.
  3. Triển khai cơ chế **pre‑fetch 10%** video đầu: tạm dừng video, gửi trước các frame vào buffer, sau đó phát lại đồng bộ với bounding box đã có sẵn, giảm cảm giác độ trễ.

### Đồng bộ dữ liệu giữa backend (Python) và frontend (JavaScript)
- `score.py` cần parse Base64 đúng cách: loại bỏ tiền tố `data:image/jpeg;base64,` trước khi decode.
- Contract dữ liệu thống nhất: backend trả về `{"status": "success", "detections": [{"bbox": [x1,y1,x2,y2], "class_name": "...", "confidence": ..., "color_class": ..., "vis_class": ...}]}`.
- Frontend vẽ dựa trên tọa độ `bbox`, sử dụng scale factor để phù hợp với kích thước canvas.

## Lệnh và Cấu hình cụ thể đã dùng

### Cấu trúc thư mục Monorepo

```
/
├── ai-core/
│   ├── inference.py
│   └── score.py
├── web-client/
│   ├── public/
│   │   ├── index.html
│   │   ├── style.css
│   │   └── app.js
│   ├── api/
│   │   └── proxy.js
│   ├── .env
│   ├── vercel.json
│   └── package.json
├── .github/
│   └── workflows/
│       └── azure-ml-deploy.yml
└── .gitignore
```

### Path Filtering trong GitHub Actions (`.github/workflows/azure-ml-deploy.yml`)

```yaml
on:
  push:
    branches:
      - main
    paths:
      - 'ai-core/**'
      - '.github/workflows/azure-ml-deploy.yml'
```

### Vercel Root Directory Configuration

Trên Vercel Dashboard → Settings → General → Root Directory: `web-client`

### `vercel.json` (đặt tại `web-client/`)

```json
{
  "regions": ["sin1"]
}
```

### `web-client/api/proxy.js` (Serverless BFF)

```javascript
export default async function handler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method Not Allowed. Use POST.' });
  }

  const AZURE_ML_ENDPOINT = process.env.AZURE_ML_ENDPOINT;
  const AZURE_ML_KEY = process.env.AZURE_ML_KEY;

  if (!AZURE_ML_ENDPOINT || !AZURE_ML_KEY) {
    console.error("Critical System Error: Missing Environment Variables");
    return res.status(500).json({ error: 'Server configuration error' });
  }

  try {
    const { image } = req.body;
    if (!image) {
      return res.status(400).json({ error: 'Missing image payload' });
    }

    const azureResponse = await fetch(AZURE_ML_ENDPOINT, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${AZURE_ML_KEY}`
      },
      body: JSON.stringify({ data: image })
    });

    if (!azureResponse.ok) {
      const errorText = await azureResponse.text();
      console.error(`Azure ML Error [${azureResponse.status}]: `, errorText);
      return res.status(azureResponse.status).json({
        error: 'Upstream Inference Failed',
        details: errorText
      });
    }

    const result = await azureResponse.json();
    return res.status(200).json(result);
  } catch (error) {
    console.error("Proxy Execution Error:", error);
    return res.status(500).json({ error: 'Internal Server Error', message: error.message });
  }
}
```

### `web-client/.env` (local)

```
AZURE_ML_ENDPOINT=https://yolo-endpoint-ver1.eastasia.inference.ml.azure.com/score
# Remember to add Azure ML Key
```

### `web-client/public/index.html`

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>YOLO Real-time Inference | Technical Demo</title>
  <link rel="stylesheet" href="style.css">
</head>
<body>
<div class="container">
  <header>
    <h1>YOLO Object Tracking Pipeline</h1>
    <div class="controls">
      <input type="file" id="videoUpload" accept="video/mp4,video/webm" />
      <button id="togglePlay" disabled>Play / Pause</button>
      <label>
        <input type="checkbox" id="toggleBBox" checked> Show Bounding Boxes
      </label>
    </div>
  </header>
  <main>
    <div class="video-wrapper">
      <video id="sourceVideo" muted playsinline style="display: none;"></video>
      <canvas id="outputCanvas"></canvas>
      <div class="telemetry-panel">
        <h3>System Telemetry</h3>
        <p>Client FPS: <span id="fps">0</span></p>
        <p>Network Latency: <span id="latency">0</span> ms</p>
        <p>Inference Time: <span id="inference">0</span> ms</p>
        <p>API Status: <span id="apiStatus" class="status-ok">Idle</span></p>
      </div>
    </div>
  </main>
</div>
<script src="app.js"></script>
</body>
</html>
```

### `web-client/public/style.css`

```css
:root {
  --bg-color: #0d1117;
  --panel-bg: #161b22;
  --text-color: #c9d1d9;
  --accent: #58a6ff;
  --border: #30363d;
}
body {
  margin: 0;
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
  background-color: var(--bg-color);
  color: var(--text-color);
}
.container {
  max-width: 1200px;
  margin: 0 auto;
  padding: 20px;
}
header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  border-bottom: 1px solid var(--border);
  padding-bottom: 15px;
  margin-bottom: 20px;
}
.controls {
  display: flex;
  gap: 15px;
  align-items: center;
}
button {
  background-color: var(--accent);
  color: #000;
  border: none;
  padding: 8px 16px;
  border-radius: 4px;
  cursor: pointer;
  font-weight: bold;
}
button:disabled {
  background-color: var(--border);
  cursor: not-allowed;
}
.video-wrapper {
  position: relative;
  background-color: #000;
  border: 1px solid var(--border);
  border-radius: 6px;
  overflow: hidden;
  display: flex;
  justify-content: center;
}
canvas {
  max-width: 100%;
  max-height: 70vh;
  display: block;
}
.telemetry-panel {
  position: absolute;
  top: 10px;
  left: 10px;
  background-color: rgba(22, 27, 34, 0.85);
  border: 1px solid var(--border);
  padding: 15px;
  border-radius: 6px;
  font-family: monospace;
  min-width: 200px;
}
.telemetry-panel h3 {
  margin: 0 0 10px 0;
  font-size: 14px;
  color: var(--accent);
  border-bottom: 1px solid var(--border);
  padding-bottom: 5px;
}
.telemetry-panel p {
  margin: 5px 0;
  font-size: 13px;
}
.status-ok { color: #3fb950; }
.status-error { color: #f85149; }
.status-syncing { color: #d29922; }
```

### `web-client/public/app.js` (phiên bản cuối với pre‑fetch 10% và vẽ bounding boxes theo inference.py)

```javascript
// File: /web-client/public/app.js

// --- CÁC BIẾN TRẠNG THÁI (STATE) TỔNG THẾ ---
const video = document.getElementById('sourceVideo');
const canvas = document.getElementById('outputCanvas');
const ctx = canvas.getContext('2d', { alpha: false });
const btnPlay = document.getElementById('togglePlay');
const fileUpload = document.getElementById('videoUpload');
const toggleBBox = document.getElementById('toggleBBox');
const statusUI = document.getElementById('apiStatus');

let isPlaying = false;
let animationFrameId;
let currentBoundingBoxes = [];
let globalScaleFactor = 1;

// --- CẤU HÌNH KIẾN TRÚC HYBRID (BUFFER 10% + REAL-TIME) ---
let isApiProcessing = false;
let bufferedResults = [];
let isBuffered = false;
let bufferTargetDuration = 0;

const INFERENCE_FPS_LIMIT = 5;
const INFERENCE_INTERVAL = 1000 / INFERENCE_FPS_LIMIT;
let lastInferenceTime = 0;
let frameCount = 0;
let lastFpsTime = performance.now();

// --- LẮNG NGHE SỰ KIỆN NẠP VIDEO ---
fileUpload.addEventListener('change', (e) => {
  const file = e.target.files[0];
  if (!file) return;

  // Reset toàn bộ state khi nạp video mới
  isBuffered = false;
  bufferedResults = [];
  currentBoundingBoxes = [];
  btnPlay.innerHTML = "Play / Pause";

  const fileURL = URL.createObjectURL(file);
  video.src = fileURL;

  video.onloadedmetadata = () => {
    canvas.width = video.videoWidth;
    canvas.height = video.videoHeight;
    // YÊU CẦU 1: Đặt mốc thời lượng 10% của video
    bufferTargetDuration = video.duration * 0.1;
    btnPlay.disabled = false;
    ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
  };
});

// --- 2. QUẢN LÝ LUỒNG ĐIỀU KHIỂN & PRE-FETCH ---
btnPlay.addEventListener('click', async () => {
  if (video.paused) {
    // Nếu chưa pre-fetch 10% data -> Khởi chạy tiến trình Buffering ngầm
    if (!isBuffered) {
      btnPlay.disabled = true;
      btnPlay.innerHTML = "Buffering 10%...";
      await buildInitialBuffer();
      isBuffered = true;
      btnPlay.disabled = false;
      btnPlay.innerHTML = "Play / Pause";
    }
    // Sau khi hoàn tất 10%, tiến hành render video đồng thời
    video.play();
    isPlaying = true;
    renderLoop();
  } else {
    video.pause();
    isPlaying = false;
    cancelAnimationFrame(animationFrameId);
  }
});

// Tiến trình ngầm: Tua video, chụp frame, gọi API và lưu trữ trước 10% thời lượng
async function buildInitialBuffer() {
  let tempTime = 0;
  statusUI.innerHTML = "Pre-fetching 10%...";
  statusUI.className = "status-syncing";

  while (tempTime <= bufferTargetDuration) {
    // Bắt buộc video tua đến thời gian tương ứng
    await new Promise(resolve => {
      video.onseeked = resolve;
      video.currentTime = tempTime;
    });
    // Vẽ frame hiện tại ra canvas để trích xuất Base64
    ctx.drawImage(video, 0, 0, canvas.width, canvas.height);

    try {
      const result = await fetchInferenceData();
      bufferedResults.push({
        time: tempTime,
        detections: result.detections || [],
        scale: globalScaleFactor
      });
    } catch (err) {
      console.error("Buffer error at timestamp", tempTime, err);
    }

    // Tịnh tiến khung hình theo tốc độ FPS giới hạn
    tempTime += (1 / INFERENCE_FPS_LIMIT);
  }

  // Reset video về 0 để chuẩn bị phát thực tế
  video.currentTime = 0;
  statusUI.innerText = "Buffer Ready";
  statusUI.className = "status-ok";
}

// Hàm Core: Giao tiếp Azure ML (Dùng chung cho cả Buffer và Real-time)
async function fetchInferenceData() {
  const MAX_WIDTH = 640;
  let base64Frame;

  if (canvas.width > MAX_WIDTH) {
    globalScaleFactor = canvas.width / MAX_WIDTH;
    const tempCanvas = document.createElement('canvas');
    tempCanvas.width = MAX_WIDTH;
    tempCanvas.height = canvas.height / globalScaleFactor;
    const tempCtx = tempCanvas.getContext('2d');
    tempCtx.drawImage(canvas, 0, 0, tempCanvas.width, tempCanvas.height);
    base64Frame = tempCanvas.toDataURL('image/jpeg', 0.6);
  } else {
    globalScaleFactor = 1;
    base64Frame = canvas.toDataURL('image/jpeg', 0.6);
  }

  const startTime = performance.now();
  const response = await fetch('/api/proxy', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ image: base64Frame })
  });
  if (!response.ok) throw new Error(`HTTP Error: ${response.status}`);
  const result = await response.json();
  const endTime = performance.now();

  document.getElementById('latency').innerText = Math.round(endTime - startTime);
  document.getElementById('inference').innerText = (result.inference_time_ms) || 0;
  return result;
}

// --- 3. LUỒNG ĐỒ HỌA (RENDER LOOP) ---
function renderLoop() {
  if (!isPlaying) return;

  const currentTime = performance.now();

  ctx.drawImage(video, 0, 0, canvas.width, canvas.height);

  // KIẾN TRÚC HYBRID: Quyết định dùng Buffer hay gọi API trực tiếp
  if (video.currentTime <= bufferTargetDuration && bufferedResults.length > 0) {
    // Giai đoạn 10% đầu: Tìm JSON có timestamp gần nhất trong Buffer
    const closest = bufferedResults.reduce((prev, curr) =>
      Math.abs(curr.time - video.currentTime) < Math.abs(prev.time - video.currentTime) ? curr : prev
    );
    currentBoundingBoxes = closest.detections;
    globalScaleFactor = closest.scale;
  } else {
    // Giai đoạn 90% sau: Gọi API Real-time (Throttling)
    if (currentTime - lastInferenceTime >= INFERENCE_INTERVAL) {
      lastInferenceTime = currentTime;
      executeRealtimeInference();
    }
  }

  // Vẽ hộp giới hạn
  if (toggleBBox.checked && currentBoundingBoxes.length > 0) {
    drawBoundingBoxes(currentBoundingBoxes);
  }

  // Đo lường Telemetry FPS
  frameCount++;
  if (currentTime - lastFpsTime >= 1000) {
    document.getElementById('fps').innerText = frameCount;
    frameCount = 0;
    lastFpsTime = currentTime;
  }

  animationFrameId = requestAnimationFrame(renderLoop);
}

// Giao tiếp bất đồng bộ cho 90% thời lượng sau của video
async function executeRealtimeInference() {
  if (isApiProcessing) return;
  isApiProcessing = true;
  statusUI.innerText = "Syncing...";
  statusUI.className = "status-syncing";

  try {
    const result = await fetchInferenceData();
    currentBoundingBoxes = result.detections || [];
    statusUI.innerText = "Connected";
    statusUI.className = "status-ok";
  } catch (error) {
    console.error("Realtime Inference Error:", error);
    statusUI.innerText = "Error / Timeout";
    statusUI.className = "status-error";
  } finally {
    isApiProcessing = false;
  }
}

// --- 4. YÊU CẦU 2: LOGIC VẼ BOUNDING BOX THEO INFERENCE.PY ---
function drawBoundingBoxes(detections) {
  detections.forEach(det => {
    const x1 = det.bbox[0] * globalScaleFactor;
    const y1 = det.bbox[1] * globalScaleFactor;
    const x2 = det.bbox[2] * globalScaleFactor;
    const y2 = det.bbox[3] * globalScaleFactor;
    const width = x2 - x1;
    const height = y2 - y1;

    const className = det.class_name;
    const confidence = det.confidence;

    // Mã gốc cv2.rectangle: BGR (0, 255, 0) -> RGB là Green (#00ff00)
    ctx.strokeStyle = "#00ff00";
    ctx.lineWidth = 2;
    ctx.strokeRect(x1, y1, width, height);
    ctx.font = "14px Arial";

    if (className.toLowerCase() === 'player') {
      let yOffset = 0;
      // Phân loại Màu áo: BGR (0, 0, 255) -> RGB là Red (#ff0000)
      if (det.color_class !== null && det.color_class !== undefined) {
        const colorConf = det.color_conf !== undefined ? det.color_conf : 0;
        const colorLabel = `Color: ${det.color_class} (${colorConf.toFixed(2)})`;
        ctx.fillStyle = "#ff0000";
        const textY = Math.min(canvas.height - 5, y2 + 20 + yOffset);
        ctx.fillText(colorLabel, x1, textY);
        yOffset += 20;
      }
      // Phân loại Số áo: BGR (255, 0, 0) -> RGB là Blue (#0000ff)
      if (det.vis_class !== null && det.vis_class !== undefined) {
        const visConf = det.vis_conf !== undefined ? det.vis_conf : 0;
        const visLabel = `Number: ${det.vis_class} (${visConf.toFixed(2)})`;
        ctx.fillStyle = "#0000ff";
        const textY = Math.min(canvas.height - 5, y2 + 20 + yOffset);
        ctx.fillText(visLabel, x1, textY);
      }
    } else {
      // Label mặc định: BGR (0, 255, 0) -> RGB là Green (#00ff00)
      const label = `${className} ${confidence.toFixed(2)}`;
      ctx.fillStyle = "#00ff00";
      const textY = Math.max(15, y1 - 10);
      ctx.fillText(label, x1, textY);
    }
  });
}
```

### `ai-core/score.py` (bản vá cuối, xử lý Base64 và trả về detections)

```python
import base64
import cv2
import numpy as np
import torch

def run(raw_data):
    """Thực thi suy luận trên từng request JSON."""
    try:
        # 1. Lấy dữ liệu linh hoạt (để phòng API Proxy đổi key)
        raw_b64 = raw_data.get("image") or raw_data.get("data")
        if not raw_b64:
            return {"error": "Missing image data in payload"}

        # 2. Xử lý triệt để tiền tố Data URI của Canvas
        if "," in raw_b64:
            raw_b64 = raw_b64.split(",")[1]

        # 3. Giải mã nhị phân
        img_bytes = base64.b64decode(raw_b64)
        np_arr = np.frombuffer(img_bytes, np.uint8)
        frame = cv2.imdecode(np_arr, cv2.IMREAD_COLOR)
        if frame is None:
            return {"error": "Invalid image payload - OpenCV decode failed"}

        # Suy luận YOLO
        detection_results = detector(frame, conf=0.3, verbose=False)
        frame_detections = []
        crops_data = []

        for result in detection_results:
            if result.boxes is None:
                continue
            for box in result.boxes:
                x1, y1, x2, y2 = map(int, box.xyxy[0].cpu().numpy())
                conf = float(box.conf[0].cpu().numpy())
                cls_id = int(box.cls[0].cpu().numpy())
                cls_name = detector.names[cls_id]

                if conf > 0.4 and x2 > x1 and y2 > y1:
                    det_info = {
                        "bbox": [x1, y1, x2, y2],
                        "class_name": cls_name,
                        "confidence": conf,
                        "color_class": None,
                        "vis_class": None
                    }
                    frame_detections.append(det_info)

                    if cls_name.lower() == 'player':
                        crop = frame[y1:y2, x1:x2]
                        crops_data.append(crop if crop.size > 0 else None)

        # Suy luận ResNet (giữ nguyên logic cũ)
        if crops_data:
            clf_results = classifier.classify_batch([c for c in crops_data if c is not None])
            crop_idx = 0
            for det in frame_detections:
                if det["class_name"].lower() == 'player' and crop_idx < len(clf_results):
                    c_cls, _, v_cls, _ = clf_results[crop_idx]
                    det["color_class"] = c_cls
                    det["vis_class"] = v_cls
                    crop_idx += 1

        return {"status": "success", "detections": frame_detections}

    except Exception as e:
        import traceback
        return {"error": str(e), "traceback": traceback.format_exc()}
```

## Lỗi gặp phải và Cách khắc phục

| Lỗi / vấn đề | Biểu hiện | Nguyên nhân | Cách khắc phục |
|--------------|-----------|-------------|----------------|
| Azure trả về response 20 bytes | Log hiển thị `200 20`, UI không có bounding box, Inference Time = 0 | `score.py` không xử lý tiền tố `data:image/jpeg;base64,`, gây exception khi decode Base64 | Tách chuỗi Base64 bằng `raw_b64.split(",")[1]` trước khi decode |
| Độ trễ mạng > 2600ms mặc dù inference time ~90ms | UI hiển thị Network Latency rất cao, request đến Azure cách nhau ~3 giây | Định tuyến Trombone: Client (VN) → Vercel (Mỹ) → Azure (HK) → ngược lại. Payload lớn (500KB–1.5MB) làm tăng thời gian truyền | Ép Vercel deploy tại `sin1` (Singapore) bằng `vercel.json`; resize ảnh xuống 640x640 và nén JPEG 0.6; cơ chế pre‑fetch 10% video đầu |
| Frontend không vẽ được bounding box | Box không hiển thị hoặc hiển thị sai vị trí | Contract dữ liệu không khớp: frontend tìm `objects` nhưng backend trả về `detections` và `bbox` là mảng, không có `xmin/ymin/xmax/ymax` | Sửa `app.js`: gán `currentBoundingBoxes = result.detections || []` và vẽ từ `det.bbox[0]`..`det.bbox[3]`, áp dụng scale factor |
| Video giật lag khi gọi API liên tục | Browser bị treo, FPS thấp | Gọi API trong vòng lặp render mà không throttle | Dùng `requestAnimationFrame` cho render, và gọi API tối đa 5 lần/giây (`INFERENCE_INTERVAL`), đồng thời dùng cờ `isApiProcessing` để tránh xếp chồng request |
| Model không detect được đối tượng | Không có detection, mặc dù YOLO chạy tốt | Thiếu chuyển đổi màu BGR ↔ RGB, hoặc input size quá lớn không được resize | Trong `score.py`, dùng `cv2.imdecode` với cờ `IMREAD_COLOR` (BGR); YOLO đã huấn luyện trên BGR nên không cần đổi. Trên frontend, resize ảnh về 640x640 trước khi gửi |

## Lộ trình chi tiết (Sprint 5 ngày, từ 12/08 – 16/08)

| Ngày | Mục tiêu | Chi tiết | Định nghĩa hoàn thành (DoD) |
|------|----------|----------|-----------------------------|
| **Ngày 1 (12/08)** | Monorepo & MLOps CI/CD Foundation | Tái cấu trúc repo thành `/ai-core` và `/web-client`; tạo Azure Service Principal, lưu secrets vào GitHub; viết YAML `azure-ml-deploy.yml` với path filtering | Push thay đổi vào `/ai-core` kích hoạt GitHub Actions tự động deploy lên Azure ML (pipeline chạy ngầm) |
| **Ngày 2 (13/08)** | Web CI/CD & Serverless Proxy (BFF) | Import `/web-client` vào Vercel; viết `api/proxy.js`; nạp biến môi trường AZURE_ML_ENDPOINT, AZURE_ML_KEY trên Vercel Dashboard | Dùng Postman/cURL gửi ảnh Base64 tới `/api/proxy` nhận về JSON tọa độ thành công |
| **Ngày 3 (14/08)** | Core Frontend – Vòng lặp Video & Throttling | Xây dựng HTML/CSS cơ bản; viết `requestAnimationFrame` để render video lên Canvas; cơ chế throttling gọi API 3–5 lần/giây | Video chạy mượt trên Canvas, Network tab ping `/api/proxy` đều đặn không gây crash |
| **Ngày 4 (15/08)** | Data Integration & Bounding Box Rendering | Parse JSON trả về, dùng `ctx.strokeRect` và `ctx.fillText` vẽ box/label; tính Network Latency, Inference Time, Client FPS; xử lý giữ box cũ khi chưa có dữ liệu mới | Luồng end‑to‑end hoàn chỉnh: tải video → phát với bounding box bám sát → telemetry cập nhật liên tục |
| **Ngày 5 (16/08)** | Graceful Degradation & Đóng gói | Xử lý lỗi API (504, 401...) không làm sập trang; tối ưu nén JPEG; hoàn thiện README.md mô tả kiến trúc phân tán; merge code, Vercel deploy xanh 100% | Không có lỗi Unhandled Promise Rejection trên console; tài liệu hoàn chỉnh; hệ thống sẵn sàng demo |

## Các phương án đã cân nhắc

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
|-----------|---------|------------|------------|
| **Monorepo (gộp chung) + Path Filtering** | Một repo duy nhất, dễ quản lý; CI/CD tách biệt nhờ path; gây ấn tượng mạnh với nhà tuyển dụng | Cần cấu hình cẩn thận; nguy cơ chạm biến môi trường nếu không cẩn thận | **Có** |
| **Polyrepo (tách riêng)** | Tách biệt hoàn toàn, pipeline độc lập | Quản lý phiên bản phức tạp, phải clone nhiều repo; không tạo được sức nặng học thuật | **Không** (vì gây phức tạp và không tận dụng được điểm mạnh của monorepo) |
| **Endpoint video đồng bộ** | Gửi toàn bộ video một lần, tiện lợi | Timeout HTTP, băng thông lớn, không real‑time | **Không** (vi phạm nguyên tắc thời gian thực, không phù hợp với sprint hiện tại) |
| **Chỉ dùng endpoint ảnh đơn (Real‑time)** | Tối ưu cho tracking, client tự chia frame; độ trễ thấp | Phải implement logic frontend phức tạp hơn | **Có** |
| **Gọi API không giới hạn (mỗi frame)** | Độ chính xác cao, cập nhật liên tục | Gây quá tải Azure, treo trình duyệt | **Không** (thay vào đó dùng throttling 5 fps và pre‑fetch 10%) |
| **Pre‑fetch 10% video đầu** | Giảm độ trễ cảm nhận, đồng bộ video và bounding box ngay từ giây đầu | Tốn thời gian buffering trước khi phát | **Có** (giúp cải thiện trải nghiệm người dùng khi mạng chậm) |

## Khái niệm & Định nghĩa

| Thuật ngữ | Định nghĩa | Ví dụ trong dự án |
|-----------|------------|-------------------|
| **BFF (Backend for Frontend)** | Lớp trung gian chạy trên server, che giấu API key, xử lý CORS, và chuẩn hóa dữ liệu trước khi gửi đến client | Vercel Serverless Function (`/api/proxy.js`) nhận Base64 từ frontend, gắn Bearer token, gọi Azure ML, trả JSON về client |
| **Path Filtering** | Kỹ thuật trong GitHub Actions chỉ kích hoạt workflow khi file trong thư mục chỉ định bị thay đổi | Chỉ trigger deploy Azure ML khi có commit vào `/ai-core`, không trigger khi sửa frontend |
| **Throttling (Giới hạn tốc độ gọi API)** | Giới hạn số lần gọi API trong một khoảng thời gian để tránh quá tải | Chỉ gọi Azure tối đa 5 lần/giây (`INFERENCE_FPS_LIMIT`) trong khi Canvas render 60 FPS |
| **Pre‑fetch / Buffering** | Gửi trước các request lên server trong lúc video tạm dừng, lưu kết quả vào bộ nhớ để khi phát thì dùng ngay | Buffering 10% đầu video: `buildInitialBuffer()` tua và gửi frame vào buffer, khi phát đến mốc đó thì dùng kết quả có sẵn |
| **Trombone Effect** | Hiện tượng định tuyến dữ liệu đi đường vòng qua nhiều vùng địa lý khác nhau, gây tăng độ trễ | Client (VN) → Vercel (Mỹ) → Azure (HK) → ngược lại, latency lên đến 2680ms |
| **Service Principal (SP)** | Tài khoản robot trong Azure, dùng cho CI/CD để xác thực và có quyền deploy lên tài nguyên | Tạo SP và lưu credentials vào GitHub Secrets để GitHub Actions có thể gọi Azure CLI deploy model |