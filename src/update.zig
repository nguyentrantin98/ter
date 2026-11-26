//! Updates from GitHub Releases. The installed copy asks for the latest release now and
//! then; when its tag is newer than VERSION, the release's ter-setup.exe is downloaded and
//! run with --update, which replaces ter.exe quietly and starts it again.
const std = @import("std");
const w = @import("w.zig");
const u = @import("util.zig");
const L = u.L;

const HOST_API = L("api.github.com");
const LATEST = L("/repos/" ++ u.REPO ++ "/releases/latest");
const ASSET = "/ter-setup.exe";

pub const Result = enum(usize) { latest, installing, failed, not_installed };

var busy = std.atomic.Value(bool).init(false);
var reply_hwnd: w.H = null;
var reply_msg: u32 = 0;

/// Look for a newer release in the background. With `manual`, the outcome is posted back
/// to `hwnd` as `msg` (wParam = Result) so it can be shown; otherwise it stays silent.
pub fn check(hwnd: w.H, msg: u32, manual: bool) void {
    if (busy.swap(true, .acq_rel)) return; // one check at a time
    reply_hwnd = hwnd;
    reply_msg = msg;
    const h = w.CreateThread(null, 0, run, @ptrFromInt(@intFromBool(manual)), 0, null);
    if (h == null) {
        busy.store(false, .release);
        return;
    }
    _ = w.CloseHandle(h);
}

fn run(arg: ?*anyopaque) callconv(.winapi) u32 {
    const manual = arg != null;
    const r = work();
    busy.store(false, .release);
    if (manual or r == .installing) _ = w.PostMessageW(reply_hwnd, reply_msg, @backingInt(r), 0);
    return 0;
}

/// Only the copy the installer put in place updates itself (not one run from a build folder).
pub fn isInstalled() bool {
    var self: [600]u16 = undefined;
    const n = w.GetModuleFileNameW(null, &self, self.len);
    if (n == 0 or n >= self.len) return false;
    var env: [300]u16 = undefined;
    var buf: [700]u16 = undefined;
    const want = u.join(&buf, &.{ u.envVar(L("LOCALAPPDATA"), &env), L("\\Programs\\Ter\\ter.exe") });
    return u.eqlCI(self[0..n], want);
}

fn work() Result {
    if (!isInstalled()) return .not_installed;
    var body: u.List(u8) = .{};
    defer body.deinit();
    if (!get(HOST_API, LATEST, &body, 1 << 20)) return .failed;
    const json = body.items();

    const tag = jsonString(json, "\"tag_name\"", 0) orelse return .failed;
    if (!newer(tag.text, u.VERSION)) return .latest;

    // the installer among the release's files
    var url: ?[]const u8 = null;
    var from: usize = 0;
    while (jsonString(json, "\"browser_download_url\"", from)) |s| {
        from = s.end;
        if (std.mem.endsWith(u8, s.text, ASSET)) {
            url = s.text;
            break;
        }
    }
    const link = url orelse return .failed;
    const prefix = "https://";
    if (!std.mem.startsWith(u8, link, prefix)) return .failed;
    const rest = link[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return .failed;
    var host: [128]u16 = undefined;
    var path: [512]u16 = undefined;
    if (!ascii(rest[0..slash], &host) or !ascii(rest[slash..], &path)) return .failed;

    var exe: u.List(u8) = .{};
    defer exe.deinit();
    if (!get(@ptrCast(&host), @ptrCast(&path), &exe, 64 << 20)) return .failed;
    const bytes = exe.items();
    if (bytes.len < 64 * 1024 or bytes[0] != 'M' or bytes[1] != 'Z') return .failed; // not a program

    var env: [300]u16 = undefined;
    var buf: [700]u16 = undefined;
    const file = u.join(&buf, &.{ u.envVar(L("TEMP"), &env), L("\\ter-update.exe") });
    if (!save(file, bytes)) return .failed;
    if (!u.shell(null, file, L("--update"), null)) return .failed;
    return .installing; // the installer closes this copy and starts the new one
}

/// "v1.2.3" newer than "1.2.0"?
fn newer(tag: []const u8, current: []const u8) bool {
    const a = parse(tag);
    const b = parse(current);
    for (a, b) |x, y| {
        if (x != y) return x > y;
    }
    return false;
}

fn parse(v: []const u8) [3]u32 {
    var out = [3]u32{ 0, 0, 0 };
    var i: usize = 0;
    for (v) |c| {
        if (c >= '0' and c <= '9') {
            out[i] = out[i] *| 10 +| (c - '0');
        } else if (c == '.') {
            i += 1;
            if (i == out.len) break;
        } else if (c == '-' or c == '+') break; // pre-release / build suffix
    }
    return out;
}

const Str = struct { text: []const u8, end: usize };

/// The string value of the first `"key": "value"` at or after `from` (values here never
/// contain escapes: tags and download links).
fn jsonString(json: []const u8, key: []const u8, from: usize) ?Str {
    var i = (std.mem.indexOfPos(u8, json, from, key) orelse return null) + key.len;
    while (i < json.len and (json[i] == ' ' or json[i] == ':' or json[i] == '\n' or json[i] == '\r' or json[i] == '\t')) i += 1;
    if (i >= json.len or json[i] != '"') return null;
    const start = i + 1;
    const end = std.mem.indexOfScalarPos(u8, json, start, '"') orelse return null;
    return .{ .text = json[start..end], .end = end + 1 };
}

fn ascii(s: []const u8, out: []u16) bool {
    if (s.len + 1 > out.len) return false;
    for (s, 0..) |c, i| {
        if (c < 0x21 or c > 0x7E) return false;
        out[i] = c;
    }
    out[s.len] = 0;
    return true;
}

/// HTTPS GET into `out` (at most `max` bytes). Redirects are followed (release files
/// live on another host).
fn get(host: w.WSTR, path: w.WSTR, out: *u.List(u8), max: usize) bool {
    const session = w.WinHttpOpen(L("Ter-updater"), 4, null, null, 0) orelse return false; // automatic proxy
    defer _ = w.WinHttpCloseHandle(session);
    _ = w.WinHttpSetTimeouts(session, 10000, 10000, 15000, 30000);
    const conn = w.WinHttpConnect(session, host, 443, 0) orelse return false;
    defer _ = w.WinHttpCloseHandle(conn);
    const req = w.WinHttpOpenRequest(conn, L("GET"), path, null, null, null, 0x00800000) orelse return false; // WINHTTP_FLAG_SECURE
    defer _ = w.WinHttpCloseHandle(req);
    const headers = L("Accept: application/vnd.github+json\r\n");
    if (w.WinHttpSendRequest(req, headers, @intCast(headers.len), null, 0, 0, 0) == 0) return false;
    if (w.WinHttpReceiveResponse(req, null) == 0) return false;
    var status: u32 = 0;
    var size: u32 = 4;
    if (w.WinHttpQueryHeaders(req, 19 | 0x20000000, null, &status, &size, null) == 0 or status != 200) return false; // status code, as number
    while (true) {
        var avail: u32 = 0;
        if (w.WinHttpQueryDataAvailable(req, &avail) == 0) return false;
        if (avail == 0) return true;
        if (out.len + avail > max) return false;
        out.ensure(avail);
        var got: u32 = 0;
        if (w.WinHttpReadData(req, out.ptr.? + out.len, avail, &got) == 0) return false;
        out.len += got;
    }
}

fn save(path: w.WSTR, bytes: []const u8) bool {
    const f = w.CreateFileW(path, 0x40000000, 0, null, 2, 0x80, null); // GENERIC_WRITE, CREATE_ALWAYS
    if (f == w.INVALID) return false;
    defer _ = w.CloseHandle(f);
    var done: usize = 0;
    while (done < bytes.len) {
        var n: u32 = 0;
        const chunk: u32 = @intCast(@min(bytes.len - done, 1 << 20));
        if (w.WriteFile(f, bytes.ptr + done, chunk, &n, null) == 0 or n == 0) return false;
        done += n;
    }
    return true;
}
