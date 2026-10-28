//! Library icons from the core (`biblio_library_icon`), cached on disk so each library's site
//! is asked only once, and shown as 36-pixel rounded tiles. A wide directory logo is trimmed
//! to its content and fitted on white; without an icon the tile shows the name's initial.

const std = @import("std");
const biblio = @import("biblio");
const gtk = @import("gtk.zig");
const c = gtk.c;
const core = @import("core.zig");

const size = 36;

const Kind = biblio.icon.Kind;
const Icon = struct { kind: Kind, texture: ?*c.GdkTexture = null };

var icons: std.StringHashMapUnmanaged(Icon) = .empty;
/// Tiles waiting for an icon being looked up, by key.
var waiting: std.StringHashMapUnmanaged(std.ArrayList(*c.GtkWidget)) = .empty;

/// Icons are keyed by website host, so a directory suggestion and the added library share one.
pub fn key(a: std.mem.Allocator, website: ?[]const u8, fallback: []const u8) []const u8 {
    const url = website orelse return fallback;
    const start = if (std.mem.find(u8, url, "://")) |i| i + 3 else 0;
    const end = std.mem.findAnyPos(u8, url, start, "/?#:") orelse url.len;
    if (end == start) return fallback;
    return std.ascii.allocLowerString(a, url[start..end]) catch fallback;
}

/// A tile for the library `name`, filled in when its icon arrives. `website` may be null when
/// it has to be read from the catalog of `subdomain`; `logo` is the directory logo, if known.
pub fn tile(name: []const u8, icon_key: []const u8, website: ?[]const u8, subdomain: ?[]const u8, logo: ?[]const u8) *c.GtkWidget {
    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    c.gtk_widget_set_size_request(box, size, size);
    c.gtk_widget_set_valign(box, c.GTK_ALIGN_CENTER);
    c.gtk_widget_set_overflow(box, c.GTK_OVERFLOW_HIDDEN);
    c.gtk_widget_add_css_class(box, "library-icon");
    // The initial, until an icon replaces it.
    var initial: [5:0]u8 = @splat(0);
    if (name.len > 0) {
        const n = std.unicode.utf8ByteSequenceLength(name[0]) catch 1;
        @memcpy(initial[0..@min(n, name.len, 4)], name[0..@min(n, name.len, 4)]);
    }
    const label = c.gtk_label_new(&initial);
    c.gtk_widget_set_vexpand(label, 1);
    c.gtk_box_append(@ptrCast(@alignCast(box)), label);
    c.gtk_widget_add_css_class(box, "fallback");
    c.gtk_accessible_update_state(@ptrCast(@alignCast(box)), c.GTK_ACCESSIBLE_STATE_HIDDEN, @as(c_int, 1), @as(c_int, -1));

    if (icons.get(icon_key)) |icon| {
        show(box, icon);
    } else if (waiting.getPtr(icon_key)) |list| {
        list.append(core.gpa, box) catch return box;
        _ = c.g_object_ref(box);
    } else {
        const k = core.gpa.dupe(u8, icon_key) catch return box;
        if (fromDisk(k)) |icon| {
            icons.put(core.gpa, k, icon) catch {};
            show(box, icon);
        } else {
            var list: std.ArrayList(*c.GtkWidget) = .empty;
            list.append(core.gpa, box) catch return box;
            _ = c.g_object_ref(box);
            waiting.put(core.gpa, k, list) catch return box;
            const ctx = core.gpa.create([]const u8) catch return box;
            ctx.* = k;
            const j = core.Job.create(&onIcon, @ptrCast(ctx)) orelse return box;
            j.fetchIcon(website, subdomain, logo);
        }
    }
    return box;
}

fn onIcon(data: ?*anyopaque, r: *core.Result) void {
    const ctx: *[]const u8 = @ptrCast(@alignCast(data.?));
    const k = ctx.*;
    core.gpa.destroy(ctx);
    const icon: Icon = .{ .kind = r.icon, .texture = if (r.icon == .none) null else texture(r.icon, r.bytes) };
    // An icon not found is looked up again next launch.
    if (icon.texture != null) save(k, r.icon, r.bytes);
    const entry = waiting.fetchRemove(k) orelse return;
    var list = entry.value;
    icons.put(core.gpa, entry.key, icon) catch {};
    for (list.items) |box| {
        show(box, icon);
        c.g_object_unref(box);
    }
    list.deinit(core.gpa);
}

fn show(box: *c.GtkWidget, icon: Icon) void {
    const t = icon.texture orelse return;
    while (c.gtk_widget_get_first_child(box)) |child| c.gtk_box_remove(@ptrCast(@alignCast(box)), child);
    c.gtk_widget_remove_css_class(box, "fallback");
    if (icon.kind == .logo) c.gtk_widget_add_css_class(box, "logo");
    const image = c.gtk_image_new_from_paintable(@ptrCast(@alignCast(t)));
    c.gtk_image_set_pixel_size(@ptrCast(@alignCast(image)), if (icon.kind == .logo) size - 6 else size);
    c.gtk_widget_set_vexpand(image, 1);
    c.gtk_box_append(@ptrCast(@alignCast(box)), image);
}

/// Decodes `bytes`, trimming a logo's white margins.
fn texture(kind: Kind, bytes: []const u8) ?*c.GdkTexture {
    const t = gtk.texture(bytes) orelse return null;
    if (kind != .logo) return t;
    const downloader = c.gdk_texture_downloader_new(t);
    defer c.gdk_texture_downloader_free(downloader);
    c.gdk_texture_downloader_set_format(downloader, c.GDK_MEMORY_R8G8B8A8);
    var stride: usize = 0;
    const pixels = c.gdk_texture_downloader_download_bytes(downloader, &stride) orelse return t;
    defer c.g_bytes_unref(pixels);
    const w: usize = @intCast(c.gdk_texture_get_width(t));
    const h: usize = @intCast(c.gdk_texture_get_height(t));
    var len: usize = 0;
    const data: [*]const u8 = @ptrCast(c.g_bytes_get_data(pixels, &len) orelse return t);
    var bounds: [4]usize = undefined;
    if (!biblio.capi.biblio_logo_bounds(data, w, h, stride, 4, &bounds)) return t;
    const offset = bounds[1] * stride + bounds[0] * 4;
    const region = c.g_bytes_new_from_bytes(pixels, offset, (bounds[3] - 1) * stride + bounds[2] * 4);
    defer c.g_bytes_unref(region);
    const cropped = c.gdk_memory_texture_new(@intCast(bounds[2]), @intCast(bounds[3]), c.GDK_MEMORY_R8G8B8A8, region, stride);
    c.g_object_unref(t);
    return cropped;
}

// MARK: Disk cache

fn path(a: std.mem.Allocator, k: []const u8, kind: Kind) ?[:0]const u8 {
    var name: std.ArrayList(u8) = .empty;
    for (k) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '-') name.append(a, ch) catch return null else name.print(a, "%{X:0>2}", .{ch}) catch return null;
    }
    const dir = std.mem.span(c.g_get_user_cache_dir());
    return std.fmt.allocPrintSentinel(a, "{s}/biblio/icons/{s}.{s}", .{ dir, name.items, @tagName(kind) }, 0) catch null;
}

fn fromDisk(k: []const u8) ?Icon {
    var arena = std.heap.ArenaAllocator.init(core.gpa);
    defer arena.deinit();
    for ([_]Kind{ .square, .logo }) |kind| {
        const p = path(arena.allocator(), k, kind) orelse return null;
        var contents: [*c]c.gchar = null;
        var len: c.gsize = 0;
        if (c.g_file_get_contents(p.ptr, &contents, &len, null) == 0) continue;
        defer c.g_free(contents);
        return .{ .kind = kind, .texture = texture(kind, contents[0..len]) orelse continue };
    }
    return null;
}

fn save(k: []const u8, kind: Kind, bytes: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(core.gpa);
    defer arena.deinit();
    const p = path(arena.allocator(), k, kind) orelse return;
    const dir = std.fs.path.dirname(p) orelse return;
    _ = c.g_mkdir_with_parents(gtk.z(arena.allocator(), dir), 0o700);
    _ = c.g_file_set_contents(p.ptr, bytes.ptr, @intCast(bytes.len), null);
}

test key {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("www.wccls.org", key(a, "https://WWW.wccls.org/home", "wccls"));
    try std.testing.expectEqualStrings("smpl.org", key(a, "smpl.org", "smpl"));
    try std.testing.expectEqualStrings("wccls", key(a, null, "wccls"));
}
