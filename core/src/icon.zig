//! Library icons. In order of preference: the website's own large square icon
//! (apple-touch-icon or a sized `rel="icon"`), the directory's wide partner logo, then the
//! site's small favicon. Apps decode the image, trim a logo with `logoBounds`, and cache it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const html = @import("html.zig");
const library = @import("library.zig");

pub const Kind = enum(c_int) { none, square, logo };

pub const Icon = struct { kind: Kind = .none, bytes: []const u8 = "" };

/// Icons at least this many pixels wide look sharp in a 36-point tile.
const large = 64;

/// `website` may be null when it has to be read from the catalog of `subdomain`.
pub fn find(l: library.Lookup, a: Allocator, website: ?[]const u8, subdomain: ?[]const u8, logo: ?[]const u8) Icon {
    var site = website;
    if (site == null) if (subdomain) |s| {
        var message: []const u8 = "";
        site = if (l.info(a, s, &message)) |info| info.website else |_| null;
    };
    const found = if (site) |s| bestIcon(l, a, s) else null;
    if (found) |f| if (f.pixels >= large) return .{ .kind = .square, .bytes = f.bytes };
    if (logo) |u| if (get(l, a, u)) |res| return .{ .kind = .logo, .bytes = res.body };
    if (found) |f| return .{ .kind = .square, .bytes = f.bytes };
    return .{};
}

const Found = struct { bytes: []const u8, pixels: u32 };

/// The largest square icon among the site's first few candidates.
fn bestIcon(l: library.Lookup, a: Allocator, website: []const u8) ?Found {
    const page = get(l, a, website) orelse return null;
    var candidates: std.ArrayList([]const u8) = .empty;
    candidates.appendSlice(a, html.iconLinks(a, page.body, page.url)) catch {};
    for ([_][]const u8{ "/apple-touch-icon.png", "/favicon.ico" }) |path| {
        const url = html.resolve(a, page.url, path);
        for (candidates.items) |c| {
            if (std.mem.eql(u8, c, url)) break;
        } else candidates.append(a, url) catch {};
    }
    var best: ?Found = null;
    for (candidates.items[0..@min(3, candidates.items.len)]) |url| {
        const res = get(l, a, url) orelse continue;
        const pixels = squarePixels(res.body) orelse continue;
        if (pixels < 16) continue;
        if (pixels > (if (best) |b| b.pixels else 0)) best = .{ .bytes = res.body, .pixels = pixels };
        if (pixels >= large) break;
    }
    return best;
}

const Page = struct { url: []const u8, body: []const u8 };

/// A successful GET, with plain http upgraded (Android and App Transport Security block it).
fn get(l: library.Lookup, a: Allocator, url: []const u8) ?Page {
    const https = if (std.mem.startsWith(u8, url, "http://"))
        std.fmt.allocPrint(a, "https://{s}", .{url["http://".len..]}) catch return null
    else
        url;
    const res = l.fetcher.fetch(a, .{ .method = "GET", .url = https }) catch return null;
    if (res.status != 200) return null;
    return .{ .url = res.url, .body = res.body };
}

/// The pixel width of the largest square image in a PNG, ICO, GIF, BMP or JPEG, or null.
pub fn squarePixels(b: []const u8) ?u32 {
    const square = struct {
        fn f(w: u32, h: u32) ?u32 {
            return if (w > 0 and @max(w, h) - @min(w, h) <= 1) w else null;
        }
    }.f;
    if (b.len >= 24 and std.mem.startsWith(u8, b, "\x89PNG\r\n\x1a\n")) {
        return square(std.mem.readInt(u32, b[16..20], .big), std.mem.readInt(u32, b[20..24], .big));
    }
    if (b.len >= 6 and std.mem.startsWith(u8, b, "\x00\x00\x01\x00")) {
        // An .ico holds several sizes; 0 means 256.
        var largest: ?u32 = null;
        const count = std.mem.readInt(u16, b[4..6], .little);
        for (0..count) |i| {
            const e = 6 + i * 16;
            if (e + 2 > b.len) break;
            const w: u32 = if (b[e] == 0) 256 else b[e];
            const h: u32 = if (b[e + 1] == 0) 256 else b[e + 1];
            if (square(w, h)) |p| largest = @max(largest orelse 0, p);
        }
        return largest;
    }
    if (b.len >= 10 and std.mem.startsWith(u8, b, "GIF8")) {
        return square(std.mem.readInt(u16, b[6..8], .little), std.mem.readInt(u16, b[8..10], .little));
    }
    if (b.len >= 26 and std.mem.startsWith(u8, b, "BM")) {
        return square(@abs(std.mem.readInt(i32, b[18..22], .little)), @abs(std.mem.readInt(i32, b[22..26], .little)));
    }
    if (b.len >= 4 and b[0] == 0xFF and b[1] == 0xD8) {
        // Walk the segments to the start-of-frame, which holds the size.
        var i: usize = 2;
        while (i + 9 <= b.len and b[i] == 0xFF) {
            const marker = b[i + 1];
            if (marker >= 0xC0 and marker <= 0xCF and marker != 0xC4 and marker != 0xC8 and marker != 0xCC) {
                return square(std.mem.readInt(u16, b[i + 7 ..][0..2], .big), std.mem.readInt(u16, b[i + 5 ..][0..2], .big));
            }
            i += 2 + std.mem.readInt(u16, b[i + 2 ..][0..2], .big);
        }
    }
    return null;
}

pub const Bounds = struct { x: usize, y: usize, width: usize, height: usize };

/// The part of a logo that isn't white margin, padded by a twentieth of its size. `pixels`
/// has `height` rows `stride` bytes apart, of `channels` bytes each: 3 colors in any order,
/// then alpha if there are 4. Null if the logo is blank.
pub fn logoBounds(pixels: []const u8, width: usize, height: usize, stride: usize, channels: usize) ?Bounds {
    if (channels < 3 or width == 0 or height == 0 or stride < width * channels or pixels.len < (height - 1) * stride + width * channels) return null;
    var min_x = width;
    var min_y = height;
    var max_x: usize = 0;
    var max_y: usize = 0;
    for (0..height) |y| {
        for (0..width) |x| {
            const p = pixels[y * stride + x * channels ..][0..channels];
            if (channels >= 4 and p[3] < 128) continue;
            if (@min(p[0], p[1], p[2]) >= 232) continue;
            min_x = @min(min_x, x);
            max_x = @max(max_x, x);
            min_y = @min(min_y, y);
            max_y = @max(max_y, y);
        }
    }
    if (min_x > max_x or min_y > max_y) return null;
    const pad = @max(max_x - min_x, max_y - min_y) / 20;
    const x0 = min_x -| pad;
    const y0 = min_y -| pad;
    const x1 = @min(width, max_x + 1 + pad);
    const y1 = @min(height, max_y + 1 + pad);
    return .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
}

const testing = std.testing;

test "image sizes" {
    var png: [24]u8 = @splat(0);
    @memcpy(png[0..8], "\x89PNG\r\n\x1a\n");
    std.mem.writeInt(u32, png[16..20], 180, .big);
    std.mem.writeInt(u32, png[20..24], 180, .big);
    try testing.expectEqual(@as(?u32, 180), squarePixels(&png));
    std.mem.writeInt(u32, png[20..24], 90, .big);
    try testing.expectEqual(@as(?u32, null), squarePixels(&png));

    // An .ico with 16, 48 and 256 (stored as 0) pixel images.
    var ico: [6 + 3 * 16]u8 = @splat(0);
    @memcpy(ico[0..4], "\x00\x00\x01\x00");
    std.mem.writeInt(u16, ico[4..6], 3, .little);
    ico[6] = 16;
    ico[7] = 16;
    ico[22] = 48;
    ico[23] = 48;
    try testing.expectEqual(@as(?u32, 256), squarePixels(&ico));

    // A JPEG with an APP0 segment before its 64×64 baseline frame.
    const jpeg = "\xFF\xD8" ++ "\xFF\xE0\x00\x04\x00\x00" ++ "\xFF\xC0\x00\x0B\x08\x00\x40\x00\x40\x01\x00";
    try testing.expectEqual(@as(?u32, 64), squarePixels(jpeg));
    try testing.expectEqual(@as(?u32, null), squarePixels("<svg/>"));
}

test "logo bounds" {
    // A 40×20 white RGB image with a dark 10×4 block at (12, 6).
    const w = 40;
    const h = 20;
    var pixels: [w * h * 3]u8 = @splat(255);
    for (6..10) |y| for (12..22) |x| {
        @memset(pixels[(y * w + x) * 3 ..][0..3], 20);
    };
    try testing.expectEqual(Bounds{ .x = 12, .y = 6, .width = 10, .height = 4 }, logoBounds(&pixels, w, h, w * 3, 3).?);
    @memset(&pixels, 255);
    try testing.expectEqual(@as(?Bounds, null), logoBounds(&pixels, w, h, w * 3, 3));
}
