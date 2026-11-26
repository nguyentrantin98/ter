//! Shared helpers: heap list, text folding, scoring, result sets.
const std = @import("std");
const w = @import("w.zig");

pub const L = std.unicode.utf8ToUtf16LeStringLiteral;

pub fn alloc(bytes: usize) [*]u8 {
    const p = w.HeapAlloc(w.GetProcessHeap(), 0, if (bytes == 0) 1 else bytes) orelse w.ExitProcess(3);
    return @ptrCast(p);
}

pub fn free(p: ?*anyopaque) void {
    if (p != null) _ = w.HeapFree(w.GetProcessHeap(), 0, p);
}

/// Growable array on the process heap (thread-safe allocator, no std dependency).
pub fn List(comptime T: type) type {
    return struct {
        ptr: ?[*]T = null,
        len: usize = 0,
        cap: usize = 0,

        const Self = @This();

        pub fn ensure(self: *Self, extra: usize) void {
            if (self.len + extra <= self.cap) return;
            var nc: usize = if (self.cap == 0) 16 else self.cap * 2;
            while (nc < self.len + extra) nc *= 2;
            const bytes = nc * @sizeOf(T);
            const heap = w.GetProcessHeap();
            const p = if (self.ptr) |old|
                w.HeapReAlloc(heap, 0, @ptrCast(old), bytes)
            else
                w.HeapAlloc(heap, 0, bytes);
            self.ptr = @ptrCast(@alignCast(p orelse w.ExitProcess(3)));
            self.cap = nc;
        }

        pub fn push(self: *Self, v: T) void {
            self.ensure(1);
            self.ptr.?[self.len] = v;
            self.len += 1;
        }

        pub fn appendSlice(self: *Self, s: []const T) void {
            if (s.len == 0) return;
            self.ensure(s.len);
            @memcpy(self.ptr.?[self.len .. self.len + s.len], s);
            self.len += s.len;
        }

        pub fn items(self: *const Self) []T {
            if (self.ptr) |p| return p[0..self.len];
            return &.{};
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
        }

        pub fn deinit(self: *Self) void {
            if (self.ptr) |p| free(@ptrCast(p));
            self.* = .{};
        }
    };
}

pub fn lenZ(p: [*]const u16) usize {
    var n: usize = 0;
    while (p[n] != 0) n += 1;
    return n;
}

pub fn sliceZ(p: [*]const u16) []const u16 {
    return p[0..lenZ(p)];
}

/// Heap copy with trailing zero.
pub fn dupZ(s: []const u16) [:0]u16 {
    const p: [*]u16 = @ptrCast(@alignCast(alloc((s.len + 1) * 2)));
    @memcpy(p[0..s.len], s);
    p[s.len] = 0;
    return p[0..s.len :0];
}

pub fn dup8(s: []const u8) []u8 {
    const p = alloc(s.len);
    @memcpy(p[0..s.len], s);
    return p[0..s.len];
}

pub fn lower16(c: u16) u16 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

pub fn eqlCI(a: []const u16, b: []const u16) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (lower16(x) != lower16(y)) return false;
    return true;
}

pub fn startsWithCI(a: []const u16, prefix: []const u16) bool {
    return a.len >= prefix.len and eqlCI(a[0..prefix.len], prefix);
}

pub fn endsWithCI(a: []const u16, suffix: []const u16) bool {
    return a.len >= suffix.len and eqlCI(a[a.len - suffix.len ..], suffix);
}

pub fn trim16(s: []const u16) []const u16 {
    var a: usize = 0;
    var b: usize = s.len;
    while (a < b and (s[a] == ' ' or s[a] == '\t')) a += 1;
    while (b > a and (s[b - 1] == ' ' or s[b - 1] == '\t')) b -= 1;
    return s[a..b];
}

pub fn indexOf(hay: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > hay.len) return null;
    const first = needle[0];
    const last = hay.len - needle.len;
    var i: usize = 0;
    while (i <= last) : (i += 1) {
        if (hay[i] != first) continue;
        var j: usize = 1;
        while (j < needle.len and hay[i + j] == needle[j]) j += 1;
        if (j == needle.len) return i;
    }
    return null;
}

/// Append UTF-16 as UTF-8.
pub fn pushUtf8(out: *List(u8), s: []const u16) void {
    out.ensure(s.len * 3);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        var cp: u32 = s[i];
        if (cp >= 0xD800 and cp < 0xDC00 and i + 1 < s.len and s[i + 1] >= 0xDC00 and s[i + 1] < 0xE000) {
            cp = 0x10000 + ((cp - 0xD800) << 10) + (s[i + 1] - 0xDC00);
            i += 1;
        }
        if (cp < 0x80) {
            out.push(@intCast(cp));
        } else if (cp < 0x800) {
            out.push(@intCast(0xC0 | (cp >> 6)));
            out.push(@intCast(0x80 | (cp & 0x3F)));
        } else if (cp < 0x10000) {
            out.push(@intCast(0xE0 | (cp >> 12)));
            out.push(@intCast(0x80 | ((cp >> 6) & 0x3F)));
            out.push(@intCast(0x80 | (cp & 0x3F)));
        } else {
            out.push(@intCast(0xF0 | (cp >> 18)));
            out.push(@intCast(0x80 | ((cp >> 12) & 0x3F)));
            out.push(@intCast(0x80 | ((cp >> 6) & 0x3F)));
            out.push(@intCast(0x80 | (cp & 0x3F)));
        }
    }
}

/// Append UTF-8 as UTF-16.
pub fn pushUtf16(out: *List(u16), s: []const u8) void {
    if (s.len == 0) return;
    out.ensure(s.len);
    const n = w.MultiByteToWideChar(65001, 0, s.ptr, @intCast(s.len), out.ptr.? + out.len, @intCast(s.len));
    if (n > 0) out.len += @intCast(n);
}

/// Search key: lowercase, Vietnamese/Latin diacritics removed, UTF-8.
/// "Báo Cáo.docx" -> "bao cao.docx", so typing without accents still matches.
pub fn foldKey(out: *List(u8), src: []const u16) void {
    var ascii = true;
    for (src) |c| {
        if (c >= 0x80) {
            ascii = false;
            break;
        }
    }
    if (ascii) {
        out.ensure(src.len);
        for (src) |c| out.push(@intCast(lower16(c)));
        return;
    }
    var a: [512]u16 = undefined;
    var b: [1600]u16 = undefined;
    const n = @min(src.len, a.len);
    @memcpy(a[0..n], src[0..n]);
    _ = w.CharLowerBuffW(&a, @intCast(n));
    const m = w.FoldStringW(0x40, &a, @intCast(n), &b, b.len); // MAP_COMPOSITE: decompose accents
    if (m <= 0) {
        pushUtf8(out, a[0..n]);
        return;
    }
    var k: usize = 0;
    for (b[0..@intCast(m)]) |c| {
        if (c >= 0x300 and c <= 0x36F) continue; // combining marks
        b[k] = if (c == 0x111) 'd' else c; // đ
        k += 1;
    }
    pushUtf8(out, b[0..k]);
}

fn isBoundary(c: u8) bool {
    return c == ' ' or c == '-' or c == '_' or c == '.' or c == '(' or c == '[';
}

fn scoreToken(key: []const u8, q: []const u8) i32 {
    const len_pen: i32 = @intCast(@min(key.len, 100));
    if (indexOf(key, q)) |pos| {
        var s: i32 = if (pos == 0) 800 else if (isBoundary(key[pos - 1])) 600 else 400;
        if (key.len == q.len) s += 200;
        return s - len_pen;
    }
    // initials: "vsc" -> Visual Studio Code
    var ini: [32]u8 = undefined;
    var n: usize = 0;
    for (key, 0..) |c, i| {
        if (n < ini.len and !isBoundary(c) and (i == 0 or isBoundary(key[i - 1]))) {
            ini[n] = c;
            n += 1;
        }
    }
    if (q.len <= n and std.mem.eql(u8, ini[0..q.len], q)) return 500 - len_pen;
    // loose subsequence
    var qi: usize = 0;
    var gaps: i32 = 0;
    var last: usize = 0;
    for (key, 0..) |c, i| {
        if (qi < q.len and c == q[qi]) {
            if (qi > 0) gaps += @intCast(i - last - 1);
            last = i;
            qi += 1;
        }
    }
    if (qi == q.len and q.len >= 2) return @max(1, 250 - gaps * 8 - len_pen);
    return 0;
}

/// Fuzzy score for app names; 0 means no match.
pub fn score(key: []const u8, q: []const u8) i32 {
    if (q.len == 0) return 1;
    const whole = scoreToken(key, q);
    if (whole > 0 or indexOf(q, " ") == null) return whole;
    var best: i32 = 100000;
    var it = std.mem.tokenizeScalar(u8, q, ' ');
    while (it.next()) |tok| {
        const s = scoreToken(key, tok);
        if (s == 0) return 0;
        best = @min(best, s);
    }
    return @max(1, @divTrunc(best, 2));
}

/// Keeps the K best (score, index) pairs, highest first; ties keep the earlier index.
pub const TopK = struct {
    pub const K = 60;
    scores: [K]i32 = undefined,
    ids: [K]u32 = undefined,
    n: usize = 0,

    pub fn add(self: *TopK, s: i32, id: u32) void {
        if (self.n == K and s <= self.scores[K - 1]) return;
        var i: usize = if (self.n < K) self.n else K - 1;
        while (i > 0 and self.scores[i - 1] < s) : (i -= 1) {
            self.scores[i] = self.scores[i - 1];
            self.ids[i] = self.ids[i - 1];
        }
        self.scores[i] = s;
        self.ids[i] = id;
        if (self.n < K) self.n += 1;
    }
};

pub const Kind = enum(u8) { app, file, dir };

pub const Row = struct {
    title_off: u32,
    title_len: u32,
    sub_off: u32,
    sub_len: u32,
    kind: Kind,
    ref: u32 = 0,
    icon: i32 = -1,
};

/// One batch of results shown in the list.
pub const Set = struct {
    rows: List(Row) = .{},
    text: List(u16) = .{},

    pub fn create() *Set {
        const s: *Set = @ptrCast(@alignCast(alloc(@sizeOf(Set))));
        s.* = .{};
        return s;
    }

    pub fn destroy(self: *Set) void {
        self.rows.deinit();
        self.text.deinit();
        free(self);
    }

    pub fn title(self: *const Set, r: Row) []const u16 {
        return self.text.items()[r.title_off..][0..r.title_len];
    }

    pub fn sub(self: *const Set, r: Row) []const u16 {
        return self.text.items()[r.sub_off..][0..r.sub_len];
    }
};

pub fn envVar(name: w.WSTR, buf: []u16) []u16 {
    const n = w.GetEnvironmentVariableW(name, buf.ptr, @intCast(buf.len));
    if (n == 0 or n >= buf.len) return buf[0..0];
    return buf[0..n];
}

/// ShellExecute wrapper. `file` and friends must be zero-terminated.
pub fn shell(verb: ?w.WSTR, file: w.WSTR, params: ?w.WSTR, dir: ?w.WSTR) bool {
    var sei = w.SHELLEXECUTEINFOW{
        .fMask = 0x400, // SEE_MASK_FLAG_NO_UI
        .lpVerb = verb,
        .lpFile = file,
        .lpParameters = params,
        .lpDirectory = dir,
    };
    return w.ShellExecuteExW(&sei) != 0;
}

// ---------------------------------------------------------------- registry (current user)

pub const HKCU: usize = 0xFFFFFFFF80000001;

pub fn regSetStr(sub: w.WSTR, name: w.WSTR, val: []const u16) void {
    var key: w.H = null;
    if (w.RegCreateKeyExW(HKCU, sub, 0, null, 0, 0x2, null, &key, null) != 0) return;
    defer _ = w.RegCloseKey(key);
    var buf: [700]u16 = undefined;
    const n = @min(val.len, buf.len - 1);
    @memcpy(buf[0..n], val[0..n]);
    buf[n] = 0;
    _ = w.RegSetValueExW(key, name, 0, 1, @ptrCast(&buf), @intCast((n + 1) * 2));
}

pub fn regSetDword(sub: w.WSTR, name: w.WSTR, v: u32) void {
    var key: w.H = null;
    if (w.RegCreateKeyExW(HKCU, sub, 0, null, 0, 0x2, null, &key, null) != 0) return;
    defer _ = w.RegCloseKey(key);
    _ = w.RegSetValueExW(key, name, 0, 4, @ptrCast(&v), 4);
}

pub fn regGetDword(sub: w.WSTR, name: w.WSTR) ?u32 {
    var key: w.H = null;
    if (w.RegCreateKeyExW(HKCU, sub, 0, null, 0, 0x1, null, &key, null) != 0) return null;
    defer _ = w.RegCloseKey(key);
    var v: u32 = 0;
    var size: u32 = 4;
    if (w.RegQueryValueExW(key, name, null, null, @ptrCast(&v), &size) != 0) return null;
    return v;
}

/// Join pieces into `buf` with a trailing zero.
pub fn join(buf: []u16, parts: []const []const u16) [:0]u16 {
    var n: usize = 0;
    for (parts) |p| {
        const k = @min(p.len, buf.len - 1 - n);
        @memcpy(buf[n..][0..k], p[0..k]);
        n += k;
    }
    buf[n] = 0;
    return buf[0..n :0];
}

pub const RUN_KEY = L("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
pub const APP_KEY = L("Software\\Ter");
pub const UNINSTALL_KEY = L("Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Ter");
pub const WINDOW_CLASS = L("TerOverlay");
pub const START_MENU_LNK = L("\\Microsoft\\Windows\\Start Menu\\Programs\\Ter.lnk");
