# Ter

Thanh tìm kiếm kiểu Spotlight và Dock kiểu macOS cho Windows. Viết bằng Zig, gọi thẳng Win32, không runtime, không phụ thuộc. Chỉ một file `.exe` khoảng 370 KB.

## Tải về

Tải **`ter-setup.exe`** ở trang [Releases](https://github.com/nguyentrantin98/ter/releases/latest) rồi chạy.

- Cài riêng cho tài khoản đang dùng, không cần quyền admin.
- Tự chạy cùng Windows. Có thể tắt ở icon khay → *Chạy cùng Windows*.
- Gỡ trong **Settings → Apps → Installed apps → Ter**.

> Bộ cài chưa được ký số nên Windows SmartScreen có thể cảnh báo. Bấm *More info → Run anyway*.

## Tính năng

### Thanh tìm kiếm (Alt+Space)

- **App**: tìm ứng dụng trong Start Menu và Microsoft Store. Gõ tiếng Việt có dấu hay không dấu đều được.
- **File**: tìm file và thư mục trên mọi ổ đĩa, nhờ một chỉ mục giữ trong bộ nhớ.
- **CMD / PS**: chạy lệnh CMD hoặc PowerShell, kết quả hiện ngay trong thanh.
- `Tab` để đổi chế độ, `Enter` để mở, `Ctrl+Enter` để chạy với quyền admin, `Shift+Enter` để mở vị trí file.
- Có thể ghim thanh trên desktop và kéo đi chỗ khác. Vị trí được nhớ lại.

### Dock

Dock thay thế taskbar Windows. Bật/tắt ở icon khay → *Dock*. Khi tắt, taskbar trở lại nguyên trạng.

- Thanh kính mờ, icon phóng to khi rê chuột, dấu chấm cho biết app đang chạy (mỗi chấm là một cửa sổ).
- **Rê chuột vào app** để xem trực tiếp các cửa sổ đang mở của nó. Bấm vào một ô để mở cửa sổ đó, bấm ✕ (hoặc chuột giữa) để đóng.
- **App chạy nền** (khay hệ thống: Zalo, OneDrive, âm lượng…) nằm ngay trong Dock. Click trái, phải và đúp hoạt động như trên taskbar.
- **Tự ẩn khi có app full-screen**: video, game, trình duyệt bấm F11.
- Đưa chuột chạm mép dưới màn hình để hiện tạm taskbar Windows (đồng hồ, thông báo).
- Click phải vào icon để mở menu: giữ trong Dock, đóng cửa sổ, mở cửa sổ mới.

## Tự cập nhật

Bản đã cài sẽ kiểm tra [Releases](https://github.com/nguyentrantin98/ter/releases) khoảng 1,5 phút sau khi khởi động, sau đó cứ 6 giờ một lần.

Khi có bản mới, Ter tự tải bộ cài và cài đè lặng lẽ, rồi hiện thông báo nhỏ *"Ter đã được cập nhật"*. Muốn kiểm tra ngay, chọn icon khay → **Kiểm tra cập nhật**.

## Tự build

Cần [Zig 0.17](https://ziglang.org/download/).

```sh
zig build -Doptimize=ReleaseFast
```

Kết quả nằm ở `zig-out/bin/`:

- `ter.exe` là chương trình.
- `ter-setup.exe` là bộ cài một file, đã chứa sẵn `ter.exe` bên trong.

### Phát hành bản mới

1. Tăng `VERSION` trong `src/util.zig`, ví dụ `1.2.0`.
2. Build bằng lệnh `zig build -Doptimize=ReleaseFast`.
3. Tạo release có tag `v` + phiên bản, đính kèm file bộ cài:

   ```sh
   gh release create v1.2.0 zig-out/bin/ter-setup.exe --title "Ter 1.2.0" --notes "..."
   ```

Các máy đã cài sẽ tự nhận bản mới. Tên file đính kèm phải đúng là `ter-setup.exe`.

## Cấu trúc mã

| File | Nội dung |
|---|---|
| `src/main.zig` | Thanh tìm kiếm, icon khay, cài đặt |
| `src/dock.zig` | Dock: vẽ, phóng to, preview cửa sổ, khay hệ thống, ẩn khi full-screen |
| `src/apps.zig` | Danh sách ứng dụng (Start Menu + Store) |
| `src/files.zig` | Chỉ mục file |
| `src/term.zig` | Chạy lệnh CMD / PowerShell |
| `src/update.zig` | Tự cập nhật từ GitHub Releases |
| `src/setup.zig` | Bộ cài |
| `src/w.zig`, `src/util.zig` | Khai báo Win32 và tiện ích |

## Giấy phép

[MIT](LICENSE): được tự do dùng, sửa, phân phối lại, kể cả cho mục đích thương mại, miễn là giữ lại thông báo bản quyền.
