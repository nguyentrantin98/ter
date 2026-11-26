//! App list: Start Menu shortcuts + packaged (Store) apps from shell:AppsFolder.
const w = @import("w.zig");
const u = @import("util.zig");
const L = u.L;

pub const App = struct {
    name: [:0]u16,
    key: []u8,
    /// .lnk path, or "shell:AppsFolder\<id>" for packaged apps.
    target: [:0]u16,
    is_lnk: bool,
    icon: i32 = -1,
};

pub const AppList = u.List(App);

/// Owned by the UI thread once delivered through `msg_ready`.
pub var list: AppList = .{};

var notify_hwnd: w.H = null;
var notify_msg: u32 = 0;

pub fn startLoad(hwnd: w.H, msg_ready: u32) void {
    notify_hwnd = hwnd;
    notify_msg = msg_ready;
    const t = w.CreateThread(null, 0, loadThread, null, 0, null);
    _ = w.CloseHandle(t);
}

/// UI thread: take ownership of a freshly loaded list.
pub fn adopt(ptr: *AppList) void {
    for (list.items()) |a| {
        u.free(a.name.ptr);
        u.free(a.key.ptr);
        u.free(a.target.ptr);
    }
    list.deinit();
    list = ptr.*;
    u.free(ptr);
}

/// UI thread: ranked matches for a folded query.
pub fn search(q: []const u8) *u.Set {
    const set = u.Set.create();
    if (q.len == 0) return set;
    var top = u.TopK{};
    for (list.items(), 0..) |a, i| {
        const s = u.score(a.key, q);
        if (s > 0) top.add(s, @intCast(i));
    }
    for (top.ids[0..top.n]) |id| {
        const a = list.items()[id];
        const off: u32 = @intCast(set.text.len);
        set.text.appendSlice(a.name);
        set.rows.push(.{
            .title_off = off,
            .title_len = @intCast(a.name.len),
            .sub_off = 0,
            .sub_len = 0,
            .kind = .app,
            .ref = id,
            .icon = a.icon,
        });
    }
    return set;
}

fn has(out: *AppList, key: []const u8) bool {
    for (out.items()) |a| {
        if (a.key.len == key.len and u.indexOf(a.key, key) != null) return true;
    }
    return false;
}

fn add(out: *AppList, name: []const u16, target: []const u16, is_lnk: bool, pidl: ?*anyopaque) void {
    var key: u.List(u8) = .{};
    defer key.deinit();
    u.foldKey(&key, name);
    if (key.len == 0 or u.indexOf(key.items(), "uninstall") != null or has(out, key.items())) return;

    var app = App{
        .name = u.dupZ(name),
        .key = u.dup8(key.items()),
        .target = u.dupZ(target),
        .is_lnk = is_lnk,
    };
    // Resolve the icon here, off the UI thread; the system image list is process-wide.
    var sfi = w.SHFILEINFOW{};
    const flags_base: u32 = 0x4000; // SHGFI_SYSICONINDEX | large icon
    const ok = if (pidl) |p|
        w.SHGetFileInfoW(p, 0, &sfi, @sizeOf(w.SHFILEINFOW), flags_base | 0x8) // SHGFI_PIDL
    else
        w.SHGetFileInfoW(app.target.ptr, 0, &sfi, @sizeOf(w.SHFILEINFOW), flags_base);
    if (ok != 0) app.icon = sfi.iIcon;
    out.push(app);
}

fn scanDir(dir: []const u16, out: *AppList, depth: u32) void {
    var path: [600]u16 = undefined;
    if (dir.len + 270 > path.len) return;
    @memcpy(path[0..dir.len], dir);
    path[dir.len] = '\\';
    path[dir.len + 1] = '*';
    path[dir.len + 2] = 0;

    var fd: w.WIN32_FIND_DATAW = undefined;
    const h = w.FindFirstFileExW(@ptrCast(&path), 1, &fd, 0, null, 0);
    if (h == w.INVALID) return;
    defer _ = w.FindClose(h);
    while (true) {
        const name = u.sliceZ(&fd.cFileName);
        const dots = name.len <= 2 and name[0] == '.' and (name.len == 1 or name[1] == '.');
        if (!dots) {
            @memcpy(path[dir.len + 1 ..][0..name.len], name);
            const child = path[0 .. dir.len + 1 + name.len];
            path[child.len] = 0;
            if (fd.dwFileAttributes & 0x10 != 0) {
                if (depth < 5) scanDir(child, out, depth + 1);
            } else if (u.endsWithCI(name, L(".lnk"))) {
                add(out, name[0 .. name.len - 4], child, true, null);
            }
        }
        if (w.FindNextFileW(h, &fd) == 0) break;
    }
}

fn scanStartMenu(env: w.WSTR, out: *AppList) void {
    var buf: [400]u16 = undefined;
    const base = u.envVar(env, buf[0..300]);
    if (base.len == 0) return;
    const tail = L("\\Microsoft\\Windows\\Start Menu\\Programs");
    @memcpy(buf[base.len..][0..tail.len], tail);
    scanDir(buf[0 .. base.len + tail.len], out, 0);
}

// ---- COM: enumerate shell:AppsFolder for packaged apps (Notepad, Terminal, Settings...)

const STRRET = extern struct {
    uType: u32,
    u: extern union { pOleStr: ?[*:0]u16, uOffset: u32, cStr: [260]u8 },
};

const IEnumIDList = extern struct {
    vt: *const extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IEnumIDList) callconv(.winapi) u32,
        Next: *const fn (*IEnumIDList, u32, *?*anyopaque, *u32) callconv(.winapi) i32,
    },
};

const IShellFolder = extern struct {
    vt: *const extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IShellFolder) callconv(.winapi) u32,
        ParseDisplayName: *const anyopaque,
        EnumObjects: *const fn (*IShellFolder, w.H, u32, *?*IEnumIDList) callconv(.winapi) i32,
        BindToObject: *const anyopaque,
        BindToStorage: *const anyopaque,
        CompareIDs: *const anyopaque,
        CreateViewObject: *const anyopaque,
        GetAttributesOf: *const anyopaque,
        GetUIObjectOf: *const anyopaque,
        GetDisplayNameOf: *const fn (*IShellFolder, ?*anyopaque, u32, *STRRET) callconv(.winapi) i32,
    },
};

const IID_IShellFolder = w.GUID{ .a = 0x000214E6, .b = 0, .c = 0, .d = .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 } };

fn scanAppsFolder(out: *AppList) void {
    var root: ?*anyopaque = null;
    if (w.SHParseDisplayName(L("shell:AppsFolder"), null, &root, 0, null) != 0 or root == null) return;
    defer w.CoTaskMemFree(root);

    var raw: ?*anyopaque = null;
    if (w.SHBindToObject(null, root, null, &IID_IShellFolder, &raw) != 0 or raw == null) return;
    const folder: *IShellFolder = @ptrCast(@alignCast(raw.?));
    defer _ = folder.vt.Release(folder);

    var en_opt: ?*IEnumIDList = null;
    if (folder.vt.EnumObjects(folder, null, 0x40, &en_opt) != 0) return; // SHCONTF_NONFOLDERS
    const en = en_opt orelse return;
    defer _ = en.vt.Release(en);

    const prefix = L("shell:AppsFolder\\");
    var name: [300]u16 = undefined;
    var target: [700]u16 = undefined;
    @memcpy(target[0..prefix.len], prefix);

    while (true) {
        var child: ?*anyopaque = null;
        var got: u32 = 0;
        if (en.vt.Next(en, 1, &child, &got) != 0 or got == 0 or child == null) break;
        defer w.CoTaskMemFree(child);

        var sr: STRRET = undefined;
        if (folder.vt.GetDisplayNameOf(folder, child, 0, &sr) != 0) continue;
        if (w.StrRetToBufW(&sr, child, &name, name.len) != 0) continue;
        if (folder.vt.GetDisplayNameOf(folder, child, 0x8000, &sr) != 0) continue; // SHGDN_FORPARSING
        if (w.StrRetToBufW(&sr, child, target[prefix.len..].ptr, @intCast(target.len - prefix.len)) != 0) continue;

        const full = w.ILCombine(root, child);
        defer w.CoTaskMemFree(full);
        add(out, u.sliceZ(&name), u.sliceZ(&target), false, full);
    }
}

fn lessKey(a: []const u8, b: []const u8) bool {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        if (x != y) return x < y;
    }
    return a.len < b.len;
}

fn loadThread(_: ?*anyopaque) callconv(.winapi) u32 {
    _ = w.CoInitializeEx(null, 2);
    const out: *AppList = @ptrCast(@alignCast(u.alloc(@sizeOf(AppList))));
    out.* = .{};

    // Shortcuts first: "run as admin" is most reliable on .lnk files.
    scanStartMenu(L("APPDATA"), out);
    scanStartMenu(L("ProgramData"), out);
    scanAppsFolder(out);

    const items = out.items();
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const x = items[i];
        var j = i;
        while (j > 0 and lessKey(x.key, items[j - 1].key)) : (j -= 1) items[j] = items[j - 1];
        items[j] = x;
    }
    _ = w.PostMessageW(notify_hwnd, notify_msg, 0, @bitCast(@intFromPtr(out)));
    return 0;
}
