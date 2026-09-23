"""
Agent chính — code-hoá từ ClickOps sang azure-ai-projects (Foundry MỚI).

Target SDK: azure-ai-projects>=2.0.0 (khớp evals/run_eval.py, khuyến nghị
pin đúng 2.7.0 để đồng bộ toàn repo). Không dùng from_connection_string —
phương thức này đã bị loại bỏ, phải khởi tạo bằng project endpoint.

Khác với rag-pipeline.py (tự gọi embedding + SearchClient + chat completion
thủ công), Agent ở đây UỶ QUYỀN retrieval cho Foundry Agent Service thông qua
AzureAISearchTool: Foundry tự lo việc query index + inject context vào model.
Khuyến nghị GIỮ LẠI rag-pipeline.py làm baseline so sánh kết quả (đúng kế
hoạch "code hoá & đối chiếu với Playground" của bạn), không xoá ngay.
"""
from __future__ import annotations

from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import PromptAgentDefinition
from azure.identity import DefaultAzureCredential

from . import config
from .guardrails import ContentSafetyGuard
from .tools.search_tool import build_azure_ai_search_tool


class FoundryRagAgent:
    def __init__(self):
        self.credential = DefaultAzureCredential()
        self.project = AIProjectClient(
            endpoint=config.FOUNDRY_PROJECT_ENDPOINT,
            credential=self.credential,
        )
        self.guard = ContentSafetyGuard()
        self._agent = None  # được set bởi create_or_update()

    def _load_instructions(self) -> str:
        if not config.SYSTEM_PROMPT_PATH.exists():
            raise FileNotFoundError(
                f"[LỖI] Không tìm thấy prompt: {config.SYSTEM_PROMPT_PATH}"
            )
        return config.SYSTEM_PROMPT_PATH.read_text(encoding="utf-8")

    def create_or_update(self):
        """
        Đăng ký Agent trên Foundry (Prompt Agent, server-side).

        LƯU Ý: create_version() tạo một VERSION MỚI mỗi lần gọi — không tự
        idempotent như create_or_update thông thường. Chỉ gọi hàm này khi
        thật sự đổi prompt/tool/model (vd. sau khi sửa system_prompt.prompty),
        KHÔNG gọi ở mỗi lần khởi động ứng dụng, để tránh sinh version rác.
        """
        search_tool = build_azure_ai_search_tool(self.project)

        self._agent = self.project.agents.create_version(
            agent_name=config.FOUNDRY_AGENT_NAME,
            definition=PromptAgentDefinition(
                model=config.FOUNDRY_AGENT_MODEL_DEPLOYMENT,
                instructions=self._load_instructions(),
                tools=[search_tool],
            ),
            description=(
                "GenAIOps Assistant — tra cứu ai300-notes-index qua "
                "Azure AI Search tool (code-first, thay thế ClickOps)."
            ),
        )
        print(
            f"[AGENT] Đã tạo/cập nhật '{self._agent.name}' "
            f"(id={self._agent.id}, version={self._agent.version})"
        )
        return self._agent

    def ask(self, question: str) -> dict:
        """Gửi câu hỏi tới Agent qua Responses API (không streaming)."""
        if not self.guard.validate_input(question):
            return {
                "answer": "Câu hỏi bị chặn bởi Content Safety guardrails.",
                "citations": [],
            }

        openai_client = self.project.get_openai_client()

        response = openai_client.responses.create(
            input=question,
            tool_choice="required",
            extra_body={
                "agent_reference": {
                    "name": config.FOUNDRY_AGENT_NAME,
                    "type": "agent_reference",
                }
            },
        )

        answer_text = getattr(response, "output_text", None) or ""
        citations = []
        for item in getattr(response, "output", []) or []:
            if getattr(item, "type", None) != "message":
                continue
            for content_part in getattr(item, "content", []) or []:
                for annotation in getattr(content_part, "annotations", []) or []:
                    if getattr(annotation, "type", None) == "url_citation":
                        citations.append(
                            {
                                "url": annotation.url,
                                "start": annotation.start_index,
                                "end": annotation.end_index,
                            }
                        )
        # Index hiện chưa có field URL retrievable (xem tools/search_tool.py)
        # -> citations ở trên thường RỖNG, đây là kỳ vọng bình thường.

        if not self.guard.validate_output(answer_text):
            return {
                "answer": "Phản hồi bị chặn bởi Content Safety guardrails.",
                "citations": [],
            }

        return {"answer": answer_text, "citations": citations}


if __name__ == "__main__":
    # So sánh nhanh với kết quả rag-pipeline.py / Playground ClickOps —
    # dùng lại đúng 2 câu test đã có trong rag-pipeline.py để đối chiếu.
    agent = FoundryRagAgent()
    agent.create_or_update()

    test_questions = [
        "Quyền RBAC là gì? Sự khác nhau giữa Control Plane và Data Plane?",
        "Công thức nấu phở bò chuẩn vị Nam Định là gì?",
    ]
    for q in test_questions:
        result = agent.ask(q)
        print("-" * 50)
        print(f"CÂU HỎI: {q}")
        print(f"TRẢ LỜI:\n{result['answer']}")
        print(f"CITATIONS: {result['citations']}")
        print("-" * 50)