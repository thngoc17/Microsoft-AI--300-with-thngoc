---
source_url: https://gemini.google.com/app/be0e8c4dc2418ddb
conversation_date: 2026-08-06
context_week: N/A
conversation_types: [FIX_HA_TANG, TRANH_LUAN_QUYET_DINH, LAP_KE_HOACH]
ai300_domains: [Design and implement MLOps infrastructure, GenAIOps infrastructure]
technologies: [Docker, Docker Desktop, WSL 2, Windows, PowerShell, Diskpart, WSL CLI]
key_decision: "Phải di dời toàn bộ dữ liệu Docker (ext4.vhdx) khỏi ổ C sang ổ E, dù ổ E chỉ còn 16 GB, và thiết lập Resource Quota + Bind Mount để tránh tái phát sự cố hết dung lượng."
status: resolved
---

## Bối cảnh & Vấn đề

- Ổ C bị tiêu tốn 20 GB còn lại do Docker sử dụng WSL 2 backend với ổ đĩa ảo `ext4.vhdx` động (dynamically allocated) nhưng không tự thu nhỏ.
- Dung lượng còn lại của ổ C chỉ 32 GB và ổ E chỉ 16 GB – cả hai đều được đánh giá là “chết yếu” cho tác vụ AI/ML (base image CUDA + PyTorch có thể ngốn 5–8 GB).
- Sau khi dọn dẹp bằng `docker system prune`, Docker Engine vẫn báo lỗi `500 Internal Server Error` ở endpoint `\\.\pipe\dockerDesktopLinuxEngine/_ping` do Daemon bị treo.
- Khi cố gắng di dời dữ liệu sang ổ E, gặp lỗi `Wsl/Service/WSL_E_DISTRO_NOT_FOUND` vì distro `docker-desktop-data` đã bị unregister nhưng chưa được tạo lại.

## Quyết định cuối cùng & Lý do

**Quyết định kiến trúc:**  
- **Bắt buộc di dời** `docker-desktop-data` (file `ext4.vhdx`) khỏi ổ C sang ổ E, mặc dù ổ E chỉ có 16 GB.  
- **Lý do:** Ổ C là phân vùng hệ điều hành; nếu đầy sẽ gây treo toàn bộ hệ thống, làm hỏng Named Pipe và WSL IPC. Về nguyên tắc, không đặt dữ liệu có tính phình to (dynamically allocated) trên ổ C.  
- **Khuyến nghị bổ sung:** Phải giải phóng ít nhất 50–100 GB trên ổ E hoặc nâng cấp phần cứng, vì 16 GB là quá thấp.

**Phương án bị loại bỏ:**  
- **KHÔNG dùng ổ C** dù còn 32 GB vì khi đầy sẽ phá hỏng tiến trình Docker Daemon và toàn bộ hệ điều hành.  
- **KHÔNG dùng `COPY`** để đưa Dataset/Model Weights vào Dockerfile; thay vào đó dùng Bind Mount (`-v`) để tránh tạo layer khổng lồ.  
- **KHÔNG dùng base image full `devel`** nếu chỉ chạy inference; ưu tiên bản `runtime` hoặc `slim` để giảm kích thước.

## Lệnh và Cấu hình cụ thể đã dùng

### Dọn rác Docker cấp cứu (Giai đoạn 1)
```powershell
docker system prune -a --volumes -f
docker builder prune -a -f
```

### Compact ổ đĩa ảo ext4.vhdx (Giai đoạn 2)
```powershell
wsl --shutdown
diskpart
```
```diskpart
select vdisk file="C:\Users\YOUR_USERNAME\AppData\Local\Docker\wsl\data\ext4.vhdx"
attach vdisk readonly
compact vdisk
detach vdisk
exit
```

### Reset kết nối IPC và WSL (khi gặp lỗi 500)
```powershell
Get-Process *docker* -ErrorAction SilentlyContinue | Stop-Process -Force
wsl --shutdown
net stop com.docker.service
net start com.docker.service
```

### Kiểm tra và khởi động lại WSL distro
```powershell
wsl -l -v
wsl -d docker-desktop
# sau đó gõ exit để thoát
```

### Unregister và re-register distro (khi bị hỏng)
```powershell
wsl --shutdown
wsl --unregister docker-desktop
wsl --unregister docker-desktop-data
# Sau đó mở Docker Desktop để tự động tạo lại distro
```

### Di dời dữ liệu Docker sang ổ E (đúng quy trình)
```powershell
wsl --shutdown
wsl --export docker-desktop-data E:\DockerData\docker-desktop-data.tar
wsl --unregister docker-desktop-data
wsl --import docker-desktop-data E:\DockerData E:\DockerData\docker-desktop-data.tar --version 2
Remove-Item E:\DockerData\docker-desktop-data.tar
```

### Thiết lập Resource Quota cho WSL 2 (file `.wslconfig` trong `%USERPROFILE%`)
```ini
[wsl2]
memory=8GB
processors=4
swap=2GB
localhostForwarding=true
```
Sau khi tạo file, chạy `wsl --shutdown` để áp dụng.

## Lỗi gặp phải và Cách khắc phục

### Lỗi 1: `500 Internal Server Error` tại `\\.\pipe\dockerDesktopLinuxEngine/_ping`
- **Nguyên nhân:** Ổ C cạn kiệt dung lượng (0 Byte) làm hỏng Docker Daemon hoặc treo các tiến trình Socket/IPC giữa Windows và WSL.
- **Cách khắc phục:**  
  1. Force kill toàn bộ process Docker: `Get-Process *docker* | Stop-Process -Force`  
  2. Shutdown WSL: `wsl --shutdown`  
  3. Restart Windows Service: `net stop com.docker.service` và `net start com.docker.service`  
  4. Nếu vẫn lỗi, kiểm tra WSL distro (`wsl -l -v`) và unregister/re-register nếu cần.

### Lỗi 2: `Wsl/Service/WSL_E_DISTRO_NOT_FOUND`
- **Nguyên nhân:** Distro `docker-desktop-data` (hoặc `docker-desktop`) đã bị `wsl --unregister` nhưng chưa được tạo lại, trong khi Docker Desktop vẫn cố truy cập.
- **Cách khắc phục:**  
  1. Mở Docker Desktop, ứng dụng sẽ tự động phát hiện thiếu distro và khởi tạo lại (`Initializing...`).  
  2. Sau khi ổn định, thực hiện lại quy trình di dời (xuất → unregister → import → xóa tar) theo đúng thứ tự.

### Lỗi 3: Ổ đĩa ảo `ext4.vhdx` không thu nhỏ sau khi prune
- **Nguyên nhân:** WSL 2 sử dụng ổ đĩa động, không tự động compact.
- **Cách khắc phục:** Dùng `diskpart` với `compact vdisk` sau khi tắt WSL và gắn ở chế độ readonly.

## Lộ trình chi tiết (Tái cấu trúc dài hạn)

1. **Dọn dẹp tức thời**  
   - Chạy `docker system prune -a --volumes -f` và `docker builder prune -a -f`.  
   - Compact ổ đĩa ảo bằng `diskpart` (như mục 3.2).  

2. **Di dời dữ liệu sang ổ E**  
   - Tạo thư mục `E:\DockerData`.  
   - Thực hiện `wsl --export`, `--unregister`, `--import` theo mục 3.6.  

3. **Thiết lập Resource Quota**  
   - Tạo file `%USERPROFILE%\.wslconfig` với cấu hình RAM/CPU/Swap (mục 3.7).  
   - Restart WSL bằng `wsl --shutdown`.  

4. **Thay đổi thói quen sử dụng Docker cho AI/ML**  
   - **Không COPY** Dataset/Weights vào image; dùng Bind Mount:  
     ```bash
     docker run -v E:\MyProjects\AI_weights:/app/weights my-ai-image
     ```  
   - **Chọn base image nhẹ hơn**, ví dụ: `nvidia/cuda:11.8.0-runtime-ubuntu22.04` thay vì `devel`.  

## Khái niệm & Định nghĩa

- **`ext4.vhdx`**  
  - **Định nghĩa:** File ổ đĩa ảo của WSL 2, chứa hệ thống tệp của distro Linux, được cấp phát động (dynamically expanding).  
  - **Ví dụ:** Docker Desktop lưu toàn bộ image, container, volume vào `C:\Users\<user>\AppData\Local\Docker\wsl\data\ext4.vhdx`.  
  - **Hậu quả:** Khi dung lượng thực tế bên trong tăng, file này phình to, nhưng sau khi xóa dữ liệu bên trong, nó không tự thu nhỏ, cần `compact vdisk`.

- **Named Pipe `\\.\pipe\dockerDesktopLinuxEngine`**  
  - **Định nghĩa:** Cơ chế IPC giữa Docker CLI trên Windows và Docker Daemon chạy bên trong WSL 2.  
  - **Ví dụ:** Lệnh `docker ps` gửi request qua pipe này. Nếu pipe bị treo (do ổ đĩa đầy), CLI nhận lỗi 500.  
  - **Khắc phục:** Restart toàn bộ Docker service và WSL để tái tạo pipe.

## Các phương án đã cân nhắc

| Phương án | Ưu điểm | Nhược điểm | Được chọn? |
|---|---|---|---|
| Để Docker data ở ổ C (mặc định) | Dễ dàng, không cần di dời | Ổ C là phân vùng hệ điều hành, khi đầy sẽ treo hệ thống, đã gây ra lỗi 500 và mất kết nối pipe. | **KHÔNG** (loại bỏ) |
| Di dời sang ổ E (ngay cả khi chỉ còn 16 GB) | Tách biệt dữ liệu Docker khỏi ổ C, đúng nguyên tắc kiến trúc; tránh sụp đổ hệ điều hành. | Dung lượng 16 GB quá nhỏ, phải nâng cấp hoặc dọn dẹp thêm (cần 50-100 GB). | **CÓ** (bắt buộc) |
| Sử dụng ổ đĩa ngoài (USB/SSD) | Có thể có dung lượng lớn, di động. | Không được đề cập trực tiếp, nhưng ngụ ý là một lựa chọn nếu không giải phóng được ổ E. | Không thảo luận chi tiết |