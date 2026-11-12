//! Format codes as readers mean them, and the key that matches one work across formats.
//!
//! Some libraries file a format under a broader code (WCCLS files 4K Ultra HD discs as Blu-ray,
//! with "4K Ultra HD" in the edition). A refinement turns such an item's code into the existing
//! BiblioCommons code it really has, so rows, details, format filters, and borrowing-history
//! matches all see an ordinary format. A library seen to use the refined code itself skips that
//! rule. A new rule needs an observed library, recorded in NOTES-API.md under library quirks.

const std = @import("std");
const Allocator = std.mem.Allocator;
const models = @import("models.zig");
const item_list = @import("list.zig");

pub const Rule = struct {
    /// The library's code for the item.
    base: []const u8,
    /// The BiblioCommons code the item really has.
    refined: []const u8,
    /// Lowercase phrases, matched as whole words in the edition or a bracketed title qualifier.
    phrases: []const []const u8,
};

pub const rules = [_]Rule{
    // WCCLS: 4K discs and 4K + Blu-ray combos are Blu-ray, with "4K Ultra HD" in the edition.
    .{ .base = "BLURAY", .refined = "UK", .phrases = &.{ "4k", "ultra hd", "uhd" } },
    // WCCLS: 4K + Blu-ray + DVD combos are DVD plus Blu-ray.
    .{ .base = "DVD_PBLURAY", .refined = "UK", .phrases = &.{ "4k", "ultra hd", "uhd" } },
};

/// The rules a library uses the refined code for itself, one bit each, learned from its responses.
pub const Native = std.atomic.Value(u32);

fn bit(i: usize) u32 {
    return @as(u32, 1) << @intCast(i);
}

/// Notes a code the library uses itself.
pub fn noteNative(native: *Native, code: []const u8) void {
    for (rules, 0..) |r, i| if (std.mem.eql(u8, code, r.refined)) {
        _ = native.fetchOr(bit(i), .monotonic);
    };
}

/// The refined code for an item, or null if no rule applies.
pub fn refined(format: []const u8, edition: ?[]const u8, title: []const u8, subtitle: ?[]const u8, native: u32) ?[]const u8 {
    for (rules, 0..) |r, i| {
        if (native & bit(i) != 0 or !std.mem.eql(u8, format, r.base)) continue;
        if (edition) |e| if (hasPhrase(e, r.phrases)) return r.refined;
        if (bracketedHasPhrase(title, r.phrases)) return r.refined;
        if (subtitle) |s| if (bracketedHasPhrase(s, r.phrases)) return r.refined;
    }
    return null;
}

/// The code to ask the server for: a refined code's first base, unless the library uses it
/// itself. A search takes one format, so a refined code with several bases (4K as Blu-ray, and as
/// DVD plus Blu-ray) finds only the first base's items.
pub fn serverCode(code: []const u8, native: u32) []const u8 {
    for (rules, 0..) |r, i| {
        if (native & bit(i) == 0 and std.mem.eql(u8, code, r.refined)) return r.base;
    }
    return code;
}

/// Whether a code is one some rule refines to (searches filter on it locally).
pub fn isRefined(code: []const u8) bool {
    for (rules) |r| if (std.mem.eql(u8, code, r.refined)) return true;
    return false;
}

/// Refines a fetched page's formats in place: notes the codes the library uses itself, keeps
/// each bib's own code in `libraryFormat`, and offers a search's refined codes as FORMAT facet
/// values (with count -1: unknown until the items are fetched) after their base.
pub fn refinePage(a: Allocator, page: *models.ListPage, native: *Native) void {
    for (page.entries) |e| noteNative(native, e.bib.format);
    for (page.facets) |f| if (std.mem.eql(u8, f.id, "FORMAT")) {
        for (f.values) |v| noteNative(native, v.value);
    };
    const n = native.load(.monotonic);
    const entries: []models.ListEntry = @constCast(page.entries);
    for (entries) |*e| {
        e.bib.libraryFormat = e.bib.format;
        if (refined(e.bib.format, e.bib.edition, e.bib.title, e.bib.subtitle, n)) |r| e.bib.format = r;
    }
    const facets: []models.Facet = @constCast(page.facets);
    for (facets) |*f| {
        if (!std.mem.eql(u8, f.id, "FORMAT")) continue;
        var values: std.ArrayList(models.FacetValue) = .empty;
        for (f.values) |v| {
            values.append(a, v) catch return;
            for (rules, 0..) |r, i| {
                if (n & bit(i) != 0 or !std.mem.eql(u8, v.value, r.base) or hasValue(values.items, r.refined)) continue;
                values.append(a, .{ .value = r.refined, .count = -1 }) catch return;
            }
        }
        f.values = values.items;
    }
}

fn hasValue(values: []const models.FacetValue, value: []const u8) bool {
    for (values) |v| if (std.mem.eql(u8, v.value, value)) return true;
    return false;
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

/// Whether the text has one of the phrases as whole words, ignoring case.
fn hasPhrase(text: []const u8, phrases: []const []const u8) bool {
    for (phrases) |p| {
        var i: usize = 0;
        while (i + p.len <= text.len) : (i += 1) {
            if (!std.ascii.eqlIgnoreCase(text[i .. i + p.len], p)) continue;
            const before = i == 0 or !isWordChar(text[i - 1]);
            const after = i + p.len == text.len or !isWordChar(text[i + p.len]);
            if (before and after) return true;
        }
    }
    return false;
}

fn bracketedHasPhrase(text: []const u8, phrases: []const []const u8) bool {
    var rest = text;
    while (std.mem.findScalar(u8, rest, '[')) |open| {
        const close = std.mem.findScalarPos(u8, rest, open, ']') orelse return false;
        if (hasPhrase(rest[open + 1 .. close], phrases)) return true;
        rest = rest[close + 1 ..];
    }
    return false;
}

// MARK: Works

/// A key shared by one work's records in every format: the title without catalog qualifiers
/// ("[videorecording]") or a leading article, and the first author's words without dates, in
/// order ("Herbert, Frank, 1920-1986" and "Frank Herbert" agree), each folded (case, accents,
/// and punctuation ignored). Empty when there is no title. Compare keys with `sameWork`.
pub fn workKey(a: Allocator, title: []const u8, author: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try fold(a, &out, title, true);
    if (out.items.len == 0) return out.toOwnedSlice(a);
    try out.append(a, 0x1f);
    var name: std.ArrayList(u8) = .empty;
    defer name.deinit(a);
    try fold(a, &name, author, false);
    var words: std.ArrayList([]const u8) = .empty;
    defer words.deinit(a);
    var it = std.mem.tokenizeScalar(u8, name.items, ' ');
    while (it.next()) |w| {
        if (std.mem.findNone(u8, w, "0123456789") != null) try words.append(a, w);
    }
    std.mem.sort([]const u8, words.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);
    for (words.items, 0..) |w, i| {
        if (i > 0) try out.append(a, ' ');
        try out.appendSlice(a, w);
    }
    return out.toOwnedSlice(a);
}

/// A work key's title.
pub fn titleOf(key: []const u8) []const u8 {
    return key[0 .. std.mem.findScalar(u8, key, 0x1f) orelse key.len];
}

fn authorOf(key: []const u8) []const u8 {
    const i = std.mem.findScalar(u8, key, 0x1f) orelse return "";
    return key[i + 1 ..];
}

/// Whether two records, by work key and format, are one work: the same title, and the same
/// author; a record that names no author matches only another without one, or, between videos,
/// any (films credit a director on one record and nobody on another). A film is no match for a
/// book of the same title.
pub fn sameWork(x: []const u8, x_format: []const u8, y: []const u8, y_format: []const u8) bool {
    if (x.len == 0 or !std.mem.eql(u8, titleOf(x), titleOf(y))) return false;
    const ax = authorOf(x);
    const ay = authorOf(y);
    if (std.mem.eql(u8, ax, ay)) return true;
    return (ax.len == 0 or ay.len == 0) and isVideo(x_format) and isVideo(y_format);
}

/// Formats of films and television, whose records often name no author.
pub fn isVideo(code: []const u8) bool {
    const video = [_][]const u8{ "DVD", "BLURAY", "UK", "DVD_PBLURAY", "VIDEO_ONLINE" };
    for (video) |v| if (std.mem.eql(u8, code, v)) return true;
    return false;
}

fn fold(a: Allocator, out: *std.ArrayList(u8), text: []const u8, drop_article: bool) Allocator.Error!void {
    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(a);
    var depth: usize = 0;
    for (text) |c| {
        if (c == '[') depth += 1 else if (c == ']') depth -|= 1 else if (depth == 0) try plain.append(a, c);
    }
    const start = out.items.len;
    var f: item_list.Folded = .{ .s = plain.items };
    var space = false;
    while (!f.done()) {
        const cp = f.next();
        const word = if (cp < 0x80) std.ascii.isAlphanumeric(@intCast(cp)) else true;
        if (!word) {
            space = true;
            continue;
        }
        if (space and out.items.len > start) try out.append(a, ' ');
        space = false;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch continue;
        try out.appendSlice(a, buf[0..n]);
    }
    if (!drop_article) return;
    for ([_][]const u8{ "the ", "a ", "an " }) |article| {
        if (out.items.len - start > article.len and std.mem.startsWith(u8, out.items[start..], article)) {
            const rest = out.items.len - start - article.len;
            std.mem.copyForwards(u8, out.items[start..][0..rest], out.items[start + article.len ..]);
            out.shrinkRetainingCapacity(start + rest);
            return;
        }
    }
}

// MARK: Tests

const testing = std.testing;

test "4K Blu-ray is refined unless the library uses the code itself" {
    try testing.expectEqualStrings("UK", refined("BLURAY", "4K Ultra HD Blu-ray", "Dune", null, 0).?);
    try testing.expectEqualStrings("UK", refined("BLURAY", "[4K Ultra HD Blu-ray + Blu-ray].", "Dune", null, 0).?);
    try testing.expectEqualStrings("UK", refined("BLURAY", null, "Dune [UHD]", null, 0).?);
    try testing.expect(refined("BLURAY", "Blu-ray", "Dune", null, 0) == null);
    try testing.expect(refined("BLURAY", null, "4K Dreams", null, 0) == null);
    try testing.expect(refined("BLURAY", "Collector's edition, 4Kids", "Dune", null, 0) == null);
    try testing.expect(refined("DVD", "4K Ultra HD", "Dune", null, 0) == null);
    try testing.expectEqualStrings("UK", refined("DVD_PBLURAY", "4K Ultra HD Blu-ray + Blu-ray + DVD", "Mamma Mia!", null, 0).?);
    try testing.expect(refined("DVD_PBLURAY", "Blu-ray + DVD", "Mamma Mia!", null, 0) == null);
    try testing.expect(refined("BLURAY", "4K Ultra HD", "Dune", null, 1) == null);
    var native: Native = .init(0);
    noteNative(&native, "BLURAY");
    try testing.expectEqual(@as(u32, 0), native.load(.monotonic));
    try testing.expectEqualStrings("BLURAY", serverCode("UK", 0));
    noteNative(&native, "UK");
    try testing.expectEqualStrings("UK", serverCode("UK", native.load(.monotonic)));
    try testing.expectEqualStrings("DVD", serverCode("DVD", 0));
}

test "pages keep the library's code and offer refined facets" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var entries = [_]models.ListEntry{
        .{ .id = "S1", .bib = .{ .id = "S1", .title = "Dune", .format = "BLURAY", .edition = "4K Ultra HD" }, .kind = "catalog", .serverIndex = 0 },
        .{ .id = "S2", .bib = .{ .id = "S2", .title = "Dune", .format = "DVD" }, .kind = "catalog", .serverIndex = 1 },
    };
    var facets = [_]models.Facet{.{ .id = "FORMAT", .values = &.{ .{ .value = "BLURAY", .count = 3 }, .{ .value = "DVD", .count = 2 }, .{ .value = "DVD_PBLURAY", .count = 1 } } }};
    var page: models.ListPage = .{ .entries = &entries, .page = 1, .pages = 1, .count = 2, .facets = &facets };
    var native: Native = .init(0);
    refinePage(a, &page, &native);
    try testing.expectEqualStrings("UK", entries[0].bib.format);
    try testing.expectEqualStrings("BLURAY", entries[0].bib.libraryFormat);
    try testing.expectEqualStrings("DVD", entries[1].bib.libraryFormat);
    // Offered once, after the first of its bases.
    try testing.expectEqual(@as(usize, 4), facets[0].values.len);
    try testing.expectEqualStrings("UK", facets[0].values[1].value);
    try testing.expectEqual(@as(i64, -1), facets[0].values[1].count);
}

test "work keys ignore case, accents, punctuation, qualifiers, and articles" {
    const a = testing.allocator;
    const k1 = try workKey(a, "The Rise and Fall of Sanctuary Moon [videorecording]", "");
    defer a.free(k1);
    try testing.expectEqualStrings("rise and fall of sanctuary moon\x1f", k1);
    const k2 = try workKey(a, "Émile, or: On Education", "Rousseau, Jean-Jacques");
    defer a.free(k2);
    try testing.expectEqualStrings("emile or on education\x1fjacques jean rousseau", k2);
    const k3 = try workKey(a, "[Untitled]", "x");
    defer a.free(k3);
    try testing.expectEqualStrings("", k3);
    const k4 = try workKey(a, "A", "");
    defer a.free(k4);
    try testing.expectEqualStrings("a\x1f", k4);
}

test "one work despite how a record writes its author" {
    const a = testing.allocator;
    const dated = try workKey(a, "Dune", "Herbert, Frank, 1920-1986");
    defer a.free(dated);
    const plain = try workKey(a, "Dune", "Frank Herbert");
    defer a.free(plain);
    const none = try workKey(a, "Dune", "");
    defer a.free(none);
    const other = try workKey(a, "Dune", "Villeneuve, Denis");
    defer a.free(other);
    const emma = try workKey(a, "Emma", "");
    defer a.free(emma);
    try testing.expectEqualStrings(plain, dated);
    // A book's author written another way is the same book.
    try testing.expect(sameWork(dated, "BK", plain, "BOOK_CD"));
    // Films: a record without a director matches one with.
    try testing.expect(sameWork(none, "DVD", other, "UK"));
    // A film without an author is no match for a book of the same title.
    try testing.expect(!sameWork(none, "DVD_PBLURAY", dated, "BK"));
    try testing.expect(!sameWork(dated, "BK", other, "BK"));
    try testing.expect(!sameWork(none, "DVD", emma, "DVD"));
    try testing.expect(!sameWork("", "BK", "", "BK"));
}
