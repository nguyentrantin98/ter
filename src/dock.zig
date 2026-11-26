//! macOS-style Dock: a glass bar at the bottom of the primary screen with pinned and
//! running apps, hover magnification, running dots and name labels. While it is on, the
//! Windows taskbar is hidden (and put back exactly as it was when the Dock is turned off).
//!
//! Everything is drawn by hand into one per-pixel-alpha window, so icons can grow out of
//! the bar and every edge is anti-aliased. The frosted glass is made here too: the screen
//! behind the bar is captured, shrunk, blurred and tinted. (Windows' own blur cannot be
//! clipped to a rounded shape - it always fills the whole window rectangle.)
const w = @import("w.zig");
const u = @import("util.zig");
const L = u.L;

// ---- look (sizes at 96 DPI)
const BASE = 48; // icon size at rest
const MAX_SCALE: f32 = 1.5; // icon under the cursor
const REACH: f32 = 2.6; // how many icon widths the magnification spreads to each side
const GAP = 6;
const PAD_SIDE = 12;
const PAD_TOP = 9;
const PAD_BOT = 11;
const MARGIN_BOT = 6; // gap between bar and screen edge
const RADIUS = 22;
const SEP_W = 17;
const LABEL_H = 26;
const GLASS_DOWN = 4; // the backdrop is blurred at 1/4 resolution
const GLASS_BLUR = 4; // box radius in shrunk pixels, applied three times (~18px gaussian)
const EASE_MS: f32 = 60; // how quickly magnification follows; smaller = snappier
// Background-app (system tray) icons are shown at the system's small-icon size (16 px at
// 100%), which is what apps hand over: copied pixel for pixel, never scaled or magnified.
const TRAY_SLOT = 22;

const WM_APPBAR = 0x8020;
const WM_FRAME = 0x8021;
const CLASS_DOCK = L("TerDock");

const Kind = enum { app, sep, trash, tray };

/// A background app's icon, normally shown in the taskbar's notification area.
const Tray = struct {
    hwnd: w.H = null,
    uid: u32 = 0,
    msg: u32 = 0, // callback message
    version: u32 = 0,
    guid: ?w.GUID = null,
    pix: ?[*]u32 = null, // tray_px x tray_px, premultiplied
};

var tray_px: i32 = 16;

const Icon = struct { mips: [4][*]u32 };
const MIP = [4]i32{ 256, 128, 64, 32 };

const Item = struct {
    kind: Kind,
    /// What identifies the app: its exe path, or "shell:AppsFolder\<id>" for Store apps.
    id: [:0]u16,
    /// What to run when it is not open yet (a shortcut keeps its arguments).
    launch: [:0]u16,
    name: [:0]u16,
    pinned: bool = false,
    icon: ?*Icon = null,
    wins: [24]w.H = undefined,
    nwins: usize = 0,
    bounce_at: u64 = 0,
    tray: Tray = .{},
    rest_c: f32 = 0,
    x: f32 = 0,
    size: f32 = 0,
};

const Seen = struct { h: w.H, id: [:0]u16, live: bool };

pub var enabled: bool = false;
/// Shows the Ter menu (set by main); used when the bar itself is right-clicked.
pub var on_menu: ?*const fn () void = null;

var hinst: w.H = null;
var dpi: i32 = 96;
var dock: w.H = null;
var classes_done = false;

var cw: i32 = 0; // window / canvas size
var ch: i32 = 0;
var win_x: i32 = 0;
var win_y: i32 = 0;
var canvas_dc: w.H = null;
var canvas_bmp: w.H = null;
var bits: [*]u32 = undefined;
var f_label: w.H = null;

var items: u.List(Item) = .{};
var seen: u.List(Seen) = .{};

var mouse_x: f32 = 0;
var hovering = false;
var tracking = false;
var mag: f32 = 0; // 0 = at rest, 1 = fully magnified
var animating = false;
var hover: ?usize = null;
var bar_l: f32 = 0;
var bar_r: f32 = 0;

// frosted-glass backdrop
var live_glass = false; // true when our own window can be kept out of the capture
var cap_dc: w.H = null;
var cap_bmp: w.H = null;
var cap_bits: [*]u32 = undefined;
var cap_top: i32 = 0; // window-local y where the captured strip starts
var cap_h: i32 = 0;
var cap_x0: i32 = 0; // captured columns: only the part of the screen the bar can reach
var cap_w: i32 = 0;
var glass: u.List(u32) = .{};
var glass_tmp: u.List(u32) = .{};
var glass_row: u.List(u32) = .{}; // one row of glass, prepared for the row being drawn
var gw: i32 = 0;
var gh: i32 = 0;
var glass_hash: u64 = 0;
var glass_idle: u32 = 0;

// animation clock
var dirty = false;
var last_frame: i64 = 0;
var qpf: i64 = 1;
var anim_event: w.H = null;

var label_for: ?[*]const u16 = null;
var label_mask: u.List(u8) = .{};
var label_w: i32 = 0;
var label_h: i32 = 0;

// partial updates: only the columns that changed are cleared, redrawn and sent to the screen
var drawn_l: i32 = 0;
var drawn_r: i32 = 0;
var drawn_t: i32 = 0;
var full_redraw = true;

var tick: u32 = 0;
var fullscreen = false;
var over_dock = false; // the cursor is on the Dock itself (not on the previews above it)
var fg_hook: w.H = null;
var peek = false;
var dwell: u32 = 0;
var away: u32 = 0;

fn px(v: i32) i32 {
    return @divTrunc(v * dpi + 48, 96);
}

fn pf(v: i32) f32 {
    return @floatFromInt(px(v));
}

fn clamp01(v: f32) f32 {
    return @max(0, @min(1, v));
}

// ================================================================ icons

const IID_IShellItemImageFactory = w.GUID{ .a = 0xbcc18b79, .b = 0xba16, .c = 0x442f, .d = .{ 0x80, 0xc4, 0x8a, 0x59, 0xc3, 0x0c, 0x46, 0x3b } };
const IID_IShellItem = w.GUID{ .a = 0x43826d1e, .b = 0xe718, .c = 0x42ee, .d = .{ 0xbc, 0x55, 0xa1, 0xe2, 0x61, 0xc3, 0x7b, 0xfe } };
const FnRelease = *const fn (*anyopaque) callconv(.winapi) u32;

fn lerpPx(a: u32, b: u32, t: u32) u32 {
    const it = 256 - t;
    const rb = (((a & 0x00FF00FF) * it + (b & 0x00FF00FF) * t) >> 8) & 0x00FF00FF;
    const ag = (((a >> 8) & 0x00FF00FF) * it + ((b >> 8) & 0x00FF00FF) * t) & 0xFF00FF00;
    return rb | ag;
}

/// Bilinear sample of a premultiplied image at 16.16 fixed-point coordinates.
fn sample(src: [*]const u32, sw: i32, sh: i32, fx: i32, fy: i32) u32 {
    const cx = @max(0, @min(fx, (sw - 1) << 16));
    const cy = @max(0, @min(fy, (sh - 1) << 16));
    const x0: usize = @intCast(cx >> 16);
    const y0: usize = @intCast(cy >> 16);
    const wd: usize = @intCast(sw);
    const x1 = @min(x0 + 1, wd - 1);
    const y1 = @min(y0 + 1, @as(usize, @intCast(sh)) - 1);
    const tx: u32 = @intCast((cx >> 8) & 255);
    const ty: u32 = @intCast((cy >> 8) & 255);
    const top = lerpPx(src[y0 * wd + x0], src[y0 * wd + x1], tx);
    const bot = lerpPx(src[y1 * wd + x0], src[y1 * wd + x1], tx);
    return lerpPx(top, bot, ty);
}

/// Bilinear sampling along one row: the vertical part is worked out once per row, so each
/// pixel only costs two horizontal lerps and one vertical one.
const Rows = struct {
    r0: [*]const u32,
    r1: [*]const u32,
    ty: u32,
    max: i32,
    last: usize,

    fn init(src: [*]const u32, sw: i32, sh: i32, fy: i32) Rows {
        const cy = @max(0, @min(fy, (sh - 1) << 16));
        const wd: usize = @intCast(sw);
        const y0: usize = @intCast(cy >> 16);
        const y1 = @min(y0 + 1, @as(usize, @intCast(sh)) - 1);
        return .{ .r0 = src + y0 * wd, .r1 = src + y1 * wd, .ty = @intCast((cy >> 8) & 255), .max = (sw - 1) << 16, .last = wd - 1 };
    }

    /// Blend the two rows into `out` over the texels that samples fx0..fx1 touch.
    fn flatten(self: Rows, out: *[256]u32, fx0: i32, fx1: i32) void {
        const a: usize = @intCast(@max(0, @min(fx0, self.max)) >> 16);
        const b = @min(@as(usize, @intCast(@max(0, @min(fx1, self.max)) >> 16)) + 1, self.last);
        for (a..b + 1) |i| out[i] = lerpPx(self.r0[i], self.r1[i], self.ty);
    }

    inline fn at(self: Rows, fx: i32) u32 {
        const cx = @max(0, @min(fx, self.max));
        const x0: usize = @intCast(cx >> 16);
        const x1 = @min(x0 + 1, self.last);
        const tx: u32 = @intCast((cx >> 8) & 255);
        return lerpPx(lerpPx(self.r0[x0], self.r0[x1], tx), lerpPx(self.r1[x0], self.r1[x1], tx), self.ty);
    }
};

/// Horizontal lerp in a row prepared by Rows.flatten (`size` texels wide).
inline fn hsample(tex: *const [256]u32, fx: i32, size: i32) u32 {
    const cx = @max(0, @min(fx, (size - 1) << 16));
    const i: usize = @intCast(cx >> 16);
    const j = @min(i + 1, @as(usize, @intCast(size - 1)));
    return lerpPx(tex[i], tex[j], @intCast((cx >> 8) & 255));
}

/// Multiply all four channels by a/256.
fn scalePx(c: u32, a: u32) u32 {
    const rb = (((c & 0x00FF00FF) * a) >> 8) & 0x00FF00FF;
    const ag = (((c >> 8) & 0x00FF00FF) * a) & 0xFF00FF00;
    return rb | ag;
}

/// Ask the shell for a large picture of `target` (file path or shell: name) and keep it as a
/// 256px premultiplied image plus smaller copies, so it can be drawn sharply at any size.
fn loadIcon(target: w.WSTR) ?*Icon {
    var raw: ?*anyopaque = null;
    if (w.SHCreateItemFromParsingName(target, null, &IID_IShellItemImageFactory, &raw) != 0) return null;
    const factory = raw orelse return null;
    defer _ = u.method(factory, 2, FnRelease)(factory);

    const FnGetImage = *const fn (*anyopaque, w.SIZE, u32, *w.H) callconv(.winapi) i32;
    var hbmp: w.H = null;
    if (u.method(factory, 3, FnGetImage)(factory, .{ .cx = 256, .cy = 256 }, 0x4, &hbmp) != 0 or hbmp == null) return null;
    defer _ = w.DeleteObject(hbmp);

    var bm = w.BITMAP{};
    if (w.GetObjectW(hbmp, @sizeOf(w.BITMAP), &bm) == 0 or bm.bmWidth <= 0 or bm.bmHeight <= 0) return null;
    const sw: usize = @intCast(bm.bmWidth);
    const sh: usize = @intCast(bm.bmHeight);
    if (sw != sh or sw > 1024) return null;
    const src: [*]u32 = @ptrCast(@alignCast(u.alloc(sw * sh * 4)));
    defer u.free(src);
    var bi = w.BITMAPINFOHEADER{ .biWidth = bm.bmWidth, .biHeight = -bm.bmHeight };
    const dc = w.GetDC(null);
    const got = w.GetDIBits(dc, hbmp, 0, @intCast(sh), src, &bi, 0);
    _ = w.ReleaseDC(null, dc);
    if (got == 0) return null;
    return iconFromPixels(src, sw, sh, true);
}

/// Normalise a picture: opaque if there is no alpha at all, premultiplied otherwise.
fn premultiply(pix: []u32) void {
    var any_alpha = false;
    var straight = false;
    for (pix) |p| {
        const a = p >> 24;
        if (a != 0) any_alpha = true;
        if ((p & 255) > a or ((p >> 8) & 255) > a or ((p >> 16) & 255) > a) straight = true;
    }
    for (pix) |*p| {
        if (!any_alpha) {
            p.* |= 0xFF000000;
        } else if (straight) {
            const a = p.* >> 24;
            const r = ((p.* >> 16) & 255) * a / 255;
            const g = ((p.* >> 8) & 255) * a / 255;
            const b = (p.* & 255) * a / 255;
            p.* = (a << 24) | (r << 16) | (g << 8) | b;
        }
    }
}

/// Turn a square picture into a 256px premultiplied image plus smaller copies. With `zoom`,
/// a picture that only fills a corner of its canvas is zoomed to fill the slot.
fn iconFromPixels(src: [*]u32, sw: usize, sh: usize, zoom: bool) ?*Icon {
    if (sw != sh or sw == 0) return null;
    premultiply(src[0 .. sw * sh]);

    // Old programs only ship a small icon, which the shell parks in a corner of the big
    // canvas. Find the drawn area and zoom into it so every icon fills its slot.
    var min_x: usize = sw;
    var min_y: usize = sh;
    var max_x: usize = 0;
    var max_y: usize = 0;
    for (0..sh) |y| {
        for (0..sw) |x| {
            if (src[y * sw + x] >> 24 > 8) {
                min_x = @min(min_x, x);
                max_x = @max(max_x, x);
                min_y = @min(min_y, y);
                max_y = @max(max_y, y);
            }
        }
    }
    if (max_x < min_x) return null; // fully transparent
    var crop_x: f32 = 0;
    var crop_y: f32 = 0;
    var crop: f32 = @floatFromInt(sw);
    const used = @max(max_x - min_x, max_y - min_y) + 1;
    if (zoom and used * 2 <= sw) {
        crop = @floatFromInt(used);
        crop_x = @as(f32, @floatFromInt(min_x + max_x + 1)) / 2 - crop / 2;
        crop_y = @as(f32, @floatFromInt(min_y + max_y + 1)) / 2 - crop / 2;
    }

    const ic: *Icon = @ptrCast(@alignCast(u.alloc(@sizeOf(Icon))));
    const m0: [*]u32 = @ptrCast(@alignCast(u.alloc(256 * 256 * 4)));
    const step = crop / 256;
    for (0..256) |y| {
        for (0..256) |x| {
            const fx = crop_x + (@as(f32, @floatFromInt(x)) + 0.5) * step - 0.5;
            const fy = crop_y + (@as(f32, @floatFromInt(y)) + 0.5) * step - 0.5;
            m0[y * 256 + x] = sample(src, @intCast(sw), @intCast(sh), @intFromFloat(fx * 65536), @intFromFloat(fy * 65536));
        }
    }
    ic.mips[0] = m0;
    // Half-size copies by averaging 2x2 blocks.
    for (1..4) |m| {
        const d: usize = @intCast(MIP[m]);
        const big = ic.mips[m - 1];
        const small: [*]u32 = @ptrCast(@alignCast(u.alloc(d * d * 4)));
        for (0..d) |y| {
            for (0..d) |x| {
                const p = [4]u32{ big[y * 2 * d * 2 + x * 2], big[y * 2 * d * 2 + x * 2 + 1], big[(y * 2 + 1) * d * 2 + x * 2], big[(y * 2 + 1) * d * 2 + x * 2 + 1] };
                var out: u32 = 0;
                inline for (.{ 0, 8, 16, 24 }) |sh_| {
                    const sum = ((p[0] >> sh_) & 255) + ((p[1] >> sh_) & 255) + ((p[2] >> sh_) & 255) + ((p[3] >> sh_) & 255);
                    out |= ((sum + 2) / 4) << sh_;
                }
                small[y * d + x] = out;
            }
        }
        ic.mips[m] = small;
    }
    return ic;
}

fn freeIcon(ic: ?*Icon) void {
    const i = ic orelse return;
    for (i.mips) |m| u.free(m);
    u.free(i);
}

// ================================================================ drawing into the canvas

/// Premultiplied source over destination.
fn blendPre(p: *u32, s: u32) void {
    const sa = s >> 24;
    if (sa == 0) return;
    if (sa == 255) {
        p.* = s;
        return;
    }
    const ia = 256 - sa;
    const d = p.*;
    const rb = (((d & 0x00FF00FF) * ia) >> 8) & 0x00FF00FF;
    const ag = (((d >> 8) & 0x00FF00FF) * ia) & 0xFF00FF00;
    p.* = s +% (rb | ag);
}

/// Plain colour (0xRRGGBB) with coverage `a` (0..1) over destination.
fn blend(x: i32, y: i32, rgb: u32, a: f32) void {
    if (x < 0 or y < 0 or x >= cw or y >= ch or a <= 0.003) return;
    const ai: u32 = @intFromFloat(clamp01(a) * 255);
    const r = ((rgb >> 16) & 255) * ai / 255;
    const g = ((rgb >> 8) & 255) * ai / 255;
    const b = (rgb & 255) * ai / 255;
    blendPre(&bits[@intCast(y * cw + x)], (ai << 24) | (r << 16) | (g << 8) | b);
}

/// Signed distance from a point to a rounded rectangle (negative inside).
fn sdf(pxl: f32, pyl: f32, l: f32, t: f32, r: f32, b: f32, rad: f32) f32 {
    const qx = @abs(pxl - (l + r) / 2) - ((r - l) / 2 - rad);
    const qy = @abs(pyl - (t + b) / 2) - ((b - t) / 2 - rad);
    const ox = @max(qx, 0);
    const oy = @max(qy, 0);
    return @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0) - rad;
}

/// Anti-aliased filled rounded rectangle.
fn fillRound(l: f32, t: f32, r: f32, b: f32, rad: f32, rgb: u32, alpha: f32) void {
    var y: i32 = @intFromFloat(@floor(t));
    while (y < @as(i32, @intFromFloat(@ceil(b)))) : (y += 1) {
        var x: i32 = @intFromFloat(@floor(l));
        while (x < @as(i32, @intFromFloat(@ceil(r)))) : (x += 1) {
            const d = sdf(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5, l, t, r, b, rad);
            blend(x, y, rgb, clamp01(0.5 - d) * alpha);
        }
    }
}

fn barTop() f32 {
    return @as(f32, @floatFromInt(ch)) - pf(MARGIN_BOT) - pf(BASE + PAD_TOP + PAD_BOT);
}

fn barBottom() f32 {
    return @as(f32, @floatFromInt(ch)) - pf(MARGIN_BOT);
}

// ---------------------------------------------------------------- frosted glass

/// One pass of a horizontal box blur (running sum, edges repeated).
fn boxBlurH(src: [*]const u32, dst: [*]u32, wd: usize, ht: usize, r: usize) void {
    const n: u32 = @intCast(2 * r + 1);
    for (0..ht) |y| {
        const row = src[y * wd ..];
        var sum = [3]u32{ 0, 0, 0 };
        var i: isize = -@as(isize, @intCast(r));
        while (i <= @as(isize, @intCast(r))) : (i += 1) {
            const px_ = row[@intCast(@max(0, @min(i, @as(isize, @intCast(wd)) - 1)))];
            sum[0] += px_ & 255;
            sum[1] += (px_ >> 8) & 255;
            sum[2] += (px_ >> 16) & 255;
        }
        for (0..wd) |x| {
            dst[y * wd + x] = 0xFF000000 | ((sum[2] / n) << 16) | ((sum[1] / n) << 8) | (sum[0] / n);
            const add = row[@min(x + r + 1, wd - 1)];
            const sub = row[if (x >= r) x - r else 0];
            sum[0] = sum[0] + (add & 255) - (sub & 255);
            sum[1] = sum[1] + ((add >> 8) & 255) - ((sub >> 8) & 255);
            sum[2] = sum[2] + ((add >> 16) & 255) - ((sub >> 16) & 255);
        }
    }
}

fn boxBlurV(src: [*]const u32, dst: [*]u32, wd: usize, ht: usize, r: usize) void {
    const n: u32 = @intCast(2 * r + 1);
    for (0..wd) |x| {
        var sum = [3]u32{ 0, 0, 0 };
        var i: isize = -@as(isize, @intCast(r));
        while (i <= @as(isize, @intCast(r))) : (i += 1) {
            const px_ = src[@as(usize, @intCast(@max(0, @min(i, @as(isize, @intCast(ht)) - 1)))) * wd + x];
            sum[0] += px_ & 255;
            sum[1] += (px_ >> 8) & 255;
            sum[2] += (px_ >> 16) & 255;
        }
        for (0..ht) |y| {
            dst[y * wd + x] = 0xFF000000 | ((sum[2] / n) << 16) | ((sum[1] / n) << 8) | (sum[0] / n);
            const add = src[@min(y + r + 1, ht - 1) * wd + x];
            const sub = src[(if (y >= r) y - r else 0) * wd + x];
            sum[0] = sum[0] + (add & 255) - (sub & 255);
            sum[1] = sum[1] + ((add >> 8) & 255) - ((sub >> 8) & 255);
            sum[2] = sum[2] + ((add >> 16) & 255) - ((sub >> 16) & 255);
        }
    }
}

/// Columns of the screen the glass is taken from: the bar at rest plus room to grow and
/// slide while icons are magnified. Capturing only these (not the full screen width) keeps
/// the screen read-back, the shrink and the blur small. Returns true when they changed.
fn glassSpan() bool {
    var a: i32 = 0;
    var b: i32 = cw;
    if (live_glass) {
        const half = restWidthAll() / 2 + pf(BASE) * MAX_SCALE * REACH + pf(PAD_SIDE) + pf(8);
        const mid = @as(f32, @floatFromInt(cw)) / 2;
        a = @max(0, @as(i32, @intFromFloat(@floor(mid - half))));
        a -= @mod(a, GLASS_DOWN);
        b = @min(cw, @as(i32, @intFromFloat(@ceil(mid + half))));
    }
    b -= @mod(b - a, GLASS_DOWN);
    if (a == cap_x0 and b - a == cap_w) return false;
    cap_x0 = a;
    cap_w = b - a;
    gw = @divTrunc(cap_w, GLASS_DOWN);
    glass_hash = 0; // the next capture always counts as new
    return true;
}

/// Grab what is on screen behind the Dock strip and turn it into the glass texture:
/// shrink 4x, blur, lift the colours a little, lay a dark tint over it.
/// Returns true when the picture changed.
fn captureGlass() bool {
    if (gw <= 0 or gh <= 0) return false;
    const screen = w.GetDC(null);
    _ = w.BitBlt(cap_dc, 0, 0, cap_w, cap_h, screen, win_x + cap_x0, win_y + cap_top, 0x00CC0020);
    _ = w.ReleaseDC(null, screen);

    const D = GLASS_DOWN;
    const wd: usize = @intCast(gw);
    const ht: usize = @intCast(gh);
    const full_w: usize = @intCast(cw);
    const a = glass_tmp.ptr.?;
    const b = glass_tmp.ptr.? + wd * ht;
    var hash: u64 = 1469598103934665603;
    for (0..ht) |y| {
        for (0..wd) |x| {
            // Sum the 4x4 block two lanes at a time: red+blue packed in one word, green in
            // another. 16 samples of 8 bits fit in 12 bits, so the lanes never collide.
            var rb: u32 = 0;
            var g: u32 = 0;
            inline for (0..D) |j| {
                const src = cap_bits[(y * D + j) * full_w + x * D ..][0..D];
                inline for (0..D) |i| {
                    rb += src[i] & 0x00FF00FF;
                    g += src[i] & 0x0000FF00;
                }
            }
            const v = ((rb >> 4) & 0x00FF00FF) | ((g >> 4) & 0x0000FF00);
            a[y * wd + x] = v;
            hash = (hash ^ v) *% 1099511628211;
        }
    }
    if (hash == glass_hash) return false;
    glass_hash = hash;

    for (0..3) |_| {
        boxBlurH(a, b, wd, ht, GLASS_BLUR);
        boxBlurV(b, a, wd, ht, GLASS_BLUR);
    }
    const out = glass.ptr.?;
    for (0..wd * ht) |i| {
        const v = a[i];
        var c = [3]i32{ @intCast(v & 255), @intCast((v >> 8) & 255), @intCast((v >> 16) & 255) };
        const lum = (c[2] * 54 + c[1] * 183 + c[0] * 19) >> 8;
        for (&c) |*ch_| {
            const vivid = @max(0, @min(255, lum + @divTrunc((ch_.* - lum) * 8, 5))); // saturation x1.6
            ch_.* = @divTrunc(vivid * 42 + 34 * 58, 100); // 58% dark tint
        }
        out[i] = 0xFF000000 | (@as(u32, @intCast(c[2])) << 16) | (@as(u32, @intCast(c[1])) << 8) | @as(u32, @intCast(c[0]));
    }
    return true;
}

const GK: f32 = 65536.0 / @as(f32, GLASS_DOWN); // window pixel -> glass texel, 16.16

fn glassRows(fy: f32) Rows {
    return Rows.init(glass.ptr.?, gw, gh, @as(i32, @intFromFloat((fy - @as(f32, @floatFromInt(cap_top))) * GK)) - 0x8000);
}

fn glassX(fx: f32) i32 {
    return @as(i32, @intFromFloat((fx - @as(f32, @floatFromInt(cap_x0))) * GK)) - 0x8000;
}

/// The bar: soft shadow outside, frosted glass inside, a light rim along the edge.
/// Most of the bar is plain glass; those pixels are found per row from the shape itself and
/// filled by a tight integer loop. Only the pixels near the edge go through the full
/// distance-field path (shadow, anti-aliasing, rim).
fn drawBar() void {
    const t = barTop();
    const b = barBottom();
    const rad = pf(RADIUS);
    const sigma = pf(7);
    const drop = pf(3);
    const spread = sigma * 3;
    const inv_sheen = 1 / ((b - t) * 0.6);
    const ri = rad - 3; // the inner shape, 3px in from the edge
    const y0: i32 = @max(0, @as(i32, @intFromFloat(t - spread)));
    const x0: i32 = @max(0, @as(i32, @intFromFloat(bar_l - spread)));
    const x1: i32 = @min(cw, @as(i32, @intFromFloat(bar_r + spread)) + 1);
    const step: i32 = 65536 / GLASS_DOWN;
    var y = y0;
    while (y < ch) : (y += 1) {
        const fy = @as(f32, @floatFromInt(y)) + 0.5;
        const row = bits + @as(usize, @intCast(y * cw));
        const sheen = 0.07 * clamp01(1 - (fy - t) * inv_sheen);
        const gr = glassRows(fy);
        const mid = fy >= t + rad and fy <= b - rad; // level with the straight sides
        const mid_s = fy - drop >= t + rad and fy - drop <= b - rad; // ... for the shadow

        // interior span [in0, in1): pixel centres strictly inside the inner shape
        var in0: i32 = x1;
        var in1: i32 = x1;
        if (fy > t + 3 and fy < b - 3) {
            const vy: f32 = if (fy < t + rad) t + rad - fy else if (fy > b - rad) fy - (b - rad) else 0;
            if (vy < ri) {
                const c = if (vy > 0) @sqrt(ri * ri - vy * vy) else ri;
                in0 = @max(x0, @as(i32, @intFromFloat(@floor(bar_l + rad - c - 0.5))) + 1);
                in1 = @min(x1, @as(i32, @intFromFloat(@ceil(bar_r - rad + c - 0.5))));
                if (in1 <= in0) {
                    in0 = x1;
                    in1 = x1;
                }
            }
        }

        if (in1 > in0) {
            // One texel row, blended vertically with the sheen laid over it (both are linear,
            // so this equals doing it per pixel); then each pixel is a single horizontal lerp.
            const sa: u32 = @intFromFloat(sheen * 255);
            const white = (sa << 24) | (sa << 16) | (sa << 8) | sa;
            const ia = 256 - sa;
            var gx = glassX(@as(f32, @floatFromInt(in0)) + 0.5);
            const last: i32 = gw - 1;
            const g0: usize = @intCast(@max(0, @min(gx >> 16, last)));
            const g1: usize = @intCast(@max(0, @min((glassX(@as(f32, @floatFromInt(in1)) + 0.5) >> 16) + 1, last)));
            const tex = glass_row.ptr.?;
            for (g0..g1 + 1) |i| tex[i] = white +% scalePx(lerpPx(gr.r0[i], gr.r1[i], gr.ty), ia);
            const maxx = last << 16;
            var x = in0;
            while (x < in1) : (x += 1) {
                const cx = @max(0, @min(gx, maxx));
                const i: usize = @intCast(cx >> 16);
                const j = @min(i + 1, @as(usize, @intCast(last)));
                row[@intCast(x)] = lerpPx(tex[i], tex[j], @intCast((cx >> 8) & 255)) | 0xFF000000;
                gx += step;
            }
        } else {
            // Rows along the top and bottom edge, and the shadow beyond them. Over the
            // straight part of the bar every pixel is the same distance from the edge, so
            // shadow, coverage, outline and rim are worked out once for the whole row; only
            // the glass changes along it.
            in0 = @max(x0, @as(i32, @intFromFloat(@floor(bar_l + rad - 0.5))) + 1);
            in1 = @min(x1, @as(i32, @intFromFloat(@ceil(bar_r - rad - 0.5))));
            if (in1 <= in0) {
                in0 = x1;
                in1 = x1;
            } else {
                const d = @max(t - fy, fy - b);
                const ds = @max(t - (fy - drop), (fy - drop) - b);
                var k = [2]f32{ 0, 0 }; // alpha and premultiplied grey of all but the glass
                var m: f32 = 1; // how much of the glass shows through the layers above it
                if (d > -0.5 and ds > 0 and ds < spread) over(&k, 0, shadowAt(ds) * clamp01(d + 0.5));
                var cov: f32 = 0;
                if (d < 0.5) {
                    cov = clamp01(0.5 - d);
                    for (&k) |*c| c.* *= 1 - cov; // the glass layer covers what is below it
                    const layers = [3][2]f32{
                        .{ 1, sheen * cov },
                        .{ 0, 0.30 * clamp01(1 - @abs(d) / 0.8) }, // crisp outer line
                        .{ 1, 0.36 * clamp01(1 - @abs(d + 1.2) / 0.9) }, // glass rim
                    };
                    for (layers) |l| {
                        over(&k, l[0], l[1]);
                        m *= 1 - l[1];
                    }
                }
                const ka: u32 = @intFromFloat(k[0] * 255); // rounded down: added to the glass, it must not carry
                const kc: u32 = @intFromFloat(k[1] * 255);
                const kp = (ka << 24) | (kc << 16) | (kc << 8) | kc;
                if (cov <= 0) {
                    @memset(row[@intCast(in0)..@intCast(in1)], kp);
                } else {
                    const ci: u32 = @intFromFloat(cov * m * 256);
                    var gx = glassX(@as(f32, @floatFromInt(in0)) + 0.5);
                    var x = in0;
                    while (x < in1) : (x += 1) {
                        row[@intCast(x)] = scalePx(gr.at(gx), ci) +% kp;
                        gx += step;
                    }
                }
            }
        }

        var x = x0;
        while (x < x1) : (x += 1) {
            if (x == in0) { // jump over the span already filled
                x = in1 - 1;
                continue;
            }
            const fx = @as(f32, @floatFromInt(x)) + 0.5;
            // Beside the straight sides the distance to the edge is just the horizontal one.
            const dx_side = @max(bar_l - fx, fx - bar_r);
            const d = if (mid) dx_side else sdf(fx, fy, bar_l, t, bar_r, b, rad);
            const p = &row[@intCast(x)];
            if (d < -3) { // inside, just outside the span (rounding at its ends)
                p.* = gr.at(glassX(fx));
                blend(x, y, 0xFFFFFF, sheen);
                continue;
            }
            if (d >= spread + drop) continue; // beyond the reach of the shadow
            if (d > -0.5) { // shadow, fading in right at the edge
                const ds = if (mid_s) dx_side else sdf(fx, fy - drop, bar_l, t, bar_r, b, rad);
                if (ds > 0 and ds < spread) blend(x, y, 0x000000, shadowAt(ds) * clamp01(d + 0.5));
            }
            if (d < 0.5) {
                const cov = clamp01(0.5 - d);
                blendPre(p, scalePx(gr.at(glassX(fx)), @intFromFloat(cov * 256)));
                blend(x, y, 0xFFFFFF, sheen * cov);
                blend(x, y, 0x000000, 0.30 * clamp01(1 - @abs(d) / 0.8)); // crisp outer line
                blend(x, y, 0xFFFFFF, 0.36 * clamp01(1 - @abs(d + 1.2) / 0.9)); // glass rim
            }
        }
    }
}

/// Shadow opacity at distance `ds` from the (dropped) bar edge: a gaussian falloff, looked
/// up from a table built on first use for the current DPI.
var shadow_lut: [64]f32 = undefined;
var shadow_lut_dpi: i32 = 0;

fn shadowAt(ds: f32) f32 {
    const spread = pf(7) * 3;
    if (shadow_lut_dpi != dpi) {
        const sigma = pf(7);
        for (&shadow_lut, 0..) |*v, i| {
            const x = @as(f32, @floatFromInt(i)) / 63 * spread;
            v.* = 0.30 * @exp(-(x * x) / (2 * sigma * sigma));
        }
        shadow_lut_dpi = dpi;
    }
    const f = clamp01(ds / spread) * 63;
    const i: usize = @intFromFloat(f);
    const j = @min(i + 1, 63);
    const fr = f - @as(f32, @floatFromInt(i));
    return shadow_lut[i] + (shadow_lut[j] - shadow_lut[i]) * fr;
}

/// Lay a grey layer (0 = black, 1 = white) with opacity `a` over k = {alpha, grey}.
fn over(k: *[2]f32, grey: f32, a: f32) void {
    if (a <= 0) return;
    k[0] = a + k[0] * (1 - a);
    k[1] = grey * a + k[1] * (1 - a);
}

/// Copy a premultiplied square picture onto the canvas 1:1 (no resampling: stays sharp).
fn blit(pic: [*]const u32, size: i32, x: i32, y: i32) void {
    var r: i32 = 0;
    while (r < size) : (r += 1) {
        const yy = y + r;
        if (yy < 0 or yy >= ch) continue;
        const row = bits + @as(usize, @intCast(yy * cw));
        var c: i32 = @max(0, -x);
        while (c < size and x + c < cw) : (c += 1) blendPre(&row[@intCast(x + c)], pic[@intCast(r * size + c)]);
    }
}

/// How much of a pixel lies on an icon of size `s`, `p` being its centre in icon space.
fn edgeCov(p: f32, s: f32) f32 {
    return clamp01(p + 0.5) * clamp01(s - p + 0.5);
}

/// Draw an icon at a fractional position and size. Sampling from the two nearest
/// pre-shrunk copies and blending between them keeps it sharp and free of shimmer
/// while it grows and slides. Texture coordinates are stepped in 16.16 fixed point and
/// only the outermost rows and columns pay for partial coverage.
fn drawIcon(ic: *Icon, fx: f32, fy: f32, fsize: f32) void {
    if (fsize < 2) return;
    var hi: usize = 0;
    while (hi + 1 < MIP.len and @as(f32, @floatFromInt(MIP[hi + 1])) >= fsize) hi += 1;
    const lo = @min(hi + 1, MIP.len - 1);
    const dh: f32 = @floatFromInt(MIP[hi]);
    const dl: f32 = @floatFromInt(MIP[lo]);
    const mix: u32 = if (hi == lo) 256 else @intFromFloat(clamp01((fsize - dl) / (dh - dl)) * 256);
    const kh = dh / fsize * 65536;
    const kl = dl / fsize * 65536;
    const kh_i: i32 = @intFromFloat(kh);
    const kl_i: i32 = @intFromFloat(kl);

    const xa: i32 = @max(@as(i32, @intFromFloat(@floor(fx))), 0);
    const xb: i32 = @min(@as(i32, @intFromFloat(@ceil(fx + fsize))), cw);
    const ya: i32 = @max(@as(i32, @intFromFloat(@floor(fy))), 0);
    const yb: i32 = @min(@as(i32, @intFromFloat(@ceil(fy + fsize))), ch);
    if (xb <= xa or yb <= ya) return;
    const px0 = @as(f32, @floatFromInt(xa)) + 0.5 - fx; // first column, icon space
    const cov_first = edgeCov(px0, fsize);
    const cov_last = edgeCov(@as(f32, @floatFromInt(xb - 1)) + 0.5 - fx, fsize);
    const uh0 = @as(i32, @intFromFloat(px0 * kh)) - 0x8000;
    const ul0 = @as(i32, @intFromFloat(px0 * kl)) - 0x8000;
    const span = xb - xa - 1;
    var tex_h: [256]u32 = undefined;
    var tex_l: [256]u32 = undefined;

    var dy = ya;
    while (dy < yb) : (dy += 1) {
        const py = @as(f32, @floatFromInt(dy)) + 0.5 - fy;
        const cy = edgeCov(py, fsize); // partial coverage on the edge rows
        if (cy <= 0) continue;
        // Blend each mip's two source rows once; every pixel is then a horizontal lerp.
        Rows.init(ic.mips[hi], MIP[hi], MIP[hi], @as(i32, @intFromFloat(py * kh)) - 0x8000).flatten(&tex_h, uh0, uh0 + kh_i * span);
        if (mix < 256) Rows.init(ic.mips[lo], MIP[lo], MIP[lo], @as(i32, @intFromFloat(py * kl)) - 0x8000).flatten(&tex_l, ul0, ul0 + kl_i * span);
        const row = bits + @as(usize, @intCast(dy * cw));
        const edge_row = cy < 0.999;
        var uh = uh0;
        var ul = ul0;
        var dx = xa;
        while (dx < xb) : (dx += 1) {
            var c = hsample(&tex_h, uh, MIP[hi]);
            if (mix < 256) c = lerpPx(hsample(&tex_l, ul, MIP[lo]), c, mix);
            uh += kh_i;
            ul += kl_i;
            if (edge_row or dx == xa or dx == xb - 1) {
                const cov = cy * (if (dx == xa) cov_first else if (dx == xb - 1) cov_last else 1);
                if (cov <= 0) continue;
                if (cov < 0.999) c = scalePx(c, @intFromFloat(cov * 256));
            }
            blendPre(&row[@intCast(dx)], c);
        }
    }
}

/// Render the name of an item once into a coverage mask (GDI text has no alpha of its own).
fn prepareLabel(name: []const u16) void {
    if (label_for == name.ptr) return;
    label_for = name.ptr;
    label_w = 0;
    if (name.len == 0) return;
    const dc = w.CreateCompatibleDC(null);
    defer _ = w.DeleteDC(dc);
    _ = w.SelectObject(dc, f_label);
    var sz = w.SIZE{};
    _ = w.GetTextExtentPoint32W(dc, name.ptr, @intCast(name.len), &sz);
    if (sz.cx <= 0 or sz.cy <= 0) return;
    var raw: ?*anyopaque = null;
    const bi = w.BITMAPINFOHEADER{ .biWidth = sz.cx, .biHeight = -sz.cy };
    const bmp = w.CreateDIBSection(dc, &bi, 0, &raw, null, 0);
    if (bmp == null or raw == null) return;
    defer _ = w.DeleteObject(bmp);
    const old = w.SelectObject(dc, bmp);
    _ = w.PatBlt(dc, 0, 0, sz.cx, sz.cy, 0x00000042);
    _ = w.SetBkMode(dc, 1);
    _ = w.SetTextColor(dc, 0x00FFFFFF);
    var rc = w.RECT{ .right = sz.cx, .bottom = sz.cy };
    _ = w.DrawTextW(dc, name.ptr, @intCast(name.len), &rc, 0x20 | 0x800);
    _ = w.SelectObject(dc, old);
    const n: usize = @intCast(sz.cx * sz.cy);
    const src: [*]const u32 = @ptrCast(@alignCast(raw.?));
    label_mask.clear();
    label_mask.ensure(n);
    for (src[0..n]) |p| label_mask.push(@intCast((p >> 8) & 255));
    label_w = sz.cx;
    label_h = sz.cy;
}

fn labelWidth() f32 {
    return @as(f32, @floatFromInt(label_w)) + pf(11) * 2;
}

/// Left edge of the name label above `it`, kept on screen.
fn labelLeft(it: *const Item) f32 {
    const wd = labelWidth();
    const l = it.x + it.size / 2 - wd / 2;
    return @max(pf(4), @min(l, @as(f32, @floatFromInt(cw)) - wd - pf(4)));
}

fn drawLabel(l: f32, icon_top: f32) void {
    if (label_w == 0) return;
    const h = pf(LABEL_H);
    const wd = labelWidth();
    const b = icon_top - pf(9);
    const t = b - h;
    const a = clamp01((mag - 0.35) * 2.2); // fades in as the icon grows
    fillRound(l - 1, t - 1, l + wd + 1, b + 1, h / 2 + 1, 0xFFFFFF, 0.16 * a);
    fillRound(l, t, l + wd, b, h / 2, 0x26262A, 0.92 * a);
    const tx: i32 = @intFromFloat(@round(l + pf(11)));
    const ty: i32 = @intFromFloat(@round(t + (h - @as(f32, @floatFromInt(label_h))) / 2));
    const ai: u32 = @intFromFloat(a * 256);
    const mask = label_mask.items();
    var y: i32 = 0;
    while (y < label_h) : (y += 1) {
        const yy = ty + y;
        if (yy < 0 or yy >= ch) continue;
        const row = bits + @as(usize, @intCast(yy * cw));
        const m = mask[@intCast(y * label_w)..];
        var x: i32 = @max(0, -tx);
        while (x < label_w and tx + x < cw) : (x += 1) {
            const v = (@as(u32, m[@intCast(x)]) * ai) >> 8; // white text, premultiplied
            if (v != 0) blendPre(&row[@intCast(tx + x)], (v << 24) | (v << 16) | (v << 8) | v);
        }
    }
}

// ================================================================ layout

fn restWidth(it: *const Item) f32 {
    return switch (it.kind) {
        .sep => pf(SEP_W),
        .tray => pf(TRAY_SLOT),
        else => pf(BASE),
    };
}

fn restWidthAll() f32 {
    var total: f32 = 0;
    for (items.items()) |*it| total += restWidth(it);
    if (items.len > 1) total += pf(GAP) * @as(f32, @floatFromInt(items.len - 1));
    return total;
}

fn magnifies(it: *const Item) bool {
    return it.kind == .app or it.kind == .trash;
}

/// Work out every icon's size and place. Icons near the cursor grow following a cosine
/// bump; the row is then re-anchored so the spot under the cursor does not slide away.
fn layout() void {
    const list = items.items();
    const gap = pf(GAP);
    const base = pf(BASE);
    var rest_w: f32 = 0;
    for (list) |*it| rest_w += restWidth(it);
    if (list.len > 1) rest_w += gap * @as(f32, @floatFromInt(list.len - 1));
    const left0 = (@as(f32, @floatFromInt(cw)) - rest_w) / 2;
    const reach = base * REACH;

    var x = left0;
    var total: f32 = 0;
    for (list) |*it| {
        const w0 = restWidth(it);
        it.rest_c = x + w0 / 2;
        x += w0 + gap;
        it.size = w0;
        if (magnifies(it) and mag > 0.001) {
            const d = @min(@abs(mouse_x - it.rest_c) / reach, 1);
            it.size = base * (1 + (MAX_SCALE - 1) * mag * (@cos(d * 3.14159265) + 1) / 2);
        }
        total += it.size;
    }
    if (list.len > 1) total += gap * @as(f32, @floatFromInt(list.len - 1));

    // Map the cursor's resting coordinate into the grown row and keep the two aligned.
    var left = left0;
    if (mag > 0.001) {
        const uu = @max(left0, @min(mouse_x, left0 + rest_w));
        var rx = left0;
        var sx: f32 = 0;
        var mapped: f32 = total;
        for (list) |*it| {
            const w0 = restWidth(it);
            if (uu <= rx + w0) {
                mapped = sx + @max(0, uu - rx) / w0 * it.size;
                break;
            }
            if (uu <= rx + w0 + gap) {
                mapped = sx + it.size + (uu - rx - w0);
                break;
            }
            rx += w0 + gap;
            sx += it.size + gap;
        }
        left = uu - mapped;
    }

    hover = null;
    x = left;
    for (list, 0..) |*it, i| {
        it.x = x;
        if (hovering and it.kind != .sep and mouse_x >= x - gap / 2 and mouse_x < x + it.size + gap / 2) hover = i;
        x += it.size + gap;
    }
    bar_l = left - pf(PAD_SIDE);
    bar_r = left + total + pf(PAD_SIDE);
}

fn render() void {
    if (dock == null or fullscreen) return;
    layout();

    // The columns this frame touches: the bar with its shadow, plus the name label.
    const spread = pf(7) * 3 + 2;
    var l = bar_l - spread;
    var r = bar_r + spread;
    var label_l: f32 = 0;
    var label: ?*const Item = null;
    if (hover) |hi| {
        if (mag > 0.35 and pv_item == null and hi < items.len) {
            const it = &items.items()[hi];
            prepareLabel(it.name);
            if (label_w > 0) {
                label = it;
                label_l = labelLeft(it);
                l = @min(l, label_l - 2);
                r = @max(r, label_l + labelWidth() + 2);
            }
        }
    }
    // ... and the rows: the bar and its shadow, up to the tallest (or hopping) icon and the label.
    var dirty_top = barTop() - spread;
    var tallest: f32 = 0;
    for (items.items()) |*it| {
        var s = it.size;
        if (it.bounce_at != 0) s += pf(16);
        tallest = @max(tallest, s);
    }
    dirty_top = @min(dirty_top, barBottom() - pf(PAD_BOT) - tallest - 1);
    if (label != null) dirty_top = 0;
    const cur_l: i32 = @max(0, @as(i32, @intFromFloat(@floor(l))));
    const cur_r: i32 = @min(cw, @as(i32, @intFromFloat(@ceil(r))));
    const cur_t: i32 = @max(0, @as(i32, @intFromFloat(@floor(dirty_top))));
    // Clear and resend only what was drawn last frame or is drawn now.
    var dl = @min(cur_l, drawn_l);
    var dr = @max(cur_r, drawn_r);
    var dt = @min(cur_t, drawn_t);
    if (full_redraw) {
        dl = 0;
        dr = cw;
        dt = 0;
        full_redraw = false;
    }
    drawn_l = cur_l;
    drawn_r = cur_r;
    drawn_t = cur_t;
    if (dr <= dl) return;
    const span: usize = @intCast(dr - dl);
    var y: i32 = dt;
    while (y < ch) : (y += 1) @memset(bits[@intCast(y * cw + dl)..][0..span], 0);

    drawBar();
    const now = w.GetTickCount64();
    const icon_bottom = barBottom() - pf(PAD_BOT);
    for (items.items()) |*it| {
        switch (it.kind) {
            .sep => {
                const cx: i32 = @intFromFloat(@round(it.x + it.size / 2));
                var yy: i32 = @intFromFloat(icon_bottom - pf(BASE) + pf(6));
                while (yy < @as(i32, @intFromFloat(icon_bottom - pf(6)))) : (yy += 1) blend(cx, yy, 0xFFFFFF, 0.28);
                continue;
            },
            .tray => { // small, never magnified, centred in the bar, on whole pixels
                const s: f32 = @floatFromInt(tray_px);
                const ix: i32 = @intFromFloat(@round(it.x + (it.size - s) / 2));
                const iy: i32 = @intFromFloat(@round(icon_bottom - pf(BASE) / 2 - s / 2));
                const fx: f32 = @floatFromInt(ix);
                const fy: f32 = @floatFromInt(iy);
                if (hover != null and &items.items()[hover.?] == it)
                    fillRound(fx - pf(5), fy - pf(5), fx + s + pf(5), fy + s + pf(5), pf(6), 0xFFFFFF, 0.16);
                if (it.tray.pix) |pic| blit(pic, tray_px, ix, iy);
                continue;
            },
            else => {},
        }
        // Launch feedback: the icon hops until its window shows up (or ~3 s pass).
        var lift: f32 = 0;
        if (it.bounce_at != 0) {
            const t: f32 = @floatFromInt(now - it.bounce_at);
            lift = @abs(@sin(t / 420 * 3.14159265)) * pf(16);
        }
        const top = icon_bottom - it.size - lift;
        if (it.icon) |ic| {
            drawIcon(ic, it.x, top, it.size);
        } else {
            fillRound(it.x + 2, top + 2, it.x + it.size - 2, top + it.size - 2, it.size * 0.22, 0x8E8E93, 0.9);
        }
        if (it.nwins > 0) { // running dots: one per open window, at most three
            const rr = pf(2);
            const n: f32 = @floatFromInt(@min(it.nwins, 3));
            const step = pf(7);
            const cy = barBottom() - pf(5);
            var cx = it.x + it.size / 2 - step * (n - 1) / 2;
            var k: f32 = 0;
            while (k < n) : (k += 1) {
                fillRound(cx - rr, cy - rr, cx + rr, cy + rr, rr, 0xFFFFFF, 0.9);
                cx += step;
            }
        }
    }
    if (label) |it| drawLabel(label_l, if (it.kind == .tray) icon_bottom - pf(BASE) else icon_bottom - it.size);
    present(dl, dt, dr);
}

/// Hand the canvas to the window, telling it which part changed so only that is copied.
fn present(dl: i32, dt: i32, dr: i32) void {
    const size = w.SIZE{ .cx = cw, .cy = ch };
    const src = w.POINT{};
    const dst = w.POINT{ .x = win_x, .y = win_y };
    const bf = w.BLENDFUNCTION{};
    const dirty_rc = w.RECT{ .left = dl, .top = dt, .right = dr, .bottom = ch };
    const info = w.UPDATELAYEREDWINDOWINFO{ .pptDst = &dst, .psize = &size, .hdcSrc = canvas_dc, .pptSrc = &src, .pblend = &bf, .dwFlags = 2, .prcDirty = &dirty_rc };
    if (w.UpdateLayeredWindowIndirect(dock, &info) == 0)
        _ = w.UpdateLayeredWindow(dock, null, &dst, &size, canvas_dc, &src, 0, &bf, 2); // ULW_ALPHA
}

// ================================================================ items

fn stem(path: []const u16) []const u16 {
    var a: usize = 0;
    var b: usize = path.len;
    for (path, 0..) |c, i| {
        if (c == '\\' or c == '/') a = i + 1;
    }
    var i = b;
    while (i > a) : (i -= 1) {
        if (path[i - 1] == '.') {
            b = i - 1;
            break;
        }
    }
    return path[a..b];
}

/// "FileDescription" from an exe's version info, e.g. "Google Chrome".
fn exeDescription(path: w.WSTR, out: []u16) usize {
    const size = w.GetFileVersionInfoSizeW(path, null);
    if (size == 0 or size > 1 << 20) return 0;
    const buf = u.alloc(size);
    defer u.free(buf);
    if (w.GetFileVersionInfoW(path, 0, size, buf) == 0) return 0;
    var val: ?*anyopaque = null;
    var len: u32 = 0;
    if (w.VerQueryValueW(buf, L("\\VarFileInfo\\Translation"), &val, &len) == 0 or len < 4) return 0;
    const tr: [*]align(1) const u16 = @ptrCast(val.?);
    var key: [64]u16 = undefined;
    const head = L("\\StringFileInfo\\");
    @memcpy(key[0..head.len], head);
    var n: usize = head.len;
    const hex = "0123456789abcdef";
    for ([2]u16{ tr[0], tr[1] }) |v| {
        for ([4]u4{ 12, 8, 4, 0 }) |s| {
            key[n] = hex[(v >> s) & 15];
            n += 1;
        }
    }
    const tail = L("\\FileDescription");
    @memcpy(key[n..][0..tail.len], tail);
    key[n + tail.len] = 0;
    if (w.VerQueryValueW(buf, @ptrCast(&key), &val, &len) == 0 or len < 2) return 0;
    const s: [*]align(1) const u16 = @ptrCast(val.?);
    var k: usize = 0;
    while (k < len and k < out.len and s[k] != 0) : (k += 1) out[k] = s[k];
    return k;
}

/// Display name the shell uses for a shell: item (Store apps, Recycle Bin).
fn shellName(target: w.WSTR, out: []u16) usize {
    var raw: ?*anyopaque = null;
    if (w.SHCreateItemFromParsingName(target, null, &IID_IShellItem, &raw) != 0) return 0;
    const item = raw orelse return 0;
    defer _ = u.method(item, 2, FnRelease)(item);
    const FnName = *const fn (*anyopaque, u32, *?[*:0]u16) callconv(.winapi) i32;
    var name: ?[*:0]u16 = null;
    if (u.method(item, 5, FnName)(item, 0, &name) != 0) return 0;
    const p = name orelse return 0;
    defer w.CoTaskMemFree(p);
    const s = u.sliceZ(p);
    const n = @min(s.len, out.len);
    @memcpy(out[0..n], s[0..n]);
    return n;
}

fn niceName(id: [:0]const u16, out: []u16) []u16 {
    var n: usize = 0;
    if (u.startsWithCI(id, L("shell:"))) n = shellName(id.ptr, out) else n = exeDescription(id.ptr, out);
    if (n == 0) {
        const s = stem(id);
        n = @min(s.len, out.len);
        @memcpy(out[0..n], s[0..n]);
    }
    return out[0..n];
}

fn findItem(id: []const u16) ?*Item {
    for (items.items()) |*it| {
        if (it.kind == .app and u.eqlCI(it.id, id)) return it;
    }
    return null;
}

/// Apps go before the first separator, background-app icons just before the Recycle Bin.
fn addItem(kind: Kind, id: []const u16, launch: []const u16, name: []const u16, pinned: bool) *Item {
    var nb: [200]u16 = undefined;
    const idz = u.dupZ(id);
    const it = Item{
        .kind = kind,
        .id = idz,
        .launch = u.dupZ(launch),
        .name = u.dupZ(if (name.len > 0 or kind == .sep) name else niceName(idz, &nb)),
        .pinned = pinned,
        .icon = if (kind == .sep) null else loadIcon(idz.ptr),
    };
    return insertItem(it);
}

fn insertItem(it: Item) *Item {
    items.push(it);
    const list = items.items();
    var at = list.len - 1;
    switch (it.kind) {
        .app => while (at > 0 and list[at - 1].kind != .app) : (at -= 1) {
            list[at] = list[at - 1];
        },
        .tray => while (at > 0 and list[at - 1].kind == .trash) : (at -= 1) {
            list[at] = list[at - 1];
        },
        else => {},
    }
    list[at] = it;
    label_for = null;
    return &list[at];
}

fn removeItem(idx: usize) void {
    const list = items.items();
    const it = list[idx];
    u.free(it.id.ptr);
    u.free(it.launch.ptr);
    u.free(it.name.ptr);
    freeIcon(it.icon);
    if (it.tray.pix) |pic| u.free(pic);
    for (idx..list.len - 1) |i| list[i] = list[i + 1];
    items.len -= 1;
    label_for = null;
    if (hover) |h| {
        if (h >= items.len) hover = null;
    }
}

// ---- pinned apps, stored as "id|launch|name" lines in the registry

fn savePins() void {
    var out: u.List(u16) = .{};
    defer out.deinit();
    for (items.items()) |it| {
        if (it.kind != .app or !it.pinned) continue;
        out.appendSlice(it.id);
        out.push('|');
        out.appendSlice(it.launch);
        out.push('|');
        out.appendSlice(it.name);
        out.push('\n');
    }
    out.push(0);
    u.regSetStrZ(u.APP_KEY, L("DockPins"), out.items()[0 .. out.len - 1 :0]);
}

const CLSID_ShellLink = w.GUID{ .a = 0x00021401, .b = 0, .c = 0, .d = .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 } };
const IID_IShellLinkW = w.GUID{ .a = 0x000214F9, .b = 0, .c = 0, .d = .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 } };
const IID_IPersistFile = w.GUID{ .a = 0x0000010B, .b = 0, .c = 0, .d = .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 } };

/// The exe a .lnk points at ("" for shortcuts that are not plain files).
fn shortcutTarget(lnk: w.WSTR, out: *[300]u16) []u16 {
    out[0] = 0;
    var raw: ?*anyopaque = null;
    if (w.CoCreateInstance(&CLSID_ShellLink, null, 1, &IID_IShellLinkW, &raw) != 0) return out[0..0];
    const link = raw orelse return out[0..0];
    defer _ = u.method(link, 2, FnRelease)(link);
    const FnQuery = *const fn (*anyopaque, *const w.GUID, *?*anyopaque) callconv(.winapi) i32;
    var raw_file: ?*anyopaque = null;
    if (u.method(link, 0, FnQuery)(link, &IID_IPersistFile, &raw_file) != 0) return out[0..0];
    const file = raw_file orelse return out[0..0];
    defer _ = u.method(file, 2, FnRelease)(file);
    const FnLoad = *const fn (*anyopaque, w.WSTR, u32) callconv(.winapi) i32;
    if (u.method(file, 5, FnLoad)(file, lnk, 0) != 0) return out[0..0];
    const FnGetPath = *const fn (*anyopaque, [*]u16, i32, ?*anyopaque, u32) callconv(.winapi) i32;
    _ = u.method(link, 3, FnGetPath)(link, out, 300, null, 0);
    return out[0..u.lenZ(out)];
}

/// First run: File Explorer plus whatever the user already pinned to the Windows taskbar.
fn defaultPins() void {
    var env: [300]u16 = undefined;
    var buf: [700]u16 = undefined;
    const explorer = u.join(&buf, &.{ u.envVar(L("SystemRoot"), &env), L("\\explorer.exe") });
    _ = addItem(.app, explorer, explorer, L("File Explorer"), true);

    var dir_buf: [700]u16 = undefined;
    const dir = u.join(&dir_buf, &.{ u.envVar(L("APPDATA"), &env), L("\\Microsoft\\Internet Explorer\\Quick Launch\\User Pinned\\TaskBar\\") });
    var pat: [720]u16 = undefined;
    var fd: w.WIN32_FIND_DATAW = undefined;
    const h = w.FindFirstFileExW(u.join(&pat, &.{ dir, L("*.lnk") }), 1, &fd, 0, null, 0);
    if (h == w.INVALID) return;
    defer _ = w.FindClose(h);
    while (true) {
        const file = u.sliceZ(&fd.cFileName);
        var lnk_buf: [1000]u16 = undefined;
        const lnk = u.join(&lnk_buf, &.{ dir, file });
        var target: [300]u16 = undefined;
        const exe = shortcutTarget(lnk, &target);
        if (exe.len > 4 and u.endsWithCI(exe, L(".exe")) and findItem(exe) == null)
            _ = addItem(.app, exe, lnk, file[0 .. file.len - 4], true);
        if (w.FindNextFileW(h, &fd) == 0) break;
    }
}

fn loadItems() void {
    const buf: [*]u16 = @ptrCast(@alignCast(u.alloc(32768 * 2)));
    defer u.free(buf);
    if (u.regGetStr(u.APP_KEY, L("DockPins"), buf[0..32768])) |all| {
        var start: usize = 0;
        for (all, 0..) |c, i| {
            if (c != '\n') continue;
            const line = all[start..i];
            start = i + 1;
            var cut: [2]usize = .{ 0, 0 };
            var k: usize = 0;
            for (line, 0..) |ch_, j| {
                if (ch_ == '|' and k < 2) {
                    cut[k] = j;
                    k += 1;
                }
            }
            if (k == 2 and cut[0] > 0) _ = addItem(.app, line[0..cut[0]], line[cut[0] + 1 .. cut[1]], line[cut[1] + 1 ..], true);
        }
    } else {
        defaultPins();
        savePins();
    }
    _ = addItem(.sep, L(""), L(""), L(""), false);
    _ = addItem(.trash, L("shell:RecycleBinFolder"), L("shell:RecycleBinFolder"), L("Thùng rác"), false);
}

// ================================================================ running windows

/// Identity of the app owning process `pid`: Store apps by package id, others by exe path.
fn idOfPid(pid: u32, buf: []u16) usize {
    const h = w.OpenProcess(0x1000, 0, pid); // PROCESS_QUERY_LIMITED_INFORMATION
    if (h == null) return 0;
    defer _ = w.CloseHandle(h);
    var aumid: [140]u16 = undefined;
    var len: u32 = aumid.len;
    if (w.GetApplicationUserModelId(h, &len, &aumid) == 0 and len > 1) {
        return u.join(buf, &.{ L("shell:AppsFolder\\"), aumid[0 .. len - 1] }).len;
    }
    var size: u32 = @intCast(buf.len);
    if (w.QueryFullProcessImageNameW(h, 0, buf.ptr, &size) == 0) return 0;
    return size;
}

fn identify(hwnd: w.H, buf: []u16) usize {
    var pid: u32 = 0;
    _ = w.GetWindowThreadProcessId(hwnd, &pid);
    if (pid == 0 or pid == w.GetCurrentProcessId()) return 0;
    var n = idOfPid(pid, buf);
    // Store apps live inside a shared frame process; the real app owns a child window.
    if (u.endsWithCI(buf[0..n], L("\\ApplicationFrameHost.exe"))) {
        n = 0;
        var child: w.H = null;
        while (true) {
            child = w.FindWindowExW(hwnd, child, L("Windows.UI.Core.CoreWindow"), null);
            if (child == null) break;
            var cpid: u32 = 0;
            _ = w.GetWindowThreadProcessId(child, &cpid);
            if (cpid != 0 and cpid != pid) {
                n = idOfPid(cpid, buf);
                break;
            }
        }
    }
    return n;
}

/// The same windows Alt+Tab would list.
fn isAppWindow(hwnd: w.H) bool {
    if (w.IsWindowVisible(hwnd) == 0) return false;
    const ex = w.GetWindowLongPtrW(hwnd, -20);
    const app_window = ex & 0x40000 != 0;
    if (ex & 0x80 != 0 and !app_window) return false; // tool window
    if (ex & 0x08000000 != 0 and !app_window) return false; // never takes focus
    if (w.GetWindow(hwnd, 4) != null and !app_window) return false; // owned dialog
    if (w.GetWindowTextLengthW(hwnd) == 0) return false;
    var cloaked: u32 = 0;
    _ = w.DwmGetWindowAttribute(hwnd, 14, &cloaked, 4); // hidden by the system (other desktop, suspended)
    if (cloaked != 0) return false;
    var cls: [64]u16 = undefined;
    const n = w.GetClassNameW(hwnd, &cls, cls.len);
    const name = cls[0..@intCast(@max(n, 0))];
    const skip = [_][]const u16{ L("Progman"), L("WorkerW"), L("Shell_TrayWnd"), L("Windows.UI.Core.CoreWindow"), L("XamlExplorerHostIslandWindow") };
    for (skip) |s| if (u.eqlCI(name, s)) return false;
    return true;
}

fn enumProc(hwnd: w.H, _: w.LPARAM) callconv(.winapi) w.BOOL {
    if (!isAppWindow(hwnd)) return 1;
    var id: []const u16 = &.{};
    for (seen.items()) |*s| {
        if (s.h == hwnd) {
            s.live = true;
            id = s.id;
            break;
        }
    }
    if (id.len == 0) {
        var buf: [600]u16 = undefined;
        const n = identify(hwnd, &buf);
        if (n == 0) return 1;
        const copy = u.dupZ(buf[0..n]);
        seen.push(.{ .h = hwnd, .id = copy, .live = true });
        id = copy;
    }
    const it = findItem(id) orelse addItem(.app, id, id, L(""), false);
    if (it.nwins < it.wins.len) {
        it.wins[it.nwins] = hwnd;
        it.nwins += 1;
    }
    return 1;
}

/// Re-scan open windows; returns true when the Dock needs redrawing.
fn refresh() bool {
    var before: usize = 0;
    for (items.items()) |*it| {
        before = before *% 31 +% it.nwins +% @intFromPtr(it.id.ptr);
        it.nwins = 0;
    }
    for (seen.items()) |*s| s.live = false;
    _ = w.EnumWindows(enumProc, 0);

    // forget windows that are gone
    var k: usize = 0;
    const sl = seen.items();
    for (sl) |s| {
        if (s.live) {
            sl[k] = s;
            k += 1;
        } else u.free(s.id.ptr);
    }
    seen.len = k;

    const now = w.GetTickCount64();
    var i: usize = 0;
    while (i < items.len) {
        const it = &items.items()[i];
        if (it.bounce_at != 0 and (it.nwins > 0 or now - it.bounce_at > 3000)) it.bounce_at = 0;
        if ((it.kind == .app and !it.pinned and it.nwins == 0 and it.bounce_at == 0) or
            (it.kind == .tray and w.IsWindow(it.tray.hwnd) == 0)) // app ended without saying so
        {
            removeItem(i);
            continue;
        }
        i += 1;
    }
    var after: usize = 0;
    for (items.items()) |*it| after = after *% 31 +% it.nwins +% @intFromPtr(it.id.ptr);
    return after != before;
}

// ================================================================ actions

fn focusWindow(h: w.H) void {
    if (w.IsIconic(h) != 0) _ = w.ShowWindow(h, 9); // restore
    _ = w.SetForegroundWindow(h);
}

fn launchItem(it: *Item) void {
    _ = u.shell(null, it.launch.ptr, null, null);
    if (it.kind == .app) {
        it.bounce_at = w.GetTickCount64();
        startAnim();
    }
}

/// Click: open it, bring it forward, step through its windows, or tuck it away if it is
/// already the one in front.
fn activate(it: *Item) void {
    if (it.kind == .sep) return;
    if (it.kind == .tray) return trayClick(it, .left);
    pv_suppress = it.id.ptr; // the previews would only get in the way now
    hidePreview();
    if (it.kind == .trash or it.nwins == 0) return launchItem(it);
    const fg = w.GetForegroundWindow();
    var in_front = false;
    for (it.wins[0..it.nwins]) |h| {
        if (h == fg) in_front = true;
    }
    if (!in_front) return focusWindow(it.wins[0]); // windows come in z-order: most recent first
    // Several windows: each click brings up the one furthest back, cycling through them all.
    if (it.nwins > 1) return focusWindow(it.wins[it.nwins - 1]);
    _ = w.PostMessageW(fg, 0x0112, 0xF020, 0); // minimise
}

const WIN_CMD = 100; // menu ids 100.. are the app's windows

/// One menu line per open window, titled like the window; the one in front is ticked.
fn appendWindows(menu: w.H, it: *const Item) void {
    const fg = w.GetForegroundWindow();
    for (it.wins[0..it.nwins], 0..) |h, i| {
        var title: [80]u16 = undefined;
        var n: usize = @intCast(@max(0, w.GetWindowTextW(h, &title, 70)));
        if (n >= 69) { // cut long titles with an ellipsis
            title[66] = 0x2026;
            n = 67;
        }
        for (title[0..n]) |*c| {
            if (c.* == '&') c.* = '+'; // '&' would become a menu shortcut underline
        }
        title[n] = 0;
        _ = w.AppendMenuW(menu, if (h == fg) 8 else 0, WIN_CMD + i, @ptrCast(&title));
    }
}

/// Pop a menu just above an item's icon and return the chosen command (0 = none).
fn popupAbove(menu: w.H, it: *const Item) usize {
    const x = win_x + @as(i32, @intFromFloat(it.x + it.size / 2));
    const y = win_y + @as(i32, @intFromFloat(barTop())) - px(8);
    _ = w.SetForegroundWindow(dock);
    const cmd = w.TrackPopupMenu(menu, 0x100 | 0x2 | 0x4 | 0x20, x, y, 0, dock, null); // centred, opening upwards
    _ = w.DestroyMenu(menu);
    return @intCast(@max(cmd, 0));
}

fn itemMenu(idx: usize) void {
    const it = &items.items()[idx];
    if (it.kind == .tray) return trayClick(it, .right); // the app's own menu
    pv_suppress = it.id.ptr;
    hidePreview();
    const menu = w.CreatePopupMenu();
    if (it.kind == .trash) {
        _ = w.AppendMenuW(menu, 0, 1, L("Mở"));
        _ = w.AppendMenuW(menu, 0, 5, L("Đổ thùng rác"));
    } else {
        if (it.nwins > 0) {
            appendWindows(menu, it);
            _ = w.AppendMenuW(menu, 0x800, 0, null);
        }
        _ = w.AppendMenuW(menu, 0, 1, if (it.nwins > 0) L("Cửa sổ mới") else L("Mở"));
        _ = w.AppendMenuW(menu, if (it.pinned) 8 else 0, 2, L("Giữ trong Dock"));
        if (it.nwins > 0) {
            _ = w.AppendMenuW(menu, 0x800, 0, null);
            _ = w.AppendMenuW(menu, 0, 3, if (it.nwins > 1) L("Đóng tất cả cửa sổ") else L("Đóng"));
        }
    }
    var wins: [24]w.H = undefined;
    const nw = it.nwins;
    @memcpy(wins[0..nw], it.wins[0..nw]);
    const id = it.id.ptr;
    const cmd = popupAbove(menu, it);
    if (cmd >= WIN_CMD) {
        if (cmd - WIN_CMD < nw) focusWindow(wins[cmd - WIN_CMD]);
        return;
    }
    // While the menu was open the list may have changed (windows, background-app icons
    // arriving): look the item up again rather than trusting the old pointer.
    const cur = itemById(id) orelse return;
    switch (cmd) {
        1 => launchItem(cur),
        2 => {
            cur.pinned = !cur.pinned;
            savePins();
            if (refresh()) render();
        },
        3 => for (cur.wins[0..cur.nwins]) |h| {
            _ = w.PostMessageW(h, 0x0010, 0, 0);
        },
        5 => _ = w.SHEmptyRecycleBinW(dock, null, 0),
        else => {},
    }
}

// ================================================================ Windows taskbar

/// Explorer's taskbar. While the Dock is on, a window of ours carries the same class name
/// (that is how it receives the background apps' icons), so it is skipped here.
fn explorerTray() w.H {
    var h: w.H = null;
    while (true) {
        h = w.FindWindowExW(null, h, L("Shell_TrayWnd"), null);
        if (h == null or h != tray_wnd) return h;
    }
}

fn eachTaskbar(cmd: i32) void {
    const main = explorerTray();
    if (main != null) _ = w.ShowWindow(main, cmd);
    var h: w.H = null;
    while (true) {
        h = w.FindWindowExW(null, h, L("Shell_SecondaryTrayWnd"), null);
        if (h == null) break;
        _ = w.ShowWindow(h, cmd);
    }
}

/// Hide the taskbar. It is switched to auto-hide first so it stops reserving screen space;
/// the previous setting is written to the registry so it survives even a crash.
fn hideTaskbar() void {
    const tray = explorerTray();
    var abd = w.APPBARDATA{ .hWnd = tray };
    if (u.regGetDword(u.APP_KEY, L("TaskbarState")) == null) {
        const state = w.SHAppBarMessage(4, &abd); // ABM_GETSTATE
        u.regSetDword(u.APP_KEY, L("TaskbarState"), @intCast(state & 0xFF));
    }
    abd.lParam = 1; // ABS_AUTOHIDE
    _ = w.SHAppBarMessage(10, &abd); // ABM_SETSTATE
    eachTaskbar(0);
}

/// Put the taskbar back the way it was. Safe to call when nothing was changed.
pub fn restoreTaskbar() void {
    const state = u.regGetDword(u.APP_KEY, L("TaskbarState")) orelse return;
    var abd = w.APPBARDATA{ .hWnd = explorerTray(), .lParam = @intCast(state) };
    _ = w.SHAppBarMessage(10, &abd);
    u.regDeleteValue(u.APP_KEY, L("TaskbarState"));
    eachTaskbar(4); // show without activating
}

/// The clock and tray icons still live on the taskbar: resting the cursor on the very
/// bottom edge of the screen brings it up; moving away hides it again.
fn peekTaskbar() void {
    var pt = w.POINT{};
    _ = w.GetCursorPos(&pt);
    const bottom = win_y + ch;
    const on_screen = pt.x >= win_x and pt.x < win_x + cw;
    if (!peek) {
        dwell = if (!fullscreen and on_screen and pt.y >= bottom - 1) dwell + 1 else 0;
        if (dwell >= 5) {
            peek = true;
            away = 0;
            eachTaskbar(4);
        } else if (tick % 5 == 0) {
            const tray = explorerTray();
            if (tray != null and w.IsWindowVisible(tray) != 0) eachTaskbar(0); // Explorer brought it back
        }
    } else {
        away = if (pt.y < bottom - px(72)) away + 1 else 0;
        if (away >= 10) {
            peek = false;
            dwell = 0;
            eachTaskbar(0);
        }
    }
}

// ================================================================ full-screen apps

/// True when the window in front covers the whole screen the Dock is on: a video, a game,
/// a browser in F11, a slideshow. (Windows' own notice, ABN_FULLSCREENAPP, misses many.)
fn fullscreenInFront() bool {
    const fg = w.GetForegroundWindow();
    if (fg == null or fg == dock or fg == preview) return false;
    var pid: u32 = 0;
    _ = w.GetWindowThreadProcessId(fg, &pid);
    if (pid == w.GetCurrentProcessId()) return false;
    var cls: [32]u16 = undefined;
    const n = w.GetClassNameW(fg, &cls, cls.len);
    const name = cls[0..@intCast(@max(n, 0))];
    // the desktop, and shell surfaces that cover the screen for a moment (Alt+Tab, Task
    // View, Start, Search): hiding for those would only make the Dock flicker
    const shell_ = [_][]const u16{ L("Progman"), L("WorkerW"), L("Shell_TrayWnd"), L("Shell_SecondaryTrayWnd"), L("XamlExplorerHostIslandWindow"), L("MultitaskingViewFrame"), L("ForegroundStaging"), L("Windows.UI.Core.CoreWindow") };
    for (shell_) |s| if (u.eqlCI(name, s)) return false;
    var cloaked: u32 = 0;
    _ = w.DwmGetWindowAttribute(fg, 14, &cloaked, 4);
    if (cloaked != 0) return false;
    var r = w.RECT{};
    if (w.GetWindowRect(fg, &r) == 0) return false;
    // A maximised window stops above the Dock (its space is reserved), so it never matches.
    return r.left <= win_x and r.top <= 0 and r.right >= win_x + cw and r.bottom >= win_y + ch;
}

fn setFullscreen(on: bool) void {
    if (on == fullscreen or dock == null) return;
    fullscreen = on;
    if (on) {
        hidePreview();
        _ = w.ShowWindow(dock, 0);
        if (peek) { // the taskbar was peeking: put it away too
            peek = false;
            dwell = 0;
            eachTaskbar(0);
        }
        return;
    }
    if (live_glass) _ = captureGlass(); // what is behind the bar has surely changed
    glass_idle = 0;
    full_redraw = true;
    render();
    _ = w.ShowWindow(dock, 4);
}

fn foregroundChanged(_: w.H, _: u32, _: w.H, _: i32, _: i32, _: u32, _: u32) callconv(.winapi) void {
    if (enabled) setFullscreen(fullscreenInFront());
}

// ================================================================ window previews

const CLASS_PREVIEW = L("TerDockPreview");
const TIMER_PV = 2;
const PV_TICK = 30; // ms between checks while the cursor is around
const PV_DELAY = 350; // resting time on an icon before its previews open
const PV_LINGER = 300; // how long they stay once the cursor has left
const PV_PAD = 8;
const PV_IN = 6; // tile padding
const PV_GAP = 4;
const PV_TITLE = 26;
const PV_TW = 232; // tile width at 96 DPI
const PV_TH = 132; // thumbnail box height for that width

const Thumb = struct { win: w.H, thumb: w.H, tile: w.RECT };

var preview: w.H = null;
var pv_item: ?[*]const u16 = null; // id of the item whose windows are shown
var pv_thumbs: [24]Thumb = undefined;
var pv_n: usize = 0;
var pv_x: i32 = 0;
var pv_y: i32 = 0;
var pv_w: i32 = 0;
var pv_h: i32 = 0;
var pv_hot: ?usize = null; // tile under the cursor
var pv_hot_close = false; // ... and on its close button
var pv_tracking = false;
var pv_timer = false;
var pv_pending: ?[*]const u16 = null;
var pv_wait: u32 = 0;
var pv_away: u32 = 0;
var pv_closed_at: u64 = 0;
var pv_suppress: ?[*]const u16 = null; // clicked: stay shut until the cursor moves on
var pv_refresh_in: u32 = 0;
var pv_ticks: u32 = 0;
var pv_titles: u64 = 0;
var f_pv_title: w.H = null;
var f_pv_icon: w.H = null;

fn itemById(id: [*]const u16) ?*Item {
    for (items.items()) |*it| {
        if (it.id.ptr == id) return it;
    }
    return null;
}

fn startPreviewTimer() void {
    if (pv_timer or dock == null) return;
    pv_timer = w.SetTimer(dock, TIMER_PV, PV_TICK, null) != 0;
}

fn clearThumbs() void {
    for (pv_thumbs[0..pv_n]) |t| {
        if (t.thumb != null) _ = w.DwmUnregisterThumbnail(t.thumb);
    }
    pv_n = 0;
}

fn closeRect(tile: w.RECT) w.RECT {
    const s = px(22);
    const top = tile.top + px(PV_IN) + @divTrunc(px(PV_TITLE) - s, 2);
    return .{ .left = tile.right - px(PV_IN) - s, .top = top, .right = tile.right - px(PV_IN), .bottom = top + s };
}

/// Lay out one tile per window, centred over `cx` (screen x), and hook up a live DWM
/// thumbnail of each window (the system draws and updates them, costing us nothing).
fn buildPreview(it: *const Item, cx: i32) void {
    clearThumbs();
    pv_item = it.id.ptr;
    pv_hot = null;
    pv_hot_close = false;
    const pad = px(PV_PAD);
    const gap = px(PV_GAP);
    const room = cw - px(16) - pad * 2;
    var n: i32 = @intCast(@min(it.nwins, pv_thumbs.len));
    if (n == 0) return;
    var tw = px(PV_TW);
    if (n * tw + (n - 1) * gap > room) tw = @max(px(140), @divTrunc(room - (n - 1) * gap, n));
    while (n > 1 and n * tw + (n - 1) * gap > room) n -= 1;
    const inner = tw - px(PV_IN) * 2;
    const th = @divTrunc(inner * PV_TH, PV_TW - PV_IN * 2);
    pv_w = pad * 2 + n * tw + (n - 1) * gap;
    pv_h = pad * 2 + px(PV_IN) * 2 + px(PV_TITLE) + th;
    pv_x = @max(win_x + px(8), @min(cx - @divTrunc(pv_w, 2), win_x + cw - pv_w - px(8)));
    const icon_top = barBottom() - pf(PAD_BOT) - pf(BASE) * MAX_SCALE;
    pv_y = win_y + @as(i32, @intFromFloat(icon_top)) - px(8) - pv_h;
    _ = w.SetWindowPos(preview, @ptrFromInt(~@as(usize, 0)), pv_x, pv_y, pv_w, pv_h, 0x10 | 0x40); // topmost, no activate, show

    var i: usize = 0;
    while (i < @as(usize, @intCast(n))) : (i += 1) {
        const left = pad + @as(i32, @intCast(i)) * (tw + gap);
        const tile = w.RECT{ .left = left, .top = pad, .right = left + tw, .bottom = pv_h - pad };
        var t = Thumb{ .win = it.wins[i], .thumb = null, .tile = tile };
        if (w.DwmRegisterThumbnail(preview, t.win, &t.thumb) == 0) {
            const box = w.RECT{ .left = left + px(PV_IN), .top = pad + px(PV_IN) + px(PV_TITLE), .right = left + tw - px(PV_IN), .bottom = pv_h - pad - px(PV_IN) };
            const bw = box.right - box.left;
            const bh = box.bottom - box.top;
            var ss = w.SIZE{};
            _ = w.DwmQueryThumbnailSourceSize(t.thumb, &ss);
            var dw = bw;
            var dh = bh;
            if (ss.cx > 0 and ss.cy > 0) { // keep the window's shape, never enlarge it
                if (@as(i64, ss.cx) * bh > @as(i64, ss.cy) * bw) {
                    dw = @min(bw, ss.cx);
                    dh = @intCast(@divTrunc(@as(i64, dw) * ss.cy, ss.cx));
                } else {
                    dh = @min(bh, ss.cy);
                    dw = @intCast(@divTrunc(@as(i64, dh) * ss.cx, ss.cy));
                }
            }
            const dx = box.left + @divTrunc(bw - dw, 2);
            const dy = box.top + @divTrunc(bh - dh, 2);
            const props = w.DWM_THUMBNAIL_PROPERTIES{
                .dwFlags = 0x1 | 0x4 | 0x8 | 0x10, // destination, opacity, visible, whole window
                .rcDestination = .{ .left = dx, .top = dy, .right = dx + dw, .bottom = dy + dh },
            };
            _ = w.DwmUpdateThumbnailProperties(t.thumb, &props);
        } else t.thumb = null;
        pv_thumbs[i] = t;
    }
    pv_n = @intCast(n);
    pv_titles = titlesHash();
    _ = w.InvalidateRect(preview, null, 0);
}

fn showPreview(it: *const Item) void {
    buildPreview(it, win_x + @as(i32, @intFromFloat(it.x + it.size / 2)));
    pv_pending = null;
    pv_away = 0;
    dirty = true; // the name label gives way to the previews
    startAnim();
}

fn hidePreview() void {
    if (pv_item == null) return;
    clearThumbs();
    pv_item = null;
    pv_hot = null;
    _ = w.ShowWindow(preview, 0);
    pv_closed_at = w.GetTickCount64();
    if (!over_dock) hovering = false; // the cursor had gone up into the previews and left
    dirty = true;
    startAnim();
}

fn titlesHash() u64 {
    var hsh: u64 = 1469598103934665603;
    for (pv_thumbs[0..pv_n]) |t| {
        var buf: [128]u16 = undefined;
        const n: usize = @intCast(@max(0, w.GetWindowTextW(t.win, &buf, buf.len)));
        for (buf[0..n]) |c| hsh = (hsh ^ c) *% 1099511628211;
        hsh = (hsh ^ 0xFFFF) *% 1099511628211;
    }
    return hsh;
}

/// The area that keeps the previews open: themselves, and the gap down to the bar.
fn inKeepZone(pt: w.POINT) bool {
    return pt.x >= pv_x - px(6) and pt.x < pv_x + pv_w + px(6) and pt.y >= pv_y - px(6) and
        pt.y < win_y + @as(i32, @intFromFloat(barTop())) + px(4);
}

/// Runs every PV_TICK ms while the cursor is on or near the Dock: opens, switches, updates
/// and closes the previews.
fn previewTick() void {
    pv_ticks +%= 1;
    if (pv_refresh_in > 0) { // a window was just closed from the previews
        pv_refresh_in -|= PV_TICK;
        if (pv_refresh_in == 0 and refresh()) {
            dirty = true;
            startAnim();
        }
    }
    var pt = w.POINT{};
    _ = w.GetCursorPos(&pt);

    // the app with open windows the cursor rests on, if any
    var cand: ?[*]const u16 = null;
    if (over_dock and !fullscreen) {
        if (hover) |hi| {
            if (hi < items.len) {
                const it = &items.items()[hi];
                if (it.kind == .app and it.nwins > 0) cand = it.id.ptr;
            }
        }
    }
    if (pv_suppress) |s| {
        if (cand == s) cand = null else pv_suppress = null;
    }

    if (pv_item) |cur| {
        const it = itemById(cur) orelse return hidePreview();
        if (it.nwins == 0) return hidePreview();
        if (cand) |c| {
            if (c != cur) return showPreview(itemById(c).?); // slid to the next app: instant
        }
        if (cand != null or inKeepZone(pt)) {
            pv_away = 0;
        } else {
            pv_away += PV_TICK;
            if (pv_away >= PV_LINGER) return hidePreview();
        }
        // follow windows opening and closing (same set in any order = no change)
        var same = it.nwins == pv_n or (it.nwins > pv_n and pv_n == pv_thumbs.len);
        if (same) {
            for (pv_thumbs[0..pv_n]) |t| {
                var found = false;
                for (it.wins[0..it.nwins]) |h| {
                    if (h == t.win) found = true;
                }
                if (!found) same = false;
            }
        }
        if (!same) return buildPreview(it, pv_x + @divTrunc(pv_w, 2));
        if (pv_ticks % 10 == 0) { // titles change (browser tabs, documents)
            const th = titlesHash();
            if (th != pv_titles) {
                pv_titles = th;
                _ = w.InvalidateRect(preview, null, 0);
            }
        }
        return;
    }

    if (cand) |c| {
        if (pv_pending != c) {
            pv_pending = c;
            pv_wait = 0;
        } else pv_wait += PV_TICK;
        const quick = w.GetTickCount64() -% pv_closed_at < 500; // moving on from other previews
        if (pv_wait >= PV_DELAY or quick) showPreview(itemById(c).?);
        return;
    }
    pv_pending = null;
    pv_wait = 0;
    if (!over_dock and pv_refresh_in == 0) {
        _ = w.KillTimer(dock, TIMER_PV);
        pv_timer = false;
    }
}

fn pvText(dc: w.H, s: []const u16, rc: w.RECT, color: u32, font: w.H, flags: u32) void {
    if (s.len == 0) return;
    var r = rc;
    _ = w.SelectObject(dc, font);
    _ = w.SetTextColor(dc, color);
    _ = w.DrawTextW(dc, s.ptr, @intCast(s.len), &r, flags);
}

fn pvPill(dc: w.H, rc: w.RECT, color: u32, radius: i32) void {
    const br = w.CreateSolidBrush(color);
    const old_b = w.SelectObject(dc, br);
    const old_p = w.SelectObject(dc, w.GetStockObject(8)); // NULL_PEN
    _ = w.RoundRect(dc, rc.left, rc.top, rc.right + 1, rc.bottom + 1, radius, radius);
    _ = w.SelectObject(dc, old_b);
    _ = w.SelectObject(dc, old_p);
    _ = w.DeleteObject(br);
}

/// Titles, hover highlight and close button. The thumbnails themselves are composed on top
/// by DWM. Painted like the launcher: black is clear glass, brightness becomes opacity.
fn paintPreview(hdc: w.H) void {
    if (pv_w <= 0 or pv_h <= 0) return;
    const dc = w.CreateCompatibleDC(hdc);
    defer _ = w.DeleteDC(dc);
    var raw: ?*anyopaque = null;
    const bi = w.BITMAPINFOHEADER{ .biWidth = pv_w, .biHeight = -pv_h };
    const bmp = w.CreateDIBSection(hdc, &bi, 0, &raw, null, 0);
    if (bmp == null or raw == null) return;
    defer _ = w.DeleteObject(bmp);
    const old = w.SelectObject(dc, bmp);
    defer _ = w.SelectObject(dc, old);
    _ = w.PatBlt(dc, 0, 0, pv_w, pv_h, 0x00000042);
    _ = w.SetBkMode(dc, 1);
    for (pv_thumbs[0..pv_n], 0..) |t, i| {
        const hot = pv_hot == i;
        if (hot) pvPill(dc, t.tile, w.rgb(0x46, 0x46, 0x4A), px(10));
        var title: [260]u16 = undefined;
        const n: usize = @intCast(@max(0, w.GetWindowTextW(t.win, &title, title.len)));
        const cr = closeRect(t.tile);
        const tr = w.RECT{ .left = t.tile.left + px(PV_IN) + px(4), .top = t.tile.top + px(PV_IN), .right = if (hot) cr.left - px(4) else t.tile.right - px(PV_IN) - px(4), .bottom = t.tile.top + px(PV_IN) + px(PV_TITLE) };
        pvText(dc, title[0..n], tr, w.rgb(0xF2, 0xF2, 0xF2), f_pv_title, 0x20 | 0x4 | 0x8000 | 0x800); // single line, centred vertically, ellipsis, no prefix
        if (hot) {
            if (pv_hot_close) pvPill(dc, cr, w.rgb(0xC4, 0x2B, 0x1C), px(6));
            pvText(dc, &[_]u16{0xE8BB}, cr, w.rgb(0xF2, 0xF2, 0xF2), f_pv_icon, 0x20 | 0x4 | 0x1);
        }
    }
    const pix: [*]u32 = @ptrCast(@alignCast(raw.?));
    for (pix[0..@intCast(pv_w * pv_h)]) |*p| {
        const v = p.*;
        const a = @max((v >> 16) & 255, @max((v >> 8) & 255, v & 255));
        p.* = (v & 0x00FFFFFF) | (a << 24);
    }
    _ = w.BitBlt(hdc, 0, 0, pv_w, pv_h, dc, 0, 0, 0x00CC0020);
}

fn closeWindowAt(i: usize) void {
    if (i >= pv_n) return;
    _ = w.PostMessageW(pv_thumbs[i].win, 0x0010, 0, 0); // WM_CLOSE
    pv_refresh_in = 240; // look again shortly, once it has had time to go
    startPreviewTimer();
}

fn previewProc(h: w.H, msg: u32, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) w.LRESULT {
    switch (msg) {
        0x0021 => return 3, // WM_MOUSEACTIVATE: never steal focus
        0x0014 => return 1, // WM_ERASEBKGND
        0x000F => { // WM_PAINT
            var ps = w.PAINTSTRUCT{};
            const hdc = w.BeginPaint(h, &ps);
            paintPreview(hdc);
            _ = w.EndPaint(h, &ps);
            return 0;
        },
        0x0200 => { // WM_MOUSEMOVE
            if (!pv_tracking) {
                var tme = w.TRACKMOUSEEVENT{ .hwndTrack = h };
                pv_tracking = w.TrackMouseEvent(&tme) != 0;
            }
            const x: i32 = @as(i16, @truncate(lp));
            const y: i32 = @as(i16, @truncate(lp >> 16));
            var hot: ?usize = null;
            var on_close = false;
            for (pv_thumbs[0..pv_n], 0..) |t, i| {
                if (x >= t.tile.left and x < t.tile.right and y >= t.tile.top and y < t.tile.bottom) {
                    hot = i;
                    const c = closeRect(t.tile);
                    on_close = x >= c.left and x < c.right and y >= c.top and y < c.bottom;
                }
            }
            if (hot != pv_hot or on_close != pv_hot_close) {
                pv_hot = hot;
                pv_hot_close = on_close;
                _ = w.InvalidateRect(h, null, 0);
            }
            return 0;
        },
        0x02A3 => { // WM_MOUSELEAVE
            pv_tracking = false;
            pv_hot = null;
            pv_hot_close = false;
            _ = w.InvalidateRect(h, null, 0);
            return 0;
        },
        0x0202 => { // WM_LBUTTONUP: bring that window forward (or close it)
            const i = pv_hot orelse return 0;
            if (pv_hot_close) {
                closeWindowAt(i);
                return 0;
            }
            const target = pv_thumbs[i].win;
            pv_suppress = pv_item;
            hidePreview();
            focusWindow(target);
            return 0;
        },
        0x0208 => { // WM_MBUTTONUP: middle click closes, like browser tabs
            if (pv_hot) |i| closeWindowAt(i);
            return 0;
        },
        else => {},
    }
    return w.DefWindowProcW(h, msg, wp, lp);
}

// ================================================================ background apps (system tray)
//
// Apps put their tray icons up with Shell_NotifyIcon, which hands the data to the topmost
// window of class "Shell_TrayWnd" by WM_COPYDATA. While the Dock is on, a hidden window
// of ours with that class sits above Explorer's, so every icon comes here first. Each
// message is then passed on to Explorer unchanged, so its own tray stays complete and
// nothing is lost when the Dock is turned off.

const CLASS_TRAY = L("Shell_TrayWnd");
const NI_SIGNATURE = 0x34753423;

var tray_wnd: w.H = null;
var real_tray: w.H = null;
var msg_taskbar_created: u32 = 0;
var tray_dbl = false;

fn findTray(t: *const w.TRAY_NID) ?*Item {
    const h: w.H = @ptrFromInt(@as(usize, t.hWnd));
    const by_guid = t.uFlags & 0x20 != 0;
    for (items.items()) |*it| {
        if (it.kind != .tray) continue;
        if (by_guid) {
            if (it.tray.guid) |g| {
                if (guidEql(g, t.guidItem)) return it;
            }
        } else if (it.tray.hwnd == h and it.tray.uid == t.uID and it.tray.guid == null) return it;
    }
    return null;
}

fn guidEql(a: w.GUID, b: w.GUID) bool {
    return a.a == b.a and a.b == b.b and a.c == b.c and @as(u64, @bitCast(a.d)) == @as(u64, @bitCast(b.d));
}

/// Copy an icon handle's picture at the tray size (the app may destroy the handle right
/// after the call). Same size: copied as is, so it stays perfectly sharp; otherwise each
/// pixel is the area-weighted average of the source pixels it covers.
fn trayPicture(hicon: w.H) ?[*]u32 {
    if (hicon == null) return null;
    var ii = w.ICONINFO{};
    if (w.GetIconInfo(hicon, &ii) == 0) return null;
    defer {
        if (ii.hbmColor != null) _ = w.DeleteObject(ii.hbmColor);
        if (ii.hbmMask != null) _ = w.DeleteObject(ii.hbmMask);
    }
    const color = ii.hbmColor orelse return null; // monochrome icons: not worth the trouble
    var bm = w.BITMAP{};
    if (w.GetObjectW(color, @sizeOf(w.BITMAP), &bm) == 0 or bm.bmWidth <= 0 or bm.bmHeight <= 0 or bm.bmWidth > 256 or bm.bmHeight > 256) return null;
    const n: usize = @intCast(bm.bmWidth * bm.bmHeight);
    const src: [*]u32 = @ptrCast(@alignCast(u.alloc(n * 4)));
    defer u.free(src);
    const mask: [*]u32 = @ptrCast(@alignCast(u.alloc(n * 4)));
    defer u.free(mask);
    var bi = w.BITMAPINFOHEADER{ .biWidth = bm.bmWidth, .biHeight = -bm.bmHeight };
    const dc = w.GetDC(null);
    defer _ = w.ReleaseDC(null, dc);
    if (w.GetDIBits(dc, color, 0, @intCast(bm.bmHeight), src, &bi, 0) == 0) return null;
    var any_alpha = false;
    for (src[0..n]) |p| {
        if (p >> 24 != 0) any_alpha = true;
    }
    if (!any_alpha) { // old-style icon: transparency comes from the AND mask
        var bi2 = w.BITMAPINFOHEADER{ .biWidth = bm.bmWidth, .biHeight = -bm.bmHeight };
        if (ii.hbmMask != null and w.GetDIBits(dc, ii.hbmMask, 0, @intCast(bm.bmHeight), mask, &bi2, 0) != 0) {
            for (src[0..n], mask[0..n]) |*p, m| p.* = if (m & 0xFFFFFF != 0) 0 else p.* | 0xFF000000;
        } else for (src[0..n]) |*p| {
            p.* |= 0xFF000000;
        }
    }
    premultiply(src[0..n]);
    return fitSquare(src, @intCast(bm.bmWidth), @intCast(bm.bmHeight), @intCast(tray_px));
}

fn fitSquare(src: [*]const u32, sw: usize, sh: usize, t: usize) [*]u32 {
    const out: [*]u32 = @ptrCast(@alignCast(u.alloc(t * t * 4)));
    if (sw == t and sh == t) {
        @memcpy(out[0 .. t * t], src[0 .. t * t]);
        return out;
    }
    const kx = @as(f32, @floatFromInt(sw)) / @as(f32, @floatFromInt(t));
    const ky = @as(f32, @floatFromInt(sh)) / @as(f32, @floatFromInt(t));
    for (0..t) |ty| {
        const y0 = @as(f32, @floatFromInt(ty)) * ky;
        const y1 = y0 + ky;
        for (0..t) |tx| {
            const x0 = @as(f32, @floatFromInt(tx)) * kx;
            const x1 = x0 + kx;
            var acc = [4]f32{ 0, 0, 0, 0 };
            var sy: usize = @intFromFloat(@floor(y0));
            while (sy < sh and @as(f32, @floatFromInt(sy)) < y1) : (sy += 1) {
                const fy = @min(y1, @as(f32, @floatFromInt(sy + 1))) - @max(y0, @as(f32, @floatFromInt(sy)));
                var sx: usize = @intFromFloat(@floor(x0));
                while (sx < sw and @as(f32, @floatFromInt(sx)) < x1) : (sx += 1) {
                    const wgt = fy * (@min(x1, @as(f32, @floatFromInt(sx + 1))) - @max(x0, @as(f32, @floatFromInt(sx))));
                    const p = src[sy * sw + sx];
                    inline for (0..4) |c| acc[c] += @as(f32, @floatFromInt((p >> (c * 8)) & 255)) * wgt;
                }
            }
            const area = kx * ky;
            var v: u32 = 0;
            inline for (0..4) |c| v |= @as(u32, @intFromFloat(@min(255, acc[c] / area + 0.5))) << (c * 8);
            out[ty * t + tx] = v;
        }
    }
    return out;
}

/// Text of a tray tooltip as a one-line label.
fn tipName(t: *const w.TRAY_NID) [:0]u16 {
    var buf: [128]u16 = undefined;
    var n: usize = 0;
    for (t.szTip) |c| {
        if (c == 0) break;
        buf[n] = if (c == '\r' or c == '\n' or c == '\t') ' ' else c;
        n += 1;
    }
    while (n > 0 and buf[n - 1] == ' ') n -= 1;
    return u.dupZ(buf[0..n]);
}

/// NIM_ADD / NIM_MODIFY / NIM_DELETE / NIM_SETVERSION from an app.
fn trayMessage(data: *const w.TRAY_DATA) bool {
    const t = &data.nid;
    const existing = findTray(t);
    switch (data.dwMessage) {
        0, 1 => { // add, modify (an add for a known icon is treated as a modify)
            if (data.dwMessage == 1 and existing == null and t.uFlags & 0x2 == 0) return false;
            const it = existing orelse insertItem(.{
                .kind = .tray,
                .id = u.dupZ(L("")),
                .launch = u.dupZ(L("")),
                .name = u.dupZ(L("")),
                .tray = .{ .hwnd = @ptrFromInt(@as(usize, t.hWnd)), .uid = t.uID, .guid = if (t.uFlags & 0x20 != 0) t.guidItem else null },
            });
            if (t.uFlags & 0x1 != 0) it.tray.msg = t.uCallbackMessage;
            if (t.uFlags & 0x2 != 0) {
                if (trayPicture(@ptrFromInt(@as(usize, t.hIcon)))) |pic| {
                    if (it.tray.pix) |old| u.free(old);
                    it.tray.pix = pic;
                }
            }
            if (t.uFlags & 0x4 != 0) {
                u.free(it.name.ptr);
                it.name = tipName(t);
                label_for = null;
            }
            if (t.uFlags & 0x8 != 0 and t.dwStateMask & 1 != 0 and t.dwState & 1 != 0) { // NIS_HIDDEN
                removeItem(@divTrunc(@intFromPtr(it) - @intFromPtr(items.ptr.?), @sizeOf(Item)));
            }
        },
        2 => { // delete
            const it = existing orelse return false;
            removeItem(@divTrunc(@intFromPtr(it) - @intFromPtr(items.ptr.?), @sizeOf(Item)));
        },
        4 => { // set version
            const it = existing orelse return false;
            it.tray.version = t.uVersion;
        },
        else => return true,
    }
    if (pv_item == null) {
        dirty = true;
        startAnim();
    }
    return true;
}

const Click = enum { left, right, double };

/// Pass a click on to the app the way the taskbar would, so it shows its menu or window.
fn trayClick(it: *Item, how: Click) void {
    const t = it.tray;
    if (w.IsWindow(t.hwnd) == 0 or t.msg == 0) return;
    var pid: u32 = 0;
    _ = w.GetWindowThreadProcessId(t.hwnd, &pid);
    _ = w.AllowSetForegroundWindow(pid); // so its menu / window can come to the front
    var pt = w.POINT{};
    _ = w.GetCursorPos(&pt);
    const v4 = t.version >= 4;
    const evs: []const u32 = switch (how) {
        .left => if (v4) &.{ 0x0201, 0x0202, 0x0400 } else &.{ 0x0201, 0x0202 }, // down, up, NIN_SELECT
        .right => if (v4) &.{ 0x0204, 0x0205, 0x007B } else &.{ 0x0204, 0x0205 }, // ..., WM_CONTEXTMENU
        .double => &.{0x0203},
    };
    for (evs) |ev| {
        if (v4) {
            // version 4: anchor point in wParam, event + icon id in lParam
            const x16: u16 = @truncate(@as(u32, @bitCast(pt.x)));
            const y16: u16 = @truncate(@as(u32, @bitCast(pt.y)));
            const wpv = @as(usize, x16) | (@as(usize, y16) << 16);
            _ = w.PostMessageW(t.hwnd, t.msg, wpv, @intCast(((t.uid & 0xFFFF) << 16) | ev));
        } else {
            _ = w.PostMessageW(t.hwnd, t.msg, t.uid, @intCast(ev));
        }
    }
}

fn forward(msg: u32, wp: w.WPARAM, lp: w.LPARAM) w.LRESULT {
    if (real_tray == null or w.IsWindow(real_tray) == 0) real_tray = explorerTray();
    if (real_tray == null) return 0;
    var res: usize = 0;
    if (w.SendMessageTimeoutW(real_tray, msg, wp, lp, 0x2, 1000, &res) == 0) return 0; // SMTO_ABORTIFHUNG
    return @bitCast(res);
}

/// App-bar requests (SHAppBarMessage) are passed to Explorer with one field changed: the
/// id of the process that is to read the request's shared memory block. The caller fills
/// in the owner of "Shell_TrayWnd" - us - while the block itself is made out for Explorer,
/// so as sent Explorer would look for it in the wrong process. (Layout, the same for 32- and
/// 64-bit callers: 64 bytes, block handle at byte 48, process id at 56.)
fn forwardAppBar(cds: *const w.COPYDATASTRUCT, wp: w.WPARAM) w.LRESULT {
    const lp: w.LPARAM = @bitCast(@intFromPtr(cds));
    const src: [*]const u8 = @ptrCast(cds.lpData orelse return forward(0x004A, wp, lp));
    if (cds.cbData != 64) return forward(0x004A, wp, lp);
    var buf: [64]u8 = undefined;
    @memcpy(&buf, src[0..64]);
    if (real_tray == null or w.IsWindow(real_tray) == 0) real_tray = explorerTray();
    var pid: u32 = 0;
    _ = w.GetWindowThreadProcessId(real_tray, &pid);
    if (@as(u32, @bitCast(buf[56..60].*)) == w.GetCurrentProcessId()) buf[56..60].* = @bitCast(pid);
    const copy = w.COPYDATASTRUCT{ .dwData = 0, .cbData = 64, .lpData = &buf };
    return forward(0x004A, wp, @bitCast(@intFromPtr(&copy)));
}

fn trayProc(h: w.H, msg: u32, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) w.LRESULT {
    if (msg == 0x004A) { // WM_COPYDATA
        const cds: *const w.COPYDATASTRUCT = @ptrFromInt(@as(usize, @bitCast(lp)));
        if (cds.dwData == 0) return forwardAppBar(cds, wp);
        const res = forward(msg, wp, lp); // Explorer first: it answers icon-rect queries, keeps its tray whole
        if (cds.dwData == 1 and cds.lpData != null and cds.cbData >= 8) {
            var data: w.TRAY_DATA = zeroed(w.TRAY_DATA);
            const len = @min(cds.cbData, @sizeOf(w.TRAY_DATA));
            @memcpy(@as([*]u8, @ptrCast(&data))[0..len], @as([*]const u8, @ptrCast(cds.lpData.?))[0..len]);
            if (data.dwSignature == NI_SIGNATURE) return @intFromBool(trayMessage(&data));
        }
        return res;
    }
    if (msg == 0x0111) return forward(msg, wp, lp); // WM_COMMAND: tools that drive the taskbar
    if (msg == msg_taskbar_created and msg_taskbar_created != 0) {
        // Explorer restarted: it has a new taskbar, created above ours. Get back on top
        // and ask the apps to send their icons again. (Our own broadcast lands here too;
        // then nothing has changed and it is ignored.)
        const now_real = explorerTray();
        if (now_real != real_tray) {
            real_tray = now_real;
            claimTray();
            if (enabled) hideTaskbar();
        }
        return 0;
    }
    return w.DefWindowProcW(h, msg, wp, lp);
}

fn zeroed(comptime T: type) T {
    var v: T = undefined;
    @memset(@as([*]u8, @ptrCast(&v))[0..@sizeOf(T)], 0);
    return v;
}

/// Put our tray window above Explorer's and have every app (re)send its icons to it.
var claimed_at: u64 = 0;

fn claimTray() void {
    claimed_at = w.GetTickCount64();
    _ = w.SetWindowPos(tray_wnd, @ptrFromInt(~@as(usize, 0)), 0, 0, 0, 0, 0x1 | 0x2 | 0x10); // topmost, no move/size/activate
    _ = w.PostMessageW(@ptrFromInt(0xFFFF), msg_taskbar_created, 0, 0); // HWND_BROADCAST
}

/// Explorer raises its taskbar now and then; when it ends up above ours, new icons would go
/// to it, so take the top again and collect them anew.
fn keepTray() void {
    if (tray_wnd == null) return;
    if (w.FindWindowW(CLASS_TRAY, null) == tray_wnd) return;
    if (w.GetTickCount64() -% claimed_at < 5000) { // just reclaimed: only get back on top
        _ = w.SetWindowPos(tray_wnd, @ptrFromInt(~@as(usize, 0)), 0, 0, 0, 0, 0x1 | 0x2 | 0x10);
    } else claimTray();
}

fn startTray() void {
    if (tray_wnd != null) return;
    real_tray = explorerTray();
    tray_px = @max(16, w.GetSystemMetrics(49)); // SM_CXSMICON
    if (msg_taskbar_created == 0) msg_taskbar_created = w.RegisterWindowMessageW(L("TaskbarCreated"));
    // Hidden, but the size of the Dock's reserved strip: some apps read the "taskbar"
    // rectangle to place their pop-ups above it.
    const sh = w.GetSystemMetrics(1);
    const th = px(MARGIN_BOT + PAD_BOT + BASE + PAD_TOP + 4);
    tray_wnd = w.CreateWindowExW(0x80 | 0x8, CLASS_TRAY, L(""), 0x80000000, 0, sh - th, w.GetSystemMetrics(0), th, null, null, hinst, null);
    if (tray_wnd != null) claimTray();
}

fn stopTray() void {
    if (tray_wnd == null) return;
    const old = tray_wnd;
    tray_wnd = null;
    _ = w.DestroyWindow(old);
    // Explorer already has every icon (each message was passed on), but ask once more in
    // case one slipped by while it was busy.
    _ = w.PostMessageW(@ptrFromInt(0xFFFF), msg_taskbar_created, 0, 0);
}

// ================================================================ windows

fn clock() i64 {
    var t: i64 = 0;
    _ = w.QueryPerformanceCounter(&t);
    return t;
}

/// Frames are paced by a helper thread that waits for the screen's refresh (DwmFlush) and
/// then asks the window to draw one frame: exactly one frame per refresh, never late ones
/// piling up. A plain WM_TIMER is too coarse and uneven for smooth motion.
fn animThread(_: ?*anyopaque) callconv(.winapi) u32 {
    while (true) {
        _ = w.WaitForSingleObject(anim_event, 0xFFFFFFFF);
        while (animating) {
            _ = w.DwmFlush();
            const target = dock;
            if (target == null) break;
            _ = w.SendMessageW(target, WM_FRAME, 0, 0);
        }
    }
}

fn startAnim() void {
    if (animating or dock == null) return;
    last_frame = clock();
    animating = true;
    _ = w.SetEvent(anim_event);
}

/// Advance the animation by the real time that passed and draw. Stops by itself once
/// nothing is moving any more.
fn frame() void {
    const t = clock();
    const dt_ms = @max(1, @min(@as(f32, @floatFromInt(t - last_frame)) * 1000 / @as(f32, @floatFromInt(qpf)), 50));
    last_frame = t;
    const target: f32 = if (hovering) 1 else 0;
    var moving = dirty;
    dirty = false;
    if (mag != target) {
        mag += (target - mag) * (1 - @exp(-dt_ms / EASE_MS));
        if (@abs(target - mag) < 0.002) mag = target;
        moving = true;
    }
    for (items.items()) |it| {
        if (it.bounce_at != 0) moving = true;
    }
    if (!moving) {
        animating = false;
        return;
    }
    render();
}

fn itemAt(x: i32) ?usize {
    mouse_x = @floatFromInt(x);
    layout();
    return hover;
}

fn dockProc(h: w.H, msg: u32, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) w.LRESULT {
    switch (msg) {
        0x0021 => return 3, // WM_MOUSEACTIVATE: never take focus away from the app in use
        0x0200 => { // WM_MOUSEMOVE
            mouse_x = @floatFromInt(@as(i16, @truncate(lp)));
            hovering = true;
            over_dock = true;
            startPreviewTimer();
            if (!tracking) {
                var tme = w.TRACKMOUSEEVENT{ .hwndTrack = h };
                tracking = w.TrackMouseEvent(&tme) != 0;
            }
            dirty = true; // drawn on the next screen refresh, not once per mouse message
            startAnim();
            return 0;
        },
        0x02A3 => { // WM_MOUSELEAVE
            tracking = false;
            over_dock = false;
            // Going up into the previews keeps the icons magnified underneath them.
            if (pv_item == null) hovering = false;
            startAnim();
            return 0;
        },
        0x0202 => { // WM_LBUTTONUP
            hovering = true;
            if (itemAt(@as(i16, @truncate(lp)))) |i| {
                if (tray_dbl) {
                    tray_dbl = false; // the release after a double click: already handled
                } else activate(&items.items()[i]);
            }
            return 0;
        },
        0x0203 => { // WM_LBUTTONDBLCLK: some background apps open their window only on this
            hovering = true;
            if (itemAt(@as(i16, @truncate(lp)))) |i| {
                const it = &items.items()[i];
                if (it.kind == .tray) {
                    trayClick(it, .double);
                    tray_dbl = true;
                }
            }
            return 0;
        },
        0x0205 => { // WM_RBUTTONUP
            hovering = true;
            if (itemAt(@as(i16, @truncate(lp)))) |i| itemMenu(i) else if (on_menu) |f| f();
            return 0;
        },
        0x0113 => { // WM_TIMER
            if (wp == TIMER_PV) {
                previewTick();
                return 0;
            }
            tick +%= 1;
            setFullscreen(fullscreenInFront());
            peekTaskbar();
            keepTray();
            var redraw = tick % 5 == 0 and refresh();
            if (redraw and glassSpan() and live_glass) _ = captureGlass(); // the bar changed length
            // Keep the glass in step with whatever is behind it: check often while it is
            // changing (a window being dragged past), rarely while it is still.
            if (live_glass and !fullscreen and (glass_idle < 3 or tick % 4 == 0)) {
                if (captureGlass()) {
                    glass_idle = 0;
                    redraw = true;
                } else glass_idle +|= 1;
            }
            if (redraw and !animating) render();
            if (tick % 100 == 0) reloadTrash();
            return 0;
        },
        WM_FRAME => {
            frame();
            return 0;
        },
        WM_APPBAR => { // Windows' hint that a full-screen app started or stopped: check now
            if (wp == 2) setFullscreen(fullscreenInFront());
            return 0;
        },
        0x007E => { // WM_DISPLAYCHANGE: resolution changed, rebuild in the new place
            disable();
            enable();
            return 0;
        },
        else => {},
    }
    return w.DefWindowProcW(h, msg, wp, lp);
}

fn reloadTrash() void {
    for (items.items()) |*it| {
        if (it.kind != .trash) continue;
        const fresh = loadIcon(it.id.ptr) orelse return;
        freeIcon(it.icon);
        it.icon = fresh; // full / empty picture follows the bin
        render();
    }
}

pub fn init(instance: w.H, system_dpi: i32) void {
    hinst = instance;
    dpi = system_dpi;
}

pub fn enable() void {
    if (enabled) return;
    if (!classes_done) {
        const arrow = w.LoadCursorW(null, 32512);
        _ = w.RegisterClassExW(&.{ .style = 0x8, .lpfnWndProc = dockProc, .hInstance = hinst, .hCursor = arrow, .lpszClassName = CLASS_DOCK }); // CS_DBLCLKS
        _ = w.RegisterClassExW(&.{ .lpfnWndProc = previewProc, .hInstance = hinst, .hCursor = arrow, .lpszClassName = CLASS_PREVIEW });
        _ = w.RegisterClassExW(&.{ .lpfnWndProc = trayProc, .hInstance = hinst, .lpszClassName = CLASS_TRAY });
        _ = w.QueryPerformanceFrequency(&qpf);
        anim_event = w.CreateEventW(null, 0, 0, null);
        _ = w.CloseHandle(w.CreateThread(null, 0, animThread, null, 0, null));
        classes_done = true;
    }

    // A strip across the bottom of the primary screen, tall enough for grown icons + label.
    cw = w.GetSystemMetrics(0);
    const screen_h = w.GetSystemMetrics(1);
    ch = px(MARGIN_BOT + PAD_BOT + LABEL_H + 28) + @as(i32, @intFromFloat(pf(BASE) * MAX_SCALE));
    win_x = 0;
    win_y = screen_h - ch;

    // layered (per-pixel alpha) + tool window + topmost + never takes focus
    dock = w.CreateWindowExW(0x80000 | 0x80 | 0x8 | 0x08000000, CLASS_DOCK, L(""), 0x80000000, win_x, win_y, cw, ch, null, null, hinst, null);

    // Glass: capture a strip from a little above the bar down to the screen edge.
    cap_top = @max(0, @as(i32, @intFromFloat(barTop())) - px(48));
    cap_top -= @mod(ch - cap_top, GLASS_DOWN); // whole number of shrunk rows
    cap_h = ch - cap_top;
    gh = @divTrunc(cap_h, GLASS_DOWN);
    var cap_raw: ?*anyopaque = null;
    const cbi = w.BITMAPINFOHEADER{ .biWidth = cw, .biHeight = -cap_h };
    cap_dc = w.CreateCompatibleDC(null);
    cap_bmp = w.CreateDIBSection(cap_dc, &cbi, 0, &cap_raw, null, 0);
    cap_bits = @ptrCast(@alignCast(cap_raw.?));
    _ = w.SelectObject(cap_dc, cap_bmp);
    const gmax: usize = @intCast(@divTrunc(cw, GLASS_DOWN) * gh); // room for the full width
    glass.clear();
    glass.ensure(gmax);
    glass_tmp.clear();
    glass_tmp.ensure(gmax * 2);
    glass_row.clear();
    glass_row.ensure(@intCast(@divTrunc(cw, GLASS_DOWN) + 1));
    glass_idle = 0;
    // Keep our own window out of screen captures so the glass can be refreshed live without
    // photographing itself. (Side effect: the Dock does not appear in screenshots.)
    // TER_DOCK_SHOT=1 turns this off for taking pictures of the Dock; the glass is then static.
    var env: [8]u16 = undefined;
    live_glass = u.envVar(L("TER_DOCK_SHOT"), &env).len == 0 and w.SetWindowDisplayAffinity(dock, 0x11) != 0;

    // Previews of an app's windows, shown on hover. Acrylic like the launcher.
    preview = w.CreateWindowExW(0x80 | 0x8 | 0x08000000, CLASS_PREVIEW, L(""), 0x80000000, 0, 0, 1, 1, dock, null, hinst, null);
    const dark: u32 = 1;
    const round: u32 = 2;
    const border: u32 = w.rgb(0x48, 0x48, 0x4C);
    _ = w.DwmSetWindowAttribute(preview, 20, &dark, 4);
    _ = w.DwmSetWindowAttribute(preview, 33, &round, 4);
    _ = w.DwmSetWindowAttribute(preview, 34, &border, 4);
    const policy = w.ACCENT_POLICY{ .state = 4, .flags = 2, .color = 0xCC201C1C };
    const cad = w.WINCOMPATTRDATA{ .attrib = 19, .data = &policy, .size = @sizeOf(w.ACCENT_POLICY) };
    _ = w.SetWindowCompositionAttribute(preview, &cad);
    if (live_glass) _ = w.SetWindowDisplayAffinity(preview, 0x11); // it overlaps the glass strip
    f_pv_title = w.CreateFontW(-px(12), 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 4, 0, L("Segoe UI Variable Text"));
    f_pv_icon = w.CreateFontW(-px(10), 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 4, 0, L("Segoe Fluent Icons"));

    var raw: ?*anyopaque = null;
    const bi = w.BITMAPINFOHEADER{ .biWidth = cw, .biHeight = -ch };
    canvas_dc = w.CreateCompatibleDC(null);
    canvas_bmp = w.CreateDIBSection(canvas_dc, &bi, 0, &raw, null, 0);
    bits = @ptrCast(@alignCast(raw.?));
    _ = w.SelectObject(canvas_dc, canvas_bmp);
    f_label = w.CreateFontW(-px(13), 0, 0, 0, 500, 0, 0, 0, 1, 0, 0, 4, 0, L("Segoe UI Variable Text"));

    enabled = true;
    mag = 0;
    hovering = false;
    over_dock = false;
    tracking = false;
    animating = false;
    fullscreen = false;
    peek = false;
    dirty = false;
    label_for = null;
    full_redraw = true;
    drawn_l = 0;
    drawn_r = cw;
    drawn_t = 0;
    pv_item = null;
    pv_n = 0;
    pv_timer = false;
    pv_suppress = null;
    pv_pending = null;
    pv_refresh_in = 0;

    loadItems();
    _ = refresh();
    cap_w = -1; // force the span to be worked out
    _ = glassSpan();
    _ = captureGlass(); // first picture, taken before the Dock itself is on screen
    hideTaskbar();

    // Reserve the strip so maximised windows stop above the Dock.
    var abd = w.APPBARDATA{ .hWnd = dock, .uCallbackMessage = WM_APPBAR };
    _ = w.SHAppBarMessage(0, &abd); // ABM_NEW
    abd.uEdge = 3; // bottom
    abd.rc = .{ .left = 0, .top = screen_h - px(MARGIN_BOT + PAD_BOT + BASE + PAD_TOP + 4), .right = cw, .bottom = screen_h };
    _ = w.SHAppBarMessage(2, &abd); // ABM_QUERYPOS
    _ = w.SHAppBarMessage(3, &abd); // ABM_SETPOS
    startTray(); // background apps' icons

    fullscreen = fullscreenInFront();
    render();
    if (!fullscreen) _ = w.ShowWindow(dock, 4);
    _ = w.SetTimer(dock, 1, 100, null);
    if (fg_hook == null) fg_hook = w.SetWinEventHook(0x0003, 0x0003, null, foregroundChanged, 0, 0, 0x2); // foreground changes, out of context, not ours
}

pub fn disable() void {
    if (!enabled) return;
    enabled = false;
    animating = false;
    if (fg_hook != null) _ = w.UnhookWinEvent(fg_hook);
    fg_hook = null;
    clearThumbs();
    pv_item = null;
    stopTray(); // first: app-bar messages must reach Explorer directly
    var abd = w.APPBARDATA{ .hWnd = dock };
    _ = w.SHAppBarMessage(1, &abd); // ABM_REMOVE
    const old = dock;
    dock = null;
    _ = w.DestroyWindow(preview);
    preview = null;
    _ = w.DestroyWindow(old);
    _ = w.DeleteObject(f_pv_title);
    _ = w.DeleteObject(f_pv_icon);
    _ = w.DeleteDC(cap_dc);
    _ = w.DeleteObject(cap_bmp);
    _ = w.DeleteDC(canvas_dc);
    _ = w.DeleteObject(canvas_bmp);
    _ = w.DeleteObject(f_label);
    while (items.len > 0) removeItem(items.len - 1);
    for (seen.items()) |s| u.free(s.id.ptr);
    seen.clear();
    restoreTaskbar();
}
