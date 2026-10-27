//! One account's window (or a guest's): a sidebar of sections, the section's list, and the
//! selected item's details in a pane at the end. Collapses to a single column on phones.

const std = @import("std");
const gtk = @import("gtk.zig");
const c = gtk.c;
const core = @import("core.zig");
const store = @import("store.zig");
const main = @import("main.zig");
const ItemList = @import("list.zig").ItemList;
const Detail = @import("detail.zig").Detail;
const Account = @import("account.zig").Account;

pub const Section = enum {
    search,
    new_titles,
    holds,
    checkouts,
    history,
    account,

    pub fn title(s: Section) [*:0]const u8 {
        return switch (s) {
            .search => "Search",
            .new_titles => "New Titles",
            .holds => "Holds",
            .checkouts => "Checked Out",
            .history => "Borrowing History",
            .account => "Account",
        };
    }

    pub fn icon(s: Section) [*:0]const u8 {
        return switch (s) {
            .search => "system-search-symbolic",
            .new_titles => "starred-symbolic",
            .holds => "bookmark-new-symbolic",
            .checkouts => "view-list-bullet-symbolic",
            .history => "document-open-recent-symbolic",
            .account => "avatar-default-symbolic",
        };
    }
};

/// Open windows by login, so each login has one window (BiblioCommons ends a session when
/// the same login signs in elsewhere, so two windows would keep signing each other out).
var open_windows: std.StringHashMapUnmanaged(*Window) = .empty;

pub const Window = struct {
    window: *c.AdwApplicationWindow,
    toasts: *c.AdwToastOverlay,
    split: *c.AdwNavigationSplitView,
    inspector: *c.AdwOverlaySplitView,
    stack: *c.GtkStack,
    sidebar: *c.GtkListBox,
    count_labels: [6]?*c.GtkWidget = @splat(null),
    client: *core.Client,
    key: []u8,
    subdomain: []u8,
    username: []u8,
    library: std.json.Value,
    arena: std.heap.ArenaAllocator,
    lists: [5]?*ItemList = @splat(null),
    detail: *Detail = undefined,
    account: ?*Account = null,
    patron: ?std.json.Value = null,
    locations: []const std.json.Value = &.{},
    /// Calls in flight from this window and its parts; it is freed when it has closed and
    /// none remain, so callbacks never see a freed window.
    pending: u32 = 0,
    closed: bool = false,
    /// Result memory still referenced (patron, locations, list pages).
    kept: std.ArrayList(*std.heap.ArenaAllocator) = .empty,

    pub fn isOpen(subdomain: []const u8, username: []const u8) bool {
        var buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}|{s}", .{ subdomain, username }) catch return false;
        return username.len > 0 and open_windows.contains(key);
    }

    pub fn open(subdomain: []const u8, username: []const u8) void {
        const key = std.fmt.allocPrint(core.gpa, "{s}|{s}", .{ subdomain, username }) catch return;
        if (username.len > 0) if (open_windows.get(key)) |existing| {
            core.gpa.free(key);
            c.gtk_window_present(@ptrCast(@alignCast(existing.window)));
            return;
        };
        const lib_index = store.find(subdomain) orelse return;
        const w = core.gpa.create(Window) catch return;
        w.* = .{
            .window = @ptrCast(@alignCast(c.adw_application_window_new(@ptrCast(main.app)))),
            .toasts = @ptrCast(@alignCast(c.adw_toast_overlay_new())),
            .split = @ptrCast(@alignCast(c.adw_navigation_split_view_new())),
            .inspector = @ptrCast(@alignCast(c.adw_overlay_split_view_new())),
            .stack = @ptrCast(@alignCast(c.gtk_stack_new())),
            .sidebar = @ptrCast(@alignCast(c.gtk_list_box_new())),
            .client = core.client(subdomain, username) orelse return,
            .key = key,
            .subdomain = core.gpa.dupe(u8, subdomain) catch return,
            .username = core.gpa.dupe(u8, username) catch return,
            .library = store.libraries.items[lib_index],
            .arena = .init(core.gpa),
        };
        if (username.len > 0) open_windows.put(core.gpa, key, w) catch {};
        w.build();
        c.gtk_window_present(@ptrCast(@alignCast(w.window)));
        w.start();
    }

    pub fn a(w: *Window) std.mem.Allocator {
        return w.arena.allocator();
    }

    pub fn isGuest(w: *const Window) bool {
        return w.username.len == 0;
    }

    fn build(w: *Window) void {
        const title = if (w.isGuest())
            std.fmt.allocPrint(w.a(), "{s} — Guest", .{store.shortName(w.library)}) catch ""
        else
            std.fmt.allocPrint(w.a(), "{s} — {s}", .{ store.shortName(w.library), w.username }) catch "";
        c.gtk_window_set_title(@ptrCast(@alignCast(w.window)), gtk.z(w.a(), title));
        c.gtk_window_set_default_size(@ptrCast(@alignCast(w.window)), 1180, 760);

        // Sidebar: the sections.
        c.gtk_widget_add_css_class(gtk.widget(w.sidebar), "navigation-sidebar");
        const sections: []const Section = if (w.isGuest()) &.{ .search, .new_titles } else std.enums.values(Section);
        for (sections) |s| w.sidebar_row(s);
        gtk.connect(w.sidebar, "row-activated", &onSection, w);
        const sidebar_toolbar = c.adw_toolbar_view_new();
        const sidebar_header = c.adw_header_bar_new();
        c.adw_header_bar_set_title_widget(@ptrCast(@alignCast(sidebar_header)), c.adw_window_title_new(gtk.z(w.a(), store.shortName(w.library)), if (w.isGuest()) "Guest" else gtk.z(w.a(), w.username)));
        const switch_button = c.gtk_button_new_from_icon_name("system-switch-user-symbolic");
        c.gtk_widget_set_tooltip_text(switch_button, "Switch User or Library");
        gtk.connect(switch_button, "clicked", &onSwitch, w);
        c.adw_header_bar_pack_start(@ptrCast(@alignCast(sidebar_header)), switch_button);
        c.adw_toolbar_view_add_top_bar(@ptrCast(@alignCast(sidebar_toolbar)), sidebar_header);
        const sidebar_scroll = c.gtk_scrolled_window_new();
        c.gtk_scrolled_window_set_child(@ptrCast(@alignCast(sidebar_scroll)), gtk.widget(w.sidebar));
        c.adw_toolbar_view_set_content(@ptrCast(@alignCast(sidebar_toolbar)), sidebar_scroll);
        c.adw_navigation_split_view_set_sidebar(w.split, c.adw_navigation_page_new(sidebar_toolbar, "Sections"));

        // Content: the section's list, with the item details in a pane at the end.
        w.detail = Detail.create(w);
        for ([_]Section{ .search, .new_titles, .holds, .checkouts, .history }, 0..) |s, i| {
            if (w.isGuest() and i >= 2) break;
            const item_list = ItemList.create(w, s);
            w.lists[i] = item_list;
            _ = c.gtk_stack_add_named(w.stack, item_list.root, @tagName(s));
        }
        if (!w.isGuest()) {
            const account = Account.create(w);
            w.account = account;
            _ = c.gtk_stack_add_named(w.stack, account.root, "account");
        }
        c.adw_overlay_split_view_set_content(w.inspector, gtk.widget(w.stack));
        c.adw_overlay_split_view_set_sidebar(w.inspector, w.detail.root);
        c.adw_overlay_split_view_set_sidebar_position(w.inspector, c.GTK_PACK_END);
        c.adw_overlay_split_view_set_show_sidebar(w.inspector, 0);
        c.adw_overlay_split_view_set_min_sidebar_width(w.inspector, 340);
        c.adw_overlay_split_view_set_max_sidebar_width(w.inspector, 420);
        c.adw_navigation_split_view_set_content(w.split, c.adw_navigation_page_new(gtk.widget(w.inspector), "Biblio"));

        c.adw_toast_overlay_set_child(w.toasts, gtk.widget(w.split));
        c.adw_application_window_set_content(w.window, gtk.widget(w.toasts));

        // Narrow windows (phones): one column at a time; the details cover the list.
        w.addBreakpoint("max-width: 900sp", gtk.object(w.inspector));
        w.addBreakpoint("max-width: 600sp", gtk.object(w.split));

        gtk.connect(w.window, "destroy", &onDestroy, w);
        w.show(.search);
        c.gtk_list_box_select_row(w.sidebar, c.gtk_list_box_get_row_at_index(w.sidebar, 0));
    }

    fn addBreakpoint(w: *Window, condition: [*:0]const u8, target: *c.GObject) void {
        const bp = c.adw_breakpoint_new(c.adw_breakpoint_condition_parse(condition));
        var value = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&value, c.g_type_from_name("gboolean"));
        c.g_value_set_boolean(&value, 1);
        c.adw_breakpoint_add_setter(bp, target, "collapsed", &value);
        c.g_value_unset(&value);
        c.adw_application_window_add_breakpoint(w.window, bp);
    }

    fn sidebar_row(w: *Window, s: Section) void {
        const row = gtk.box(false, 12);
        gtk.margins(row, 6);
        gtk.append(row, c.gtk_image_new_from_icon_name(s.icon()));
        const title = gtk.label(std.mem.span(s.title()), w.a(), &.{});
        c.gtk_widget_set_hexpand(title, 1);
        gtk.append(row, title);
        const count = gtk.label("", w.a(), &.{ "dim-label", "numeric" });
        gtk.append(row, count);
        w.count_labels[@intFromEnum(s)] = count;
        const list_row = c.gtk_list_box_row_new();
        c.gtk_list_box_row_set_child(@ptrCast(@alignCast(list_row)), row);
        c.g_object_set_data(@ptrCast(@alignCast(list_row)), "section", @ptrFromInt(@intFromEnum(s) + 1));
        c.gtk_list_box_append(w.sidebar, list_row);
    }

    pub fn setCount(w: *Window, s: Section, count: ?i64) void {
        const l = w.count_labels[@intFromEnum(s)] orelse return;
        const text = if (count) |n| std.fmt.allocPrint(w.a(), "{d}", .{n}) catch "" else "";
        c.gtk_label_set_text(@ptrCast(@alignCast(l)), gtk.z(w.a(), text));
    }

    fn onSection(_: *c.GtkListBox, row: *c.GtkListBoxRow, data: ?*anyopaque) callconv(.c) void {
        const w: *Window = @ptrCast(@alignCast(data.?));
        const raw = @intFromPtr(c.g_object_get_data(@ptrCast(@alignCast(row)), "section"));
        if (raw == 0) return;
        w.show(@enumFromInt(raw - 1));
        c.adw_navigation_split_view_set_show_content(w.split, 1);
    }

    pub fn show(w: *Window, s: Section) void {
        c.gtk_stack_set_visible_child_name(w.stack, @tagName(s));
        if (s == .account) {
            c.adw_overlay_split_view_set_show_sidebar(w.inspector, 0);
            if (w.account) |acc| acc.refresh();
        } else if (w.lists[@intFromEnum(s)]) |item_list| {
            item_list.loadIfNeeded();
        }
    }

    /// Runs a core call on behalf of this window or one of its parts (`ctx`). The callback
    /// must start with `if (window.finishPending()) return;`.
    pub fn call(w: *Window, request: anytype, callback: core.Callback, ctx: ?*anyopaque) void {
        w.pending += 1;
        core.call(w.client, request, callback, ctx);
    }

    /// Keeps a result's memory until the window is freed.
    pub fn keep(w: *Window, r: *core.Result) void {
        w.kept.append(core.gpa, r.keep()) catch {};
    }

    fn start(w: *Window) void {
        w.call(.{ .op = "locations" }, &onLocations, w);
        if (w.isGuest()) return;
        w.call(.{ .op = "login" }, &onLogin, w);
    }

    fn onLogin(data: ?*anyopaque, r: *core.Result) void {
        const w: *Window = @ptrCast(@alignCast(data.?));
        if (w.finishPending()) return;
        if (!r.ok) return w.toast(r.message);
        w.patron = r.value;
        w.keep(r);
        // Fill the sidebar's hold and checkout counts without waiting for those lists to be opened.
        if (w.lists[@intFromEnum(Section.holds)]) |l| l.loadIfNeeded();
        if (w.lists[@intFromEnum(Section.checkouts)]) |l| l.loadIfNeeded();
        if (w.account) |acc| acc.refresh();
    }

    fn onLocations(data: ?*anyopaque, r: *core.Result) void {
        const w: *Window = @ptrCast(@alignCast(data.?));
        if (w.finishPending()) return;
        if (!r.ok) return;
        w.locations = core.items(r.value);
        w.keep(r);
    }

    /// Ends one outstanding call; true if the window has closed and was freed meanwhile.
    pub fn finishPending(w: *Window) bool {
        w.pending -= 1;
        if (w.closed and w.pending == 0) {
            w.free();
            return true;
        }
        return w.closed;
    }

    pub fn toast(w: *Window, message: []const u8) void {
        gtk.toast(w.toasts, message, w.a());
    }

    /// Shows `entry`'s item in the details pane.
    pub fn select(w: *Window, entry: std.json.Value) void {
        w.detail.showEntry(entry);
        c.adw_overlay_split_view_set_show_sidebar(w.inspector, 1);
    }

    pub fn hideDetail(w: *Window) void {
        c.adw_overlay_split_view_set_show_sidebar(w.inspector, 0);
    }

    pub fn list(w: *Window, s: Section) ?*ItemList {
        return if (@intFromEnum(s) < w.lists.len) w.lists[@intFromEnum(s)] else null;
    }

    /// After placing or cancelling a hold: refresh the holds list and catalog rows.
    pub fn holdsChanged(w: *Window) void {
        if (w.list(.holds)) |l| l.reload();
        for ([_]Section{ .search, .new_titles }) |s| if (w.list(s)) |l| l.reloadIfLoaded();
    }

    pub fn libraryLabels(w: *Window) ?std.json.Value {
        return if (w.library == .object) w.library.object.get("labels") else null;
    }

    fn onSwitch(_: *c.GtkButton, _: ?*anyopaque) callconv(.c) void {
        main.Launcher.open();
    }

    fn onDestroy(_: *c.GtkWidget, data: ?*anyopaque) callconv(.c) void {
        const w: *Window = @ptrCast(@alignCast(data.?));
        w.closed = true;
        _ = open_windows.remove(w.key);
        if (w.pending == 0) w.free();
    }

    fn free(w: *Window) void {
        for (w.lists) |l| if (l) |item_list| item_list.free();
        w.detail.free();
        if (w.account) |acc| acc.free();
        for (w.kept.items) |arena| core.release(arena);
        w.kept.deinit(core.gpa);
        @import("biblio").biblio_client_free(w.client);
        core.gpa.free(w.key);
        core.gpa.free(w.subdomain);
        core.gpa.free(w.username);
        w.arena.deinit();
        core.gpa.destroy(w);
    }
};
