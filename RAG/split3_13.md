---
source_url: https://gemini.google.com/app/6f5439f231217ed7
conversation_date: 2026-09-01
context_week: N/A
conversation_types: [LY_THUYET, FIX_HA_TANG, TRANH_LUAN_QUYET_DINH]
ai300_domains: [Design and implement MLOps infrastructure, Model lifecycle]
technologies: [Conda, Pip, PyTorch, CUDA 12.1, OpenCV, NumPy, scikit-learn, matplotlib, pillow, ONNX, ONNX Runtime, PyYAML, tqdm, seaborn, Ultralytics, uv]
key_decision: "Ưu tiên giải pháp lai Conda + Pip dùng `environment.yml` hoặc `uv` để quản lý dependency; nếu gặp lỗi bản nightly PyTorch cũ, nên nâng cấp lên bản mới nhất thay vì hạ cấp về stable để tránh nợ kỹ thuật."
status: resolved
---

## Bối cảnh & Vấn đề

Người dùng đang sử dụng môi trường Conda và muốn cài đặt trực tiếp một danh sách các gói (được liệt kê theo định dạng `pip`) vào môi trường này, đồng thời mong muốn tránh gặp phải các vấn đề "dependency hell". Danh sách gói này có đặc điểm:

- Chứa hậu tố `+cu121` (dành cho CUDA 12.1) trong các gói PyTorch, đây là định dạng chỉ pip hiểu được.
- Gắn bản `dev` của PyTorch (`2.2.0.dev20231211`) - một bản nightly cũ từ tháng 12/2023.
- Kết hợp các thư viện mới ra mắt cuối 2024/đầu 2025 (scikit-learn~=1.6.1, matplotlib~=3.10.0) với PyTorch cũ.

## Quyết định cuối cùng & Lý do

**Kiến trúc chốt:** Sử dụng mô hình quản lý môi trường hybrid **Conda + Pip** (hoặc `uv` thay thế pip), trong đó:

1. **Conda (qua kênh conda-forge)** sẽ quản lý các thư viện lõi, đặc biệt là các thư viện có binding C/C++ (như NumPy, OpenCV, ONNX, ONNX Runtime) để tránh lỗi thiếu thư viện chia sẻ (.so/.dll) và đảm bảo đồng bộ với hệ thống.
2. **Pip (hoặc uv)** sẽ được sử dụng để cài các gói không có sẵn trên Conda hoặc yêu cầu build cụ thể, như bản dev của PyTorch và Ultralytics. Việc này được thực hiện bằng cách chỉ định `--extra-index-url` cho PyTorch.

**Lý do:**
- Tránh xung đột C/C++ runtime giữa các thư viện.
- Conda không hiểu hậu tố `+cu121` nên không thể cài trực tiếp, bắt buộc phải dùng pip cho phần này.
- Cách tiếp cận này cô lập bộ giải quyết phụ thuộc của Conda và pip, giảm nguy cơ xung đột.

**Phương án bị loại bỏ:**
- **KHÔNG dùng** `pip install -r` trực tiếp vào môi trường Conda rỗng. **Vì:** Công thức này chắc chắn dẫn đến xung đột dependency, đặc biệt giữa các thư viện C/C++ runtime.

**Khuyến nghị về phiên bản PyTorch:**
- Nếu lệnh cài đặt thất bại ở bước cài torch do kho lưu trữ đã xóa bản nightly `2.2.0.dev20231211`, **bắt buộc** phải thỏa hiệp bằng một trong hai hướng:
  1. **Hạ cấp về bản Stable 2.2.0:** Sửa thành `torch==2.2.0+cu121` và `torchvision==0.17.0+cu121` (yêu cầu index url [https://download.pytorch.org/whl/cu121](https://download.pytorch.org/whl/cu121)).
  2. **Nâng cấp lên bản Nightly/Stable mới nhất hiện có** (được khuyến nghị). **Vì:** Hệ thống cũ kỹ đi kèm với các package mới nhất là một nợ kỹ thuật (technical debt) không đáng có.

## Lệnh và Cấu hình cụ thể đã dùng

### Cách 1: Sử dụng tệp environment.yml (Khuyến nghị)

**1. Tạo tệp `environment.yml` với nội dung:**

```yaml
name: cv_workspace
channels:
 - conda-forge
 - defaults
dependencies:
 # Cấu hình lõi - Ép Python >= 3.10 để đáp ứng sklearn 1.6 & matplotlib 3.10
 - python=3.10
 - pip
 
 # Nhóm giải quyết qua Conda (tránh lỗi C/C++ runtime)
 - numpy~=1.26.4
 - scikit-learn~=1.6.1
 - pillow~=11.1.0
 - onnx>=1.15.0
 - onnxruntime>=1.16.0
 - pyyaml~=6.0.2
 - tqdm~=4.67.1
 - matplotlib~=3.10.0
 - seaborn~=0.13.2
 - opencv # Loại bỏ -python, dùng bản gốc của conda-forge
 
 # Nhóm giải quyết qua Pip
 - pip:
   # URL chỉ định kho lưu trữ chứa các bản build cho CUDA 12.1
   - --extra-index-url https://download.pytorch.org/whl/nightly/cu121
   - torch~=2.2.0.dev20231211
   - torchvision~=0.17.0.dev20231211
   - ultralytics~=8.3.189
```

**2. Chạy lệnh tạo môi trường:**

```bash
conda env create -f environment.yml
```

### Cách 2: Sử dụng uv (Thay thế pip, tối ưu tốc độ và tránh xung đột sâu)

**1. Tạo môi trường conda với phiên bản Python phù hợp:**

```bash
conda create -n cv_workspace python=3.10
conda activate cv_workspace
```

**2. Cài đặt uv:**

```bash
conda install conda-forge::uv
```

**3. Chạy cài đặt tệp requirements.txt của bạn thông qua uv pip:**

```bash
uv pip install -r requirements.txt --extra-index-url https://download.pytorch.org/whl/nightly/cu121
```

## Lỗi gặp phải và Cách khắc phục

1.  **Lỗi/Phương án không khả thi:**
    - **Anti-pattern:** Chạy `pip install -r` trực tiếp vào môi trường Conda.
    - **Rủi ro:** Xung đột dependency, đặc biệt là xung đột C/C++ runtime (OpenCV, NumPy, PyTorch).
    - **Cách khắc phục:** Sử dụng kiến trúc hybrid (Conda cho lõi, pip cho phần còn lại) hoặc dùng `uv`.

2.  **Lỗi tiềm ẩn:**
    - **Lỗi:** Lỗi thiếu thư viện chia sẻ (`opencv-python` qua pip).
    - **Nguyên nhân:** `opencv-python` từ pip không đồng bộ với hệ thống.
    - **Cách khắc phục:** Cài `opencv` thông qua kênh conda-forge (như trong `environment.yml`).

3.  **Lỗi có thể xảy ra khi cài PyTorch:**
    - **Lỗi:** Tỷ lệ thất bại cao khi tải bản nightly `2.2.0.dev20231211` do kho lưu trữ xóa các bản cũ.
    - **Cách khắc phục:** Thực hiện theo một trong hai hướng tại mục "Quyết định cuối cùng & Lý do".

## Khái niệm & Định nghĩa

- **Hậu tố `+cu121`**
  - **Định nghĩa:** Đây là "local version identifier" (định danh phiên bản cục bộ) chỉ có ý nghĩa với hệ sinh thái của PyTorch thông qua pip. Conda không hiểu định dạng này.
  - **Ví dụ:** `torch==2.2.0+cu121` sẽ được pip hiểu là phiên bản 2.2.0 được build cho CUDA 12.1, còn Conda sẽ báo lỗi.

- **Bản Nightly/Dev**
  - **Định nghĩa:** Các bản phát hành hàng đêm (nightly) hoặc chưa ổn định (dev) của một thư viện.
  - **Đặc điểm:** Các kho lưu trữ (repository) thường xóa các bản nightly cũ. Việc cố định một bản nightly cũ trong file cấu hình có tỷ lệ thất bại cao trừ khi bạn đã tải sẵn file `.whl` về máy.

- **Xung đột thế hệ thư viện (Library Generation Conflict)**
  - **Định nghĩa:** Tình trạng ghim các thư viện ở các mốc thời gian khác xa nhau, ví dụ như PyTorch cũ (cuối 2023) kết hợp với các thư viện mới ra mắt (cuối 2024/đầu 2025), dẫn đến yêu cầu phiên bản Python không tương thích hoặc xung đột phụ thuộc.

- **Nguyên tắc quản lý môi trường (Conda + Pip Hybrid)**
  - **Định nghĩa:** Giao quyền quản lý các thư viện lõi, C/C++ bindings (như OpenCV, NumPy, ONNX) cho Conda thông qua kênh conda-forge. Chỉ dùng pip để giải quyết các gói không có sẵn trên Conda hoặc yêu cầu build cụ thể (như bản dev của PyTorch và Ultralytics).

## Các phương án đã cân nhắc

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
| :--- | :--- | :--- | :--- |
| **1. Cài `environment.yml` hybrid** | - Cô lập bộ giải quyết phụ thuộc Conda và pip.<br>- Conda quản lý các thư viện C++ để tránh lỗi runtime.<br>- Là khuyến nghị chuẩn cho môi trường ML. | - Phức tạp hơn so với `pip install -r` đơn thuần.<br>- Yêu cầu viết và bảo trì file YAML. | **Có (Ưu tiên)** |
| **2. Sử dụng `uv` thay thế pip** | - Tốc độ nhanh, giải quyết dependency nghiêm ngặt hơn pip truyền thống.<br>- Vẫn có thể dùng trực tiếp file requirements.txt. | - Phụ thuộc vào công cụ bên thứ ba (`uv`).<br>- Vẫn cần cài thêm `uv` vào môi trường. | **Có (Phương án thay thế)** |
| **3. `pip install -r` trực tiếp** | - Đơn giản, nhanh chóng. | - **Chắc chắn dẫn đến xung đột** (dependency hell) do Conda không hiểu hậu tố CUDA và xung đột C/C++. | **KHÔNG** |
| **4. Nâng cấp PyTorch lên bản mới nhất** (Khuyến nghị khi bản cũ lỗi) | - Giảm nợ kỹ thuật.<br>- Tương thích tốt hơn với các thư viện mới. | - Có thể thay đổi API so với bản gốc (cần kiểm tra lại code). | **Có (Khi bản nightly cũ bị lỗi)** |
| **5. Hạ cấp PyTorch xuống bản Stable 2.2.0** | - Giữ nguyên phiên bản gần với gốc (2.2.0). | - Vẫn có thể tồn tại xung đột thế hệ thư viện với scikit-learn 1.6 và matplotlib 3.10. | **Có (Phương án dự phòng)** |
