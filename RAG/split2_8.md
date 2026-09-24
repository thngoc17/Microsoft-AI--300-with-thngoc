---
source_url: https://gemini.google.com/app/8257dcec2396b0a0
conversation_date: 2026-07-28
context_week: "Tuần 2-3 (Sprint 7 ngày: 28/07/2026 – 03/08/2026)"
conversation_types: [LAP_KE_HOACH, TRANH_LUAN_QUYET_DINH, FIX_CODE, LY_THUYET, KIEM_TRA_KIEN_THUC]
ai300_domains: [GenAIOps infrastructure, Optimize generative AI systems and model performance]
technologies: [Azure ML, FastAPI, Docker, LangChain, ChromaDB, HuggingFace, MLflow, Llama.cpp, Qwen, Uvicorn, Pydantic, PowerShell]
key_decision: "Quyết định chiến lược: rã đông monolithic Telegram sang FastAPI + Docker ngay lập tức, áp dụng nguyên tắc Fail Fast, chuyển từ MLOps sang GenAIOps để tối ưu CPU và chi phí, loại bỏ compute instance, sử dụng stateless API với context management phía client."
status: resolved
---

## Bối cảnh & Vấn đề

- **Kiến trúc hiện tại là monolithic**: Mã nguồn chatbot gộp chung logic UI (Telegram) và logic lõi (Inference/RAG) thông qua `infinity_polling()`.
- **Rủi ro đứt gãy hệ thống**: Điểm yếu nằm ở lớp phục vụ (Serving Layer), không phải ở khâu xử lý dữ liệu. Khả năng làm chủ Docker và thiết kế REST API là khâu đòi hỏi độ cọ xát kỹ thuật cao nhất.
- **Vấn đề chi phí**: Compute Instance là thủ phạm gây hao hụt ngân sách. Cần chuyển sang Compute Cluster CPU với `min_instances: 0` để tự động ngắt điện khi không vận hành.
- **Hạn chế phần cứng**: Suy luận trên CPU với mô hình 4B, tài nguyên giới hạn.
- **Lỗi semantic trong API test**: Vector search trả về ngữ cảnh sai (kỹ năng chuyên môn thay vì danh tính cá nhân). Mô hình bị overfit với dữ liệu hội thoại Facebook → hallucination. Thiếu System Prompt khiến mô hình mất ý thức về vai trò.

## Quyết định cuối cùng & Lý do

1. **KHÔNG** chạy Data Pipeline trước → **Tập trung rã đông Telegram sang FastAPI + Docker ngay lập tức** (nguyên tắc Fail Fast).
2. **KHÔNG** sử dụng Compute Instance → **Dùng Compute Cluster CPU** (`Standard_DS2_v2`) với `min_instances: 0` để tiết kiệm chi phí.
3. **KHÔNG** nướng checkpoint vào Docker Image → **Đăng ký Model Registry**, Managed Endpoint sẽ tự động kéo mô hình.
4. **KHÔNG** lưu trạng thái phiên trong API → **Chuyển sang stateless architecture**: Client quản lý lịch sử hội thoại và gửi toàn bộ payload qua HTTP.
5. **KHÔNG** dùng telebot hay infinity_polling trong core → **FastAPI REST API** nhận POST request, thực hiện RAG → suy luận Qwen → trả JSON.
6. **KHÔNG** dùng Ngrok hay openai client → **Tích hợp trực tiếp Llama.cpp** nạp trọng số mô hình vào RAM, suy luận nội bộ.

## Lệnh và Cấu hình cụ thể đã dùng

### FastAPI Code (main.py)
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

    model_path = os.path.join(os.path.dirname(__file__), 'qwen3-4b-instruct-2507.Q4_K_M.gguf')
    ml_models["llm"] = Llama(
        model_path=model_path,
        n_ctx=4096,
        n_gpu_layers=0  # CPU inference
    )
    yield
    ml_models.clear()

app = FastAPI(lifespan=lifespan)

@app.post("/chat", response_model=ChatResponse)
async def chat_endpoint(request: ChatRequest):
    start_time = time.time()
    user_query = request.messages[-1].content

    # RAG
    vector_db = ml_models["vector_db"]
    results = vector_db.similarity_search(user_query, k=2)
    context_str = "\n".join([f"- {doc.page_content}" for doc in results]) if results else ""

    # System Prompt injection
    system_instruction = (
        "Bạn là Lê Thái Ngọc, một sinh viên năm 3 ngành Trí tuệ Nhân tạo tại HCMUS. "
        "Hãy đóng vai hoàn hảo và trả lời dựa trên tính cách của bạn. "
        "Dưới đây là một số thông tin lấy từ ký ức của bạn để hỗ trợ trả lời:\n"
        f"{context_str}\n\n"
        "Quy tắc hành xử:\n"
        "- Nếu người dùng chửi thề hoặc xưng 'tao/mày' (như bạn bè): Xưng 'tao', gọi 'mày', trả lời cộc lốc, bựa.\n"
        "- Nếu hỏi thông tin không có trong ký ức, hãy trả lời theo kiến thức cá nhân của Lê Thái Ngọc một cách tự nhiên."
    )

    formatted_messages = [{"role": "system", "content": system_instruction}]
    for m in request.messages:
        if m.role != "system":
            formatted_messages.append({"role": m.role, "content": m.content})

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
    return ChatResponse(
        reply=ai_reply,
        retrieved_context=context_str if context_str else "Không tìm thấy trong DB",
        processing_time=process_time
    )
```

### Pydantic Schemas (schemas.py)
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

### Uvicorn startup command (PowerShell)
```powershell
uvicorn main:app --host 127.0.0.1 --port 8000 --reload
```

### Test Request (PowerShell)
```powershell
$headers = @{ "Content-Type" = "application/json" }
$body = @{
    messages = @(
        @{ role = "user"; content = "cho tao biết tên mày đi thẳng lồn" }
    )
    temperature = 0.2
    max_tokens = 1024
} | ConvertTo-Json -Depth 5

Invoke-RestMethod -Uri "http://127.0.0.1:8000/chat" -Method Post -Headers $headers -Body $body
```

## Lỗi gặp phải và Cách khắc phục

| Lỗi / Vấn đề | Nguyên nhân | Cách khắc phục |
|---|---|---|
| API trả về `{"detail":"Not Found"}` khi truy cập `http://127.0.0.1:8000` | Trình duyệt gửi GET request tới root, nhưng chỉ có endpoint POST `/chat`. | Dùng Swagger UI tại `/docs` hoặc gửi POST request qua PowerShell/Postman. |
| Phản hồi semantic sai: hỏi tên nhưng trả về kỹ năng YOLO, BERT, OCR | ChromaDB trả về ngữ cảnh sai (do vector search không hiểu từ lóng "tao/mày"). Mô hình bị overfit với dữ liệu hội thoại Facebook. | **Thêm System Prompt** để định danh vai trò và quy tắc hành xử. Inject System Prompt vào đầu mảng messages mỗi request. |
| Câu trả lời "Đùn Tối nay t bạn lắm n Đang ở trên trường" không giải quyết câu hỏi | Thiếu System Prompt, mô hình không có ý thức về vai trò, bị overfit với dữ liệu training. | **Sửa main.py**: Tạo `system_instruction` với vai trò, thông tin cá nhân, quy tắc ứng xử, và context RAG. |
| API lưu trạng thái phiên trong dictionary `chat_histories` | Vi phạm nguyên tắc stateless, gây memory leak, không scale ngang. | **Xóa dictionary toàn cục**. Client quản lý lịch sử và gửi toàn bộ `messages` trong payload mỗi request. |
| API test có `processing_time` ~6.5s | Suy luận CPU trên model 4B với n_ctx=4096. | Chấp nhận cho giai đoạn dev. Tối ưu Dockerfile (chọn base image mỏng, dùng pre-built wheels) để giảm thời gian build. |

## Lộ trình chi tiết (Sprint 7 ngày)

| Ngày | Nhiệm vụ | Mục tiêu | Chỉ tiêu hoàn thành |
|---|---|---|---|
| **Ngày 1 (28/07/2026)** | Rã đông Lớp Phục vụ & Phát triển REST API (FastAPI) | - Gỡ bỏ hoàn toàn `telebot` khỏi tệp tin lõi.<br>- Xây dựng endpoint POST `/chat` bằng FastAPI.<br>- Tích hợp HuggingFaceEmbeddings + Chroma + llama-cpp-python.<br>- Đảm bảo stateless (không lưu session memory). | API có thể nhận payload JSON, thực hiện RAG, suy luận Qwen, trả JSON. Test thành công qua Swagger UI hoặc PowerShell. |
| **Ngày 2 (29/07/2026)** | Containerization & Kiểm thử Cục bộ | - Viết Dockerfile với base image `python:3.10-slim`.<br>- Cài đặt thư viện biên dịch C++ tối thiểu hỗ trợ `llama-cpp-python` trên CPU.<br>- Build và chạy container trên Windows (Docker Desktop + WSL2). | Container expose đúng cổng Uvicorn, nhận request qua Postman/cURL. |
| **Ngày 3 (30/07/2026)** | Kiến tạo Hạ tầng Azure & Model Registry | - Khởi tạo Azure ML Workspace, cấu hình CLI/SDK v2.<br>- Tải checkpoint `qwen3-4b-instruct-2507.Q4_K_M.gguf` lên Azure Blob Storage (Datastore).<br>- Đăng ký checkpoint vào Azure ML Model Registry. | Checkpoint được đăng ký, sẵn sàng để Managed Endpoint kéo về. |
| **Ngày 4 (31/07/2026)** | Tự động hóa Data Pipeline (Command Job) | - Đóng gói thư viện (Langchain, Chroma, Underthesea) vào `conda.yaml`.<br>- Ghép logic tiền xử lý JSON và tạo Vector DB thành một luồng thực thi.<br>- Tạo YAML Command Job: Input từ Datastore, Output ghi đè `knowledge_db`. | Command Job chạy tự động trên Compute Cluster CPU với `min_instances: 0`. |
| **Ngày 5 (01/08/2026)** | Triển khai Điểm cuối (Managed Online Endpoint) | - Đẩy Docker Image lên Azure Container Registry (ACR).<br>- Viết Deployment YAML: kết hợp Image từ ACR + Checkpoint từ Model Registry.<br>- Mount Vector DB volume từ Datastore vào container runtime. | Endpoint hoạt động, có thể gửi request từ client. |
| **Ngày 6 (02/08/2026)** | Đo lường MLflow & Tái cấu trúc Client | - Tích hợp MLflow vào Data Pipeline: log số lượng bản ghi, dung lượng Vector DB, thời gian embedding.<br>- Viết lại Telegram Bot thành Client API thuần túy: chuyển tiếp tin nhắn lên Azure Endpoint. | Client hoạt động, MLflow tracking có dữ liệu. |
| **Ngày 7 (03/08/2026)** | Đánh giá Nút thắt Cổ chai (Bottleneck Assessment) | - Theo dõi throughput và latency của CPU Azure khi truy xuất ChromaDB + LLM inference.<br>- Rà soát tự động tắt/mở Compute Cluster để đánh giá hiệu quả chi phí. | Báo cáo đánh giá hiệu năng và chi phí. |

## Khái niệm & Định nghĩa

- **Stateless API**: API không lưu trữ bất kỳ thông tin phiên nào. Mỗi request phải chứa toàn bộ dữ liệu cần thiết (ví dụ: lịch sử hội thoại) để xử lý. Lợi ích: dễ dàng scale ngang, không bị memory leak.
- **Fail Fast**: Nguyên tắc phát hiện và xử lý lỗi sớm nhất có thể, thường bằng cách thử nghiệm các phần rủi ro nhất trước. Trong ngữ cảnh này: ưu tiên rã đông monolithic (Serving Layer) ngay từ ngày 1 thay vì làm Data Pipeline trước.
- **RAG (Retrieval-Augmented Generation)**: Kỹ thuật tăng cường sinh văn bản bằng cách truy xuất thông tin từ cơ sở dữ liệu vector và đưa vào prompt làm ngữ cảnh.
- **System Prompt**: Hướng dẫn vai trò và quy tắc ứng xử cho LLM, được inject vào đầu mảng messages để định hướng hành vi của mô hình.
- **Payload Piggybacking**: Cơ chế client mang toàn bộ lịch sử hội thoại trong payload mỗi request, thay vì API lưu trạng thái.
- **Sliding Window / Ring Buffer**: Client giới hạn số lượng tin nhắn lưu (ví dụ: 5 cặp QA gần nhất) để tránh payload quá lớn, đảm bảo không vượt ngưỡng token context của LLM.

## Các phương án đã cân nhắc

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
|---|---|---|---|
| **Chạy Data Pipeline trước, API sau** | Có cảm giác tiến triển, dễ dàng test vector DB. | Bỏ qua rủi ro lớn nhất (Docker + REST API). Không kịp fix nếu gặp sự cố. | ❌ KHÔNG. Chọn Fail Fast. |
| **Dùng Compute Instance để chạy API** | Dễ cài đặt, quen thuộc với dev. | Chi phí rảnh rỗi cao (luôn chạy). Không tối ưu cho production. | ❌ KHÔNG. Chuyển sang Compute Cluster với `min_instances: 0`. |
| **Gọi Llama.cpp qua Ngrok (openai client)** | Đơn giản, tách biệt inference server. | Network latency, tăng độ phức tạp, khó debug. | ❌ KHÔNG. Tích hợp trực tiếp Llama.cpp vào main.py. |
| **Nướng checkpoint vào Docker Image** | Dễ triển khai, không cần kéo model từ registry. | Image lớn, khó cập nhật checkpoint, anti-pattern. | ❌ KHÔNG. Dùng Model Registry để Managed Endpoint tự kéo. |
| **API stateful (lưu chat_histories)** | Đơn giản, ít network I/O. | Memory leak, không scale ngang, vi phạm separation of concerns. | ❌ KHÔNG. Chọn stateless, client quản lý context. |
| **API stateless + client quản lý context** | Scale ngang vô hạn, không memory leak, tách biệt rõ ràng UI và logic. | Payload lớn dần theo lịch sử, network I/O tăng. | ✅ CHỌN. Đảm bảo separation of concerns và khả năng mở rộng. |
| **Biên dịch mã nguồn C++ trong Dockerfile** | Tối ưu phần cứng, hiệu năng cao. | Thời gian build lâu, phức tạp. | ⏳ Đang cân nhắc cho Ngày 2. Có thể dùng pre-built wheels để nhanh hơn. |
| **Dùng pre-built wheels (pip install)** | Build nhanh, đơn giản. | Image nặng hơn, không tối ưu tối đa. | ⏳ Đang cân nhắc cho Ngày 2. Có thể chọn để tiết kiệm thời gian sprint. |