"""
Content Safety guardrails — kiểm soát input/output độc lập với toggle trên UI.

Dùng pattern `response.categories_analysis` (khuyến nghị hiện hành của
azure-ai-contentsafety), KHÔNG dùng response.hate_result / .violence_result /
.self_harm_result — các thuộc tính này vẫn tồn tại ở một số bản SDK nhưng tài
liệu chính thức hiện tại không còn minh hoạ theo cách đó, và categories_analysis
linh hoạt hơn khi cần thêm category mà không phải sửa lại nhiều chỗ trong code.
"""
from __future__ import annotations

from azure.ai.contentsafety import ContentSafetyClient
from azure.ai.contentsafety.models import AnalyzeTextOptions, TextCategory
from azure.identity import DefaultAzureCredential

from .config import CONTENT_SAFETY_ENDPOINT, CONTENT_SAFETY_SEVERITY_THRESHOLD

_CHECKED_CATEGORIES = [
    TextCategory.HATE,
    TextCategory.VIOLENCE,
    TextCategory.SELF_HARM,
    TextCategory.SEXUAL,
]


class ContentSafetyGuard:
    """Bọc input/output của Agent qua Azure AI Content Safety.

    Nếu CONTENT_SAFETY_ENDPOINT chưa được cấu hình, guard fail-open (luôn trả
    True) và in cảnh báo — tránh vô tình khoá cứng toàn hệ thống khi migrate
    dở dang và chưa kịp deploy Content Safety resource.
    """

    def __init__(self, endpoint: str | None = CONTENT_SAFETY_ENDPOINT):
        self.enabled = bool(endpoint)
        if self.enabled:
            self.client = ContentSafetyClient(endpoint, DefaultAzureCredential())
        else:
            print(
                "[CẢNH BÁO] CONTENT_SAFETY_ENDPOINT chưa được cấu hình "
                "-> guardrails đang TẮT (fail-open)."
            )

    def _is_safe(self, text: str) -> bool:
        if not self.enabled:
            return True

        response = self.client.analyze_text(AnalyzeTextOptions(text=text))

        for category in _CHECKED_CATEGORIES:
            result = next(
                (r for r in response.categories_analysis if r.category == category),
                None,
            )
            if result and result.severity > CONTENT_SAFETY_SEVERITY_THRESHOLD:
                print(
                    f"[GUARDRAILS] Chặn nội dung — category={category}, "
                    f"severity={result.severity} (ngưỡng={CONTENT_SAFETY_SEVERITY_THRESHOLD})"
                )
                return False
        return True

    def validate_input(self, user_prompt: str) -> bool:
        return self._is_safe(user_prompt)

    def validate_output(self, agent_reply: str) -> bool:
        return self._is_safe(agent_reply)