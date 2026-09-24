---
source_url: "Trích xuất từ file PDF"
conversation_date: "2026-08-22"
context_week: "N/A"
conversation_types: [FIX_CODE, FIX_HA_TANG, LAP_KE_HOACH, TRANH_LUAN_QUYET_DINH, KIEM_TRA_KIEN_THUC]
ai300_domains: ["Thiết kế và triển khai hạ tầng MLOps", "GenAIOps infrastructure", "Observability và quality assurance"]
technologies: ["Azure ML Managed Online Endpoints", "Azure Key Vault", "Azure Log Analytics", "KQL (Kusto)", "Bicep", "Python requests", "ThreadPoolExecutor", "Azure CLI", "AzureDiagnostics", "AmIOnlineEndpointTrafficLog", "PACING_DELAY", "uniqueString", "SystemAssigned identity"]
key_decision: "Quyết định bật `AmIOnlineEndpointTrafficLog` trong Diagnostic Settings để ghi nhận log tầng Gateway (401/429/424) và sử dụng KQL với `union isfuzzy=true` để truy vấn dữ liệu, đồng thời khuyến nghị sử dụng Bicep để quản lý hạ tầng nhằm tránh ClickOps."
status: resolved
---

## Bối cảnh & Vấn đề

- **Mục tiêu ban đầu**: Chuyển đổi script từ Stress Test (đo độ chịu tải) sang Chaos Testing (tiêm lỗi có chủ đích) để kiểm chứng khả năng giám sát và phân loại sự cố của hệ thống MLOps trên Azure.
- **Vấn đề phát sinh trong quá trình thực hiện**:
  1. **Routing error (HTTP 404)**: Mặc dù token hợp lệ, request bị Gateway chặn vì URL endpoint thiếu hậu tố `/score` hoặc chưa gán traffic cho deployment.
  2. **Rate limiting (HTTP 429) và Timeout (HTTP 0)**: Script gửi 50 request đồng thời (`CONCURRENCY=5`) trong khi endpoint chỉ xử lý được tối đa 2 concurrent request.
  3. **Mất log telemetry**: Sau khi sửa script, truy vấn KQL trên Log Analytics báo lỗi "Failed to resolve table" hoặc trả về 0 dòng do chưa bật `AmIOnlineEndpointTrafficLog`.
  4. **Dữ liệu cũ không được đẩy lên**: Diagnostic Settings chỉ ghi nhận log từ thời điểm bật, không có cơ chế hồi tố.

---

## Quyết định cuối cùng & Lý do

- **Quyết định 1**: Sử dụng **Chaos Testing thay vì Stress Testing** cho mục đích giám sát và phân loại sự cố.
  - **Lý do**: Stress test tập trung vào việc đẩy hệ thống đến giới hạn (trả về HTTP 502/503/504), trong khi Chaos test cần tiêm các lỗi có chủ đích (400, 401) để kiểm tra khả năng quan sát và phân loại của hệ thống.
  - **KHÔNG dùng** cơ chế leo thang (step-load) và ngắt khẩn cấp (abort) vì trong Chaos testing, tỷ lệ lỗi cao là mục tiêu, không phải là dấu hiệu hệ thống sập.

- **Quyết định 2**: Kiểm soát lưu lượng đầu vào bằng **Client-side Pacing** với `CONCURRENCY=2` và `PACING_DELAY=3.0` giây.
  - **Lý do**: Hạ tầng CPU giới hạn chỉ xử lý được 2 request song song. Nếu gửi ồ ạt, hệ thống trả về HTTP 429 (Rate Limit) và timeout, gây nhiễu cho việc kiểm thử.
  - **KHÔNG dùng** `CONCURRENCY=5` vì gây hiệu ứng thắt cổ chai (bottleneck) và làm sai lệch kết quả.

- **Quyết định 3**: Bắt buộc bật **`AmIOnlineEndpointTrafficLog`** trong Diagnostic Settings để ghi nhận log tầng Gateway.
  - **Lý do**: ConsoleLog và EventLog chỉ ghi lại hoạt động bên trong container. Các lỗi 401 (Unauthorized) và 429 (Too Many Requests) xảy ra ở tầng Gateway trước khi request chạm tới container nên không được ghi nhận nếu chỉ bật 2 loại log kia.
  - **KHÔNG dùng** duy nhất `ConsoleLog` và `EventLog` cho mục đích giám sát lỗi xác thực và giới hạn tốc độ.

- **Quyết định 4**: Sử dụng **Bicep (Infrastructure as Code)** để quản lý toàn bộ tài nguyên Azure ML thay vì ClickOps.
  - **Lý do**: ClickOps dễ dẫn đến sai sót như quên bật TrafficLog, không tái sử dụng được, thiếu tính đồng nhất. Bicep cho phép khai báo hạ tầng bằng mã nguồn, đảm bảo khả năng tái tạo và kiểm soát phiên bản.

---

## Lệnh và Cấu hình cụ thể đã dùng

**Script Chaos Testing (phiên bản cuối cùng, có PACING_DELAY và CONCURRENCY=2):**

```python
import os
import sys
import time
import random
import requests
import concurrent.futures
import logging
from datetime import datetime
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient

# CẤU HÌNH LOGGING
CURRENT_DIR = os.path.dirname(os.path.abspath(__file__))
LOG_FILENAME = os.path.join(CURRENT_DIR, f"chaos_test_{datetime.now().strftime('%Y%m%d_%H%M%S')}.log")
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(message)s",
    handlers=[
        logging.FileHandler(LOG_FILENAME, encoding="utf-8"),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger(__name__)

# 1. XÁC THỰC BẢO MẬT (KEY VAULT)
KEY_VAULT_NAME = "qwen-rag-vault"
KV_URI = f"https://{KEY_VAULT_NAME}.vault.azure.net"
try:
    credential = DefaultAzureCredential()
    client = SecretClient(vault_url=KV_URI, credential=credential)
    AZURE_ENDPOINT_URL = client.get_secret("azure-endpoint-url").value
    AZURE_API_KEY = client.get_secret("azure-api-key").value
    logger.info("Decrypted API configuration keys successfully.")
except Exception as e:
    logger.error(f"KEY VAULT ERROR: {e}")
    sys.exit(1)

# 2. ĐỊNH NGHĨA KỊCH BẢN & LƯU LƯỢNG
TOTAL_REQUESTS = 50
CONCURRENCY = 2        # Đồng bộ tuyệt đối với năng lực xử lý (max 2)
PACING_DELAY = 3.0     # Độ trễ (giây) giữa các lần nạp request vào hàng đợi

SCENARIOS = {
    "VALID": {
        "headers": {"Content-Type": "application/json", "Authorization": f"Bearer {AZURE_API_KEY}"},
        "payload": {"messages": [{"role": "user", "content": "Tóm tắt tiểu sử của bạn."}], "temperature": 0.2},
        "expected_code": 200
    },
    "BAD_REQUEST": {
        "headers": {"Content-Type": "application/json", "Authorization": f"Bearer {AZURE_API_KEY}"},
        "payload": {"wrong_schema_key": "data", "temperature": "high"},
        "expected_code": 400
    },
    "UNAUTHORIZED": {
        "headers": {"Content-Type": "application/json", "Authorization": "Bearer INVALID_OR_EXPIRED_TOKEN_123"},
        "payload": {"messages": [{"role": "user", "content": "Test."}]},
        "expected_code": 401
    }
}

# 3. LOGIC THỰC THI (ĐIỀU PHỐI NHỊP ĐỘ)
def inject_chaos(request_id):
    scenario_name = random.choice(list(SCENARIOS.keys()))
    scenario = SCENARIOS[scenario_name]
    try:
        # Tăng timeout lên 60s cho LLM trên CPU
        response = requests.post(
            AZURE_ENDPOINT_URL,
            headers=scenario["headers"],
            json=scenario["payload"],
            timeout=60
        )
        status = response.status_code
        logger.info(f"Req-{request_id:02d} [{scenario_name}] -> HTTP {status}")
        return status
    except requests.exceptions.Timeout:
        logger.error(f"Req-{request_id:02d} [{scenario_name}] -> TIMEOUT EXCEPTION")
        return 0
    except Exception as e:
        logger.error(f"Req-{request_id:02d} [{scenario_name}] -> NETWORK EXCEPTION: {str(e)}")
        return 0

def run_chaos_test():
    logger.info("=" * 50)
    logger.info(f"KHỞI CHẠY CHAOS TEST: {TOTAL_REQUESTS} REQUESTS (PACED)")
    logger.info("=" * 50)
    status_counts = {}

    with concurrent.futures.ThreadPoolExecutor(max_workers=CONCURRENCY) as executor:
        futures = []
        # Nạp request từ từ vào hàng đợi của ThreadPool thay vì nạp ồ ạt
        for i in range(TOTAL_REQUESTS):
            futures.append(executor.submit(inject_chaos, i))
            time.sleep(PACING_DELAY)

        for future in concurrent.futures.as_completed(futures):
            status = future.result()
            status_counts[status] = status_counts.get(status, 0) + 1

    logger.info("\n" + "=" * 50)
    logger.info("TỔNG HỢP HTTP STATUS CODES:")
    for code, count in status_counts.items():
        logger.info(f"HTTP {code}: {count} requests")
    logger.info("=" * 50)
    logger.warning("BẮT BUỘC CHỜ 5 PHÚT ĐỂ LOG ANALYTICS HOÀN TẤT ĐỒNG BỘ DỮ LIỆU (INGESTION)...")
    logger.warning("TUYỆT ĐỐI KHÔNG XÓA ENDPOINT LÚC NÀY.")
    time.sleep(300)
    logger.info("Đã hoàn tất đồng bộ. Bạn có thể mở Azure Portal và chạy KQL.")

if __name__ == "__main__":
    run_chaos_test()
```

**Truy vấn KQL "chống đạn" (dùng `union isfuzzy=true` và `column_iexists`) để truy xuất TrafficLog:**

```kql
union isfuzzy=true
    AmlOnlineEndpointTrafficLog,
    (AzureDiagnostics | where Category == "AmlOnlineEndpointTrafficLog")
| where TimeGenerated > ago(1h)
| extend Safe_StatusCode = coalesce(
    tostring(column_iexists('StatusCode', ' ')),
    tostring(column_iexists('httpStatusCode_d', ' ')),
    'N/A'
  )
| where Safe_StatusCode != 'N/A'
| summarize RequestCount = count() by Safe_StatusCode
| order by RequestCount desc
```

**Mẫu Bicep (Infrastructure as Code) cho Azure ML Workspace + 4 tài nguyên vệ tinh:**

```bicep
// Tên định danh chung để tạo sự đồng nhất cho các resource
param basename string = 'qwenrag'
param location string = resourceGroup().location

// 1. Storage Account
resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' = {
  name: '${basename}storage${uniqueString(resourceGroup().id)}'
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
  }
}

// 2. Key Vault
resource keyVault 'Microsoft.KeyVault/vaults@2022-07-01' = {
  name: '${basename}-kv-${uniqueString(resourceGroup().id)}'
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    accessPolicies: []
  }
}

// 3. Application Insights
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${basename}-appInsights'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
  }
}

// 4. Container Registry
resource containerRegistry 'Microsoft.ContainerRegistry/registries@2022-12-01' = {
  name: '${basename}cr${uniqueString(resourceGroup().id)}'
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: true
  }
}

// 5. Azure Machine Learning Workspace (Tài nguyên chính)
resource mlWorkspace 'Microsoft.MachineLearningServices/workspaces@2022-10-01' = {
  name: '${basename}-workspace'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    friendlyName: 'RAG ML Workspace'
    storageAccount: storageAccount.id
    keyVault: keyVault.id
    applicationInsights: appInsights.id
    containerRegistry: containerRegistry.id
  }
}
```

---

## Lỗi gặp phải và Cách khắc phục

| **Lỗi / Hiện tượng** | **Nguyên nhân** | **Cách khắc phục** |
|---|---|---|
| Toàn bộ request trả về HTTP 404 (trừ 401). | URL endpoint trong Key Vault thiếu hậu tố `/score` hoặc chưa gán traffic 100% cho deployment. | Kiểm tra URL, đảm bảo kết thúc bằng `/score`. Chạy `az ml online-endpoint show --name <tên>` để xem trường `traffic` và gán traffic nếu cần. |
| HTTP 429 (Too Many Requests) và HTTP 0 (Timeout) xuất hiện. | `CONCURRENCY=5` vượt quá khả năng xử lý thực tế (chỉ 2 concurrent). Timeout 30s quá thấp cho LLM trên CPU. | Giảm `CONCURRENCY=2`, thêm `PACING_DELAY=3.0`, tăng `timeout=60`. |
| Truy vấn KQL báo "Failed to resolve table" hoặc trả về 0 dòng. | Chưa bật `AmIOnlineEndpointTrafficLog` trong Diagnostic Settings. | Bật tick chọn `AmIOnlineEndpointTrafficLog`, lưu lại, chờ 5-15 phút cho lần đầu khởi tạo schema. |
| Dữ liệu cũ (chạy từ hôm trước) không hiển thị dù truy vấn `ago(48h)`. | Diagnostic Settings chỉ ghi log từ thời điểm được bật, không có cơ chế hồi tố. | Chạy lại script Chaos Test để tạo dữ liệu mới, đợi 5 phút, truy vấn `ago(1h)`. |
| Dùng `union isfuzzy=true AmlOnlineEndpointTrafficLog` vẫn báo lỗi `project` operator. | Bảng áo (dummy) được tạo ra nhưng không có cột nào, dẫn đến lỗi khi gọi `project`. | Sử dụng `column_iexists()` và `coalesce()` để kiểm tra sự tồn tại của cột trước khi trích xuất. |
| Lỗi `Failed to resolve table 'AzureDiagnostics'`. | Workspace sử dụng chế độ Resource-specific (bảng chuyên biệt), không có bảng `AzureDiagnostics`. | Dùng `union isfuzzy=true` để quét cả 2 loại bảng, tránh lỗi nếu một bảng không tồn tại. |

---

## Lộ trình chi tiết (IaC)

- **Mục tiêu**: Loại bỏ ClickOps, quản lý toàn bộ Azure ML Workspace và các tài nguyên vệ tinh bằng Bicep.
- **Các bước thực hiện**:

| **Bước** | **Hành động** | **Lệnh / File** |
|---|---|---|
| 1 | Tạo Resource Group | `az group create --name mlops-iac-rg --location eastasia` |
| 2 | Tạo file `main.bicep` với nội dung như trên (bao gồm Storage, Key Vault, App Insights, Container Registry, ML Workspace). | `main.bicep` |
| 3 | Triển khai Bicep | `az deployment group create --resource-group mlops-iac-rg --template-file main.bicep` |
| 4 | (Mở rộng) Tự động gắn Diagnostic Settings cho Managed Online Endpoint | Có thể thêm resource `Microsoft.Insights/diagnosticSettings` vào Bicep để bật sẵn `AmIOnlineEndpointTrafficLog` khi tạo endpoint. |

**Chỉ tiêu hoàn thành**:
- Workspace được tạo thành công với đầy đủ 4 tài nguyên vệ tinh.
- Có thể triển khai lại toàn bộ hạ tầng chỉ bằng 1 lệnh CLI.
- (Nâng cao) Diagnostic Settings cho TrafficLog được cấu hình tự động, không cần thao tác thủ công trên Portal.

---

## Các phương án đã cân nhắc (trong quá trình xử lý lỗi log)

| **Phương án** | **Ưu điểm** | **Nhược điểm** | **Được chọn?** |
|---|---|---|---|
| Chỉ bật `ConsoleLog` và `EventLog` trong Diagnostic Settings. | Đơn giản, ít cấu hình. | Không ghi nhận lỗi tầng Gateway (401, 429). | **KHÔNG** chọn. |
| Bật thêm `TrafficLog` và truy vấn trực tiếp bảng `AmIOnlineEndpointTrafficLog`. | Ghi nhận đầy đủ lỗi tầng Gateway, đúng cấu trúc bảng chuyên biệt. | Nếu workspace dùng chế độ `AzureDiagnostics`, bảng này sẽ không tồn tại. | **KHÔNG** dùng duy nhất vì không tương thích với một số cấu hình. |
| Sử dụng `union isfuzzy=true` để quét cả 2 loại bảng (`AmIOnlineEndpointTrafficLog` và `AzureDiagnostics`). | Bao phủ được cả 2 chế độ routing, không báo lỗi nếu thiếu bảng. | Câu lệnh phức tạp hơn, cần dùng `column_iexists()` để tránh lỗi cột. | **CHỌN** (giải pháp "chống đạn"). |
| Dùng Azure CLI để lấy log trực tiếp từ container (live logs). | Truy xuất nhanh, không cần chờ ingestion. | Log không lưu trữ, bị mất khi container restart. Không dùng cho cảnh báo tự động. | **KHÔNG** chọn cho observability lâu dài. |
| Viết lại script để tự động bật Diagnostic Settings bằng code. | Loại bỏ hoàn toàn ClickOps, đảm bảo cấu hình đúng ngay từ đầu. | Cần thời gian viết code và kiểm thử. | **SẼ** triển khai trong kế hoạch IaC (Bicep). |

**Tiêu chí quyết định**: Khả năng thu thập đầy đủ log lỗi tầng Gateway, tính ổn định (không bị lỗi schema khi truy vấn), và khả năng tự động hóa để tránh sai sót con người.