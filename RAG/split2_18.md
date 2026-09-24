---
source_url: https://gemini.google.com/app/414e67427c7085b9
conversation_date: 2026-08-06
context_week: "Tuần 1"
conversation_types: [LAP_KE_HOACH, FIX_CODE, FIX_HA_TANG, TRANH_LUAN_QUYET_DINH, LY_THUYET]
ai300_domains: [GenAIOps infrastructure, Optimize generative AI systems and model performance, Model lifecycle]
technologies: [FastAPI, Docker, Azure ML, Azure CLI, ChromaDB, Llama.cpp, Langchain, Qwen 3, MLflow, Azure Key Vault, Azure Container Registry, Managed Identity, Telebot]
key_decision: "Chuyển từ monolithic Telegram bot sang kiến trúc microservices với FastAPI stateless, Azure ML, và Zero-trust Key Vault; khắc phục bottleneck CPU và RAM bằng thread pool, multi-stage Docker, và auto-scaling."
status: resolved
---

## Bối cảnh & Vấn đề

Hệ thống ban đầu là một monolithic Telegram Bot (Fat Client) xử lý RAG và LLM inference trên CPU cục bộ, dẫn đến các vấn đề:

1.  **Thread Blocking trong FastAPI:** Đặt tác vụ tính toán nặng (RAG + LLM) bên trong `async def` sẽ block toàn bộ Event Loop, làm API tê liệt khi xử lý request A, không thể tiếp nhận request B/C.
2.  **Docker Image phình to:** Build Dockerfile 1 giai đoạn chứa trình biên dịch C++ khiến dung lượng Image >1.5GB.
3.  **Thiếu hụt RAM:** Máy ảo Azure Standard_DS2_v2 (7GB RAM) không đủ để chạy đồng thời mô hình Qwen 4B và Vector DB Chroma.
4.  **Bảo mật kém:** Hardcode Telegram Token và Azure API Key trực tiếp trong mã nguồn (`telegram_client.py`).
5.  **Quản lý mã nguồn kém:** Commit nhầm dữ liệu nhị phân (`knowledge_db/`, `*.gguf`) vào Git, làm phình to repository.

## Quyết định cuối cùng & Lý do

### Kiến trúc đã chốt

- **Serving Layer (FastAPI):** Xây dựng REST API phi trạng thái (Stateless), xử lý inference trên Azure Managed Endpoint.
    - **Lý do:** Tách biệt logic AI khỏi giao diện, cho phép scale độc lập.
    - **Chi tiết:** Sử dụng `def chat_endpoint()` thay vì `async def` để FastAPI tự động chuyển tác vụ nặng vào Thread Pool ngoại vi, giải phóng Event Loop.
- **Data Pipeline (Azure ML):** Tự động hóa việc sinh Vector DB từ `profile.json` bằng Command Job.
    - **Lý do:** Đảm bảo tái tạo được, tách biệt khỏi môi trường serving, giảm chi phí (job chạy xong tự tắt compute).
- **Thin Client (Telegram):** Telegram Bot chỉ quản lý lịch sử chat và gửi HTTP request lên Azure.
    - **Lý do:** Giảm tải tài nguyên cục bộ, không cần tải mô hình nặng.
- **Xác thực (Zero-Trust):** Sử dụng Azure Key Vault kết hợp Managed Identity để lưu và truy cập bí mật (secrets).
    - **Lý do:** Loại bỏ hoàn toàn hardcode secrets trong mã nguồn và Docker Image, ngăn chặn rò rỉ và tấn công chiếm dụng billing.

### Các phương án bị loại bỏ

| Phương án                                  | Lý do loại bỏ                                                                               |
| :----------------------------------------- | :------------------------------------------------------------------------------------------ |
| **Dùng `async def` trong FastAPI**         | **ĐÃ LOẠI BỎ.** Gây blocking toàn bộ Event Loop. Khắc phục bằng `def` + thread pool.        |
| **Build Dockerfile 1 giai đoạn**           | **ĐÃ LOẠI BỎ.** Image >1.5GB, chậm pull/push, chứa lỗ hổng bảo mật. Dùng multi-stage build. |
| **Giảm `n_ctx` để tiết kiệm RAM**          | **ĐÃ LOẠI BỎ.** "Thiến" khả năng dung nạp tài liệu truy xuất từ ChromaDB.                    |
| **Dùng mmap để ánh xạ RAM sang SSD**       | **ĐÃ LOẠI BỎ.** Tốc độ sinh token giảm không thể chấp nhận do I/O latency.                 |
| **Mount Vector DB trực tiếp từ Datastore** | **ĐÃ LOẠI BỎ.** Azure Managed Endpoint chỉ tự động mount duy nhất tài nguyên `model`.      |
| **Nướng (bake) model & DB vào Docker Image** | **ĐÃ LOẠI BỎ.** Làm phình Image, khó cập nhật, vi phạm Separation of Concerns.             |

## Lệnh và Cấu hình cụ thể đã dùng

### `requirements.txt` (cho FastAPI API)

```
fastapi==0.100.0
uvicorn==0.22.0
pydantic==2.0.0
langchain-huggingface==0.0.1
langchain-chroma==0.1.1
llama-cpp-python==0.3.16
```

### `Dockerfile` (Multi-stage cho CPU)

```dockerfile
# =============================================
# STAGE 1: BUILDER (Môi trường biên dịch)
# =============================================
FROM python:3.10-slim as builder

WORKDIR /build

# Cài đặt các công cụ biên dịch C++ và OpenBLAS để tối ưu CPU
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    libopenblas-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .

# Ép llama-cpp-python biên dịch với OpenBLAS để tận dụng đa luồng CPU
ENV CMAKE_ARGS="-DLLAMA_BLAS=ON -DLLAMA_BLAS_VENDOR=OpenBLAS"
ENV FORCE_CMAKE=1

# Biên dịch tất cả thư viện thành dạng .whl
RUN pip wheel --no-cache-dir --wheel-dir /build/wheels -r requirements.txt

# =============================================
# STAGE 2: RUNTIME (Môi trường thực thi)
# =============================================
FROM python:3.10-slim

WORKDIR /app

# Chỉ cài đặt thư viện runtime của OpenBLAS, KHÔNG mang theo gcc/cmake
RUN apt-get update && apt-get install -y --no-install-recommends \
    libopenblas0 \
    && rm -rf /var/lib/apt/lists/*

# Copy các gói đã biên dịch từ Stage 1 sang
COPY --from=builder /build/wheels /wheels
COPY --from=builder /build/requirements.txt .

# Cài đặt từ các gói nội bộ, không tải lại từ Internet
RUN pip install --no-cache-dir /wheels/*

# Xóa rác biên dịch
RUN rm -rf /wheels /build/requirements.txt

# Đưa mã nguồn vào container
COPY main.py schemas.py ./

# Mở cổng giao tiếp
EXPOSE 8000

# Lệnh khởi động Server
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

## Lệnh Build và Run Container

```powershell
# Build image
docker build -t qwen-rag-api:v1 .

# Run container với volume mount cho model và vector DB
docker run -d `
 --name genai-backend `
 -p 8000:8000 `
 -v ${PWD}/qwen3-4b-instruct-2507.Q4_K_M.gguf:/app/qwen3-4b-instruct-2507.Q4_K_M.gguf `
 -v ${PWD}/my_data/knowledge_db:/app/my_data/knowledge_db `
 qwen-rag-api:v1
```

### `build_db.py` (Chạy trong Azure ML Command Job)

```python
import json
import os
import sys
import argparse
import mlflow
from langchain_huggingface import HuggingFaceEmbeddings
from langchain_chroma import Chroma
from langchain_core.documents import Document

def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input_data", type=str, required=True)
    parser.add_argument("--output_db", type=str, required=True)
    return parser.parse_args()

def load_data(file_path):
    if not os.path.exists(file_path):
        print(f"[LỖI] Không tìm thấy file tại {file_path}.")
        sys.exit(1)
    with open(file_path, 'r', encoding='utf-8') as f:
        return json.load(f)

if __name__ == "__main__":
    args = parse_args()

    if not os.path.exists(args.output_db):
        os.makedirs(args.output_db)

    raw_data = load_data(args.input_data)

    # 1. Khởi động MLflow run
    mlflow.start_run()

    documents = []
    for item in raw_data:
        meta = item.get('metadata', {}).copy()
        meta['category'] = str(item.get('category', 'unknown'))
        meta['original_id'] = str(item.get('id', 'unknown'))
        if 'keywords' in meta:
            if isinstance(meta['keywords'], list):
                meta['keywords_str'] = ", ".join(meta['keywords'])
            del meta['keywords']

        doc = Document(page_content=item.get('content', ''), metadata=meta)
        documents.append(doc)

    # 2. Ghi nhận số liệu (Metrics)
    total_docs = len(documents)
    print(f"[INFO] Đã load {total_docs} bản ghi hợp lệ.")
    mlflow.log_metric("document_count", total_docs)
    mlflow.log_param("embedding_model", "bkai-foundation-models/vietnamese-bi-encoder")

    embedding_model = HuggingFaceEmbeddings(model_name="bkai-foundation-models/vietnamese-bi-encoder")

    vector_db = Chroma.from_documents(
        documents=documents,
        embedding=embedding_model,
        persist_directory=args.output_db
    )

    db_size_mb = sum(os.path.getsize(os.path.join(dirpath, filename)) for dirpath, _, filenames in os.walk(args.output_db) for filename in filenames) / (1024 * 1024)
    mlflow.log_metric("vector_db_size_mb", db_size_mb)

    print(f"[HOÀN TẤT] Vector DB ({db_size_mb:.2f} MB) lưu tại: {args.output_db}")

    # 3. Kết thúc run
    mlflow.end_run()
```

### `conda.yaml` (cho Data Pipeline)

```yaml
name: data-pipeline-en
channels:
  - conda-forge
dependencies:
  - python=3.10
  - pip
  - pip:
    - langchain-huggingface==0.0.1
    - langchain-chroma==0.1.1
    - huggingface-hub==0.16.4
    - chromadb==0.4.22
```

### `pipeline_job.yml` (Azure ML Command Job)

```yaml
$schema: https://azuremlschemas.azureedge.net/latest/commandJob.schema.json
experiment_name: build_knowledge_db_pipeline
compute: azureml:serverless
environment:
  image: mcr.microsoft.com/azureml/openmpi4.1.0-ubuntu20.04:latest
  conda_file: ./conda.yaml
inputs:
  profile_source:
    type: uri_file
    path: azureml:profile_json_data:1
    mode: ro_mount
outputs:
  vector_db_output:
    type: uri_folder
    path: azureml://datastores/workspaceblobstore/paths/vector_db/
    mode: rw_mount
command: >-
  python source/build_db.py --input_data ${inputs.profile_source} --output_db ${outputs.vector_db_output}
```

### `endpoint.yml` và `deployment.yml`

```yaml
# endpoint.yml
$schema: https://azuremlschemas.azureedge.net/latest/managedOnlineEndpoint.schema.json
name: qwen-rag-endpoint
auth_mode: key
```

```yaml
# deployment.yml
$schema: https://azuremlschemas.azureedge.net/latest/managedOnlineDeployment.schema.json
name: rag-deployment-v1
endpoint_name: qwen-rag-endpoint
model: azureml:qwen3-4b-gguf-model:1
environment:
  image: <TÊN_ACR_CỦA_BẠN>.azurecr.io/qwen-rag-api:v1
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
instance_type: Standard_DS3_v2
instance_count: 1
```

### `telegram_client.py` (Thin Client)

```python
import os
import telebot
import requests
import json
import time
from dotenv import load_dotenv
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient

load_dotenv()
KEY_VAULT_NAME = "qwen-rag-vault"
KV_URI = f"https://{KEY_VAULT_NAME}.vault.azure.net"

credential = DefaultAzureCredential()
client = SecretClient(vault_url=KV_URI, credential=credential)

TELEGRAM_TOKEN = client.get_secret("telegram-token").value
AZURE_ENDPOINT_URL = client.get_secret("azure-endpoint-url").value
AZURE_API_KEY = client.get_secret("azure-api-key").value

bot = telebot.TeleBot(TELEGRAM_TOKEN)
chat_histories = {}

SYSTEM_PROMPT = """Bạn là trợ lý AI ảo. Hãy trả lời ngắn gọn, chính xác và tự nhiên."""

@bot.message_handler(func=lambda message: True)
def handle_message(message):
    # ... (logic quản lý chat history và gọi API) ...
    pass

bot.infinity_polling()
```

### Script kiểm thử chịu tải (Stress Test)

```python
import os
import sys
import time
import requests
import concurrent.futures
import logging
from datetime import datetime
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient

# ... (Cấu hình logging và lấy secrets từ Key Vault) ...

CONCURRENCY_LEVELS = [1, 5, 15, 30, 50]
COOL_DOWN_SECONDS = 20
PAYLOAD = { "messages": [{"role": "user", "content": "Tóm tắt về tiểu sử của bạn trong 2 câu."}], "temperature": 0.2, "max_tokens": 1024 }

def send_request(user_id):
    # ... (gửi request và đo latency) ...

def run_stress_test():
    # ... (vòng lặp qua các mức concurrency, ghi log, phân tích kết quả) ...

if __name__ == "__main__":
    run_stress_test()
```

## Lỗi gặp phải và Cách khắc phục

| Lỗi / Anti-pattern                                                                                                              | Cách khắc phục / Quy tắc thiết lập                                                                                                           |
| :------------------------------------------------------------------------------------------------------------------------------ | :------------------------------------------------------------------------------------------------------------------------------------------- |
| **Thread Blocking** trong FastAPI (`async def` + tác vụ nặng)                                                                   | **Bắt buộc** sử dụng `def` (không `async`) cho endpoint chứa tác vụ CPU-bound để FastAPI chuyển vào ThreadPool.                               |
| **Docker Image >1.5GB** do chứa gcc/cmake                                                                                       | Áp dụng **Multi-stage Build**: Stage 1 biên dịch, Stage 2 chỉ copy wheels. Image cuối ~300-400MB.                                            |
| **OOMKilled** khi chạy Qwen 4B + ChromaDB trên máy ảo 7GB RAM                                                                  | Nâng cấp lên `Standard_DS3_v2` (14GB RAM). **Không** dùng thủ thuật giảm `n_ctx` hay `mmap`.                                                 |
| **Lỗi xác thực khi lấy secret từ Key Vault**                                                                                    | Chạy `az login` trên terminal để xác thực Managed Identity hoặc user account.                                                                |
| **Lỗi HTTP 429 (Too Many Requests / Overflow)** khi Stress Test với 5+ users đồng thời trên `Standard_DS2_v2`                  | Đây là **Graceful Degradation**. Hệ thống từ chối kết nối mới (overflow) thay vì crash (OOM). Chấp nhận giới hạn phần cứng.                 |
| **Hardcode Secrets (CWE-798)** trong mã nguồn                                                                                   | **Cấm** hardcode. Sử dụng `.env` cho local và **Azure Key Vault + Managed Identity** cho production. Thêm `.env` vào `.gitignore`.           |
| **Commit dữ liệu nhị phân (`.gguf`, `.sqlite3`, `.bin`) vào Git**                                                              | Thêm các pattern `*.gguf`, `*.sqlite3`, `*.bin`, `my_data/` vào `.gitignore`. Dùng `git rm --cached` để gỡ khỏi lịch sử.                    |
| **Hardcoded path trong `build_db.py`** (`os.path.dirname(__file__)`)                                                           | Sửa thành `argparse` để nhận đường dẫn từ Azure ML (`--input_data`, `--output_db`).                                                          |

## Lộ trình chi tiết

| Ngày | Mục tiêu                                                                                                                                                                                                     | Chỉ tiêu hoàn thành                                                                                                                                                                                                                  |
| :--- | :----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | :----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 2    | Cô lập ứng dụng với Docker; tối ưu CPU và image.                                                                                                                                                             | - Viết `Dockerfile` multi-stage.<br>- Build image.<br>- Chạy container với volume mount cho model và DB.<br>- Kiểm thử bottleneck với `docker stats`.                                                                                |
| 3    | Thiết lập hạ tầng Azure ML và đăng ký assets.                                                                                                                                                                | - Tạo Resource Group, Workspace.<br>- Đăng ký model Qwen GGUF vào Model Registry.<br>- Tải Vector DB lên Datastore.<br>- Xác định dùng Curated Environment cho Data Pipeline.                                                        |
| 4    | Xây dựng Data Pipeline để tự động tạo Vector DB từ `profile.json`.                                                                                                                                           | - Sửa `build_db.py` để dùng argparse.<br>- Tạo `conda.yaml`.<br>- Đăng ký `profile.json` như Data Asset.<br>- Viết và chạy `pipeline_job.yml`.<br>- Tích hợp MLflow tracking vào script.                                           |
| 5    | Triển khai Managed Online Endpoint.                                                                                                                                                                          | - Push Docker image lên ACR.<br>- Sửa code FastAPI để đọc model từ `AZUREML_MODEL_DIR`.<br>- Tạo `endpoint.yml` và `deployment.yml`.<br>- Deploy và lấy API Key, URL.                                                               |
| 6    | Tách Telegram Bot thành Thin Client; tích hợp MLflow.                                                                                                                                                        | - Viết lại `telegram_client.py` chỉ làm nhiệm vụ giao tiếp.<br>- Loại bỏ AI logic khỏi client.<br>- Cập nhật `build_db.py` với `mlflow.log_metric`.<br>- Xác định kiến trúc Zero-Trust cho secrets.                                |
| 7    | Đánh giá chịu tải; tái cấu trúc repository; viết tài liệu.                                                                                                                                                   | - Viết script `stress_test.py` (step-load testing).<br>- Cấu hình Auto-scaling rule.<br>- Purge Git history.<br>- Tái cấu trúc thư mục.<br>- Viết README.md chuyên nghiệp.<br>- Push lên GitHub.                                     |

## Khái niệm & Định nghĩa

- **Multi-stage Build (Docker):** Kỹ thuật chia Dockerfile thành nhiều giai đoạn (stages) để tối ưu dung lượng image. Stage đầu tiên dùng để biên dịch và tạo ra các artifact (wheels), stage sau chỉ copy artifact cần thiết, loại bỏ các công cụ biên dịch nặng.
    - **Ví dụ:** Stage `builder` cài gcc, cmake để biên dịch `llama-cpp-python`; Stage `runtime` chỉ copy file `.whl` đã biên dịch, không mang theo gcc.
- **Step-load Testing:** Phương pháp kiểm thử hiệu năng bằng cách tăng dần số lượng người dùng đồng thời (concurrency) theo từng bậc (step). Mục đích là tìm ra điểm gãy (breaking point) và quan sát hành vi của hệ thống khi quá tải.
    - **Ví dụ:** Test lần lượt với 1, 5, 15, 30, 50 users đồng thời, có thời gian nghỉ (cool-down) giữa các bậc.
- **Graceful Degradation (Suy thoái có kiểm soát):** Nguyên tắc thiết kế hệ thống sao cho khi gặp sự cố hoặc quá tải, hệ thống sẽ suy giảm chất lượng dịch vụ một cách có kiểm soát (ví dụ: từ chối request mới, trả về lỗi 429) thay vì sập hoàn toàn (crash).
    - **Ví dụ:** Azure Endpoint trả về HTTP 429 khi hàng đợi đầy, thay vì để container bị OOMKilled.
- **Zero-Trust Architecture:** Mô hình bảo mật giả định không có một thành phần nào (bên trong hay bên ngoài mạng) được tin cậy ngầm định. Mọi truy cập đều phải được xác thực và ủy quyền.
    - **Ví dụ:** Ứng dụng không hardcode secrets mà sử dụng Managed Identity để lấy credentials từ Azure Key Vault mỗi khi cần. Ngay cả khi Docker Image bị đánh cắp, kẻ tấn công cũng không có quyền truy cập vào Key Vault vì thiếu Managed Identity của máy ảo chạy image đó.

## Các phương án đã cân nhắc

| Phương án                                                                                              | Ưu điểm                                                                                                                | Nhược điểm                                                                                                                              | Được chọn? |
| :----------------------------------------------------------------------------------------------------- | :--------------------------------------------------------------------------------------------------------------------- | :-------------------------------------------------------------------------------------------------------------------------------------- | :--------- |
| **1. Chạy Telebot + FastAPI trên cùng một máy (monolithic)**                                          | Đơn giản, dễ triển khai.                                                                                               | Tốn tài nguyên, khó scale, dễ crash do OOM, rủi ro bảo mật khi hardcode token.                                                          | ❌         |
| **2. Tách Telebot thành Thin Client, FastAPI deploy lên Azure**                                       | **Tách biệt concern, scale độc lập, bảo mật tốt hơn.**                                                                 | Phức tạp hơn, phải quản lý nhiều thành phần.                                                                                            | ✅         |
| **3. Deploy FastAPI lên Azure VM (IaaS)**                                                             | Linh hoạt, kiểm soát hoàn toàn hệ điều hành.                                                                           | Phải tự quản lý OS, bảo mật, scaling, và chi phí cao hơn (trả tiền VM 24/7).                                                            | ❌         |
| **4. Deploy FastAPI lên Azure Container Apps / Web App**                                              | Dễ dàng hơn Managed Endpoint, tích hợp sẵn scaling.                                                                    | Không tích hợp sẵn Model Registry và MLOps features như Azure ML. Khó quản lý model version và data assets.                              | ❌         |
| **5. Deploy FastAPI lên Azure ML Managed Online Endpoint**                                            | **Tích hợp sẵn Model Registry, Datastore, Auto-scaling, và MLOps.** Quản lý model và data tập trung.                  | Có thể phức tạp hơn một chút so với Container Apps, nhưng phù hợp với bài toán.                                                          | ✅         |
| **6. Cập nhật Vector DB thủ công hoặc trong cùng container với FastAPI**                              | Đơn giản nhất.                                                                                                         | Không tách biệt, khó kiểm soát version, rủi ro ảnh hưởng đến serving.                                                                   | ❌         |
| **7. Tạo Data Pipeline riêng với Azure ML Command Job**                                              | **Tự động, tái tạo được, tách biệt hoàn toàn khỏi serving, tiết kiệm chi phí (compute chỉ chạy khi job chạy).**        | Phải viết thêm script và config.                                                                                                       | ✅         |
| **8. Lưu secrets trong .env file và commit lên GitHub (public/private)**                             | Dễ dàng.                                                                                                               | **CỰC KỲ NGUY HIỂM.** Rò rỉ secrets, bị tấn công chiếm đoạt billing hoặc bot.                                                          | ❌         |
| **9. Sử dụng Azure Key Vault + Managed Identity để lấy secrets**                                     | **An toàn tuyệt đối, Zero-Trust.** Secrets không bao giờ xuất hiện trong code hay image.                              | Cần thiết lập thêm và hiểu về RBAC.                                                                                                    | ✅         |
| **10. Giảm `n_ctx` để tiết kiệm RAM**                                                                 | Giảm RAM tiêu thụ.                                                                                                     | Giảm khả năng xử lý context, ảnh hưởng chất lượng RAG.                                                                                 | ❌         |
| **11. Sử dụng `mmap` để giảm RAM**                                                                    | Cho phép chạy model lớn hơn trên RAM ít hơn.                                                                           | Chậm hơn rất nhiều do I/O SSD.                                                                                                         | ❌         |
| **12. Nâng cấp máy ảo lên Standard_DS3_v2 (14GB RAM)**                                               | **Giải quyết triệt để bài toán RAM.**                                                                                  | Tăng chi phí (nhưng chấp nhận được so với lợi ích).                                                                                    | ✅         |
| **13. Chạy background task cho inference để không block main thread (trong FastAPI)**                | Giải phóng Event Loop.                                                                                                 | Async tasks (`asyncio.create_task`) phức tạp khi quản lý kết quả trả về cho client, dễ gây memory leak.                                 | ❌         |
| **14. Sử dụng FastAPI `def` endpoint (thread pool)**                                                 | **Đơn giản, hiệu quả, không block Event Loop.**                                                                        | Tăng CPU overhead nhẹ do chuyển context thread, nhưng không đáng kể so với lợi ích.                                                     | ✅         |

