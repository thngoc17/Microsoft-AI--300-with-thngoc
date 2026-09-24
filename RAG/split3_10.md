---
source_url: https://gemini.google.com/app/f109f568262c4025
conversation_date: N/A
context_week: N/A
conversation_types: [FIX_HA_TANG, LY_THUYET, TRANH_LUAN_QUYET_DINH, FIX_CODE]
ai300_domains: ["Không áp dụng trực tiếp (chỉ liên quan phần MLOps infrastructure)"]
technologies: [Vercel, Azure ML, Serverless Functions, JavaScript, HTML/CSS, canvas, Base64, JSON, HTTP, GitHub, CI/CD]
key_decision: "Để fix lỗi 404 trên Vercel khi client gọi /api/proxy, cần đặt thư mục api/ và public/ đúng cấu trúc, chỉnh Root Directory thành web-client, xóa/cấu hình đúng vercel.json, và luôn Redeploy sau khi thay đổi biến môi trường (AZURE_ML_KEY/ENDPOINT)."
status: resolved
---

## Bối cảnh & Vấn đề
- Người dùng triển khai một web client (YOLO tracking bóng đá) lên Vercel, giao tiếp với Azure ML endpoint để inference.
- Gặp lỗi HTTP 404 khi client gọi fetch('/api/proxy') mặc dù code đã có đầy đủ thư mục api/proxy.js và public/app.js.
- Sau khi chỉnh Root Directory trên Vercel, vẫn bị 404 và sau đó còn lỗi liên quan đến biến môi trường (API key thay đổi).

## Quyết định cuối cùng & Lý do
- **Kiến trúc**: Sử dụng mô hình 3 lớp: Client (frontend tĩnh) → Serverless Proxy (Vercel function) → Azure ML Endpoint. **KHÔNG** gọi trực tiếp Azure từ client vì lộ API key (bảo mật).
- **Cấu trúc thư mục**: Đặt thư mục `api/` và `public/` ngang hàng ở root của dự án (sau khi đã đặt root directory là web-client). Cụ thể:
  ```
  / (Root Project)
    index.html (nằm trong public/)
    app.js (nằm trong public/)
    style.css (nằm trong public/)
    api/
      proxy.js
  ```
- **Root Directory trên Vercel**: Đặt là `web-client` (vì toàn bộ mã web nằm trong thư mục đó).
- **Biến môi trường**: Khai báo `AZURE_ML_ENDPOINT` và `AZURE_ML_KEY` trên Vercel Dashboard (Settings → Environment Variables), **không** dùng file .env local (không được Vercel tự động đọc và có nguy cơ rò rỉ).
- **Redeploy bắt buộc**: Sau bất kỳ thay đổi cấu hình (root directory, env vars, vercel.json), phải Redeploy để áp dụng.

**Các phương án bị loại bỏ**:
- **Gọi trực tiếp Azure từ client**: KHÔNG dùng vì lộ API Key, vi phạm bảo mật (CWE-312).
- **Chỉ sửa file .env local và push lên GitHub**: KHÔNG dùng vì Vercel production không đọc .env, chỉ dùng biến môi trường cấu hình trên Dashboard.
- **Giữ nguyên vercel.json tùy chỉnh**: KHÔNG dùng nếu chưa kiểm tra kỹ; có thể override routing gây 404. Nên tạm xóa hoặc dùng cấu hình zero-config.

## Lệnh và Cấu hình cụ thể đã dùng

### Cấu trúc thư mục dự án (sau khi sửa)
```text
/web-client/
  public/
    index.html
    app.js
    style.css
  api/
    proxy.js
  package.json (nếu có)
  vercel.json (tùy chọn, nếu dùng phải đúng)
```

### Nội dung proxy.js (trích dẫn theo cuộc hội thoại)
```javascript
// File api/proxy.js
// ... (giới hạn body 4MB, chỉ nhận POST)
// Trích xuất image từ payload, gắn header AZURE_ML_KEY, forward đến AZURE_ML_ENDPOINT
// Trả về flatten JSON bao gồm detections và telemetry
```
(Lưu ý: file gốc không hiển thị đầy đủ, nhưng cấu trúc được mô tả trong response.)

### Cấu hình Root Directory trên Vercel
- Dashboard → Project → Settings → General → Root Directory: `web-client`

### Biến môi trường cần khai báo
```env
AZURE_ML_ENDPOINT=<url_endpoint>
AZURE_ML_KEY=<api_key_mới>
```

## Lỗi gặp phải và Cách khắc phục

| Lỗi | Nguyên nhân | Cách fix |
|-----|-------------|----------|
| HTTP 404 trên /api/proxy | Thư mục `api/` không nằm đúng root directory của Vercel; hoặc vercel.json override route. | Đặt root directory thành `web-client`; kiểm tra/xóa vercel.json; redeploy. |
| HTTP 404 tiếp diễn sau khi sửa root | Thay đổi root directory không áp dụng hồi tố cho deployment đang chạy (tính bất biến). | Redeploy (bấm Redeploy trên dashboard hoặc push commit mới). |
| HTTP 500 (Internal Server Error) | Thiếu biến môi trường AZURE_ML_ENDPOINT hoặc AZURE_ML_KEY (vì .env không được tự động đọc trên Vercel). | Thêm biến môi trường trên Dashboard → Environment Variables, sau đó Redeploy. |
| HTTP 401 (Unauthorized) | API key đã bị thay đổi trên Azure nhưng chưa cập nhật trong Vercel. | Cập nhật giá trị AZURE_ML_KEY trên Dashboard → Redeploy. |

**Quy tắc chung**:
- Không commit file `.env` lên GitHub (thêm vào .gitignore).
- Mỗi khi thay đổi biến môi trường hoặc cấu trúc thư mục, **phải Redeploy**.
- Theo dõi logs trên Vercel Dashboard (tab Logs) để đọc chi tiết lỗi, không chỉ dựa vào HTTP status.

## Khái niệm & Định nghĩa 

- **Serverless Proxy**: Hàm serverless (Vercel Function) đóng vai trò trung gian, giữ API key an toàn, chuyển request từ client đến Azure ML và trả kết quả về.
- **Tính bất biến của deployment (Deployment Immutability)**: Mỗi bản deployment là cố định; thay đổi cấu hình không tự động áp dụng cho bản đang chạy, cần redeploy để tạo bản mới.
- **Throttling (client)**: Giới hạn tần suất gọi API (5 FPS) để tránh quá tải, sử dụng cờ `isApiProcessing`.
- **Downscaling ảnh**: Client thu nhỏ frame xuống ≤ 640px chiều rộng, nén JPEG chất lượng 60%, serialize thành Base64 để giảm payload.
- **Định tuyến tĩnh trên Vercel**: Thư mục `public/` được serve tĩnh ở root URL, `api/` được dùng cho serverless functions.

## Các phương án đã cân nhắc

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
|-----------|---------|------------|------------|
| Client gọi trực tiếp Azure ML | Đơn giản, ít thành phần | Lộ API key trên trình duyệt (mất an toàn) | KHÔNG |
| Sử dụng Vercel Serverless Proxy | An toàn, dễ triển khai, phù hợp với mô hình 3 lớp | Tăng chi phí (Vercel function), cần cấu hình thêm | CÓ |
| Đặt toàn bộ mã web trong thư mục con `web-client` và không chỉnh root | Không cần thay đổi cấu trúc repo | Vercel không nhận diện route /api/* → 404 | KHÔNG (phải chỉnh root) |
| Sử dụng file `.env` local và push lên GitHub | Tiện lợi, dễ quản lý | Rò rỉ key nếu commit; Vercel không đọc file .env | KHÔNG |
| Cập nhật biến môi trường trên Dashboard mà không Redeploy | Nhanh, không mất thời gian build | Không áp dụng được cho bản deployment hiện tại | KHÔNG (cần Redeploy) |

**Tiêu chí quyết định**: Bảo mật (không lộ key), khả năng hoạt động trên Vercel, tuân thủ cơ chế serverless.