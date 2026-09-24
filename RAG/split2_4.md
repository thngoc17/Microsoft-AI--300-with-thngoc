---
source_url: https://gemini.google.com/app/2cea387ffd972665
conversation_date: N/A (suy luận từ nội dung: sau ngày 11/03/2026, dựa trên đường dẫn lịch sử)
context_week: "Tuần 3 - Ngày 3 (suy luận từ dòng lịch sử: 'Ngày 3 của lô trình')"
conversation_types: [FIX_CODE, TRANH_LUAN_QUYET_DINH, LAP_KE_HOACH, FIX_HA_TANG, LY_THUYET]
ai300_domains: ["Thiết kế và vận hành cơ sở hạ tầng MLOps", "Vận hành GenAIOps"]
technologies: [Azure, Azure ML, Python, LangChain, ChromaDB, HuggingFace, PyTorch, Conda, Bicep/YAML (đề cập)]
key_decision: "Tái cấu trúc script Python từ dạng monolithic notebook sang kiến trúc modular, tách biệt cấu hình (qua env/CLI) khỏi logic, và gắn storage persistent (Azure Files) thay vì ổ đĩa ephemeral của Compute Instance để đảm bảo pipeline MLOps sản xuất."
status: resolved
---

## Bối cảnh & Vấn đề
*   **Code nguồn ban đầu (Notebook-style):** Mã nguồn mang tính chất thử nghiệm, hardcode đường dẫn, thiếu logging, xử lý ngoại lệ kém, và không đạt chuẩn để đưa vào pipeline MLOps sản xuất.
*   **Thách thức vận hành trên Azure:** Khi chạy trên Azure Compute Instance, thư mục lưu trữ Vector DB (`knowledge_db`) mặc định được tạo ngay sát mã nguồn, nằm trên ổ đĩa cục bộ (ephemeral). Điều này dẫn đến mất dữ liệu khi instance bị tắt (sau 30 phút).
*   **Lỗi thực thi:** Khi script được chạy trên Azure, gặp lỗi `OSError: undefined symbol` liên quan đến torch/torchaudio, nguyên nhân do sự xung đột giữa các thư viện PyTorch trong môi trường conda mặc định của Azure ML.

## Quyết định cuối cùng & Lý do
*   **Tái cấu trúc mã nguồn:** Áp dụng mô hình Module hóa, tách riêng phần:
    *   **Cấu hình (Configuration):** Quản lý qua class `PipelineConfig`, đọc từ Biến môi trường (`os.getenv`) và tham số CLI (`argparse`), loại bỏ hoàn toàn việc hardcode đường dẫn.
    *   **Logging:** Thay thế toàn bộ `print` bằng `logging` để có traceability và tích hợp với hệ thống giám sát tập trung.
    *   **Xử lý dữ liệu:** Đảm bảo dữ liệu metadata tuân thủ schema của ChromaDB (chỉ chấp nhận kiểu dữ liệu nguyên thủy: `str`, `int`, `float`, `bool`).
*   **Lưu trữ bền vững trên Azure (Persistent Storage):** Bắt buộc phải lưu Vector DB vào thư mục mount của Azure Storage (ví dụ: `~/cloudfiles/`) thay vì ổ cục bộ.
*   **Xử lý lỗi môi trường:** Xác định lỗi do sự không tương thích về ABI C++ giữa `torch`, `torchvision`, và `torchaudio`. Quyết định cài đặt lại bộ ba thư viện này từ một index chính thức dành riêng cho CPU để đảm bảo đồng bộ.
*   **ĐÃ LOẠI BỎ:** Phương án giữ nguyên logic tạo DB ngay sát thư mục code (`current_dir`) vì dữ liệu sẽ bị xóa khi instance tắt.

## Lệnh và Cấu hình cụ thể đã dùng
*   **Cấu trúc PipelineConfig mới:**
    ```python
    class PipelineConfig:
        def __init__(self, data_input_dir: str, db_output_dir: str, model_name: str):
            # Ưu tiên Biến môi trường cho Cloud (12-Factor App)
            env_input_dir = os.getenv("APP_DATA_INPUT_DIR", data_input_dir)
            env_output_dir = os.getenv("APP_DB_OUTPUT_DIR", db_output_dir)
            
            self.input_dir = Path(env_input_dir).resolve()
            self.input_json_path = self.input_dir / "profile.json"
            self.db_output_path = Path(env_output_dir).resolve()
            self.model_name = model_name
    ```
*   **Tham số CLI mới (hỗ trợ Persistent Storage):**
    ```bash
    # Chạy trên Azure: chỉ định thư mục DB nằm trong vùng mount persistent
    python build_db.py --db_output_dir ~/cloudfiles/data/knowledge_db
    ```
*   **Bản vá cho khối chuyển đổi dữ liệu (Document Transformer):**
    ```python
    # Sử dụng .copy() để tránh side-effect và xóa khóa 'keywords' list gốc
    meta = item.get('metadata', {}).copy()
    if 'keywords' in meta and isinstance(meta['keywords'], list):
        meta['keywords_str'] = ", ".join(meta['keywords'])
        del meta['keywords']  # BẮT BUỘC: Xóa list để ChromaDB không báo lỗi
    ```

## Lỗi gặp phải và Cách khắc phục
*   **Lỗi 1 (Logic): Vi phạm Schema của ChromaDB**
    *   *Mô tả:* Script giữ lại trường `keywords` dạng `list` trong metadata khi ghi vào ChromaDB, gây ra `ValueError`.
    *   *Khắc phục:* Bổ sung lệnh `del meta['keywords']` sau khi đã tạo chuỗi `keywords_str`.
*   **Lỗi 2 (Môi trường): `OSError: undefined symbol`**
    *   *Mô tả:* Lỗi liên quan đến `torchaudio` và `libtorch` khi load model embedding.
    *   *Khắc phục:* Cài đặt lại bộ ba PyTorch đồng nhất trên terminal của Compute Instance:
    ```bash
    pip uninstall -y torch torchvision torchaudio
    pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu
    ```
*   **Lỗi 3 (Kiến trúc): Dữ liệu bị xóa khi Instance tắt**
    *   *Mô tả:* Lưu DB vào ổ cục bộ.
    *   *Khắc phục:* Chuyển đường dẫn đầu ra sang thư mục mount của Azure Storage (ví dụ: `~/cloudfiles/...`).

## Lộ trình chi tiết
*   **Giai đoạn 1 (Hiện tại - Ngày 3):**
    *   [x] Tái cấu trúc script thành dạng module với logging và type hinting.
    *   [x] Hỗ trợ cấu hình qua CLI và Env Var, sẵn sàng cho Cloud.
    *   [x] Xác thực việc lưu trữ Vector DB trên vùng persistent (Azure Files).
*   **Giai đoạn 2 (Sắp tới - Lộ trình MLOps):**
    *   [ ] Đóng gói môi trường thành `requirements.txt` / `conda.yml`.
    *   [ ] Đăng ký Custom Environment trên Azure ML Workspace.
    *   [ ] Tích hợp script vào Azure ML Pipeline (sử dụng Command Job và Data Assets) thay vì chạy thủ công trên Compute Instance.

## Khái niệm & Định nghĩa
*   **Ephemeral Storage (Lưu trữ tạm thời):** Là ổ đĩa cục bộ của máy ảo (VMs) hoặc container, dữ liệu sẽ bị xóa khi instance bị tắt hoặc thu hồi. Trong kiến trúc Cloud, không nên lưu trạng thái quan trọng ở đây.
*   **Persistent Storage (Lưu trữ bền vững):** Là dịch vụ lưu trữ riêng biệt với compute, như Azure Files, Azure Blob. Dữ liệu tồn tại độc lập với vòng đời của VM, đảm bảo an toàn khi instance bị tắt.
*   **ABI (Application Binary Interface) Compatibility:** Sự tương thích ở cấp độ binary giữa các thư viện được viết bằng C/C++. Lỗi "undefined symbol" (như đã gặp với torchaudio) xảy ra khi một thư viện được biên dịch với phiên bản khác của thư viện khác (libtorch).

## Các phương án đã cân nhắc
| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
| :--- | :--- | :--- | :--- |
| **A. Giữ nguyên logic, hardcode đường dẫn `./my_data`** | Đơn giản, dễ chạy local. | Không linh hoạt, dễ mất dữ liệu trên Cloud. | Không |
| **B. Dùng `os.getcwd()` để tạo thư mục DB tự động** | Không cần nhập tham số. | Vẫn phụ thuộc vào vị trí mount code, không bền vững. | Không |
| **C. Tách biệt cấu hình qua Env Var và CLI, mount vùng Azure Files** | Đúng chuẩn 12-factor, dữ liệu bền vững, sẵn sàng cho CI/CD. | Phức tạp hơn, cần hiểu về cấu hình Cloud. | **Có** |```