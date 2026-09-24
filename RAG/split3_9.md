---
source_url: https://gemini.google.com/app/d86dc017f9101780
conversation_date: 2026-08-12
context_week: N/A
conversation_types: [LAP_KE_HOACH, TRANH_LUAN_QUYET_DINH, FIX_HA_TANG, FIX_CODE, LY_THUYET]
ai300_domains: [Design and implement MLOps infrastructure, Model lifecycle]
technologies: [Azure ML, Vercel, GitHub Actions, Node.js, YOLO, PowerShell, Azure CLI, Service Principal, Serverless Functions]
key_decision: "Quyết định xây dựng kiến trúc Monorepo với Path Filtering để cách ly CI/CD, sử dụng Vercel làm BFF (Backend for Frontend) thay vì Polyrepo hay Monolithic Pipeline nhằm tối ưu chi phí deploy và bảo mật API Key."
status: resolved
---

## Bối cảnh & Vấn đề

Người dùng đang phát triển một hệ thống demo nhận diện vật thể (YOLO) đã được train và deploy thành công lên Azure ML. Nhiệm vụ đặt ra là xây dựng một luồng end-to-end trong vòng 5 ngày, bao gồm:

-   Triển khai CI/CD cho toàn bộ hệ thống (AI và Frontend).
-   Xây dựng Frontend (Canvas/Video) có đủ tính năng.
-   Cấu hình dự án một cách chuyên nghiệp và đầy đủ.
-   Tích hợp Frontend với Backend (Frame/Video) đã có sẵn.
-   **Vấn đề nhận định ban đầu:** Người dùng cho rằng "gộp chung (Monorepo) thì luồng CI/CD mới rõ ràng". Quan điểm này bị phản biện vì tiềm ẩn nguy cơ tạo ra Monolithic Pipeline gây lãng phí tài nguyên.
-   **Thiếu sót:** Sprint ban đầu bỏ qua CI/CD cho hạ tầng AI, tập trung vào Frontend là chủ yếu.

## Quyết định cuối cùng & Lý do

1.  **Kiến trúc Repository:** Quyết định **Gộp chung (Monorepo)** thay vì tách riêng (Polyrepo).
    -   **Lý do:** Tạo một "Single Source of Truth" cho nhà tuyển dụng, thể hiện toàn bộ năng lực AI và Software Engineering trong một repo. Dễ dàng trình bày tổng quan hệ thống.
    -   **Điều kiện bắt buộc:** Phải thiết lập **Cách ly Pipeline (Pipeline Isolation)** bằng kỹ thuật Path Filtering trong GitHub Actions để tránh lãng phí tài nguyên.
    -   **Phương án bị loại bỏ (Polyrepo):** KHÔNG chọn tách riêng vì sẽ làm phức tạp việc quản lý và trình diễn cho nhà tuyển dụng, dù có ưu điểm về mặt DevOps thuần túy.

2.  **Kiến trúc Frontend (BFF):** Sử dụng **Vercel** làm lớp BFF (Backend for Frontend) với Serverless Functions.
    -   **Lý do:** Cung cấp buffer về thời gian, vượt qua CORS, giấu API Key của Azure ML, và tự động quản lý CI/CD cho Frontend.
    -   **Phương án bị loại bỏ:** KHÔNG gọi trực tiếp API Azure ML từ Client vì sẽ lộ Key và gặp lỗi CORS.

3.  **CI/CD cho AI:** Tự động hóa deployment lên Azure ML bằng GitHub Actions và Azure Service Principal.
    -   **Lý do:** Đảm bảo mỗi lần thay đổi code trong `ai-core` đều được deploy lên Cloud một cách tự động và nhất quán, đúng chuẩn MLOps.

4.  **Cấu hình Vercel:** Chọn preset **"Other"** khi liên kết dự án.
    -   **Lý do:** Dự án sử dụng HTML, CSS, Vanilla JS thuần, không có framework build (React/Vue). Chọn "Other" để Vercel không cố gắng chạy `npm run build` (không tồn tại) và gây lỗi.

## 3. Lệnh và Cấu hình cụ thể đã dùng

### Tái cấu trúc Monorepo (Ngày 1)

```bash
# Di chuyển vào thư mục gốc và tạo cấu trúc
mkdir ai-core
mkdir web-client

# Di chuyển toàn bộ code hiện tại vào ai-core (cẩn thận tránh di chuyển .git, .github)
mv * ai-core/
```

### Tạo Service Principal (Ngày 1)

```bash
# Đăng nhập Azure
az login

# Lấy Subscription ID
az account show --query id -o tsv

# Tạo Service Principal
az ad sp create-for-rbac --name "github-actions-yolo-deploy" --role contributor \
  --scopes /subscriptions/<SUBSCRIPTION_ID>/resourceGroups/<RESOURCE_GROUP_NAME> \
  --sdk-auth
```

> Lưu ý: Copy toàn bộ chuỗi JSON trả về và lưu vào GitHub Secret với tên `AZURE_CREDENTIALS`.

### Pipeline MLOps (YAML - Ngày 1)

File: `.github/workflows/azure-ml-deploy.yml`

```yaml
name: YOLO MLOps Pipeline

on:
  push:
    branches:
      - main
    paths:
      - 'ai-core/**'                 # TỐI QUAN TRỌNG: Chỉ chạy khi thay đổi trong ai-core
      - '.github/workflows/azure-ml-deploy.yml'

jobs:
  deploy-yolo-model:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Source Code
        uses: actions/checkout@v3

      - name: Azure Login
        uses: azure/login@v1
        with:
          creds: ${{ secrets.AZURE_CREDENTIALS }}

      - name: Install Azure ML CLI v2
        run: az extension add -n ml -y

      - name: Set Default Workspace
        # Thay thế YOUR_WORKSPACE và YOUR_RESOURCE_GROUP
        run: |
          az configure --defaults workspace=YOUR_WORKSPACE group=YOUR_RESOURCE_GROUP

      - name: Deploy Model to Online Endpoint
        run: az ml online-deployment create -f ai-core/deployment.yml --all-traffic
```

### Cấu hình Vercel (Ngày 2)

File: `web-client/package.json`

```json
{
  "name": "yolo-web-client",
  "version": "1.0.0",
  "description": "Frontend and BFF Proxy for YOLO Azure ML",
  "scripts": {
    "dev": "vercel dev"
  },
  "dependencies": {}
}
```

File: `web-client/.env.local` (KHÔNG commit lên Git)

```
AZURE_ML_ENDPOINT=https://<ten-endpoint-cua-ban>.region.inference.ml.azure.com/score
AZURE_ML_KEY=chuoI-khoa-api-cua-ban
```

### Mã nguồn Proxy (BFF - Ngày 2)

File: `web-client/api/proxy.js`

```javascript
export const config = {
  api: {
    bodyParser: {
      sizeLimit: '4mb',
    }
  }
}

export default async function handler(req, res) {
  if (req.method != 'POST') {
    return res.status(405).json({ error: 'Method Not Allowed' });
  }

  const azureEndpoint = process.env.AZURE_ML_ENDPOINT;
  const azureApiKey = process.env.AZURE_ML_KEY;

  // Kiểm tra cấu hình server
  if (!azureEndpoint || !azureApiKey) {
    return res.status(500).json({ error: 'Server configuration error' });
  }

  try {
    const { image } = req.body;
    if (!image) {
      return res.status(400).json({ error: 'No image data provided' });
    }

    const azurePayload = {
      "input_data": {
        "columns": ["image"],
        "data": [image]
      }
    };

    const startTime = Date.now();
    const response = await fetch(azureEndpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${azureApiKey}`
      },
      body: JSON.stringify(azurePayload)
    });
    const inferenceTime = Date.now() - startTime;

    if (!response.ok) {
      const errorText = await response.text();
      console.error(`Azure ML Error (${response.status}):`, errorText);
      return res.status(response.status).json({
        error: 'Inference failed on Azure ML',
        details: response.status === 401 ? 'Unauthorized' : 'Gateway Timeout/Error'
      });
    }

    const azureData = await response.json();
    return res.status(200).json({
      success: true,
      data: azureData,
      telemetry: {
        inference_ms: inferenceTime
      }
    });

  } catch (error) {
    console.error("Proxy execution error:", error);
    return res.status(500).json({ error: 'Internal Server Error processing request' });
  }
}
```

### Cấu hình Vercel CLI (Trả lời trên terminal)

| Vercel CLI Prompt | Lựa chọn / Phím gõ | Giải thích kỹ thuật |
|---|---|---|
| `Set up and deploy "~/path/to/web-client"?` | `Y` | Xác nhận thư mục hiện tại. |
| `Which scope do you want to deploy to?` | `[Enter]` | Giữ mặc định tài khoản cá nhân. |
| `Link to existing project?` | `N` | Đây là dự án mới. |
| `What's your project's name?` | `yolo-web-client` | Tên định danh dự án. |
| `In which directory is your code located?` | `[Enter]` (./) | Giữ thư mục gốc của web-client. |
| `Want to override the settings?` | `N` | Để Vercel tự động phát hiện "Other". |

### Frontend Core Logic (Ngày 3)

File: `web-client/public/app.js` (Trích đoạn chính)

```javascript
// ... Biến, State, Upload, Play/Pause ...

// VÒNG LẬP ĐỒ HỌA (60 FPS)
let lastFrameTime = performance.now();
function renderLoop() {
  if (!isPlaying) return;

  const now = performance.now();
  fpsDisplay.innerHTML = Math.round(1000 / (now - lastFrameTime));
  lastFrameTime = now;

  // Vẽ khung hình hiện tại lên canvas
  ctx.drawImage(video, 0, 0, canvas.width, canvas.height);

  // Kích hoạt luồng AI (chỉ gọi khi request trước đó đã xong)
  triggerInference();

  // Vẽ Bounding Boxes (dùng dữ liệu cũ)
  drawBoundingBoxes();

  requestAnimationFrame(renderLoop);
}

// LUỒNG GỌI API (Throttling)
async function triggerInference() {
  if (isInferencing) return; // Khóa chống ngập lụt
  isInferencing = true;

  // Nén chất lượng xuống 0.5 để giảm kích thước payload
  const base64Image = canvas.toDataURL('image/jpeg', 0.5);
  const fetchStart = performance.now();

  try {
    const response = await fetch('/api/proxy', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ image: base64Image })
    });

    if (response.ok) {
      const result = await response.json();
      currentBoundingBoxes = result.data || [];
      latencyDisplay.innerText = Math.round(performance.now() - fetchStart);
      if(result.telemetry) inferenceDisplay.innerText = Math.round(result.telemetry.inference_ms);
    }
  } catch (error) {
    console.error("Network Fetch Error:", error);
  } finally {
    isInferencing = false;
  }
}
```

## Lỗi gặp phải và Cách khắc phục

1.  **Lỗi 1: `cd: web-client/: No such file or directory`**
    -   **Nguyên nhân:** Đứng ở thư mục gốc, cố gắng `cd` vào `web-client` nhưng terminal đã ở trong thư mục đó.
    -   **Cách khắc phục:** Đây là lỗi thao tác, không ảnh hưởng. Cần xác định chính xác vị trí terminal để chạy lệnh.

2.  **Lỗi 2: `Error: 'vercel dev' must not recursively invoke itself.`**
    -   **Nguyên nhân:** Trong `package.json`, script `"dev": "vercel dev"` khiến Vercel CLI đọc lại `package.json` và tự gọi chính nó, tạo vòng lặp vô tận.
    -   **Cách khắc phục:**
        -   Sửa lại `package.json` (xóa script `dev` hoặc đổi thành `"start": "node"`).
        -   Gọi trực tiếp lệnh `vercel dev` từ terminal thay vì dùng `npm run dev`.

3.  **Lỗi 3: `{“error”: “Internal Server Error processing request”}` (HTTP 500)**
    -   **Nguyên nhân 1 (Môi trường):** Thiếu biến môi trường `AZURE_ML_ENDPOINT` và `AZURE_ML_KEY` ở local. Vercel dev server không tự động lấy từ Cloud xuống.
        -   **Cách khắc phục:** Tạo file `.env.local` trong `web-client` chứa 2 biến này và khởi động lại server.
    -   **Nguyên nhân 2 (Cú pháp):** Lệnh `curl.exe` trên PowerShell làm hỏng cấu trúc JSON payload.
        -   **Cách khắc phục:** Sử dụng `Invoke-RestMethod` thay vì `curl.exe` trên Windows để test.
        ```powershell
        Invoke-RestMethod -Uri "http://localhost:3000/api/proxy" -Method Post `
          -ContentType "application/json" -Body '{"image": "data:image/jpeg;base64,..."}'
        ```

4.  **Lỗi 4: `Azure ML Error (404): No valid deployments to route to.`**
    -   **Nguyên nhân:** Endpoint Azure ML không có deployment nào được gán lưu lượng truy cập (traffic weight = 0%).
    -   **Cách khắc phục:** Dùng Azure CLI để cập nhật traffic cho deployment.
        ```bash
        az ml online-endpoint update --name <ten-endpoint-cua-ban> --traffic "<ten-deployment-cua-ban>=100"
        ```

5.  **Lỗi 5: `ApiError: Invalid JSON`**
    -   **Nguyên nhân:** Payload gửi lên bị hỏng do copy/paste hoặc lỗi cú pháp PowerShell.
    -   **Cách khắc phục:** Kiểm tra kỹ chuỗi JSON, đảm bảo dùng dấu nháy kép (`"`) đúng chuẩn. Không dùng dấu ngoặc kép Unicode thông minh (`“` và `”`).

## Lộ trình chi tiết (Sprint 5 ngày)

| Ngày | Mục tiêu | Công việc cụ thể | Tiêu chuẩn nghiệm thu (DoD) |
|---|---|---|---|
| **Ngày 1** (12/08) | **Monorepo & MLOps CI/CD Foundation** | - Tái cấu trúc thư mục thành `/ai-core` và `/web-client`.<br>- Cập nhật đường dẫn trong các file cấu hình (code: `./ai-core`).<br>- Tạo Azure Service Principal và lưu vào GitHub Secrets (`AZURE_CREDENTIALS`).<br>- Viết workflow GitHub Actions (`.github/workflows/azure-ml-deploy.yml`) với Path Filtering (`paths: 'ai-core/**'`). | - Push code lên main, GitHub Actions kích hoạt và vượt qua bước "Azure Login".<br>- (Pipeline AI có thể đang chạy, không cần đợi). |
| **Ngày 2** (13/08) | **Web CI/CD & Serverless Proxy (BFF)** | - Khởi tạo Vercel với thư mục `/web-client` (chọn preset "Other").<br>- Code file `/web-client/api/proxy.js` với xử lý lỗi và telemetry.<br>- Nạp biến môi trường `AZURE_ML_ENDPOINT` và `AZURE_ML_KEY` vào Vercel. | - Dùng Postman/cURL (hoặc `Invoke-RestMethod`) gửi payload test vào `/api/proxy`, nhận về JSON thành công (dù là lỗi 400 từ Azure cũng OK vì đã chạm được tới model). |
| **Ngày 3** (14/08) | **Core Frontend - Vòng lập Video & Throttling** | - Xây dựng UI: `<video>` ẩn, `<canvas>`, bảng điều khiển (Play/Pause/Upload), Telemetry.<br>- Viết `renderLoop` với `requestAnimationFrame`.<br>- Viết cơ chế Throttling (`isInferencing`) để gọi API `/api/proxy` 3-5 lần/giây. | - Video chạy mượt trên Canvas.<br>- Network tab thấy các request `/api/proxy` đều đặn, không gây giật lag. |
| **Ngày 4** (15/08) | **Data Integration & Bounding Box Rendering** | - Phân tích JSON trả về từ Proxy, vẽ Bounding Box lên Canvas (`ctx.strokeRect`, `ctx.fillText`).<br>- Đảm bảo giữ Bounding Box cũ cho đến khi có dữ liệu mới.<br>- Cập nhật Telemetry (Inference Time, Network Latency, FPS). | - Luồng End-to-End hoàn chỉnh: Video phát, Bounding Box bám sát vật thể, Telemetry nhảy số liên tục. |
| **Ngày 5** (16/08) | **Graceful Degradation & Đóng gói** | - Xử lý lỗi API (Timeout, 401, 500) để UI không bị sập.<br>- Tối ưu Base64 (nén xuống chất lượng 0.6-0.7).<br>- Hoàn thiện `README.md` (sơ đồ kiến trúc, hướng dẫn). | - Mã nguồn merge vào `main`, Vercel deploy xanh.<br>- Không có lỗi Unhandled Promise Rejection trên console. |

## Các phương án đã cân nhắc

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
|---|---|---|---|
| **Polyrepo** (tách riêng AI và Web) | - Cách ly CI/CD triệt để nhất.<br>- Mỗi repo có vòng đời riêng. | - Phức tạp khi trình diễn (clone 2 repo).<br>- Khó quản lý version và tích hợp. | **KHÔNG** (vì khó trình diễn năng lực tổng thể cho nhà tuyển dụng). |
| **Monorepo (không cách ly CI/CD)** | - Dễ quản lý, một nguồn chân lý. | - Tạo Monolithic Pipeline: Thay đổi CSS trigger deploy model nặng hàng GB. | **KHÔNG** (vì lãng phí tài nguyên và thời gian). |
| **Monorepo + Path Filtering** | - Dễ quản lý, một nguồn chân lý.<br>- Cách ly CI/CD bằng Path Filtering. | - Cần cấu hình cẩn thận để tránh xung đột. | **CÓ** (đây là quyết định cuối cùng). |
| **Gọi trực tiếp Azure ML từ Frontend** | - Đơn giản, không cần Proxy. | - Lộ API Key.<br>- Gặp lỗi CORS. | **KHÔNG** (vì mất an toàn bảo mật). |
| **Vercel Serverless Proxy (BFF)** | - Giấu API Key.<br>- Xử lý CORS.<br>- Tự động CI/CD. | - Thêm một lớp trung gian (tăng nhẹ latency). | **CÓ** (quyết định chiến lược cho dự án). |
