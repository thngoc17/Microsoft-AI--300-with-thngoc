---
source_url: "N/A (nội dung từ file PDF azure-27.pdf, không có URL gốc)"
conversation_date: "2026-09-03"
context_week: "Tuần 1 (Ngày 2 → Ngày 7)"
conversation_types:
  - LAP_KE_HOACH
  - TRANH_LUAN_QUYET_DINH
  - FIX_CODE
  - FIX_HA_TANG
  - LY_THUYET
  - KIEM_TRA_KIEN_THUC
ai300_domains:
  - Design and implement MLOps infrastructure
  - Model lifecycle
  - GenAIOps infrastructure
  - GenAI quality assurance and observability
  - Optimize generative AI systems and model performance
technologies:
  - Azure Machine Learning (Azure ML)
  - Azure CLI (v2)
  - Azure Container Registry (ACR)
  - Azure Key Vault
  - Docker
  - FastAPI
  - Uvicorn
  - Qwen 4B (GGUF, qwen3-4b-instruct-2507.Q4_K_M.gguf)
  - LangChain
  - ChromaDB
  - HuggingFace Embeddings (bkai-foundation-models/vietnamese-bi-encoder)
  - MLflow
  - Llama.cpp
  - Conda
  - Git
  - Python (argparse, dotenv, telebot)
  - Telegram Bot API
  - Managed Online Endpoints
  - Command Jobs
  - Serverless Compute
  - Data Assets (uri_file, uri_folder)
  - Model Registry
  - Azure Blob Storage (Datastore)
key_decision: >
  Tái cấu trúc hệ thống RAG từ monolithic sang microservices: tách rẽ Serving Layer (FastAPI trên Managed Endpoint),
  Data Pipeline (Command Job trên serverless compute) và Thin Client (Telegram bot); áp dụng multi-stage Docker để tối ưu image,
  dùng Azure Key Vault + Managed Identity thay vì hardcode secret, và thiết lập guardrails cho RAG để tránh ảo giác trong demo.
status: resolved
---

## Bối cảnh & Vấn đề

Tài liệu ghi lại toàn bộ quá trình chuyển đổi từ một hệ thống **GenAI monolithic** (chạy trên máy Windows, Dockerfile 1 stage, RAM thiếu hụt) sang một kiến trúc **microservices + MLOps** trên Azure, trải qua các ngày từ Ngày 2 đến Ngày 7.

**Vấn đề cốt lõi được giải quyết theo tiến trình:**

- **Ngày 2:** Docker image quá lớn (>1.5GB), RAM trên máy ảo Azure `Standard_DS2_v2` (7GB) không đủ để chạy đồng thời LLM 4B + ChromaDB.
- **Ngày 3:** Lần đầu tiếp cận Azure ML v2, thiết lập Workspace, đăng ký model `qwen3-4b-gguf-model:1` và upload Vector DB lên Datastore.
- **Ngày 4:** Xây dựng Command Job tự động sinh Vector DB từ `profile.json`, loại bỏ hoàn toàn phần training, sử dụng Curated Environment.
- **Ngày 5:** Triển khai Managed Online Endpoint, push Docker image lên ACR, xử lý vấn đề mount model (dùng `AZUREML_MODEL_DIR`).
- **Ngày 6:** Chuyển Telegram bot thành Thin Client (chỉ gọi HTTP), tích hợp MLflow vào Data Pipeline.
- **Ngày 7:** Stress test, thiết lập auto-scaling, tái cấu trúc repository, xây dựng kịch bản demo và giải pháp xử lý ảo giác (hallucination).

---

## Quyết định cuối cùng & Lý do

| Quyết định / Kiến trúc | Lý do / Ưu điểm | Phương án bị loại bỏ (ĐÃ LOẠI BỎ) |
|---|---|---|
| **Sử dụng multi-stage Dockerfile** | Image cuối chỉ còn ~300–400MB (thay vì >1.5GB), tăng tốc pull/push lên ACR. | Dockerfile 1 giai đoạn chứa gcc/g++ → image quá lớn, không phù hợp với MLOps. |
| **Tách model (GGUF) và Vector DB ra khỏi image, mount khi runtime** | Áp dụng Separation of Concerns; model được Azure tự mount qua `AZUREML_MODEL_DIR`, Vector DB được tải từ Datastore khi khởi động FastAPI. | Nướng (bake) cả model và DB vào image → image quá nặng, không linh hoạt khi cập nhật. |
| **Nâng cấp máy ảo lên `Standard_DS3_v2` (14GB RAM)** | Đảm bảo không bị OOM khi chạy Qwen 4B + ChromaDB đồng thời. | Dùng `Standard_DS2_v2` (7GB) → gây OOM, dùng mmap trên SSD làm chậm token generation. |
| **Sử dụng Azure Managed Identity + Key Vault** | Zero-Trust, không hardcode secret trong source code, an toàn ngay cả khi mã nguồn bị lộ. | Hardcode TELEGRAM_TOKEN và AZURE_API_KEY trực tiếp trong code (CWE-798) — bị đánh giá là lỗ hổng bảo mật nghiêm trọng, không được chấp nhận. |
| **Dùng .env + python-dotenv cho local client** | Cách ly secret khỏi Git, dễ dàng cấu hình cho từng môi trường. | Lưu secret trong file `.env` nhưng thiếu `.gitignore` → nguy cơ commit nhầm lên public repo. |
| **Data Pipeline dùng Command Job + serverless compute** | Tự động hóa 100% quá trình tạo Vector DB; job tự tắt sau khi chạy để tiết kiệm chi phí. | Dùng Custom Docker Image của API cho job → image nặng, chứa llama-cpp-python không cần thiết. |
| **RAG guardrail: similarity_search_with_score + threshold** | Lọc bỏ context có điểm số >1.5, tránh nhồi nhét dữ liệu sai vào LLM. | Luôn lấy `k=2` bất kể độ tương tự → gây nhiễu và ảo giác. |
| **Client-side mask: dùng parse_mode="HTML" + html.escape** | Tránh lỗi parse Markdown do ký tự đặc biệt, bọc thép chống crash khi context có dấu `_`, `*`, `[`, `]`. | Dùng parse_mode="Markdown" khi gửi context → dễ bị Telegram API trả về lỗi 400, làm crash bot. |
| **Kịch bản Demo "Đường mòn Trải hoa"** | Chứng minh kiến trúc hoạt động (RAG, logging, monitoring), che giấu điểm yếu của model do thiếu dữ liệu. | Để user tự do nhập câu hỏi bất kỳ → bot dễ bị ảo giác và RAG kém, làm giảm giá trị trình diễn. |

---

## Lệnh và Cấu hình cụ thể đã dùng

### 1. Dockerfile (multi-stage)

```dockerfile
FROM python:3.11-slim AS builder

WORKDIR /build

# Cài đặt gcc/g++ để biên dịch llama-cpp-python
RUN apt-get update && \
    apt-get install -y --no-install-recommends gcc g++ && \
    rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# =========================
FROM python:3.11-slim

WORKDIR /app

COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin

# Xóa rác biên dịch
RUN rm -rf /wheels /build/requirements.txt

# Đưa mã nguồn vào container
COPY main.py schemas.py ./

# Mở cổng giao tiếp
EXPOSE 8000

# Lệnh khởi động Server
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

### 2. PowerShell – build & run trên Windows

```powershell
# Build image
docker build -t qwen-rag-api:v1 .

# Chạy container với volume mount
docker run -d `
  --name genai-backend `
  -p 8000:8000 `
  -v ${PWD}/qwen3-4b-instruct-2507.Q4_K_M.gguf:/app/qwen3-4b-instruct-2507.Q4_K_M.gguf `
  -v ${PWD}/my_data/knowledge_db:/app/my_data/knowledge_db `
  qwen-rag-api:v1
```

### 3. Azure CLI – Workspace & Model Registration

```bash
az extension add -n ml -y
az login
az configure --defaults group="genai-resource-group" workspace="rag-workspace" location="southeastasia"

# Tạo resource group và workspace
az group create --name "genai-resource-group" --location "southeastasia"
az ml workspace create --name "rag-workspace"

# Đăng ký model (model.yml)
az ml model create --file model.yml
```

**model.yml**
```yaml
$schema: https://azuremlschemas.azureedge.net/latest/model.schema.json
name: qwen3-4b-gguf-model
version: 1
path: ./qwen3-4b-instruct-2507.Q4_K_M.gguf
type: custom_model
description: "Mô hình Qwen 4B đã lượng từ hóa Q4_K_M phục vụ cho RAG inference trên CPU."
```

### 4. Upload Vector DB lên Datastore

```powershell
$STORAGE_ACCOUNT = az ml workspace show --query storage_account -o tsv | Split-Path -Leaf
az storage blob upload-batch `
  --destination "https://$STORAGE_ACCOUNT.blob.core.windows.net/azureml-blobstore-<YOUR_BLOB_ID>/vector_db" `
  --source ". \my_data\knowledge_db" `
  --auth-mode login
```

### 5. Data Pipeline – build_db.py (argparse, MLflow)

```python
import argparse
import json
import os
import sys
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
        print(f"X LỖI: Không tìm thấy file tại {file_path}.")
        sys.exit(1)
    with open(file_path, 'r', encoding='utf-8') as f:
        return json.load(f)

if __name__ == "__main__":
    args = parse_args()
    if not os.path.exists(args.output_db):
        os.makedirs(args.output_db)

    raw_data = load_data(args.input_data)

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

    # MLflow tracking
    mlflow.start_run()
    total_docs = len(documents)
    mlflow.log_metric("document_count", total_docs)
    mlflow.log_param("embedding_model", "bkai-foundation-models/vietnamese-bi-encoder")

    embedding_model = HuggingFaceEmbeddings(model_name="bkai-foundation-models/vietnamese-bi-encoder")
    vector_db = Chroma.from_documents(
        documents=documents,
        embedding=embedding_model,
        persist_directory=args.output_db
    )

    db_size_mb = sum(os.path.getsize(os.path.join(dirpath, filename))
                     for dirpath, _, filenames in os.walk(args.output_db)
                     for filename in filenames) / (1024 * 1024)
    mlflow.log_metric("vector_db_size_mb", db_size_mb)
    mlflow.end_run()

    print(f"HOÀN TẤT! Vector DB ({db_size_mb:.2f} MB) lưu tại: {args.output_db}")
```

### 6. conda.yaml (Data Environment)

```yaml
name: data-pipeline-env
channels:
  - conda-forge
dependencies:
  - python=3.11
  - pip
  - pip:
    - langchain-huggingface
    - langchain-chroma
    - langchain-core
    - mlflow
    - sentence-transformers
    - chromadb
```

### 7. profile_data.yml (Data Asset)

```yaml
$schema: https://azuremlschemas.azureedge.net/latest/data.schema.json
name: profile_json_data
version: 1
type: uri_file
path: ./my_data/profile.json
description: "Dữ liệu cá nhân dạng JSON để sinh Vector Database"
```

### 8. pipeline_job.yml (Command Job)

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
code: command: >
  python source/build_db.py
  --input_data ${inputs.profile_source}
  --output_db ${outputs.vector_db_output}
```

### 9. endpoint.yml

```yaml
$schema: https://azuremlschemas.azureedge.net/latest/managedOnlineEndpoint.schema.json
name: qwen-rag-endpoint
auth_mode: key
```

### 10. deployment.yml

```yaml
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

### 11. FastAPI – sửa đường dẫn model (AZUREML_MODEL_DIR)

```python
import os
model_dir = os.getenv("AZUREML_MODEL_DIR")
if model_dir is None:
    raise RuntimeError("Không tìm thấy AZUREML_MODEL_DIR. Bảo lỗi cấu hình Deployment.")
model_path = os.path.join(model_dir, "qwen3-4b-instruct-2507.Q4_K_M.gguf")
```

### 12. Thin Client – telegram_client.py (có .env)

```python
import os
import html
import time
import requests
import telebot
from dotenv import load_dotenv

load_dotenv()
TELEGRAM_TOKEN = os.getenv("TELEGRAM_TOKEN")
AZURE_API_KEY = os.getenv("AZURE_API_KEY")
AZURE_ENDPOINT_URL = os.getenv("AZURE_ENDPOINT_URL")

if not TELEGRAM_TOKEN or not AZURE_API_KEY or not AZURE_ENDPOINT_URL:
    raise ValueError("Lỗi: Chưa cấu hình đầy đủ TELEGRAM_TOKEN, AZURE_API_KEY, AZURE_ENDPOINT_URL trong .env")

bot = telebot.TeleBot(TELEGRAM_TOKEN)
chat_histories = {}
SYSTEM_PROMPT = """Bạn là trợ lý AI ảo. Hãy trả lời ngắn gọn, chính xác và tự nhiên."""

@bot.message_handler(func=lambda message: True)
def handle_message(message):
    chat_id = message.chat.id
    user_text = message.text
    if chat_id not in chat_histories:
        chat_histories[chat_id] = [{"role": "system", "content": SYSTEM_PROMPT}]
    chat_histories[chat_id].append({"role": "user", "content": user_text})
    if len(chat_histories[chat_id]) > 10:
        chat_histories[chat_id] = [chat_histories[chat_id][0]] + chat_histories[chat_id][-8:]

    bot.send_chat_action(chat_id, 'typing')

    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {AZURE_API_KEY}"
    }
    payload = {
        "messages": chat_histories[chat_id],
        "temperature": 0.01,
        "max_tokens": 1024
    }

    try:
        start_time = time.time()
        response = requests.post(AZURE_ENDPOINT_URL, headers=headers, json=payload, timeout=120)
        response.raise_for_status()
        response_data = response.json()

        ai_reply = response_data.get("reply", "")
        retrieved_context = response_data.get("retrieved_context", "")
        processing_time = response_data.get("processing_time", 0)

        # Client-side mask
        ai_reply = ai_reply.replace("[Gửi một hình ảnh]", "").replace("[Gửi một video]", "").replace("<|im_end|>", "").strip()
        if len(ai_reply) < 2:
            ai_reply = "Xin lỗi, đường truyền tin hiệu từ bộ nhớ của tôi đang bị gián đoạn."

        chat_histories[chat_id].append({"role": "assistant", "content": ai_reply})

        # Hiển thị RAG context (HTML-safe)
        if retrieved_context.strip():
            safe_context = html.escape(retrieved_context)
            debug_msg = f"<b>[RAG TRUY XUẤT]</b>:\n<pre>{safe_context}</pre>\n\n<i>Độ trễ xử lý:</i> {processing_time:.2f}s"
            bot.reply_to(message, debug_msg, parse_mode="HTML")
        else:
            bot.reply_to(message, "<i>[Debug Alert] RAG không truy xuất được ngữ cảnh (Dữ liệu rỗng hoặc bị chặn)</i>", parse_mode="HTML")

        time.sleep(0.5)
        if len(ai_reply) > 4000:
            for part in [ai_reply[i:i+4000] for i in range(0, len(ai_reply), 4000)]:
                bot.reply_to(message, part)
                time.sleep(0.3)
        else:
            bot.reply_to(message, ai_reply)

    except requests.exceptions.Timeout:
        bot.reply_to(message, "Cloud system is overloaded. Please wait.")
        chat_histories[chat_id].pop()
    except Exception as e:
        print(f"CRITICAL ERROR: {e}")
        bot.reply_to(message, "Hệ thống gặp sự cố trong lúc phân tích cú pháp hoặc mất kết nối.")
        chat_histories[chat_id].pop()

bot.infinity_polling()
```

### 13. .gitignore

```
my_data/
*.sqlite3
*.bin
*.gguf
*.pt
*.safetensors
.env
__pycache__/
*.pyc
.venv/
venv/
```

---

## Lỗi gặp phải và Cách khắc phục

| Lỗi / Vấn đề | Nguyên nhân | Cách khắc phục |
|---|---|---|
| **Docker image >1.5GB** | Dockerfile 1 giai đoạn giữ lại gcc/g++ và các file build. | Chuyển sang multi-stage: builder stage cài gcc, final stage chỉ copy site-packages và binary, xóa rác. |
| **OOMKilled trên Standard_DS2_v2 (7GB)** | Qwen 4B + ChromaDB cần >7GB RAM. | Nâng lên Standard_DS3_v2 (14GB). Không dùng mmap vì làm giảm tốc độ token generation. |
| **Hardcode secret trong source** | TELEGRAM_TOKEN, AZURE_API_KEY gắn trực tiếp. | Dùng .env + python-dotenv cho local; trên cloud dùng Azure Key Vault + Managed Identity. |
| **Lỗi 400 Bad Request khi gửi context Telegram** | parse_mode="Markdown" không escape được ký tự `_`, `*`, `[`, `]` trong context. | Chuyển sang parse_mode="HTML", dùng `html.escape()` để escape toàn bộ context. |
| **RAG nhiễu, trả lời sai ngữ cảnh** | ChromaDB luôn lấy `k=2` bất kể độ tương tự, nhồi nhét context sai. | Dùng `similarity_search_with_score` và lọc threshold (ví dụ score < 1.5), nếu không có context hợp lệ thì bỏ qua RAG. |
| **Ảo giác (hallucination) trong demo** | Model yếu, thiếu dữ liệu, temperature 0.2 vẫn khuyến khích sáng tạo. | Giảm temperature xuống 0.01, cập nhật system prompt yêu cầu "KHÔNG bịa đặt", dùng guardrail threshold. |
| **MLflow không hiển thị metrics** | Quên cài mlflow trong conda.yaml và gọi `mlflow.start_run()` / `mlflow.log_metric` | Thêm mlflow vào conda.yaml, gọi start_run trước khi xử lý và end_run sau khi hoàn tất. |
| **Data Pipeline không tìm thấy file input** | Hardcoded path trong build_db.py; Azure mount dữ liệu vào thư mục tạm. | Sửa build_db.py dùng argparse để nhận `--input_data` và `--output_db` từ Command Job. |

---

## Lộ trình chi tiết

| Ngày | Mốc chính | Mục tiêu | Chỉ tiêu hoàn thành |
|---|---|---|---|
| **Ngày 2** | Tối ưu Docker, kiểm thử RAM | – Viết Dockerfile multi-stage<br>– Build & run container<br>– Đo tài nguyên bằng `docker stats` | Image < 500MB, xác định được giới hạn RAM của Standard_DS2_v2 (7GB) là không đủ. |
| **Ngày 3** | Thiết lập Azure ML, đăng ký model | – Cài Azure CLI extension `ml`<br>– Tạo Resource Group & Workspace<br>– Đăng ký model `qwen3-4b-gguf-model:1`<br>– Upload Vector DB lên Datastore | Workspace hoạt động; model và data asset hiển thị trong Azure ML Studio. |
| **Ngày 4** | Xây dựng Data Pipeline | – Sửa `build_db.py` với argparse + MLflow<br>– Tạo `conda.yaml`<br>– Tạo `profile_data.yml`, `pipeline_job.yml`<br>– Chạy `az ml job create` và stream log | Job chạy thành công, Vector DB được sinh và lưu trên Datastore, metrics hiển thị trên MLflow. |
| **Ngày 5** | Triển khai Managed Online Endpoint | – Push Docker image lên ACR<br>– Sửa `main.py` dùng `AZUREML_MODEL_DIR`<br>– Tạo `endpoint.yml`, `deployment.yml`<br>– Chạy `az ml online-endpoint create`, `az ml online-deployment create` | Endpoint hoạt động, nhận request và trả về response; lấy được scoring_uri và API key. |
| **Ngày 6** | Tách Telegram Client, tích hợp MLflow | – Viết `telegram_client.py` dùng `.env`<br>– Loại bỏ logic ML khỏi client<br>– Cấy MLflow vào `build_db.py` | Client chỉ làm HTTP thin client; Data Pipeline ghi log metrics (document_count, db_size). |
| **Ngày 7** | Stress test, Auto-scaling, Refactor Repo | – Chạy `stress_test.py`<br>– Cấu hình auto-scale<br>– Dọn dẹp Git (`.gitignore`, xóa binary)<br>– Viết README mới<br>– Xây dựng kịch bản demo (golden path) | Hệ thống chịu được 10-20 concurrent request; auto-scale bảo vệ ngân sách; repo sạch, có README và demo video. |

---

## Khái niệm & Định nghĩa

| Thuật ngữ | Định nghĩa | Ví dụ minh hoạ |
|---|---|---|
| **Multi-stage Docker** | Kỹ thuật dùng nhiều `FROM` trong Dockerfile: stage builder để biên dịch/install, stage final chỉ copy artifact cần thiết. | Builder stage cài gcc/g++ để build llama-cpp-python; final stage chỉ copy binary và site-packages, xóa gcc để giảm dung lượng. |
| **Managed Identity (Azure)** | "Căn cước công dân đám mây" – định danh an toàn cho Azure resource, không cần lưu secret. | Endpoint dùng Managed Identity để truy cập Key Vault mà không cần hardcode token. |
| **Azure ML Command Job** | Job chạy một command duy nhất trên compute cluster, tự động mount input/output, có thể kết hợp conda environment. | `az ml job create --file pipeline_job.yml --stream` chạy `build_db.py` với input là profile.json, output là Vector DB. |
| **Model Registry** | Kho lưu trữ có version cho model, cho phép gọi bằng tên và version trong deployment. | `model: azureml:qwen3-4b-gguf-model:1` – khi cần nâng cấp model chỉ việc tăng version, deployment code không đổi. |
| **Thin Client vs Fat Client** | Thin Client chỉ làm nhiệm vụ giao tiếp mạng và hiển thị; Fat Client chứa toàn bộ logic ML, nặng và dễ sập. | Telegram bot cũ (Fat) nạp model embedding + ChromaDB; bot mới (Thin) chỉ gọi HTTP lên Azure Endpoint. |
| **RAG Guardrail** | Cơ chế lọc/kiểm soát để tránh LLM dùng context sai hoặc ảo giác. | `similarity_search_with_score` + ngưỡng score < 1.5; nếu không có context hợp lệ thì bỏ qua RAG và chỉ gửi query gốc. |
| **MLflow Tracking** | Ghi nhận metrics, params, artifacts của mỗi lần chạy model/pipeline, giúp so sánh và theo dõi hiệu năng. | Log `document_count` và `vector_db_size_mb` vào job; xem biểu đồ trên Azure ML Studio → Jobs → Metrics. |
| **YAGNI (You Aren't Gonna Need It)** | Nguyên tắc phát triển: không thêm tính năng cho đến khi thực sự cần. | Loại bỏ toàn bộ phần training và `process_data.py` khỏi pipeline vì hệ thống chỉ cần inference RAG. |
| **Zero-Trust Security** | Không tin tưởng bất kỳ thành phần nào, luôn xác thực và phân quyền tối thiểu. | Dùng Managed Identity + Key Vault; không hardcode secret, kể cả trong code hay .env trên cloud. |

---

## Các phương án đã cân nhắc

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
|---|---|---|---|
| **Dùng Standard_DS2_v2 (7GB) + mmap** | Chi phí thấp hơn | Tốc độ token generation chậm do I/O SSD, dễ bị OOM khi load ChromaDB. | KHÔNG – bị loại do hiệu năng kém. |
| **Nâng lên Standard_DS3_v2 (14GB)** | Đủ RAM, không cần mmap, tốc độ ổn định. | Chi phí cao hơn một chút. | CÓ – đảm bảo ổn định cho demo. |
| **Hardcode secret trong source** | Đơn giản, nhanh. | Rò rỉ bảo mật (CWE-798), dễ bị khai thác nếu push lên public repo. | KHÔNG – bị loại do lỗ hổng bảo mật. |
| **.env + python-dotenv (local)** | Tách biệt cấu hình, dễ dàng thay đổi, không commit secret. | Vẫn lưu secret ở dạng plaintext trên ổ cứng. | CÓ cho local client – đủ tốt cho demo. |
| **Azure Key Vault + Managed Identity** | Zero-Trust, không lưu secret dạng text, an toàn ngay cả khi bị lộ code. | Cần cấu hình thêm, phức tạp hơn. | Được khuyến nghị cho production nhưng chưa triển khai trong phạm vi dự án. |
| **Dùng Custom Docker Image cho Data Pipeline** | Tận dụng lại image đã có. | Image nặng, chứa thư viện C++ không cần thiết cho embedding. | KHÔNG – chọn Curated Environment + conda.yaml để nhẹ và tách biệt. |
| **Dùng parse_mode="Markdown" cho Telegram** | Hỗ trợ định dạng phong phú. | Dễ crash khi context chứa ký tự đặc biệt (`_`, `*`, `[`, `]`). | KHÔNG – chuyển sang HTML + html.escape để bọc thép. |

---

## Nhật ký câu hỏi – trả lời – đánh giá

| Câu hỏi / Case study | Câu trả lời của người dùng | Đánh giá | Đáp án / Giải thích chuẩn |
|---|---|---|---|
| **"Tại sao tôi không in được kết quả RAG qua màn hình?"** | (Người dùng không đưa ra câu trả lời, chỉ nêu câu hỏi) | - | Nguyên nhân: 1) parse_mode="Markdown" bị lỗi 400 do ký tự đặc biệt; 2) khối `if retrieved_context:` bỏ qua khi context rỗng; 3) thiếu client-side mask xóa cụm [Gửi một hình ảnh]. Giải pháp: dùng parse_mode="HTML" + html.escape, thêm fallback khi context rỗng, thêm mask xóa rác. |
| **"Chi tiết công việc ngày 3"** | (Người dùng yêu cầu hướng dẫn, không đưa ra câu trả lời) | - | Đáp án là toàn bộ nội dung Ngày 3 trong tài liệu: thiết lập Azure ML Workspace, đăng ký model, upload Vector DB. Không có câu hỏi trắc nghiệm. |
| **"Chi tiết ngày 4 đi. Lưu ý rằng Data Pipeline của tôi có 2 điểm cần lưu ý..."** | (Người dùng đưa ra yêu cầu cụ thể, không phải câu trả lời) | - | Đáp án là toàn bộ nội dung Ngày 4: sửa build_db.py, dùng Curated Environment, tạo Command Job. Không có câu hỏi trắc nghiệm. |
| **"Nghe rất ngổ khi đem cả 2 loại key gắn vô thẳng source. Hãy đánh giá..."** | Người dùng nhận xét về việc hardcode key là "ngổ", yêu cầu đánh giá và giải pháp. | Đúng | Giải pháp đúng: dùng .env + python-dotenv cho local, và Azure Key Vault + Managed Identity cho cloud. Hardcode bị đánh giá là CWE-798 – lỗ hổng bảo mật. |
| **"Làm sao để tôi show RAG hoạt động nhỉ (Tôi không biết kết quả RAG được show ở đâu)"** | Người dùng không biết cách hiển thị kết quả RAG. | - | Đáp án: sửa telegram_client.py để lấy `retrieved_context` từ response, hiển thị bằng parse_mode="HTML" + html.escape, kèm thông báo fallback khi context rỗng. |
| **"Ngoài RAG, Chatbot tele và Log Server trên ml studio ra thì tôi có cần show gì khác trên demo nữa không?"** | Người dùng hỏi về nội dung demo. | - | Đáp án: ngoài RAG, cần show 3 phần: 1) Azure ML Studio – Jobs + MLflow metrics; 2) Endpoint Healthy + Monitor (latency, CPU); 3) Split-screen: Telegram + terminal log. |