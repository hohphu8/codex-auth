# codex-auth

**Đổi nhanh giữa nhiều tài khoản Codex CLI trên Windows và WSL, không phải đăng nhập lại mỗi lần.**

[English](README.en.md) · [Danh sách lệnh](docs/commands.md)

`codex-auth` lưu mỗi lần đăng nhập thành một profile riêng. Lệnh `use` hoặc `next` chọn profile cho lần chạy `codex` tiếp theo. Windows và WSL dùng chung kho thông tin đăng nhập trên ổ Windows, còn mỗi hệ điều hành giữ cấu hình và lịch sử phiên của mình.

## Tính năng

- Lưu và chuyển giữa nhiều tài khoản ChatGPT dùng cho Codex CLI.
- Dùng lại profile đã đăng nhập trên Windows từ WSL, hoặc ngược lại.
- Giữ lịch sử `/resume` chung giữa các account **trong cùng một hệ điều hành**.
- `sessions` và `resume-all` tìm phiên qua các account, kể cả khi `/resume` chỉ hiện phiên của account hiện tại.
- `run` / `next-run` đổi account và mở Codex bằng một lệnh.
- `status`, `verify` và `doctor` giúp kiểm tra account thực tế mà CLI đọc.
- Không chuyển file SQLite, WAL, cấu hình hoặc session giữa Windows và WSL.

## Cài trên máy mới

### 1. Cài Codex CLI

Trên **Windows PowerShell**, cài Git, Node.js và Codex CLI theo [hướng dẫn chính thức](https://learn.chatgpt.com/docs/cli):

```powershell
winget install OpenJS.NodeJS.LTS
winget install Git.Git
# Mở PowerShell mới sau khi cài Node.js và Git
npm.cmd install -g @openai/codex
codex --version
```

Nếu máy chưa có WSL, chạy `wsl --install` trong PowerShell với quyền quản trị và hoàn tất bước khởi động lại/khởi tạo Ubuntu. Sau đó, **trong terminal WSL**, cài bản Codex Linux riêng theo [hướng dẫn WSL](https://learn.chatgpt.com/docs/windows/wsl). Đừng dùng `codex` nằm dưới `/mnt/c/Program Files/nodejs`:

```bash
sudo apt update
sudo apt install -y python3 git
curl -fsSL https://chatgpt.com/codex/install.sh | sh
codex --version
```

Nếu chỉ dùng Windows, bỏ qua phần WSL bên dưới.

### 2. Cài codex-auth trên Windows

```powershell
git clone https://github.com/hohphu8/codex-auth.git
cd codex-auth
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

Script chép bốn file Windows vào `%USERPROFILE%\.codex\bin` và thêm thư mục này vào User PATH. **Mở PowerShell mới**, rồi kiểm tra:

```powershell
codex-auth help
codex-auth doctor
```

Nếu muốn tự quản lý PATH, chạy `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -NoPath` và thêm `%USERPROFILE%\.codex\bin` thủ công.

### 3. Cài codex-auth trong WSL (tùy chọn)

Mở terminal **WSL**, rồi chạy:

```bash
git clone https://github.com/hohphu8/codex-auth.git
cd codex-auth
bash ./install-wsl.sh
```

Script cài `~/.local/bin/codex-auth` và thêm `~/.local/bin` vào PATH của Bash hoặc Zsh nếu cần. Mở shell mới, rồi kiểm tra:

```bash
codex-auth status
codex-auth list
```

WSL tự tìm Windows home qua `cmd.exe` và `wslpath`. Nếu WSL interop bị tắt hoặc máy có nhiều Windows user, đặt đường dẫn thủ công trong shell WSL:

```bash
export CODEX_AUTH_SHARED_HOME=/mnt/c/Users/<windows-user>/.codex
codex-auth status
```

Lưu dòng `export` vào `~/.bashrc` hoặc `~/.zshrc` nếu cần dùng thường xuyên. Có thể cài WSL trước Windows; kho profile sẽ được tạo khi login lần đầu.

## Bắt đầu dùng

Trên Windows, lệnh `login` mở một cửa sổ terminal cho từng account. Hoàn tất đăng nhập trong cửa sổ đó và để script lưu profile:

```powershell
codex-auth login account1@example.com
codex-auth login account2@example.com
codex-auth list
codex-auth use 1
codex
```

Trên WSL, account đã lưu trên Windows xuất hiện qua `list` mà **không cần đăng nhập thêm**:

```bash
codex-auth list
codex-auth use 2
codex-auth verify
codex
```

Cũng có thể `codex-auth login account3@example.com` trong WSL; profile mới sẽ xuất hiện trên Windows. Mỗi hệ điều hành chọn account đang hoạt động riêng bằng `use` hoặc `next`. Hãy thoát phiên Codex đang mở trước khi chuyển account, rồi chạy `codex` mới.

Nếu đã login bằng `codex` thường trước khi cài công cụ:

```powershell
# Windows: nhập đúng email của account đang active
codex-auth sync-active account1@example.com
```

```bash
# WSL: tự đọc email từ auth.json hiện có
codex-auth sync
```

## Các lệnh hay dùng

```text
codex-auth list                 Liệt kê profile, số thứ tự và account đang chọn
codex-auth use 2                Chọn account số 2
codex-auth next                 Chọn account kế tiếp
codex-auth run 2                Chọn account 2 rồi mở Codex
codex-auth next-run             Chuyển account rồi mở Codex
codex-auth status               Xem account đang chọn
codex-auth verify               Hỏi Codex CLI account thực tế đã tải
codex-auth sessions             Liệt kê phiên trong thư mục hiện tại
codex-auth sessions --all       Liệt kê mọi phiên trên hệ điều hành hiện tại
codex-auth resume-all           Chọn phiên từ danh sách của thư mục hiện tại
codex-auth resume-all --all     Chọn phiên từ mọi thư mục
```

Trên Windows còn có `doctor`, `run-isolated`, `remove` và `clean`. Xem [danh sách lệnh](docs/commands.md) để biết cú pháp và khác biệt giữa Windows/WSL.

## Cách đồng bộ hoạt động

```text
Windows: %USERPROFILE%\.codex\auth-profiles\  <-- thông tin đăng nhập -->  WSL: /mnt/c/Users/.../.codex/auth-profiles/
Windows: %USERPROFILE%\.codex\sessions\       (lịch sử riêng)            WSL: ~/.codex/sessions/
Windows: %USERPROFILE%\.codex\auth.json        (account active riêng)     WSL: ~/.codex/auth.json
```

`codex-auth` chỉ trao đổi thông tin đăng nhập đã lưu. Khi Codex làm mới token, Windows lưu lại lúc chuyển account/chạy qua công cụ; WSL lưu lại khi chạy `sync`, chuyển account, hoặc thoát khỏi `run`/`next-run`/`resume-all`. Nếu dùng `codex` thường trong WSL lâu ngày, chạy `codex-auth sync` trước khi dùng account đó ở Windows.

`/resume` và `resume-all` đọc session của **hệ điều hành đang chạy**. Chúng gom session giữa các account trong cùng Windows hoặc cùng WSL, không gộp session Windows với WSL. Project trên `/mnt/c` có thể chậm hơn project trong `/home` khi Codex chạy ở WSL; xem [hướng dẫn WSL](https://learn.chatgpt.com/docs/windows/wsl).

## Lỗi thường gặp

| Hiện tượng | Cách xử lý |
| --- | --- |
| `codex-auth` không được nhận diện sau khi cài | Mở terminal mới; kiểm tra `%USERPROFILE%\.codex\bin` (Windows) hoặc `~/.local/bin` (WSL) có trên PATH. |
| `codex-auth use` xong nhưng account vẫn cũ | Thoát Codex đang mở, chạy `codex-auth verify`, kiểm tra `CODEX_HOME` không trỏ sang home khác. |
| WSL dùng nhầm Codex Windows | Chạy `type -a codex`; bản Linux phải đứng trước đường dẫn `/mnt/c/...`. Cài Codex Linux theo phần trên. |
| WSL không tìm thấy kho Windows | Đặt `CODEX_AUTH_SHARED_HOME=/mnt/c/Users/<windows-user>/.codex`. |
| `resume-all` không thấy phiên | Chạy `codex-auth sessions --all`; lệnh mặc định chỉ hiện phiên của thư mục hiện tại. |
| Title tiếng Việt bị lỗi dấu trên Windows | Cập nhật repo và chạy lại `install.ps1`; helper truyền JSON ASCII để PowerShell 5.1 đọc đúng Unicode. |

## Bảo mật và giới hạn

`auth.json` và `auth-profiles/` chứa token đăng nhập. **Không commit, gửi công khai, hay chia sẻ chúng.** `.gitignore` của repo loại các file đó. Chỉ dùng với các account bạn có quyền sử dụng và tuân thủ giới hạn của tổ chức/OpenAI.

`codex logout` có thể làm token của account không còn dùng được ở cả hai bên. Công cụ này lưu profile để chuyển nhanh, không cung cấp đăng xuất đồng bộ. `codex-auth remove` trên Windows xóa profile đã lưu; hãy kiểm tra account đang mở ở cả Windows và WSL trước khi xóa.

## Kiểm tra mã nguồn

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\codex-auth.test.ps1
node --check .\windows\codex-auth.probe.mjs
node --check .\windows\codex-auth.sessions.mjs
```

```bash
python3 linux/codex-auth-linux.test.py
python3 -m py_compile linux/codex-auth-linux.py
```

Các bài test dùng account và Codex CLI giả, không cần token thật. Xem [mã nguồn Windows](windows/codex-auth.ps1) và [mã nguồn WSL](linux/codex-auth-linux.py).
