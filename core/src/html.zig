//! Just enough HTML scraping to read and submit the library site's Rails forms (account
//! settings have no gateway endpoint), read the app state a catalog page embeds, and read
//! BiblioCommons' partner directory. Matching is case-insensitive and tolerant, like the
//! regular expressions the Apple app used.

const std = @import("std");
const Allocator = std.mem.Allocator;
const findI = std.ascii.findIgnoreCasePos;

pub const Input = struct { name: []const u8, type: []const u8, value: []const u8 };

pub const Form = struct {
    /// Absolute URL the form submits to.
    action: []const u8,
    /// "GET" or "POST" (Rails tunnels PUT/PATCH through a hidden `_method` field).
    method: []const u8,
    inputs: []const Input,

    /// Default submission values: hidden fields (authenticity token etc.), text values,
    /// checked boxes, selected options, and the first submit button, as a browser would.
    pub fn fields(self: Form, a: Allocator) std.StringArrayHashMapUnmanaged([]const u8) {
        var out: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        for (self.inputs) |i| {
            if (eq(i.type, "submit") or eq(i.type, "button") or eq(i.type, "image") or eq(i.type, "password")) continue;
            out.put(a, i.name, i.value) catch {};
        }
        for (self.inputs) |i| {
            if (eq(i.type, "submit")) {
                out.put(a, i.name, i.value) catch {};
                break;
            }
        }
        return out;
    }

    /// The path of `action`, for matching a form by where it submits.
    pub fn actionPath(self: Form) []const u8 {
        return urlPath(self.action);
    }
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// A `<tag ...>` found in the source: its attribute text and where it ends.
const Tag = struct { attrs: []const u8, end: usize };

/// Finds the next `<name` tag (followed by whitespace, `>` or `/`) at or after `from`.
fn nextTag(html: []const u8, from: usize, name: []const u8) ?struct { start: usize, tag: Tag } {
    var i = from;
    while (std.mem.findScalarPos(u8, html, i, '<')) |lt| {
        const after = lt + 1 + name.len;
        if (after <= html.len and std.ascii.eqlIgnoreCase(html[lt + 1 .. after], name) and
            (after == html.len or isTagBoundary(html[after])))
        {
            const gt = std.mem.findScalarPos(u8, html, after, '>') orelse return null;
            return .{ .start = lt, .tag = .{ .attrs = html[after..gt], .end = gt + 1 } };
        }
        i = lt + 1;
    }
    return null;
}

fn isTagBoundary(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '>' or c == '/';
}

/// The value of attribute `name` in a tag's attribute text (double or single quoted).
pub fn attribute(attrs: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (findI(attrs, i, name)) |p| {
        i = p + 1;
        // Word boundary before the name.
        if (p > 0 and (std.ascii.isAlphanumeric(attrs[p - 1]) or attrs[p - 1] == '_' or attrs[p - 1] == '-')) continue;
        var j = p + name.len;
        while (j < attrs.len and std.ascii.isWhitespace(attrs[j])) j += 1;
        if (j >= attrs.len or attrs[j] != '=') continue;
        j += 1;
        while (j < attrs.len and std.ascii.isWhitespace(attrs[j])) j += 1;
        if (j >= attrs.len) return null;
        const q = attrs[j];
        if (q == '"' or q == '\'') {
            const close = std.mem.findScalarPos(u8, attrs, j + 1, q) orelse return null;
            return attrs[j + 1 .. close];
        }
        var k = j;
        while (k < attrs.len and !std.ascii.isWhitespace(attrs[k]) and attrs[k] != '>') k += 1;
        return attrs[j..k];
    }
    return null;
}

fn hasWord(attrs: []const u8, word: []const u8) bool {
    return std.ascii.findIgnoreCase(attrs, word) != null;
}

/// Finds the closing `</name>` at or after `from`.
fn closing(html: []const u8, from: usize, name: []const u8) ?usize {
    var i = from;
    while (findI(html, i, "</")) |p| {
        const after = p + 2 + name.len;
        if (after <= html.len and std.ascii.eqlIgnoreCase(html[p + 2 .. after], name)) return p;
        i = p + 2;
    }
    return null;
}

pub fn forms(a: Allocator, html: []const u8, base: []const u8) []const Form {
    var out: std.ArrayList(Form) = .empty;
    var pos: usize = 0;
    while (nextTag(html, pos, "form")) |f| {
        const close = closing(html, f.tag.end, "form") orelse break;
        const body = html[f.tag.end..close];
        pos = close;
        const action = if (attribute(f.tag.attrs, "action")) |raw| resolve(a, base, decode(a, raw)) else base;
        const declared = attribute(f.tag.attrs, "method") orelse "get";
        const method: []const u8 = if (std.ascii.eqlIgnoreCase(declared, "get")) "GET" else "POST";

        var inputs: std.ArrayList(Input) = .empty;
        var ip: usize = 0;
        while (nextTag(body, ip, "input")) |t| {
            ip = t.tag.end;
            const name = attribute(t.tag.attrs, "name") orelse continue;
            const type_raw = attribute(t.tag.attrs, "type") orelse "text";
            const type_ = std.ascii.allocLowerString(a, type_raw) catch continue;
            if ((eq(type_, "checkbox") or eq(type_, "radio")) and !hasWord(t.tag.attrs, "checked")) continue;
            inputs.append(a, .{
                .name = decode(a, name),
                .type = type_,
                .value = decode(a, attribute(t.tag.attrs, "value") orelse ""),
            }) catch {};
        }
        var sp: usize = 0;
        while (nextTag(body, sp, "select")) |s| {
            const s_close = closing(body, s.tag.end, "select") orelse break;
            sp = s_close;
            const name = attribute(s.tag.attrs, "name") orelse continue;
            const options = body[s.tag.end..s_close];
            var chosen: ?[]const u8 = null;
            var first: ?[]const u8 = null;
            var op: usize = 0;
            while (nextTag(options, op, "option")) |o| {
                op = o.tag.end;
                if (first == null) first = o.tag.attrs;
                if (chosen == null and hasWord(o.tag.attrs, "selected")) chosen = o.tag.attrs;
            }
            const attrs = chosen orelse first;
            const value = if (attrs) |t| attribute(t, "value") orelse "" else "";
            inputs.append(a, .{ .name = decode(a, name), .type = "select", .value = decode(a, value) }) catch {};
        }
        out.append(a, .{ .action = action, .method = method, .inputs = inputs.items }) catch {};
    }
    return out.items;
}

/// Finds a visible error message in a response page, if any.
pub fn errorMessage(a: Allocator, html: []const u8) ?[]const u8 {
    const classes = [_][]const u8{ "alert-danger", "alert-error", "form-error", "error_message", "errorMessage" };
    var pos: usize = 0;
    while (findI(html, pos, "class=\"")) |p| {
        pos = p + 7;
        const close_quote = std.mem.findScalarPos(u8, html, pos, '"') orelse return null;
        const class = html[pos..close_quote];
        var matched = false;
        for (classes) |c| if (std.mem.find(u8, class, c) != null) {
            matched = true;
        };
        if (!matched) continue;
        const gt = std.mem.findScalarPos(u8, html, close_quote, '>') orelse return null;
        const end = std.mem.findPos(u8, html, gt + 1, "</") orelse return null;
        const text = std.mem.trim(u8, decode(a, stripTags(a, html[gt + 1 .. end])), " \t\r\n");
        if (text.len > 0) return text;
    }
    return null;
}

fn stripTags(a: Allocator, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_tag = false;
    for (s) |c| {
        if (c == '<') in_tag = true else if (c == '>') in_tag = false else if (!in_tag) out.append(a, c) catch {};
    }
    return out.items;
}

/// The page's `<title>`, if it has one.
pub fn title(a: Allocator, html: []const u8) ?[]const u8 {
    const head = html[0..@min(html.len, 64 * 1024)];
    const t = nextTag(head, 0, "title") orelse return null;
    const end = std.mem.findScalarPos(u8, head, t.tag.end, '<') orelse return null;
    const text = std.mem.trim(u8, head[t.tag.end..end], " \t\r\n");
    return if (text.len == 0) null else decode(a, text);
}

/// The JSON app state the site embeds in `<script type="application/json">`.
pub fn pageState(html: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (nextTag(html, pos, "script")) |s| {
        const close = findI(html, s.tag.end, "</script>") orelse return null;
        pos = close;
        const type_ = attribute(s.tag.attrs, "type") orelse continue;
        if (!std.ascii.eqlIgnoreCase(type_, "application/json")) continue;
        const body = html[s.tag.end..close];
        if (std.mem.find(u8, body, "\"branding\"") != null) return body;
    }
    return null;
}

pub const DirectoryEntry = struct {
    name: []const u8,
    website: ?[]const u8 = null,
    region: ?[]const u8 = null,
    /// A wide (640×400) partner logo from the directory page.
    logo: ?[]const u8 = null,
};

/// Entries on one page of bibliocommons.com/libraries-we-work-with: each is an
/// `<a class="library-link" href=…>` holding an `<img alt=name src=logo>`, followed by
/// an element marked `fs-cmsfilter-field="Region"`.
pub fn directoryEntries(a: Allocator, html: []const u8) []const DirectoryEntry {
    var out: std.ArrayList(DirectoryEntry) = .empty;
    var pos: usize = 0;
    while (nextTag(html, pos, "a")) |link| {
        pos = link.tag.end;
        const class = attribute(link.tag.attrs, "class") orelse continue;
        if (!std.mem.startsWith(u8, class, "library-link")) continue;
        const href = attribute(link.tag.attrs, "href");
        const img = nextTag(html, link.tag.end, "img") orelse break;
        const name = decode(a, attribute(img.tag.attrs, "alt") orelse continue);
        if (name.len == 0) continue;
        // The region belongs to this entry only if it comes before the next library link.
        const next_link = std.mem.findPos(u8, html, img.tag.end, "class=\"library-link") orelse html.len;
        var region: ?[]const u8 = null;
        if (std.mem.findPos(u8, html, img.tag.end, "fs-cmsfilter-field=\"Region\"")) |r| {
            if (r < next_link) {
                if (std.mem.findScalarPos(u8, html, r, '>')) |gt| {
                    if (std.mem.findScalarPos(u8, html, gt, '<')) |lt| region = decode(a, html[gt + 1 .. lt]);
                }
            }
        }
        out.append(a, .{ .name = name, .website = href, .region = region, .logo = attribute(img.tag.attrs, "src") }) catch {};
    }
    return out.items;
}

/// The directory's "next page" link (`?<hex>_page=N` on the `w-pagination-next` anchor).
pub fn directoryNextPage(a: Allocator, html: []const u8, base: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (nextTag(html, pos, "a")) |link| {
        pos = link.tag.end;
        const class = attribute(link.tag.attrs, "class") orelse continue;
        if (std.mem.find(u8, class, "w-pagination-next") == null) continue;
        const href = attribute(link.tag.attrs, "href") orelse return null;
        if (!std.mem.startsWith(u8, href, "?") or std.mem.find(u8, href, "_page=") == null) return null;
        return resolve(a, base, decode(a, href));
    }
    return null;
}

/// A page's icon URLs: sized icons first, largest first (apple-touch-icons count as 180 px
/// when unsized), then unsized `rel="icon"` links.
pub fn iconLinks(a: Allocator, html: []const u8, base: []const u8) []const []const u8 {
    const Link = struct { size: u32, url: []const u8 };
    var found: std.ArrayList(Link) = .empty;
    var pos: usize = 0;
    while (nextTag(html, pos, "link")) |link| {
        pos = link.tag.end;
        const rel = attribute(link.tag.attrs, "rel") orelse continue;
        const href = attribute(link.tag.attrs, "href") orelse continue;
        const sizes = attribute(link.tag.attrs, "sizes") orelse "";
        const size = std.fmt.parseInt(u32, sizes[0 .. std.mem.findAny(u8, sizes, "xX") orelse sizes.len], 10) catch 0;
        const touch = std.ascii.findIgnoreCase(rel, "apple-touch-icon") != null;
        var words = std.mem.tokenizeAny(u8, rel, " \t\n");
        const icon = while (words.next()) |w| {
            if (std.ascii.eqlIgnoreCase(w, "icon")) break true;
        } else false;
        if (!touch and !icon) continue;
        found.append(a, .{ .size = if (touch) @max(size, 180) else size, .url = resolve(a, base, decode(a, href)) }) catch {};
    }
    std.sort.insertion(Link, found.items, {}, struct {
        fn larger(_: void, x: Link, y: Link) bool {
            return x.size > y.size;
        }
    }.larger);
    var out: std.ArrayList([]const u8) = .empty;
    outer: for (found.items) |l| {
        for (out.items) |u| if (eq(u, l.url)) continue :outer;
        out.append(a, l.url) catch {};
    }
    return out.items;
}

/// Decodes the entities the library pages actually use, plus numeric ones.
pub fn decode(a: Allocator, s: []const u8) []const u8 {
    if (std.mem.findScalar(u8, s, '&') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') {
            if (std.mem.findScalarPos(u8, s, i, ';')) |semi| if (semi - i <= 10) {
                const ent = s[i + 1 .. semi];
                const named: ?[]const u8 = if (eq(ent, "amp")) "&" else if (eq(ent, "quot")) "\"" else if (eq(ent, "apos")) "'" else if (eq(ent, "lt")) "<" else if (eq(ent, "gt")) ">" else if (eq(ent, "nbsp")) "\u{a0}" else null;
                if (named) |n| {
                    out.appendSlice(a, n) catch {};
                    i = semi + 1;
                    continue;
                }
                if (ent.len > 1 and ent[0] == '#') {
                    const cp = if (ent[1] == 'x' or ent[1] == 'X')
                        std.fmt.parseInt(u21, ent[2..], 16) catch null
                    else
                        std.fmt.parseInt(u21, ent[1..], 10) catch null;
                    if (cp) |c| {
                        var buf: [4]u8 = undefined;
                        if (std.unicode.utf8Encode(c, &buf)) |n| {
                            out.appendSlice(a, buf[0..n]) catch {};
                            i = semi + 1;
                            continue;
                        } else |_| {}
                    }
                }
            };
        }
        out.append(a, s[i]) catch {};
        i += 1;
    }
    return out.items;
}

/// The path part of an absolute URL ("https://x.org/a/b?c" → "/a/b").
pub fn urlPath(url: []const u8) []const u8 {
    const scheme = std.mem.find(u8, url, "://") orelse return url;
    const slash = std.mem.findScalarPos(u8, url, scheme + 3, '/') orelse return "/";
    var end = url.len;
    if (std.mem.findAnyPos(u8, url, slash, "?#")) |q| end = q;
    return url[slash..end];
}

/// Resolves `ref` against the absolute URL `base`, enough for the links the library pages use:
/// absolute URLs, scheme-relative, host-relative paths, query-only and relative paths.
pub fn resolve(a: Allocator, base: []const u8, ref: []const u8) []const u8 {
    if (std.mem.find(u8, ref, "://") != null) return ref;
    const scheme_end = (std.mem.find(u8, base, "://") orelse return ref) + 3;
    const host_end = std.mem.findAnyPos(u8, base, scheme_end, "/?#") orelse base.len;
    if (std.mem.startsWith(u8, ref, "//")) return std.fmt.allocPrint(a, "{s}{s}", .{ base[0 .. scheme_end - 2], ref[2..] }) catch ref;
    if (std.mem.startsWith(u8, ref, "/")) return std.fmt.allocPrint(a, "{s}{s}", .{ base[0..host_end], ref }) catch ref;
    const path_end = std.mem.findAnyPos(u8, base, host_end, "?#") orelse base.len;
    if (std.mem.startsWith(u8, ref, "?")) return std.fmt.allocPrint(a, "{s}{s}", .{ base[0..path_end], ref }) catch ref;
    const dir_end = if (std.mem.findScalarLast(u8, base[host_end..path_end], '/')) |s| host_end + s + 1 else host_end;
    const sep: []const u8 = if (dir_end == host_end) "/" else "";
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ base[0..dir_end], sep, ref }) catch ref;
}

const testing = std.testing;

test "forms" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const html =
        \\<FORM class="x" action="/account/user_lang" method="post">
        \\<input type="hidden" name="authenticity_token" value="a&amp;b">
        \\<input name="_method" type="hidden" value="put" />
        \\<input type="checkbox" name="off" value="1">
        \\<input type="checkbox" name="on" value="1" checked>
        \\<select name="user_lang"><option value="en-US">English</option><option value="fr-CA" selected>French</option></select>
        \\<input type="submit" name="commit" value="Save">
        \\</form>
    ;
    const fs = forms(a, html, "https://wccls.bibliocommons.com/account/language");
    try testing.expectEqual(@as(usize, 1), fs.len);
    try testing.expectEqualStrings("https://wccls.bibliocommons.com/account/user_lang", fs[0].action);
    try testing.expectEqualStrings("/account/user_lang", fs[0].actionPath());
    try testing.expectEqualStrings("POST", fs[0].method);
    var f = fs[0].fields(a);
    try testing.expectEqualStrings("a&b", f.get("authenticity_token").?);
    try testing.expectEqualStrings("fr-CA", f.get("user_lang").?);
    try testing.expectEqualStrings("Save", f.get("commit").?);
    try testing.expect(f.get("off") == null);
    try testing.expectEqualStrings("1", f.get("on").?);
}

test "error message, title, decode, resolve" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("PIN is <b>wrong</b>", errorMessage(a, "<div class=\"alert alert-danger\" role=x>PIN is &lt;b&gt;wrong&lt;/b&gt;</div>").?);
    try testing.expectEqualStrings("My Account | WCCLS", title(a, "<html><title> My Account | WCCLS </title>").?);
    try testing.expectEqualStrings("✓ '", decode(a, "&#x2713; &#39;"));
    try testing.expectEqualStrings("https://w.org/libraries?a_page=2", resolve(a, "https://w.org/libraries?a_page=1", "?a_page=2"));
    try testing.expectEqualStrings("https://w.org/a/c", resolve(a, "https://w.org/a/b", "c"));
    try testing.expectEqualStrings("https://w.org/c", resolve(a, "https://w.org", "c"));
}

test "page state and directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const page =
        \\<script type="application/json">{"other":1}</script>
        \\<script data-x type="application/json">{"branding":{"primaryBrandColor":"#123456"}}</script>
    ;
    try testing.expectEqualStrings("{\"branding\":{\"primaryBrandColor\":\"#123456\"}}", pageState(page).?);
    const dir =
        \\<a href="https://smpl.org" class="library-link w-inline-block"><img alt="Santa Monica Public Library" src="https://cdn/x.png" loading="lazy"></a>
        \\<div fs-cmsfilter-field="Region" class="r">California</div>
        \\<a href="https://wccls.org" class="library-link"><img alt="WCCLS &amp; Co" src="y.png"></a>
        \\<a href="?3a_page=2" aria-label="Next" class="w-pagination-next next">Next</a>
    ;
    const entries = directoryEntries(a, dir);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("California", entries[0].region.?);
    try testing.expectEqualStrings("WCCLS & Co", entries[1].name);
    try testing.expect(entries[1].region == null);
    try testing.expectEqualStrings("https://www.bibliocommons.com/libraries-we-work-with?3a_page=2", directoryNextPage(a, dir, "https://www.bibliocommons.com/libraries-we-work-with").?);
}

test "icon links" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const page =
        \\<link rel="stylesheet" href="/s.css">
        \\<link rel="shortcut icon" href="/favicon.ico">
        \\<link rel="icon" type="image/png" sizes="32x32" href="/i32.png">
        \\<link rel="apple-touch-icon" href="touch.png?v=1&amp;x=2">
        \\<link rel="icon" sizes="192x192" href="https://cdn.example/i192.png">
        \\<link rel="icon" href="/favicon.ico">
    ;
    const links = iconLinks(a, page, "https://lib.example/home/");
    try testing.expectEqual(@as(usize, 4), links.len);
    try testing.expectEqualStrings("https://cdn.example/i192.png", links[0]);
    try testing.expectEqualStrings("https://lib.example/home/touch.png?v=1&x=2", links[1]);
    try testing.expectEqualStrings("https://lib.example/i32.png", links[2]);
    try testing.expectEqualStrings("https://lib.example/favicon.ico", links[3]);
}
