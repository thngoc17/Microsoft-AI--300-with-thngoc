---
source_url: https://gemini.google.com/app/0af4325eb83c1a79
conversation_date: 2026-08-06
context_week: Tuần 2
conversation_types: [LAP_KE_HOACH, TRANH_LUAN_QUYET_DINH, FIX_HA_TANG, LY_THUYET, KIEM_TRA_KIEN_THUC]
ai300_domains: [Design and implement MLOps infrastructure, GenAIOps infrastructure]
technologies: [Azure ML, Compute Instance, Compute Cluster, Command Job, GPU Quota, Docker, WSL2, MLflow, Curated Environments, ChromaDB, LangChain, Qwen, FastAPI, Azure Container Registry]
key_decision: "Chuyển từ chiến lược test trên CPU Compute Instance sang kiến trúc GenAIOps thuần: bỏ qua training, sử dụng checkpoint Qwen inference trên CPU + RAG pipeline trên Azure ML Command Job với Compute Cluster scale-to-zero, Docker hóa API thành Online Endpoint."
status: resolved
---

## Bối cảnh & Vấn đề

**Vấn đề cốt lõi:** 
- Compute Instance đăng ký được là dạng CPU, gây xung đột thư viện nghiêm trọng (Torch CPU vs GPU)
- Test trên CPU không đảm bảo tương thích với môi trường GPU → không thể và không nên test trước bằng CPU CI
- Tài khoản Azure for Students **không cấp quota GPU** (cấm cứng ở cấp độ hệ thống)
- Chi phí phát sinh $10 chỉ sau vài giờ bật máy CPU → nguyên nhân: Compute Instance chạy 24/7, không tự scale-to-zero
- Mã nguồn hiện tại bị "Software Rot" (không chạy từ đầu năm 2026)
- Kiến trúc hiện tại bị phân mảnh: Kaggle notebooks (training + inference) tách biệt khỏi Azure pipeline → anti-pattern MLOps

**Phát hiện anti-pattern trong mã nguồn:**
```python
# Lỗi 1: Daemon service trong Command Job
bot.infinity_polling()  # → sẽ "giam" GPU 24/7, không phù hợp với Compute Cluster

# Lỗi 2: Hardcode đường dẫn
os.path.join(current_dir, '..', 'my_data')  # → không tồn tại trên container Azure ML

# Lỗi 3: Lưu Vector DB trên ổ ephemeral
persist_directory = db_output_path  # → bị xóa khi cluster tắt
```

## Quyết định cuối cùng & Lý do

**KHÔNG dùng: Phương án 1 — Fake model training trên CPU**
- Lý do: Model yếu → output rác → không thể tái cấu trúc end-to-end
- Đi ngược lại triết lý AI Engineering: "garbage in, garbage out"
- CI/CD sinh ra để phục vụ sản phẩm, không phải sản phẩm bị bóp méo để chạy vừa CI/CD

**KHÔNG dùng: Docker trên Windows để test GPU**
- Lý do: Thiết lập GPU passthrough qua WSL2 sẽ là "hố đen thời gian" nếu chưa vững Docker

**ĐÃ CHỌN: Phương án 2 — Bỏ qua training, sử dụng checkpoint Qwen + RAG pipeline**
- Lý do chính: Phù hợp với thực tế GenAIOps (Foundation Models không cần fine-tune từ đầu)
- Giải quyết bài toán domain-knowledge qua RAG (Retrieval-Augmented Generation)
- Qwen đã lượng từ hóa → chạy inference được trên CPU
- Azure ML Workspace vẫn là trung tâm quản lý, không cần nâng cấp subscription

**Kiến trúc mới:**
```
Data Pipeline (CI/CD) → ChromaDB → Blob Storage
                              ↓
Model Registry (Qwen checkpoint)
                              ↓
FastAPI → Docker → ACR → Azure Online Endpoint (CPU)
                              ↓
Telegram Bot (Client) → Gọi API Endpoint
```

## Lệnh và Cấu hình cụ thể đã dùng

### Cấu hình Environment (Ngày 3)
**File: `conda.yaml`**
```yaml
name: rag-telegram-env
channels:
- conda-forge
dependencies:
- python=3.10
- pip:
  - pyTelegramBotAPI==4.15.4
  - openai==1.14.0
  - langchain-core==0.1.33
  - langchain-huggingface==0.0.3
  - langchain-chroma==0.1.1
  - chromadb==0.4.24
  - sentence-transformers==2.5.1
  - underthesea-core==1.0.4
  - tqdm==4.66.2
  - mlflow
  - azureml-mlflow
```

**File: `environment.yml`**
```yaml
$schema: https://azuremlschemas.azureedge.net/latest/environment.schema.json
name: rag-telegram-gpu-env
version: 1
description: Môi trường GPU chứa PyTorch, Langchain, ChromaDB và thư viện xử lý NLP tiếng Việt.
image: mcr.microsoft.com/azureml/curated/acpt-pytorch-2.2-cuda12.1-ubuntu22.04-py310:latest
conda_file: conda.yaml
```

**Lệnh đăng ký Environment:**
```bash
az ml environment create --file environment.yml --resource-group <tên_resource_group> --workspace-name <tên_workspace>
```

### Cấu hình Compute Cluster CPU (Ngày 4)
**File: `compute.yml`**
```yaml
$schema: https://azuremlschemas.azureedge.net/latest/amlCompute.schema.json
name: aml-cluster-cpu
type: amlcompute
size: STANDARD_DS2_V2
min_instances: 0
max_instances: 1
idle_time_before_scale_down: 120
tier: low_priority
```

**Lệnh tạo Compute:**
```bash
az ml compute create --file compute.yml --resource-group <tên_resource_group> --workspace-name <tên_workspace>
```

### Cấu hình Command Job (Data Pipeline)
**File: `train_job.yml`**
```yaml
$schema: https://azuremlschemas.azureedge.net/latest/commandJob.schema.json
code: ./src
command: >
  python train_mock.py
  --data_dir ${inputs.training_data}
inputs:
  training_data:
    type: uri_folder
    path: azureml://datastores/workspaceblobstore/paths/my_data/
environment: azureml:rag-telegram-gpu-env:1
compute: azureml:aml-cluster-cpu
display_name: mock-training-pipeline
experiment_name: ai-300-ci-cd-test
```

**Lệnh submit job:**
```bash
az ml job create -f train_job.yml
```

### Các lệnh CLI Azure ML
**Lệnh chuẩn (Workspace-level):**
```bash
az ml environment create --file my_env.yml --resource-group my-resource-group --workspace-name my-workspace
```

**Lệnh Registry-level (cho Enterprise):**
```bash
az ml environment create --file my_env.yml --registry-name my-registry-name --resource-group my-resource-group
```

**⚠️ Lệnh cần tránh (Anti-pattern):**
```bash
az ml environment create --name my-env --version 1 --file my_env.yml --image pytorch/pytorch ...
# Việc ghi đè --image trên CLI phá vỡ tính toàn vẹn của YAML
```

## Lỗi gặp phải và Cách khắc phục

### Lỗi xung đột thư viện trên Compute Instance CPU
| Lỗi | Nguyên nhân | Cách khắc phục |
|-----|-------------|----------------|
| Xung đột Torch + các thư viện khác | PyTorch CPU vs GPU dependency | Dùng Curated Environments của Azure ML làm base image |
| Code chạy trên CPU không đảm bảo chạy trên GPU | Environment mismatch | Bỏ qua test trên CPU, đi thẳng vào Command Job trên GPU/CPU đích |

### Lỗi Quota GPU trên Azure for Students
| Lỗi | Nguyên nhân | Cách khắc phục |
|-----|-------------|----------------|
| Không tìm thấy tùy chọn GPU trong Compute | Azure for Students cấm cấp quota GPU ở cấp độ hệ thống | 1. Nâng cấp lên Pay-As-You-Go + xin quota (24-48h) **hoặc** 2. Chuyển sang CPU cluster + mock model/checkpoint Qwen |

### Lỗi chi phí $10 chỉ trong vài giờ
| Lỗi | Nguyên nhân | Cách khắc phục |
|-----|-------------|----------------|
| Phát sinh chi phí bất thường | Sử dụng Compute Instance (chạy 24/7) thay vì Compute Cluster | Luôn dùng Compute Cluster với `min_instances: 0` và `idle_time_before_scale_down: 120` |
| Không tắt tài nguyên sau khi dùng | Quên tắt Compute Instance | Thiết lập scale-to-zero tự động |

### Lỗi kiến trúc trong mã nguồn
| Anti-pattern | Vấn đề | Cách khắc phục |
|--------------|--------|----------------|
| `bot.infinity_polling()` | Job chạy vô hạn, "giam" cluster | Tách bot thành Client, deploy API riêng |
| Hardcode đường dẫn `os.path.join(current_dir, '..')` | Đường dẫn không tồn tại trên container | Dùng argparse để truyền đường dẫn từ CLI |
| Lưu Vector DB vào ổ cục bộ | Bị xóa khi cluster scale-down | Trỏ `persist_directory` vào Datastore mount |
| Notebook trên Kaggle | Không thể CI/CD, không version control | Refactor sang .py files, đưa vào git |

## Lộ trình chi tiết (Tuần 2 & 3)

### Tuần 2 — Data Pipeline & RAG Infrastructure

| Ngày | Mục tiêu | Chỉ tiêu hoàn thành |
|------|----------|---------------------|
| **Ngày 3** | Định nghĩa Environment GPU chuẩn | Tạo file `conda.yaml` + `environment.yml`, đăng ký lên Azure bằng CLI. Build hoàn tất trong < 30 phút. |
| **Ngày 4** | Thiết lập Compute Cluster CPU | Tạo `compute.yml` với `min_instances: 0`. Đăng ký thành công, kiểm tra trong Azure ML Studio. ✅ ĐÃ HOÀN THÀNH (dùng CPU do quota). |
| **Ngày 5** | Đóng gói Data Pipeline (Command Job) | Refactor `process_data.py` + `build_db.py` thành script đọc/ghi từ Datastore. Job chạy thành công, Vector DB được ghi lên Blob Storage. |
| **Ngày 6** | Tích hợp MLflow Tracking | Gọi `mlflow.autolog()` và `mlflow.log_metric()` trong script. Xem được metrics trong Azure ML Studio tab Experiments. |
| **Ngày 7** | Local Docker Foundations (chuẩn bị Tuần 3) | Cài Docker Desktop, bật WSL2 backend. Viết Dockerfile tối giản cho Python, thực hành `docker build`, `docker run`, `docker push`. |

### Tuần 3 — Docker hóa & Deploy Qwen (NLP)

| Ngày | Mục tiêu | Chỉ tiêu hoàn thành |
|------|----------|---------------------|
| **Ngày 8** | Refactor code: Telegram → FastAPI | Tách riêng logic RAG khỏi telebot. Xây dựng API FastAPI nhận POST request, trả JSON. Test local thành công. |
| **Ngày 9** | Đăng ký Checkpoint Qwen vào Model Registry | Tải checkpoint Qwen (định dạng GGUF/quantized) lên Datastore. Đăng ký vào Azure ML Model Registry. |
| **Ngày 10** | Viết Dockerfile cho Inference CPU | Base image `python:3.10-slim`. Cài dependencies, copy code, entrypoint Uvicorn/FastAPI. Build local thành công. |
| **Ngày 11** | Push image lên Azure Container Registry | `docker tag` + `docker push` thành công. Kiểm tra image trong ACR. |
| **Ngày 12** | Deploy Managed Online Endpoint | Viết deployment YAML. Endpoint chạy trên CPU, tải checkpoint từ Registry. Test gọi API thành công. |
| **Ngày 13** | Cập nhật Telegram Bot thành Client | Bot cục bộ gửi request đến Azure Endpoint. End-to-end test thành công. |

## Khái niệm & Định nghĩa

| Thuật ngữ | Định nghĩa | Ví dụ trong hội thoại |
|-----------|------------|----------------------|
| **Compute Cluster** | Cụm máy ảo dùng cho batch processing, tự động scale về 0 khi không dùng | `min_instances: 0`, `idle_time_before_scale_down: 120` → cluster tự tắt sau 2 phút job hoàn tất |
| **Compute Instance** | Máy ảo chạy liên tục 24/7, dùng cho dev/interactive work | Thủ phạm gây chi phí $10 sau vài giờ bật máy |
| **Curated Environments** | Image container sẵn do Microsoft cung cấp, đã cài CUDA + PyTorch tối ưu | `mcr.microsoft.com/azureml/curated/acpt-pytorch-2.2-cuda12.1-ubuntu22.04-py310:latest` |
| **Command Job** | Đơn vị thực thi trên Azure ML, kết nối Code + Environment + Compute | File YAML khai báo `code`, `command`, `environment`, `compute` |
| **MLflow Tracking** | Ghi log parameters, metrics, artifacts trong quá trình thực thi | `mlflow.autolog()`, `mlflow.log_metric("loss", 0.01)` |
| **Datastore** | Kết nối đến Azure Blob Storage để lưu dữ liệu đầu vào/đầu ra | `azureml://datastores/workspaceblobstore/paths/my_data/` |
| **GenAIOps** | Ứng dụng MLOps cho Foundation Models; tập trung vào RAG, inference, evaluation | Bỏ qua training, dùng Qwen checkpoint + RAG pipeline |
| **Quota** | Hạn mức tài nguyên cho từng vùng/region | Azure for Students: quota GPU = 0 (cấm cứng) |
| **Spot Instance (Low Priority)** | Máy ảo giá rẻ, có thể bị thu hồi bất kỳ lúc nào | Giảm 70-80% chi phí so với dedicated |

## Các phương án đã cân nhắc

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
|-----------|---------|------------|------------|
| **Test trên Compute Instance CPU** | Dễ thiết lập, không cần cấu hình thêm | Xung đột thư viện nặng, không đảm bảo tương thích GPU, tốn chi phí 24/7 | ❌ KHÔNG |
| **Docker trên Windows + WSL2 GPU passthrough** | Test local với GPU | Cực kỳ phức tạp, dễ rơi vào "hố đen thời gian" | ❌ KHÔNG |
| **Phương án A: Nâng cấp subscription + xin quota GPU** | Train được Qwen thật sự trên cloud | Tốn tiền, chờ 24-48h xin quota | ❌ KHÔNG (do budget) |
| **Phương án 1: Fake model training trên CPU** | Giữ được pipeline training, không cần GPU | Model rác, không thể end-to-end thực tế, đi ngược triết lý | ❌ KHÔNG |
| **Phương án 2: Bỏ training, dùng checkpoint Qwen + RAG** | GenAIOps chuẩn mực, không cần GPU, giá trị thực tế cao | Không thực hành được training tracking | ✅ ĐÃ CHỌN |

**Tiêu chí quyết định:** 
1. Chi phí (ưu tiên hàng đầu với Azure for Students)
2. Giá trị thực tiễn của hệ thống
3. Độ sát với thực tế GenAIOps (Foundation Models không cần fine-tune từ đầu)
4. Mức độ bao phủ kiến thức AI-300 (Data pipeline, Model Registry, Containerization, Online Endpoint)

## Nhật ký câu hỏi – trả lời – đánh giá

### Câu 1: Xác định domain AI-300
**Câu hỏi:** Mã nguồn hiện tại (RAG + Qwen checkpoint) thuộc domain nào trong 5 domain của AI-300?

**Câu trả lời của người dùng:** "Trọng tâm của AI-300 là Model Lifecycle và GenAIOps"

**Đánh giá:** ✅ Đúng — 2 domain chính:
- GenAIOps infrastructure (RAG pipeline, inference serving)
- GenAI quality assurance and observability (MLflow tracking ở inference phase)

---

### Câu 2: Tại sao không thể tìm thấy GPU trên Azure for Students?

**Câu hỏi:** "Làm thế nào để tôi tạo 1 compute cluster đúng? Tôi không check được cái nào cho tôi GPU."

**Câu trả lời của người dùng:** (Không trả lời trực tiếp, chỉ đưa ảnh chụp màn hình)

**Đánh giá:** ❌ Người dùng chưa hiểu nguyên nhân gốc rễ

**Đáp án chuẩn:** Azure for Students **cấm cứng** ở cấp độ hệ thống việc cấp quota GPU (các dòng NC, ND, NV). Việc tìm kiếm "NC" trong Usage + quotas sẽ trả về trống hoặc báo 0 quota. Support ticket cũng bị auto-reject.

---

### Câu 3: Phân biệt MLOps truyền thống vs GenAIOps

**Câu hỏi:** "Nếu fake kiểu đó chắc chắn 100% qua tuần 3 sẽ tê liệt hoàn toàn nếu không thực hiện code lại toàn bộ project theo hướng CPU-base"

**Câu trả lời của người dùng:** Lo ngại phải viết lại toàn bộ code cho CPU

**Đánh giá:** ❌ Sai — Người dùng chưa hiểu rằng BERT-based model (bkai-foundation-models/vietnamese-bi-encoder) tự động chạy trên CPU nhờ `torch.cuda.is_available()`; không cần viết lại code.

**Đáp án chuẩn:** 
- Inference (Forward Pass): Có thể chạy Qwen lượng từ hóa trên CPU (GGUF/llama.cpp)
- Training (Backpropagation): KHÔNG thể fine-tune LLM trên CPU (kể cả LoRA) — mất hàng tuần
- Embedding model (sentence-transformers): TỰ ĐỘNG tương thích CPU/GPU

---

### Câu 4: Câu lệnh CLI nào đúng cho Environment?

**Câu hỏi:** Chọn lệnh đúng để đăng ký Environment từ file YAML

**Câu trả lời của người dùng:** Đã đưa ra 3 lựa chọn từ help của CLI

**Đánh giá:** ✅ Đúng — Người dùng đã nhận ra lệnh chuẩn:
```bash
az ml environment create --file my_env.yml --resource-group my-resource-group --workspace-name my-workspace
```

**Đáp án chuẩn:** 
- ✅ Lệnh 1 (Workspace-level): Đúng, minh bạch nhất cho CI/CD
- ⚠️ Lệnh 2 (Registry-level): Chỉ dùng khi có nhiều workspace chia sẻ chung image
- ❌ Lệnh 3 (Override YAML): Anti-pattern, phá vỡ Source of Truth

---

### Câu 5: Chi phí $10 chỉ sau vài giờ CPU

**Câu hỏi:** "Tôi chỉ mới bật máy CPU vài tiếng mà billing hiện tại đã lên tới 10$"

**Câu trả lời của người dùng:** Cho rằng cloud quá đắt

**Đánh giá:** ❌ Sai — Nguyên nhân là do thiết kế hạ tầng, không phải giá cloud

**Đáp án chuẩn:** 
- Standard_DS2_v2: ~$0.11-0.15/giờ
- Để đạt $10 trong vài giờ → phải là Compute Instance (chạy 24/7) hoặc dùng VM quá lớn
- Giải pháp: Compute Cluster với `min_instances: 0` + `idle_time_before_scale_down: 120` + `tier: low_priority`

---

### Câu 6: Có nên thử nghiệm training LLM trên CPU?

**Câu hỏi:** Qwen "chạy được trên CPU" → có nên fine-tune trên CPU?

**Câu trả lời của người dùng:** Đề xuất Phương án B: "model Qwen tôi sử dụng chạy được trên CPU"

**Đánh giá:** ❌ Sai — Nhầm lẫn giữa inference và training

**Đáp án chuẩn:** 
- ✅ Inference (suy luận): Qwen lượng từ hóa chạy được trên CPU (tuy chậm)
- ❌ Training (huấn luyện): Không thể fine-tune LLM trên CPU thông thường — mất hàng tuần cho 1 epoch
- Backpropagation + gradient descent yêu cầu Tensor cores của GPU
