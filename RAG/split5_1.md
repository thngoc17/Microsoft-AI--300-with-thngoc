---
source_url: https://claude.ai/chat/56a70ba3-009b-4a4d-858b-838d405d4fac
conversation_date: 2026-08-27 to 2026-09-01
context_week: Tuần 7
conversation_types: [LAP_KE_HOACH, LY_THUYET, FIX_HA_TANG, TRANH_LUAN_QUYET_DINH, KIEM_TRA_KIEN_THUC]
ai300_domains: ["Design and implement MLOps infrastructure", "Model lifecycle", "GenAIOps infrastructure", "Optimize generative AI systems and model performance"]
technologies: [Microsoft Foundry, Azure ML, Azure AI Search F0, GitHub Models, DeepSeek-V3.2-Speciale, llama.cpp, ChromaDB]
key_decision: "Do chính sách Azure for Students chặn chat completion, chuyển sang PAYG (có Budget Alert) để deploy thành công DeepSeek-V3.2-Speciale với chi phí token thấp, tránh xa các tính năng tính phí theo giờ như Managed Compute và Fine-tune."
status: resolved
---

## Bối cảnh & Vấn đề

Lộ trình học Tuần 7 tập trung vào làm quen với giao diện **Microsoft Foundry (mới)** để deploy và test các model AI "latest" qua Model Catalog. Tuy nhiên, quá trình thực hành gặp nhiều rào cản kỹ thuật và hành chính:

- **Sự khác biệt giao diện:** Microsoft đổi tên "Azure AI Foundry" thành "Microsoft Foundry", có toggle chuyển đổi giữa giao diện mới (foundry project) và classic (hub-based project).
- **Rào cản quota:** Người dùng gặp lỗi "insufficient quota" khi deploy chat model dù đã brute-force qua nhiều region.
- **Bẫy chi phí:** Vô tình bấm Fine-tune trong Foundry khiến $50 credit trong tài khoản Azure for Students bị đốt sạch.
- **Rào cản subscription:** Azure for Students không hỗ trợ chat completion service, bất kể model nào.

## Quyết định cuối cùng & Lý do

**Quyết định 1: Không dùng Managed Compute / Global Provisioned Throughput**
- **Lý do:** Tính phí theo giờ (cụm 8x A100 có thể tốn hàng chục triệu đồng/ngày), không phù hợp học tập. Chỉ dùng Serverless (PAYG) cho test.
- **Phương án bị loại bỏ:** Dùng GPU Dedicated - "KHÔNG dùng vì cần xác thực thanh toán và quota GPU cũng bị chặn tương tự".

**Quyết định 2: Chuyển từ Azure for Students sang PAYG (hoặc GitHub Models)**
- **Lý do:** Azure for Students có chính sách `RequestDisallowedByAzure` chặn chat completion. PAYG mở khóa hoàn toàn.
- **Phương án bị loại bỏ:** Chỉ dùng GitHub Models (miễn phí) - "KHÔNG dùng vì không sát với môi trường thi AI-300 thực tế".

**Quyết định 3: Deployment cuối cùng**
- **Model:** DeepSeek-V3.2-Speciale (Global Standard).
- **Lý do:** Giá rẻ (0.58 USD / 1M input tokens), hỗ trợ function calling (phù hợp Tuần 8), độ ổn định cao.

## Lệnh và Cấu hình cụ thể đã dùng

*Không có CLI/code blocks cụ thể trong log này. Các bước cấu hình chính bao gồm:*

- **Kiểm tra Budget Alert:**
  - Vào Azure Portal → Cost Management + Billing → Budgets → Tạo ngưỡng cảnh báo thấp (ví dụ $5).
- **Deploy Model trên Foundry:**
  - Đường dẫn (new UI): Discover → Models → Chọn model (DeepSeek-V3.2-Speciale).
  - Chọn **Deployment type**: Global Standard (Serverless API).
  - **Model instances**: Để mặc định (không tăng).
- **Kiểm tra Quota:**
  - Foundry Portal → Quota → Kiểm tra tab **Token per Minute** (cho Standard) và **Provisioned Throughput Unit** (cho PTU). Lưu ý đây là 2 kho quota khác nhau.

## Lỗi gặp phải và Cách khắc phục

| Lỗi / Vấn đề | Nguyên nhân chính xác | Cách khắc phục / Quy tắc rút ra |
| :--- | :--- | :--- |
| **"Insufficient quota"** khi deploy model dù bảng quota thấy có hạn mức. | Nhầm lẫn giữa quota **TPM** (Global Standard) và **PTU** (Provisioned Throughput). | Phân biệt rõ 2 tab trong Quota blade. Kiểm tra đúng tab tương ứng với deployment type đã chọn. |
| **Không deploy được bất kỳ chat model nào** ở bất kỳ region. | `Azure for Students` subscription bị chặn cấp platform (policy) cho loại tác vụ chat completion. (Lỗi: `RequestDisallowedByAzure`). | Chuyển sang Free Trial (nếu còn) hoặc PAYG. Tuyệt đối không cố brute-force region nữa. |
| **Mất $50 credit do bấm Fine-tune.** | Fine-tune trong Foundry tính phí theo giờ compute (training). Không phải miễn phí. | **Quy tắc:** Nghiêm cấm bấm "Fine-tune" và "Managed Compute" (Global Provisioned Throughput) trên Foundry nếu không có budget. Luôn đặt Budget Alert trước khi thao tác. |
| **Quota GPU (N-series) trên Azure ML bằng 0.** | Chính sách mặc định của các subscription mới/sinh viên. | Cần xin tăng quota, nhưng tỉ lệ duyệt thấp. Nếu cần training nhẹ, dùng CPU compute (Dv-series) như Tuần 3. |

## Lộ trình chi tiết (Tuần 7)

Dưới đây là lộ trình đã được lập, với lưu ý cập nhật giao diện mới của Microsoft Foundry:

**Ngày 1 — Hiểu kiến trúc mới**
- Đọc tài liệu "What is Microsoft Foundry".
- Phân biệt: **Hub-based project (Classic)** (dùng RP `Microsoft.MachineLearningServices`, có Hub cha) vs **Foundry project (mới)** (dùng RP `Microsoft.CognitiveServices`, cấu trúc Foundry Resource → Project → Assets).
- Deliverable: Bảng so sánh với Azure ML Workspace đã học.

**Ngày 2 — Tạo Foundry Project**
- Bật toggle **Foundry (new)** trên portal.
- Tạo Foundry resource + project (không tạo Hub).
- Khám phá thanh điều hướng: Agents, Models, Fine-tune, Knowledge, Data, Evaluations, Guardrails.

**Ngày 3 — Model Catalog và Deploy model**
- Đường dẫn mới: **Discover → Models** để chọn model.
- Deploy model bằng **Default settings** hoặc **Custom settings**.
- **Quan trọng:** Phải phân biệt rõ 2 kiểu tính phí:
  - **Serverless / PAYG:** Tính theo token. Không gọi = không tốn.
  - **Managed Compute / PTU:** Thuê GPU cụm, tính theo giờ. **Cực kỳ đắt**, chỉ dùng cho traffic cực lớn (>100M token/tháng). **Khuyến cáo không dùng cho học tập.**

**Ngày 4 — Kiểm thử & Đối chiếu**
- Vào **Build → Models** để quản lý endpoint.
- Test trong Playground.
- Lưu ý các mốc deprecate: Agents v1 (31/3/2027), Prompt Flow (20/4/2027), Workflows Agents v2 (1/12/2026).

**Ngày 5 — Gọi API từ code**
- **Cập nhật quan trọng:** Azure AI Inference beta SDK đã deprecate (26/8/2026). Chuyển sang dùng SDK OpenAI tiêu chuẩn (OpenAI/v1 API).
- Viết script Python gọi model đã deploy.

## Các phương án đã cân nhắc

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
| :--- | :--- | :--- | :--- |
| **Dùng Managed Compute (8x A100)** | Tốc độ cực nhanh, đúng chuẩn production. | Chi phí quá cao (hàng chục triệu/ngày). | **KHÔNG** (đã loại bỏ vì cost). |
| **Dùng Azure ML CPU + Qwen nhỏ** | Không đụng vào quota GPU, rẻ. | Lặp lại kỹ năng Tuần 3, không học được Foundry Model Catalog. | **KHÔNG** (đã loại bỏ vì đi lệch mục tiêu). |
| **Dùng GitHub Models** | Miễn phí, không cần thẻ. Dễ dùng. | Không sát với môi trường thi và kiến trúc Foundry. | **KHÔNG** (dự phòng, không dùng chính thức). |
| **Chuyển sang PAYG + Deploy Serverless (DeepSeek)** | Học đúng Foundry, chi phí token rất thấp (có thể free nếu ít request). | Cần thông tin thanh toán thật (nhưng đã có sẵn). Đặt Budget Alert để an toàn. | **ĐƯỢC CHỌN** |

## Nhật ký câu hỏi – trả lời – đánh giá

**Câu hỏi / Tình huống:** "Sao tôi thấy loại nào cũng không có quota mặc dù check trong bảng quota vẫn có hạn mức cho phép nhỉ? Vùng East Asia."
- **Câu trả lời của người dùng:** (Ngầm hiểu) Nghi vấn sai số của portal.
- **Đánh giá:** **Sai về bản chất.**
- **Đáp án chuẩn / Giải thích:** Quota TPM (Standard) và PTU (Managed) là hai kho khác nhau, nằm ở hai tab riêng biệt trong Quota blade. Việc thấy hạn mức ở tab TPM không có nghĩa là có PTU ở East Asia (thường là 0). Đây là bẫy dễ nhầm lẫn nhất trong Foundry.

**Câu hỏi / Tình huống:** "Tôi đã đốt hết $50, không muốn bỏ thêm 1 đồng nào cho MS trước khi thi AI-300."
- **Câu trả lời của người dùng:** Đề xuất bỏ Azure, dùng cloud khác hoặc tự host.
- **Đánh giá:** **Sai chiến lược.**
- **Đáp án chuẩn / Giải thích:** Việc rời Azure đi ngược mục tiêu ôn thi. Thay vì bỏ, nên dùng tính năng **Budget Alert** và chọn đúng **deployment type (Serverless)** để chi phí gần như bằng 0 cho mục đích test (vài cent cho vài trăm request). PAYG là con đường đúng nếu Free Trial đã hết.
