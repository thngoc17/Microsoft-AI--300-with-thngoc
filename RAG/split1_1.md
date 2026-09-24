---
source_url: "https://gemini.google.com/app/0f1a1ffd9c17f208"
conversation_date: "2026-07-30"
context_week: "N/A"
conversation_types: [LAP_KE_HOACH, TRANH_LUAN_QUYET_DINH, LY_THUYET]
ai300_domains:
  - "Design and implement MLOps infrastructure"
  - "Model lifecycle"
technologies:
  - "Microsoft Azure"
  - "Microsoft Learn"
  - "Azure for Students"
  - "Azure Fundamentals"
  - "AI-900"
  - "AZ-900"
  - "DP-900"
  - "AZ-204"
  - "AI-102"
  - "AZ-104"
  - "AZ-305"
  - "DP-100"
  - "Azure Machine Learning"
  - "Azure ML Python SDK v2"
  - "Azure ML Workspace"
  - "Compute Instance"
  - "Compute Cluster"
  - "Azure Blob Storage"
  - "Datastores"
  - "Data Assets"
  - "CommandJob"
  - "Sweep Job"
  - "Model Registry"
  - "Managed Online Endpoint"
  - "Docker"
  - "FastAPI"
  - "Flask"
  - "PyTorch"
  - "YOLO"
  - "LLM"
  - "RAG"
  - "John Savill's Technical Training"
  - "Udemy"
key_decision: "Không nên đi theo AZ-104 hoặc các chứng chỉ Fundamentals làm trọng tâm; hướng phù hợp hơn là lộ trình Azure Associate/MLOps, đặc biệt DP-100 hoặc AI-102, kết hợp triển khai chính các project AI lên Azure."
status: open_question
---

## Bối cảnh & Vấn đề

Hội thoại bắt đầu từ nhu cầu tìm một con đường học và thi chứng chỉ Azure **chuẩn chỉnh nhưng tiết kiệm**, sau đó chuyển sang quyết định cấp độ chứng chỉ phù hợp, so sánh AZ-104 với đề thi đại học, rồi cuối cùng xuất hiện mục tiêu được gọi là **"AI-200"** và cần xác định lại chính xác chứng chỉ cũng như lộ trình học.

Các vấn đề chính được đặt ra:

- Học Azure và lấy chứng chỉ với chi phí thấp.
- Xác định nên học Fundamentals, Associate hay cấp độ cao hơn dựa trên nền tảng AI/programming hiện có.
- Bù đắp các kỹ năng Software Engineering và cloud deployment thông qua project thực chiến.
- Đánh giá độ rộng và kiểu khó của AZ-104 so với bài thi tại ĐH KHTN.
- Xác minh mã chứng chỉ **AI-200** và xử lý việc chọn hướng đi thay thế.
- Xây dựng lộ trình MLOps thực chiến trên Azure, ánh xạ workflow local/Jupyter/Kaggle sang Azure Machine Learning.

Nguồn gốc hội thoại và phần mở đầu về mục tiêu học Azure được ghi trong tài liệu.

## Quyết định cuối cùng & Lý do

### Hướng chứng chỉ

Quyết định ban đầu là nhắm vào **Associate**, không lấy Fundamentals làm trọng tâm và không vội chuyển lên Expert.

Lý do được đưa ra:

- Người học đã có nền tảng mạnh về lập trình AI, gồm LLM, YOLO, PyTorch và các project như chatbot/RAG.
- Khoảng trống quan trọng hơn nằm ở Software Engineering và deployment: Docker, API, server và đưa model lên cloud.
- Fundamentals như AZ-900/AI-900 được đánh giá là quá cơ bản đối với nền tảng hiện tại.
- Expert như AZ-305 bị đánh giá là thiên về enterprise architecture và đòi hỏi kinh nghiệm hệ thống thực tế nhiều hơn.

### Project-first thay cho học lý thuyết thuần túy

Quyết định được đề xuất là dùng chính các project đã có để học Azure:

- lấy chatbot persona hoặc hệ thống tracking bóng đá;
- viết API bằng FastAPI hoặc Flask;
- đóng gói model + API thành Docker image;
- deploy lên Azure Container Instances hoặc Azure App Service.

Theo nội dung hội thoại, flow này được kỳ vọng đồng thời rèn kỹ năng Engineer và bao phủ một phần đáng kể kiến thức lõi của AZ-204.

### AZ-104

**KHÔNG dùng AZ-104 làm hướng chính vì:**

- Nội dung tập trung mạnh vào System Administration/IT Operations và "cấu hình và quản lý".
- Networking, Storage và các kiến thức quản trị cloud được xem là lệch khỏi trọng tâm AI/Data Engineer đang hướng tới.
- Kiểu tư duy của AZ-104 thiên về quản trị hạ tầng, quota, SKU, thông số kỹ thuật, CLI/PowerShell và scenario-based administration thay vì coding/model deployment.

Hội thoại kết luận rằng AZ-104 có thể **khó học và dễ gây nản hơn** đối với người có nền tảng AI không phải vì toán học khó hơn mà vì nó yêu cầu kiểu ghi nhớ và tư duy hệ thống khác.

### Fundamentals

**KHÔNG dùng Fundamentals làm mục tiêu học chính vì** chúng chủ yếu cung cấp kiến thức cloud/AI cơ bản và ít tạo thêm giá trị thực chiến với nền tảng hiện có.

Tuy nhiên, Fundamentals vẫn được xem là đáng thi khi có thể lấy voucher miễn phí.

### "AI-200"

**ĐÃ LOẠI BỎ giả định rằng AI-200 là mã chứng chỉ cần theo đuổi**, vì hội thoại xác định rằng hệ thống chứng chỉ Azure được tham chiếu trong tài liệu không có mã "AI-200".

Hai hướng thay thế được đưa ra:

- **AI-102**: thiên về tích hợp Azure AI Services và xây dựng ứng dụng AI, ví dụ bọc LLM vào Web API.
- **DP-100**: thiên về Azure Machine Learning, training model, lifecycle, tracking và deployment.

Với các project YOLO/NLP/RAG và nhu cầu học MLOps, hội thoại **nghiêng về DP-100/ML Engineer** hơn AI-102. Tuy nhiên, cuối tài liệu vẫn yêu cầu xác định tiếp giữa hai hướng này, nên quyết định cuối cùng chưa hoàn toàn đóng.

## Lỗi gặp phải và Cách khắc phục

### Xác định sai mã chứng chỉ

**Lỗi:** mục tiêu được gọi là `AI-200`.

**Cách xử lý:** không tiếp tục xây lộ trình dựa trên mã đó; trước tiên xác định đúng certification target. Hai candidate được đề xuất là `AI-102` và `DP-100`.

### Anti-pattern: học chứng chỉ quá lệch khỏi mục tiêu nghề nghiệp

**Anti-pattern:** chọn AZ-104 chỉ vì đây là một certification Azure mà không xét mục tiêu AI/ML Engineering.

**Quy tắc được thiết lập:** certification nên bù đúng khoảng trống kỹ năng hiện tại. Với mục tiêu đưa model AI lên cloud, cần ưu tiên deployment, API, container, Azure ML và model lifecycle thay vì đi quá sâu vào administration/network/storage.

## Lộ trình chi tiết

### Giai đoạn 1 — Nền tảng + tài nguyên

Nguồn học được đề xuất:

- **Microsoft Learn**: tài liệu chính chủ và có Sandbox để thực hành.
- **John Savill's Technical Training**: Study Cram để tổng hợp kiến thức.
- **Udemy**: mock exams của Scott Duffy hoặc Alan Rodrigues, mua trong đợt sale.

Chiến lược chi phí:

- tận dụng Azure for Students và credit sinh viên;
- theo dõi Microsoft Virtual Training Days;
- tận dụng các chương trình voucher/giảm giá khi đủ điều kiện.

### Giai đoạn 2 — AZ-204-oriented project deployment

**Tuần 1–2**

- Học Docker cơ bản.
- Học RESTful API.
- Làm quen Azure Portal.
- Có thể sử dụng Azure for Students để thực hành.

**Tuần 3–5**

- Đưa project AI lên cloud.
- Thực hành deploy các model hiện có lên Azure.

**Tuần 6–8**

- Xem John Savill Study Cram.
- Làm mock exams.
- Chuẩn bị thi.

Tổng thời gian được ước tính khoảng **2–2,5 tháng với 10–15 giờ/tuần**.

### Giai đoạn 3 — Lộ trình MLOps trên Azure

Lộ trình được điều chỉnh về hướng DP-100/ML Engineer gồm:

1. **Thiết lập Azure ML Workspace**
   - Ưu tiên SDK thay vì chỉ thao tác UI.
   - Học `azure-ai-ml`, Azure ML Python SDK v2.
   - Làm việc với Workspace và Compute Instance.

2. **Quản lý dữ liệu**
   - Dùng Azure Blob Storage.
   - Tạo Data Assets.
   - Học versioning dữ liệu.

3. **Training Job và Hyperparameter Optimization**
   - Đưa script YOLO/RAG lên Azure ML.
   - Tạo `CommandJob`.
   - Định nghĩa environment.
   - Sử dụng base Docker image có PyTorch.
   - Thực hành `Sweep Job` để tìm hyperparameter.

4. **Model Registry và Deployment**
   - Register model vào Model Registry.
   - Viết `score.py`.
   - Cấu hình YAML.
   - Tạo `Managed Online Endpoint`.
   - Expose model thành API URL thực tế.

Các bước này trực tiếp tương ứng với model lifecycle/MLOps: workspace → data → training → optimization → registry → serving.

## Khái niệm & Định nghĩa

### Fundamentals
→ Cấp độ chứng chỉ nền tảng, tập trung vào các khái niệm cơ bản về cloud/Azure/AI.  
→ Ví dụ trong hội thoại: `AZ-900`, `AI-900`, `DP-900`.

### Associate
→ Cấp độ thực chiến, yêu cầu làm việc với dịch vụ và workflow triển khai thực tế.  
→ Ví dụ: `AZ-204`, `AI-102`.

### AZ-104
→ Azure Administrator, tập trung vào quản lý/cấu hình hệ thống Azure, bao gồm Networking, Storage, quyền và các thao tác vận hành.  
→ Ví dụ scenario trong hội thoại: hệ thống nhiều server, phân quyền người dùng và bảo vệ network.

### AI-102
→ Azure AI Engineer, tập trung vào tích hợp các AI API/services của Azure vào ứng dụng; ít tập trung vào train model từ đầu.  
→ Ví dụ trong hội thoại: bọc LLM vào Web API.

### DP-100
→ Azure Data Scientist, tập trung vào Azure Machine Learning, training model, tracking và deployment; đây là hướng được đánh giá khớp hơn với project YOLO/NLP hiện có.

### Azure ML Workspace
→ Không gian làm việc trung tâm cho workflow machine learning trên Azure.  
→ Ví dụ workflow: kết nối local → Workspace → Compute → Job → Model Registry → Endpoint.

### Data Asset
→ Đại diện dữ liệu được quản lý trên Azure ML thay vì để script truy cập trực tiếp các file CSV/image local.  
→ Ví dụ: dữ liệu được lưu trên Azure Blob Storage rồi tạo Data Asset để versioning.

### CommandJob
→ Job dùng để chạy training/script trên Azure ML với environment được định nghĩa.  
→ Ví dụ trong hội thoại: chạy script train YOLO hoặc RAG trên Azure.

### Sweep Job
→ Cơ chế tự động dò tìm hyperparameter trên Azure ML.  
→ Ví dụ trong hội thoại: dùng Sweep Job để tìm hyperparameter tốt nhất cho quá trình train.

### Model Registry
→ Nơi đăng ký/quản lý model sau khi training để phục vụ deployment.  
→ Ví dụ: train xong → register model → triển khai ra endpoint.

### Managed Online Endpoint
→ Endpoint trực tuyến cung cấp API URL để gửi request prediction tới model đã deploy.  
→ Ví dụ: `score.py` nhận request và trả về prediction.

### AZ-104 vs bài thi ĐH KHTN
→ AZ-104 được mô tả là bài thi thiên về system thinking, configuration và memory; còn bài thi Toán/Giải thuật/AI thiên về logic, toán học, chứng minh, code và optimization.  
→ Ví dụ đối chiếu trong hội thoại: AZ-104 yêu cầu suy nghĩ về phân quyền, network isolation và cấu hình hệ thống nhiều server.

## Các phương án đã cân nhắc

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
|---|---|---|---|
| Fundamentals (`AZ-900`, `AI-900`, `DP-900`) | Nền tảng dễ tiếp cận; có giá trị nếu lấy voucher miễn phí | Quá cơ bản so với nền tảng AI/programming hiện tại | Không làm mục tiêu chính |
| `AZ-204` | Bám sát Software Engineering, API, Docker và deployment | Không tập trung trực tiếp vào ML lifecycle | Có, từng được định hướng |
| `AZ-104` | Có kiến thức Azure administration sâu, hiểu Networking/Storage/RBAC | Lệch trọng tâm AI/Data Engineer; thiên SysAdmin; dễ học vẹt | **Không** |
| `AI-102` | Phù hợp xây ứng dụng AI và tích hợp Azure AI Services | Ít tập trung vào tự train/custom model và MLOps | Cân nhắc |
| `DP-100` | Khớp với Azure ML, training, tracking, deployment và lifecycle của model | Cần học thêm hệ sinh thái Azure ML nếu chưa quen | **Nghiêng về lựa chọn này** |
| `"AI-200"` | Là mục tiêu ban đầu được nêu | Mã chứng chỉ được hội thoại xác định là không tồn tại | **ĐÃ LOẠI BỎ** |
| `AZ-305` / Expert | Kiến thức architecture cấp enterprise | Quá xa nhu cầu hiện tại, đòi hỏi kinh nghiệm kiến trúc thực tế | **Không** |

Tiêu chí lựa chọn xuyên suốt là **mức độ phù hợp với mục tiêu AI/ML Engineer, khả năng tận dụng project hiện có, khoảng trống Software Engineering/MLOps và tính thực chiến**, thay vì chỉ chọn chứng chỉ theo độ "cao".

