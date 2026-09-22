import os
from dotenv import load_dotenv
from azure.identity import DefaultAzureCredential
from azure.core.exceptions import ResourceNotFoundError
from azure.search.documents.indexes import SearchIndexClient
from azure.search.documents.indexes.models import (
    SearchIndex,
    SimpleField,
    SearchableField,
    SearchField,
    SearchFieldDataType,
    VectorSearch,
    HnswAlgorithmConfiguration,
    VectorSearchProfile
)

# Load cấu hình
load_dotenv()
SEARCH_ENDPOINT = os.environ.get("AZURE_SEARCH_ENDPOINT")
INDEX_NAME = "ai300-notes-index"

# 1. Khởi tạo Client (Sử dụng SearchIndexClient cho Control/Schema Plane)
credential = DefaultAzureCredential()
index_client = SearchIndexClient(endpoint=SEARCH_ENDPOINT, credential=credential)

# 2. Định nghĩa cấu trúc Vector Search (Bắt buộc cho content_vector)
vector_search = VectorSearch(
    algorithms=[
        HnswAlgorithmConfiguration(
            name="myHnsw",
            parameters={"m": 4, "efConstruction": 400, "efSearch": 500, "metric": "cosine"}
        )
    ],
    profiles=[
        VectorSearchProfile(name="default-profile", algorithm_configuration_name="myHnsw")
    ]
)

# 3. Ánh xạ Schema dựa trên YAML Frontmatter
fields = [
    SimpleField(name="id", type=SearchFieldDataType.String, key=True),
    SearchableField(name="content", type=SearchFieldDataType.String),
    SearchField(name="content_vector", type=SearchFieldDataType.Collection(SearchFieldDataType.Single), 
                searchable=True, vector_search_dimensions=3072, vector_search_profile_name="default-profile"),
    SimpleField(name="source_file", type=SearchFieldDataType.String, filterable=True),
    SearchableField(name="section_title", type=SearchFieldDataType.String, filterable=True),
    SimpleField(name="context_week", type=SearchFieldDataType.String, filterable=True, facetable=True),
    SimpleField(name="ai300_domains", type=SearchFieldDataType.Collection(SearchFieldDataType.String), filterable=True, facetable=True),
    SimpleField(name="technologies", type=SearchFieldDataType.Collection(SearchFieldDataType.String), filterable=True, facetable=True),
    SimpleField(name="status", type=SearchFieldDataType.String, filterable=True)
]

# 4. Thực thi: Xóa Index cũ (nếu có) và tạo mới (Đảm bảo tính Idempotent)
try:
    print(f"Kiểm tra index '{INDEX_NAME}'...")
    index_client.get_index(INDEX_NAME)
    print("Index đã tồn tại. Đang tiến hành xóa để tạo lại bản sạch...")
    index_client.delete_index(INDEX_NAME)
except ResourceNotFoundError:
    print("Index chưa tồn tại. Chuẩn bị tạo mới...")

# Tạo mới Index
index = SearchIndex(name=INDEX_NAME, fields=fields, vector_search=vector_search)
result = index_client.create_index(index)
print(f"TẠO THÀNH CÔNG: Index '{result.name}' đã sẵn sàng nhận dữ liệu.")