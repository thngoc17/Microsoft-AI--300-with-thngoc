---
source_url: https://gemini.google.com/app/5236e0c1486bdf52
conversation_date: N/A
context_week: N/A
conversation_types: [LAP_KE_HOACH, TRANH_LUAN_QUYET_DINH, FIX_HA_TANG]
ai300_domains: [Design and implement MLOps infrastructure, Optimize generative AI systems and model performance]
technologies: [Azure ML, YOLO, Vercel, GitHub Actions, GitHub Pages, Azure Functions, Azure Blob Storage, Python, JavaScript, Node.js]
key_decision: "Lựa chọn kiến trúc Serverless Proxy (BFF) trên Vercel thay vì Azure Functions hoặc gọi trực tiếp từ GitHub Pages để giải quyết triệt để rào cản CORS và lộ API Key, đảm bảo an toàn bảo mật trong thời gian 5 ngày."
status: resolved
---

## Bối cảnh & Vấn đề

Người dùng đã deploy thành công mô hình YOLO lên Azure ML Endpoint, endpoint nhận ảnh/video mã hóa base64 và trả về JSON kết quả. Vấn đề đặt ra là làm thế nào để xây dựng một bản demo thuyết phục, trong khi vấp phải các rào cản kỹ thuật sau:

- **Anti-pattern Base64 Video**: Việc gửi toàn bộ video base64 qua HTTP là một anti-pattern, gây phình dữ liệu (33%), dễ dẫn đến lỗi HTTP 413 (Payload Too Large) hoặc 504 (Gateway Timeout).
- **CORS & Bảo mật**: Gọi trực tiếp Azure ML Endpoint từ client-side (trình duyệt) sẽ gặp lỗi CORS và lộ API Key, dẫn đến mất an toàn bảo mật (Secret Leakage).
- **Ràng buộc thời gian**: Cần hoàn thành CI/CD và frontend demo trong 5 ngày.

## Quyết định cuối cùng & Lý do

### Kiến trúc được chọn: Serverless Proxy (BFF - Backend for Frontend) trên Vercel

- **Quy trình**: Client (trình duyệt) gọi API nội bộ `/api/proxy` trên Vercel, Vercel Function sẽ gọi tới Azure ML Endpoint với API Key được lưu trong Environment Variables.
- **Lý do**:
  - **Giải quyết CORS**: Loại bỏ hoàn toàn CORS vì client và proxy cùng domain.
  - **Bảo mật**: API Key được che giấu hoàn toàn ở server-side (Vercel), không bị lộ trên client.
  - **CI/CD tự động**: Vercel tự động build và deploy, giảm tải cấu hình so với Azure Functions.
  - **Phù hợp với ràng buộc thời gian 5 ngày**: Tránh over-engineering, tập trung vào core AI.

### Các phương án bị loại bỏ

| Phương án                                         | Lý do loại bỏ                                                                                                                                                    |
| ------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Gọi trực tiếp Azure ML Endpoint từ client**     | **KHÔNG dùng** vì lộ API Key, gây mất an toàn bảo mật và bị chặn CORS.                                                                                           |
| **GitHub Pages + Azure Functions Proxy**          | **KHÔNG dùng** vì phức tạp, mất thời gian cấu hình (2-3 ngày) và học thêm Azure Functions, không phù hợp với timeline 5 ngày.                                    |
| **Lưu API Key vào GitHub Secrets + inject khi build** | **KHÔNG dùng** vì đây là ngụy biện bảo mật (Security through obscurity). API Key sẽ nằm trong file JS tải xuống client, vẫn có thể xem được qua DevTools (F12). |
| **Cấu trúc Polyrepo (tách riêng Frontend)**       | **KHÔNG dùng** vì sẽ làm phức tạp CI/CD và quản lý versioning so với Monorepo.                                                                                   |

## Lệnh và Cấu hình cụ thể đã dùng

### Cấu trúc thư mục Monorepo (buộc phải tuân thủ)

```plaintext
/yolo-azure-project/
├── .github/
│   └── workflows/
│       ├── azure-ml-deploy.yml          # Pipeline 1: CI/CD cho AI
│       └── vercel-deploy.yml            # Pipeline 2: (Tùy chọn, Vercel tự quản lý)
├── ai-core/                             # Code AI (model training, deployment)
│   ├── training/
│   ├── deployment/
│   │   ├── score.py
│   │   ├── Dockerfile
│   │   └── conda.yml
│   └── data/
└── web-client/                          # Frontend + Serverless Proxy
    ├── api/
    │   └── proxy.js                     # Vercel Serverless Function
    ├── public/
    │   ├── index.html
    │   ├── style.css
    │   └── app.js
    ├── package.json
    └── package-lock.json
```

### CI/CD cho Azure ML (GitHub Actions)

**File: `.github/workflows/azure-ml-deploy.yml`**

```yaml
# Tối quan trọng: Chỉ chạy pipeline AI khi có thay đổi trong thư mục ai-core
on:
  push:
    branches:
      - main
    paths:
      - 'ai-core/**'
      - '.github/workflows/azure-ml-deploy.yml'

jobs:
  deploy-ai-model:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v3

      - name: Login to Azure
        uses: azure/login@v1
        with:
          creds: ${{ secrets.AZURE_CREDENTIALS }}   # Service Principal

      - name: Deploy to Azure ML
        run: |
          # Đăng ký model
          az ml model create --name yolo-model --path ai-core/deployment/
          # Tạo endpoint
          az ml online-deployment create --name yolo-deploy --endpoint yolo-endpoint --model yolo-model --code ai-core/deployment/ --environment azureml:yolo-env@latest
```

### Serverless Proxy (Vercel BFF)

**File: `/web-client/api/proxy.js`**

```javascript
// Lưu ý: AZURE_ML_ENDPOINT và AZURE_ML_KEY được đặt trong Environment Variables của Vercel
const AZURE_ML_ENDPOINT = process.env.AZURE_ML_ENDPOINT;
const AZURE_ML_KEY = process.env.AZURE_ML_KEY;

export default async function handler(req, res) {
  // 1. Nhận dữ liệu (Base64) từ Client
  const { image } = req.body;

  // 2. Gắn API Key vào Header và gửi tới Azure ML
  const response = await fetch(AZURE_ML_ENDPOINT, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${AZURE_ML_KEY}`
    },
    body: JSON.stringify({ image: image })
  });

  // 3. Xử lý lỗi (Try/Catch: Azure timeout, 401, 413, v.v.)
  if (!response.ok) {
    const error = await response.text();
    return res.status(response.status).json({ error: `Azure ML Error: ${error}` });
  }

  // 4. Trả JSON chuẩn hóa về lại Client
  const data = await response.json();
  res.status(200).json(data);
}
```

### Frontend (Core Logic)

**File: `/web-client/public/app.js` (Mã giả)**

```javascript
// 1. Vòng lặp Canvas: Lấy frame từ video và vẽ lên canvas
function renderLoop() {
  ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
  // Vẽ Bounding Box (dựa trên dữ liệu JSON mới nhất)
  if (latestDetections) {
    drawBoundingBoxes(latestDetections);
  }
  requestAnimationFrame(renderLoop);
}

// 2. Cơ chế Throttling: Gửi API 3-5 lần/giây
setInterval(() => {
  const base64Data = canvas.toDataURL('image/jpeg', 0.6); // Nén JPEG
  fetch('/api/proxy', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ image: base64Data })
  })
  .then(response => response.json())
  .then(data => {
    latestDetections = data.objects; // Cập nhật kết quả
    updateTelemetry(data.inference_time, performance.now() - startTime);
  })
  .catch(error => {
    console.error('API Error:', error);
    document.getElementById('status').innerText = 'Azure ML Endpoint Offline';
  });
}, 200); // Gửi mỗi 200ms (5 frames/s)
```

## Lỗi gặp phải và Cách khắc phục

### Lỗi CORS

- **Lỗi**: `Access to fetch at 'https://<azure-endpoint>.azureml.ms' from origin 'https://<username>.github.io' has been blocked by CORS policy.`
- **Nguyên nhân**: Azure ML Endpoint không được cấu hình để trả lời Preflight Request (OPTIONS) từ client-side.
- **Cách khắc phục**: Sử dụng Serverless Proxy (Vercel) làm lớp trung gian, client chỉ gọi tới domain của Vercel, từ server gọi tới Azure (server-to-server), bỏ qua CORS.

### Lộ API Key

- **Lỗi**: API Key hiển thị trong file JavaScript trên trình duyệt, bất kỳ ai cũng có thể lấy được qua DevTools.
- **Nguyên nhân**: Lưu API Key trực tiếp trong code hoặc inject qua biến môi trường trong lúc build nhưng vẫn nằm trong client.
- **Cách khắc phục**: **Tuyệt đối không đưa API Key xuống client**. Lưu trữ API Key trong Environment Variables của Vercel (server-side) và chỉ sử dụng trong Vercel Functions.

### HTTP 413 (Payload Too Large) / 504 (Gateway Timeout)

- **Lỗi**: Gửi toàn bộ video base64 (file lớn) dẫn đến request bị từ chối hoặc timeout.
- **Nguyên nhân**: Gửi cả video base64 trong một request.
- **Cách khắc phục**: Không gửi video, chỉ gửi từng frame (JPEG base64) với tần suất 3-5 lần/giây (throttling). Áp dụng nén ảnh (chất lượng 0.6) để giảm kích thước payload.

## Lộ trình chi tiết (Sprint 5 ngày)

| Ngày    | Tên & Mục tiêu                                                                                                          | Công việc chi tiết                                                                                                                                                                                                                                          | Tiêu chí hoàn thành (Definition of Done)                                                                                                                                                                                                                   |
| ------- | ----------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Ngày 1** | **Monorepo & MLOps CI/CD Foundation** <br> *Thiết lập khung dự án và tự động hóa deploy AI*                             | - Tái cấu trúc repository thành `/ai-core` và `/web-client`.<br>- Tạo Azure Service Principal, lưu thông tin `AZURE_CREDENTIALS` vào GitHub Secrets.<br>- Viết `.github/workflows/azure-ml-deploy.yml` với **Path Filtering** (chỉ trigger khi thay đổi `/ai-core`).<br>- Kiểm tra cấu hình Vercel Root Directory là `/web-client`. | - GitHub Actions tự động kích hoạt deploy AI khi push code vào `/ai-core`.<br>- Vercel trả về trang HTML trắng, không lỗi build.<br>- Postman gọi `/api/proxy` thành công (dù chưa có logic).                                                              |
| **Ngày 2** | **Web CI/CD & Serverless Proxy (BFF)** <br> *Xây dựng lớp bảo mật và kết nối Azure ML*                                  | - Import project vào Vercel.<br>- Code `/web-client/api/proxy.js` (nhận Base64, gọi Azure ML, trả JSON).<br>- Cấu hình Environment Variables (`AZURE_ML_ENDPOINT`, `AZURE_ML_KEY`) trên Vercel.<br>- Bổ sung xử lý lỗi (try/catch) trong proxy.             | - Dùng Postman gửi Base64 ảnh tới `https://<project>.vercel.app/api/proxy` và nhận về JSON tọa độ thành công.<br>- API Key không lộ ra ngoài (kiểm tra log).<br>- Cả AI Pipeline và Web Pipeline hoạt động độc lập.                                         |
| **Ngày 3** | **Core Frontend - Canvas & Cơ chế Throttling** <br> *Giải quyết hiệu năng render và gọi API*                            | - Dựng HTML/CSS: `<video>` ẩn, `<canvas>` hiển thị, bảng Telemetry, nút điều khiển.<br>- Viết `requestAnimationFrame` để render video ra Canvas (60 FPS).<br>- Code logic **Throttling**: gửi base64 lên `/api/proxy` 3-5 lần/giây.                        | - Video chạy mượt trên Canvas (không giật lag).<br>- Network tab trên DevTools thấy trình duyệt gửi request `/api/proxy` đều đặn mà không gây crash.<br>- Không có lỗi memory leak (kiểm tra bằng Task Manager).                                            |
| **Ngày 4** | **Tích hợp Data & Bounding Box Rendering** <br> *Vẽ kết quả lên Canvas và đo lường hiệu năng*                           | - Phân tích JSON trả về, dùng `ctx.strokeRect` và `ctx.fillText` vẽ bounding box và label lên Canvas.<br>- Viết logic giữ bounding box cũ cho đến khi có dữ liệu mới (async handling).<br>- Xây dựng Telemetry Panel: hiển thị Network Latency, Inference Time, Client FPS. | - Video có bounding box bám sát vật thể.<br>- Bảng thông số (latency, inference time, FPS) cập nhật liên tục.<br>- Không có lỗi Unhandled Promise Rejection trong Console.                                                                                 |
| **Ngày 5** | **Graceful Degradation & Đóng gói** <br> *Xử lý ngoại lệ, tối ưu và viết tài liệu*                                      | - Viết xử lý lỗi: API timeout, 401, v.v. Hiển thị thông báo "Syncing..." hoặc "Azure Offline".<br>- Tối ưu nén base64 (chất lượng 0.6).<br>- Viết README.md (kiến trúc Monorepo, Vercel BFF, hướng dẫn local).<br>- Merge toàn bộ code lên nhánh `main`.     | - Hệ thống hoạt động ổn định, không crash khi API lỗi.<br>- Mọi thay đổi trên `main` trigger đúng pipeline (AI deploy Azure, Web deploy Vercel).<br>- Dự án sẵn sàng để demo, tài liệu đầy đủ. |

## Các phương án đã cân nhắc

| Phương án                                                | Ưu điểm                                                                                                | Nhược điểm                                                                                                                              | Được chọn? |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------- | ---------- |
| **Gọi trực tiếp Azure ML (Client-side)**                 | Đơn giản, không cần backend trung gian.                                                                | Lộ API Key, bị chặn CORS, không bảo mật.                                                                                               | ❌          |
| **GitHub Pages + Azure Functions Proxy**                 | Sử dụng hoàn toàn trong hệ sinh thái Azure, đồng bộ hạ tầng.                                           | Phức tạp, mất 2-3 ngày học/cấu hình, không đáp ứng timeline 5 ngày.                                                                    | ❌          |
| **Vercel (Serverless Proxy - BFF)**                      | Giải quyết CORS, bảo mật tuyệt đối, CI/CD tự động, triển khai nhanh (< 3 phút).                        | Không dùng 100% Azure, nhưng đây là trade-off có lợi về thời gian và chi phí.                                                           | ✅          |
| **Monorepo (gộp AI + Web)**                              | Single source of truth, dễ quản lý version, thể hiện tư duy end-to-end.                                | Cần thiết lập Path Filtering để cách ly CI/CD.                                                                                         | ✅          |
| **Polyrepo (tách AI + Web)**                             | Cách ly hoàn toàn repo, tránh conflict.                                                                | Phức tạp trong quản lý CI/CD chéo, khó cho người xem chỉ clone 1 repo.                                                                 | ❌          |
| **Lưu API Key vào GitHub Secrets + inject khi build**    | Có vẻ an toàn vì key không hiển thị trong code.                                                        | **Ngụy biện bảo mật**: Key vẫn bị lộ trên client sau build, ai cũng có thể xem qua DevTools (F12).                                     | ❌          |

