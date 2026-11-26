//! In-memory file index over all fixed drives + background search.
//! One thread walks the disks (breadth first), another answers queries.
const w = @import("w.zig");
const u = @import("util.zig");
const L = u.L;

const Entry = extern struct {
    name_off: u32,
    key_off: u32,
    /// Index of the parent directory entry; top bit set when this entry is a directory.
    parent: u32,
    name_len: u16,
    key_len: u16,
};

const DIR_BIT: u32 = 0x8000_0000;
const NO_PARENT: u32 = 0x7FFF_FFFF;
const MAX_ENTRIES: usize = 4_000_000;

var entries: u.List(Entry) = .{};
var text: u.List(u8) = .{};
var lock: w.SRWLOCK = .{};

pub var indexing: bool = false;
pub var count: u32 = 0;
var restart: bool = false;

var hwnd: w.H = null;
var msg_results: u32 = 0;
var msg_done: u32 = 0;

var q_lock: w.SRWLOCK = .{};
var q_buf: [256]u8 = undefined;
var q_len: usize = 0;
var q_gen: u32 = 0;
var q_event: w.H = null;

var profile_buf: [300]u16 = undefined;
var profile: []u16 = profile_buf[0..0];

pub fn start(h: w.H, results_msg: u32, done_msg: u32) void {
    hwnd = h;
    msg_results = results_msg;
    msg_done = done_msg;
    profile = u.envVar(L("USERPROFILE"), &profile_buf);
    q_event = w.CreateEventW(null, 0, 0, null);
    _ = w.CloseHandle(w.CreateThread(null, 0, searchThread, null, 0, null));
    reindex();
}

/// UI thread: (re)build the index from scratch.
pub fn reindex() void {
    if (indexing) {
        restart = true;
        return;
    }
    indexing = true;
    _ = w.CloseHandle(w.CreateThread(null, 0, indexThread, null, 0, null));
}

/// UI thread: ask for results; they arrive via `msg_results` tagged with the returned id.
pub fn request(key: []const u8) u32 {
    w.AcquireSRWLockExclusive(&q_lock);
    q_len = @min(key.len, q_buf.len);
    @memcpy(q_buf[0..q_len], key[0..q_len]);
    q_gen +%= 1;
    const gen = q_gen;
    w.ReleaseSRWLockExclusive(&q_lock);
    _ = w.SetEvent(q_event);
    return gen;
}

// ---------------------------------------------------------------- indexing

fn skipDir(name: []const u16, parent_is_drive: bool, parent_is_profile: bool) bool {
    const always = [_][]const u16{
        L("node_modules"), L(".git"),        L("$RECYCLE.BIN"), L("System Volume Information"),
        L(".zig-cache"),   L("zig-cache"),   L("__pycache__"),  L(".venv"),
        L("AppData"),
    };
    for (always) |s| if (u.eqlCI(name, s)) return true;
    if (name[0] == '$') return true;
    if (parent_is_profile and name[0] == '.') return true;
    if (parent_is_drive) {
        const at_root = [_][]const u16{ L("Windows"), L("ProgramData"), L("Recovery"), L("PerfLogs") };
        for (at_root) |s| if (u.eqlCI(name, s)) return true;
    }
    return false;
}

fn appendEntry(ents: *u.List(Entry), txt: *u.List(u8), name: []const u16, parent: u32, is_dir: bool) void {
    const name_off = txt.len;
    u.pushUtf8(txt, name);
    const name_len = txt.len - name_off;
    var key_off = txt.len;
    u.foldKey(txt, name);
    var key_len = txt.len - key_off;
    const bytes = txt.items();
    // Most names are already lowercase ASCII: share the bytes instead of storing twice.
    if (key_len == name_len and u.indexOf(bytes[name_off..][0..name_len], bytes[key_off..][0..key_len]) != null) {
        txt.len = key_off;
        key_off = name_off;
        key_len = name_len;
    }
    ents.push(.{
        .name_off = @intCast(name_off),
        .key_off = @intCast(key_off),
        .parent = parent | (if (is_dir) DIR_BIT else 0),
        .name_len = @intCast(name_len),
        .key_len = @intCast(key_len),
    });
}

/// Full path of entry `idx` as UTF-16 (no trailing zero). Caller holds the lock or is the indexer.
fn buildPath(idx: u32, out: *u.List(u16)) void {
    var chain: [256]u32 = undefined;
    var n: usize = 0;
    var i = idx;
    const ents = entries.items();
    while (i != NO_PARENT and n < chain.len) {
        chain[n] = i;
        n += 1;
        i = ents[i].parent & NO_PARENT;
    }
    const bytes = text.items();
    while (n > 0) {
        n -= 1;
        const e = ents[chain[n]];
        const items = out.items();
        if (items.len > 0 and items[items.len - 1] != '\\') out.push('\\');
        u.pushUtf16(out, bytes[e.name_off..][0..e.name_len]);
    }
}

fn indexOnce() void {
    w.AcquireSRWLockExclusive(&lock);
    entries.clear();
    text.clear();
    count = 0;
    // Roots: the user's profile first (most relevant), then every fixed drive.
    if (profile.len > 0) appendEntry(&entries, &text, profile, NO_PARENT, true);
    const drives = w.GetLogicalDrives();
    var d: u5 = 0;
    while (d < 26) : (d += 1) {
        if (drives & (@as(u32, 1) << d) == 0) continue;
        const root = [_:0]u16{ 'A' + @as(u16, d), ':', '\\' };
        if (w.GetDriveTypeW(&root) == 3) appendEntry(&entries, &text, &root, NO_PARENT, true); // DRIVE_FIXED
    }
    const root_count = entries.len;
    w.ReleaseSRWLockExclusive(&lock);

    var b_ents: u.List(Entry) = .{};
    var b_text: u.List(u8) = .{};
    var path: u.List(u16) = .{};
    defer b_ents.deinit();
    defer b_text.deinit();
    defer path.deinit();

    var fd: w.WIN32_FIND_DATAW = undefined;
    var cursor: u32 = 0;
    // Only this thread appends, so reading `entries` here without the lock is safe.
    while (cursor < entries.len and !restart) : (cursor += 1) {
        if (entries.items()[cursor].parent & DIR_BIT == 0) continue;

        path.clear();
        path.appendSlice(L("\\\\?\\"));
        buildPath(cursor, &path);
        const dir_len = path.len;
        if (path.items()[dir_len - 1] != '\\') path.push('\\');
        path.push('*');
        path.push(0);

        const h = w.FindFirstFileExW(@ptrCast(path.ptr.?), 1, &fd, 0, null, 2); // basic info, large fetch
        if (h == w.INVALID) continue;

        const parent_is_drive = cursor < root_count and !(profile.len > 0 and cursor == 0);
        const parent_is_profile = profile.len > 0 and cursor == 0;
        b_ents.clear();
        b_text.clear();
        while (true) {
            const name = u.sliceZ(&fd.cFileName);
            const attr = fd.dwFileAttributes;
            const is_dir = attr & 0x10 != 0;
            var keep = true;
            if (name.len <= 2 and name[0] == '.' and (name.len == 1 or name[1] == '.')) keep = false;
            if (attr & 0x400 != 0) keep = false; // reparse point: junction/symlink
            if (attr & 0x6 == 0x6) keep = false; // hidden + system
            if (keep and is_dir) {
                if (skipDir(name, parent_is_drive, parent_is_profile)) keep = false;
                // The profile is its own root; don't index it again under C:\Users.
                if (keep and profile.len > 0 and cursor != 0) {
                    const dir = path.items()[4..dir_len];
                    const sep: usize = if (dir[dir.len - 1] == '\\') 0 else 1;
                    if (dir.len + sep + name.len == profile.len and
                        u.startsWithCI(profile, dir) and u.endsWithCI(profile, name)) keep = false;
                }
            }
            if (keep) appendEntry(&b_ents, &b_text, name, cursor, is_dir);
            if (w.FindNextFileW(h, &fd) == 0) break;
        }
        _ = w.FindClose(h);

        if (b_ents.len == 0) continue;
        w.AcquireSRWLockExclusive(&lock);
        if (entries.len + b_ents.len <= MAX_ENTRIES and text.len + b_text.len < 0xF000_0000) {
            const base: u32 = @intCast(text.len);
            text.appendSlice(b_text.items());
            for (b_ents.items()) |*e| {
                e.name_off += base;
                e.key_off += base;
            }
            entries.appendSlice(b_ents.items());
            count = @intCast(entries.len);
        }
        w.ReleaseSRWLockExclusive(&lock);
    }
}

fn indexThread(_: ?*anyopaque) callconv(.winapi) u32 {
    while (true) {
        restart = false;
        indexOnce();
        if (!restart) break;
    }
    indexing = false;
    _ = w.PostMessageW(hwnd, msg_done, 0, 0);
    return 0;
}

// ---------------------------------------------------------------- searching

fn isBoundary(c: u8) bool {
    return c == ' ' or c == '-' or c == '_' or c == '.' or c == '(' or c == '[';
}

fn searchThread(_: ?*anyopaque) callconv(.winapi) u32 {
    var q: [256]u8 = undefined;
    while (true) {
        _ = w.WaitForSingleObject(q_event, 0xFFFFFFFF);
        w.AcquireSRWLockShared(&q_lock);
        const len = q_len;
        const gen = q_gen;
        @memcpy(q[0..len], q_buf[0..len]);
        w.ReleaseSRWLockShared(&q_lock);

        // Split into words; every word must appear in the file name.
        var toks: [8][]const u8 = undefined;
        var nt: usize = 0;
        var i: usize = 0;
        while (i < len and nt < toks.len) {
            while (i < len and q[i] == ' ') i += 1;
            const s = i;
            while (i < len and q[i] != ' ') i += 1;
            if (i > s) {
                toks[nt] = q[s..i];
                nt += 1;
            }
        }

        const set = u.Set.create();
        var aborted = false;
        if (nt > 0) {
            var top = u.TopK{};
            w.AcquireSRWLockShared(&lock);
            const ents = entries.items();
            const bytes = text.items();
            const single_len: usize = if (nt == 1) toks[0].len else 0;
            scan: for (ents, 0..) |e, idx| {
                if (idx & 0x3FFF == 0 and q_gen != gen) {
                    aborted = true;
                    break;
                }
                const key = bytes[e.key_off..][0..e.key_len];
                const pos = u.indexOf(key, toks[0]) orelse continue;
                for (toks[1..nt]) |t| {
                    if (u.indexOf(key, t) == null) continue :scan;
                }
                var s: i32 = if (pos == 0) 300 else if (isBoundary(key[pos - 1])) 200 else 100;
                if (key.len == single_len) s += 200;
                s -= @intCast(@min(key.len, 100));
                if (e.parent & DIR_BIT != 0) s += 10;
                top.add(s, @intCast(idx));
            }
            if (!aborted) {
                var path: u.List(u16) = .{};
                defer path.deinit();
                for (top.ids[0..top.n]) |id| {
                    const e = ents[id];
                    const t_off: u32 = @intCast(set.text.len);
                    u.pushUtf16(&set.text, bytes[e.name_off..][0..e.name_len]);
                    const t_len: u32 = @intCast(set.text.len - t_off);
                    const s_off: u32 = @intCast(set.text.len);
                    const par = e.parent & NO_PARENT;
                    if (par != NO_PARENT) {
                        path.clear();
                        buildPath(par, &path);
                        set.text.appendSlice(path.items());
                    }
                    set.rows.push(.{
                        .title_off = t_off,
                        .title_len = t_len,
                        .sub_off = s_off,
                        .sub_len = @intCast(set.text.len - s_off),
                        .kind = if (e.parent & DIR_BIT != 0) .dir else .file,
                    });
                }
            }
            w.ReleaseSRWLockShared(&lock);
        }
        if (aborted) {
            set.destroy();
        } else {
            _ = w.PostMessageW(hwnd, msg_results, gen, @bitCast(@intFromPtr(set)));
        }
    }
}
