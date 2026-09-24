---
source_url: https://gemini.google.com/app/d8067c4d38b71645
conversation_date: 2026-09-03
context_week: "Tuần 2"
conversation_types: [LAP_KE_HOACH, FIX_HA_TANG, FIX_CODE, TRANH_LUAN_QUYET_DINH, LY_THUYET]
ai300_domains: [Design and implement MLOps infrastructure, GenAIOps infrastructure]
technologies: [Azure ML, YAML, SSH, VS Code, Heredoc, Data Asset, ChromaDB, LangChain, HuggingFace, PyTorch, CUDA, Conda, Azure ML Environments, WSL]
key_decision: "Sử dụng Heredoc để tạo file YAML tránh lỗi thụt lề; bắt buộc dùng Public Key (không phải Private Key) cho SSH; kết nối Compute Instance không có Public IP qua Azure Relay; lưu ChromaDB vào ~/cloudfiles/ để bền vững; dùng Conda và Azure ML Curated Environments để quản lý thư viện CPU/GPU tự động thích ứng."
status: resolved
---

## Bối cảnh & Vấn đề

Người dùng đang trong quá trình thiết lập hạ tầng MLOps trên Azure cho dự án RAG chatbot (tuần 2 của lộ trình AI-300). Các vấn đề kỹ thuật cụ thể phát sinh:

- Lỗi parse YAML khi tạo Compute Instance do sai thụt lề.
- Nhầm lẫn giữa Private Key và Public Key khi cấu hình SSH.
- Compute Instance không được gán Public IP do chính sách tổ chức, phá vỡ kế hoạch kết nối SSH thủ công.
- Nhu cầu chuyển đổi từ môi trường local (WSL) sang Azure Compute Instance để đảm bảo tính nhất quán và bền vững của dữ liệu.
- Xung đột thư viện khi cài đặt CPU vs GPU trên cùng một môi trường.
- Tư duy code cũ gắn chặt với đường dẫn cục bộ, không tách biệt lưu trữ và tính toán.

## Quyết định cuối cùng & Lý do

| Quyết định | Lý do |
| :--- | :--- |
| **Sử dụng Heredoc (`cat <<EOF > file.yml`)** để tạo file YAML. | Tránh hoàn toàn lỗi thụt lề (indentation) do copy/paste thủ công hoặc dùng phím Tab. |
| **Bắt buộc sử dụng Public Key (`.pub`)** trong cấu hình SSH. | **KHÔNG dùng Private Key** vì: (1) Azure chỉ cần public key để xác thực, (2) Việc đẩy private key lên cloud là lỗ hổng bảo mật nghiêm trọng, (3) Private key có nhiều dòng sẽ phá vỡ cấu trúc YAML. |
| **Kết nối qua Azure Relay (VS Code Remote)** thay vì SSH trực tiếp. | **KHÔNG dùng SSH qua Public IP** vì Compute Instance bị chính sách tổ chức vô hiệu hóa Public IP. Phương án thay thế: dùng extension "Azure Machine Learning - Remote" để tạo đường hầm WebSocket qua Azure Relay. |
| **Lưu ChromaDB vào thư mục `~/cloudfiles/code/Users/azureuser/chroma_db_store`.** | **KHÔNG lưu trong thư mục mã nguồn (`./knowledge_db`)** vì Compute Instance có thể bị xóa hoặc tự tắt sau 30 phút idle. `~/cloudfiles/` được mount vào Azure File Share, đảm bảo lưu trữ vĩnh viễn (persistent). |
| **Sử dụng Azure ML Environments (Conda + Base Image)** để quản lý thư viện. | **KHÔNG dùng `pip install` trực tiếp** trên VM vì gây xung đột giữa bản dựng CPU và GPU, vi phạm nguyên tắc môi trường bất biến (Immutable Environment). Base Image của Microsoft (`mcr.microsoft.com/azureml/openmpi4.1.0-ubuntu22.04`) sẽ tự động điều chỉnh PyTorch cho CPU hoặc GPU. |
| **Đăng ký dữ liệu dạng `uri_folder` (Data Asset).** | Tách biệt lưu trữ và tính toán. Dữ liệu được đẩy lên Storage Account, pipeline sau này chỉ gọi bằng định danh `azureml:...` thay vì đường dẫn vật lý. |
| **Sử dụng `pathlib` và `os.path.expanduser`** cho đường dẫn. | **KHÔNG dùng dấu `\` hay ghép chuỗi thủ công** để đảm bảo tương thích đa nền tảng (Windows/WSL/Ubuntu). |

## Lệnh và Cấu hình cụ thể đã dùng

### Tạo SSH Key (trên Ubuntu/WSL)

```bash
# Tạo key (bỏ qua nếu đã có)
ssh-keygen -t rsa -b 4096 -f ~/.ssh/azureml_key -N ""

# Đọc Public Key vào biến môi trường (đúng chuẩn Linux)
PUB_KEY=$(cat ~/.ssh/azureml_key.pub)
```

### Tạo file YAML cho Compute Instance bằng Heredoc

```bash
cat <<EOF > compute-instance.yml
\$schema: https://azuremlschemas.azureedge.net/latest/computeInstance.schema.json
name: ci-dev-cpu-01
type: computeinstance
size: STANDARD_DS3_V2
ssh_settings:
  admin_username: azureuser
  ssh_key_value: "${PUB_KEY}"
idle_time_before_shutdown: PT30M
EOF
```

### Lệnh tạo Compute Instance

```bash
az ml compute create \
  --file compute-instance.yml \
  --resource-group "mlops-week1-rg" \
  --workspace-name "ml-test"
```

### Kiểm tra trạng thái và SSH settings

```bash
# Kiểm tra trạng thái (phải là Running)
az ml compute show \
  --name "ci-dev-cpu-n01" \
  --resource-group "mlops-week1-rg" \
  --workspace-name "ml-test" \
  --query "state" -o tsv

# Kiểm tra SSH settings (thiếu ssh_public_uri nếu không có Public IP)
az ml compute show \
  --name "ci-dev-cpu-n01" \
  --resource-group "mlops-week1-rg" \
  --workspace-name "ml-test" \
  --query "ssh_settings"
```

### Tạo Data Asset cho JSON (Heredoc)

```bash
cat <<EOF > data-asset.yml
\$schema: https://azuremlschemas.azureedge.net/latest/data.schema.json
name: digital-twin-knowledge-base
type: uri_folder
description: "Kho dữ liệu JSON phục vụ nhúng vector cho dự án Digital Twin."
path: ./My-Digital-Twin/my_data/
EOF

az ml data create \
  --file data-asset.yml \
  --resource-group "mlops-week1-rg" \
  --workspace-name "ml-test"
```

### Sửa đường dẫn trong `build_db.py` để lưu ChromaDB bền vững

**Đoạn code refactor (thay thế phần CẤU HÌNH ĐƯỜNG DẪN):**

```python
import os
from pathlib import Path
import chromadb
from chromadb.config import Settings

# --- CẤU HÌNH ĐƯỜNG DẪN BỀN VỮNG TRÊN AZURE ---
current_dir = os.path.dirname(os.path.abspath(__file__))
data_dir = os.path.join(current_dir, '..', 'my_data')
input_json_path = os.path.join(data_dir, 'profile.json')

# Ép lưu vào phân vùng cloudfiles để tránh mất dữ liệu
azure_persist_base = os.path.expanduser("~/cloudfiles/code/Users/azureuser/chroma_db_store")
db_output_path = os.path.join(azure_persist_base, 'knowledge_db')

os.makedirs(data_dir, exist_ok=True)
os.makedirs(db_output_path, exist_ok=True)

print(f"Đang đọc dữ liệu từ: {input_json_path}")
print(f"DB sẽ được lưu vĩnh viễn tại: {db_output_path}")

# --- KHỞI TẠO CHROMADB VỚI PERSIST_DIR ---
client = chromadb.PersistentClient(
    path=db_output_path,
    settings=Settings(anonymized_telemetry=False)
)
```

### Kiểm tra tính bền vững của ChromaDB

```bash
ls -la ~/cloudfiles/code/Users/azureuser/chroma_db_store/knowledge_db
# Kỳ vọng thấy file chroma.sqlite3
```

### Cấu hình môi trường Azure ML (Conda + Base Image)

**`conda_env.yaml`** (định nghĩa thư viện, để Conda tự chọn build CPU/GPU):

```yaml
name: rag-env
channels:
  - conda-forge
dependencies:
  - python=3.10
  - pip
  - pytorch  # Conda sẽ tự chọn bản phù hợp với phần cứng
  - pip:
    - langchain-huggingface
    - langchain-chroma
    - sentence-transformers
    - chromadb
```

**`azure-env.yml`** (định nghĩa Environment trên Azure ML):

```yaml
\$schema: https://azuremlschemas.azureedge.net/latest/environment.schema.json
name: rag-execution-env
description: Môi trường chạy RAG tự động thích ứng CPU/GPU
image: mcr.microsoft.com/azureml/openmpi4.1.0-ubuntu22.04
conda_file: conda_env.yaml
```

### Đảm bảo tính tất định trong code (CPU/GPU)

```python
import torch
import numpy as np
import random
from langchain_huggingface import HuggingFaceEmbeddings

SEED = 42
random.seed(SEED)
np.random.seed(SEED)
torch.manual_seed(SEED)

if torch.cuda.is_available():
    torch.cuda.manual_seed_all(SEED)
    # Ép cuDNN dùng thuật toán tất định
    torch.backends.cudnn.deterministic = True
    torch.backends.cudnn.benchmark = False

target_device = 'cuda' if torch.cuda.is_available() else 'cpu'
print(f"Môi trường thực thi được cố định tại: {target_device.upper()}")

embedding_model = HuggingFaceEmbeddings(
    model_name="bkai-foundation-models/vietnamese-bi-encoder",
    model_kwargs={'device': target_device}
)
```

## Lỗi gặp phải và Cách khắc phục

| Lỗi / Anti-pattern | Nguyên nhân | Cách khắc phục / Quy tắc thiết lập |
| :--- | :--- | :--- |
| `expected '<document start>', but found '<scalar>' in "compute-instant.yml", line 6, column 1` | Mất thụt lề (indentation) hoặc dùng Tab thay vì Space trong YAML. | **KHÔNG tạo file YAML thủ công bằng nano/vim**. Dùng Heredoc (`cat <<EOF > file.yml`) để đảm bảo thụt lề chính xác. |
| Đọc nhầm Private Key vào biến `PUB_KEY`. | Quên đuôi `.pub` và dùng đường dẫn Windows `:USERPROFILE\.ssh\...` trên Ubuntu. | **Bắt buộc đọc Public Key**: `PUB_KEY=$(cat ~/.ssh/azureml_key.pub)`. Trên Ubuntu dùng `~` hoặc `$HOME`, gạch chéo `/`. |
| Lệnh `az ml compute show --query "ssh_settings"` không trả về `ssh_public_uri`. | Compute Instance không có Public IP do Azure Policy cấm. | **KHÔNG dùng SSH trực tiếp**. Chuyển sang kết nối qua Azure Relay dùng VS Code extension "Azure Machine Learning - Remote". |
| Dữ liệu mất sau khi Compute Instance tắt. | Lưu ChromaDB trong thư mục mã nguồn (`./knowledge_db`) hoặc `/mnt/` (tạm thời). | **Bắt buộc lưu vào** `~/cloudfiles/...` (được mount với Azure File Share). Kiểm tra bằng `ls` sau khi tạo DB. |
| Xung đột thư viện CPU vs GPU khi cài bằng `pip`. | Cài thủ công trên VM dẫn đến "Dependency Hell". | **KHÔNG dùng `pip install` trực tiếp**. Dùng Azure ML Environment với Conda và Base Image của Microsoft. Conda sẽ tự động chọn bản PyTorch phù hợp với phần cứng. |
| Code dùng đường dẫn cứng (`C:\Users\...\`) dễ sập trên Linux. | Anti-pattern ghép chuỗi và dùng dấu `\`. | **Dùng `pathlib` hoặc `os.path.join`**. Ví dụ: `Path(__file__).resolve().parent / "data" / filename`. |

## Lộ trình chi tiết

| Ngày / Mốc | Mục tiêu | Chỉ tiêu hoàn thành |
| :--- | :--- | :--- |
| **Ngày 1** | Thiết lập hạ tầng Azure ML cơ bản. | - Tạo Resource Group, Workspace, Storage Account.<br>- Tạo Compute Instance (CPU) thành công với SSH key.<br>- Kiểm tra trạng thái `Running`. |
| **Ngày 2** | Kết nối VS Code vào Compute Instance. | - Cài extension "Azure Machine Learning - Remote".<br>- Đăng nhập Azure và kết nối được vào máy ảo (hiện dấu nhắc `azureuser@ci-dev-cpu-n01`). |
| **Ngày 3** | Đăng ký dữ liệu và chạy pipeline RAG cơ bản. | - Tạo Data Asset từ thư mục JSON (`digital-twin-knowledge-base`).<br>- Sửa `build_db.py` để lưu ChromaDB vào `~/cloudfiles/...`.<br>- Chạy thành công script, kiểm tra file `chroma.sqlite3` xuất hiện. |
| **Tuần 3** | Đóng gói môi trường và chuyển sang GPU (nếu có quota). | - Tạo Azure ML Environment (`rag-execution-env`).<br>- Test script trên môi trường mới, đảm bảo tính tất định (seed, cuDNN).<br>- Gửi yêu cầu tăng quota GPU (nếu cần). |

## Khái niệm & Định nghĩa

- **Data Asset (Azure ML)**: Tài nguyên quản lý dữ liệu trong Azure ML. Dạng `uri_folder` đại diện cho một thư mục (có thể chứa nhiều file), cho phép pipeline chỉ gọi bằng tên (ví dụ: `azureml:digital-twin-knowledge-base:1`) thay vì đường dẫn vật lý. Mục đích: tách biệt lưu trữ và tính toán.
- **Heredoc (trong Bash)**: Cú pháp `cat <<EOF > file` cho phép tạo file với nội dung nhiều dòng, giữ nguyên thụt lề và biến (interpolation). Ví dụ: Dùng để tạo YAML mà không lo sai indentation.
- **Azure Relay / VS Code Remote**: Cơ chế kết nối qua WebSocket, không cần Public IP. Extension "Azure Machine Learning - Remote" tạo đường hầm bảo mật từ VS Code (local) tới Compute Instance thông qua Control Plane của Azure. Thay thế cho SSH khi tổ chức chặn Public IP.
- **Immutable Environment (Môi trường bất biến)**: Nguyên tắc trong MLOps: môi trường thực thi (thư viện, HĐH, biến môi trường) được định nghĩa và đóng gói (ví dụ qua Docker/Conda), không thay đổi sau khi tạo. Đảm bảo tính nhất quán giữa Dev, Staging, Production.
- **CPU Fallback (PyTorch)**: Khi code yêu cầu GPU nhưng phần cứng không có, PyTorch tự động chuyển sang chạy trên CPU mà không báo lỗi. Ví dụ: `target_device = 'cuda' if torch.cuda.is_available() else 'cpu'`. Mặc dù chạy chậm hơn, logic và kết quả vẫn đúng.

## Các phương án đã cân nhắc

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
| :--- | :--- | :--- | :--- |
| **Dùng SSH trực tiếp qua Public IP** | Kết nối đơn giản, dùng file `~/.ssh/config`. | Yêu cầu Public IP. Azure Policy chặn Public IP. | **KHÔNG** |
| **Dùng Azure Relay / VS Code Remote** | Hoạt động khi không có Public IP. Tích hợp sẵn với VS Code. | Cần cài extension, phụ thuộc vào Control Plane. | **CÓ** |
| **Cài thư viện bằng `pip install` trên VM** | Nhanh, quen thuộc. | Gây xung đột CPU/GPU. Vi phạm nguyên tắc môi trường bất biến. | **KHÔNG** |
| **Dùng Azure ML Environment (Conda + Base Image)** | Conda tự giải quyết xung đột CPU/GPU. Đóng gói môi trường, tái sử dụng. | Cần định nghĩa 2 file YAML, chậm hơn lần đầu build. | **CÓ** |
| **Lưu ChromaDB trong thư mục mã nguồn** | Dễ viết code, thân thiện với local dev. | Dữ liệu mất khi compute instance bị xóa hoặc tắt. | **KHÔNG** |
| **Lưu ChromaDB trong `~/cloudfiles/...`** | Dữ liệu bền vững, được mount từ Azure File Share. | Phải refactor code, biết đường dẫn chính xác. | **CÓ** |

## Nhật ký câu hỏi – trả lời – đánh giá

**Câu hỏi 1**: Tại sao lệnh `az ml compute show --query "ssh_settings"` không trả về `ssh_public_uri` dù máy đang ở trạng thái `Running`?

- **Người dùng**: (Ngầm hỏi, mong đợi có IP để SSH).
- **Trợ lý đánh giá**: Sai. Nguyên nhân là do chính sách tổ chức vô hiệu hóa Public IP. Giải pháp đúng là dùng Azure Relay.
- **Đáp án chuẩn**: Compute Instance ở trạng thái `Running` nhưng không có Public IP. Kiểm tra `--query "state"` chỉ đảm bảo máy đã sẵn sàng, không đảm bảo có endpoint mạng. `ssh_public_uri` chỉ xuất hiện khi máy được cấp Public IP. Khi không có, phải dùng phương thức kết nối thay thế (Azure Relay).

**Câu hỏi 2**: Đoạn mã load JSON và tạo ChromaDB, nên lưu database ở đâu để không mất khi compute tắt?

- **Người dùng**: Đề xuất lưu trong thư mục `./knowledge_db` (cùng cấp với code).
- **Trợ lý đánh giá**: Sai. `./knowledge_db` nằm trong thư mục tạm thời của máy ảo.
- **Đáp án chuẩn**: Phải lưu trong `~/cloudfiles/code/Users/azureuser/chroma_db_store`. Đây là vùng được mount trực tiếp với Azure File Share, đảm bảo bền vững. Kiểm tra bằng `ls -la ~/cloudfiles/code/Users/azureuser/chroma_db_store/knowledge_db` để thấy file `chroma.sqlite3`.