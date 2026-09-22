import os
import yaml
from pathlib import Path
from dotenv import load_dotenv
from azure.identity import DefaultAzureCredential
from azure.search.documents import SearchClient
from openai import AzureOpenAI

# ==========================================
# CẤU HÌNH HỆ THỐNG & XÁC THỰC
# ==========================================
# Load file .env lên môi trường một cách tường minh
load_dotenv()

# Đọc cấu hình từ file .env (Fail-fast nếu thiếu biến)
SEARCH_ENDPOINT = os.environ.get("AZURE_SEARCH_ENDPOINT")
if not SEARCH_ENDPOINT:
    raise ValueError("[LỖI] Thiếu AZURE_SEARCH_ENDPOINT trong file .env")

FOUNDRY_ENDPOINT = os.environ.get("FOUNDRY_EMBEDDING_ENDPOINT")
if not FOUNDRY_ENDPOINT:
    raise ValueError("[LỖI] Thiếu FOUNDRY_EMBEDDING_ENDPOINT trong file .env")

# Khởi tạo Credential thông qua Entra ID (az login)
credential = DefaultAzureCredential()
INDEX_NAME = "ai300-notes-index"

# Khởi tạo Search Client
search_client = SearchClient(
    endpoint=SEARCH_ENDPOINT,
    index_name=INDEX_NAME,
    credential=credential
)

# Khởi tạo Embedding Client (Azure OpenAI tương thích)
# Vẫn giữ hỗ trợ API_KEY cho trường hợp fallback, nhưng khuyến khích dùng credential
FOUNDRY_KEY = os.environ.get("FOUNDRY_EMBEDDING_KEY")
if FOUNDRY_KEY:
    EMBEDDING_CLIENT = AzureOpenAI(
        azure_endpoint=FOUNDRY_ENDPOINT,
        api_key=FOUNDRY_KEY, 
        api_version="2023-05-15"
    )
else:
    EMBEDDING_CLIENT = AzureOpenAI(
        azure_endpoint=FOUNDRY_ENDPOINT,
        azure_ad_token_provider=credential.get_token("https://cognitiveservices.azure.com/.default"),
        api_version="2023-05-15"
    )

EMBEDDING_MODEL = "text-embedding-3-large"

# ==========================================
# LOGIC XỬ LÝ & CHUNKING
# ==========================================
def embed_text(text: str) -> list[float]:
    """Gọi API để lấy vector cho text chunk."""
    response = EMBEDDING_CLIENT.embeddings.create(input=text, model=EMBEDDING_MODEL)
    return response.data[0].embedding

def parse_and_chunk_markdown(filepath: str) -> list[dict]:
    """
    Đọc file Markdown, bóc tách YAML frontmatter, 
    và chunk nội dung dựa trên ranh giới '## ' trong khi bảo toàn các khối code (```).
    """
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()

    # 1. Bóc tách YAML frontmatter
    parts = content.split('---\n', 2)
    meta = {}
    body_text = content
    if len(parts) >= 3:
        meta = yaml.safe_load(parts[1])
        body_text = parts[2]

    # 2. Chunking nhận diện Code Block (Fence ```)
    chunks = []
    current_chunk = []
    current_heading = "Mở đầu"
    in_code_block = False

    for line in body_text.split('\n'):
        if line.startswith('```'):
            in_code_block = not in_code_block
        
        # Nếu gặp heading level 2 và KHÔNG nằm trong code block -> Cắt chunk
        if line.startswith('## ') and not in_code_block:
            if current_chunk and "".join(current_chunk).strip():
                chunks.append({
                    "heading": current_heading,
                    "text": "\n".join(current_chunk).strip(),
                    "meta": meta
                })
            current_heading = line.replace('## ', '').strip()
            current_chunk = [line]
        else:
            current_chunk.append(line)

    # Đẩy chunk cuối cùng vào mảng
    if current_chunk and "".join(current_chunk).strip():
        chunks.append({
            "heading": current_heading,
            "text": "\n".join(current_chunk).strip(),
            "meta": meta
        })
    
    return chunks

# ==========================================
# MAIN EXECUTION FLOW (REFACTORED CHO BATCH)
# ==========================================
def process_and_upload(filepath: Path):
    """Xử lý và upload một file cụ thể."""
    filename = filepath.name
    print(f"\n[TIẾN TRÌNH] Bắt đầu xử lý file: {filename}")
    
    # Chuyển đổi Path object thành chuỗi khi đọc file
    raw_chunks = parse_and_chunk_markdown(str(filepath))
    docs_to_upload = []
    
    for idx, chunk in enumerate(raw_chunks):
        if len(chunk["text"]) < 10:
            continue
            
        print(f"  -> Vector hóa chunk [{idx}]: {chunk['heading']}")
        
        docs_to_upload.append({
            "id": f"{filepath.stem}-chunk-{idx}", # dùng .stem để lấy tên file không có đuôi .md
            "content": chunk["text"],
            "content_vector": embed_text(chunk["text"]),
            "source_file": filename,
            "section_title": chunk["heading"],
            "context_week": chunk["meta"].get("context_week", "Unknown"),
            "ai300_domains": chunk["meta"].get("ai300_domains", []),
            "technologies": chunk["meta"].get("technologies", []),
            "status": chunk["meta"].get("status", "Unknown")
        })
    
    if not docs_to_upload:
        print(f"  -> [BỎ QUA] Không có chunk hợp lệ nào trong {filename}.")
        return

    print(f"  -> Đang đẩy {len(docs_to_upload)} documents lên index '{INDEX_NAME}'...")
    result = search_client.upload_documents(documents=docs_to_upload)
    
    for res in result:
        if not res.succeeded:
            print(f"  -> [LỖI CỤC BỘ] Upload thất bại chunk ID {res.key}: {res.error_message}")
    print(f"  -> [HOÀN TẤT] File {filename} đã được index.")

def run_batch_ingestion(relative_dir: str):
    """Quét và xử lý toàn bộ file markdown trong thư mục chỉ định."""
    # Xác định đường dẫn tuyệt đối một cách an toàn dựa trên vị trí của file script hiện tại
    current_script_dir = Path(__file__).resolve().parent
    target_dir = (current_script_dir / relative_dir).resolve()
    
    print(f"=== BẮT ĐẦU PIPELINE NẠP DỮ LIỆU ===")
    print(f"Thư mục đích (đã phân giải): {target_dir}")
    
    # Fail-fast: Kiểm tra thư mục tồn tại
    if not target_dir.exists() or not target_dir.is_dir():
        raise FileNotFoundError(f"[LỖI CHÍ MẠNG] Thư mục không tồn tại hoặc không hợp lệ: {target_dir}")
        
    # Quét toàn bộ file .md
    md_files = list(target_dir.glob("*.md"))
    if not md_files:
        print(f"[CẢNH BÁO] Không tìm thấy file Markdown (.md) nào trong thư mục {target_dir}")
        return
        
    print(f"Phát hiện {len(md_files)} file Markdown. Đưa vào hàng đợi xử lý...")
    
    for file_path in md_files:
        try:
            process_and_upload(file_path)
        except Exception as e:
            print(f"[LỖI NGHIÊM TRỌNG] Quá trình xử lý file {file_path.name} bị gián đoạn: {str(e)}")
            # Tùy thuộc vào chiến lược chịu lỗi (fault tolerance), bạn có thể 'continue' hoặc 'raise'
            continue
            
    print(f"\n=== PIPELINE HOÀN TẤT ===")

if __name__ == "__main__":
    # Gọi hàm xử lý hàng loạt với đường dẫn tương đối
    run_batch_ingestion("../RAG")