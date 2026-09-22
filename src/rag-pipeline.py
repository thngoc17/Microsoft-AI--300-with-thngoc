import os
from dotenv import load_dotenv
from azure.identity import DefaultAzureCredential
from azure.search.documents import SearchClient
from azure.search.documents.models import VectorizedQuery
from openai import AzureOpenAI, OpenAI

# ==========================================
# 1. CẤU HÌNH HỆ THỐNG & XÁC THỰC
# ==========================================
load_dotenv()

SEARCH_ENDPOINT = os.environ.get("AZURE_SEARCH_ENDPOINT")
INDEX_NAME = "ai300-notes-index"

# Khởi tạo Search Client
credential = DefaultAzureCredential()
search_client = SearchClient(
    endpoint=SEARCH_ENDPOINT,
    index_name=INDEX_NAME,
    credential=credential
)

# Khởi tạo Embedding Client (text-embedding-3-large)
EMBEDDING_CLIENT = AzureOpenAI(
    azure_endpoint=os.environ.get("FOUNDRY_EMBEDDING_ENDPOINT"),
    api_key=os.environ.get("FOUNDRY_EMBEDDING_KEY"), 
    api_version="2023-05-15"
)
EMBEDDING_MODEL = "text-embedding-3-large"

# ==========================================
# Khởi tạo Generation Client (DeepSeek V3.2 qua Serverless MaaS)
# ==========================================
raw_endpoint = os.environ.get("FOUNDRY_DEEPSEEK_ENDPOINT").rstrip("/")
# Tự động chuẩn hóa URL, đảm bảo có hậu tố /v1 cho tiêu chuẩn MaaS
deepseek_base_url = raw_endpoint if raw_endpoint.endswith("/v1") else f"{raw_endpoint}/v1"

GENERATION_CLIENT = OpenAI(
    base_url=deepseek_base_url,
    api_key=os.environ.get("FOUNDRY_DEEPSEEK_KEY")
)

# Với Serverless API, tên model thường bị bỏ qua bởi endpoint, 
# nhưng cần truyền đúng tên deployment hoặc tên gốc của mô hình trên Foundry
GENERATION_MODEL = "DeepSeek-V3.2-Speciale"
# ==========================================
# 2. LOGIC RAG PIPELINE
# ==========================================

def get_embedding(text: str) -> list[float]:
    """Tạo vector embedding cho truy vấn đầu vào."""
    response = EMBEDDING_CLIENT.embeddings.create(input=text, model=EMBEDDING_MODEL)
    return response.data[0].embedding

def retrieve_context(question: str) -> tuple[str, list[str]]:
    """Thực thi Hybrid Search (Vector + Keyword) và trả về ngữ cảnh định dạng sẵn."""
    query_vector = get_embedding(question)
    
    # Thực hiện search kết hợp RRF (nếu được hỗ trợ)
    results = search_client.search(
        search_text=question,
        vector_queries=[
            VectorizedQuery(
                vector=query_vector, 
                k_nearest_neighbors=8, 
                fields="content_vector"
            )
        ],
        top=5,
        select=["content", "source_file", "section_title", "context_week"]
    )
    
    # Đóng gói ngữ cảnh và trích xuất danh sách nguồn
    context_blocks = []
    sources = []
    
    for r in results:
        block = f"[Nguồn: {r['source_file']} - {r['context_week']} - {r['section_title']}]\n{r['content']}"
        context_blocks.append(block)
        sources.append(r['source_file'])
        
    return "\n\n".join(context_blocks), list(set(sources))

def rag_query(question: str) -> dict:
    """Orchestrator: Nhận câu hỏi, tìm ngữ cảnh, và gọi LLM."""
    print(f"\n[RAG] Đang truy vấn: '{question}'")
    
    # 1. Retrieve
    context_text, sources = retrieve_context(question)
    
    if not context_text.strip():
        return {"answer": "Không tìm thấy dữ liệu liên quan trong hệ thống.", "sources": []}

    # 2. Xây dựng Prompt
    system_prompt = (
        "Bạn là một chuyên gia kỹ thuật AI. Bạn chỉ được trả lời dựa trên phần NGỮ CẢNH được cung cấp bên dưới. "
        "Nếu ngữ cảnh không đủ thông tin để trả lời, hãy nói rõ 'Không tìm thấy thông tin này trong tài liệu' "
        "thay vì tự suy đoán. Khi trả lời, BẮT BUỘC trích dẫn nguồn theo dạng [Nguồn: ...]."
    )
    user_prompt = f"NGỮ CẢNH:\n{context_text}\n\nCÂU HỎI: {question}"

    # 3. Generate với nhiệt độ thấp (0.1)
    response = GENERATION_CLIENT.chat.completions.create(
        model=GENERATION_MODEL,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt}
        ],
        temperature=0.1,
        max_tokens=2000
    )
    
    ai_reply = response.choices[0].message.content
    
    return {
        "answer": ai_reply,
        "sources": sources
    }

# ==========================================
# 3. MÔI TRƯỜNG KIỂM THỬ (TESTING)
# ==========================================
if __name__ == "__main__":
    # Test case 1: Câu hỏi mang tính kỹ thuật sâu, yêu cầu trích dẫn code/quy trình
    test_q1 = "Quyền RBAC là gì? Sự khác nhau giữa Control Plane và Data Plane?"
    
    # Test case 2: Câu hỏi kiểm tra tính groundedness (cố tình hỏi ngoài lề)
    test_q2 = "Công thức nấu phở bò chuẩn vị Nam Định là gì?"
    
    print("=== BẮT ĐẦU KIỂM THỬ RAG PIPELINE ===")
    
    for q in [test_q1, test_q2]:
        result = rag_query(q)
        print("-" * 50)
        print(f"TRẢ LỜI:\n{result['answer']}")
        print(f"\nNGUỒN ĐÃ DÙNG: {result['sources']}")
        print("-" * 50)