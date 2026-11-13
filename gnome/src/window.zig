//! One account's window (or a guest's): a sidebar of sections, the section's list, and the
//! selected item's details in a pane at the end. Collapses to a single column on phones.

const std = @import("std");
const gtk = @import("gtk.zig");
const c = gtk.c;
const core = @import("core.zig");
const capi = core.capi;
const store = @import("store.zig");
const main = @import("main.zig");
const ItemList = @import("list.zig").ItemList;
const Detail = @import("detail.zig").Detail;
const Account = @import("account.zig").Account;
const Borrowed = @import("borrowed.zig").Borrowed;
const barcode = @import("barcode.zig");

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

/// How long the status bar stays after the last request finishes.
const status_fade_ms = 2000;

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
    /// "Couldn’t sign in", with Try Again.
    banner: *c.AdwBanner,
    status_revealer: *c.GtkRevealer,
    status_label: *c.GtkLabel,
    status_spinner: *c.GtkWidget,
    status_fade: c.guint = 0,
    count_labels: [6]?*c.GtkWidget = @splat(null),
    client: *core.Client,
    key: []u8,
    subdomain: []u8,
    username: []u8,
    library: std.json.Value,
    /// The library's labels, for format and sort names.
    labels: []const capi.Pair = &.{},
    arena: std.heap.ArenaAllocator,
    section: Section = .search,
    lists: [5]?*ItemList = @splat(null),
    detail: *Detail = undefined,
    account: ?*Account = null,
    /// What this login borrowed before; null for guests.
    borrowed: ?*Borrowed = null,
    /// The signed-in patron, replaced (and the old one released) when it is fetched again.
    patron: ?*capi.Patron = null,
    locations: []const capi.Location = &.{},
    location_list: ?*capi.LocationList = null,
    /// Calls in flight from this window and its parts; it is freed when it has closed and
    /// none remain, so callbacks never see a freed window.
    pending: u32 = 0,
    closed: bool = false,
    /// A title to show in the details once its list has it (a guest window's item, after signing in).
    pending_select: ?[]u8 = null,

    pub fn isOpen(subdomain: []const u8, username: []const u8) bool {
        var buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}|{s}", .{ subdomain, username }) catch return false;
        return username.len > 0 and open_windows.contains(key);
    }

    /// Whether any of the library's logins has a window.
    pub fn libraryIsOpen(subdomain: []const u8) bool {
        var it = open_windows.valueIterator();
        while (it.next()) |w| if (std.mem.eql(u8, w.*.subdomain, subdomain)) return true;
        return false;
    }

    /// Opens (or brings forward) the login's window; null if it couldn't be made.
    pub fn open(subdomain: []const u8, username: []const u8) ?*Window {
        if (username.len > 0) {
            var buf: [512]u8 = undefined;
            const probe = std.fmt.bufPrint(&buf, "{s}|{s}", .{ subdomain, username }) catch "";
            if (open_windows.get(probe)) |existing| {
                c.gtk_window_present(@ptrCast(@alignCast(existing.window)));
                return existing;
            }
        }
        const lib_index = store.find(subdomain) orelse return null;
        // Everything that can fail comes before the first widget, so a failure leaves nothing behind.
        const key = std.fmt.allocPrint(core.gpa, "{s}|{s}", .{ subdomain, username }) catch return null;
        errdefer core.gpa.free(key);
        const sub = core.gpa.dupe(u8, subdomain) catch return null;
        errdefer core.gpa.free(sub);
        const user = core.gpa.dupe(u8, username) catch return null;
        errdefer core.gpa.free(user);
        const w = core.gpa.create(Window) catch return null;
        errdefer core.gpa.destroy(w);
        if (username.len > 0) open_windows.put(core.gpa, key, w) catch return null;
        errdefer _ = open_windows.remove(key);
        const client = core.client(subdomain, username) orelse return null;

        w.* = .{
            .window = @ptrCast(@alignCast(c.adw_application_window_new(@ptrCast(main.app)))),
            .toasts = @ptrCast(@alignCast(c.adw_toast_overlay_new())),
            .split = @ptrCast(@alignCast(c.adw_navigation_split_view_new())),
            .inspector = @ptrCast(@alignCast(c.adw_overlay_split_view_new())),
            .stack = @ptrCast(@alignCast(c.gtk_stack_new())),
            .sidebar = @ptrCast(@alignCast(c.gtk_list_box_new())),
            .banner = @ptrCast(@alignCast(c.adw_banner_new(""))),
            .status_revealer = @ptrCast(@alignCast(c.gtk_revealer_new())),
            .status_label = @ptrCast(@alignCast(c.gtk_label_new(""))),
            .status_spinner = c.adw_spinner_new(),
            .client = client,
            .key = key,
            .subdomain = sub,
            .username = user,
            .library = store.libraries.items[lib_index],
            .arena = .init(core.gpa),
        };
        w.labels = store.labels(w.a(), w.library);
        if (!w.isGuest()) w.borrowed = Borrowed.create(w);
        w.build();
        c.gtk_window_present(@ptrCast(@alignCast(w.window)));
        w.start();
        main.Launcher.windowsChanged();
        return w;
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
        c.gtk_application_window_set_help_overlay(@ptrCast(@alignCast(w.window)), main.shortcutsWindow());

        // Sidebar: the sections.
        c.gtk_widget_add_css_class(gtk.widget(w.sidebar), "navigation-sidebar");
        const sections: []const Section = if (w.isGuest()) &.{ .search, .new_titles } else std.enums.values(Section);
        for (sections) |s| w.sidebarRow(s);
        gtk.connect(w.sidebar, "row-activated", &onSection, w);
        const sidebar_toolbar = c.adw_toolbar_view_new();
        const sidebar_header = c.adw_header_bar_new();
        c.adw_header_bar_set_title_widget(@ptrCast(@alignCast(sidebar_header)), c.adw_window_title_new(gtk.z(w.a(), store.shortName(w.library)), if (w.isGuest()) "Guest" else gtk.z(w.a(), w.username)));
        const switch_button = c.gtk_button_new_from_icon_name("system-switch-user-symbolic");
        c.gtk_widget_set_tooltip_text(switch_button, "Switch User or Library");
        gtk.connect(switch_button, "clicked", &onSwitch, w);
        c.adw_header_bar_pack_start(@ptrCast(@alignCast(sidebar_header)), switch_button);
        c.adw_header_bar_pack_end(@ptrCast(@alignCast(sidebar_header)), main.primaryMenu(true));
        c.adw_toolbar_view_add_top_bar(@ptrCast(@alignCast(sidebar_toolbar)), sidebar_header);
        const sidebar_scroll = c.gtk_scrolled_window_new();
        c.gtk_scrolled_window_set_child(@ptrCast(@alignCast(sidebar_scroll)), gtk.widget(w.sidebar));
        c.adw_toolbar_view_set_content(@ptrCast(@alignCast(sidebar_toolbar)), sidebar_scroll);
        c.adw_toolbar_view_add_bottom_bar(@ptrCast(@alignCast(sidebar_toolbar)), w.sidebarFooter());
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

        c.adw_banner_set_button_label(w.banner, "_Try Again");
        gtk.connect(w.banner, "button-clicked", &onRetrySignIn, w);
        const content = gtk.box(true, 0);
        gtk.append(content, gtk.widget(w.banner));
        c.gtk_widget_set_vexpand(gtk.widget(w.inspector), 1);
        gtk.append(content, gtk.widget(w.inspector));
        gtk.append(content, w.statusBar());
        c.adw_navigation_split_view_set_content(w.split, c.adw_navigation_page_new(content, "Biblio"));

        c.adw_toast_overlay_set_child(w.toasts, gtk.widget(w.split));
        c.adw_application_window_set_content(w.window, gtk.widget(w.toasts));

        // Narrow windows (phones): one column at a time; the details cover the list.
        // Only the last matching breakpoint applies, so the narrower one repeats the wider one's setter.
        const advanced_button = if (w.lists[0]) |search| search.advanced_button else null;
        w.addBreakpoint("max-width: 900sp", &.{gtk.object(w.inspector)}, null);
        w.addBreakpoint("max-width: 600sp", &.{ gtk.object(w.inspector), gtk.object(w.split) }, advanced_button);

        gtk.connect(w.inspector, "notify::collapsed", &onInspectorCollapsed, w);
        w.addActions();
        gtk.connect(w.window, "destroy", &onDestroy, w);
        w.show(.search);
        c.gtk_list_box_select_row(w.sidebar, c.gtk_list_box_get_row_at_index(w.sidebar, 0));
    }

    /// Sign In for guests, the library card for accounts, and the app's version.
    fn sidebarFooter(w: *Window) *c.GtkWidget {
        const footer = gtk.box(true, 6);
        gtk.margins(footer, 6);
        if (w.isGuest()) {
            const sign_in = c.gtk_button_new_with_mnemonic("_Sign In");
            c.gtk_widget_add_css_class(sign_in, "suggested-action");
            c.gtk_widget_add_css_class(sign_in, "pill");
            c.gtk_widget_set_halign(sign_in, c.GTK_ALIGN_CENTER);
            gtk.connect(sign_in, "clicked", &onSignIn, w);
            gtk.append(footer, sign_in);
        } else {
            const card = c.gtk_button_new_with_mnemonic("Library _Card");
            c.gtk_widget_set_tooltip_text(card, "Show your library card’s barcode");
            c.gtk_widget_set_halign(card, c.GTK_ALIGN_CENTER);
            gtk.connect(card, "clicked", &onCard, w);
            gtk.append(footer, card);
        }
        const version = std.fmt.allocPrint(w.a(), "Version {s}", .{std.mem.span(@import("biblio").biblio_version())}) catch "About Biblio";
        const about = c.gtk_button_new_with_label(gtk.z(w.a(), version));
        c.gtk_widget_add_css_class(about, "flat");
        c.gtk_widget_add_css_class(about, "dim-label");
        c.gtk_widget_add_css_class(about, "caption");
        c.gtk_widget_set_halign(about, c.GTK_ALIGN_CENTER);
        c.gtk_widget_set_tooltip_text(about, "About Biblio");
        c.gtk_actionable_set_action_name(@ptrCast(@alignCast(about)), "app.about");
        gtk.append(footer, about);
        return footer;
    }

    /// The latest request, as `TITLE [SIZE KiB]` (the URL on hover), fading once requests stop.
    fn statusBar(w: *Window) *c.GtkWidget {
        const bar = gtk.box(false, 6);
        c.gtk_widget_add_css_class(bar, "status-bar");
        c.gtk_label_set_ellipsize(w.status_label, c.PANGO_ELLIPSIZE_MIDDLE);
        c.gtk_label_set_xalign(w.status_label, 0);
        c.gtk_widget_set_hexpand(gtk.widget(w.status_label), 1);
        c.gtk_widget_add_css_class(gtk.widget(w.status_label), "caption");
        c.gtk_widget_add_css_class(gtk.widget(w.status_label), "dim-label");
        c.gtk_widget_add_css_class(gtk.widget(w.status_label), "numeric");
        gtk.append(bar, gtk.widget(w.status_label));
        c.gtk_widget_set_size_request(w.status_spinner, 12, 12);
        gtk.append(bar, w.status_spinner);
        c.gtk_revealer_set_transition_type(w.status_revealer, c.GTK_REVEALER_TRANSITION_TYPE_CROSSFADE);
        c.gtk_revealer_set_transition_duration(w.status_revealer, 400);
        c.gtk_revealer_set_child(w.status_revealer, bar);
        return gtk.widget(w.status_revealer);
    }

    /// Collapses `targets` (and hides `hidden`, if any) when the condition holds.
    fn addBreakpoint(w: *Window, condition: [*:0]const u8, targets: []const *c.GObject, hidden: ?*c.GtkWidget) void {
        const bp = c.adw_breakpoint_new(c.adw_breakpoint_condition_parse(condition));
        var value = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&value, c.G_TYPE_BOOLEAN);
        c.g_value_set_boolean(&value, 1);
        for (targets) |target| c.adw_breakpoint_add_setter(bp, target, "collapsed", &value);
        c.g_value_set_boolean(&value, 0);
        if (hidden) |widget| c.adw_breakpoint_add_setter(bp, gtk.object(widget), "visible", &value);
        c.g_value_unset(&value);
        c.adw_application_window_add_breakpoint(w.window, bp);
    }

    /// Ctrl+R refreshes the section; Ctrl+F searches.
    fn addActions(w: *Window) void {
        const actions = [_]struct { name: [*:0]const u8, handler: *const fn (*c.GSimpleAction, ?*c.GVariant, ?*anyopaque) callconv(.c) void }{
            .{ .name = "refresh", .handler = &onRefreshAction },
            .{ .name = "search", .handler = &onSearchAction },
            .{ .name = "advanced-search", .handler = &onAdvancedAction },
        };
        for (actions) |action| {
            const simple = c.g_simple_action_new(action.name, null);
            gtk.connect(simple, "activate", action.handler, w);
            c.g_action_map_add_action(@ptrCast(@alignCast(w.window)), @ptrCast(@alignCast(simple)));
            c.g_object_unref(simple);
        }
    }

    fn sidebarRow(w: *Window, s: Section) void {
        const row = gtk.box(false, 12);
        gtk.margins(row, 6);
        gtk.append(row, c.gtk_image_new_from_icon_name(s.icon()));
        const title = gtk.label(std.mem.span(s.title()), w.a(), &.{});
        c.gtk_widget_set_hexpand(title, 1);
        gtk.append(row, title);
        const count = gtk.label("", w.a(), &.{ "dim-label", "numeric" });
        gtk.append(row, count);
        w.count_labels[@backingInt(s)] = count;
        const list_row = c.gtk_list_box_row_new();
        c.gtk_list_box_row_set_child(@ptrCast(@alignCast(list_row)), row);
        c.g_object_set_data(@ptrCast(@alignCast(list_row)), "section", @ptrFromInt(@backingInt(s) + 1));
        c.gtk_list_box_append(w.sidebar, list_row);
    }

    pub fn setCount(w: *Window, s: Section, count: ?i64) void {
        const l = w.count_labels[@backingInt(s)] orelse return;
        const text = if (count) |n| std.fmt.allocPrint(w.a(), "{d}", .{n}) catch "" else "";
        c.gtk_label_set_text(@ptrCast(@alignCast(l)), gtk.z(w.a(), text));
    }

    fn onSection(_: *c.GtkListBox, row: *c.GtkListBoxRow, data: ?*anyopaque) callconv(.c) void {
        const w: *Window = @ptrCast(@alignCast(data.?));
        const raw = @intFromPtr(c.g_object_get_data(@ptrCast(@alignCast(row)), "section"));
        if (raw == 0) return;
        w.show(@fromBackingInt(@intCast(raw - 1)));
        c.adw_navigation_split_view_set_show_content(w.split, 1);
    }

    /// Shows a section; the inspector, which belongs to the section left, closes.
    pub fn show(w: *Window, s: Section) void {
        if (s != w.section) {
            w.hideDetail();
            if (w.list(w.section)) |previous| previous.endSelecting();
        }
        w.section = s;
        c.gtk_stack_set_visible_child_name(w.stack, @tagName(s));
        // Selecting it too, for sections shown without the sidebar (Ctrl+F, an author's works).
        const index: c_int = @backingInt(s);
        if (c.gtk_list_box_get_row_at_index(w.sidebar, index)) |row| {
            if (c.gtk_list_box_get_selected_row(w.sidebar) != row) c.gtk_list_box_select_row(w.sidebar, row);
        }
        if (s == .account) {
            if (w.account) |acc| acc.refresh();
        } else if (w.lists[@backingInt(s)]) |item_list| {
            item_list.loadIfNeeded();
        }
    }

    /// A core call on behalf of this window or one of its parts (`ctx`), to be started with
    /// `Job.start`. The callback must start with `if (window.finishPending()) return;`.
    pub fn job(w: *Window, callback: core.Callback, ctx: ?*anyopaque) ?*core.Job {
        const j = core.Job.create(callback, ctx) orelse return null;
        w.pending += 1;
        w.updateStatus();
        return j;
    }

    /// Replaces the patron, releasing the one it replaces.
    pub fn setPatron(w: *Window, patron: *capi.Patron) void {
        if (w.patron) |old| core.release(old);
        w.patron = patron;
    }

    fn start(w: *Window) void {
        if (w.isGuest()) return;
        if (w.job(&onLocations, w)) |j| j.start(capi.biblio_locations, .{w.client});
        w.signIn(false);
    }

    fn signIn(w: *Window, force: bool) void {
        c.adw_banner_set_revealed(w.banner, 0);
        if (w.job(&onLogin, w)) |j| j.start(capi.biblio_login, .{ w.client, force });
    }

    fn onLogin(data: ?*anyopaque, r: *core.Result) void {
        const w: *Window = @ptrCast(@alignCast(data.?));
        if (w.finishPending()) return;
        if (!r.ok) {
            // The account sections need a session: say so, with a way to try again.
            const title = std.fmt.allocPrint(w.a(), "Couldn’t sign in: {s}", .{r.message}) catch "Couldn’t sign in.";
            c.adw_banner_set_title(w.banner, gtk.z(w.a(), title));
            c.adw_banner_set_revealed(w.banner, 1);
            return;
        }
        w.setPatron(r.keep(capi.Patron) orelse return);
        // Fill the sidebar's hold and checkout counts without waiting for those lists to be opened.
        for ([_]Section{ .holds, .checkouts, w.section }) |s| if (w.list(s)) |l| l.loadIfNeeded();
        if (w.borrowed) |b| if (w.patron) |p| b.patronChanged(p);
        if (w.account) |acc| acc.refresh();
        // Item detail's pickup locations follow the preferred one.
        w.detail.refresh();
    }

    fn onRetrySignIn(_: *c.AdwBanner, data: ?*anyopaque) callconv(.c) void {
        const w: *Window = @ptrCast(@alignCast(data.?));
        w.signIn(true);
    }

    fn onLocations(data: ?*anyopaque, r: *core.Result) void {
        const w: *Window = @ptrCast(@alignCast(data.?));
        if (w.finishPending()) return;
        if (!r.ok) return;
        const locations = r.keep(capi.LocationList) orelse return;
        if (w.location_list) |old| core.release(old);
        w.location_list = locations;
        w.locations = core.items(capi.Location, locations.items, locations.items_count);
        w.detail.refresh();
    }

    /// Ends one outstanding call; true if the window has closed (and is freed, or will be).
    pub fn finishPending(w: *Window) bool {
        w.pending -= 1;
        if (w.closed) {
            if (w.pending == 0) w.free();
            return true;
        }
        w.updateStatus();
        return false;
    }

    pub fn toast(w: *Window, message: []const u8) void {
        gtk.toast(w.toasts, message, w.a());
    }

    // MARK: Status bar

    fn updateStatus(w: *Window) void {
        var status: ?*capi.FetchStatus = null;
        if (capi.biblio_status(w.client, &status, null) != .ok) return;
        const s = status orelse return;
        defer core.release(s);
        const active = s.active > 0;
        c.gtk_widget_set_visible(w.status_spinner, @intFromBool(active));
        if (core.str(s.title)) |title| {
            var buf: [1024]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&buf);
            const kib = @as(f64, @floatFromInt(s.bytes)) / 1024;
            const text = std.fmt.allocPrint(fba.allocator(), "{s} [{d:.1} KiB]", .{ title, kib }) catch title;
            c.gtk_label_set_text(w.status_label, gtk.z(fba.allocator(), text));
            c.gtk_widget_set_tooltip_text(gtk.widget(w.status_label), if (s.url) |u| u else null);
        } else if (!active) return;
        c.gtk_revealer_set_reveal_child(w.status_revealer, 1);
        if (w.status_fade != 0) _ = c.g_source_remove(w.status_fade);
        w.status_fade = if (active) 0 else c.g_timeout_add(status_fade_ms, &onStatusFade, w);
    }

    fn onStatusFade(data: ?*anyopaque) callconv(.c) c.gboolean {
        const w: *Window = @ptrCast(@alignCast(data.?));
        w.status_fade = 0;
        c.gtk_revealer_set_reveal_child(w.status_revealer, 0);
        return 0; // G_SOURCE_REMOVE
    }

    // MARK: Selection

    /// Shows `entry`'s item in the details pane.
    pub fn select(w: *Window, entry: *const capi.ListEntry) void {
        w.detail.showEntry(entry);
        c.adw_overlay_split_view_set_show_sidebar(w.inspector, 1);
    }

    /// Several items are selected: one item's details no longer apply, and the list's bottom
    /// bar offers what can be done with them all.
    pub fn selectMany(w: *Window, section: Section, entries: []const *const capi.ListEntry) void {
        _ = entries;
        _ = section;
        w.hideDetail();
    }

    /// A list fetched rows: shows the title waiting to be shown, if this list has it.
    pub fn selectPending(w: *Window, l: *ItemList) void {
        const id = w.pending_select orelse return;
        if (l.section != w.section) return;
        const entry = l.entryForBib(id) orelse return;
        core.gpa.free(id);
        w.pending_select = null;
        w.select(entry);
    }

    pub fn hideDetail(w: *Window) void {
        c.adw_overlay_split_view_set_show_sidebar(w.inspector, 0);
    }

    pub fn list(w: *Window, s: Section) ?*ItemList {
        return if (@backingInt(s) < w.lists.len) w.lists[@backingInt(s)] else null;
    }

    /// This account's hold on a title, from the holds list.
    pub fn holdFor(w: *Window, bib_id: []const u8) ?*const capi.ListEntry {
        const holds = w.list(.holds) orelse return null;
        return holds.entryForBib(bib_id);
    }

    /// After placing holds: catalog rows say so at once, and the holds list refreshes.
    pub fn holdsPlaced(w: *Window, bib_ids: []const []const u8) void {
        for ([_]Section{ .search, .new_titles }) |s| if (w.list(s)) |l| l.markHeld(bib_ids, true);
        if (w.list(.holds)) |l| l.reload();
    }

    /// After canceling holds: their rows go, and catalog rows lose their mark.
    pub fn holdsCanceled(w: *Window, hold_ids: []const []const u8, bib_ids: []const []const u8) void {
        for ([_]Section{ .search, .new_titles }) |s| if (w.list(s)) |l| l.markHeld(bib_ids, false);
        if (w.list(.holds)) |l| if (hold_ids.len > 0) l.removeEntries(hold_ids) else l.reload();
    }

    /// The borrowed-before index changed: marks, filters, and progress follow it.
    pub fn borrowedChanged(w: *Window) void {
        for ([_]Section{ .search, .new_titles, .holds }) |s| if (w.list(s)) |l| l.borrowedChanged();
        w.detail.borrowedChanged();
        if (w.account) |acc| acc.borrowedChanged();
    }

    // MARK: Signing in from a guest window

    /// The sign-in sheet: the library's users, or the sign-in form if it has none.
    pub fn requestSignIn(w: *Window) void {
        @import("signin.zig").SignIn.present(w);
    }

    /// Opens the login's window where this guest window left off: its search, section, and
    /// selection. Then the guest window closes.
    pub fn continueAs(w: *Window, username: []const u8) void {
        const next = open(w.subdomain, username) orelse return w.toast("Biblio couldn’t open that account.");
        if (next == w) return;
        if (w.list(.search)) |from| if (next.list(.search)) |to| to.continueFrom(from);
        next.show(w.section);
        if (c.adw_overlay_split_view_get_show_sidebar(w.inspector) != 0) if (w.detail.shown()) |entry| {
            // The signed-in rows say what this account has of it, so show theirs.
            next.pending_select = core.gpa.dupe(u8, std.mem.span(entry.bib.id)) catch null;
        };
        c.gtk_window_close(@ptrCast(@alignCast(w.window)));
    }

    fn onSignIn(_: *c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const w: *Window = @ptrCast(@alignCast(data.?));
        w.requestSignIn();
    }

    fn onCard(_: *c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const w: *Window = @ptrCast(@alignCast(data.?));
        const value = if (w.patron) |p| core.str(p.barcode) else null;
        const dialog: *c.AdwDialog = @ptrCast(@alignCast(c.adw_dialog_new()));
        c.adw_dialog_set_title(dialog, "Library Card");
        c.adw_dialog_set_content_width(dialog, 420);
        const toolbar = c.adw_toolbar_view_new();
        c.adw_toolbar_view_add_top_bar(@ptrCast(@alignCast(toolbar)), c.adw_header_bar_new());
        const body = gtk.box(true, 12);
        gtk.margins(body, 24);
        if (value) |v| {
            gtk.append(body, barcode.card(v, store.barcodeType(w.subdomain), 120));
            gtk.append(body, gtk.label("Show this at the library’s self-checkout or desk. Change the barcode type in Account.", w.a(), &.{ "dim-label", "caption" }));
        } else {
            gtk.append(body, gtk.label(if (w.patron == null) "Sign in to show your library card." else "The library didn’t give a card number for this account.", w.a(), &.{"dim-label"}));
        }
        c.adw_toolbar_view_set_content(@ptrCast(@alignCast(toolbar)), body);
        c.adw_dialog_set_child(dialog, toolbar);
        c.adw_dialog_present(dialog, gtk.widget(w.window));
    }

    // MARK: Actions

    fn onRefreshAction(_: *c.GSimpleAction, _: ?*c.GVariant, data: ?*anyopaque) callconv(.c) void {
        const w: *Window = @ptrCast(@alignCast(data.?));
        if (w.list(w.section)) |l| return l.refresh();
        if (w.section == .account) w.signIn(true);
    }

    fn onSearchAction(_: *c.GSimpleAction, _: ?*c.GVariant, data: ?*anyopaque) callconv(.c) void {
        const w: *Window = @ptrCast(@alignCast(data.?));
        w.show(.search);
        c.adw_navigation_split_view_set_show_content(w.split, 1);
        if (w.list(.search)) |l| l.focusSearch();
    }

    /// The split view shows its sidebar again when the window grows wide; with no item to
    /// show, that would be an empty pane.
    fn onInspectorCollapsed(_: *c.AdwOverlaySplitView, _: ?*c.GParamSpec, data: ?*anyopaque) callconv(.c) void {
        const w: *Window = @ptrCast(@alignCast(data.?));
        if (c.adw_overlay_split_view_get_collapsed(w.inspector) == 0 and w.detail.shown() == null) w.hideDetail();
    }

    fn onAdvancedAction(_: *c.GSimpleAction, _: ?*c.GVariant, data: ?*anyopaque) callconv(.c) void {
        const w: *Window = @ptrCast(@alignCast(data.?));
        if (w.list(.search)) |l| l.openAdvanced();
    }

    fn onSwitch(_: *c.GtkButton, _: ?*anyopaque) callconv(.c) void {
        main.Launcher.open();
    }

    fn onDestroy(_: *c.GtkWidget, data: ?*anyopaque) callconv(.c) void {
        const w: *Window = @ptrCast(@alignCast(data.?));
        w.closed = true;
        _ = open_windows.remove(w.key);
        if (w.status_fade != 0) _ = c.g_source_remove(w.status_fade);
        w.status_fade = 0;
        @import("log.zig").sync();
        main.Launcher.windowsChanged();
        // Freed once the window's widgets are gone: they still emit signals (such as a list's
        // unbind) while the window is disposed, after "destroy", and their handlers use `w`.
        w.pending += 1;
        gtk.idle(&onDisposed, w);
    }

    fn onDisposed(data: ?*anyopaque) callconv(.c) c.gboolean {
        const w: *Window = @ptrCast(@alignCast(data.?));
        _ = w.finishPending();
        return 0; // G_SOURCE_REMOVE
    }

    fn free(w: *Window) void {
        for (w.lists) |l| if (l) |item_list| item_list.free();
        w.detail.free();
        if (w.account) |acc| acc.free();
        if (w.borrowed) |b| b.free();
        if (w.patron) |p| core.release(p);
        if (w.pending_select) |id| core.gpa.free(id);
        if (w.location_list) |l| core.release(l);
        @import("biblio").biblio_client_free(w.client);
        core.gpa.free(w.key);
        core.gpa.free(w.subdomain);
        core.gpa.free(w.username);
        w.arena.deinit();
        core.gpa.destroy(w);
    }
};
