//! ter-setup.exe — one-file installer. Carries ter.exe inside itself and installs it for the
//! current user only (no admin): program folder, Start Menu shortcut, "Installed apps" entry,
//! start with Windows. `--silent` skips the dialogs. Undo with `ter.exe --uninstall`.
const w = @import("w.zig");
const u = @import("util.zig");
const L = u.L;

const payload = @embedFile("ter_exe");
const VERSION = L("1.0.0");

fn hasArg(needle: []const u16) bool {
    const cl = u.sliceZ(w.GetCommandLineW());
    var i: usize = 0;
    while (i + needle.len <= cl.len) : (i += 1) {
        if (u.eqlCI(cl[i..][0..needle.len], needle)) return true;
    }
    return false;
}

fn fail(silent: bool, msg: w.WSTR) void {
    if (!silent) _ = w.MessageBoxW(null, msg, L("Cài đặt Ter"), 0x10);
    w.ExitProcess(1);
}

/// The running copy keeps ter.exe locked for a moment after it is told to close, so retry.
fn writePayload(path: w.WSTR) bool {
    var tries: u32 = 0;
    while (tries < 50) : (tries += 1) {
        const f = w.CreateFileW(path, 0x40000000, 0, null, 2, 0x80, null); // GENERIC_WRITE, CREATE_ALWAYS
        if (f == w.INVALID) {
            w.Sleep(100);
            continue;
        }
        defer _ = w.CloseHandle(f);
        var done: usize = 0;
        while (done < payload.len) {
            var n: u32 = 0;
            const chunk: u32 = @intCast(@min(payload.len - done, 1 << 20));
            if (w.WriteFile(f, payload.ptr + done, chunk, &n, null) == 0 or n == 0) return false;
            done += n;
        }
        return true;
    }
    return false;
}

// ---- Start Menu shortcut through the shell's ShellLink COM object

const CLSID_ShellLink = w.GUID{ .a = 0x00021401, .b = 0, .c = 0, .d = .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 } };
const IID_IShellLinkW = w.GUID{ .a = 0x000214F9, .b = 0, .c = 0, .d = .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 } };
const IID_IPersistFile = w.GUID{ .a = 0x0000010B, .b = 0, .c = 0, .d = .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 } };

/// Method `idx` of a COM object's vtable, cast to its signature.
fn method(obj: *anyopaque, idx: usize, comptime F: type) F {
    const vt: *const [*]const *const anyopaque = @ptrCast(@alignCast(obj));
    return @ptrCast(@alignCast(vt.*[idx]));
}

const FnStr = *const fn (*anyopaque, w.WSTR) callconv(.winapi) i32;
const FnQuery = *const fn (*anyopaque, *const w.GUID, *?*anyopaque) callconv(.winapi) i32;
const FnSave = *const fn (*anyopaque, w.WSTR, w.BOOL) callconv(.winapi) i32;
const FnRelease = *const fn (*anyopaque) callconv(.winapi) u32;

fn createShortcut(lnk: w.WSTR, target: w.WSTR, dir: w.WSTR) bool {
    var raw: ?*anyopaque = null;
    if (w.CoCreateInstance(&CLSID_ShellLink, null, 1, &IID_IShellLinkW, &raw) != 0) return false;
    const link = raw orelse return false;
    defer _ = method(link, 2, FnRelease)(link);
    _ = method(link, 20, FnStr)(link, target); // SetPath
    _ = method(link, 9, FnStr)(link, dir); // SetWorkingDirectory
    _ = method(link, 7, FnStr)(link, L("Tìm app, tìm file, chạy lệnh")); // SetDescription

    var raw_file: ?*anyopaque = null;
    if (method(link, 0, FnQuery)(link, &IID_IPersistFile, &raw_file) != 0) return false;
    const file = raw_file orelse return false;
    defer _ = method(file, 2, FnRelease)(file);
    return method(file, 6, FnSave)(file, lnk, 1) == 0; // Save
}

pub fn main() void {
    @setEvalBranchQuota(100_000); // the long dialog texts are converted to UTF-16 at compile time
    const silent = hasArg(L("--silent"));
    const intro = L("Cài Ter vào máy này?\n\n" ++
        "•  Alt+Space để gọi thanh tìm kiếm\n" ++
        "•  Tự chạy cùng Windows (tắt được ở icon khay hệ thống)\n" ++
        "•  Cài cho riêng tài khoản này, không cần quyền admin");
    if (!silent and w.MessageBoxW(null, intro, L("Cài đặt Ter"), 0x1 | 0x40) != 1) return;

    _ = w.CoInitializeEx(null, 2);

    // Close a running copy so its file can be replaced.
    const running = w.FindWindowW(u.WINDOW_CLASS, null);
    if (running != null) _ = w.PostMessageW(running, 0x0010, 0, 0); // WM_CLOSE

    var env: [300]u16 = undefined;
    var b1: [700]u16 = undefined;
    var b2: [700]u16 = undefined;
    var b3: [700]u16 = undefined;
    var b4: [700]u16 = undefined;

    const local = u.envVar(L("LOCALAPPDATA"), &env);
    if (local.len == 0) fail(silent, L("Không tìm thấy thư mục LOCALAPPDATA."));
    _ = w.CreateDirectoryW(u.join(&b1, &.{ local, L("\\Programs") }), null);
    const dir = u.join(&b1, &.{ local, L("\\Programs\\Ter") });
    _ = w.CreateDirectoryW(dir, null);
    const exe = u.join(&b2, &.{ dir, L("\\ter.exe") });
    if (!writePayload(exe)) fail(silent, L("Không ghi được ter.exe. Hãy thoát Ter (icon khay → Thoát) rồi chạy lại bộ cài."));

    var env2: [300]u16 = undefined;
    const lnk = u.join(&b3, &.{ u.envVar(L("APPDATA"), &env2), u.START_MENU_LNK });
    _ = createShortcut(lnk, exe, dir);

    // "Installed apps" entry
    const K = u.UNINSTALL_KEY;
    u.regSetStr(K, L("DisplayName"), L("Ter"));
    u.regSetStr(K, L("DisplayVersion"), VERSION);
    u.regSetStr(K, L("Publisher"), L("Ter"));
    u.regSetStr(K, L("DisplayIcon"), exe);
    u.regSetStr(K, L("InstallLocation"), dir);
    u.regSetStr(K, L("UninstallString"), u.join(&b4, &.{ L("\""), exe, L("\" --uninstall") }));
    u.regSetStr(K, L("QuietUninstallString"), u.join(&b4, &.{ L("\""), exe, L("\" --uninstall --silent") }));
    u.regSetDword(K, L("NoModify"), 1);
    u.regSetDword(K, L("NoRepair"), 1);
    u.regSetDword(K, L("EstimatedSize"), @intCast(payload.len / 1024));

    // start with Windows
    u.regSetStr(u.RUN_KEY, L("Ter"), u.join(&b4, &.{ L("\""), exe, L("\" --hidden") }));

    if (!silent) _ = w.MessageBoxW(null, L("Đã cài xong.\n\nBấm Alt+Space để mở Ter bất cứ lúc nào."), L("Cài đặt Ter"), 0x40);
    _ = u.shell(null, exe, null, dir);
}
