"""
Cấu hình tập trung cho Foundry Agent — dự án Foundry MỚI (Microsoft.CognitiveServices).

CẢNH BÁO QUAN TRỌNG:
FOUNDRY_PROJECT_ENDPOINT bên dưới phải trỏ tới một project được tạo trên
resource type `Microsoft.CognitiveServices/accounts/projects` (Foundry hiện
hành), KHÔNG PHẢI project kiểu Hub/Project cũ
(`Microsoft.MachineLearningServices/workspaces`) đang được provision trong
infra/main.bicep ở thời điểm viết file này. Hai loại project KHÔNG tương
thích: SDK azure-ai-projects (bản mới, cùng dòng với evals/run_eval.py) không
đọc được project hay connection tạo trên project kiểu cũ. Cần cập nhật
main.bicep trước khi các file trong agent/ chạy được với hạ tầng thật.
"""
import os
from pathlib import Path

from dotenv import load_dotenv

load_dotenv()


def _require(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise ValueError(f"[LỖI] Thiếu biến môi trường bắt buộc: {name}")
    return value


# ==========================================
# FOUNDRY PROJECT (mới — Microsoft.CognitiveServices)
# ==========================================
# Copy chính xác từ tab "Overview" của project trên portal Foundry.
# Dạng thường thấy: https://<account>.services.ai.azure.com/api/projects/<project>
FOUNDRY_PROJECT_ENDPOINT = _require("FOUNDRY_PROJECT_ENDPOINT")

# Dùng CHUNG tên biến với evals/run_eval.py để agent runtime và agent được
# eval luôn là MỘT — tránh tình trạng eval một agent, chạy thật một agent khác.
FOUNDRY_AGENT_NAME = os.environ.get("FOUNDRY_AGENT_NAME", "support-agent")

# Deployment model dùng để Agent reasoning/generation — PHẢI là một deployment
# có thật trong tab "Models + endpoints" của CHÍNH Foundry resource này.
# Đây KHÔNG phải endpoint DeepSeek rời rạc như FOUNDRY_DEEPSEEK_ENDPOINT trong
# rag-pipeline.py cũ — nếu muốn dùng lại DeepSeek, model đó phải được deploy
# (serverless) ngay trong resource Foundry đang trỏ tới ở trên.
FOUNDRY_AGENT_MODEL_DEPLOYMENT = os.environ.get(
    "FOUNDRY_AGENT_MODEL_DEPLOYMENT", "gpt-4o-mini"
)

# ==========================================
# AZURE AI SEARCH (index đã tạo bằng create-index.py / chunking.py)
# ==========================================
AZURE_SEARCH_INDEX_NAME = os.environ.get("AZURE_SEARCH_INDEX_NAME", "ai300-notes-index")

# Tên PROJECT CONNECTION trỏ tới Azure AI Search — khác với AZURE_SEARCH_ENDPOINT
# (dùng gọi trực tiếp SearchClient trong chunking.py/rag-pipeline.py). Connection
# này phải được tạo lại trên project Foundry MỚI, xem ghi chú trong
# tools/search_tool.py.
AZURE_SEARCH_CONNECTION_NAME = os.environ.get(
    "AZURE_SEARCH_CONNECTION_NAME", "SearchServiceConnection"
)

# ==========================================
# CONTENT SAFETY (guardrails)
# ==========================================
# Để trống -> guardrails tự tắt (fail-open), không chặn nhầm khi chưa kịp cấu hình.
CONTENT_SAFETY_ENDPOINT = os.environ.get("CONTENT_SAFETY_ENDPOINT")
CONTENT_SAFETY_SEVERITY_THRESHOLD = int(
    os.environ.get("CONTENT_SAFETY_SEVERITY_THRESHOLD", "2")
)

# ==========================================
# PROMPT VERSIONING
# ==========================================
# .../src/agent/config.py -> parents[1] = .../src
SYSTEM_PROMPT_PATH = Path(__file__).resolve().parents[1] / "prompt" / "system_prompt.prompty"