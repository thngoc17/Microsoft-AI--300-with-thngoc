"""
Wiring cho Azure AI Search tool trên Foundry Agent (SDK mới, azure-ai-projects).

Index và schema (content_vector 3072 chiều, KHÔNG có Semantic Configuration)
được tạo trước bởi src/create-index.py — file này KHÔNG được phép tạo/sửa index.
"""
from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import (
    AISearchIndexResource,
    AzureAISearchQueryType,
    AzureAISearchTool,
    AzureAISearchToolResource,
)

from ..config import AZURE_SEARCH_CONNECTION_NAME, AZURE_SEARCH_INDEX_NAME


def build_azure_ai_search_tool(project_client: AIProjectClient) -> AzureAISearchTool:
    """
    Phân giải Project Connection theo TÊN (không hardcode connection ID) rồi
    gắn vào Agent dưới dạng tool.

    LƯU Ý BẮT BUỘC: connection AZURE_SEARCH_CONNECTION_NAME phải được tạo trên
    CHÍNH project Foundry mới (Microsoft.CognitiveServices/accounts/projects).
    Connection cùng tên được tạo trên Hub/Project cũ
    (Microsoft.MachineLearningServices/workspaces, như trong infra/main.bicep
    hiện tại) KHÔNG được project_client.connections.get() ở SDK mới nhìn thấy
    -> sẽ raise ResourceNotFoundError nếu chưa tạo lại connection.

    RBAC cần gán cho managed identity của project (nếu dùng keyless/AAD auth):
      - Search Index Data Contributor
      - Search Service Contributor
    """
    connection = project_client.connections.get(AZURE_SEARCH_CONNECTION_NAME)

    return AzureAISearchTool(
        azure_ai_search=AzureAISearchToolResource(
            indexes=[
                AISearchIndexResource(
                    project_connection_id=connection.id,
                    index_name=AZURE_SEARCH_INDEX_NAME,
                    # Index hiện CHƯA bật Semantic Configuration (create-index.py
                    # chỉ định nghĩa HNSW vector search) -> dùng hybrid vector +
                    # keyword thuần, tương đương cách rag-pipeline.py đang làm
                    # thủ công (search_text + vector_queries cùng lúc). Sau khi
                    # bật semantic ranker cho index, đổi sang
                    # AzureAISearchQueryType.VECTOR_SEMANTIC_HYBRID để có
                    # citation chất lượng hơn.
                    query_type=AzureAISearchQueryType.VECTOR_SIMPLE_HYBRID,
                ),
            ]
        )
    )


# Ghi chú về citation:
# Index hiện tại (xem create-index.py) không có field URL retrievable, chỉ có
# source_file/section_title. Vì vậy annotation kiểu "url_citation" mà tool này
# tự sinh ra sẽ THƯỜNG XUYÊN RỖNG — trích dẫn nguồn vẫn xuất hiện dưới dạng
# text thô [Nguồn: ...] vì system_prompt.prompty đã yêu cầu model tự làm việc
# này dựa trên metadata trả về từ tool, không phụ thuộc cơ chế url_citation.