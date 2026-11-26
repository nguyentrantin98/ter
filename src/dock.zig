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

const WM_APPBAR = 0x8020;
const WM_FRAME = 0x8021;
const CLASS_DOCK = L("TerDock");

const Kind = enum { app, sep, trash };

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
var glass: u.List(u32) = .{};
var glass_tmp: u.List(u32) = .{};
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

var tick: u32 = 0;
var fullscreen = false;
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

    // Normalise: opaque if there is no alpha at all, premultiplied otherwise.
    var any_alpha = false;
    var straight = false;
    for (src[0 .. sw * sh]) |p| {
        const a = p >> 24;
        if (a != 0) any_alpha = true;
        if ((p & 255) > a or ((p >> 8) & 255) > a or ((p >> 16) & 255) > a) straight = true;
    }
    for (src[0 .. sw * sh]) |*p| {
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
    if (used * 2 <= sw) {
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

/// Grab what is on screen behind the Dock strip and turn it into the glass texture:
/// shrink 4x, blur, lift the colours a little, lay a dark tint over it.
/// Returns true when the picture changed.
fn captureGlass() bool {
    const screen = w.GetDC(null);
    _ = w.BitBlt(cap_dc, 0, 0, cw, cap_h, screen, win_x, win_y + cap_top, 0x00CC0020);
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
            var sum = [3]u32{ 0, 0, 0 };
            for (0..D) |j| {
                for (0..D) |i| {
                    const px_ = cap_bits[(y * D + j) * full_w + x * D + i];
                    sum[0] += px_ & 255;
                    sum[1] += (px_ >> 8) & 255;
                    sum[2] += (px_ >> 16) & 255;
                }
            }
            const v = ((sum[2] / (D * D)) << 16) | ((sum[1] / (D * D)) << 8) | (sum[0] / (D * D));
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

fn glassAt(fx: f32, fy: f32) u32 {
    const k: f32 = 65536.0 / @as(f32, GLASS_DOWN);
    return sample(glass.ptr.?, gw, gh, @as(i32, @intFromFloat(fx * k)) - 0x8000, @as(i32, @intFromFloat((fy - @as(f32, @floatFromInt(cap_top))) * k)) - 0x8000);
}

/// The bar: soft shadow outside, frosted glass inside, a light rim along the edge.
fn drawBar() void {
    const t = barTop();
    const b = barBottom();
    const rad = pf(RADIUS);
    const sigma = pf(7);
    const drop = pf(3);
    const spread = sigma * 3;
    const y0: i32 = @max(0, @as(i32, @intFromFloat(t - spread)));
    const x0: i32 = @max(0, @as(i32, @intFromFloat(bar_l - spread)));
    const x1: i32 = @min(cw, @as(i32, @intFromFloat(bar_r + spread)) + 1);
    var y = y0;
    while (y < ch) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            const fx = @as(f32, @floatFromInt(x)) + 0.5;
            const fy = @as(f32, @floatFromInt(y)) + 0.5;
            const d = sdf(fx, fy, bar_l, t, bar_r, b, rad);
            const p = &bits[@intCast(y * cw + x)];
            if (d < -3) { // well inside: glass plus a faint sheen that fades downwards
                p.* = glassAt(fx, fy);
                blend(x, y, 0xFFFFFF, 0.07 * clamp01(1 - (fy - t) / ((b - t) * 0.6)));
                continue;
            }
            if (d > -0.5) { // shadow, fading in right at the edge
                const ds = sdf(fx, fy - drop, bar_l, t, bar_r, b, rad);
                if (ds > 0 and ds < spread) blend(x, y, 0x000000, 0.30 * @exp(-(ds * ds) / (2 * sigma * sigma)) * clamp01(d + 0.5));
            }
            if (d < 0.5) {
                const cov = clamp01(0.5 - d);
                blendPre(p, scalePx(glassAt(fx, fy), @intFromFloat(cov * 256)));
                blend(x, y, 0xFFFFFF, 0.07 * clamp01(1 - (fy - t) / ((b - t) * 0.6)) * cov);
                blend(x, y, 0x000000, 0.30 * clamp01(1 - @abs(d) / 0.8)); // crisp outer line
                blend(x, y, 0xFFFFFF, 0.36 * clamp01(1 - @abs(d + 1.2) / 0.9)); // glass rim
            }
        }
    }
}

/// Draw an icon at a fractional position and size. Sampling from the two nearest
/// pre-shrunk copies and blending between them keeps it sharp and free of shimmer
/// while it grows and slides.
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

    const x0: i32 = @intFromFloat(@floor(fx));
    const x1: i32 = @intFromFloat(@ceil(fx + fsize));
    const y0: i32 = @intFromFloat(@floor(fy));
    const y1: i32 = @intFromFloat(@ceil(fy + fsize));
    var dy = @max(y0, 0);
    while (dy < @min(y1, ch)) : (dy += 1) {
        const py = @as(f32, @floatFromInt(dy)) + 0.5 - fy;
        const cy = clamp01(py + 0.5) * clamp01(fsize - py + 0.5); // partial coverage on the edge rows
        if (cy <= 0) continue;
        const vh = @as(i32, @intFromFloat(py * kh)) - 0x8000;
        const vl = @as(i32, @intFromFloat(py * kl)) - 0x8000;
        var dx = @max(x0, 0);
        while (dx < @min(x1, cw)) : (dx += 1) {
            const pxl = @as(f32, @floatFromInt(dx)) + 0.5 - fx;
            const cov = cy * clamp01(pxl + 0.5) * clamp01(fsize - pxl + 0.5);
            if (cov <= 0) continue;
            var c = sample(ic.mips[hi], MIP[hi], MIP[hi], @as(i32, @intFromFloat(pxl * kh)) - 0x8000, vh);
            if (mix < 256) c = lerpPx(sample(ic.mips[lo], MIP[lo], MIP[lo], @as(i32, @intFromFloat(pxl * kl)) - 0x8000, vl), c, mix);
            if (cov < 0.999) c = scalePx(c, @intFromFloat(cov * 256));
            blendPre(&bits[@intCast(dy * cw + dx)], c);
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

fn drawLabel(it: *const Item, icon_top: f32) void {
    prepareLabel(it.name);
    if (label_w == 0) return;
    const pad = pf(11);
    const h = pf(LABEL_H);
    const wd = @as(f32, @floatFromInt(label_w)) + pad * 2;
    var l = it.x + it.size / 2 - wd / 2;
    l = @max(pf(4), @min(l, @as(f32, @floatFromInt(cw)) - wd - pf(4)));
    const b = icon_top - pf(9);
    const t = b - h;
    const a = clamp01((mag - 0.35) * 2.2); // fades in as the icon grows
    fillRound(l - 1, t - 1, l + wd + 1, b + 1, h / 2 + 1, 0xFFFFFF, 0.16 * a);
    fillRound(l, t, l + wd, b, h / 2, 0x26262A, 0.92 * a);
    const tx: i32 = @intFromFloat(@round(l + pad));
    const ty: i32 = @intFromFloat(@round(t + (h - @as(f32, @floatFromInt(label_h))) / 2));
    var y: i32 = 0;
    while (y < label_h) : (y += 1) {
        var x: i32 = 0;
        while (x < label_w) : (x += 1) {
            const c = label_mask.items()[@intCast(y * label_w + x)];
            if (c != 0) blend(tx + x, ty + y, 0xFFFFFF, @as(f32, @floatFromInt(c)) / 255 * a);
        }
    }
}

// ================================================================ layout

fn restWidth(it: *const Item) f32 {
    return if (it.kind == .sep) pf(SEP_W) else pf(BASE);
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
        if (it.kind != .sep and mag > 0.001) {
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
    @memset(bits[0..@intCast(cw * ch)], 0);
    drawBar();

    const now = w.GetTickCount64();
    const icon_bottom = barBottom() - pf(PAD_BOT);
    for (items.items()) |*it| {
        if (it.kind == .sep) {
            const cx: i32 = @intFromFloat(@round(it.x + it.size / 2));
            const top: i32 = @intFromFloat(icon_bottom - pf(BASE) + pf(6));
            var y = top;
            while (y < @as(i32, @intFromFloat(icon_bottom - pf(6)))) : (y += 1) blend(cx, y, 0xFFFFFF, 0.28);
            continue;
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
            const r = pf(2);
            const n: f32 = @floatFromInt(@min(it.nwins, 3));
            const step = pf(7);
            const cy = barBottom() - pf(5);
            var cx = it.x + it.size / 2 - step * (n - 1) / 2;
            var k: f32 = 0;
            while (k < n) : (k += 1) {
                fillRound(cx - r, cy - r, cx + r, cy + r, r, 0xFFFFFF, 0.9);
                cx += step;
            }
        }
    }
    if (hover) |hi| {
        const it = &items.items()[hi];
        if (mag > 0.35) drawLabel(it, icon_bottom - it.size);
    }

    const size = w.SIZE{ .cx = cw, .cy = ch };
    const src = w.POINT{};
    const dst = w.POINT{ .x = win_x, .y = win_y };
    const bf = w.BLENDFUNCTION{};
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

/// Apps go before the separator; the separator and Recycle Bin stay at the end.
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
    items.push(it);
    const list = items.items();
    var at = list.len - 1;
    if (kind == .app) {
        while (at > 0 and list[at - 1].kind != .app) : (at -= 1) list[at] = list[at - 1];
        list[at] = it;
    }
    return &list[at];
}

fn removeItem(idx: usize) void {
    const list = items.items();
    const it = list[idx];
    u.free(it.id.ptr);
    u.free(it.launch.ptr);
    u.free(it.name.ptr);
    freeIcon(it.icon);
    for (idx..list.len - 1) |i| list[i] = list[i + 1];
    items.len -= 1;
    label_for = null;
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
        if (it.kind == .app and !it.pinned and it.nwins == 0 and it.bounce_at == 0) {
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
    if (it.kind == .trash or it.nwins == 0) return launchItem(it);
    const fg = w.GetForegroundWindow();
    var in_front = false;
    for (it.wins[0..it.nwins]) |h| {
        if (h == fg) in_front = true;
    }
    if (it.nwins > 1) return windowList(it); // several windows: let the user pick
    if (!in_front) return focusWindow(it.wins[0]);
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

fn windowList(it: *Item) void {
    const menu = w.CreatePopupMenu();
    appendWindows(menu, it);
    var wins: [24]w.H = undefined;
    const n = it.nwins;
    @memcpy(wins[0..n], it.wins[0..n]); // the item may be refreshed while the menu is open
    const cmd = popupAbove(menu, it);
    if (cmd >= WIN_CMD and cmd - WIN_CMD < n) focusWindow(wins[cmd - WIN_CMD]);
}

fn itemMenu(idx: usize) void {
    const it = &items.items()[idx];
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
    const cmd = popupAbove(menu, it);
    if (cmd >= WIN_CMD) {
        if (cmd - WIN_CMD < nw) focusWindow(wins[cmd - WIN_CMD]);
        return;
    }
    if (idx >= items.len) return;
    switch (cmd) {
        1 => launchItem(it),
        2 => {
            it.pinned = !it.pinned;
            savePins();
            if (refresh()) render();
        },
        3 => for (it.wins[0..it.nwins]) |h| {
            _ = w.PostMessageW(h, 0x0010, 0, 0);
        },
        5 => _ = w.SHEmptyRecycleBinW(dock, null, 0),
        else => {},
    }
}

// ================================================================ Windows taskbar

fn eachTaskbar(cmd: i32) void {
    const main = w.FindWindowW(L("Shell_TrayWnd"), null);
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
    const tray = w.FindWindowW(L("Shell_TrayWnd"), null);
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
    var abd = w.APPBARDATA{ .hWnd = w.FindWindowW(L("Shell_TrayWnd"), null), .lParam = @intCast(state) };
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
        dwell = if (on_screen and pt.y >= bottom - 1) dwell + 1 else 0;
        if (dwell >= 5) {
            peek = true;
            away = 0;
            eachTaskbar(4);
        } else if (tick % 5 == 0) {
            const tray = w.FindWindowW(L("Shell_TrayWnd"), null);
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
            hovering = false;
            startAnim();
            return 0;
        },
        0x0202 => { // WM_LBUTTONUP
            hovering = true;
            if (itemAt(@as(i16, @truncate(lp)))) |i| activate(&items.items()[i]);
            return 0;
        },
        0x0205 => { // WM_RBUTTONUP
            hovering = true;
            if (itemAt(@as(i16, @truncate(lp)))) |i| itemMenu(i) else if (on_menu) |f| f();
            return 0;
        },
        0x0113 => { // WM_TIMER
            tick +%= 1;
            peekTaskbar();
            var redraw = tick % 5 == 0 and refresh();
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
        WM_APPBAR => { // a full-screen app (video, game) starts or stops: get out of its way
            if (wp == 2) {
                fullscreen = lp != 0;
                _ = w.ShowWindow(dock, if (fullscreen) 0 else 4);
                if (!fullscreen) render();
            }
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
        _ = w.RegisterClassExW(&.{ .lpfnWndProc = dockProc, .hInstance = hinst, .hCursor = arrow, .lpszClassName = CLASS_DOCK });
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
    gw = @divTrunc(cw, GLASS_DOWN);
    gh = @divTrunc(cap_h, GLASS_DOWN);
    var cap_raw: ?*anyopaque = null;
    const cbi = w.BITMAPINFOHEADER{ .biWidth = cw, .biHeight = -cap_h };
    cap_dc = w.CreateCompatibleDC(null);
    cap_bmp = w.CreateDIBSection(cap_dc, &cbi, 0, &cap_raw, null, 0);
    cap_bits = @ptrCast(@alignCast(cap_raw.?));
    _ = w.SelectObject(cap_dc, cap_bmp);
    glass.clear();
    glass.ensure(@intCast(gw * gh));
    glass_tmp.clear();
    glass_tmp.ensure(@intCast(gw * gh * 2));
    glass_hash = 0;
    glass_idle = 0;
    _ = captureGlass(); // first picture, taken before the Dock itself is on screen
    // Keep our own window out of screen captures so the glass can be refreshed live without
    // photographing itself. (Side effect: the Dock does not appear in screenshots.)
    // TER_DOCK_SHOT=1 turns this off for taking pictures of the Dock; the glass is then static.
    var env: [8]u16 = undefined;
    live_glass = u.envVar(L("TER_DOCK_SHOT"), &env).len == 0 and w.SetWindowDisplayAffinity(dock, 0x11) != 0;

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
    tracking = false;
    animating = false;
    fullscreen = false;
    peek = false;
    dirty = false;
    label_for = null;

    loadItems();
    _ = refresh();
    hideTaskbar();

    // Reserve the strip so maximised windows stop above the Dock.
    var abd = w.APPBARDATA{ .hWnd = dock, .uCallbackMessage = WM_APPBAR };
    _ = w.SHAppBarMessage(0, &abd); // ABM_NEW
    abd.uEdge = 3; // bottom
    abd.rc = .{ .left = 0, .top = screen_h - px(MARGIN_BOT + PAD_BOT + BASE + PAD_TOP + 4), .right = cw, .bottom = screen_h };
    _ = w.SHAppBarMessage(2, &abd); // ABM_QUERYPOS
    _ = w.SHAppBarMessage(3, &abd); // ABM_SETPOS

    render();
    _ = w.ShowWindow(dock, 4);
    _ = w.SetTimer(dock, 1, 100, null);
}

pub fn disable() void {
    if (!enabled) return;
    enabled = false;
    animating = false;
    var abd = w.APPBARDATA{ .hWnd = dock };
    _ = w.SHAppBarMessage(1, &abd); // ABM_REMOVE
    const old = dock;
    dock = null;
    _ = w.DestroyWindow(old);
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
