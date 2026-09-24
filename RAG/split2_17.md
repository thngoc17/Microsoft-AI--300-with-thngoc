---
source_url: https://gemini.google.com/app/350f06f10438e39f
conversation_date: 2026-08-04
context_week: N/A
conversation_types: [FIX_CODE, FIX_HA_TANG, TRANH_LUAN_QUYET_DINH, LY_THUYET, LAP_KE_HOACH]
ai300_domains: ["GenAIOps infrastructure", "Optimize generative AI systems and model performance"]
technologies: [Azure ML, FastAPI, Llama.cpp, ChromaDB, Docker, ACR, Key Vault, Application Insights, JWT, CORS, Uvicorn]
key_decision: "Chuyển từ hardcoded path sang os.walk() dynamic resolution; bổ sung yield trong lifespan; tăng request_timeout_ms lên 90000ms và giảm max_tokens xuống 150 để tránh HTTP 408 timeout; sử dụng auth_mode: key thay vì aml_token cho Telegram Client."
status: resolved
---

## Bối cảnh & Vấn đề

| STT | Vấn đề | Biểu hiện |
|-----|--------|-----------|
| 1 | Đường dẫn model hardcoded không khớp cấu trúc mount của Azure ML | `ValueError: Model path does not exist: /var/azureml-app/azureml-models/qwen3-4b-gguf-model/1/qwen3-4b-gguf-model/qwen3-4b-instruct-2507.Q4_K_M.gguf` |
| 2 | Hàm `lifespan` thiếu từ khóa `yield` | `TypeError: 'coroutine' object is not an async iterator` |
| 3 | Endpoint không route traffic đến deployment | `HTTP 404: No valid deployments to route to` |
| 4 | Request bị timeout sau 60 giây | `HTTP 408 Request Timeout` |
| 5 | Azure Portal test báo "Network Error" | Do CORS và payload rỗng `{}` |
| 6 | `az ml online-endpoint get-credentials` trả về JWT thay vì API key | Do `auth_mode: aml_token` |

---

## Quyết định cuối cùng & Lý do

### ✅ Quyết định được chọn

| Quyết định | Lý do |
|------------|-------|
| Dùng `os.walk()` để quét động đường dẫn model | Azure tự động tiêm thêm version và nests thư mục, không thể hardcode |
| Bổ sung `yield` vào hàm `lifespan` | FastAPI yêu cầu async generator, thiếu yield sẽ gây lỗi coroutine |
| Đặt `auth_mode: key` trong endpoint.yml | JWT token hết hạn sau 15-30 phút, không dùng được cho Telegram Client |
| Tăng `request_timeout_ms` lên 90000ms | Qwen 4B chạy trên CPU DS2_v2 tốc độ ~4 tokens/s, cần thời gian dài |
| Giảm `max_tokens` từ 1024 xuống 150 | 1024 token mất 4-5 phút, vượt quá timeout của Azure |
| Dùng script Python thay vì Azure Portal Test | Portal bị CORS block và không hỗ trợ Custom FastAPI |
| Xóa endpoint khi không dùng | Không có cơ chế "pause", phải delete để giải phóng máy ảo |

### ❌ Phương án bị loại bỏ

| Phương án bị loại bỏ | Lý do |
|----------------------|-------|
| KHÔNG dùng hardcoded path | Azure tự động thêm version và thư mục lồng nhau |
| KHÔNG dùng `auth_mode: aml_token` cho Telegram Client | Token hết hạn nhanh, không thể chạy 24/7 |
| KHÔNG dùng Azure Portal Test | CORS block + payload rỗng gây lỗi |
| KHÔNG thêm CORSMiddleware chỉ để dùng Portal Test | Tốn thời gian build/deploy 25 phút cho tính năng không cần thiết |
| KHÔNG dùng `max_tokens=1024` trên CPU DS2_v2 | Vượt quá giới hạn timeout, gây HTTP 408 |
| KHÔNG dùng `instance_count=0` để tạm dừng | Azure Managed Endpoint không hỗ trợ scale-to-zero |

---

## Lệnh và Cấu hình cụ thể đã dùng

### Dynamic Path Resolution (source/main.py)

```python
# 2. Khởi tạo Mô hình LLM từ biến môi trường của Azure
model_dir = os.getenv("AZUREML_MODEL_DIR")
if not model_dir:
    raise RuntimeError("CRITICAL: Không tìm thấy AZUREML_MODEL_DIR.")

# LUỒNG QUÉT ĐỘNG: Bất chấp Azure lồng bao nhiêu thư mục, code sẽ tự động dò tìm file GGUF
target_filename = "qwen3-4b-instruct-2507.Q4_K_M.gguf"
model_path = None

for root, dirs, files in os.walk(model_dir):
    if target_filename in files:
        model_path = os.path.join(root, target_filename)
        break  # Dừng lại ngay khi tìm thấy file

if not model_path:
    raise FileNotFoundError(f"CRITICAL: Quét toàn bộ {model_dir} nhưng không thấy {target_filename}")

print(f"✅ LLM Found at absolute path: {model_path}")

try:
    # Nạp mô hình với đường dẫn động vừa quét được
    ml_models["llm"] = Llama(
        model_path=model_path,
        n_ctx=2048,
        n_gpu_layers=0
    )
except Exception as e:
    raise RuntimeError(f"Lỗi nạp mô hình Llama.cpp: {e}")
```

### Lifespan với yield (source/main.py)

```python
from fastapi import FastAPI
from contextlib import asynccontextmanager

ml_models = {}

@asynccontextmanager
async def lifespan(app: FastAPI):
    # --- PHẦN 1: SETUP (KHỞI CHẠY TRƯỚC KHI API NHẬN REQUEST) ---
    db_path = os.path.join(os.path.dirname(__file__), 'knowledge_db')
    print(f"Loading ChromaDB from {db_path}...")
    try:
        ml_models["embedding"] = HuggingFaceEmbeddings(
            model_name="bakai-foundation-models/vietnamese-bi-encoder"
        )
        ml_models["vector_db"] = Chroma(
            persist_directory=db_path,
            embedding_function=ml_models["embedding"]
        )
    except Exception as e:
        raise RuntimeError(f"Lỗi khởi tạo Vector DB: {e}")

    model_dir = os.getenv("AZUREML_MODEL_DIR")
    if not model_dir:
        raise RuntimeError("CRITICAL: Không tìm thấy AZUREML_MODEL_DIR.")
    target_filename = "qwen3-4b-instruct-2507.Q4_K_M.gguf"
    model_path = None
    for root, dirs, files in os.walk(model_dir):
        if target_filename in files:
            model_path = os.path.join(root, target_filename)
            break
    if not model_path:
        raise FileNotFoundError(f"CRITICAL: Quét toàn bộ {model_dir} nhưng không thấy {target_filename}")
    print(f"✅ LLM Found at absolute path: {model_path}")
    try:
        ml_models["llm"] = Llama(
            model_path=model_path,
            n_ctx=2048,
            n_gpu_layers=0
        )
    except Exception as e:
        raise RuntimeError(f"Lỗi nạp LLM: {e}")

    # ###########################################################################
    # CHỐT CHẶN BẮT BUỘC (ĐIỂM GÂY CỦA BẠN NẰM Ở ĐÂY)
    # Tạm dừng hàm tại đây và nhường quyền kiểm soát cho FastAPI
    # ###########################################################################
    yield

    # --- PHẦN 2: TEARDOWN (CHẠY KHI API BỊ TẮT ĐỂ GIẢI PHÓNG RAM) ---
    ml_models.clear()
    print("Đã giải phóng tài nguyên LLM và ChromaDB.")

app = FastAPI(lifespan=lifespan)
# ... (Các route bên dưới giữ nguyên) ...
```

### Tối ưu CPU threads (source/main.py)

```python
ml_models["llm"] = Llama(
    model_path=model_path,
    n_ctx=2048,
    n_threads=2,  # Cố định 2 luồng vật lý cho DS2_v2
    n_gpu_layers=0
)
```

### deployment.yml (bổ sung request_timeout)

```yaml
$schema: https://azuremlschemas.azureedge.net/latest/managedOnlineDeployment.schema.json
name: rag-deployment-ver1
endpoint_name: qwen-rag-endpoint-ver3
model: azureml:qwen3-4b-gguf-model:1
environment:
  image: <TÊN_ACR_CỦA_BẠN>.azurecr.io/qwen-rag-api:v2
inference_config:
  liveness_route:
    port: 8000
    path: /docs
  readiness_route:
    port: 8000
    path: /docs
  scoring_route:
    port: 8000
    path: /chat
# [BỔ SUNG]: Ép Azure chờ tối đa 90 giây trước khi ngắt kết nối
request_settings:
  request_timeout_ms: 90000
instance_type: Standard_DS2_v2
instance_count: 1
```

### endpoint.yml (auth_mode: key)

```yaml
$schema: https://azuremlschemas.azureedge.net/latest/managedOnlineEndpoint.schema.json
name: qwen-rag-endpoint-ver3
auth_mode: key
```

### Test Script (test_inference.py)

```python
import urllib.request
import json

SCORING_URI = "https://qwen-rag-endpoint-ver1.eastasia.inference.ml.azure.com/chat"
API_KEY = "<JWT_TOKEN_HOAC_API_KEY>"

def test_azure_endpoint():
    data = {
        "messages": [
            {
                "role": "user",
                "content": "Chào bạn, bạn đang học chuyên ngành gì và ở trường nào?"
            }
        ],
        "temperature": 0.2,
        "max_tokens": 1024
    }
    body = str.encode(json.dumps(data))
    headers = {
        'Content-Type': 'application/json',
        'Authorization': f'Bearer {API_KEY}'
    }
    req = urllib.request.Request(SCORING_URI, body, headers)
    print("⏳ Đang gửi request lên Azure ML Endpoint... (Có thể mất vài giây)")
    try:
        response = urllib.request.urlopen(req)
        result = response.read()
        print("\n✅ KẾT QUẢ TRẢ VỀ TỪ QWEN & RAG:")
        print("-" * 50)
        formatted_result = json.dumps(json.loads(result), indent=4, ensure_ascii=False)
        print(formatted_result)
        print("-" * 50)
    except urllib.error.HTTPError as error:
        print(f"❌ HTTP Lỗi {error.code}")
        print(error.read().decode("utf8", 'ignore'))
    except Exception as e:
        print(f"❌ Lỗi hệ thống: {e}")

if __name__ == "__main__":
    test_azure_endpoint()
```

### Client-side routing (thêm header để bypass traffic weight)

```python
headers = {
    'Content-Type': 'application/json',
    'Authorization': f'Bearer {API_KEY}',
    # Ép buộc request đâm thẳng vào Deployment cụ thể
    'azureml-model-deployment': 'rag-deployment-ver1'
}
```

### Cập nhật biến trong Key Vault

```bash
az keyvault secret set \
  --vault-name "qwen-rag-vault" \
  --name "ENDPOINT-API-KEY" \
  --value "<GIÁ_TRI_API_KEY_MỚI>"
```

### Xem toàn bộ secret trong Key Vault

```bash
# Liệt kê tên secret
az keyvault secret list --vault-name "qwen-rag-vault" --output table

# Kiểm toán giá trị thực tế
secrets=$(az keyvault secret list --vault-name "qwen-rag-vault" --query "[].name" -o tsv)
for secret in $secrets; do
    value=$(az keyvault secret show --vault-name "qwen-rag-vault" --name "$secret" --query "value" -o tsv)
    echo "🔐 [Secret]: $secret"
    echo "📌 [Value] : $value"
    echo " ---"
done
```

### Xóa endpoint (giải phóng máy ảo)

```bash
az ml online-endpoint delete \
  --name qwen-rag-endpoint-ver3 \
  --resource-group mlops-rg \
  --workspace-name mlops-workspace \
  --yes
```

### Dọn dẹp tài nguyên

```bash
# Xóa toàn bộ Resource Group
az group delete --name mlops-rg --yes --no-wait

# Hoặc xóa thủ công từng tài nguyên
az acr delete --name 63b2ec7eba0d44ea9a68fb9ece0790a2 --resource-group mlops-rg --yes
az storage account delete --name mlopsworstorageacc1ddc663 --resource-group mlops-rg --yes
```

---

## Lỗi gặp phải và Cách khắc phục

| # | Lỗi | Nguyên nhân | Cách khắc phục |
|---|-----|-------------|----------------|
| 1 | `ValueError: Model path does not exist` | Hardcoded path không khớp với cấu trúc mount của Azure (thêm version và thư mục lồng) | Dùng `os.walk()` quét động target file |
| 2 | `TypeError: 'coroutine' object is not an async iterator` | Hàm `lifespan` thiếu từ khóa `yield` | Bổ sung `yield` vào giữa setup và teardown |
| 3 | `HTTP 404: No valid deployments to route to` | Traffic weight = 0% do không set khi update | `az ml online-endpoint update --traffic "rag-deployment-ver1=100"` hoặc thêm header `azureml-model-deployment` |
| 4 | `HTTP 408 Request Timeout` | Qwen 4B trên CPU DS2_v2 chạy chậm (~4 tokens/s), vượt quá 60s timeout mặc định | Tăng `request_timeout_ms: 90000` và giảm `max_tokens` từ 1024 xuống 150 |
| 5 | `Network Error` trên Azure Portal Test | CORS chặn request từ browser + payload rỗng `{}` | Dùng script Python hoặc curl, không dùng Portal Test |
| 6 | `az ml online-endpoint get-credentials` trả về JWT token | `auth_mode: aml_token` trong endpoint.yml | Đổi sang `auth_mode: key` và update endpoint |
| 7 | JWT token hết hạn sau 15-30 phút | Token có vòng đời ngắn | Không dùng JWT cho Telegram Client, chuyển sang API key tĩnh |
| 8 | Không tìm thấy endpoint khi update | Azure tự động dọn dẹp deployment hỏng | Chạy lại `az ml online-deployment update` để tạo mới |

---

## Lộ trình chi tiết

### Luồng triển khai hoàn chỉnh

| Bước | Hành động | Lệnh / Mô tả |
|------|-----------|--------------|
| 1 | Build Docker Image | `docker build -f source/Dockerfile -t qwen-rag-api:v2 .` |
| 2 | Tag Image | `docker tag qwen-rag-api:v2 <ACR>.azurecr.io/qwen-rag-api:v2` |
| 3 | Push lên ACR | `docker push <ACR>.azurecr.io/qwen-rag-api:v2` |
| 4 | Tạo endpoint | `az ml online-endpoint create --file azure/endpoint.yml --resource-group mlops-rg --workspace-name mlops-workspace` |
| 5 | Tạo deployment | `az ml online-deployment create --file azure/deployment.yml --resource-group mlops-rg --workspace-name mlops-workspace` |
| 6 | Set traffic | `az ml online-endpoint update --traffic "rag-deployment-ver1=100" ...` |
| 7 | Lấy API key | `az ml online-endpoint get-credentials --name qwen-rag-endpoint-ver3 ...` |
| 8 | Cập nhật Key Vault | `az keyvault secret set --vault-name "qwen-rag-vault" --name "ENDPOINT-API-KEY" --value "<KEY>"` |
| 9 | Test inference | Chạy `test_inference.py` |
| 10 | Xóa endpoint khi không dùng | `az ml online-endpoint delete ... --yes` |
| 11 | Dọn dẹp resource group | `az group delete --name mlops-rg --yes --no-wait` |

---

## Khái niệm & Định nghĩa

### CORS (Cross-Origin Resource Sharing)

| Thuật ngữ | Định nghĩa | Ví dụ |
|-----------|------------|-------|
| **CORS** | Cơ chế bảo mật của trình duyệt web, chặn request từ domain khác với domain của server | Azure ML Studio domain `portal.azure.com` gọi API đến endpoint domain `eastasia.inference.ml.azure.com` → bị chặn |
| **CORSMiddleware** | Middleware trong FastAPI để cho phép CORS | Nếu thêm, browser cho phép gọi; nhưng không khuyến nghị vì tốn thời gian build lại |

### JWT vs API Key

| Thuật ngữ | Định nghĩa | Đặc điểm |
|-----------|------------|----------|
| **JWT Token** | JSON Web Token, token có cấu trúc chứa thông tin xác thực | Vòng đời ngắn (15-30 phút), phù hợp server-to-server |
| **API Key** | Chuỗi ngẫu nhiên tĩnh dùng để xác thực | Vòng đời dài, phù hợp cho client chạy 24/7 (Telegram Bot) |
| **auth_mode: aml_token** | Cấu hình endpoint dùng JWT token | Không sinh primaryKey/secondaryKey |
| **auth_mode: key** | Cấu hình endpoint dùng API key tĩnh | Sinh primaryKey và secondaryKey |

### Azure ML Kiến trúc: Endpoint vs Deployment

| Thuật ngữ | Định nghĩa | Vai trò |
|-----------|------------|---------|
| **Endpoint** | Lớp vỏ (frontend) chứa scoring URI và auth policy | Định tuyến traffic đến các deployment |
| **Deployment** | Lớp lõi (backend) chứa container, model và compute | Thực tế chạy inference |
| **Traffic weight** | Tỷ lệ % traffic được gửi đến mỗi deployment | Hỗ trợ rollout an toàn (canary deployment) |

### Application Insights & Action Group

| Thuật ngữ | Định nghĩa | Ví dụ |
|-----------|------------|-------|
| **Application Insights** | Dịch vụ giám sát (APM) và telemetry | Ghi log HTTP (số request, độ trễ, lỗi), CPU/RAM của container |
| **Action Group** | Công cụ định tuyến cảnh báo (alert routing) | Khi phát hiện bất thường về thời gian phản hồi, gửi email cảnh báo |
| **Smart Detection** | Tính năng tự động phát hiện bất thường bằng ML | Phát hiện đột biến latency của model Qwen |

### Azure Key Vault: System vs Application

| Thuật ngữ | Định nghĩa | Ví dụ trong bài |
|-----------|------------|-----------------|
| **System Key Vault** | Azure tự tạo để lưu bí mật hạ tầng | `mlopsworkeyvaultbf799f9f` (tự sinh, không can thiệp) |
| **Application Key Vault** | Người dùng tự tạo để lưu bí mật ứng dụng | `qwen-rag-vault` (tên đẹp, chứa ENDPOINT-API-KEY) |
| **Separation of Privilege** | Nguyên tắc phân tách đặc quyền | Không trộn lẫn bí mật hạ tầng và bí mật ứng dụng |

---

## Các phương án đã cân nhắc

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
|-----------|---------|------------|------------|
| Hardcoded path | Đơn giản, dễ code | Không chịu được biến động cấu trúc thư mục của Azure | ❌ Không |
| `os.walk()` dynamic scan | Luôn tìm đúng file, không quan tâm đường dẫn | Tốn CPU cycle khi quét (không đáng kể) | ✅ Có |
| `auth_mode: aml_token` | Bảo mật cao, token có vòng đời ngắn | Token hết hạn nhanh, không dùng cho Telegram Bot | ❌ Không (cho Client) |
| `auth_mode: key` | API key tĩnh, dùng được 24/7 | Kém bảo mật hơn token (có thể bị lộ) | ✅ Có (cho Telegram Client) |
| Dùng Azure Portal Test | Tiện lợi, không cần code | CORS block, payload rỗng gây lỗi | ❌ Không |
| Dùng script Python / curl | Không bị CORS, payload kiểm soát được | Cần code/CLI | ✅ Có |
| Giữ nguyên `max_tokens=1024` | Câu trả lời dài, đầy đủ | Timeout 4-5 phút → HTTP 408 | ❌ Không |
| Giảm `max_tokens=150` | Phản hồi nhanh, nằm trong timeout 90s | Câu trả lời ngắn hơn | ✅ Có |
| `instance_count=0` (pause) | Tiết kiệm chi phí tạm thời | Azure Managed Endpoint không hỗ trợ | ❌ Không |
| Xóa endpoint | Giải phóng hoàn toàn máy ảo | Mất 1-2 phút để tạo lại sau | ✅ Có |
| Thêm CORSMiddleware | Cho phép Portal Test hoạt động | Tốn 25 phút build/deploy cho tính năng không cần thiết | ❌ Không |
| Giữ nguyên `auth_mode: aml_token` cho Telegram | Không cần thay đổi endpoint | Token hết hạn, bot chết | ❌ Không |