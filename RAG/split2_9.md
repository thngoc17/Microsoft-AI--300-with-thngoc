---
source_url: https://gemini.google.com/app/2e21af0a4293cbe2
conversation_date: N/A
context_week: N/A
conversation_types: [FIX_HA_TANG, LY_THUYET]
ai300_domains: [Không áp dụng]
technologies: [Docker Desktop, WSL, Windows PowerShell, LxssManager]
key_decision: "Để khắc phục lỗi Docker Engine không khởi động được trong WSL khi lệnh wsl --shutdown thông thường không hiệu quả, cần phải tắt các tiến trình watchdog của Docker bằng lệnh Stop-Process và Stop-Service, đồng thời khởi động lại service LxssManager để phá vỡ deadlock cấp độ kernel."
status: open_question
---

## Bối cảnh & Vấn đề
Người dùng báo cáo rằng Docker Desktop đang bị lỗi. Cụ thể, máy ảo WSL vẫn chạy nhưng **engine docker không khởi động được**. Trợ lý đã chỉ ra một sai lầm trong tư duy chẩn đoán ban đầu: người dùng đã nhầm lẫn rằng việc một distro WSL cá nhân (như Ubuntu) hoạt động tốt đồng nghĩa với việc Docker Engine cũng có thể khởi động. Trên thực tế, Docker Desktop quản lý hai distros ẩn riêng biệt là `docker-desktop` và `docker-desktop-data`; việc hai distros này bị treo, hỏng dữ liệu, hoặc bị kẹt file lock là nguyên nhân chính.

## Quyết định cuối cùng & Lý do
**Quy trình xử lý lỗi được đề xuất** (từ mức độ can thiệp nhẹ đến dọn dẹp hệ thống) và đã được người dùng bắt đầu thực hiện:

1.  **Triệt tiêu trạng thái treo (Zombie State)**: Sử dụng lệnh `wsl --shutdown` để ép buộc tắt toàn bộ hệ thống WSL. Mục đích là giải phóng mọi file lock.
2.  **Khắc phục lỗi cấu hình**: Kiểm tra và xóa/đổi tên các file cấu hình `settings.json` và `daemon.json` bị hỏng hoặc có lỗi cú pháp để Docker khởi động với cấu hình mặc định.
3.  **Phân tích Log cốt lõi**: Nếu hai bước trên thất bại, cần đọc file log `dockerd.log` trong thư mục `%LOCALAPPDATA%\Docker\log\vm` để tìm nguyên nhân chính xác (ví dụ: lỗi không gian đĩa, lỗi mạng).
4.  **Tải thiết lập Backend**: Nếu file ảo hóa bị hỏng, thực hiện hành động phá hủy bằng lệnh `wsl --unregister` để xóa hai distros của Docker và để Docker Desktop tự cài lại (sẽ mất toàn bộ dữ liệu hiện có).

**Quyết định quan trọng trong tình huống cụ thể (Sau Bước 1)**:
Khi người dùng thực hiện Bước 1 và nhận được kết quả là `Ubuntu` đã `Stopped` nhưng `docker-desktop` vẫn `Running`, trợ lý đã kết luận cách tiếp cận `wsl --shutdown` thông thường là không đủ. Lý do là tiến trình watchdog của Docker (như `com.docker.service`) đã tự động kích hoạt lại `docker-desktop` ngay sau khi bị tắt. Do đó, cần phải **triệt tiêu tiến trình từ cấp độ Windows Services** để cắt đứt vòng lặp này. Điều này được thực hiện bằng cách:
- Dừng các tiến trình `Docker Desktop`, `com.docker.backend`.
- Dừng service `com.docker.service`.
- Khởi động lại service `LxssManager` để phá vỡ mọi deadlock.

**Phương án bị loại bỏ**:
- **KHÔNG dùng** lệnh `wsl --shutdown` đơn thuần để sửa lỗi khi `docker-desktop` vẫn hiển thị `Running` sau lệnh này. Nguyên nhân là do nó không thể ngắt các tiến trình watchdog của Docker đang chạy ở cấp độ Windows.

## Lệnh và Cấu hình cụ thể đã dùng
**Nhóm lệnh khắc phục lỗi WSL cơ bản (Bước 1)**:
```powershell
wsl --shutdown
wsl -l -v
```

**Nhóm lệnh khắc phục lỗi cấu hình (Bước 2)**:
```powershell
# Đường dẫn tới file settings.json
%APPDATA%\Docker
# Đường dẫn tới file daemon.json
%USERPROFILE%\.docker
```

**Nhóm lệnh xử lý Watchdog và LxssManager (được yêu cầu thực hiện khi lệnh tắt thông thường thất bại)**:
```powershell
Stop-Process -Name "Docker Desktop" -Force -ErrorAction SilentlyContinue
Stop-Process -Name "com.docker.backend" -Force -ErrorAction SilentlyContinue
Stop-Service -Name com.docker.service -Force -ErrorAction SilentlyContinue

Restart-Service -Name LxssManager -Force

wsl --shutdown
wsl -l -v
```

**Nhóm lệnh tái thiết lập Backend (Bước 4)**:
```powershell
wsl --unregister docker-desktop
wsl --unregister docker-desktop-data
```

## Lỗi gặp phải và Cách khắc phục
**Lỗi 1: Tư duy chẩn đoán sai**:
- **Mô tả**: Giả định rằng việc distro WSL cá nhân (Ubuntu) đang chạy thì Docker Engine cũng có thể khởi động được.
- **Cách khắc phục**: Nhận thức rõ rằng Docker Desktop quản lý hai distros ẩn là `docker-desktop` và `docker-desktop-data`, hoàn toàn độc lập với các distro khác.

**Lỗi 2: WSL shutdown không ngắt được tiến trình docker-desktop (Zombie State / Deadlock)**:
- **Mô tả**: Sau khi thực thi `wsl --shutdown`, lệnh `wsl -l -v` vẫn hiển thị `docker-desktop` ở trạng thái `Running`. Điều này xảy ra do:
    1.  **Watchdog Process**: Tiến trình nền của Docker trên Windows (ví dụ: `com.docker.service`) tự động kích hoạt lại distro.
    2.  **Kernel Deadlock**: Service `LxssManager` bị deadlock hoặc từ chối quyền truy cập khi cố gắng ngắt tiến trình VHDX của Docker.
- **Cách khắc phục**:
    1.  Triệt tiêu các tiến trình watchdog của Docker bằng lệnh `Stop-Process` và `Stop-Service`.
    2.  Ép buộc khởi động lại `LxssManager` bằng `Restart-Service`.
    3.  Nếu lệnh `Restart-Service` bị treo, lựa chọn duy nhất là khởi động lại toàn bộ máy tính Windows.

## Khái niệm & Định nghĩa
- **Watchdog Process**: Một tiến trình nền (ví dụ: `com.docker.service`) có chức năng giám sát và tự động khởi động lại các dịch vụ chính. Trong ngữ cảnh này, nó phát hiện trạng thái của distro `docker-desktop` bị tắt và ngay lập tức kích hoạt nó chạy lại, gây cản trở cho việc tắt hệ thống WSL bằng lệnh thông thường.
- **Kernel Deadlock**: Trạng thái mà một tiến trình hoặc service (ở đây là `LxssManager`) bị kẹt vô hạn khi chờ đợi một tài nguyên (như quyền truy cập vào file VHDX của Docker) không bao giờ được giải phóng, dẫn đến việc nó không thể xử lý các lệnh khác (ví dụ: tắt WSL).