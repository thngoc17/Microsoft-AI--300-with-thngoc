---
source_url: "https://gemini.google.com/app/10ebafda50814a03"
conversation_date: "2026-08-09"
context_week: "N/A"
conversation_types: [FIX_HA_TANG, TRANH_LUAN_QUYET_DINH]
ai300_domains: ["Design and implement MLOps infrastructure", "Model lifecycle"]
technologies: [Azure ML, Azure CLI, YOLO, Docker, Azure Container Registry, Standard_B2s, Standard_DS3_v2, Standard_NC4as_T4_v3, OpenCV, FastAPI, Python]
key_decision: "Xóa deployment yolo-deployment-ver1 bị lỗi unrecoverable, nâng cấp instance_type từ Standard_B2s lên Standard_DS3_v2, sửa scoring_route từ /chat sang /score, và tạo lại deployment để khắc phục lỗi InternalServerError khi khởi tạo."
status: "resolved"
---

## Bối cảnh & Vấn đề

Quá trình triển khai mô hình YOLO (`football-tracking-ensemble`) lên Azure ML Online Endpoint thất bại với lỗi `InternalServerError`. Người dùng đã thực hiện các lệnh CLI mà không kiểm tra trạng thái tài nguyên, dẫn đến trạng thái deployment bị corrupt. Vấn đề được xác định nằm ở hai điểm chính: **cấu hình tài nguyên (instance_type) quá thấp** và **cấu hình routing sai lệch** giữa container và Azure ML.

## Quyết định cuối cùng & Lý do

**Quyết định cuối cùng:** Xóa bỏ deployment đang ở trạng thái lỗi, sửa đổi file cấu hình `deployment.yml` để nâng cấp tài nguyên và sửa routing, sau đó tạo deployment mới.

- **KHÔNG dùng** `az ml online-deployment update` trên deployment đã thất bại. **Lý do:** Azure ML Control Plane không cho phép cập nhật (update) một deployment đang ở trạng thái `Failed` (unrecoverable). Lệnh `update` trả về lỗi 400 BadRequest với message rõ ràng: *"Specified deployment [yolo-deployment-ver1] failed during initial provisioning and is in an unrecoverable state. Delete and re-create."*

- **KHÔNG dùng** `instance_type: Standard_B2s` hoặc `Standard_B2ms` cho mô hình YOLO. **Lý do:** Đây là máy ảo Burstable, dựa trên cơ chế CPU Credit. Quá trình load model YOLO (với PyTorch, OpenCV) yêu cầu tài nguyên tính toán liên tục và cao, sẽ nhanh chóng vắt kiệt CPU Credit, dẫn đến throttling và timeout khi khởi động. Kết quả là deployment rơi vào trạng thái `Failed`.

- **KHÔNG dùng** routing path `/chat` nếu API container không implement endpoint đó. **Lý do:** Azure ML sử dụng `liveness_route` và `readiness_route` để kiểm tra sức khỏe container. Nếu path không tồn tại, container sẽ bị coi là không sẵn sàng và bị khởi động lại liên tục (CrashLoopBackOff), dẫn đến lỗi `InternalServerError` khi khởi tạo.

## Lệnh và Cấu hình cụ thể đã dùng

**Lệnh tạo deployment bị lỗi ban đầu:**
```powershell
az ml online-deployment create --file config/deployment.yml --resource-group CV-YOLO-rg --workspace-name mlops-workspace
```

**Lệnh update sai cách đã thực hiện:**
```powershell
az ml online-deployment update --file config/deployment.yml --resource-group CV-YOLO-rg --workspace-name mlops-workspace --debug
```

**File cấu hình `config/deployment.yml` mẫu, chỉ ra các điểm sai (dựa trên log và phân tích):**
```yaml
# config/deployment.yml (Cấu hình ban đầu có lỗi)
name: yolo-deployment-ver1
endpoint_name: yolo-endpoint-ver1
model: azureml:football-tracking-ensemble:1
environment:
  image: acrthngoc17cv.azurecr.io/tracking-api:v1
  inference_config:
    liveness_route:
      port: 31311
      path: /docs
    readiness_route:
      port: 31311
      path: /docs
    scoring_route:
      port: 31311
      path: /chat   # <--- LỖI 1: Sai routing. Container được build với API FastAPI có lẽ không có endpoint /chat
instance_type: Standard_B2s # <--- LỖI 2: Tài nguyên quá thấp (Burstable)
```

**File cấu hình đã sửa theo khuyến nghị:**
```yaml
# config/deployment.yml (Cấu hình đã sửa)
name: yolo-deployment-ver1
endpoint_name: yolo-endpoint-ver1
model: azureml:football-tracking-ensemble:1
environment:
  image: acrthngoc17cv.azurecr.io/tracking-api:v1
  inference_config:
    liveness_route:
      port: 31311
      path: /docs      # Đảm bảo container thực sự có API docs tại /docs
    readiness_route:
      port: 31311
      path: /docs
    scoring_route:
      port: 31311
      path: /score     # Đã sửa từ /chat sang /score (phù hợp với ứng dụng CV inference thông thường)
request_settings:
  request_timeout_ms: 180000 # Tăng timeout để tránh lỗi khi model tải lâu
instance_type: Standard_DS3_v2 # NÂNG CẤP: 4 vCPU, 14GB RAM (ổn định, không burst)
instance_count: 1
```

**Lệnh xóa deployment bị corrupt:**
```powershell
az ml online-deployment delete --name yolo-deployment-ver1 --endpoint-name yolo-endpoint-ver1 --resource-group CV-YOLO-rg --workspace-name mlops-workspace
```

**Lệnh tạo lại deployment sau khi đã sửa:**
```powershell
az ml online-deployment create --file config/deployment.yml --resource-group CV-YOLO-rg --workspace-name mlops-workspace
```

**Lệnh lấy log container (dùng để gỡ lỗi nếu deployment vẫn thất bại):**
```powershell
az ml online-deployment get-logs --name yolo-deployment-ver1 --endpoint-name yolo-endpoint-ver1 --resource-group CV-YOLO-rg --workspace-name mlops-workspace
```

## Lỗi gặp phải và Cách khắc phục

- **Lỗi 1:** `InternalServerError` (HTTP 500)
    - **Nguyên nhân:** Người dùng chạy `create` nhưng deployment đã tồn tại. Sau đó chạy `update` nhưng deployment đang ở trạng thái `Failed`, không thể cập nhật được.
    - **Cách khắc phục:** Không update deployment đã fail. Luôn kiểm tra trạng thái tài nguyên trước khi thao tác. Nếu deployment ở trạng thái `Failed`, bắt buộc phải xóa và tạo mới.

- **Lỗi 2:** `HttpResponseError: (BadRequest) ... Specified deployment [yolo-deployment-ver1] failed during initial provisioning and is in an unrecoverable state. Delete and re-create.`
    - **Nguyên nhân:** Deployment đầu tiên đã thất bại ở tầng provisioning (có thể do OOM, timeout, hoặc lỗi container).
    - **Cách khắc phục:** Thực hiện lệnh `az ml online-deployment delete` để xóa tài nguyên rác, sau đó sửa file YAML và tạo lại.

- **Lỗi 3 (Nguyên nhân gốc rễ):** `Operation failed or canceled` sau 92 giây khi tạo deployment.
    - **Nguyên nhân:** `instance_type: Standard_B2s` quá yếu cho mô hình Computer Vision (YOLO). Quá trình tải model và khởi động server vượt quá giới hạn tài nguyên của máy ảo Burstable, dẫn đến quá trình khởi tạo bị treo và Azure đánh dấu thất bại sau timeout.
    - **Cách khắc phục:** Thay đổi `instance_type` thành một SKU mạnh hơn. Khuyến nghị tối thiểu `Standard_DS3_v2` (4 vCPU, 14GB RAM) cho CPU testing, hoặc `Standard_NC4as_T4_v3` (GPU) cho production. Tránh sử dụng dòng `B-series` cho các tác vụ đòi hỏi CPU liên tục.

- **Lỗi 4 (Nguyên nhân tiềm ẩn):** Routing mismatch (ví dụ: `scoring_route: /chat` không tồn tại).
    - **Nguyên nhân:** Azure ML gửi yêu cầu liveness/readiness probe đến các route đã cấu hình. Nếu route không tồn tại, container không thể trở thành "Ready", và deployment sẽ thất bại.
    - **Cách khắc phục:** Đảm bảo `path` trong `liveness_route`, `readiness_route`, và `scoring_route` khớp với các endpoint thực tế đã được code trong ứng dụng FastAPI/Flask bên trong container.

## Các phương án đã cân nhắc

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
| :--- | :--- | :--- | :--- |
| **Sử dụng `az ml online-deployment update`** | Nhanh, tiết kiệm thời gian, không cần xóa tài nguyên. | Không thể áp dụng cho deployment đang ở trạng thái `Failed`. Azure trả về lỗi `BadRequest` và từ chối. | **KHÔNG** (ĐÃ LOẠI BỎ). Lý do: Hệ thống yêu cầu phải xóa và tạo lại vì trạng thái deployment là unrecoverable. |
| **Sử dụng CPU Instance (Standard_B2s)** | Chi phí thấp, phù hợp với tác vụ nhẹ. | Quá yếu cho mô hình YOLO. CPU Credit bị cạn kiệt nhanh chóng, gây timeout và failed deployment. | **KHÔNG** (ĐÃ LOẠI BỎ). Lý do: Không đủ tài nguyên (RAM và CPU baseline) để load model và khởi tạo thành công. |
| **Sử dụng CPU Instance (Standard_DS3_v2 / Standard_F4s_v2)** | Chi phí vừa phải, tài nguyên ổn định (dedicated vCPU), đủ RAM (8-14GB) để load model YOLO và dependencies. | Không có GPU, inference chậm hơn so với GPU. | **CÓ**, như một bước testing hoặc tiết kiệm chi phí. Được khuyến nghị để xác nhận deployment thành công trước khi nâng cấp lên GPU. |
| **Sử dụng GPU Instance (Standard_NC4as_T4_v3)** | Hiệu suất inference cao, tối ưu cho YOLO. | Chi phí cao. | **CÓ**, được đề xuất cho môi trường Production. |
