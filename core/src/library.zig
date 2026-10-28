//! Public, unauthenticated library information: finding a library's catalog subdomain,
//! reading its name, brand color, languages and labels, and the BiblioCommons partner
//! directory used to autocomplete "Add Library". Also the display helpers every app needs
//! for library data (format names, readable brand colors).

const std = @import("std");
const Allocator = std.mem.Allocator;
const http = @import("http.zig");
const html = @import("html.zig");
const json = @import("json.zig");
const models = @import("models.zig");
const J = json.J;

/// Accepts "wccls", "WCCLS", "https://smpl.bibliocommons.com/", "smpl.bibliocommons.com/v2/search?…".
pub fn subdomainFrom(a: Allocator, input: []const u8) ?[]const u8 {
    const s = std.ascii.allocLowerString(a, std.mem.trim(u8, input, " \t\r\n")) catch return null;
    if (s.len == 0) return null;
    if (std.mem.find(u8, s, "://") != null or std.mem.findScalar(u8, s, '.') != null) {
        const url = if (std.mem.find(u8, s, "://") == null) std.fmt.allocPrint(a, "https://{s}", .{s}) catch return null else s;
        const host = http.hostOf(url);
        if (std.mem.endsWith(u8, host, "bibliocommons.com")) {
            const label = host[0 .. std.mem.findScalar(u8, host, '.') orelse host.len];
            if (std.mem.eql(u8, label, "www") or std.mem.eql(u8, label, "bibliocommons")) return null;
            return label;
        }
    }
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-')) return null;
    return s;
}

pub const Lookup = struct {
    fetcher: http.Fetcher,

    fn get(l: Lookup, a: Allocator, url: []const u8) !http.Response {
        return l.fetcher.fetch(a, .{ .method = "GET", .url = url });
    }

    pub fn exists(l: Lookup, a: Allocator, subdomain: []const u8) bool {
        const url = std.fmt.allocPrint(a, "https://gateway.bibliocommons.com/v2/libraries/{s}/locations?limit=1", .{subdomain}) catch return false;
        const res = l.get(a, url) catch return false;
        return res.status == 200;
    }

    /// Name, brand colour, languages and catalog labels from the library's public search page.
    pub fn info(l: Lookup, a: Allocator, subdomain: []const u8, failure: *[]const u8) !models.LibraryInfo {
        const url = try std.fmt.allocPrint(a, "https://{s}.bibliocommons.com/v2/search?query=library&searchType=keyword", .{subdomain});
        const res = l.get(a, url) catch {
            failure.* = "The library could not be reached.";
            return error.Transport;
        };
        const prefix = try std.fmt.allocPrint(a, "{s}.", .{subdomain});
        if (res.status != 200 or !std.mem.startsWith(u8, http.hostOf(res.url), prefix)) {
            failure.* = try std.fmt.allocPrint(a, "“{s}” is not a BiblioCommons library.", .{subdomain});
            return error.NotALibrary;
        }
        const state_text = html.pageState(res.body) orelse {
            failure.* = try std.fmt.allocPrint(a, "“{s}” did not return a catalog page.", .{subdomain});
            return error.NotALibrary;
        };
        return infoFromState(a, subdomain, json.parse(a, state_text));
    }

    /// One page of the partner directory and the URL of the next, if any.
    pub fn directoryPage(l: Lookup, a: Allocator, url: ?[]const u8) !struct { entries: []const html.DirectoryEntry, next: ?[]const u8 } {
        const page_url = url orelse "https://www.bibliocommons.com/libraries-we-work-with";
        const res = try l.get(a, page_url);
        if (res.status != 200) return error.Http;
        return .{ .entries = html.directoryEntries(a, res.body), .next = html.directoryNextPage(a, res.body, page_url) };
    }

    /// Guesses the catalog subdomain for a directory entry and confirms it against the gateway.
    pub fn resolveSubdomain(l: Lookup, a: Allocator, name: []const u8, website: ?[]const u8) ?[]const u8 {
        for (subdomainCandidates(a, name, website)) |c| {
            if (l.exists(a, c)) return c;
        }
        return null;
    }
};

pub fn infoFromState(a: Allocator, subdomain: []const u8, state: J) models.LibraryInfo {
    var lib = J.null_;
    if (state.path("entities.libraries").object()) |o| {
        if (o.count() > 0) lib = J.of(o.values()[0]);
    }
    const prefixes = [_][]const u8{ "FORMAT.", "AUDIENCE.", "FICTION_TYPE.", "LANGUAGE.", "sort.", "LANGUAGE_NAME." };
    var labels: std.json.ArrayHashMap([]const u8) = .{};
    if (state.path("localization.messages").object()) |o| {
        var it = o.iterator();
        while (it.next()) |e| {
            const value = J.of(e.value_ptr.*).str(a) orelse continue;
            for (prefixes) |p| if (std.mem.startsWith(u8, e.key_ptr.*, p)) {
                labels.map.put(a, e.key_ptr.*, value) catch {};
                break;
            };
        }
    }
    return .{
        .subdomain = subdomain,
        .name = lib.get("fullName").nonEmpty(a) orelse lib.get("longName").nonEmpty(a) orelse
            (std.ascii.allocUpperString(a, subdomain) catch subdomain),
        .shortName = lib.get("shortName").nonEmpty(a),
        .primaryColor = state.path("branding.primaryBrandColor").str(a),
        .website = lib.get("homeLink").nonEmpty(a),
        .labels = labels,
        .languages = state.path("localization.availableLanguages").strings(a),
    };
}

pub fn subdomainCandidates(a: Allocator, name: []const u8, website: ?[]const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const skip = [_][]const u8{ "www", "com", "org", "gov", "net", "ca", "us", "edu", "info", "library", "lib" };
    if (website) |w| {
        const url = if (std.mem.find(u8, w, "://") == null) std.fmt.allocPrint(a, "https://{s}", .{w}) catch w else w;
        const host = std.ascii.allocLowerString(a, http.hostOf(url)) catch "";
        var labels: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, host, '.');
        outer: while (it.next()) |label| {
            for (skip) |s| if (std.mem.eql(u8, s, label)) continue :outer;
            labels.append(a, label) catch {};
        }
        out.appendSlice(a, labels.items) catch {};
        if (labels.items.len > 0) out.append(a, std.fmt.allocPrint(a, "{s}library", .{labels.items[0]}) catch "") catch {};
    }
    var initials: std.ArrayList(u8) = .empty;
    var words = std.mem.tokenizeScalar(u8, name, ' ');
    while (words.next()) |w| initials.append(a, std.ascii.toLower(w[0])) catch {};
    out.append(a, initials.items) catch {};
    var letters: std.ArrayList(u8) = .empty;
    for (name) |c| if (std.ascii.isAlphabetic(c)) letters.append(a, std.ascii.toLower(c)) catch {};
    out.append(a, letters.items) catch {};

    var unique: std.ArrayList([]const u8) = .empty;
    outer: for (out.items) |c| {
        if (c.len == 0) continue;
        for (unique.items) |u| if (std.mem.eql(u8, u, c)) continue :outer;
        unique.append(a, c) catch {};
    }
    return unique.items;
}

// MARK: Display helpers

pub const fallback_format_names = std.StaticStringMap([]const u8).initComptime(.{
    .{ "BK", "Book" },                                   .{ "EBOOK", "eBook" },                    .{ "AB", "Downloadable Audiobook" },
    .{ "VIDEO_ONLINE", "Streaming Video" },              .{ "GRAPHIC_NOVEL", "Graphic Novel" },    .{ "GRAPHIC_NOVEL_DOWNLOAD", "Downloadable Graphic Novel" },
    .{ "PICTURE_BOOK", "Picture Book" },                 .{ "ONLINE_LEARNING", "Online Learning" }, .{ "DVD", "DVD" },
    .{ "LPRINT", "Large Print" },                        .{ "MAG_ONLINE", "Online Magazine" },     .{ "BOARD_BK", "Board Book" },
    .{ "BLURAY", "Blu-ray Disc" },                       .{ "MUSIC_CD", "Music CD" },              .{ "BOOK_CD", "Audiobook CD" },
    .{ "BOARD_GAME", "Board Game" },                     .{ "BOOK_PAUDIO", "Book plus Audio" },    .{ "EASY_READER", "Early Readers" },
    .{ "PLAYAWAY_AUDIOBOOK", "Preloaded Audiobook" },    .{ "VIDEO_GAME", "Video Game" },          .{ "THREE_D_OBJECT", "3D Object" },
    .{ "BOOK_CLUB_KIT", "Book Club Kit" },               .{ "DVD_PBLURAY", "DVD plus Blu-ray" },   .{ "KIT", "Kit" },
    .{ "BOOK_PCD", "Book plus CD" },                     .{ "ATLAS", "Atlas" },                    .{ "BR", "Braille" },
    .{ "MAG", "Magazine" },                              .{ "BOOK_PDVD", "Book plus DVD" },        .{ "MN", "Printed Music" },
    .{ "NEWSPAPER", "Newspaper" },                       .{ "UK", "4K Ultra HD Blu-ray" },
});

/// The library's own name for a format code, else a built-in English one, else the code prettified.
pub fn formatName(a: Allocator, labels: J, code: []const u8) []const u8 {
    if (std.mem.eql(u8, code, "UK")) return "4K Ultra HD Blu-ray";
    const lower = std.ascii.allocLowerString(a, code) catch code;
    const key = std.fmt.allocPrint(a, "FORMAT.{s}", .{lower}) catch "";
    if (labels.get(key).str(a)) |s| return s;
    return fallback_format_names.get(code) orelse json.prettified(a, code);
}

pub fn sortName(a: Allocator, labels: J, id: []const u8) []const u8 {
    const lower = std.ascii.allocLowerString(a, id) catch id;
    const key = std.fmt.allocPrint(a, "sort.{s}", .{lower}) catch "";
    return labels.get(key).str(a) orelse json.prettified(a, id);
}

/// sRGB color math for keeping brand colors readable (WCAG relative luminance and contrast).
pub const Rgb = struct {
    r: f64,
    g: f64,
    b: f64,

    /// Approximate toolbar/sidebar backgrounds in each appearance.
    pub const light_bar: Rgb = .{ .r = 0.96, .g = 0.96, .b = 0.97 };
    pub const dark_bar: Rgb = .{ .r = 0.17, .g = 0.17, .b = 0.18 };

    pub fn fromHex(hex: []const u8) ?Rgb {
        var s = std.mem.trim(u8, hex, " ");
        if (std.mem.startsWith(u8, s, "#")) s = s[1..];
        if (s.len != 6) return null;
        const v = std.fmt.parseInt(u32, s, 16) catch return null;
        return .{ .r = @as(f64, @floatFromInt((v >> 16) & 0xFF)) / 255, .g = @as(f64, @floatFromInt((v >> 8) & 0xFF)) / 255, .b = @as(f64, @floatFromInt(v & 0xFF)) / 255 };
    }

    pub fn toHex(c: Rgb, buf: *[7]u8) []const u8 {
        const ch = struct {
            fn f(x: f64) u8 {
                return @intFromFloat(@round(std.math.clamp(x, 0, 1) * 255));
            }
        }.f;
        return std.fmt.bufPrint(buf, "#{X:0>2}{X:0>2}{X:0>2}", .{ ch(c.r), ch(c.g), ch(c.b) }) catch "#000000";
    }

    pub fn luminance(c: Rgb) f64 {
        const lin = struct {
            fn f(x: f64) f64 {
                return if (x <= 0.03928) x / 12.92 else std.math.pow(f64, (x + 0.055) / 1.055, 2.4);
            }
        }.f;
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
    }

    pub fn contrast(c: Rgb, other: Rgb) f64 {
        const x = c.luminance();
        const y = other.luminance();
        return (@max(x, y) + 0.05) / (@min(x, y) + 0.05);
    }

    /// The smallest change in HSL lightness (keeping hue and saturation, so the brand stays
    /// recognizable) that reaches `minimum` contrast with `background`.
    pub fn readable(c: Rgb, background: Rgb, lighten: bool, minimum: f64) Rgb {
        const h = c.hsl();
        var l = h[2];
        var out = c;
        while (out.contrast(background) < minimum and (if (lighten) l < 1 else l > 0)) {
            l = if (lighten) @min(1, l + 0.02) else @max(0, l - 0.02);
            out = fromHsl(h[0], h[1], l);
        }
        return out;
    }

    pub fn hsl(c: Rgb) [3]f64 {
        const mx = @max(c.r, @max(c.g, c.b));
        const mn = @min(c.r, @min(c.g, c.b));
        const l = (mx + mn) / 2;
        if (mx == mn) return .{ 0, 0, l };
        const d = mx - mn;
        const s = if (l > 0.5) d / (2 - mx - mn) else d / (mx + mn);
        const h = if (mx == c.r)
            ((c.g - c.b) / d + @as(f64, if (c.g < c.b) 6 else 0)) / 6
        else if (mx == c.g)
            ((c.b - c.r) / d + 2) / 6
        else
            ((c.r - c.g) / d + 4) / 6;
        return .{ h, s, l };
    }

    pub fn fromHsl(h: f64, s: f64, l: f64) Rgb {
        if (s <= 0) return .{ .r = l, .g = l, .b = l };
        const hue = struct {
            fn f(p: f64, q: f64, t0: f64) f64 {
                var t = t0;
                if (t < 0) t += 1;
                if (t > 1) t -= 1;
                if (t < 1.0 / 6.0) return p + (q - p) * 6 * t;
                if (t < 1.0 / 2.0) return q;
                if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6;
                return p;
            }
        }.f;
        const q = if (l < 0.5) l * (1 + s) else l + s - l * s;
        const p = 2 * l - q;
        return .{ .r = hue(p, q, h + 1.0 / 3.0), .g = hue(p, q, h), .b = hue(p, q, h - 1.0 / 3.0) };
    }
};

/// The library's brand color adjusted for one appearance so tinted controls stay legible:
/// darkened for light mode, lightened for dark mode, until it reaches 4.5:1 contrast.
pub fn readableTint(hex: []const u8, dark: bool, buf: *[7]u8) ?[]const u8 {
    const brand = Rgb.fromHex(hex) orelse return null;
    const c = if (dark) brand.readable(Rgb.dark_bar, true, 4.5) else brand.readable(Rgb.light_bar, false, 4.5);
    return c.toHex(buf);
}

const testing = std.testing;

test "subdomains" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("wccls", subdomainFrom(a, " WCCLS ").?);
    try testing.expectEqualStrings("smpl", subdomainFrom(a, "https://smpl.bibliocommons.com/").?);
    try testing.expectEqualStrings("smpl", subdomainFrom(a, "smpl.bibliocommons.com/v2/search?q=x").?);
    try testing.expect(subdomainFrom(a, "www.bibliocommons.com") == null);
    try testing.expect(subdomainFrom(a, "not a library") == null);
    const c = subdomainCandidates(a, "Santa Monica Public Library", "https://smpl.org/");
    try testing.expectEqualStrings("smpl", c[0]);
    try testing.expectEqualStrings("smpllibrary", c[1]);
    try testing.expectEqualStrings("smpl", c[0]);
    try testing.expectEqualStrings("santamonicapubliclibrary", c[c.len - 1]);
}

test "colors and names" {
    var buf: [7]u8 = undefined;
    // A light yellow brand darkens for light mode until readable.
    const light = readableTint("#FFE066", false, &buf).?;
    try testing.expect(Rgb.fromHex(light).?.contrast(Rgb.light_bar) >= 4.5);
    try testing.expectEqualStrings("#336699", Rgb.fromHex("#336699").?.toHex(&buf));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const labels = json.parse(a, "{\"FORMAT.bk\":\"Libro\"}");
    try testing.expectEqualStrings("Libro", formatName(a, labels, "BK"));
    try testing.expectEqualStrings("DVD", formatName(a, labels, "DVD"));
    try testing.expectEqualStrings("Some thing", formatName(a, labels, "SOME_THING"));
}
