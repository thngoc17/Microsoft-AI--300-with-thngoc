---
source_url: https://gemini.google.com/app/79a189d9176640da
conversation_date: 2026-09-03
context_week: N/A
conversation_types: [FIX_HA_TANG, LY_THUYET]
ai300_domains: [Thiết kế và triển khai hạ tầng MLOps]
technologies: [Azure CLI, Azure Key Vault, Azure Python SDK, azure-identity, azure-keyvault-secrets, azure-mgmt-keyvault, pip, winget, PowerShell]
key_decision: "Không dùng gói `azure` toàn cục (đã bị deprecated); thay vào đó, dùng Azure CLI trên terminal và các micro-packages Python (azure-identity, azure-keyvault-secrets) riêng biệt cho từng dịch vụ."
status: resolved
---

## Bối cảnh & Vấn đề

Người dùng gặp phải **hai vấn đề hoàn toàn độc lập** trong cùng một phiên làm việc:

1.  Lỗi khi chạy lệnh `az keyvault create` trên PowerShell: `The term 'az' is not recognized`.
2.  Lỗi khi chạy `pip install azure` để cố gắng xử lý vấn đề số 1: gói `azure` đã bị deprecated, không thể cài đặt từ phiên bản 5.0.0.

Người dùng đã nhầm lẫn giữa Azure CLI (công cụ dòng lệnh) và Azure SDK cho Python (thư viện phần mềm).

## Quyết định cuối cùng & Lý do

*   **Vấn đề 1 (lệnh `az`):**
    *   **Quyết định:** Cài đặt Azure CLI ở cấp độ hệ điều hành thông qua `winget install -e --id Microsoft.AzureCLI` hoặc tải bộ cài MSI trực tiếp.
    *   **Lý do:** `az` là một trình thực thi độc lập, không phải là một gói Python. Nó cần được cài đặt và thêm vào biến môi trường `PATH`.
    *   **Lưu ý:** Sau khi cài đặt, bắt buộc phải **khởi động lại** PowerShell/IDE để nhận biến môi trường mới.
    *   **Phương án bị loại bỏ:** KHÔNG dùng `pip install azure` để cài đặt CLI. Đây là một sai lầm về mặt kiến trúc.

*   **Vấn đề 2 (gói `azure` trên Python):**
    *   **Quyết định:** Cài đặt các micro-packages chuyên biệt cho từng dịch vụ. Cụ thể cho Key Vault: `pip install azure-identity azure-keyvault-secrets`.
    *   **Lý do:** Gói `azure` nguyên khối (monolithic) đã bị Microsoft loại bỏ (deprecated) từ phiên bản 5.0.0 để giảm "bloatware" và chỉ tập trung vào các module cần thiết cho từng tác vụ.
    *   **Phương án bị loại bỏ:** KHÔNG cài `azure`. Nếu muốn quản lý Key Vault (tạo, xóa, cấu hình) bằng Python, cần cài `azure-mgmt-keyvault`. Nếu chỉ muốn đọc/ghi secret, cài `azure-keyvault-secrets`.

## Lệnh và Cấu hình cụ thể đã dùng

**Lệnh Azure CLI (để tạo Key Vault trên PowerShell):**
```powershell
az keyvault create --name $KEY_VAULT_NAME --resource-group $RESOURCE_GROUP --location "eastasia"
```

**Lệnh cài đặt Azure CLI qua Winget (giải pháp cho lỗi thiếu `az`):**
```powershell
winget install -e --id Microsoft.AzureCLI
```

**Lệnh cài đặt Azure SDK for Python chính xác (cho việc tương tác với Key Vault):**
```bash
pip install azure-identity azure-keyvault-secrets
```

**Lệnh cài đặt Azure SDK cho Management (nếu cần quản lý Key Vault bằng Python):**
```bash
pip install azure-mgmt-keyvault
```

## Lỗi gặp phải và Cách khắc phục

| **Lỗi** | **Nguyên nhân** | **Cách khắc phục** |
| :--- | :--- | :--- |
| `The term 'az' is not recognized` | Azure CLI chưa được cài đặt trên hệ điều hành hoặc chưa có trong biến môi trường PATH. | Cài đặt Azure CLI (dùng `winget` hoặc MSI) và **khởi động lại** terminal. |
| `error: RuntimeError: Starting with v5.0.0, the 'azure' meta-package is deprecated...` | Cố gắng cài đặt gói `azure` toàn cục đã bị deprecated. | Cài đặt các gói module cụ thể cho dịch vụ cần dùng (ví dụ: `azure-keyvault-secrets`). |

## Khái niệm & Định nghĩa

*   **Thuật ngữ:** Azure CLI
    *   **Định nghĩa:** Là một công cụ dòng lệnh (command-line tool) cấp hệ điều hành để quản lý và tương tác với các tài nguyên Azure.
    *   **Ví dụ:** Lệnh `az keyvault create` được dùng để tạo một vault trên Azure từ terminal.
*   **Thuật ngữ:** Azure Python SDK
    *   **Định nghĩa:** Là tập hợp các thư viện (libraries) dành cho ngôn ngữ lập trình Python, được thiết kế để viết mã nguồn tích hợp với các dịch vụ Azure.
    *   **Ví dụ:** `azure-keyvault-secrets` là một thư viện cho phép bạn đọc và ghi secret vào Key Vault từ mã Python.
*   **Thuật ngữ:** Micro-packages (so với Monolithic package)
    *   **Định nghĩa:** Kiến trúc SDK hiện tại của Azure được chia nhỏ thành các module riêng biệt cho từng dịch vụ (ví dụ: `azure-storage-blob`, `azure-keyvault-secrets`), thay vì một gói cài đặt duy nhất chứa tất cả (`azure`). Điều này giúp dự án nhẹ hơn và giảm dependencies không cần thiết.
    *   **Ví dụ:** Thay vì `pip install azure`, bây giờ bạn cần chạy `pip install azure-keyvault-secrets` để chỉ lấy đúng chức năng cần cho Key Vault.
