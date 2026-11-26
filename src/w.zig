//! Minimal Win32 bindings used by Ter.

pub const H = ?*anyopaque;
pub const BOOL = i32;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const WSTR = [*:0]const u16;
pub const WNDPROC = *const fn (H, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
pub const THREADPROC = *const fn (?*anyopaque) callconv(.winapi) u32;

pub const INVALID: H = @ptrFromInt(~@as(usize, 0));

pub const POINT = extern struct { x: i32 = 0, y: i32 = 0 };
pub const SIZE = extern struct { cx: i32 = 0, cy: i32 = 0 };
pub const RECT = extern struct { left: i32 = 0, top: i32 = 0, right: i32 = 0, bottom: i32 = 0 };
pub const GUID = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };
pub const SRWLOCK = extern struct { p: ?*anyopaque = null };

pub const WNDCLASSEXW = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXW),
    style: u32 = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: H = null,
    hIcon: H = null,
    hCursor: H = null,
    hbrBackground: H = null,
    lpszMenuName: ?WSTR = null,
    lpszClassName: WSTR,
    hIconSm: H = null,
};

pub const MSG = extern struct {
    hwnd: H = null,
    message: u32 = 0,
    wParam: WPARAM = 0,
    lParam: LPARAM = 0,
    time: u32 = 0,
    pt: POINT = .{},
    lPrivate: u32 = 0,
};

pub const PAINTSTRUCT = extern struct {
    hdc: H = null,
    fErase: BOOL = 0,
    rcPaint: RECT = .{},
    fRestore: BOOL = 0,
    fIncUpdate: BOOL = 0,
    rgbReserved: [32]u8 = @splat(0),
};

pub const MONITORINFO = extern struct {
    cbSize: u32 = @sizeOf(MONITORINFO),
    rcMonitor: RECT = .{},
    rcWork: RECT = .{},
    dwFlags: u32 = 0,
};

pub const WIN32_FIND_DATAW = extern struct {
    dwFileAttributes: u32,
    ftCreationTime: [2]u32,
    ftLastAccessTime: [2]u32,
    ftLastWriteTime: [2]u32,
    nFileSizeHigh: u32,
    nFileSizeLow: u32,
    dwReserved0: u32,
    dwReserved1: u32,
    cFileName: [260]u16,
    cAlternateFileName: [14]u16,
};

pub const SECURITY_ATTRIBUTES = extern struct {
    nLength: u32 = @sizeOf(SECURITY_ATTRIBUTES),
    lpSecurityDescriptor: ?*anyopaque = null,
    bInheritHandle: BOOL = 0,
};

pub const STARTUPINFOW = extern struct {
    cb: u32 = @sizeOf(STARTUPINFOW),
    lpReserved: ?*anyopaque = null,
    lpDesktop: ?*anyopaque = null,
    lpTitle: ?*anyopaque = null,
    dwX: u32 = 0,
    dwY: u32 = 0,
    dwXSize: u32 = 0,
    dwYSize: u32 = 0,
    dwXCountChars: u32 = 0,
    dwYCountChars: u32 = 0,
    dwFillAttribute: u32 = 0,
    dwFlags: u32 = 0,
    wShowWindow: u16 = 0,
    cbReserved2: u16 = 0,
    lpReserved2: ?*anyopaque = null,
    hStdInput: H = null,
    hStdOutput: H = null,
    hStdError: H = null,
};

pub const PROCESS_INFORMATION = extern struct {
    hProcess: H = null,
    hThread: H = null,
    dwProcessId: u32 = 0,
    dwThreadId: u32 = 0,
};

pub const SHELLEXECUTEINFOW = extern struct {
    cbSize: u32 = @sizeOf(SHELLEXECUTEINFOW),
    fMask: u32 = 0,
    hwnd: H = null,
    lpVerb: ?WSTR = null,
    lpFile: ?WSTR = null,
    lpParameters: ?WSTR = null,
    lpDirectory: ?WSTR = null,
    nShow: i32 = 1,
    hInstApp: H = null,
    lpIDList: ?*anyopaque = null,
    lpClass: ?WSTR = null,
    hkeyClass: H = null,
    dwHotKey: u32 = 0,
    hIcon: H = null,
    hProcess: H = null,
};

pub const NOTIFYICONDATAW = extern struct {
    cbSize: u32 = @sizeOf(NOTIFYICONDATAW),
    hWnd: H = null,
    uID: u32 = 0,
    uFlags: u32 = 0,
    uCallbackMessage: u32 = 0,
    hIcon: H = null,
    szTip: [128]u16 = @splat(0),
    dwState: u32 = 0,
    dwStateMask: u32 = 0,
    szInfo: [256]u16 = @splat(0),
    uVersion: u32 = 0,
    szInfoTitle: [64]u16 = @splat(0),
    dwInfoFlags: u32 = 0,
    guidItem: GUID = .{ .a = 0, .b = 0, .c = 0, .d = @splat(0) },
    hBalloonIcon: H = null,
};

pub const SHFILEINFOW = extern struct {
    hIcon: H = null,
    iIcon: i32 = 0,
    dwAttributes: u32 = 0,
    szDisplayName: [260]u16 = undefined,
    szTypeName: [80]u16 = undefined,
};

pub const ICONINFO = extern struct {
    fIcon: BOOL = 1,
    xHotspot: u32 = 0,
    yHotspot: u32 = 0,
    hbmMask: H = null,
    hbmColor: H = null,
};

// ---- kernel32
pub extern "kernel32" fn GetModuleHandleW(?WSTR) callconv(.winapi) H;
pub extern "kernel32" fn GetCommandLineW() callconv(.winapi) WSTR;
pub extern "kernel32" fn GetModuleFileNameW(H, [*]u16, u32) callconv(.winapi) u32;
pub extern "kernel32" fn CreateThread(?*anyopaque, usize, THREADPROC, ?*anyopaque, u32, ?*u32) callconv(.winapi) H;
pub extern "kernel32" fn CloseHandle(H) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateEventW(?*anyopaque, BOOL, BOOL, ?WSTR) callconv(.winapi) H;
pub extern "kernel32" fn SetEvent(H) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitForSingleObject(H, u32) callconv(.winapi) u32;
pub extern "kernel32" fn Sleep(u32) callconv(.winapi) void;
pub extern "kernel32" fn GetProcessHeap() callconv(.winapi) H;
pub extern "kernel32" fn HeapAlloc(H, u32, usize) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn HeapReAlloc(H, u32, ?*anyopaque, usize) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn HeapFree(H, u32, ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn AcquireSRWLockExclusive(*SRWLOCK) callconv(.winapi) void;
pub extern "kernel32" fn ReleaseSRWLockExclusive(*SRWLOCK) callconv(.winapi) void;
pub extern "kernel32" fn AcquireSRWLockShared(*SRWLOCK) callconv(.winapi) void;
pub extern "kernel32" fn ReleaseSRWLockShared(*SRWLOCK) callconv(.winapi) void;
pub extern "kernel32" fn FindFirstFileExW(WSTR, i32, *WIN32_FIND_DATAW, i32, ?*anyopaque, u32) callconv(.winapi) H;
pub extern "kernel32" fn FindNextFileW(H, *WIN32_FIND_DATAW) callconv(.winapi) BOOL;
pub extern "kernel32" fn FindClose(H) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetLogicalDrives() callconv(.winapi) u32;
pub extern "kernel32" fn GetDriveTypeW(WSTR) callconv(.winapi) u32;
pub extern "kernel32" fn GetEnvironmentVariableW(WSTR, [*]u16, u32) callconv(.winapi) u32;
pub extern "kernel32" fn CreatePipe(*H, *H, ?*SECURITY_ATTRIBUTES, u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetHandleInformation(H, u32, u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateProcessW(?WSTR, ?[*]u16, ?*anyopaque, ?*anyopaque, BOOL, u32, ?*anyopaque, ?WSTR, *STARTUPINFOW, *PROCESS_INFORMATION) callconv(.winapi) BOOL;
pub extern "kernel32" fn ReadFile(H, [*]u8, u32, ?*u32, ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateFileW(WSTR, u32, u32, ?*SECURITY_ATTRIBUTES, u32, u32, H) callconv(.winapi) H;
pub extern "kernel32" fn GetExitCodeProcess(H, *u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn ResumeThread(H) callconv(.winapi) u32;
pub extern "kernel32" fn CreateJobObjectW(?*anyopaque, ?WSTR) callconv(.winapi) H;
pub extern "kernel32" fn AssignProcessToJobObject(H, H) callconv(.winapi) BOOL;
pub extern "kernel32" fn TerminateJobObject(H, u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetCurrentDirectoryW(WSTR) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetCurrentDirectoryW(u32, [*]u16) callconv(.winapi) u32;
pub extern "kernel32" fn MultiByteToWideChar(u32, u32, [*]const u8, i32, ?[*]u16, i32) callconv(.winapi) i32;
pub extern "kernel32" fn FoldStringW(u32, [*]const u16, i32, ?[*]u16, i32) callconv(.winapi) i32;
pub extern "kernel32" fn CreateMutexW(?*anyopaque, BOOL, ?WSTR) callconv(.winapi) H;
pub extern "kernel32" fn GetLastError() callconv(.winapi) u32;
pub extern "kernel32" fn SearchPathW(?WSTR, WSTR, ?WSTR, u32, [*]u16, ?*anyopaque) callconv(.winapi) u32;
pub extern "kernel32" fn GlobalAlloc(u32, usize) callconv(.winapi) H;
pub extern "kernel32" fn GlobalLock(H) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(H) callconv(.winapi) BOOL;
pub extern "kernel32" fn ExitProcess(u32) callconv(.winapi) noreturn;

// ---- user32
pub extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) u16;
pub extern "user32" fn CreateWindowExW(u32, WSTR, ?WSTR, u32, i32, i32, i32, i32, H, H, H, ?*anyopaque) callconv(.winapi) H;
pub extern "user32" fn DefWindowProcW(H, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn CallWindowProcW(usize, H, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn GetMessageW(*MSG, H, u32, u32) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn PostQuitMessage(i32) callconv(.winapi) void;
pub extern "user32" fn PostMessageW(H, u32, WPARAM, LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn SendMessageW(H, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn ShowWindow(H, i32) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPos(H, H, i32, i32, i32, i32, u32) callconv(.winapi) BOOL;
pub extern "user32" fn MoveWindow(H, i32, i32, i32, i32, BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn SetForegroundWindow(H) callconv(.winapi) BOOL;
pub extern "user32" fn SetFocus(H) callconv(.winapi) H;
pub extern "user32" fn RegisterHotKey(H, i32, u32, u32) callconv(.winapi) BOOL;
pub extern "user32" fn BeginPaint(H, *PAINTSTRUCT) callconv(.winapi) H;
pub extern "user32" fn EndPaint(H, *const PAINTSTRUCT) callconv(.winapi) BOOL;
pub extern "user32" fn InvalidateRect(H, ?*const RECT, BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn GetClientRect(H, *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn FillRect(H, *const RECT, H) callconv(.winapi) i32;
pub extern "user32" fn DrawTextW(H, [*]const u16, i32, *RECT, u32) callconv(.winapi) i32;
pub extern "user32" fn GetDC(H) callconv(.winapi) H;
pub extern "user32" fn ReleaseDC(H, H) callconv(.winapi) i32;
pub extern "user32" fn SetWindowLongPtrW(H, i32, usize) callconv(.winapi) usize;
pub extern "user32" fn GetKeyState(i32) callconv(.winapi) i16;
pub extern "user32" fn GetCursorPos(*POINT) callconv(.winapi) BOOL;
pub extern "user32" fn MonitorFromPoint(POINT, u32) callconv(.winapi) H;
pub extern "user32" fn GetMonitorInfoW(H, *MONITORINFO) callconv(.winapi) BOOL;
pub extern "user32" fn IsWindowVisible(H) callconv(.winapi) BOOL;
pub extern "user32" fn FindWindowW(?WSTR, ?WSTR) callconv(.winapi) H;
pub extern "user32" fn LoadCursorW(H, usize) callconv(.winapi) H;
pub extern "user32" fn CreatePopupMenu() callconv(.winapi) H;
pub extern "user32" fn AppendMenuW(H, u32, usize, ?WSTR) callconv(.winapi) BOOL;
pub extern "user32" fn TrackPopupMenu(H, u32, i32, i32, i32, H, ?*const RECT) callconv(.winapi) BOOL;
pub extern "user32" fn DestroyMenu(H) callconv(.winapi) BOOL;
pub extern "user32" fn OpenClipboard(H) callconv(.winapi) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn SetClipboardData(u32, H) callconv(.winapi) H;
pub extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn CharLowerBuffW([*]u16, u32) callconv(.winapi) u32;
pub extern "user32" fn SetProcessDpiAwarenessContext(isize) callconv(.winapi) BOOL;
pub extern "user32" fn GetDpiForSystem() callconv(.winapi) u32;
pub extern "user32" fn CreateIconIndirect(*ICONINFO) callconv(.winapi) H;
pub extern "user32" fn GetWindowTextW(H, [*]u16, i32) callconv(.winapi) i32;
pub extern "user32" fn GetWindowTextLengthW(H) callconv(.winapi) i32;
pub extern "user32" fn SetWindowTextW(H, WSTR) callconv(.winapi) BOOL;
pub extern "user32" fn DestroyWindow(H) callconv(.winapi) BOOL;
pub extern "user32" fn SetTimer(H, usize, u32, ?*anyopaque) callconv(.winapi) usize;

// ---- gdi32
pub extern "gdi32" fn CreateCompatibleDC(H) callconv(.winapi) H;
pub extern "gdi32" fn CreateCompatibleBitmap(H, i32, i32) callconv(.winapi) H;
pub extern "gdi32" fn CreateBitmap(i32, i32, u32, u32, ?*const anyopaque) callconv(.winapi) H;
pub extern "gdi32" fn SelectObject(H, H) callconv(.winapi) H;
pub extern "gdi32" fn DeleteObject(H) callconv(.winapi) BOOL;
pub extern "gdi32" fn DeleteDC(H) callconv(.winapi) BOOL;
pub extern "gdi32" fn BitBlt(H, i32, i32, i32, i32, H, i32, i32, u32) callconv(.winapi) BOOL;
pub extern "gdi32" fn PatBlt(H, i32, i32, i32, i32, u32) callconv(.winapi) BOOL;
pub extern "gdi32" fn CreateSolidBrush(u32) callconv(.winapi) H;
pub extern "gdi32" fn SetBkMode(H, i32) callconv(.winapi) i32;
pub extern "gdi32" fn SetTextColor(H, u32) callconv(.winapi) u32;
pub extern "gdi32" fn SetBkColor(H, u32) callconv(.winapi) u32;
pub extern "gdi32" fn CreateFontW(i32, i32, i32, i32, i32, u32, u32, u32, u32, u32, u32, u32, u32, WSTR) callconv(.winapi) H;
pub extern "gdi32" fn GetTextExtentPoint32W(H, [*]const u16, i32, *SIZE) callconv(.winapi) BOOL;
pub extern "gdi32" fn RoundRect(H, i32, i32, i32, i32, i32, i32) callconv(.winapi) BOOL;
pub extern "gdi32" fn GetStockObject(i32) callconv(.winapi) H;

// ---- shell32 / ole32 / shlwapi / comctl32 / dwmapi / advapi32
pub extern "shell32" fn ShellExecuteExW(*SHELLEXECUTEINFOW) callconv(.winapi) BOOL;
pub extern "shell32" fn Shell_NotifyIconW(u32, *NOTIFYICONDATAW) callconv(.winapi) BOOL;
pub extern "shell32" fn SHGetFileInfoW(?*const anyopaque, u32, *SHFILEINFOW, u32, u32) callconv(.winapi) usize;
pub extern "shell32" fn SHParseDisplayName(WSTR, ?*anyopaque, *?*anyopaque, u32, ?*u32) callconv(.winapi) i32;
pub extern "shell32" fn SHBindToObject(?*anyopaque, ?*anyopaque, ?*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) i32;
pub extern "shell32" fn ILCombine(?*anyopaque, ?*anyopaque) callconv(.winapi) ?*anyopaque;
pub extern "ole32" fn CoInitializeEx(?*anyopaque, u32) callconv(.winapi) i32;
pub extern "ole32" fn CoTaskMemFree(?*anyopaque) callconv(.winapi) void;
pub extern "shlwapi" fn StrRetToBufW(*anyopaque, ?*anyopaque, [*]u16, u32) callconv(.winapi) i32;
pub extern "comctl32" fn ImageList_Draw(usize, i32, H, i32, i32, u32) callconv(.winapi) BOOL;
pub extern "comctl32" fn ImageList_GetIconSize(usize, *i32, *i32) callconv(.winapi) BOOL;
pub extern "dwmapi" fn DwmSetWindowAttribute(H, u32, *const anyopaque, u32) callconv(.winapi) i32;
pub extern "advapi32" fn RegCreateKeyExW(usize, WSTR, u32, ?WSTR, u32, u32, ?*anyopaque, *H, ?*u32) callconv(.winapi) i32;
pub extern "advapi32" fn RegSetValueExW(H, WSTR, u32, u32, [*]const u8, u32) callconv(.winapi) i32;
pub extern "advapi32" fn RegQueryValueExW(H, WSTR, ?*u32, ?*u32, ?[*]u8, ?*u32) callconv(.winapi) i32;
pub extern "advapi32" fn RegDeleteValueW(H, WSTR) callconv(.winapi) i32;
pub extern "advapi32" fn RegCloseKey(H) callconv(.winapi) i32;

pub fn rgb(r: u32, g: u32, b: u32) u32 {
    return r | (g << 8) | (b << 16);
}

// ---- glass / DIB
pub const BITMAPINFOHEADER = extern struct {
    biSize: u32 = 40,
    biWidth: i32,
    biHeight: i32,
    biPlanes: u16 = 1,
    biBitCount: u16 = 32,
    biCompression: u32 = 0,
    biSizeImage: u32 = 0,
    biXPelsPerMeter: i32 = 0,
    biYPelsPerMeter: i32 = 0,
    biClrUsed: u32 = 0,
    biClrImportant: u32 = 0,
};
pub extern "gdi32" fn CreateDIBSection(H, *const BITMAPINFOHEADER, u32, *?*anyopaque, H, u32) callconv(.winapi) H;
pub extern "gdi32" fn GetTextFaceW(H, i32, [*]u16) callconv(.winapi) i32;
pub extern "dwmapi" fn DwmExtendFrameIntoClientArea(H, *const [4]i32) callconv(.winapi) i32;

pub const ACCENT_POLICY = extern struct { state: u32, flags: u32, color: u32, anim: u32 = 0 };
pub const WINCOMPATTRDATA = extern struct { attrib: u32, data: *const anyopaque, size: usize };
pub extern "user32" fn SetWindowCompositionAttribute(H, *const WINCOMPATTRDATA) callconv(.winapi) BOOL;
pub extern "user32" fn GetForegroundWindow() callconv(.winapi) H;
pub extern "user32" fn GetClassNameW(H, [*]u16, i32) callconv(.winapi) i32;

// ---- drag, install / uninstall
pub extern "user32" fn ScreenToClient(H, *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowRect(H, *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn MessageBoxW(H, WSTR, WSTR, u32) callconv(.winapi) i32;
pub extern "user32" fn LoadIconW(H, usize) callconv(.winapi) H;
pub extern "kernel32" fn DeleteFileW(WSTR) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateDirectoryW(WSTR, ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn WriteFile(H, [*]const u8, u32, ?*u32, ?*anyopaque) callconv(.winapi) BOOL;
pub extern "advapi32" fn RegDeleteKeyW(usize, WSTR) callconv(.winapi) i32;
pub extern "ole32" fn CoCreateInstance(*const GUID, ?*anyopaque, u32, *const GUID, *?*anyopaque) callconv(.winapi) i32;

// ---- dock
pub const ENUMPROC = *const fn (H, LPARAM) callconv(.winapi) BOOL;
pub const APPBARDATA = extern struct {
    cbSize: u32 = @sizeOf(APPBARDATA),
    hWnd: H = null,
    uCallbackMessage: u32 = 0,
    uEdge: u32 = 0,
    rc: RECT = .{},
    lParam: LPARAM = 0,
};
pub const BITMAP = extern struct {
    bmType: i32 = 0,
    bmWidth: i32 = 0,
    bmHeight: i32 = 0,
    bmWidthBytes: i32 = 0,
    bmPlanes: u16 = 0,
    bmBitsPixel: u16 = 0,
    bmBits: ?*anyopaque = null,
};
pub const TRACKMOUSEEVENT = extern struct {
    cbSize: u32 = @sizeOf(TRACKMOUSEEVENT),
    dwFlags: u32 = 2,
    hwndTrack: H = null,
    dwHoverTime: u32 = 0,
};
pub const BLENDFUNCTION = extern struct { op: u8 = 0, flags: u8 = 0, alpha: u8 = 255, format: u8 = 1 };

pub extern "user32" fn EnumWindows(ENUMPROC, LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindow(H, u32) callconv(.winapi) H;
pub extern "user32" fn GetWindowLongPtrW(H, i32) callconv(.winapi) usize;
pub extern "user32" fn GetWindowThreadProcessId(H, ?*u32) callconv(.winapi) u32;
pub extern "user32" fn FindWindowExW(H, H, ?WSTR, ?WSTR) callconv(.winapi) H;
pub extern "user32" fn IsIconic(H) callconv(.winapi) BOOL;
pub extern "user32" fn UpdateLayeredWindow(H, H, ?*const POINT, ?*const SIZE, H, ?*const POINT, u32, ?*const BLENDFUNCTION, u32) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowRgn(H, H, BOOL) callconv(.winapi) i32;
pub extern "user32" fn TrackMouseEvent(*TRACKMOUSEEVENT) callconv(.winapi) BOOL;
pub extern "user32" fn KillTimer(H, usize) callconv(.winapi) BOOL;
pub extern "user32" fn GetSystemMetrics(i32) callconv(.winapi) i32;
pub extern "gdi32" fn CreateRoundRectRgn(i32, i32, i32, i32, i32, i32) callconv(.winapi) H;
pub extern "gdi32" fn GetObjectW(H, i32, *anyopaque) callconv(.winapi) i32;
pub extern "gdi32" fn GetDIBits(H, H, u32, u32, ?*anyopaque, *BITMAPINFOHEADER, u32) callconv(.winapi) i32;
pub extern "kernel32" fn OpenProcess(u32, BOOL, u32) callconv(.winapi) H;
pub extern "kernel32" fn QueryFullProcessImageNameW(H, u32, [*]u16, *u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetApplicationUserModelId(H, *u32, [*]u16) callconv(.winapi) i32;
pub extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
pub extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
pub extern "shell32" fn SHAppBarMessage(u32, *APPBARDATA) callconv(.winapi) usize;
pub extern "shell32" fn SHCreateItemFromParsingName(WSTR, ?*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) i32;
pub extern "shell32" fn SHEmptyRecycleBinW(H, ?WSTR, u32) callconv(.winapi) i32;
pub extern "dwmapi" fn DwmGetWindowAttribute(H, u32, *anyopaque, u32) callconv(.winapi) i32;
pub extern "version" fn GetFileVersionInfoSizeW(WSTR, ?*u32) callconv(.winapi) u32;
pub extern "version" fn GetFileVersionInfoW(WSTR, u32, u32, *anyopaque) callconv(.winapi) BOOL;
pub extern "version" fn VerQueryValueW(*const anyopaque, WSTR, *?*anyopaque, *u32) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowDisplayAffinity(H, u32) callconv(.winapi) BOOL;
pub extern "dwmapi" fn DwmFlush() callconv(.winapi) i32;
pub extern "kernel32" fn QueryPerformanceCounter(*i64) callconv(.winapi) BOOL;
pub extern "kernel32" fn QueryPerformanceFrequency(*i64) callconv(.winapi) BOOL;

// ---- dock: full-screen detection, window previews, partial layered updates
pub const DWM_THUMBNAIL_PROPERTIES = extern struct {
    dwFlags: u32 = 0,
    rcDestination: RECT = .{},
    rcSource: RECT = .{},
    opacity: u8 = 255,
    fVisible: BOOL = 1,
    fSourceClientAreaOnly: BOOL = 0,
};
pub const UPDATELAYEREDWINDOWINFO = extern struct {
    cbSize: u32 = @sizeOf(UPDATELAYEREDWINDOWINFO),
    hdcDst: H = null,
    pptDst: ?*const POINT = null,
    psize: ?*const SIZE = null,
    hdcSrc: H = null,
    pptSrc: ?*const POINT = null,
    crKey: u32 = 0,
    pblend: ?*const BLENDFUNCTION = null,
    dwFlags: u32 = 0,
    prcDirty: ?*const RECT = null,
};
pub extern "user32" fn UpdateLayeredWindowIndirect(H, *const UPDATELAYEREDWINDOWINFO) callconv(.winapi) BOOL;
pub extern "user32" fn MonitorFromWindow(H, u32) callconv(.winapi) H;
pub extern "dwmapi" fn DwmRegisterThumbnail(H, H, *H) callconv(.winapi) i32;
pub extern "dwmapi" fn DwmUnregisterThumbnail(H) callconv(.winapi) i32;
pub extern "dwmapi" fn DwmUpdateThumbnailProperties(H, *const DWM_THUMBNAIL_PROPERTIES) callconv(.winapi) i32;
pub extern "dwmapi" fn DwmQueryThumbnailSourceSize(H, *SIZE) callconv(.winapi) i32;

// ---- dock: system tray icons (the Dock answers Shell_NotifyIcon itself)
pub const COPYDATASTRUCT = extern struct { dwData: usize, cbData: u32, lpData: ?*anyopaque };
/// NOTIFYICONDATAW as it travels to the tray: handles are always 32 bits wide.
pub const TRAY_NID = extern struct {
    cbSize: u32,
    hWnd: u32,
    uID: u32,
    uFlags: u32,
    uCallbackMessage: u32,
    hIcon: u32,
    szTip: [128]u16,
    dwState: u32,
    dwStateMask: u32,
    szInfo: [256]u16,
    uVersion: u32,
    szInfoTitle: [64]u16,
    dwInfoFlags: u32,
    guidItem: GUID,
    hBalloonIcon: u32,
};
pub const TRAY_DATA = extern struct { dwSignature: u32, dwMessage: u32, nid: TRAY_NID };
pub const WINEVENTPROC = *const fn (H, u32, H, i32, i32, u32, u32) callconv(.winapi) void;
pub extern "user32" fn SendMessageTimeoutW(H, u32, WPARAM, LPARAM, u32, u32, ?*usize) callconv(.winapi) LRESULT;
pub extern "user32" fn RegisterWindowMessageW(WSTR) callconv(.winapi) u32;
pub extern "user32" fn IsWindow(H) callconv(.winapi) BOOL;
pub extern "user32" fn AllowSetForegroundWindow(u32) callconv(.winapi) BOOL;
pub extern "user32" fn GetIconInfo(H, *ICONINFO) callconv(.winapi) BOOL;
pub extern "user32" fn SetWinEventHook(u32, u32, H, WINEVENTPROC, u32, u32, u32) callconv(.winapi) H;
pub extern "user32" fn UnhookWinEvent(H) callconv(.winapi) BOOL;

// ---- updates (WinHTTP)
pub extern "winhttp" fn WinHttpOpen(?WSTR, u32, ?WSTR, ?WSTR, u32) callconv(.winapi) H;
pub extern "winhttp" fn WinHttpConnect(H, WSTR, u16, u32) callconv(.winapi) H;
pub extern "winhttp" fn WinHttpOpenRequest(H, WSTR, WSTR, ?WSTR, ?WSTR, ?*const ?WSTR, u32) callconv(.winapi) H;
pub extern "winhttp" fn WinHttpSendRequest(H, ?WSTR, u32, ?*anyopaque, u32, u32, usize) callconv(.winapi) BOOL;
pub extern "winhttp" fn WinHttpReceiveResponse(H, ?*anyopaque) callconv(.winapi) BOOL;
pub extern "winhttp" fn WinHttpQueryHeaders(H, u32, ?WSTR, ?*anyopaque, *u32, ?*u32) callconv(.winapi) BOOL;
pub extern "winhttp" fn WinHttpQueryDataAvailable(H, *u32) callconv(.winapi) BOOL;
pub extern "winhttp" fn WinHttpReadData(H, [*]u8, u32, *u32) callconv(.winapi) BOOL;
pub extern "winhttp" fn WinHttpSetTimeouts(H, i32, i32, i32, i32) callconv(.winapi) BOOL;
pub extern "winhttp" fn WinHttpCloseHandle(H) callconv(.winapi) BOOL;
