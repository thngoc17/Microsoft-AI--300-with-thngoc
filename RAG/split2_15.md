---
source_url: https://gemini.google.com/app/284bd22fba5d2bb3
conversation_date: 2026-08-06
context_week: "Tuần 2–3 (Sprint 7 ngày: 28/07/2026 – 03/08/2026)"
conversation_types: [LAP_KE_HOACH, TRANH_LUAN_QUYET_DINH, FIX_CODE, FIX_HA_TANG, LY_THUYET, KIEM_TRA_KIEN_THUC]
ai300_domains: [Design and implement MLOps infrastructure, GenAIOps infrastructure, Optimize generative AI systems and model performance]
technologies: [Azure ML, FastAPI, Docker, ChromaDB, LangChain, llama-cpp-python, MLflow, Azure Key Vault, Azure Container Registry, Azure Blob Storage, Telegram Bot API, Pydantic, Uvicorn, HuggingFace Embeddings, Qwen, Azure CLI, RBAC, Managed Identity]
key_decision: "Rã đông kiến trúc monolithic (telebot + inference) thành stateless FastAPI serving layer và Telegram thin client, triển khai lên Azure ML Managed Endpoint với Zero-Trust security (Key Vault + Managed Identity), tối ưu chi phí bằng compute cluster auto-scale (min_instances: 0)."
status: resolved
---

## Bối cảnh & Vấn đề

Hệ thống chatbot hiện tại đang là một **kiến trúc nguyên khối (monolithic)** gộp chung:
- Giao diện Telegram (telebot + infinity_polling)
- Logic lõi (RAG + LLM inference)
- Lưu trữ trạng thái phiên (chat_histories dictionary toàn cục)

Các vấn đề kỹ thuật cụ thể:
- **Rò rỉ bộ nhớ (memory leak)** do dictionary toàn cục tích lũy lịch sử không giới hạn.
- **Không thể mở rộng theo chiều ngang (horizontal scaling)** do stateful.
- **Chi phí rảnh rỗi** từ Compute Instance chạy 24/7.
- **Thread blocking** khi async def chạy CPU-heavy tasks (LLM inference) → event loop bị khóa, không nhận request mới.
- **Volume mounts bị khóa cứng** trên Managed Endpoint: chỉ mount được model qua `AZUREML_MODEL_DIR`, không thể mount vector DB từ Datastore tùy ý.

## Quyết định cuối cùng & Lý do

### Quyết định chiến lược

**Chọn: Rã đông mã nguồn Telegram sang FastAPI và Docker ngay lập tức** (ưu tiên hơn data pipeline).

Lý do:
- Điểm nghẽn nằm ở **serving layer**, không phải data processing.
- Docker và REST API là những khâu **đòi hỏi độ cọ xát kỹ thuật khắt khe nhất** → cần "Fail Fast" để phát hiện sớm rủi ro.
- Data pipeline (Command Job) mang lại **cảm giác tiến triển giả tạo** nếu serving layer vẫn chưa hoạt động.

**Phương án bị loại bỏ:**
- ❌ KHÔNG ưu tiên cấu hình Command Job cho Data Pipeline trước → vì rủi ro sụp đổ dự án nằm ở khả năng làm chủ Docker và thiết kế REST API.

### Kiến trúc Serving Layer

| Quyết định | Lý do |
|---|---|
| **Dùng FastAPI thay vì telebot** | Tách biệt UI và logic core, đảm bảo Separation of Concerns. |
| **Stateless API** | Không lưu session memory cục bộ; toàn bộ lịch sử được truyền qua HTTP payload. |
| **Synchronous def thay vì async def** | FastAPI tự động đẩy synchronous task vào ThreadPool, không block event loop. |
| **Lifespan context manager** | Khởi tạo embedding, vector DB, LLM khi startup; giải phóng khi shutdown. |
| **Llama.cpp trực tiếp (không qua Ngrok)** | Loại bỏ network latency, inference nội bộ trong container. |
| **Multi-stage Docker build** | Tối thiểu hóa dung lượng image (~300-400MB thay vì 1.5GB), loại bỏ trình biên dịch khỏi runtime. |
| **Model Registry thay vì nướng checkpoint vào image** | Checkpoint được đăng ký vào Azure ML Model Registry, mount tại runtime → dễ dàng update version. |
| **Nâng cấp VM lên Standard_DS3_v2 (14GB RAM)** | Tránh OOMKilled khi vừa nạp Qwen 4B vừa cấp phát buffer cho ChromaDB. |
| **Azure Key Vault + Managed Identity (Zero-Trust)** | Không hardcode secret; xác thực qua DefaultAzureCredential, không cần token. |

**Phương án bị loại bỏ:**
- ❌ KHÔNG dùng `async def` với `asyncio.to_thread` → phức tạp không cần thiết; `def` synchronous đủ tốt.
- ❌ KHÔNG giảm `n_ctx` hoặc dùng mmap để tiết kiệm RAM → ảnh hưởng chất lượng/tốc độ.
- ❌ KHÔNG dùng custom Docker image cho data pipeline → dùng Curated Environment của Azure ML để giảm rủi ro xung đột thư viện và kích thước.

### Kiến trúc Data Pipeline

| Quyết định | Lý do |
|---|---|
| **Dùng Curated Environment (openmpi4.1.0-ubuntu20.04 + conda.yaml)** | Tách biệt môi trường serving (nặng, có C++) và data processing (nhẹ, chỉ Python thuần). |
| **Command Job với min_instances: 0 (serverless)** | Tự động ngắt điện khi không vận hành → tối ưu chi phí. |
| **Đăng ký profile.json là Data Asset (uri_file)** | Quản lý phiên bản dữ liệu đầu vào. |
| **MLflow tracking** | Ghi nhận document_count, vector_db_size_mb, embedding_time → đo lường hiệu suất pipeline. |
| **Argparse thay vì hardcoded paths** | Đảm bảo script nhận đường dẫn động từ Azure khi mount dữ liệu. |

**Phương án bị loại bỏ:**
- ❌ KHÔNG đăng ký vector DB vào Model Registry → nó là **dữ liệu biến động**, không phải model tĩnh.
- ❌ KHÔNG dùng lại Docker image của API cho Command Job → chứa llama-cpp-python và C++ compiler, quá nặng và không cần thiết.
- ❌ KHÔNG giữ lại `process_data.py` (training) → áp dụng YAGNI, loại bỏ hoàn toàn phần training.

### Bảo mật

| Quyết định | Lý do |
|---|---|
| **Azure Key Vault + DefaultAzureCredential** | Zero-Trust: không lưu secret dạng plaintext ở bất kỳ đâu. |
| **RBAC: Key Vault Secrets Officer** | Chỉ cấp quyền đọc secret cho Managed Identity của endpoint. |
| **.env + python-dotenv (giải pháp tạm thời)** | Dùng cho thin client cục bộ, nhưng không an toàn bằng Key Vault. |

**Phương án bị loại bỏ:**
- ❌ KHÔNG hardcode TELEGRAM_TOKEN và AZURE_API_KEY vào source code (CWE-798) → rủi ro bảo mật nghiêm trọng.
- ❌ KHÔNG commit .env vào Git → thêm vào .gitignore.

## Lệnh và Cấu hình cụ thể đã dùng

### schemas.py (Pydantic models)

```python
from pydantic import BaseModel
from typing import List, Optional

class Message(BaseModel):
    role: str
    content: str

class ChatRequest(BaseModel):
    messages: List[Message]
    temperature: Optional[float] = 0.2
    max_tokens: Optional[int] = 1024

class ChatResponse(BaseModel):
    reply: str
    retrieved_context: str
    processing_time: float
```

### main.py (FastAPI với lifespan và synchronous endpoint)

```python
from fastapi import FastAPI, HTTPException
from contextlib import asynccontextmanager
from langchain_huggingface import HuggingFaceEmbeddings
from langchain_chroma import Chroma
from llama_cpp import Llama
import time
import os
from schemas import ChatRequest, ChatResponse

ml_models = {}

@asynccontextmanager
async def lifespan(app: FastAPI):
    db_path = os.path.join(os.path.dirname(__file__), '..', 'my_data', 'knowledge_db')
    try:
        ml_models["embedding"] = HuggingFaceEmbeddings(
            model_name="bkai-foundation-models/vietnamese-bi-encoder"
        )
        ml_models["vector_db"] = Chroma(
            persist_directory=db_path,
            embedding_function=ml_models["embedding"]
        )
    except Exception as e:
        raise RuntimeError(f"Lỗi khởi tạo Vector DB: {e}")
    
    model_dir = os.getenv("AZUREML_MODEL_DIR")
    if model_dir is None:
        raise RuntimeError("Không tìm thấy AZUREML_MODEL_DIR. Báo lỗi cấu hình Deployment.")
    model_path = os.path.join(model_dir, "qwen3-4b-gguf-model", "qwen3-4b-instruct-2507.Q4_K_M.gguf")
    
    ml_models["llm"] = Llama(
        model_path=model_path,
        n_ctx=4096,
        n_gpu_layers=0
    )
    yield
    ml_models.clear()

app = FastAPI(lifespan=lifespan)

@app.post("/chat", response_model=ChatResponse)
def chat_endpoint(request: ChatRequest):  # synchronous, không async
    start_time = time.time()
    user_query = request.messages[-1].content
    vector_db = ml_models["vector_db"]
    results = vector_db.similarity_search(user_query, k=2)
    context_str = "\n".join([f"- {doc.page_content}" for doc in results]) if results else ""
    
    if context_str:
        augmented_prompt = f"[THÔNG TIN NỀN VỀ BẠN]:\n{context_str}\n\n[CÂU HỎI]:\n{user_query}"
        request.messages[-1].content = augmented_prompt
    
    formatted_messages = [{"role": m.role, "content": m.content} for m in request.messages]
    llm = ml_models["llm"]
    try:
        response = llm.create_chat_completion(
            messages=formatted_messages,
            max_tokens=request.max_tokens,
            temperature=request.temperature,
            stop=["<|im_end|>", "<|endoftext|>"]
        )
        ai_reply = response["choices"][0]["message"]["content"].strip()
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    
    process_time = time.time() - start_time
    return ChatResponse(reply=ai_reply, retrieved_context=context_str, processing_time=process_time)
```

### requirements.txt

```text
fastapi==0.100.0
uvicorn==0.22.0
pydantic==2.0.0
langchain-huggingface==0.0.1
langchain-chroma==0.1.1
llama-cpp-python==0.3.16
```

### Dockerfile (Multi-stage build)

```dockerfile
# =========================================
# STAGE 1: BUILDER (Môi trường biên dịch)
# =========================================
FROM python:3.10-slim as builder

WORKDIR /build

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    libopenblas-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .

ENV CMAKE_ARGS="-DLAMA_BLAS=ON -DLAMA_BLAS_VENDOR=OpenBLAS"
ENV FORCE_CMAKE=1

RUN pip wheel --no-cache-dir --wheel-dir /build/wheels -r requirements.txt

# =========================================
# STAGE 2: RUNTIME (Môi trường thực thi)
# =========================================
FROM python:3.10-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    libopenblas-dev \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/wheels /wheels
COPY --from=builder /build/requirements.txt .

RUN pip install --no-cache-dir /wheels/*

RUN rm -rf /wheels /build/requirements.txt

COPY main.py schemas.py ./

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

### build_db.py (với argparse + MLflow)

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
        print(f"✖ LỖI: Không tìm thấy file tại {file_path}.")
        sys.exit(1)
    with open(file_path, 'r', encoding='utf-8') as f:
        return json.load(f)

if __name__ == "__main__":
    args = parse_args()
    if not os.path.exists(args.output_db):
        os.makedirs(args.output_db)

    raw_data = load_data(args.input_data)
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

    total_docs = len(documents)
    print(f"📖 Đã load {total_docs} bản ghi hợp lệ.")
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
    print(f"✅ HOÀN TẤT! Vector DB ({db_size_mb:.2f} MB) lưu tại: {args.output_db}")

    mlflow.end_run()
```

### conda.yaml (Data Environment)

```yaml
name: data-pipeline-env
channels:
  - conda-forge
dependencies:
  - python=3.10
  - pip:
    - langchain-huggingface==0.0.1
    - langchain-chroma==0.1.1
    - mlflow
```

### profile_data.yaml

```yaml
$schema: https://azuremlschemas.azureedge.net/latest/data.schema.json
name: profile_json_data
version: 1
type: uri_file
path: ./my_data/profile.json
description: "Dữ liệu cá nhân dạng JSON để sinh Vector Database"
```

### pipeline_job.yml (Command Job)

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
  python source/build_db.py
  --input_data ${{inputs.profile_source}}
  --output_db ${{outputs.vector_db_output}}
```

### model.yml

```yaml
$schema: https://azuremlschemas.azureedge.net/latest/model.schema.json
name: qwen3-4b-gguf-model
version: 1
path: ./qwen3-4b-instruct-2507.Q4_K_M.gguf
type: custom_model
description: "Mô hình Qwen 4B đã lượng từ hóa Q4_K_M phục vụ cho RAG inference trên CPU."
```

### endpoint.yml

```yaml
$schema: https://azuremlschemas.azureedge.net/latest/managedOnlineEndpoint.schema.json
name: qwen-rag-endpoint
auth_mode: key
```

### deployment.yml

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

### telegram_client.py (Zero-Trust với Azure Key Vault)

```python
import sys
import time
import requests
import telebot
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient
from azure.core.exceptions import ClientAuthenticationError, ResourceNotFoundError

# ==============================================
# 1. XÁC THỰC & TRÍCH XUẤT BÍ MẬT TỪ KEY VAULT
# ==============================================
KEY_VAULT_NAME = "tên-duy-nhất-cho-vault-của-bạn"
KV_URI = f"https://{KEY_VAULT_NAME}.vault.azure.net"

print(f"🔐 Đang xác thực với Azure Key Vault: {KV_URI}...")

try:
    credential = DefaultAzureCredential()
    client = SecretClient(vault_url=KV_URI, credential=credential)

    TELEGRAM_TOKEN = client.get_secret("telegram-token").value
    AZURE_ENDPOINT_URL = client.get_secret("azure-endpoint-url").value
    AZURE_API_KEY = client.get_secret("azure-api-key").value
    print("✅ Đã giải mã thành công toàn bộ khóa cấu hình.")

except ClientAuthenticationError:
    print("❌ LỖI XÁC THỰC: Không thể chứng minh danh tính với Azure.")
    print("👉 Hãy mở PowerShell và chạy lệnh: 'az login' để cấp quyền truy cập cục bộ.")
    sys.exit(1)
except ResourceNotFoundError as e:
    print(f"❌ LỖI TÀI NGUYÊN: Không tìm thấy Secret trong Vault. Chi tiết: {e}")
    sys.exit(1)
except Exception as e:
    print(f"❌ LỖI KHÔNG XÁC ĐỊNH KHI KẾT NỐI KEY VAULT: {e}")
    sys.exit(1)

# ==============================================
# 2. KHỞI TẠO ỨNG DỤNG THIN CLIENT
# ==============================================
bot = telebot.TeleBot(TELEGRAM_TOKEN)
chat_histories = {}
SYSTEM_PROMPT = "Bạn là trợ lý AI. Trả lời ngắn gọn, trực tiếp và chính xác."

def split_text(text, limit=4000):
    return [text[i:i + limit] for i in range(0, len(text), limit)]

# ==============================================
# 3. LUỒNG THỰC THI CHÍNH (EVENT LOOP)
# ==============================================
@bot.message_handler(func=lambda message: True)
def handle_message(message):
    chat_id = message.chat.id
    user_text = message.text
    print(f"👤 [User-{chat_id}]: {user_text}")

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
        "temperature": 0.2,
        "max_tokens": 1024
    }

    try:
        start_time = time.time()
        response = requests.post(
            AZURE_ENDPOINT_URL,
            headers=headers,
            json=payload,
            timeout=120
        )
        response.raise_for_status()
        response_data = response.json()
        ai_reply = response_data.get("reply", "")
        processing_time = response_data.get("processing_time", 0)
        print(f"📤 [Backend Azure] (Độ trễ: {processing_time:.2f}s): {ai_reply}")

        chat_histories[chat_id].append({"role": "assistant", "content": ai_reply})

        if len(ai_reply) > 4000:
            for part in split_text(ai_reply):
                bot.reply_to(message, part)
                time.sleep(0.3)
        else:
            bot.reply_to(message, ai_reply)

    except requests.exceptions.Timeout:
        print(f"❌ [Timeout]: Azure Endpoint không phản hồi.")
        bot.reply_to(message, "⚠️ Hệ thống đám mây đang quá tải hoặc khởi động. Vui lòng đợi và thử lại.")
        chat_histories[chat_id].pop()

    except requests.exceptions.RequestException as e:
        print(f"❌ [HTTP Error]: {e}")
        bot.reply_to(message, "⚠️ Lỗi giao tiếp với Backend AI.")
        chat_histories[chat_id].pop()

if __name__ == "__main__":
    print("🚀 Telegram Thin Client (Zero-Trust Architecture) đã khởi động...")
    bot.infinity_polling()
```

### Lệnh Azure CLI

```powershell
# Cài đặt extension ML
az extension add -n ml -y

# Đăng nhập
az login

# Thiết lập mặc định
az configure --defaults group="genai-resource-group" workspace="rag-workspace" location="southeastasia"

# Tạo resource group và workspace
az group create --name "genai-resource-group" --location "southeastasia"
az ml workspace create --name "rag-workspace"

# Đăng ký model
az ml model create --file model.yml

# Đăng ký data asset
az ml data create --file profile_data.yaml

# Chạy Command Job
az ml job create --file pipeline_job.yml --stream

# Đẩy image lên ACR
az acr login --name <TÊN_ACR>
docker tag qwen-rag-api:v1 <TÊN_ACR>.azurecr.io/qwen-rag-api:v1
docker push <TÊN_ACR>.azurecr.io/qwen-rag-api:v1

# Tạo endpoint và deployment
az ml online-endpoint create --file endpoint.yml
az ml online-deployment create --file deployment.yml --all-traffic

# Lấy URL và key
az ml online-endpoint show --name qwen-rag-endpoint --query scoring_uri -o tsv
az ml online-endpoint get-credentials --name qwen-rag-endpoint --query primaryKey -o tsv

# Lấy storage account
$STORAGE_ACCOUNT = az ml workspace show --query storage_account -o tsv | Split-Path -Leaf

# Upload vector DB
az storage blob upload-batch \
  --destination "https://$STORAGE_ACCOUNT.blob.core.windows.net/azureml-blobstore-<YOUR_BLOB_ID>/vector_db" \
  --source ".\my_data\knowledge_db" \
  --auth-mode login
```

### Lệnh Azure Key Vault

```powershell
$KEY_VAULT_NAME = "tên-duy-nhất-cho-vault-của-bạn"
$RESOURCE_GROUP = "genai-resource-group"

# Tạo Key Vault
az keyvault create --name $KEY_VAULT_NAME --resource-group $RESOURCE_GROUP --location "southeastasia"

# Cấp RBAC cho tài khoản của bạn
$USER_UPN = az ad signed-in-user show --query userPrincipalName -o tsv
az role assignment create --role "Key Vault Secrets Officer" --assignee $USER_UPN --scope "/subscriptions/${az account show --query id -o tsv}/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.KeyVault/vaults/$KEY_VAULT_NAME"

# Bơm secrets
az keyvault secret set --vault-name $KEY_VAULT_NAME --name "telegram-token" --value "123456789:ABCdefGHIJklMN0pqrSTU"
az keyvault secret set --vault-name $KEY_VAULT_NAME --name "azure-endpoint-url" --value "https://qwen-rag-endpoint.southeastasia.inference.ml.azure.com/chat"
az keyvault secret set --vault-name $KEY_VAULT_NAME --name "azure-api-key" --value "mã_khóa_chính_của_endpoint"
```

## Lỗi gặp phải và Cách khắc phục

| Lỗi / Anti-pattern | Cách khắc phục |
|---|---|
| **Hardcoded credentials (CWE-798)** — gắn TELEGRAM_TOKEN, AZURE_API_KEY thẳng vào source code. | Dùng Azure Key Vault + Managed Identity (Zero-Trust). Không lưu secret dạng plaintext. |
| **Gộp UI và inference (Monolithic)** — telebot + RAG + LLM cùng file. | Tách thành FastAPI (serving layer) và Telegram thin client. |
| **async def blocking event loop** — CPU-heavy LLM inference khóa event loop. | Dùng `def` synchronous để FastAPI đẩy vào ThreadPool. |
| **ChromaDB lỗi với metadata chứa list** — `metadata['keywords']` là list → ChromaDB báo lỗi. | Chuyển list thành string (`keywords_str`), xóa list cũ. |
| **Hardcoded paths trong build_db.py** — `os.path.dirname(__file__)` không hoạt động trên Azure. | Dùng `argparse` để nhận đường dẫn từ command line. |
| **Volume mounts không hỗ trợ Datastore tùy ý** — Managed Endpoint chỉ mount được model qua AZUREML_MODEL_DIR. | Pull vector DB từ Blob Storage vào container lúc runtime (qua lifespan). |
| **OOMKilled trên Standard_DS2_v2 (7GB RAM)** — Qwen 4B + ChromaDB buffer vượt ngưỡng. | Nâng cấp lên Standard_DS3_v2 (14GB RAM). |
| **Custom Docker image quá nặng (1.5GB)** — do chứa gcc, cmake. | Dùng multi-stage build: runtime chỉ giữ libopenblas, image ~300-400MB. |
| **Nướng checkpoint vào Docker image** — khó update model, image cồng kềnh. | Đăng ký model vào Model Registry, mount tại runtime. |
| **Compute Instance chạy 24/7** — hao hụt ngân sách. | Dùng Compute Cluster với min_instances: 0 (serverless). |

## Lộ trình chi tiết (Sprint 7 ngày)

| Ngày | Mục tiêu | Chỉ tiêu hoàn thành |
|---|---|---|
| **Ngày 1 (28/07/2026)** | Rã đông lớp phục vụ, phát triển REST API (FastAPI). | Tách telebot khỏi logic core; endpoint /chat hoạt động cục bộ với Swagger UI. |
| **Ngày 2 (29/07/2026)** | Containerization & kiểm thử cục bộ. | Dockerfile multi-stage build thành công; container chạy trên Windows với volume mount model và vector DB. |
| **Ngày 3 (30/07/2026)** | Kiến tạo hạ tầng Azure & Model Registry. | Azure ML Workspace khởi tạo; model .gguf đăng ký vào Model Registry; vector DB upload lên Datastore. |
| **Ngày 4 (31/07/2026)** | Tự động hóa Data Pipeline (Command Job). | build_db.py chạy thành công trên Azure với argparse + MLflow; vector DB tự động cập nhật. |
| **Ngày 5 (01/08/2026)** | Triển khai Điểm cuối (Managed Online Endpoint). | Image push lên ACR; endpoint và deployment YAML khởi tạo; API có thể nhận request qua Internet. |
| **Ngày 6 (02/08/2026)** | Đo lường MLflow & Tái cấu trúc Client. | MLflow log metrics trong data pipeline; Telegram bot chuyển thành thin client (gọi API, không chạy inference). |
| **Ngày 7 (03/08/2026)** | Đánh giá nút thắt cổ chai (Bottleneck Assessment). | Theo dõi throughput, latency, auto-scaling; xác nhận chi phí tối ưu. |

## Khái niệm & Định nghĩa

| Thuật ngữ | Định nghĩa | Ví dụ trong hệ thống |
|---|---|---|
| **Stateless API** | API không lưu trạng thái phiên; toàn bộ context được client gửi qua payload. | FastAPI endpoint `/chat` nhận `messages` array đầy đủ, không dùng `chat_histories` dictionary toàn cục. |
| **Lifespan context manager** | FastAPI cơ chế khởi tạo và dọn dẹp tài nguyên khi server start/stop. | Khởi tạo HuggingFaceEmbeddings, Chroma, Llama trong `@asynccontextmanager`; `ml_models.clear()` khi shutdown. |
| **ThreadPool vs Event Loop** | FastAPI `async def` chạy trên event loop (single-thread); `def` synchronous được đẩy vào ThreadPool (multi-thread). | Dùng `def` cho `/chat` để không block event loop khi LLM inference chạy 2-5 giây. |
| **Multi-stage Docker build** | Chia Dockerfile thành nhiều stage: builder (có compiler) và runtime (chỉ lấy artifacts). | Stage 1 biên dịch llama-cpp-python với OpenBLAS; Stage 2 chỉ copy .whl, bỏ gcc/cmake. |
| **Separation of Concerns** | Tách biệt các thành phần có trách nhiệm khác nhau. | Telegram (UI) tách khỏi FastAPI (serving layer); data pipeline (processing) tách khỏi inference (serving). |
| **Zero-Trust Architecture** | Không tin tưởng bất kỳ request nào từ bên ngoài; xác thực liên tục. | Azure Key Vault + Managed Identity: secret không bao giờ xuất hiện dạng plaintext; chỉ Managed Identity của endpoint mới được đọc. |
| **YAGNI (You Aren't Gonna Need It)** | Không xây dựng tính năng chưa cần thiết. | Loại bỏ `process_data.py` (training) vì đã quyết định không fine-tune, chỉ dùng RAG + inference. |
| **MLflow Tracking** | Ghi nhận metrics, params, artifacts trong quá trình chạy ML pipeline. | Log `document_count`, `vector_db_size_mb`, `embedding_model` trong Command Job. |

## Các phương án đã cân nhắc

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
|---|---|---|---|
| **Ưu tiên Data Pipeline trước** (Command Job) | Tự động hóa sớm, giảm thao tác thủ công. | Rủi ro sụp đổ dự án nằm ở serving layer (Docker, API) → trì hoãn phát hiện lỗi. | ❌ Không |
| **Ưu tiên Serving Layer trước** (FastAPI + Docker) | Fail Fast: phát hiện sớm vấn đề kiến trúc quan trọng nhất. | Data pipeline phải làm sau, nhưng không ảnh hưởng đến core logic. | ✅ Có |
| **Giữ async def cho endpoint** | Tuân thủ best practice của FastAPI. | Block event loop → không nhận request mới trong khi inference. | ❌ Không |
| **Dùng synchronous def** | FastAPI tự đẩy vào ThreadPool, event loop rảnh. | Tốn thread nhưng chấp nhận được với CPU-bound tasks. | ✅ Có |
| **Giảm n_ctx hoặc dùng mmap** | Tiết kiệm RAM, có thể dùng Standard_DS2_v2 (7GB). | Giảm chất lượng (n_ctx thấp) hoặc tốc độ chậm (mmap). | ❌ Không |
| **Nâng cấp VM lên Standard_DS3_v2 (14GB)** | Đủ RAM cho Qwen 4B + ChromaDB buffer. | Tăng chi phí, nhưng vẫn nằm trong ngân sách. | ✅ Có |
| **Custom Docker image cho Data Pipeline** | Tận dụng lại image của API. | Chứa llama-cpp-python và C++ compiler, rất nặng và không cần thiết. | ❌ Không |
| **Curated Environment của Azure ML** | Nhẹ, chỉ chứa Python và các thư viện cần thiết. | Phải viết conda.yaml riêng. | ✅ Có |
| **Hardcode credentials vào source code** | Nhanh, đơn giản. | Rủi ro bảo mật nghiêm trọng (CWE-798). | ❌ Không |
| **.env + python-dotenv** | Tách biệt cấu hình khỏi mã nguồn, dễ dùng. | Vẫn còn file văn bản trên ổ cứng, có thể bị lộ. | ✅ Chọn tạm thời cho client cục bộ |
| **Azure Key Vault + Managed Identity** | Zero-Trust: không lưu secret dạng plaintext ở bất kỳ đâu. | Phức tạp hơn, yêu cầu RBAC. | ✅ Chọn chính thức |

## Nhật ký câu hỏi – trả lời – đánh giá

| Câu hỏi / Case Study | Câu trả lời của người dùng | Đúng/Sai | Đáp án / Giải thích chuẩn |
|---|---|---|---|
| **Ngày 1:** "Kiến trúc mới ép buộc RAG và LLM Inference phải chạy đồng bộ trong cùng tiến trình C++. Vì bạn đang hướng tới triển khai trên CPU của Azure với tài nguyên giới hạn, bạn dự định giải quyết vấn đề nghẽn luồng (thread blocking) nếu có nhiều HTTP Request gửi tới API cùng một thời điểm như thế nào?" | *(Người dùng chưa trả lời, chỉ đặt câu hỏi ở cuối Ngày 1, sau đó bắt đầu Ngày 2)* | — | **Giải pháp được đề xuất (Ngày 2):** Dùng `def` synchronous thay vì `async def` để FastAPI đẩy vào ThreadPool. Không dùng `asyncio.to_thread`. |
| **Ngày 2:** "Bạn sẽ xử lý kịch bản thiếu hụt RAM này như thế nào nếu bắt buộc phải triển khai lên máy ảo 7GB của Azure: Cấu hình lại n_ctx của Llama.cpp để giảm lượng RAM cấp phát trước, hay hy sinh tốc độ bằng cách ánh xạ bộ nhớ ảo (mmap) lên ổ cứng SSD?" | *(Người dùng chưa trả lời, chỉ đặt câu hỏi ở cuối Ngày 2, sau đó bắt đầu Ngày 3)* | — | **Giải pháp được đề xuất (Ngày 3):** Không dùng thủ thuật phần mềm; nâng cấp VM lên Standard_DS3_v2 (14GB RAM). |
| **Ngày 3:** "Trong tư duy thiết kế Command Job, bạn quyết định sử dụng môi trường Docker tự chế từ Ngày 2 để chạy luồng cập nhật dữ liệu, hay sử dụng một Curated Environment (môi trường đóng gói sẵn) của Azure để giảm rủi ro xung đột thư viện?" | *(Người dùng chưa trả lời, chỉ đặt câu hỏi ở cuối Ngày 3, sau đó bắt đầu Ngày 4)* | — | **Giải pháp được đề xuất (Ngày 4):** Dùng Curated Environment (openmpi4.1.0-ubuntu20.04 + conda.yaml), không dùng custom image của API. |
| **Ngày 4:** "Ở Ngày 5, Managed Endpoint sẽ cần một cơ chế để nhận diện và nạp thư mục knowledge_db này từ Datastore vào bên trong Docker Container (FastAPI). Bạn định cấu hình volume_mounts trong tệp Deployment YAML hay tải trực tiếp thư mục này xuống vùng nhớ cục bộ của Container khi khởi động ứng dụng?" | *(Người dùng chưa trả lời, chỉ đặt câu hỏi ở cuối Ngày 4, sau đó bắt đầu Ngày 5)* | — | **Giải pháp được đề xuất (Ngày 5):** Không dùng volume_mounts (bị hardcode chỉ cho model). Pull vector DB từ Blob Storage vào container lúc runtime qua lifespan. |
| **Ngày 5:** "Bạn muốn tích hợp MLflow vào Pipeline trước để giám sát độ trễ, hay ưu tiên viết lại Telegram Client ngay để hoàn thiện luồng gửi nhận tin nhắn End-to-End?" | *(Người dùng chưa trả lời, chỉ đặt câu hỏi ở cuối Ngày 5, sau đó bắt đầu Ngày 6)* | — | **Giải pháp được đề xuất (Ngày 6):** Làm cả hai: MLflow vào build_db.py và Telegram thin client cùng ngày. |
| **Ngày 7 (không có trong hội thoại, chỉ được đề cập trong lịch trình):** "Bạn muốn tôi vạch ra các kịch bản kiểm tra áp lực (Stress Test) để xem máy ảo Azure sập ở ngưỡng bao nhiêu người dùng đồng thời, hay thiết lập cấu hình tự động co giãn (Auto-scaling) để bảo vệ ngân sách?" | *(Không có phản hồi từ user)* | — | **Đáp án được đề xuất:** Cần cả hai: stress test để biết giới hạn, auto-scaling (instance_count: 1..3) để bảo vệ chi phí. |
| **Ngày 6 (phần bảo mật):** "Nghe rất ngổ khi đem cả 2 loại key gắn vô thẳng source. Hãy đánh giá xem giải pháp đó như thế nào và xem xét các giải pháp khác nếu có." | User phản hồi: đồng ý hardcode là sai, yêu cầu đánh giá. | ✅ Đúng | **Phân tích:** Hardcode credentials là CWE-798, vi phạm bảo mật. Giải pháp: .env (tạm thời) hoặc Azure Key Vault + Managed Identity (chính thức). User chọn Key Vault. |
| **Ngày 6 (phần bảo mật - tiếp):** User yêu cầu mã nguồn telegram_client theo Azure Key Vault. | User: "Không. Theo cái azure key vault kìa." | ✅ Đúng | **Đáp án:** Cung cấp mã nguồn đầy đủ với DefaultAzureCredential, SecretClient, xử lý ClientAuthenticationError, ResourceNotFoundError. |