---
source_url: https://gemini.google.com/app/e8aa9ba00a652bd6
conversation_date: 2026-09-04
context_week: N/A
conversation_types: [FIX_HA_TANG, LY_THUYET, TRANH_LUAN_QUYET_DINH, LAP_KE_HOACH]
ai300_domains: ["Thiết kế và triển khai hạ tầng MLOps", "GenAIOps infrastructure", "Tối ưu hệ thống GenAI và hiệu suất mô hình"]
technologies: [Azure Foundry, Azure OpenAI, TPM, PTU, Global Standard, Standard, Provisioned Throughput, Fine-tune, Enqueued tokens, Azure for Students, Resource Provider, Cognitive Services, ARM, GPT-4o-mini, Llama-3, Phi-3, text embeddings, FLUX.2, RAG, ChromaDB, Vector Database]
key_decision: "Từ bỏ việc deploy chatbot trên Azure Foundry do quota bị khóa cứng với tài khoản sinh viên; chuyển sang kiến trúc RAG phân tán (Decoupled RAG) sử dụng dịch vụ embeddings có sẵn + vector DB độc lập + endpoint sinh văn bản ngoại vi, nhằm phá vỡ ràng buộc hạ tầng và tiến độ dự án."
status: resolved
---

## Bối cảnh & Vấn đề

- Người dùng gặp khó khăn khi deploy chatbot trên Azure Foundry, dù đã kiểm tra quota TPM >0 tại vùng East Asia nhưng vẫn báo lỗi **"Insufficient Quota"**.
- Sau khi thử nhiều vùng và loại deployment (Global Standard, Standard, Provisioned Throughput), người dùng phát hiện hầu hết các vùng cho phép mở Foundry Project chỉ hỗ trợ model embeddings và tạo ảnh (FLUX.2), **không hỗ trợ model chat (GPT, Llama, Phi…)** dành cho tài khoản Azure for Students.
- Quá trình mò quota và tìm vùng khả thi kéo dài 4 ngày, làm chậm tiến độ dự án.

## Quyết định cuối cùng & Lý do

**Quyết định:** Đóng "Ngày 3" (dừng xử lý quota) và chuyển trục hạ tầng sang **kiến trúc RAG phân tán (Decoupled RAG Architecture)**.

**Lý do:**
- Azure for Students có chính sách cấp phát quota rất khắt khe, đặc biệt với các model sinh văn bản (chat) tại vùng phổ thông.
- Việc brute force tìm vùng khả thi đã chứng minh không có vùng nào hỗ trợ Standard TPM cho model chat; chỉ còn dịch vụ embeddings và image generation.
- Chi phí cơ hội: 4 ngày lãng phí là không thể chấp nhận, cần pivot ngay để chứng minh năng lực thiết kế và giữ tiến độ.

**Các phương án bị loại bỏ:**

| Phương án | Lý do loại bỏ |
|-----------|---------------|
| **Global Standard** | Gói Azure for Students KHÔNG cho phép sử dụng định tuyến đa vùng (global routing), luôn báo lỗi Insufficient Quota. |
| **Provisioned Throughput (PTU)** | Quota PTU tại East Asia = 0; không có sẵn cho subscription sinh viên. |
| **Deploy tại Japan East** | Chỉ có quota **FineTune** cho model 4.1-mini (500K TPM) nhưng **không có quota Standard** (0/0 TPM) → không thể deploy model chat. |
| **East Asia / các vùng châu Á** | Bị shadow ban hoặc khóa TPM đối với tài khoản sinh viên, dù giao diện hiển thị quota >0. |
| **Tiếp tục xin tăng quota** | Không khả thi vì Azure for Students không hỗ trợ yêu cầu tăng PTU hoặc TPM cho model chat. |

## Lệnh và Cấu hình cụ thể đã dùng

*Không có lệnh CLI/YAML/Bicep trong hội thoại; chỉ có các hướng dẫn vận hành trên Azure Portal. Dưới đây là các bước xác thực và dry-run được khuyến nghị:*

**Quy trình quét vùng khả thi (Dry-run Deployment):**

1. Truy cập **Azure Portal** (portal.azure.com), không dùng Foundry Portal.
2. Chọn **Create a resource** → tìm kiếm **Azure AI services** (hoặc **Azure OpenAI**) → bấm **Create**.
3. Tại tab **Basics**, xổ danh sách **Region**:
   - Hệ thống tự động kiểm tra quota của subscription và **bôi xám (greyed out)** các vùng không đủ quota hoặc bị cấm với Azure for Students.
   - Các vùng thường "sống sót": **Sweden Central, East US, Switzerland North, France Central**.
4. Nếu một region (vd: Sweden Central) được chấp nhận, tạo **Foundry Resource** (kind: `AiServices`) tại region đó.
5. Quay lại Foundry portal, tạo **Foundry Project** là con của resource vừa tạo.
6. Vào **Discover → Models**, chọn **gpt-4o-mini** hoặc model mã nguồn mở nhỏ (Phi-3, Llama-3) → **Deploy** → chọn **Deployment type = "Standard"** (KHÔNG chọn Global Standard hay Provisioned Throughput).

**Kích hoạt Resource Provider (nếu chưa đăng ký):**

- Azure Portal → Subscriptions → Chọn subscription → Resource providers → Tìm `Microsoft.CognitiveServices` → Nếu trạng thái `NotRegistered`, bấm **Register** và đợi 1-3 phút.

## Lỗi gặp phải và Cách khắc phục

| Lỗi / Hiện tượng | Nguyên nhân | Cách khắc phục |
|------------------|-------------|----------------|
| Báo `Insufficient Quota` dù TPM >0 | Nhầm lẫn giữa **TPM** (Standard/Global Standard) và **PTU** (Provisioned Throughput). Quota TPM không áp dụng cho deployment dạng Provisioned. | Chọn đúng **Deployment type = Standard** hoặc Global Standard (nếu được phép). |
| Global Standard cũng không được | Azure for Students không hỗ trợ global routing. | Chỉ dùng **Standard** (regional). |
| Không thấy dòng Cognitive Services trong Usage + quotas | Resource Provider `Microsoft.CognitiveServices` chưa được đăng ký (NotRegistered). | Đăng ký provider như hướng dẫn ở mục 3. |
| Vùng East Asia hiển thị quota nhưng deploy vẫn lỗi | Bị shadow ban hoặc vùng đông đúc bị khóa TPM cho tài khoản sinh viên. | Dùng dry-run deployment trên Azure Portal để phát hiện vùng thực sự khả dụng (Sweden Central, East US, …). |
| Japan East có 500K TPM dòng FineTune nhưng không deploy được model chat | Quota **FineTune** chỉ dùng cho model đã fine-tune, **không thể vay mượn** cho model thường. | Chỉ quan tâm dòng **không có hậu tố** (Standard) và phải >0. |
| Toàn bộ vùng chỉ hỗ trợ embeddings và tạo ảnh | Chính sách Azure for Students ưu tiên cấp quota cho tác vụ nhẹ (embeddings) và image, không cấp TPM cho model chat. | Chấp nhận pivot sang kiến trúc RAG phân tán. |

## Lộ trình chi tiết (sau khi pivot)

Theo khuyến nghị cuối cùng, lộ trình mới (không còn phụ thuộc vào Foundry) là:

- **Bước 1:** Khai thác dịch vụ **text embeddings** trên Azure (đã xác nhận có quota) để chuyển hóa tài liệu thành vector.
- **Bước 2:** Thiết lập **vector database độc lập** (ví dụ ChromaDB) để lưu trữ và truy vấn embedding.
- **Bước 3:** Xây dựng **endpoint sinh văn bản (Generation)** biệt lập hoặc môi trường tính toán tự quản trị (có thể dùng GPU riêng, model mã nguồn mở như Qwen).
- **Bước 4:** Định tuyến truy vấn (query routing): từ vector DB → endpoint generation → trả kết quả cho chatbot.

Mục tiêu: Hoàn thành POC trong vòng 1 tuần, không bị chặn bởi quota của nhà cung cấp.

## Khái niệm & Định nghĩa

**Enqueued tokens**
- Là hạn mức dành riêng cho xử lý batch bất đồng bộ (Asynchronous Batch Processing), thông qua loại triển khai **Global Batch** hoặc **Data Zone Batch**.
- Cơ chế: Gom nhiều request vào file JSONL, đẩy lên server, token được xếp hàng chờ xử lý trong vòng 24 giờ.
- **Không dùng cho chatbot thời gian thực**, vì chatbot yêu cầu inference với độ trễ thấp, đo bằng TPM (Tokens Per Minute).

**Hậu tố "- FineTune"**
- Là kỹ thuật phân tách hạn mức (quota segregation) giữa model nền tảng (base/foundation) và model đã fine-tune.
- **Loại thường (không hậu tố):** Hạn mức cho model gốc, gọi API và nhận kết quả ngay (zero-shot/few-shot).
- **Loại "- FineTune":** Hạn mức CHỈ dùng để triển khai model đã được fine-tune bằng dữ liệu riêng. **Không thể sử dụng cho model thường**, dù có TPM lớn.

## Các phương án đã cân nhắc

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
|-----------|----------|------------|------------|
| **Sử dụng Global Standard** | Định tuyến đa vùng, độ sẵn sàng cao | Không được phép trên Azure for Students → lỗi quota | ❌ KHÔNG |
| **Sử dụng Provisioned Throughput** | Cam kết băng thông cứng, ổn định | Quota PTU = 0 tại hầu hết vùng cho tài khoản sinh viên; chi phí cao | ❌ KHÔNG |
| **Deploy tại Sweden Central / East US** | Có TPM Standard khả dụng cho một số model (mini) | Vẫn bị giới hạn bởi chính sách sinh viên, chỉ dùng được model nhỏ | ❌ (cuối cùng không khả thi cho chatbot chat) |
| **Sử dụng dịch vụ embeddings + RAG phân tán** | Tận dụng quota embeddings có sẵn; không bị ràng buộc bởi quota model chat; linh hoạt về hạ tầng | Phải tự quản lý vector DB và endpoint generation; phức tạp hơn | ✅ ĐƯỢC CHỌN |

**Tiêu chí quyết định:** Ưu tiên khả năng triển khai ngay (không chờ xin quota), chi phí thấp, và minh chứng được kiến trúc hệ thống trong thời gian ngắn.

