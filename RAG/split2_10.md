---
source_url: https://gemini.google.com/app/6dfaf375618d9d
conversation_date: N/A
context_week: N/A
conversation_types: [FIX_HA_TANG, FIX_CODE, TRANH_LUAN_QUYET_DINH, LAP_KE_HOACH]
ai300_domains: [GenAIOps infrastructure, Optimize generative AI systems and model performance, Model lifecycle]
technologies: [WSL2, Docker Desktop, PowerShell, netsh, Ubuntu, FastAPI, Uvicorn, LangChain, llama-cpp-python, ChromaDB, sentence-transformers, OpenBLAS, libgomp, Azure Container Registry, Azure ML]
key_decision: "Tách mô hình (2.3GB) khỏi mã nguồn và Docker image, sử dụng volume mount; sửa lỗi WSL/Docker và bổ sung thư viện thiếu (libgomp1, sentence-transformers) để container chạy ổn định trên môi trường local và tương thích với Azure."
status: resolved
---

## Bối cảnh & Vấn đề

Hội thoại xoay quanh việc xây dựng một API RAG (Retrieval-Augmented Generation) sử dụng mô hình ngôn ngữ Qwen3-4B (định dạng GGUF) và vector database Chroma, đóng gói trong container Docker. Trong quá trình thiết lập, gặp hàng loạt lỗi từ tầng hạ tầng ảo hóa (WSL2, Docker Desktop), lỗi cấu hình mount, lỗi thiếu thư viện hệ thống và Python, cũng như lỗi thiết kế kiến trúc (đặt mô hình nặng trong thư mục source). Cần khắc phục để chạy được API cục bộ, đồng thời đảm bảo khả năng triển khai lên Azure trong tương lai (Ngày 3 và Ngày 5).

## Quyết định cuối cùng & Lý do

- **KHÔNG đặt mô hình GGUF (2.32 GB) trong thư mục `source/`** vì:
  - Làm tăng build context, gây treo I/O và build cực chậm.
  - Nướng mô hình vào image làm image nặng (~3GB), không tương thích với cơ chế mount model từ Azure ML Model Registry.
  - Gây lỗi mount khi Docker không tìm thấy file mà tạo thư mục ảo.
  - **Quyết định**: Tạo thư mục `model/` riêng, thêm vào `.dockerignore`, sử dụng volume mount `-v ${PWD}/model:/app/model` khi chạy container.

- **KHÔNG dùng `async def chat_endpoint`** vì tác vụ LLM và RAG là CPU-bound, sẽ block event loop của FastAPI. **Quyết định**: đổi thành `def chat_endpoint` để FastAPI tự động đẩy sang threadpool.

- **Phải bổ sung thư viện hệ thống `libgomp1`** trong Dockerfile (runtime stage) vì llama-cpp-python yêu cầu OpenMP để đa luồng CPU.

- **Phải bổ sung `sentence-transformers`** vào `requirements.txt` vì LangChain HuggingFace Embeddings dùng động, không được phát hiện bởi phân tích tĩnh.

- **Sử dụng import tuyệt đối** `from source.schemas import ...` thay vì `from schemas import` để Python tìm đúng module trong cấu trúc container.

## Lệnh và Cấu hình cụ thể đã dùng

### Lệnh xử lý sự cố WSL/Docker
```powershell
# Tắt WSL cứng
wsl --shutdown

# (Nếu lỗi LxssManager)
Restart-Service LxssManager

# Reset network stack
netsh winsock reset
netsh int ip reset
ipconfig /flushdns

# Cập nhật WSL
wsl --update

# Khởi động lại máy tính (Hard Reboot)
```

### Lệnh Docker (sau khi sửa)
```bash
# Xóa container lỗi
docker rm -f genai-backend

# Build image (sử dụng cache)
docker build -t qwen-rag-api:v1 .

# Chạy container với 2 volume mounts
docker run -d \
  --name genai-backend \
  -p 8000:8000 \
  -v ${PWD}/my_data:/app/my_data \
  -v ${PWD}/model:/app/model \
  qwen-rag-api:v1

# Kiểm tra log
docker logs -f genai-backend
```

### Cấu hình Dockerfile (đoạn sửa runtime stage)
```dockerfile
FROM python:3.10-slim
WORKDIR /app

# Bổ sung libgomp1 cho OpenMP
RUN apt-get update && apt-get install -y --no-install-recommends \
    libopenblas0 libgomp1 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/wheels /wheels
COPY requirements.txt .
RUN pip install --no-cache-dir /wheels/*
RUN rm -rf /wheels requirements.txt

COPY source /app/source/

EXPOSE 8000
CMD ["uvicorn", "source.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

### `.dockerignore`
```
my_data/
model/
.git/
.idea/
__pycache__/
*.gguf
```

### `requirements.txt` (bổ sung dòng cuối)
```
fastapi==0.100.0
uvicorn==0.22.0
pydantic==2.0.0
langchain-huggingface==0.0.1
langchain-chroma==0.1.1
llama-cpp-python==0.3.16
sentence-transformers
```

### Đoạn code `source/main.py` (sửa đường dẫn và synchronous)
```python
from fastapi import FastAPI, HTTPException
from contextlib import asynccontextmanager
from langchain_huggingface import HuggingFaceEmbeddings
from langchain_chroma import Chroma
from llama_cpp import Llama
import time
import os
from source.schemas import ChatGPTRequest, ChatGPTResponse   # absolute import

ml_models = {}

@asynccontextmanager
async def lifespan(app: FastAPI):
    db_path = os.path.join(os.path.dirname(__file__), '../my_data', 'knowledge_db')
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

    model_path = os.path.join(os.path.dirname(__file__), '../model', 'qwen3-4b-instruct-2507.Q4_K_M.gguf')
    ml_models["llm"] = Llama(
        model_path=model_path,
        n_ctx=4096,
        n_gpu_layers=0
    )
    yield
    ml_models.clear()

app = FastAPI(lifespan=lifespan)

@app.post("/chat", response_model=ChatGPTResponse)
def chat_endpoint(request: ChatGPTRequest):
    start_time = time.time()
    try:
        user_query = request.messages[-1].content
        vector_db = ml_models["vector_db"]
        results = vector_db.similarity_search(user_query, k=2)
        context_str = "\n".join([f"- {doc.page_content}" for doc in results]) if results else ""

        if context_str:
            augmented_prompt = f"[THÔNG TIN NỀN VỀ BẠN]:\n{context_str}\n\n[CÂU HỎI]:\n{user_query}"
            request.messages[-1].content = augmented_prompt

        formatted_messages = [{"role": m.role, "content": m.content} for m in request.messages]
        llm = ml_models["llm"]
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
    return ChatGPTResponse(
        reply=ai_reply,
        retrieved_context=context_str,
        processing_time=process_time
    )
```

## Lỗi gặp phải và Cách khắc phục

| Lỗi | Nguyên nhân | Cách khắc phục |
|-----|------------|----------------|
| `stargz-snapshotter panic`, `OSError: [Errno 5] Input/output error` | Hệ thống tệp WSL bị hỏng, I/O block | `wsl --shutdown`, Docker factory reset (Clean/Purge data) |
| `DockerDesktop/Wsl/ExecError: exit status 1` | Proxy agent của Docker bị treo, symlink zombie | `Restart-Service LxssManager`, toggle WSL Integration, manual boot Ubuntu |
| `Catastrophic failure Error code: Wsl/Service/E_UNEXPECTED` | Winsock catalog corruption, Hyper-V switch lỗi | `netsh winsock reset`, `netsh int ip reset`, `ipconfig /flushdns`, `wsl --update`, **hard reboot** |
| `docker run: Are you trying to mount a directory onto a file?` | Docker không tìm thấy file model, tự tạo thư mục ảo | Xóa thư mục ảo, tải model đúng vị trí, dùng volume mount (không build vào image) |
| `RuntimeError: Failed to load shared library libllama.so: libgomp.so.1: cannot open shared object file` | Thiếu thư viện OpenMP trong runtime image | Thêm `libgomp1` vào `apt-get install` ở stage runtime |
| `ImportError: cannot import name 'ChatRequest' from 'schemas' (unknown location)` | Python không tìm thấy module do cấu trúc thư mục | Sửa import thành `from source.schemas import ...` |
| `ModuleNotFoundError: No module named 'sentence_transformers'` | Phụ thuộc ẩn của LangChain HuggingFace Embeddings | Bổ sung `sentence-transformers` vào `requirements.txt` |

## Lộ trình chi tiết (liên quan đến các Ngày 3 và 5)

- **Ngày 3 (dự kiến)**: Đẩy Docker image lên Azure Container Registry (ACR). Lưu ý: image đã được tối ưu nhẹ (~300MB) nhờ không chứa model.
- **Ngày 5 (dự kiến)**: Triển khai lên Azure ML Managed Endpoint. Model sẽ được mount từ Model Registry vào `/app/model`, tương thích với cấu hình volume mount đã thiết lập ở local.
- **Yêu cầu bắt buộc**: Phải hoàn thành tái cấu trúc ngay trong Ngày 2, không trì hoãn, vì:
  - Build local sẽ nhanh (mili giây) sau mỗi lần sửa code.
  - Tránh lãng phí thời gian push image 3GB lên cloud.
  - Đảm bảo môi trường local mô phỏng đúng kiến trúc cloud.

## Các phương án đã cân nhắc

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
|-----------|---------|------------|------------|
| **A. Đặt model trong source và COPY vào image** | Đơn giản, không cần mount khi run | Image nặng (~3GB), build chậm, không tương thích cloud, gây lỗi mount | **KHÔNG** (loại bỏ) |
| **B. Đặt model trong thư mục riêng, dùng volume mount** | Image nhẹ, build nhanh, đúng mô hình cloud, dễ debug | Phải đảm bảo file model có sẵn trên host, phải mount đúng đường dẫn | **CÓ** (chọn) |
| **C. Tải model từ internet khi container start** | Không cần lưu model local | Tốn băng thông, chậm, phụ thuộc mạng, không ổn định cho production | **KHÔNG** (không đề cập) |

Tiêu chí quyết định: **tính tương thích với Azure deployment, tốc độ build local, và khả năng tái sử dụng image**.
