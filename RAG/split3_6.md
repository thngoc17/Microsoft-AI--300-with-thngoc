---
source_url: https://gemini.google.com/app/8f1680df6ebdfd35
conversation_date: 2026-09-01
context_week: N/A
conversation_types: [FIX_HA_TANG, TRANH_LUAN_QUYET_DINH, LY_THUYET]
ai300_domains: ["Thiết kế và triển khai hạ tầng MLOps"]
technologies: [Azure ML, Azure Container Registry (ACR), Docker, YOLO, PyTorch, OpenCV, RBAC, Managed Identity, CLI, YAML, B-series VM, D-series VM]
key_decision: "Không sử dụng Standard_B2ms vì thiếu quota và giới hạn vật lý (disk/IOPS); chọn Standard_D2as_v4 và tạo Endpoint trước Deployment để tránh lỗi ResourceNotFound."
status: resolved
---

## Bối cảnh & Vấn đề
User gặp lỗi "Internal Error" khi triển khai container (Docker image chứa model YOLO tracking bóng đá) lên Azure Managed Online Endpoint. Container sập ngay sau khi triển khai, không có log ứng dụng (Application logs), CPU/RAM utilization hiển thị 0%. Trên local (Windows) container chạy thành công. Các giả định ban đầu của user về lỗi đều sai:
- **"Làm gì có logs đầu"**: Không thấy log vì container chết ở tầng infrastructure (trước khi ứng dụng chạy).
- **"Không có lỗi đường dẫn"**: User bỏ qua sự khác biệt giữa Windows (case-insensitive, CRLF) và Linux (case-sensitive, LF).

Qua quá trình debug, phát hiện nguyên nhân nằm ở:
1.  **Quota và loại VM**: Region East Asia không có quota cho dòng VM **Standard_B2ms** (Burstable). Control Plane từ chối cấp phát VM, dẫn đến lỗi chung chung "Internal Error" và không có log.
2.  **Thiếu Endpoint**: Sau khi hard reset (xóa endpoint), user cố tạo Deployment trước khi tạo lại Endpoint, gây lỗi **ResourceNotFoundError**.
3.  **Rủi ro phần cứng (dự phòng)**: Nếu dùng B2ms (dù có quota), dung lượng disk tạm (8GB) không đủ để giải nén Docker image (PyTorch + OpenCV + model YOLO), gây lỗi `Disk Exhaustion / OOMKilled`.

## Quyết định cuối cùng & Lý do
- **Không dùng Standard_B2ms** vì:
  - **Không có quota** tại region East Asia cho gói Azure for Students (hoặc bị chặn ngầm).
  - Nếu có quota, vẫn **KHÔNG ĐỦ** tài nguyên disk và RAM, gây sập container (đã được cảnh báo từ đầu).
- **Chọn Standard_D2as_v4** (AMD EPYC, 2vCPU, 8GB RAM, 16GB temp disk) - là lựa chọn rẻ nhất đáp ứng ngưỡng vật lý tối thiểu để load model YOLO ensemble mà không bị OOM / tràn disk.
- **Quy trình triển khai đúng**: Tạo **Endpoint** (cha) trước, sau đó mới tạo **Deployment** (con) gắn vào endpoint đó. Không được đảo thứ tự.

## Lệnh và Cấu hình cụ thể đã dùng
### Cấu hình phần cứng (deployment.yml) – Sửa đổi cuối cùng
```yaml
# Thay thế instance_type từ Standard_B2ms thành:
instance_type: Standard_D2as_v4
```
*(Lưu ý: Nếu muốn an toàn hơn về RAM, có thể dùng Standard_DS3_v2 nhưng tốn chi phí hơn)*

### Lệnh kiểm tra log Infrastructure (Azure ML)
```bash
az ml online-deployment get-logs --name yolo-deployment-ver1 --endpoint-name yolo-endpoint-ver1 --lines 100
```
*(Lệnh này chỉ có log sau khi container đã tồn tại; nếu VM chưa được cấp thì sẽ báo "There are no logs")*

### Lệnh khắc phục lỗi ResourceNotFound (tạo Endpoint trước)
```bash
# BƯỚC 1: Tạo Endpoint (tài nguyên cha)
az ml online-endpoint create --file endpoint.yml --resource-group CV-YOLO-rg --workspace-name mlops-workspace

# BƯỚC 2: (Chỉ sau khi endpoint thành công) Tạo Deployment (tài nguyên con)
az ml online-deployment create --file deployment.yml --resource-group CV-YOLO-rg --workspace-name mlops-workspace --all-traffic
```

### Lệnh kiểm tra Quota VM theo region
```bash
# (Không có lệnh cụ thể, user tự kiểm tra trên Azure Portal)
# Kết quả phát hiện: East Asia không có quota cho B-series
```

### Lệnh kiểm tra kiến trúc image trên ACR (dùng để debug lỗi CRLF)
```bash
# Kiểm tra architecture của image đã push
docker inspect <acr-login-server>/<image>:<tag> | grep Architecture
docker inspect <acr-login-server>/<image>:<tag> | grep Os

# Kiểm tra CRLF trong file script bên trong container (chạy override entrypoint)
docker run -it --entrypoint /bin/sh <acr-login-server>/<image>:<tag>
cat -v /path/to/start.sh   # Nếu thấy ^M ở cuối dòng -> lỗi CRLF
```

## Lỗi gặp phải và Cách khắc phục
| Lỗi / Vấn đề | Nguyên nhân | Cách khắc phục / Kết luận |
| :--- | :--- | :--- |
| **"Internal Error" + 0% Utilization + No logs** | Region East Asia không có quota cho VM loại B (Standard_B2ms). Control Plane từ chối cấp phát VM. | Chọn VM có quota (ví dụ Standard_D2as_v4). Kiểm tra quota trước khi deploy. |
| **ResourceNotFoundError: ...onlineEndpoints/yolo-endpoint-ver1... was not found** | User xóa Endpoint (hard reset) nhưng lại chạy lệnh tạo Deployment trước khi tạo lại Endpoint. | Phải tạo Endpoint trước, Deployment sau. Đây là thứ tự bắt buộc của Azure ML. |
| **(Dự phòng) Container sập do tràn disk / OOM** | Standard_B2ms chỉ có 4GB RAM và 8GB temp disk, không đủ để giải nén image AI (PyTorch + YOLO ensemble). | Dùng VM có disk >= 16GB và RAM >= 8GB (D2as_v4). |
| **Docker container chạy local OK nhưng cloud crash** | Khác biệt môi trường: Windows (case-insensitive, CRLF) vs Linux (case-sensitive, LF) có thể gây lỗi ở script (ví dụ `^M`). | Dùng `dos2unix` trong Dockerfile, hoặc set LF trong VS Code. |
| **Liveness/Readiness probe sai** (đã xảy ra trước đó) | User set probe vào `/docs` nhưng dùng `azmlinfsrv` (Azure ML inference server) không hỗ trợ endpoint đó. | Sửa probe thành `/` hoặc `health` (tùy SDK). |

## Các phương án đã cân nhắc (Tranh luận & Quyết định)
| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
| :--- | :--- | :--- | :--- |
| **Dùng Standard_B2ms** (Giá rẻ nhất) | Chi phí thấp (~0.10 USD/h) | **KHÔNG có quota tại East Asia.** Nếu có quota, vẫn bị tràn disk (8GB) và thiếu RAM (4GB) khi load model YOLO. | **KHÔNG** (Đã loại bỏ vì lý do vật lý và quota) |
| **Đổi region sang East US để dùng B2ms** | Có thể bypass lỗi quota | Rủi ro disk/disk I/O vẫn y hệt (8GB disk), container sẽ sập với lỗi tương tự; phí di chuyển data. | **KHÔNG** (Không giải quyết triệt để root cause) |
| **Dùng Standard_F2s_v2** (Compute Optimized, giá rẻ) | CPU tốt, giá rẻ | **Chỉ có 4GB RAM**, chắc chắn bị OOM khi load PyTorch + YOLO. | **KHÔNG** (RAM quá thấp) |
| **Dùng Standard_D2as_v4** (AMD EPYC) | 8GB RAM, 16GB disk, chi phí hợp lý (~0.13-0.14 USD/h), có quota tại East Asia. | Đắt hơn B-series một chút. | **CHỌN** (Đáp ứng ngưỡng tối thiểu về RAM/disk, rẻ nhất trong nhóm khả thi) |

## Khái niệm & Định nghĩa
### Azure ML Endpoint vs Deployment
- **Endpoint (tài nguyên cha)**: Là cổng giao tiếp logic (URL, authentication). Nó không chạy code, chỉ định tuyến traffic.
- **Deployment (tài nguyên con)**: Là môi trường tính toán vật lý (VM, container, model). Một endpoint có thể có nhiều deployment (blue/green, canary).
- **Quy tắc**: **Phải tạo Endpoint trước**, sau đó mới tạo Deployment gắn vào Endpoint đó.

### Control Plane vs Data Plane
- **Control Plane**: Quản lý tài nguyên (Azure Resource Manager - ARM). Xử lý yêu cầu quota, RBAC, cấp phát VM. Nếu lỗi ở đây (ví dụ quota) → Deployment không được tạo → không có log.
- **Data Plane**: Nơi chạy container và code. Ở đây mới sinh ra application logs và metrics.

### Lỗi CRLF trong Docker container
- Trên Windows, file script (`start.sh`) có ký tự xuống dòng `\r\n` (CRLF). Trên Linux, chỉ có `\n` (LF).
- Khi Linux bash gặp `\r`, nó báo lỗi `no such file or directory` hoặc `command not found` ngay khi khởi động container → container chết, không có log ứng dụng.
- Kiểm tra bằng `cat -v file.sh` (thấy `^M` ở cuối dòng) và sửa bằng `dos2unix` trong Dockerfile hoặc set LF trong editor.

## Nhật ký lỗi CLI – Phân tích từ Traceback
- **Lỗi**: `ResourceNotFoundError: The Resource 'Microsoft.MachineLearningServices/workspaces/mlops-workspace/onlineEndpoints/yolo-endpoint-ver1' under resource group 'CV-YOLO-rg' was not found.`
- **Nguyên nhân trực tiếp**: User xóa endpoint nhưng vẫn chạy `az ml online-deployment create` (lệnh tạo deployment), lệnh này gọi `GET` endpoint để kiểm tra sự tồn tại → không tìm thấy → báo lỗi.
- **Cách đọc lỗi**: Dòng `azure.core.exceptions.ResourceNotFoundError` và `map_error` chỉ ra lỗi 404. Không cần đọc toàn bộ stack trace 80 dòng.
