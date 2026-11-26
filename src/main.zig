//! Ter — Spotlight-style overlay for Windows: find apps, find files, run CMD / PowerShell.
const w = @import("w.zig");
const u = @import("util.zig");
const apps = @import("apps.zig");
const files = @import("files.zig");
const term = @import("term.zig");
const L = u.L;

const Mode = enum(u8) { app, file, cmd, ps };

// layout at 96 DPI
const WIN_W = 720;
const PAD = 18;
const INPUT_H = 60;
const ROW_H = 48;
const FOOT_H = 30;
const MAX_ROWS = 8;
const TERM_LINES = 16;
const CHIP_W = 46;
const CHIP_GAP = 4;

// Palette. Everything is drawn on black and composited over the acrylic backdrop:
// black = clear glass, brighter = more solid.
const C_SEP = w.rgb(72, 72, 78);
const C_TEXT = w.rgb(246, 246, 248);
const C_DIM = w.rgb(176, 176, 186);
const C_FAINT = w.rgb(128, 128, 138);
const C_SEL = w.rgb(10, 100, 222);
const C_SEL_SUB = w.rgb(214, 228, 252);
const C_KEY = w.rgb(60, 60, 68);
const C_RED = w.rgb(255, 105, 97);
/// Extra darkening (0-255) behind terminal output so long text stays readable.
const PANE_ALPHA = 120;
/// Dark tint laid over the blur, 0xAABBGGRR: higher alpha = darker, less see-through.
const GLASS_TINT: u32 = 0xCC1E1A1A;

/// Each mode has its own colour so you always know where you are.
fn accent(m: Mode) u32 {
    return switch (m) {
        .app => w.rgb(64, 156, 255), // blue
        .file => w.rgb(50, 215, 95), // green
        .cmd => w.rgb(255, 170, 40), // amber
        .ps => w.rgb(200, 120, 255), // purple
    };
}

/// Same hue, much darker: used as the tinted fill behind accent-coloured text.
fn tint(color: u32) u32 {
    return w.rgb((color & 255) * 30 / 100, ((color >> 8) & 255) * 30 / 100, ((color >> 16) & 255) * 30 / 100);
}

const WM_TRAY = 0x8001;
const WM_APPS = 0x8002;
const WM_FILES = 0x8003;
const WM_INDEXED = 0x8004;
const WM_TDATA = 0x8005;
const WM_TDONE = 0x8006;
const WM_SHOWME = 0x8007;

const CLASS = L("TerOverlay");

var hinst: w.H = null;
var hwnd: w.H = null;
var edit: w.H = null;
var edit_proc: usize = 0;
var dpi: i32 = 96;
var himl: usize = 0;
var icon_px: i32 = 32;

var f_input: w.H = null;
var f_title: w.H = null;
var f_small: w.H = null;
var f_bold: w.H = null;
var f_mono: w.H = null;
var f_icon: w.H = null;
var pane_top: i32 = 0;
var pane_bot: i32 = 0;
var line_h: i32 = 19;

var mode: Mode = .app;
var set: ?*u.Set = null;
var sel: usize = 0;
var top: usize = 0;
var qkey: u.List(u8) = .{};
var file_gen: u32 = 0;
var file_wait: bool = false;
var in_fix: bool = false;
var hist_pos: usize = 0;
var hotkey_name: []const u16 = L("");
var text_buf: [1024]u16 = undefined;

fn px(v: i32) i32 {
    return @divTrunc(v * dpi + 48, 96);
}

fn isTerm() bool {
    return mode == .cmd or mode == .ps;
}

fn getText() []const u16 {
    const n = w.GetWindowTextW(edit, &text_buf, text_buf.len);
    return text_buf[0..@intCast(@max(n, 0))];
}

fn setText(s: []const u16) void {
    var buf: [1024]u16 = undefined;
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    in_fix = true;
    _ = w.SetWindowTextW(edit, @ptrCast(&buf));
    in_fix = false;
    _ = w.SendMessageW(edit, 0xB1, n, @intCast(n)); // EM_SETSEL: caret to end
}

fn rowCount() usize {
    return if (set) |s| s.rows.len else 0;
}

fn replaceSet(new: ?*u.Set) void {
    if (set) |old| old.destroy();
    set = new;
    sel = 0;
    top = 0;
}

fn contentHeight() i32 {
    if (isTerm()) {
        if (term.lineCount() == 0 and !term.running) return 0;
        return 1 + px(8) * 2 + TERM_LINES * line_h;
    }
    const n: i32 = @intCast(@min(rowCount(), MAX_ROWS));
    if (n > 0) return 1 + px(6) * 2 + n * px(ROW_H);
    if (qkey.len > 0) return 1 + px(ROW_H);
    return 0;
}

fn relayout() void {
    const h = px(INPUT_H) + contentHeight() + px(FOOT_H);
    _ = w.SetWindowPos(hwnd, null, 0, 0, px(WIN_W), h, 0x2 | 0x4 | 0x10);
    _ = w.InvalidateRect(hwnd, null, 0);
}

/// Re-run the current query for the current mode.
fn refresh() void {
    if (in_fix) return;
    var text = getText();
    if (!isTerm() and text.len > 0 and (text[0] == '>' or text[0] == '$')) {
        mode = if (text[0] == '>') .cmd else .ps;
        setText(text[1..]);
        text = getText();
        _ = w.InvalidateRect(edit, null, 1);
    }
    qkey.clear();
    u.foldKey(&qkey, u.trim16(text));
    switch (mode) {
        .app => replaceSet(apps.search(qkey.items())),
        .file => {
            if (qkey.len == 0) {
                replaceSet(null);
                file_wait = false;
            } else {
                file_gen = files.request(qkey.items());
                file_wait = true;
            }
        },
        else => {
            replaceSet(null);
            qkey.clear();
        },
    }
    relayout();
}

fn setMode(m: Mode) void {
    if (m == mode) return;
    mode = m;
    replaceSet(null);
    hist_pos = term.history.len;
    _ = w.InvalidateRect(edit, null, 1);
    refresh();
}

/// Pinned: the bar lives on the desktop all the time. "Hiding" only lets it sink behind
/// other windows; the hotkey brings it back to the front.
var pinned: bool = true;
var resting: bool = false;
var raised: bool = false;

fn isFront() bool {
    return w.GetForegroundWindow() == hwnd;
}

fn hide() void {
    if (!pinned) {
        if (w.IsWindowVisible(hwnd) != 0) _ = w.ShowWindow(hwnd, 0);
        return;
    }
    if (resting) return;
    resting = true;
    // Hiding for an instant hands keyboard focus back to the window used before.
    if (isFront()) _ = w.ShowWindow(hwnd, 0);
    // Bottom of the stack = on the desktop; this also drops the always-on-top flag.
    _ = w.SetWindowPos(hwnd, @ptrFromInt(1), 0, 0, 0, 0, 0x1 | 0x2 | 0x10 | 0x40);
    raised = false;
    resting = false;
}

fn placement() w.RECT {
    var pt = w.POINT{};
    _ = w.GetCursorPos(&pt);
    var mi = w.MONITORINFO{};
    _ = w.GetMonitorInfoW(w.MonitorFromPoint(pt, 2), &mi);
    var x = mi.rcWork.left + @divTrunc(mi.rcWork.right - mi.rcWork.left - px(WIN_W), 2);
    var y = mi.rcWork.top + @divTrunc((mi.rcWork.bottom - mi.rcWork.top) * 22, 100);
    // Use the dragged position as long as it is still on a connected screen.
    if (pos_set and w.MonitorFromPoint(.{ .x = pos_x + @divTrunc(px(WIN_W), 2), .y = pos_y + px(20) }, 0) != null) {
        x = pos_x;
        y = pos_y;
    }
    return .{ .left = x, .top = y, .right = px(WIN_W), .bottom = px(INPUT_H) + contentHeight() + px(FOOT_H) };
}

/// Put the bar on the desktop without taking focus (start-up in pinned mode).
fn showResting() void {
    const r = placement();
    _ = w.SetWindowPos(hwnd, @ptrFromInt(1), r.left, r.top, r.right, r.bottom, 0x10 | 0x40);
}

fn show() void {
    if (w.IsWindowVisible(hwnd) != 0) {
        // already on the desktop: keep its place, just bring it to the front
        _ = w.SetWindowPos(hwnd, w.INVALID, 0, 0, 0, 0, 0x1 | 0x2);
    } else {
        const r = placement();
        _ = w.SetWindowPos(hwnd, w.INVALID, r.left, r.top, r.right, r.bottom, 0x40); // topmost + show
    }
    _ = w.SetForegroundWindow(hwnd);
    _ = w.SetFocus(edit);
    _ = w.SendMessageW(edit, 0xB1, 0, -1); // select all: typing replaces the old query
}

fn toggle() void {
    const up = if (pinned) isFront() else w.IsWindowVisible(hwnd) != 0;
    if (up) hide() else show();
}

/// Pinned mode: "Show desktop" (Win+D) covers ordinary windows, so while the desktop
/// itself has focus keep the bar above it, and let it sink again afterwards.
fn keepOnDesktop() void {
    if (!pinned or w.IsWindowVisible(hwnd) == 0 or isFront()) return;
    const fg = w.GetForegroundWindow();
    var cls: [40]u16 = undefined;
    const n = if (fg != null) w.GetClassNameW(fg, &cls, cls.len) else 0;
    const name = cls[0..@intCast(@max(n, 0))];
    const desktop = u.eqlCI(name, L("Progman")) or u.eqlCI(name, L("WorkerW"));
    if (desktop and !raised) {
        _ = w.SetWindowPos(hwnd, w.INVALID, 0, 0, 0, 0, 0x1 | 0x2 | 0x10);
        raised = true;
    } else if (!desktop and raised) {
        _ = w.SetWindowPos(hwnd, @ptrFromInt(1), 0, 0, 0, 0, 0x1 | 0x2 | 0x10);
        raised = false;
    }
}

const APP_KEY = u.APP_KEY;

/// Where the user dragged the bar to (screen pixels); unset = centred near the top.
var pos_set: bool = false;
var pos_x: i32 = 0;
var pos_y: i32 = 0;

fn loadSettings() void {
    if (u.regGetDword(APP_KEY, L("Pin"))) |v| pinned = v != 0;
    const x = u.regGetDword(APP_KEY, L("X")) orelse return;
    const y = u.regGetDword(APP_KEY, L("Y")) orelse return;
    pos_x = @bitCast(x);
    pos_y = @bitCast(y);
    pos_set = (u.regGetDword(APP_KEY, L("Pos")) orelse 0) != 0;
}

fn setPinned(on: bool) void {
    pinned = on;
    u.regSetDword(APP_KEY, L("Pin"), @intFromBool(on));
    if (on) {
        if (w.IsWindowVisible(hwnd) == 0) showResting();
    } else if (!isFront()) {
        _ = w.ShowWindow(hwnd, 0);
    }
}

/// Called when a drag ends: remember the new spot.
fn savePosition() void {
    var r = w.RECT{};
    if (w.GetWindowRect(hwnd, &r) == 0) return;
    pos_x = r.left;
    pos_y = r.top;
    pos_set = true;
    u.regSetDword(APP_KEY, L("X"), @bitCast(pos_x));
    u.regSetDword(APP_KEY, L("Y"), @bitCast(pos_y));
    u.regSetDword(APP_KEY, L("Pos"), 1);
}

fn resetPosition() void {
    pos_set = false;
    u.regSetDword(APP_KEY, L("Pos"), 0);
    if (w.IsWindowVisible(hwnd) != 0) {
        const r = placement();
        _ = w.SetWindowPos(hwnd, null, r.left, r.top, 0, 0, 0x1 | 0x4 | 0x10);
    }
}

/// The parts of the bar you can grab to drag it: the icon left of the text box,
/// the thin strips above and below the text box, and the footer.
fn isDragZone(x: i32, y: i32) bool {
    var rc = w.RECT{};
    _ = w.GetClientRect(hwnd, &rc);
    if (y >= rc.bottom - px(FOOT_H)) return true;
    if (y >= px(INPUT_H)) return false;
    if (x < px(PAD + 30)) return true;
    return x < chipRect(0).left - px(6) and (y < px(12) or y >= px(INPUT_H) - px(12));
}

fn moveSel(delta: i32) void {
    const n = rowCount();
    if (n == 0) return;
    const cur: i32 = @intCast(sel);
    sel = @intCast(@max(0, @min(cur + delta, @as(i32, @intCast(n)) - 1)));
    if (sel < top) top = sel;
    if (sel >= top + MAX_ROWS) top = sel + 1 - MAX_ROWS;
    _ = w.InvalidateRect(hwnd, null, 0);
}

fn scrollTerm(delta: i32) void {
    const total: i32 = @intCast(term.lineCount());
    const max = @max(0, total - TERM_LINES);
    const cur: i32 = @intCast(term.scroll);
    term.scroll = @intCast(@max(0, @min(cur + delta, max)));
    _ = w.InvalidateRect(hwnd, null, 0);
}

fn historyMove(delta: i32) void {
    const items = term.history.items();
    const pos: i32 = @as(i32, @intCast(hist_pos)) + delta;
    if (pos < 0 or pos > items.len) return;
    hist_pos = @intCast(pos);
    setText(if (hist_pos == items.len) L("") else items[hist_pos]);
}

/// Full path of the selected row (zero-terminated), plus its folder when known.
fn selectedPath(path: *u.List(u16), dir: *u.List(u16)) ?u.Row {
    const s = set orelse return null;
    if (sel >= s.rows.len) return null;
    const r = s.rows.items()[sel];
    if (r.kind == .app) {
        path.appendSlice(apps.list.items()[r.ref].target);
    } else {
        const sub = s.sub(r);
        path.appendSlice(sub);
        if (sub.len > 0 and sub[sub.len - 1] != '\\') path.push('\\');
        path.appendSlice(s.title(r));
        dir.appendSlice(sub);
    }
    path.push(0);
    dir.push(0);
    return r;
}

fn activate(admin: bool, alt: bool) void {
    if (isTerm()) {
        const text = getText();
        const sh: term.Shell = if (mode == .cmd) .cmd else .ps;
        if (u.eqlCI(u.trim16(text), L("exit"))) {
            setText(L(""));
            return hide();
        }
        if (admin or alt) {
            term.remember(text);
            term.openExternal(sh, text, admin);
            setText(L(""));
            return hide();
        }
        if (u.trim16(text).len == 0) return;
        term.remember(text);
        term.run(sh, text);
        hist_pos = term.history.len;
        setText(L(""));
        return relayout();
    }

    var path: u.List(u16) = .{};
    var dir: u.List(u16) = .{};
    defer path.deinit();
    defer dir.deinit();
    const r = selectedPath(&path, &dir) orelse return;
    const file: w.WSTR = @ptrCast(path.ptr.?);
    const folder: ?w.WSTR = if (dir.len > 1) @ptrCast(dir.ptr.?) else null;
    const packaged = r.kind == .app and !apps.list.items()[r.ref].is_lnk;
    hide();

    if (alt and !packaged) {
        var p: u.List(u16) = .{};
        defer p.deinit();
        p.appendSlice(L("/select,\""));
        p.appendSlice(path.items()[0 .. path.len - 1]);
        p.appendSlice(L("\""));
        p.push(0);
        _ = u.shell(null, L("explorer.exe"), @ptrCast(p.ptr.?), null);
    } else if (admin) {
        // 1223 = user said No on the UAC prompt; anything else: fall back to a normal open.
        if (!u.shell(L("runas"), file, null, folder) and w.GetLastError() != 1223)
            _ = u.shell(null, file, null, folder);
    } else {
        _ = u.shell(null, file, null, folder);
    }
}

fn copyPath() void {
    var path: u.List(u16) = .{};
    var dir: u.List(u16) = .{};
    defer path.deinit();
    defer dir.deinit();
    _ = selectedPath(&path, &dir) orelse return;
    if (w.OpenClipboard(hwnd) == 0) return;
    _ = w.EmptyClipboard();
    const mem = w.GlobalAlloc(2, path.len * 2);
    if (w.GlobalLock(mem)) |p| {
        const dst: [*]u16 = @ptrCast(@alignCast(p));
        @memcpy(dst[0..path.len], path.items());
        _ = w.GlobalUnlock(mem);
        _ = w.SetClipboardData(13, mem); // CF_UNICODETEXT
    }
    _ = w.CloseClipboard();
}

// ---------------------------------------------------------------- painting

const DT_LEFT = 0x20 | 0x4 | 0x800; // single line, vcenter, no prefix
const DT_ELLIP = 0x8000;
const DT_PATH = 0x4000;

fn drawText(dc: w.H, s: []const u16, rc: w.RECT, color: u32, font: w.H, flags: u32) void {
    if (s.len == 0) return;
    var r = rc;
    _ = w.SelectObject(dc, font);
    _ = w.SetTextColor(dc, color);
    _ = w.DrawTextW(dc, s.ptr, @intCast(s.len), &r, flags);
}

fn textW(dc: w.H, s: []const u16, font: w.H) i32 {
    var sz = w.SIZE{};
    _ = w.SelectObject(dc, font);
    _ = w.GetTextExtentPoint32W(dc, s.ptr, @intCast(s.len), &sz);
    return sz.cx;
}

fn fill(dc: w.H, rc: w.RECT, color: u32) void {
    const br = w.CreateSolidBrush(color);
    _ = w.FillRect(dc, &rc, br);
    _ = w.DeleteObject(br);
}

fn pill(dc: w.H, rc: w.RECT, color: u32, radius: i32) void {
    const br = w.CreateSolidBrush(color);
    const old_b = w.SelectObject(dc, br);
    const old_p = w.SelectObject(dc, w.GetStockObject(8)); // NULL_PEN
    _ = w.RoundRect(dc, rc.left, rc.top, rc.right + 1, rc.bottom + 1, radius, radius);
    _ = w.SelectObject(dc, old_b);
    _ = w.SelectObject(dc, old_p);
    _ = w.DeleteObject(br);
}

fn chipRect(i: i32) w.RECT {
    const right = px(WIN_W) - px(12) - (3 - i) * px(CHIP_W + CHIP_GAP);
    const t = @divTrunc(px(INPUT_H) - px(26), 2);
    return .{ .left = right - px(CHIP_W), .top = t, .right = right, .bottom = t + px(26) };
}

fn placeholder() []const u16 {
    return switch (mode) {
        .app => L("Tìm app…"),
        .file => L("Tìm file…"),
        .cmd => L("Lệnh CMD…"),
        .ps => L("Lệnh PowerShell…"),
    };
}

fn fmtCount(buf: []u16, v: u32) []u16 {
    var tmp: [16]u16 = undefined;
    var k: usize = 0;
    var x = v;
    while (true) {
        if (k % 4 == 3) {
            tmp[k] = '.';
            k += 1;
        }
        tmp[k] = '0' + @as(u16, @intCast(x % 10));
        k += 1;
        x /= 10;
        if (x == 0) break;
    }
    for (0..k) |i| buf[i] = tmp[k - 1 - i];
    return buf[0..k];
}

fn fileIcon(s: *u.Set, r: *u.Row) void {
    var name: [300]u16 = undefined;
    const t = s.title(r.*);
    const n = @min(t.len, name.len - 1);
    @memcpy(name[0..n], t[0..n]);
    name[n] = 0;
    var sfi = w.SHFILEINFOW{};
    const attr: u32 = if (r.kind == .dir) 0x10 else 0x80;
    // SYSICONINDEX | USEFILEATTRIBUTES: icon by type only, no disk access
    r.icon = if (w.SHGetFileInfoW(&name, attr, &sfi, @sizeOf(w.SHFILEINFOW), 0x4000 | 0x10) != 0) sfi.iIcon else -2;
}

fn paintRows(dc: w.H, y0: i32, width: i32) void {
    const s = set orelse return;
    const rows = s.rows.items();
    const rh = px(ROW_H);
    var i: usize = top;
    var y = y0 + px(6);
    while (i < rows.len and i < top + MAX_ROWS) : (i += 1) {
        const r = &rows[i];
        const selected = i == sel;
        if (selected) pill(dc, .{ .left = px(8), .top = y, .right = width - px(8), .bottom = y + rh }, C_SEL, px(12));
        if (r.icon == -1 and r.kind != .app) fileIcon(s, r);
        if (r.icon >= 0 and himl != 0)
            _ = w.ImageList_Draw(himl, r.icon, dc, px(PAD), y + @divTrunc(rh - icon_px, 2), 1);
        const tx = px(PAD) + icon_px + px(12);
        const sub = s.sub(r.*);
        const title = s.title(r.*);

        // what kind of thing this is, on the right
        var ext: [8]u16 = undefined;
        var kind: []const u16 = switch (r.kind) {
            .app => L("Ứng dụng"),
            .dir => L("Thư mục"),
            .file => L("File"),
        };
        if (r.kind == .file) {
            var d = title.len;
            while (d > 0 and title[d - 1] != '.') d -= 1;
            const e = title[d..];
            if (d > 1 and e.len > 0 and e.len <= ext.len) {
                for (e, 0..) |c, k| ext[k] = if (c >= 'a' and c <= 'z') c - 32 else c;
                kind = ext[0..e.len];
            }
        }
        const kw = textW(dc, kind, f_small);
        const tr = width - px(PAD) - px(6) - kw - px(12);
        drawText(dc, kind, .{ .left = tr + px(12), .top = y, .right = width - px(PAD) - px(6), .bottom = y + rh }, if (selected) C_SEL_SUB else C_FAINT, f_small, DT_LEFT);
        if (sub.len == 0) {
            drawText(dc, title, .{ .left = tx, .top = y, .right = tr, .bottom = y + rh }, C_TEXT, f_title, DT_LEFT | DT_ELLIP);
        } else {
            const mid = y + @divTrunc(rh, 2);
            drawText(dc, title, .{ .left = tx, .top = mid - px(19), .right = tr, .bottom = mid + px(1) }, C_TEXT, f_title, DT_LEFT | DT_ELLIP);
            drawText(dc, sub, .{ .left = tx, .top = mid + px(1), .right = tr, .bottom = mid + px(18) }, if (selected) C_SEL_SUB else C_DIM, f_small, DT_LEFT | DT_PATH);
        }
        y += rh;
    }
}

fn paintTerm(dc: w.H, y0: i32, width: i32, height: i32) void {
    pane_top = y0;
    pane_bot = y0 + height;
    const total = term.lineCount();
    const vis: usize = TERM_LINES;
    const max_scroll = if (total > vis) total - vis else 0;
    if (term.scroll > max_scroll) term.scroll = max_scroll;
    var i: usize = if (total > vis) total - vis - term.scroll else 0;
    var y = y0 + px(8);
    var n: usize = 0;
    while (i < total and n < vis) : ({
        i += 1;
        n += 1;
    }) {
        const ln = term.getLine(i);
        const color = switch (ln.kind) {
            .out => C_TEXT,
            .cmd => accent(mode),
            .info => C_DIM,
            .err => C_RED,
        };
        drawText(dc, ln.ptr[0..ln.len], .{ .left = px(PAD), .top = y, .right = width - px(8), .bottom = y + line_h }, color, f_mono, 0x20 | 0x800 | 0x100);
        y += line_h;
    }
}

const Hint = struct { key: []const u16, label: []const u16 };

fn paintFooter(dc: w.H, y0: i32, width: i32) void {
    const find_hints = [_]Hint{
        .{ .key = L("Enter"), .label = L("Mở") },
        .{ .key = L("Ctrl+Enter"), .label = L("Admin") },
        .{ .key = L("Shift+Enter"), .label = L("Vị trí") },
        .{ .key = L("Tab"), .label = L("Đổi") },
    };
    const term_hints = [_]Hint{
        .{ .key = L("Enter"), .label = L("Chạy") },
        .{ .key = L("Ctrl+Enter"), .label = L("Admin") },
        .{ .key = L("Shift+Enter"), .label = L("Cửa sổ") },
        .{ .key = L("Ctrl+C"), .label = L("Dừng") },
    };
    const hints: []const Hint = if (isTerm()) &term_hints else &find_hints;
    const bottom = y0 + px(FOOT_H);
    var x = px(PAD);
    for (hints) |h| {
        const kw = textW(dc, h.key, f_bold) + px(12);
        const mid = y0 + @divTrunc(px(FOOT_H), 2);
        const cap = w.RECT{ .left = x, .top = mid - px(10), .right = x + kw, .bottom = mid + px(10) };
        pill(dc, cap, C_KEY, px(8));
        drawText(dc, h.key, cap, C_TEXT, f_bold, DT_LEFT | 0x1);
        x += kw + px(6);
        const lw = textW(dc, h.label, f_small);
        drawText(dc, h.label, .{ .left = x, .top = y0, .right = x + lw, .bottom = bottom }, C_DIM, f_small, DT_LEFT);
        x += lw + px(14);
    }

    var buf: [64]u16 = undefined;
    var right: []const u16 = hotkey_name;
    var flags: u32 = DT_LEFT | 0x2; // right aligned
    if (isTerm()) {
        right = if (term.running) L("Đang chạy…") else term.cwd();
        flags |= DT_PATH;
    } else if (mode == .file) {
        var n: usize = 0;
        if (files.indexing) {
            const pre = L("Đang quét… ");
            @memcpy(buf[0..pre.len], pre);
            n = pre.len;
        }
        n += fmtCount(buf[n..], files.count).len;
        const suf = L(" mục");
        @memcpy(buf[n..][0..suf.len], suf);
        right = buf[0 .. n + suf.len];
    }
    drawText(dc, right, .{ .left = x, .top = y0, .right = width - px(PAD), .bottom = bottom }, C_DIM, f_small, flags);
}

fn paint(hdc: w.H) void {
    var rc = w.RECT{};
    _ = w.GetClientRect(hwnd, &rc);
    const width = rc.right;
    const height = rc.bottom;
    const dc = w.CreateCompatibleDC(hdc);
    var bits: ?*anyopaque = null;
    const bi = w.BITMAPINFOHEADER{ .biWidth = width, .biHeight = -height };
    const bmp = w.CreateDIBSection(hdc, &bi, 0, &bits, null, 0);
    if (bmp == null or bits == null or width <= 0 or height <= 0) {
        _ = w.DeleteDC(dc);
        return;
    }
    const old = w.SelectObject(dc, bmp);
    _ = w.SetBkMode(dc, 1);
    _ = w.PatBlt(dc, 0, 0, width, height, 0x00000042); // black = fully clear glass
    pane_top = 0;
    pane_bot = 0;

    // search bar: glyph + (edit control) + mode chips
    const ih = px(INPUT_H);
    const glyph: []const u16 = if (isTerm()) &[_]u16{0xE756} else &[_]u16{0xE721};
    drawText(dc, glyph, .{ .left = px(PAD), .top = 0, .right = px(PAD + 28), .bottom = ih }, accent(mode), f_icon, DT_LEFT);
    const labels = [_][]const u16{ L("App"), L("File"), L("CMD"), L("PS") };
    for (labels, 0..) |label, i| {
        const cr = chipRect(@intCast(i));
        const active = @intFromEnum(mode) == i;
        const m: Mode = @enumFromInt(i);
        if (active) pill(dc, cr, tint(accent(m)), px(10));
        drawText(dc, label, cr, if (active) accent(m) else C_DIM, f_bold, DT_LEFT | 0x1);
    }

    const ch = contentHeight();
    if (ch > 0) {
        fill(dc, .{ .left = 0, .top = ih, .right = width, .bottom = ih + 1 }, C_SEP);
        if (isTerm()) {
            paintTerm(dc, ih + 1, width, ch - 1);
        } else if (rowCount() > 0) {
            paintRows(dc, ih + 1, width);
        } else {
            const msg = if (mode == .file and (file_wait or files.indexing)) L("Đang tìm…") else L("Không thấy");
            drawText(dc, msg, .{ .left = 0, .top = ih + 1, .right = width, .bottom = ih + ch }, C_DIM, f_title, DT_LEFT | 0x1);
        }
        fill(dc, .{ .left = 0, .top = ih + ch, .right = width, .bottom = ih + ch + 1 }, C_SEP);
    }
    paintFooter(dc, ih + ch, width);

    // GDI leaves alpha at 0. Give every pixel an alpha equal to its brightness, so text and
    // fills become solid while the black background stays see-through to the blur behind.
    const pix: [*]u32 = @ptrCast(@alignCast(bits.?));
    const wd: usize = @intCast(width);
    var y: i32 = 0;
    while (y < height) : (y += 1) {
        const floor: u32 = if (y >= pane_top and y < pane_bot) PANE_ALPHA else 0;
        for (pix[@as(usize, @intCast(y)) * wd ..][0..wd]) |*p| {
            const v = p.*;
            const a = @max(@max(v >> 24, floor), @max((v >> 16) & 255, @max((v >> 8) & 255, v & 255)));
            p.* = (v & 0x00FFFFFF) | (a << 24);
        }
    }

    _ = w.BitBlt(hdc, 0, 0, width, height, dc, 0, 0, 0x00CC0020);
    _ = w.SelectObject(dc, old);
    _ = w.DeleteObject(bmp);
    _ = w.DeleteDC(dc);
}

// ---------------------------------------------------------------- input

fn down(vk: i32) bool {
    return w.GetKeyState(vk) < 0;
}

fn selEmpty() bool {
    var a: u32 = 0;
    var b: u32 = 0;
    _ = w.SendMessageW(edit, 0xB0, @intFromPtr(&a), @bitCast(@intFromPtr(&b)));
    return a == b;
}

fn deleteWord() void {
    var a: u32 = 0;
    var b: u32 = 0;
    _ = w.SendMessageW(edit, 0xB0, @intFromPtr(&a), @bitCast(@intFromPtr(&b)));
    const text = getText();
    var i: usize = @min(a, text.len);
    while (i > 0 and text[i - 1] == ' ') i -= 1;
    while (i > 0 and text[i - 1] != ' ' and text[i - 1] != '\\') i -= 1;
    _ = w.SendMessageW(edit, 0xB1, i, b);
    _ = w.SendMessageW(edit, 0xC2, 1, @bitCast(@intFromPtr(L("").ptr)));
}

fn editProc(h: w.H, msg: u32, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) w.LRESULT {
    switch (msg) {
        0x0100 => { // WM_KEYDOWN
            const ctrl = down(0x11);
            const shift = down(0x10);
            switch (wp) {
                0x1B => return ret(hide()),
                0x0D => return ret(activate(ctrl, shift)),
                0x09 => {
                    const n: u8 = @intFromEnum(mode);
                    return ret(setMode(@enumFromInt(if (shift) (n + 3) % 4 else (n + 1) % 4)));
                },
                0x26 => return ret(if (isTerm()) historyMove(-1) else moveSel(-1)),
                0x28 => return ret(if (isTerm()) historyMove(1) else moveSel(1)),
                0x21 => return ret(if (isTerm()) scrollTerm(TERM_LINES - 2) else moveSel(-MAX_ROWS)),
                0x22 => return ret(if (isTerm()) scrollTerm(-(TERM_LINES - 2)) else moveSel(MAX_ROWS)),
                0x74 => return ret(files.reindex()), // F5
                '1'...'4' => if (ctrl) return ret(setMode(@enumFromInt(wp - '1'))),
                'A' => if (ctrl) return w.SendMessageW(edit, 0xB1, 0, -1),
                'L' => if (ctrl and isTerm()) {
                    term.clear();
                    return ret(relayout());
                },
                'C' => if (ctrl and selEmpty()) {
                    if (isTerm()) term.kill() else copyPath();
                    return 0;
                },
                else => {},
            }
        },
        0x0102 => { // WM_CHAR: swallow keys handled above (no beep), Ctrl+Backspace deletes a word
            switch (wp) {
                0x0D, 0x0A, 0x09, 0x1B, 0x01, 0x0C => return 0,
                0x7F => return ret(deleteWord()),
                else => {},
            }
        },
        0x020A => return w.SendMessageW(hwnd, msg, wp, lp), // WM_MOUSEWHEEL
        0x000F => { // WM_PAINT: draw the placeholder over the empty field
            const r = w.CallWindowProcW(edit_proc, h, msg, wp, lp);
            if (w.GetWindowTextLengthW(h) == 0) {
                const dc = w.GetDC(h);
                var rc = w.RECT{};
                _ = w.GetClientRect(h, &rc);
                rc.left += px(2);
                _ = w.SetBkMode(dc, 1);
                drawText(dc, placeholder(), rc, C_FAINT, f_input, DT_LEFT);
                _ = w.ReleaseDC(h, dc);
            }
            return r;
        },
        else => {},
    }
    return w.CallWindowProcW(edit_proc, h, msg, wp, lp);
}

fn ret(_: void) w.LRESULT {
    return 0;
}

fn click(x: i32, y: i32) void {
    var i: i32 = 0;
    while (i < 4) : (i += 1) {
        const r = chipRect(i);
        if (x >= r.left and x < r.right and y >= r.top - px(6) and y < r.bottom + px(6))
            return setMode(@enumFromInt(i));
    }
    if (isTerm()) return;
    const y0 = px(INPUT_H) + 1 + px(6);
    if (y < y0) return;
    const idx = top + @as(usize, @intCast(@divTrunc(y - y0, px(ROW_H))));
    if (idx < rowCount() and idx < top + MAX_ROWS) {
        sel = idx;
        activate(down(0x11), down(0x10));
    }
}

// ---------------------------------------------------------------- tray, hotkey, autostart

const RUN_KEY = L("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
const HKCU: usize = 0xFFFFFFFF80000001;

fn autostartOn() bool {
    var key: w.H = null;
    if (w.RegCreateKeyExW(HKCU, RUN_KEY, 0, null, 0, 0x1, null, &key, null) != 0) return false;
    defer _ = w.RegCloseKey(key);
    return w.RegQueryValueExW(key, L("Ter"), null, null, null, null) == 0;
}

fn toggleAutostart() void {
    const on = autostartOn();
    var key: w.H = null;
    if (w.RegCreateKeyExW(HKCU, RUN_KEY, 0, null, 0, 0x2, null, &key, null) != 0) return;
    defer _ = w.RegCloseKey(key);
    if (on) {
        _ = w.RegDeleteValueW(key, L("Ter"));
        return;
    }
    var val: [600]u16 = undefined;
    val[0] = '"';
    const n = w.GetModuleFileNameW(null, val[1..].ptr, 500);
    const tail = L("\" --hidden");
    @memcpy(val[1 + n ..][0..tail.len], tail);
    val[1 + n + tail.len] = 0;
    _ = w.RegSetValueExW(key, L("Ter"), 0, 1, @ptrCast(&val), @intCast((2 + n + tail.len) * 2));
}

fn makeIcon() w.H {
    const screen = w.GetDC(null);
    const dc = w.CreateCompatibleDC(screen);
    const color = w.CreateCompatibleBitmap(screen, 32, 32);
    const mask = w.CreateBitmap(32, 32, 1, 1, null);
    const full = w.RECT{ .left = 0, .top = 0, .right = 32, .bottom = 32 };

    var old = w.SelectObject(dc, mask);
    _ = w.PatBlt(dc, 0, 0, 32, 32, 0x00FF0062); // WHITENESS = transparent
    pill(dc, .{ .left = 1, .top = 1, .right = 30, .bottom = 30 }, 0, 12);
    _ = w.SelectObject(dc, color);
    _ = w.PatBlt(dc, 0, 0, 32, 32, 0x00000042); // BLACKNESS
    pill(dc, .{ .left = 1, .top = 1, .right = 30, .bottom = 30 }, accent(.app), 12);
    const font = w.CreateFontW(-24, 0, 0, 0, 800, 0, 0, 0, 1, 0, 0, 4, 0, L("Consolas"));
    _ = w.SetBkMode(dc, 1);
    drawText(dc, L(">"), full, w.rgb(255, 255, 255), font, DT_LEFT | 0x1);
    old = w.SelectObject(dc, old);
    _ = w.DeleteObject(font);
    _ = w.DeleteDC(dc);
    _ = w.ReleaseDC(null, screen);

    var ii = w.ICONINFO{ .hbmMask = mask, .hbmColor = color };
    const icon = w.CreateIconIndirect(&ii);
    _ = w.DeleteObject(mask);
    _ = w.DeleteObject(color);
    return icon;
}

var nid: w.NOTIFYICONDATAW = .{};

fn addTray() void {
    nid.hWnd = hwnd;
    nid.uID = 1;
    nid.uFlags = 1 | 2 | 4;
    nid.uCallbackMessage = WM_TRAY;
    nid.hIcon = w.LoadIconW(hinst, 1) orelse makeIcon(); // icon resource, else drawn at runtime
    const tip = L("Ter — ");
    @memcpy(nid.szTip[0..tip.len], tip);
    @memcpy(nid.szTip[tip.len..][0..hotkey_name.len], hotkey_name);
    _ = w.Shell_NotifyIconW(0, &nid);
}

fn trayMenu() void {
    const menu = w.CreatePopupMenu();
    _ = w.AppendMenuW(menu, 0, 1, L("Mở Ter"));
    _ = w.AppendMenuW(menu, 0, 2, L("Quét lại file"));
    _ = w.AppendMenuW(menu, if (pinned) 8 else 0, 5, L("Luôn hiện trên desktop"));
    _ = w.AppendMenuW(menu, if (pos_set) 0 else 1, 6, L("Đặt lại vị trí"));
    _ = w.AppendMenuW(menu, if (autostartOn()) 8 else 0, 3, L("Chạy cùng Windows"));
    _ = w.AppendMenuW(menu, 0x800, 0, null);
    _ = w.AppendMenuW(menu, 0, 4, L("Thoát"));
    var pt = w.POINT{};
    _ = w.GetCursorPos(&pt);
    _ = w.SetForegroundWindow(hwnd);
    const cmd = w.TrackPopupMenu(menu, 0x100 | 0x2, pt.x, pt.y, 0, hwnd, null);
    _ = w.DestroyMenu(menu);
    switch (cmd) {
        1 => show(),
        2 => files.reindex(),
        3 => toggleAutostart(),
        4 => _ = w.DestroyWindow(hwnd),
        5 => setPinned(!pinned),
        6 => resetPosition(),
        else => {},
    }
}

fn registerHotkey() void {
    const Combo = struct { mods: u32, vk: u32, name: []const u16 };
    const combos = [_]Combo{
        .{ .mods = 1, .vk = 0x20, .name = L("Alt+Space") },
        .{ .mods = 1, .vk = 0xC0, .name = L("Alt+`") },
        .{ .mods = 3, .vk = 0x20, .name = L("Ctrl+Alt+Space") },
    };
    for (combos) |c| {
        if (w.RegisterHotKey(hwnd, 1, c.mods | 0x4000, c.vk) != 0) {
            hotkey_name = c.name;
            return;
        }
    }
    hotkey_name = L("Mở từ khay hệ thống");
}

// ---------------------------------------------------------------- window

fn wndProc(h: w.H, msg: u32, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) w.LRESULT {
    switch (msg) {
        0x000F => { // WM_PAINT
            var ps = w.PAINTSTRUCT{};
            const dc = w.BeginPaint(h, &ps);
            paint(dc);
            _ = w.EndPaint(h, &ps);
            return 0;
        },
        0x0014 => return 1, // WM_ERASEBKGND
        0x0133 => { // WM_CTLCOLOREDIT
            const dc: w.H = @ptrFromInt(wp);
            _ = w.SetTextColor(dc, C_TEXT);
            _ = w.SetBkColor(dc, 0);
            return @bitCast(@intFromPtr(w.GetStockObject(4))); // BLACK_BRUSH = clear glass
        },
        0x0111 => { // WM_COMMAND: EN_CHANGE
            if ((wp >> 16) & 0xFFFF == 0x0300) refresh();
            return 0;
        },
        0x0006 => { // WM_ACTIVATE: losing focus closes the overlay (or rests it on the desktop)
            if (wp & 0xFFFF == 0) {
                hide();
            } else {
                _ = w.SetWindowPos(h, w.INVALID, 0, 0, 0, 0, 0x1 | 0x2 | 0x10); // in use: stay on top
            }
            return 0;
        },
        0x0007 => { // WM_SETFOCUS
            _ = w.SetFocus(edit);
            return 0;
        },
        0x0084 => { // WM_NCHITTEST: grab zones behave like a title bar, so Windows does the dragging
            var pt = w.POINT{ .x = @as(i16, @truncate(lp)), .y = @as(i16, @truncate(lp >> 16)) };
            _ = w.ScreenToClient(h, &pt);
            return if (isDragZone(pt.x, pt.y)) 2 else 1; // HTCAPTION : HTCLIENT
        },
        0x0232 => { // WM_EXITSIZEMOVE
            savePosition();
            _ = w.SetFocus(edit);
            return 0;
        },
        0x0201 => { // WM_LBUTTONDOWN
            click(@as(i16, @truncate(lp)), @as(i16, @truncate(lp >> 16)));
            _ = w.SetFocus(edit);
            return 0;
        },
        0x020A => { // WM_MOUSEWHEEL
            const delta: i16 = @bitCast(@as(u16, @truncate(wp >> 16)));
            const step: i32 = if (delta > 0) 1 else -1;
            if (isTerm()) scrollTerm(step * 3) else moveSel(-step);
            return 0;
        },
        0x0312 => return ret(toggle()), // WM_HOTKEY
        0x0113 => { // WM_TIMER 2: pinned upkeep; 1: live progress while the disks are scanned
            if (wp == 2) {
                keepOnDesktop();
                return 0;
            }
            if (w.IsWindowVisible(h) != 0 and mode == .file and files.indexing) {
                if (qkey.len > 0) file_gen = files.request(qkey.items());
                _ = w.InvalidateRect(h, null, 0);
            }
            return 0;
        },
        WM_SHOWME => { // wParam 1..4 optionally picks the mode
            if (wp >= 1 and wp <= 4) setMode(@enumFromInt(wp - 1));
            show();
            return 0;
        },
        WM_TRAY => {
            if (lp == 0x0202) toggle();
            if (lp == 0x0205) trayMenu();
            return 0;
        },
        WM_APPS => {
            apps.adopt(@ptrFromInt(@as(usize, @bitCast(lp))));
            if (mode == .app) refresh();
            return 0;
        },
        WM_FILES => {
            const s: *u.Set = @ptrFromInt(@as(usize, @bitCast(lp)));
            if (mode != .file or wp != file_gen or qkey.len == 0) {
                s.destroy();
                return 0;
            }
            // Keep the highlighted row when a rescan delivers the same list again.
            const keep_sel = sel;
            const keep_top = top;
            const same = set != null and set.?.rows.len == s.rows.len;
            replaceSet(s);
            if (same) {
                sel = keep_sel;
                top = keep_top;
            }
            file_wait = false;
            relayout();
            return 0;
        },
        WM_INDEXED => {
            if (mode == .file and qkey.len > 0) file_gen = files.request(qkey.items());
            _ = w.InvalidateRect(h, null, 0);
            return 0;
        },
        WM_TDATA, WM_TDONE => {
            const before = contentHeight();
            if (msg == WM_TDATA) term.onData(wp, @ptrFromInt(@as(usize, @bitCast(lp)))) else term.onDone(wp, @truncate(@as(usize, @bitCast(lp))));
            if (contentHeight() != before) relayout() else _ = w.InvalidateRect(h, null, 0);
            return 0;
        },
        0x0002 => { // WM_DESTROY
            _ = w.Shell_NotifyIconW(2, &nid);
            term.kill();
            w.PostQuitMessage(0);
            return 0;
        },
        else => {},
    }
    return w.DefWindowProcW(h, msg, wp, lp);
}

/// Create a font, preferring the Windows 11 face and falling back when it is not installed.
fn mkFont(size: i32, weight: i32, face: w.WSTR, fallback: w.WSTR) w.H {
    const f = w.CreateFontW(-px(size), 0, 0, 0, weight, 0, 0, 0, 1, 0, 0, 5, 0, face);
    const dc = w.GetDC(null);
    defer _ = w.ReleaseDC(null, dc);
    const old = w.SelectObject(dc, f);
    var got: [64]u16 = undefined;
    const n = w.GetTextFaceW(dc, got.len, &got);
    _ = w.SelectObject(dc, old);
    if (n > 0 and u.eqlCI(u.sliceZ(&got), u.sliceZ(face))) return f;
    _ = w.DeleteObject(f);
    return w.CreateFontW(-px(size), 0, 0, 0, weight, 0, 0, 0, 1, 0, 0, 5, 0, fallback);
}

fn hasArg(needle: []const u16) bool {
    const cl = u.sliceZ(w.GetCommandLineW());
    var i: usize = 0;
    while (i + needle.len <= cl.len) : (i += 1) {
        if (u.eqlCI(cl[i..][0..needle.len], needle)) return true;
    }
    return false;
}

/// `ter.exe --uninstall`: undo everything the installer did (it is the entry in "Installed apps").
fn uninstall() void {
    const silent = hasArg(L("--silent"));
    if (!silent and w.MessageBoxW(null, L("Gỡ Ter khỏi máy này?"), L("Ter"), 0x4 | 0x20) != 6) return;

    const other = w.FindWindowW(CLASS, null);
    if (other != null) {
        _ = w.PostMessageW(other, 0x0010, 0, 0); // WM_CLOSE
        w.Sleep(800);
    }

    var buf: [700]u16 = undefined;
    var env: [300]u16 = undefined;
    _ = w.DeleteFileW(u.join(&buf, &.{ u.envVar(L("APPDATA"), &env), u.START_MENU_LNK }));

    var key: w.H = null;
    if (w.RegCreateKeyExW(u.HKCU, u.RUN_KEY, 0, null, 0, 0x2, null, &key, null) == 0) {
        _ = w.RegDeleteValueW(key, L("Ter"));
        _ = w.RegCloseKey(key);
    }
    _ = w.RegDeleteKeyW(u.HKCU, u.APP_KEY);
    _ = w.RegDeleteKeyW(u.HKCU, u.UNINSTALL_KEY);

    if (!silent) _ = w.MessageBoxW(null, L("Đã gỡ Ter."), L("Ter"), 0x40);

    // Delete the program folder once this process has exited. Only ever the folder the
    // installer created (...\Programs\Ter) — never wherever a dev build happens to sit.
    var exe: [600]u16 = undefined;
    var n: usize = w.GetModuleFileNameW(null, &exe, exe.len);
    while (n > 0 and exe[n - 1] != '\\') n -= 1;
    if (n < 2) return;
    const dir = exe[0 .. n - 1];
    if (!u.endsWithCI(dir, L("\\Programs\\Ter"))) return;
    var cl: [900]u16 = undefined;
    const line = u.join(&cl, &.{ L("cmd.exe /c ping 127.0.0.1 -n 3 >nul & rmdir /s /q \""), dir, L("\"") });
    const root = u.join(&buf, &.{u.envVar(L("SystemRoot"), &env)});
    var si = w.STARTUPINFOW{};
    var pi = w.PROCESS_INFORMATION{};
    if (w.CreateProcessW(null, line.ptr, null, null, 0, 0x08000000, null, root, &si, &pi) != 0) {
        _ = w.CloseHandle(pi.hThread);
        _ = w.CloseHandle(pi.hProcess);
    }
}

pub fn main() void {
    if (hasArg(L("--uninstall"))) return uninstall();
    _ = w.CreateMutexW(null, 0, L("Ter.SingleInstance"));
    if (w.GetLastError() == 183) { // already running: just bring it up
        const other = w.FindWindowW(CLASS, null);
        if (other != null) _ = w.PostMessageW(other, WM_SHOWME, 0, 0);
        return;
    }

    _ = w.SetProcessDpiAwarenessContext(-2);
    _ = w.CoInitializeEx(null, 2);
    hinst = w.GetModuleHandleW(null);
    dpi = @intCast(w.GetDpiForSystem());

    f_input = mkFont(24, 400, L("Segoe UI Variable Display"), L("Segoe UI"));
    f_title = mkFont(15, 500, L("Segoe UI Variable Text"), L("Segoe UI"));
    f_small = mkFont(12, 400, L("Segoe UI Variable Small"), L("Segoe UI"));
    f_bold = mkFont(12, 600, L("Segoe UI Variable Small"), L("Segoe UI"));
    f_mono = mkFont(14, 400, L("Cascadia Mono"), L("Consolas"));
    f_icon = mkFont(18, 400, L("Segoe Fluent Icons"), L("Segoe MDL2 Assets"));

    var sfi = w.SHFILEINFOW{};
    himl = w.SHGetFileInfoW(L("C:\\"), 0x10, &sfi, @sizeOf(w.SHFILEINFOW), 0x4000 | 0x10);
    var icx: i32 = 32;
    var icy: i32 = 32;
    if (himl != 0 and w.ImageList_GetIconSize(himl, &icx, &icy) != 0) icon_px = icx;

    const wc = w.WNDCLASSEXW{
        .lpfnWndProc = wndProc,
        .hInstance = hinst,
        .hCursor = w.LoadCursorW(null, 32512),
        .lpszClassName = CLASS,
    };
    _ = w.RegisterClassExW(&wc);
    // tool window (no taskbar button) + topmost; popup + clip children
    hwnd = w.CreateWindowExW(0x80 | 0x8, CLASS, L("Ter"), 0x80000000 | 0x02000000, 0, 0, px(WIN_W), px(INPUT_H + FOOT_H), null, null, hinst, null);

    const dark: u32 = 1;
    const round: u32 = 2;
    const border: u32 = C_SEP;
    _ = w.DwmSetWindowAttribute(hwnd, 20, &dark, 4);
    _ = w.DwmSetWindowAttribute(hwnd, 33, &round, 4);
    _ = w.DwmSetWindowAttribute(hwnd, 34, &border, 4);
    // Frosted glass: blurred acrylic behind the window, tinted dark (colour is 0xAABBGGRR).
    // The documented DWMWA_SYSTEMBACKDROP_TYPE does not apply to caption-less popups,
    // so this uses the accent policy the Windows shell itself uses for its flyouts.
    const policy = w.ACCENT_POLICY{ .state = 4, .flags = 2, .color = GLASS_TINT };
    const data = w.WINCOMPATTRDATA{ .attrib = 19, .data = &policy, .size = @sizeOf(w.ACCENT_POLICY) };
    _ = w.SetWindowCompositionAttribute(hwnd, &data);

    // measure fonts
    const dc = w.GetDC(hwnd);
    var sz = w.SIZE{};
    _ = w.SelectObject(dc, f_mono);
    _ = w.GetTextExtentPoint32W(dc, L("M"), 1, &sz);
    line_h = sz.cy + px(2);
    term.cols = @intCast(@max(20, @divTrunc(px(WIN_W) - px(PAD) - px(10), @max(sz.cx, 1))));
    _ = w.SelectObject(dc, f_input);
    _ = w.GetTextExtentPoint32W(dc, L("Ag"), 2, &sz);
    _ = w.ReleaseDC(hwnd, dc);

    const ex = px(PAD + 34);
    const ew = chipRect(0).left - px(10) - ex;
    edit = w.CreateWindowExW(0, L("EDIT"), null, 0x40000000 | 0x10000000 | 0x80, ex, @divTrunc(px(INPUT_H) - sz.cy, 2), ew, sz.cy, hwnd, null, hinst, null);
    _ = w.SendMessageW(edit, 0x30, @intFromPtr(f_input), 1); // WM_SETFONT
    _ = w.SendMessageW(edit, 0xC5, 500, 0); // EM_LIMITTEXT
    edit_proc = w.SetWindowLongPtrW(edit, -4, @intFromPtr(&editProc));

    registerHotkey();
    addTray();
    term.init(hwnd, WM_TDATA, WM_TDONE);
    apps.startLoad(hwnd, WM_APPS);
    files.start(hwnd, WM_FILES, WM_INDEXED);
    _ = w.SetTimer(hwnd, 1, 600, null);

    _ = w.SetTimer(hwnd, 2, 300, null);
    loadSettings();
    if (!hasArg(L("--hidden"))) show() else if (pinned) showResting();

    var msg = w.MSG{};
    while (w.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = w.TranslateMessage(&msg);
        _ = w.DispatchMessageW(&msg);
    }
}
