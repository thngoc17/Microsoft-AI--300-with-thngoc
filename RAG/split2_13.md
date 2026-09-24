---
source_url: https://gemini.google.com/app/b69f8ed51b6ed235
conversation_date: 2026-07-28
context_week: Tuần 2 và Tuần 3
conversation_types: [LAP_KE_HOACH, FIX_CODE, LY_THUYET, FIX_HA_TANG, TRANH_LUAN_QUYET_DINH]
ai300_domains: [Thiết kế và triển khai hạ tầng MLOps, Hạ tầng GenAIOps, Tối ưu hệ thống AI tạo sinh và hiệu năng mô hình]
technologies: [Azure ML, FastAPI, Docker, LangChain, ChromaDB, Llama.cpp, MLflow, Azure Container Registry, Azure Blob Storage]
key_decision: "Tập trung vào phát triển FastAPI và Docker ngay từ đầu thay vì Data Pipeline để bộc lộ sớm rủi ro ở Serving Layer; sử dụng Multi-stage Docker build để giảm kích thước image; áp dụng serverless compute cho Data Pipeline để tiết kiệm chi phí; tách biệt hoàn toàn checkpoint mô hình (Model Registry) và Vector DB (Datastore) khỏi mã nguồn container."
status: resolved
---

## Bối cảnh & Vấn đề

- Kiến trúc hệ thống chatbot hiện tại là monolithic: gộp chung logic UI (Telegram Bot) và logic lõi (Inference/RAG) trong cùng một tiến trình, sử dụng vòng lặp `infinity_polling()` và dictionary toàn cục `chat_histories` để lưu trạng thái.
- Vấn đề chi phí: Compute Instance bị tốn kém ngay cả khi không hoạt động. Cần chuyển sang cơ chế tự động tắt/mở (auto-scaling) với `min_instances: 0`.
- Yêu cầu chuyển đổi sang kiến trúc GenAIOps với trọng tâm là RAG và Inference trên CPU, loại bỏ khâu huấn luyện.

## Quyết định cuối cùng & Lý do

- **Quyết định chiến lược:** Phát triển FastAPI và Docker ngay lập tức (Ngày 1 và 2) thay vì cấu hình Command Job cho Data Pipeline (dời sang Ngày 4). Quyết định này dựa trên nguyên tắc "Fail Fast": rủi ro lớn nhất không nằm ở xử lý dữ liệu mà nằm ở khả năng làm chủ Docker và thiết kế REST API.
- **Kiến trúc API:** Xây dựng REST API phi trạng thái (stateless) với FastAPI, không lưu lịch sử hội thoại (phải được truyền qua payload). Sử dụng *synchronous endpoint (`def`)* thay vì `async def` để tránh block event loop khi thực thi RAG và LLM inference.
- **Containerization:** Áp dụng **Multi-stage Build** cho Dockerfile để tối ưu dung lượng image (loại bỏ trình biên dịch C++ khỏi runtime image).
- **Xử lý RAM:** Sử dụng máy ảo có RAM lớn hơn (Standard_DS3_v2) hoặc điều chỉnh tham số `n_ctx` để giảm mức tiêu thụ bộ nhớ của Llama.cpp.
- **Quản lý tài nguyên:**
    - **Model Checkpoint:** Đăng ký vào Azure ML Model Registry (dạng `custom_model`) để quản lý phiên bản. **KHÔNG** nướng checkpoint vào Docker image (anti-pattern).
    - **Vector DB:** Lưu trữ trên Azure Blob Storage (Datastore) và mount vào container khi runtime. **KHÔNG** đăng ký vào Model Registry (vì là dữ liệu, không phải model). **KHÔNG** sử dụng `serverless` compute trong Command Job YAML; thay vào đó dùng khối `resources` để kích hoạt cơ chế serverless.

## Lệnh và Cấu hình cụ thể đã dùng

### A. FastAPI Schemas (`schemas.py`)
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

### B. FastAPI Lifespan & Endpoint (`main.py`)
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
    # Khởi tạo Vector DB
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
    
    # Tích hợp trực tiếp Llama.cpp
    model_path = os.path.join(os.path.dirname(__file__), 'qwen3-4b-instruct-2507.Q4_K_M.gguf')
    ml_models["llm"] = Llama(
        model_path=model_path,
        n_ctx=4096,
        n_gpu_layers=0  # Inference trên CPU
    )
    
    yield
    ml_models.clear()

app = FastAPI(lifespan=lifespan)

@app.post("/chat", response_model=ChatResponse)
def chat_endpoint(request: ChatRequest):  # Quan trọng: dùng def thay vì async def
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

### C. Multi-stage Dockerfile cho CPU Inference
```dockerfile
# STAGE 1: BUILDER
FROM python:3.10-slim as builder
WORKDIR /build
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential cmake libopenblas-dev && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
ENV CMAKE_ARGS="-DLAMA_BLAS=ON -DLAMA_BLAS_VENDOR=OpenBLAS"
ENV FORCE_CMAKE=1
RUN pip wheel --no-cache-dir --wheel-dir /build/wheels -r requirements.txt

# STAGE 2: RUNTIME
FROM python:3.10-slim
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends \
    libopenblas-dev && rm -rf /var/lib/apt/lists/*
COPY --from=builder /build/wheels /wheels
COPY --from=builder /build/requirements.txt .
RUN pip install --no-cache-dir /wheels/*
RUN rm -rf /wheels /build/requirements.txt
COPY main.py schemas.py ./
EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

### D. Lệnh tạo Data Asset và Command Job (sau khi sửa lỗi)
**File `profile_data.yml`** (đặt trong thư mục `source`):
```yaml
$schema: https://azuremlschemas.azureedge.net/latest/data.schema.json
name: profile_json_data
version: 1
type: uri_file
path: ../my_data/profile.json  # Quan trọng: đường dẫn tương đối từ thư mục source ra ngoài
description: "Dữ liệu cá nhân dạng JSON để sinh Vector Database"
```

**Lệnh đăng ký Data Asset:**
```bash
az ml data create --file profile_data.yml --resource-group mlops-rg --workspace-name mlops-workspace
```

**File `pipeline_job.yml` (phiên bản sửa lỗi):**
```yaml
$schema: https://azuremlschemas.azureedge.net/latest/commandJob.schema.json
experiment_name: build_knowledge_db_pipeline
resources:
  instance_type: Standard_DS3_v2  # Thay vì compute: azureml:serverless
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
code: .  # Vì đang đứng trong thư mục source
command: >-
  python build_db.py
  --input_data ${{inputs.profile_source}}
  --output_db ${{outputs.vector_db_output}}
```

**Lệnh chạy Job:**
```bash
az ml job create --file pipeline_job.yml --resource-group mlops-rg --workspace-name mlops-workspace --stream
```

## Lỗi gặp phải và Cách khắc phục

1. **Lỗi Unknown compute target 'serverless'**
   - **Nguyên nhân:** Không thể gọi `compute: azureml:serverless` trực tiếp.
   - **Cách khắc phục:** Thay thế bằng khối `resources` với `instance_type: Standard_DS3_v2`.
2. **Lỗi CouldNotResolveUris (Data Asset not found)**
   - **Nguyên nhân:** File `profile_data.yml` có đường dẫn `path: ./my_data/profile.json` trong khi thực thi từ thư mục `source`, hoặc Asset chưa được đăng ký thành công.
   - **Cách khắc phục:** Sửa đường dẫn thành `../my_data/profile.json` và đăng ký lại Asset bằng lệnh `az ml data create`. Đảm bảo lệnh này chạy thành công trước khi chạy Job.

## Lộ trình chi tiết

### Sprint 7 Ngày (28/07/2026 – 03/08/2026)
| Ngày | Nhiệm vụ | Chỉ tiêu hoàn thành |
| :--- | :--- | :--- |
| **Ngày 1** | Rã đông Lớp Phục vụ & Phát triển REST API (FastAPI) | Endpoint POST `/chat` hoạt động stateless, đọc được Vector DB và checkpoint cục bộ. |
| **Ngày 2** | Containerization & Kiểm thử Cục bộ (Multi-stage Dockerfile) | Image build thành công, chạy được container trên Windows với volume mount cho model và Vector DB. |
| **Ngày 3** | Kiến tạo Hạ tầng Azure & Model Registry | Workspace, Resource Group tạo thành công; checkpoint được đăng ký lên Model Registry dạng `custom_model`. |
| **Ngày 4** | Tự động hóa Data Pipeline (Command Job) | Job chạy thành công trên serverless compute, tạo `knowledge_db` mới trên Datastore. |
| **Ngày 5** | Triển khai Điểm cuối (Managed Online Endpoint) | Endpoint hoạt động, kết hợp Image từ ACR và Checkpoint từ Model Registry. |
| **Ngày 6** | Đo lường MLflow & Tái cấu trúc Client | Data Pipeline log đủ metadata (số bản ghi, thời gian embedding). Telegram Bot được chuyển thành Client API thuần túy. |
| **Ngày 7** | Đánh giá Nút thắt Cổ chai (Bottleneck Assessment) | Đo throughput/latency, đánh giá hiệu quả chi phí của compute cluster tự động tắt/mở. |

## Khái niệm & Định nghĩa

| Thuật ngữ | Định nghĩa | Ví dụ từ hội thoại |
| :--- | :--- | :--- |
| **Stateless API** | API không lưu trạng thái phiên (session) cục bộ. Toàn bộ thông tin cần thiết (ví dụ lịch sử chat) phải được gửi kèm trong mỗi request. | Không dùng dictionary `chat_histories` toàn cục nữa; thay vào đó, client gửi mảng `messages` qua payload. |
| **Multi-stage Build** | Kỹ thuật Docker chia quá trình build thành nhiều giai đoạn. Giai đoạn đầu cài đặt công cụ biên dịch, giai đoạn sau chỉ copy kết quả biên dịch vào image chạy, giúp giảm dung lượng. | Stage 1 cài `build-essential` và `cmake` để compile `llama-cpp-python`, Stage 2 chỉ copy các file `.whl` đã build và cài đặt. |
| **Serverless Compute (Azure ML)** | Cơ chế Azure tự động cấp phát máy ảo theo yêu cầu và ngắt điện khi không hoạt động. Không cần khai báo compute cluster trước. | Khai báo `resources: instance_type: Standard_DS3_v2` thay vì `compute: azureml:serverless`. |
| **Model Registry** | Kho lưu trữ tập trung để quản lý phiên bản các mô hình ML. Cho phép theo dõi và triển khai các phiên bản cụ thể. | Đăng ký `qwen3-4b-gguf-model` dạng `custom_model`, phiên bản 1. |
| **Fail Fast** | Nguyên tắc phát triển phần mềm: ưu tiên xử lý các rủi ro/nút thắt lớn nhất ngay từ đầu để phát hiện thất bại sớm, tránh lãng phí. | Chọn làm FastAPI và Docker trước thay vì Data Pipeline vì khâu này có rủi ro cao hơn (Docker, API design). |

## Các phương án đã cân nhắc

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
| :--- | :--- | :--- | :--- |
| **Sử dụng Async endpoint (`async def`)** | Hỗ trợ nhiều request đồng thời tốt hơn trên lý thuyết. | Sẽ block event loop nếu có tác vụ CPU-bound (RAG + LLM inference) bên trong. | **KHÔNG**. Chọn `def` để FastAPI tự động đẩy vào thread pool ngoài. |
| **Nướng (bake) checkpoint và Vector DB vào Docker Image** | Dễ dàng triển khai, không cần mount phức tạp. | Image quá lớn (có thể >1.5GB), khó quản lý phiên bản, không tách biệt được dữ liệu. | **KHÔNG**. Chọn mount volume và dùng Model Registry. |
| **Giảm `n_ctx` để tiết kiệm RAM** | Giảm lượng RAM cần cấp phát. | Làm giảm khả năng đưa ngữ cảnh từ RAG vào prompt, ảnh hưởng chất lượng sinh. | Có thể áp dụng nếu vẫn chạy được trên Standard_DS2_v2, nhưng ưu tiên dùng máy lớn hơn (Standard_DS3_v2). |
| **Dùng `mmap` để ánh xạ checkpoint lên SSD** | Giảm RAM vật lý khi load model. | Giảm tốc độ inference do độ trễ I/O. | **KHÔNG**. Tránh dùng khi có thể nâng cấp RAM. |
| **Sử dụng Curated Environment cho Data Pipeline** | Tránh xung đột thư viện, giảm rủi ro build Docker cho job xử lý data. | Không tùy biến được nhiều, nhưng phù hợp cho tác vụ đơn giản (embedding). | **CÓ**. Chọn dùng image `openmpi4.1.0-ubuntu20.04` + `conda.yaml` thay vì custom image nặng của FastAPI. |
