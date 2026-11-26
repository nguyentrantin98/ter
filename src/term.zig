//! Command runner for CMD / PowerShell: output is piped into a scrollback buffer.
const w = @import("w.zig");
const u = @import("util.zig");
const L = u.L;

pub const Shell = enum { cmd, ps };
pub const LineKind = enum(u8) { out, cmd, info, err };

pub const Line = struct { ptr: [*]u16, len: u32, kind: LineKind };

var lines: u.List(Line) = .{};
var cur: u.List(u16) = .{};
pub var cols: usize = 100;
/// Lines scrolled up from the bottom.
pub var scroll: usize = 0;
pub var running: bool = false;

var hwnd: w.H = null;
var msg_data: u32 = 0;
var msg_done: u32 = 0;
var gen: u32 = 0;
var job: w.H = null;
var pending: u32 = 0;
var killed: bool = false;

// stream decoder state
var esc: u8 = 0;
var cr: bool = false;
var u8_need: u8 = 0;
var u8_cp: u32 = 0;

var cwd_buf: [1024]u16 = undefined;
var cwd_len: usize = 0;

var ps_exe_buf: [300]u16 = undefined;
var ps_exe: []const u16 = L("powershell.exe");

pub var history: u.List([:0]u16) = .{};

pub fn init(h: w.H, data_msg: u32, done_msg: u32) void {
    hwnd = h;
    msg_data = data_msg;
    msg_done = done_msg;
    var buf: [300]u16 = undefined;
    const home = u.envVar(L("USERPROFILE"), &buf);
    if (home.len > 0) {
        buf[home.len] = 0;
        _ = w.SetCurrentDirectoryW(@ptrCast(&buf));
    }
    refreshCwd();
    const n = w.SearchPathW(null, L("pwsh.exe"), null, ps_exe_buf.len, &ps_exe_buf, null);
    if (n > 0 and n < ps_exe_buf.len) ps_exe = ps_exe_buf[0..n];
}

fn refreshCwd() void {
    cwd_len = w.GetCurrentDirectoryW(cwd_buf.len, &cwd_buf);
    if (cwd_len >= cwd_buf.len) cwd_len = 0;
}

pub fn cwd() []const u16 {
    return cwd_buf[0..cwd_len];
}

pub fn lineCount() usize {
    return lines.len + @as(usize, if (cur.len > 0) 1 else 0);
}

pub fn getLine(i: usize) Line {
    if (i < lines.len) return lines.items()[i];
    return .{ .ptr = cur.ptr.?, .len = @intCast(cur.len), .kind = .out };
}

pub fn clear() void {
    for (lines.items()) |l| u.free(l.ptr);
    lines.clear();
    cur.clear();
    scroll = 0;
}

fn pushLine(s: []const u16, kind: LineKind) void {
    if (lines.len >= 5000) {
        const drop = 1000;
        const items = lines.items();
        for (items[0..drop]) |l| u.free(l.ptr);
        for (items[drop..], 0..) |l, i| items[i] = l;
        lines.len -= drop;
    }
    const d = u.dupZ(s);
    lines.push(.{ .ptr = d.ptr, .len = @intCast(s.len), .kind = kind });
    if (scroll > 0) scroll += 1; // keep the viewport still while reading history
}

/// Add a status line, wrapping long text.
pub fn say(s: []const u16, kind: LineKind) void {
    flushCur();
    var rest = s;
    while (rest.len > cols) {
        pushLine(rest[0..cols], kind);
        rest = rest[cols..];
    }
    pushLine(rest, kind);
}

fn flushCur() void {
    if (cur.len == 0) return;
    pushLine(cur.items(), .out);
    cur.clear();
}

fn putChar(c: u16) void {
    if (cr) {
        cur.clear(); // a lone CR rewinds the line (progress bars)
        cr = false;
    }
    if (cur.len >= cols) {
        pushLine(cur.items(), .out);
        cur.clear();
    }
    cur.push(c);
}

fn feed(data: []const u8) void {
    for (data) |b| {
        switch (esc) {
            1 => {
                esc = if (b == '[') 2 else if (b == ']') 3 else 0;
                continue;
            },
            2 => { // CSI ... final byte
                if (b >= 0x40 and b <= 0x7E) esc = 0;
                continue;
            },
            3 => { // OSC ... BEL or ESC
                if (b == 7) esc = 0;
                if (b == 0x1B) esc = 1;
                continue;
            },
            else => {},
        }
        if (u8_need > 0) {
            if (b & 0xC0 == 0x80) {
                u8_cp = (u8_cp << 6) | (b & 0x3F);
                u8_need -= 1;
                if (u8_need == 0) {
                    if (u8_cp >= 0x10000) {
                        const v = u8_cp - 0x10000;
                        putChar(@intCast(0xD800 + (v >> 10)));
                        putChar(@intCast(0xDC00 + (v & 0x3FF)));
                    } else putChar(@intCast(u8_cp));
                }
                continue;
            }
            u8_need = 0; // broken sequence: fall through and treat b normally
        }
        switch (b) {
            0x1B => esc = 1,
            '\n' => {
                if (cur.len == 0) pushLine(&.{}, .out) else flushCur();
                cr = false;
            },
            '\r' => cr = true,
            '\t' => {
                putChar(' ');
                while (cur.len % 8 != 0 and cur.len < cols) putChar(' ');
            },
            8 => {
                if (cur.len > 0) cur.len -= 1;
            },
            0...7, 11...12, 14...0x1A, 0x1C...0x1F => {},
            0x20...0x7F => putChar(b),
            0xC0...0xDF => {
                u8_need = 1;
                u8_cp = b & 0x1F;
            },
            0xE0...0xEF => {
                u8_need = 2;
                u8_cp = b & 0x0F;
            },
            0xF0...0xF7 => {
                u8_need = 3;
                u8_cp = b & 0x07;
            },
            else => putChar('?'),
        }
    }
}

// ---------------------------------------------------------------- UI-thread message handlers

/// Block layout posted by the reader thread: u32 length + bytes.
pub fn onData(g: usize, block: ?*anyopaque) void {
    const p: [*]u8 = @ptrCast(block.?);
    _ = @atomicRmw(u32, &pending, .Sub, 1, .seq_cst);
    if (g == gen) {
        const n = @as(*align(1) const u32, @ptrCast(p)).*;
        feed(p[4..][0..n]);
    }
    u.free(block);
}

pub fn onDone(g: usize, code: u32) void {
    if (g != gen) return;
    running = false;
    if (job != null) {
        _ = w.CloseHandle(job);
        job = null;
    }
    flushCur();
    if (killed) {
        say(L("■ Đã dừng"), .info);
    } else if (code != 0) {
        var buf: [40]u16 = undefined;
        const pre = L("✗ Lỗi, mã ");
        @memcpy(buf[0..pre.len], pre);
        var n: usize = pre.len;
        var digits: [12]u16 = undefined;
        var k: usize = 0;
        var v = code;
        while (true) {
            digits[k] = '0' + @as(u16, @intCast(v % 10));
            k += 1;
            v /= 10;
            if (v == 0) break;
        }
        while (k > 0) {
            k -= 1;
            buf[n] = digits[k];
            n += 1;
        }
        say(buf[0..n], .err);
    }
}

pub fn kill() void {
    if (running and job != null) {
        killed = true;
        _ = w.TerminateJobObject(job, 1);
    }
}

// ---------------------------------------------------------------- running commands

const b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// PowerShell -EncodedCommand payload: base64 of the UTF-16LE script. Avoids all quoting issues.
fn pushEncoded(out: *u.List(u16), script: []const u16) void {
    const bytes: []const u8 = @as([*]const u8, @ptrCast(script.ptr))[0 .. script.len * 2];
    var i: usize = 0;
    while (i < bytes.len) : (i += 3) {
        const b0: u32 = bytes[i];
        const b1: u32 = if (i + 1 < bytes.len) bytes[i + 1] else 0;
        const b2: u32 = if (i + 2 < bytes.len) bytes[i + 2] else 0;
        const v = (b0 << 16) | (b1 << 8) | b2;
        out.push(b64[(v >> 18) & 63]);
        out.push(b64[(v >> 12) & 63]);
        out.push(if (i + 1 < bytes.len) b64[(v >> 6) & 63] else '=');
        out.push(if (i + 2 < bytes.len) b64[v & 63] else '=');
    }
}

/// Quote one argument the way CommandLineToArgvW expects.
fn pushQuotedArg(out: *u.List(u16), s: []const u16) void {
    out.push('"');
    var slashes: usize = 0;
    for (s) |ch| {
        if (ch == '\\') {
            slashes += 1;
        } else {
            if (ch == '"') {
                for (0..slashes + 1) |_| out.push('\\');
            }
            slashes = 0;
        }
        out.push(ch);
    }
    for (0..slashes) |_| out.push('\\');
    out.push('"');
}

fn pushPsExe(out: *u.List(u16)) void {
    out.push('"');
    out.appendSlice(ps_exe);
    out.push('"');
}

/// Handles `cd` ourselves so the folder sticks between commands. Returns true when consumed.
fn tryCd(text: []const u16) bool {
    var arg: []const u16 = undefined;
    if (text.len == 2 and text[1] == ':') {
        arg = text;
    } else {
        const kws = [_][]const u16{ L("cd"), L("chdir"), L("set-location"), L("sl") };
        var hit: ?usize = null;
        for (kws) |kw| {
            if (!u.startsWithCI(text, kw)) continue;
            if (text.len == kw.len) {
                hit = kw.len;
                break;
            }
            const c = text[kw.len];
            if (c == ' ' or ((c == '.' or c == '\\' or c == '/') and kw.len == 2 and u.lower16(text[0]) == 'c')) {
                hit = kw.len;
                break;
            }
        }
        arg = u.trim16(text[(hit orelse return false)..]);
        if (u.startsWithCI(arg, L("/d "))) arg = u.trim16(arg[3..]);
        if (arg.len >= 2 and (arg[0] == '"' or arg[0] == '\'') and arg[arg.len - 1] == arg[0]) arg = arg[1 .. arg.len - 1];
        for (arg) |c| if (c == '&' or c == '|' or c == ';' or c == '"') return false;
    }
    if (arg.len == 0) {
        say(cwd(), .out);
        return true;
    }
    var buf: [1100]u16 = undefined;
    var n: usize = 0;
    if (arg[0] == '~') {
        n = u.envVar(L("USERPROFILE"), buf[0..300]).len;
        arg = arg[1..];
    }
    if (n + arg.len + 2 >= buf.len) return false;
    @memcpy(buf[n..][0..arg.len], arg);
    n += arg.len;
    if (n == 2 and buf[1] == ':') {
        buf[n] = '\\';
        n += 1;
    }
    buf[n] = 0;
    if (w.SetCurrentDirectoryW(@ptrCast(&buf)) != 0) {
        refreshCwd();
    } else {
        say(L("✗ Không thấy thư mục"), .err);
    }
    return true;
}

const Ctx = struct { rd: w.H, proc: w.H, gen: u32 };

fn readerThread(param: ?*anyopaque) callconv(.winapi) u32 {
    const c: *Ctx = @ptrCast(@alignCast(param.?));
    var buf: [16384]u8 = undefined;
    while (true) {
        var n: u32 = 0;
        if (w.ReadFile(c.rd, &buf, buf.len, &n, null) == 0 or n == 0) break;
        // Back-pressure so a chatty command cannot flood the message queue.
        while (@atomicLoad(u32, &pending, .seq_cst) > 32) w.Sleep(2);
        const blk = u.alloc(4 + n);
        @as(*align(1) u32, @ptrCast(blk)).* = n;
        @memcpy(blk[4..][0..n], buf[0..n]);
        _ = @atomicRmw(u32, &pending, .Add, 1, .seq_cst);
        _ = w.PostMessageW(hwnd, msg_data, c.gen, @bitCast(@intFromPtr(blk)));
    }
    _ = w.WaitForSingleObject(c.proc, 0xFFFFFFFF);
    var code: u32 = 0;
    _ = w.GetExitCodeProcess(c.proc, &code);
    _ = w.CloseHandle(c.rd);
    _ = w.CloseHandle(c.proc);
    _ = w.PostMessageW(hwnd, msg_done, c.gen, code);
    u.free(c);
    return 0;
}

/// Run `raw` in the given shell, streaming output into the scrollback.
pub fn run(shell: Shell, raw: []const u16) void {
    const text = u.trim16(raw);
    if (text.len == 0) return;
    if (running) {
        say(L("Đang chạy lệnh khác — Ctrl+C để dừng"), .info);
        return;
    }
    scroll = 0;
    var echo: u.List(u16) = .{};
    defer echo.deinit();
    echo.appendSlice(L("❯ "));
    echo.appendSlice(text);
    say(echo.items(), .cmd);

    if (u.eqlCI(text, L("cls")) or u.eqlCI(text, L("clear"))) return clear();
    if (tryCd(text)) return;

    var cl: u.List(u16) = .{};
    defer cl.deinit();
    switch (shell) {
        .cmd => {
            // cmd only picks up a new code page when it starts, so switch to UTF-8 in an outer
            // shell and run the command in an inner one. The user's text sits inside our quotes:
            // whatever its own quotes expose to the outer shell gets caret-escaped.
            cl.appendSlice(L("cmd.exe /d /s /c \"chcp 65001>nul & cmd.exe /d /s /c \""));
            var quoted = true;
            for (text) |ch| {
                if (ch == '"') quoted = !quoted;
                if (!quoted and (ch == '&' or ch == '|' or ch == '<' or ch == '>' or ch == '^' or ch == '(' or ch == ')')) cl.push('^');
                cl.push(ch);
            }
            cl.appendSlice(L("\"\""));
        },
        .ps => {
            var script: u.List(u16) = .{};
            defer script.deinit();
            script.appendSlice(L("[Console]::OutputEncoding=[Text.Encoding]::UTF8;$ProgressPreference='SilentlyContinue'\n"));
            script.appendSlice(text);
            pushPsExe(&cl);
            // -Command (not -EncodedCommand) keeps errors as plain text instead of CLIXML.
            cl.appendSlice(L(" -NoLogo -NoProfile -NonInteractive -Command "));
            pushQuotedArg(&cl, script.items());
        },
    }
    cl.push(0);

    var sa = w.SECURITY_ATTRIBUTES{ .bInheritHandle = 1 };
    var rd: w.H = null;
    var wr: w.H = null;
    if (w.CreatePipe(&rd, &wr, &sa, 1 << 16) == 0) return say(L("✗ Không tạo được pipe"), .err);
    _ = w.SetHandleInformation(rd, 1, 0);
    const nul = w.CreateFileW(L("NUL"), 0x80000000, 3, &sa, 3, 0, null);

    var si = w.STARTUPINFOW{ .dwFlags = 0x100, .hStdInput = nul, .hStdOutput = wr, .hStdError = wr };
    var pi = w.PROCESS_INFORMATION{};
    // CREATE_NO_WINDOW | CREATE_SUSPENDED: join the job before the child can spawn anything.
    const ok = w.CreateProcessW(null, cl.ptr, null, null, 1, 0x08000000 | 0x4, null, null, &si, &pi);
    _ = w.CloseHandle(wr);
    _ = w.CloseHandle(nul);
    if (ok == 0) {
        _ = w.CloseHandle(rd);
        return say(L("✗ Không chạy được lệnh"), .err);
    }
    job = w.CreateJobObjectW(null, null);
    _ = w.AssignProcessToJobObject(job, pi.hProcess);
    _ = w.ResumeThread(pi.hThread);
    _ = w.CloseHandle(pi.hThread);

    gen +%= 1;
    running = true;
    killed = false;
    esc = 0;
    cr = false;
    u8_need = 0;
    const c: *Ctx = @ptrCast(@alignCast(u.alloc(@sizeOf(Ctx))));
    c.* = .{ .rd = rd, .proc = pi.hProcess, .gen = gen };
    _ = w.CloseHandle(w.CreateThread(null, 0, readerThread, c, 0, null));
}

/// Open a real console window in the current folder (optionally elevated), running `raw` if given.
pub fn openExternal(shell: Shell, raw: []const u16, admin: bool) void {
    const text = u.trim16(raw);
    var params: u.List(u16) = .{};
    var file: u.List(u16) = .{};
    defer params.deinit();
    defer file.deinit();
    switch (shell) {
        .cmd => {
            file.appendSlice(L("cmd.exe"));
            params.appendSlice(L("/k cd /d \""));
            params.appendSlice(cwd());
            params.push('"');
            if (text.len > 0) {
                params.appendSlice(L(" & "));
                params.appendSlice(text);
            }
        },
        .ps => {
            file.appendSlice(ps_exe);
            var script: u.List(u16) = .{};
            defer script.deinit();
            script.appendSlice(L("Set-Location -LiteralPath '"));
            for (cwd()) |ch| {
                if (ch == '\'') script.push('\'');
                script.push(ch);
            }
            script.appendSlice(L("';"));
            script.appendSlice(text);
            params.appendSlice(L("-NoLogo -NoExit -EncodedCommand "));
            pushEncoded(&params, script.items());
        },
    }
    file.push(0);
    params.push(0);
    var dir: [1025]u16 = undefined;
    @memcpy(dir[0..cwd_len], cwd());
    dir[cwd_len] = 0;
    _ = u.shell(if (admin) L("runas") else L("open"), @ptrCast(file.ptr.?), @ptrCast(params.ptr.?), @ptrCast(&dir));
}

pub fn remember(raw: []const u16) void {
    const text = u.trim16(raw);
    if (text.len == 0) return;
    const items = history.items();
    if (items.len > 0 and u.eqlCI(items[items.len - 1], text)) return;
    history.push(u.dupZ(text));
}
