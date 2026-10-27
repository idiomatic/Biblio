//! A paged, infinitely scrolling list of catalog search results, new titles, holds,
//! checkouts or borrowing history, with sorting and (for searches) a format filter.

const std = @import("std");
const gtk = @import("gtk.zig");
const c = gtk.c;
const core = @import("core.zig");
const win = @import("window.zig");
const Window = win.Window;
const Section = win.Section;

pub const ItemList = struct {
    window: *Window,
    section: Section,
    root: *c.GtkWidget,
    stack: *c.GtkStack,
    list_box: *c.GtkListBox,
    status: *c.AdwStatusPage,
    title: *c.AdwWindowTitle,
    search: ?*c.GtkSearchEntry = null,
    sort_dropdown: *c.GtkDropDown,
    format_dropdown: *c.GtkDropDown,
    spinner: *c.GtkWidget,
    arena: std.heap.ArenaAllocator,
    /// Each page's result memory, released on reload.
    pages_memory: std.ArrayList(*std.heap.ArenaAllocator) = .empty,
    entries: std.ArrayList(std.json.Value) = .empty,
    query: []const u8 = "",
    sort: ?[]const u8 = null,
    format: ?[]const u8 = null,
    sort_ids: []const []const u8 = &.{},
    format_ids: []const []const u8 = &.{},
    page: i64 = 0,
    pages: i64 = 1,
    count: i64 = 0,
    loading: bool = false,
    loaded: bool = false,
    /// Bumped on reload so responses for an older query are ignored.
    generation: u32 = 0,
    /// Set while the dropdowns are being refilled, so their change signals are ignored.
    updating: bool = false,

    pub fn create(w: *Window, section: Section) *ItemList {
        const l = core.gpa.create(ItemList) catch unreachable;
        const toolbar = c.adw_toolbar_view_new();
        const header = c.adw_header_bar_new();
        const title: *c.AdwWindowTitle = @ptrCast(@alignCast(c.adw_window_title_new(section.title(), "")));
        const sort_dropdown: *c.GtkDropDown = @ptrCast(@alignCast(c.gtk_drop_down_new(null, null)));
        c.gtk_widget_set_tooltip_text(gtk.widget(sort_dropdown), "Sort");
        const format_dropdown: *c.GtkDropDown = @ptrCast(@alignCast(c.gtk_drop_down_new(null, null)));
        c.gtk_widget_set_tooltip_text(gtk.widget(format_dropdown), "Format");
        c.gtk_widget_set_visible(gtk.widget(format_dropdown), 0);
        const spinner = c.adw_spinner_new();
        c.gtk_widget_set_visible(spinner, 0);
        c.adw_header_bar_pack_end(@ptrCast(@alignCast(header)), gtk.widget(sort_dropdown));
        c.adw_header_bar_pack_end(@ptrCast(@alignCast(header)), gtk.widget(format_dropdown));
        c.adw_header_bar_pack_start(@ptrCast(@alignCast(header)), spinner);
        c.adw_toolbar_view_add_top_bar(@ptrCast(@alignCast(toolbar)), header);

        l.* = .{
            .window = w,
            .section = section,
            .root = toolbar,
            .stack = @ptrCast(@alignCast(c.gtk_stack_new())),
            .list_box = @ptrCast(@alignCast(c.gtk_list_box_new())),
            .status = @ptrCast(@alignCast(c.adw_status_page_new())),
            .title = title,
            .sort_dropdown = sort_dropdown,
            .format_dropdown = format_dropdown,
            .spinner = spinner,
            .arena = .init(core.gpa),
        };
        if (section == .search) {
            const search: *c.GtkSearchEntry = @ptrCast(@alignCast(c.gtk_search_entry_new()));
            c.gtk_search_entry_set_placeholder_text(search, "Search the catalog");
            c.gtk_widget_set_hexpand(gtk.widget(search), 1);
            const clamp = c.adw_clamp_new();
            c.adw_clamp_set_maximum_size(@ptrCast(@alignCast(clamp)), 480);
            c.adw_clamp_set_child(@ptrCast(@alignCast(clamp)), gtk.widget(search));
            c.adw_header_bar_set_title_widget(@ptrCast(@alignCast(header)), clamp);
            gtk.connect(search, "activate", &onSearch, l);
            l.search = search;
        } else {
            c.adw_header_bar_set_title_widget(@ptrCast(@alignCast(header)), gtk.widget(title));
        }

        c.gtk_list_box_set_selection_mode(l.list_box, c.GTK_SELECTION_SINGLE);
        c.gtk_widget_add_css_class(gtk.widget(l.list_box), "boxed-list");
        gtk.margins(gtk.widget(l.list_box), 12);
        gtk.connect(l.list_box, "row-activated", &onRow, l);
        const clamp = c.adw_clamp_new();
        c.adw_clamp_set_maximum_size(@ptrCast(@alignCast(clamp)), 900);
        c.adw_clamp_set_child(@ptrCast(@alignCast(clamp)), gtk.widget(l.list_box));
        const scroll = c.gtk_scrolled_window_new();
        c.gtk_scrolled_window_set_child(@ptrCast(@alignCast(scroll)), clamp);
        c.gtk_scrolled_window_set_policy(@ptrCast(@alignCast(scroll)), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
        gtk.connect(scroll, "edge-reached", &onEdge, l);
        _ = c.gtk_stack_add_named(l.stack, scroll, "list");
        _ = c.gtk_stack_add_named(l.stack, gtk.widget(l.status), "status");
        c.adw_toolbar_view_set_content(@ptrCast(@alignCast(toolbar)), gtk.widget(l.stack));

        gtk.connect(sort_dropdown, "notify::selected", &onSort, l);
        gtk.connect(format_dropdown, "notify::selected", &onFormat, l);
        l.showEmpty();
        return l;
    }

    pub fn free(l: *ItemList) void {
        for (l.pages_memory.items) |arena| core.release(arena);
        l.pages_memory.deinit(core.gpa);
        l.entries.deinit(core.gpa);
        l.arena.deinit();
        core.gpa.destroy(l);
    }

    fn a(l: *ItemList) std.mem.Allocator {
        return l.arena.allocator();
    }

    fn showEmpty(l: *ItemList) void {
        const s = l.status;
        switch (l.section) {
            .search => {
                c.adw_status_page_set_icon_name(s, "system-search-symbolic");
                const t = std.fmt.allocPrint(l.a(), "Search {s}", .{@import("store.zig").shortName(l.window.library)}) catch "Search";
                c.adw_status_page_set_title(s, gtk.z(l.a(), t));
                c.adw_status_page_set_description(s, if (l.query.len == 0) "Find books, movies, music and more." else "No results.");
            },
            .holds => {
                c.adw_status_page_set_icon_name(s, Section.holds.icon());
                c.adw_status_page_set_title(s, "No Holds");
                c.adw_status_page_set_description(s, "Items you place on hold appear here.");
            },
            .checkouts => {
                c.adw_status_page_set_icon_name(s, Section.checkouts.icon());
                c.adw_status_page_set_title(s, "Nothing Checked Out");
                c.adw_status_page_set_description(s, null);
            },
            .history => {
                c.adw_status_page_set_icon_name(s, Section.history.icon());
                c.adw_status_page_set_title(s, "No Borrowing History");
                c.adw_status_page_set_description(s, "If borrowing history is turned on in Account, items you return appear here.");
            },
            else => {
                c.adw_status_page_set_icon_name(s, Section.new_titles.icon());
                c.adw_status_page_set_title(s, "No New Titles");
                c.adw_status_page_set_description(s, null);
            },
        }
        c.gtk_stack_set_visible_child_name(l.stack, "status");
    }

    // MARK: Loading

    pub fn loadIfNeeded(l: *ItemList) void {
        if (!l.loaded and !l.loading) l.reload();
    }

    pub fn reloadIfLoaded(l: *ItemList) void {
        if (l.loaded) l.reload();
    }

    pub fn reload(l: *ItemList) void {
        l.generation +%= 1;
        for (l.pages_memory.items) |arena| core.release(arena);
        l.pages_memory.clearRetainingCapacity();
        l.entries.clearRetainingCapacity();
        c.gtk_list_box_remove_all(l.list_box);
        l.page = 0;
        l.pages = 1;
        l.loaded = false;
        l.loading = false;
        if (l.section == .search and std.mem.trim(u8, l.query, " ").len == 0) return l.showEmpty();
        l.loadPage(1);
    }

    fn loadMore(l: *ItemList) void {
        if (l.loading or !l.loaded or l.page >= l.pages) return;
        l.loadPage(l.page + 1);
    }

    const Ticket = struct { list: *ItemList, generation: u32 };

    fn loadPage(l: *ItemList, page: i64) void {
        l.loading = true;
        c.gtk_widget_set_visible(l.spinner, 1);
        const ticket = core.gpa.create(Ticket) catch return;
        ticket.* = .{ .list = l, .generation = l.generation };
        const w = l.window;
        switch (l.section) {
            .search => w.call(.{ .op = "search", .query = l.query, .page = page, .sort = l.sort, .format = l.format }, &onPage, ticket),
            .new_titles => w.call(.{
                .op = "search",
                .query = "nw:[0 TO 180]",
                .searchType = "bl",
                .filters = .{ .f_on_order = "false" },
                .page = page,
                .sort = l.sort orelse "newly_acquired",
                .format = l.format,
            }, &onPage, ticket),
            .holds => w.call(.{ .op = "holds", .page = page, .sort = l.sort }, &onPage, ticket),
            .checkouts => w.call(.{ .op = "checkouts", .page = page, .sort = l.sort }, &onPage, ticket),
            .history => w.call(.{ .op = "history", .page = page, .sort = l.sort }, &onPage, ticket),
            .account => {},
        }
    }

    fn onPage(data: ?*anyopaque, r: *core.Result) void {
        const ticket: *Ticket = @ptrCast(@alignCast(data.?));
        const l = ticket.list;
        const generation = ticket.generation;
        core.gpa.destroy(ticket);
        if (l.window.finishPending()) return;
        if (generation != l.generation) return;
        l.loading = false;
        c.gtk_widget_set_visible(l.spinner, 0);
        if (!r.ok) {
            l.window.toast(r.message);
            if (!l.loaded) l.showEmpty();
            return;
        }
        l.pages_memory.append(core.gpa, r.keep()) catch {};
        const first = !l.loaded;
        l.loaded = true;
        l.page = core.int(r.value, "page") orelse l.page + 1;
        l.pages = core.int(r.value, "pages") orelse l.page;
        l.count = core.int(r.value, "count") orelse 0;
        for (core.items(core.field(r.value, "entries"))) |entry| {
            l.entries.append(core.gpa, entry) catch continue;
            l.addRow(entry, l.entries.items.len - 1);
        }
        if (first) l.updateControls(r.value);
        l.updateTitle();
        if (l.entries.items.len == 0) l.showEmpty() else c.gtk_stack_set_visible_child_name(l.stack, "list");
        switch (l.section) {
            .holds, .checkouts => l.window.setCount(l.section, l.count),
            else => {},
        }
    }

    fn updateTitle(l: *ItemList) void {
        const subtitle = if (l.count == 1) "1 item" else std.fmt.allocPrint(l.a(), "{d} items", .{l.count}) catch "";
        c.adw_window_title_set_subtitle(l.title, gtk.z(l.a(), subtitle));
    }

    /// Fills the sort menu from the server's options and, for catalog lists, the format menu
    /// from the FORMAT facet.
    fn updateControls(l: *ItemList, page: std.json.Value) void {
        l.updating = true;
        defer l.updating = false;
        const labels = l.window.libraryLabels();

        var sort_ids: std.ArrayList([]const u8) = .empty;
        var sort_names: std.ArrayList(?[*:0]const u8) = .empty;
        var selected: c.guint = 0;
        for (core.items(core.field(page, "sortOptions"))) |s| {
            if (s != .string) continue;
            const name = core.now(l.a(), .{ .op = "sortName", .id = s.string, .labels = labels });
            const text = if (name) |n| if (n == .string) n.string else s.string else s.string;
            if (std.mem.eql(u8, s.string, l.sort orelse core.str(page, "appliedSort") orelse "")) selected = @intCast(sort_ids.items.len);
            sort_ids.append(l.a(), l.a().dupe(u8, s.string) catch continue) catch {};
            sort_names.append(l.a(), gtk.z(l.a(), text)) catch {};
        }
        sort_names.append(l.a(), null) catch {};
        l.sort_ids = sort_ids.items;
        c.gtk_drop_down_set_model(l.sort_dropdown, @ptrCast(@alignCast(c.gtk_string_list_new(@ptrCast(sort_names.items.ptr)))));
        c.gtk_drop_down_set_selected(l.sort_dropdown, selected);
        c.gtk_widget_set_visible(gtk.widget(l.sort_dropdown), @intFromBool(sort_ids.items.len > 1));

        if (l.section != .search and l.section != .new_titles) return;
        var format_ids: std.ArrayList([]const u8) = .empty;
        var format_names: std.ArrayList(?[*:0]const u8) = .empty;
        format_ids.append(l.a(), "") catch {};
        format_names.append(l.a(), "All Formats") catch {};
        var format_selected: c.guint = 0;
        for (core.items(core.field(page, "facets"))) |facet| {
            if (!std.mem.eql(u8, core.str(facet, "id") orelse "", "FORMAT")) continue;
            for (core.items(core.field(facet, "values"))) |v| {
                const code = core.str(v, "value") orelse continue;
                const name = core.now(l.a(), .{ .op = "formatName", .code = code, .labels = labels });
                const text = if (name) |n| if (n == .string) n.string else code else code;
                const label = std.fmt.allocPrint(l.a(), "{s} ({d})", .{ text, core.int(v, "count") orelse 0 }) catch text;
                if (l.format) |f| if (std.mem.eql(u8, f, code)) {
                    format_selected = @intCast(format_ids.items.len);
                };
                format_ids.append(l.a(), l.a().dupe(u8, code) catch continue) catch {};
                format_names.append(l.a(), gtk.z(l.a(), label)) catch {};
            }
        }
        format_names.append(l.a(), null) catch {};
        l.format_ids = format_ids.items;
        c.gtk_drop_down_set_model(l.format_dropdown, @ptrCast(@alignCast(c.gtk_string_list_new(@ptrCast(format_names.items.ptr)))));
        c.gtk_drop_down_set_selected(l.format_dropdown, format_selected);
        c.gtk_widget_set_visible(gtk.widget(l.format_dropdown), @intFromBool(format_ids.items.len > 1));
    }

    // MARK: Rows

    fn addRow(l: *ItemList, entry: std.json.Value, index: usize) void {
        const bib = core.field(entry, "bib");
        const row = gtk.box(false, 12);
        gtk.margins(row, 10);

        const jacket: *c.GtkPicture = @ptrCast(@alignCast(c.gtk_picture_new()));
        c.gtk_picture_set_content_fit(jacket, c.GTK_CONTENT_FIT_CONTAIN);
        c.gtk_widget_set_size_request(gtk.widget(jacket), 48, 72);
        c.gtk_widget_set_valign(gtk.widget(jacket), c.GTK_ALIGN_START);
        c.gtk_widget_add_css_class(gtk.widget(jacket), "jacket");
        gtk.append(row, gtk.widget(jacket));
        if (core.str(bib, "jacketSmall")) |url| loadJacket(l.window, jacket, url);

        const text = gtk.box(true, 2);
        c.gtk_widget_set_hexpand(text, 1);
        gtk.append(text, gtk.label(core.str(bib, "title") orelse "Untitled", l.a(), &.{"heading"}));
        if (core.str(bib, "subtitle")) |s| gtk.append(text, gtk.label(s, l.a(), &.{"dim-label"}));
        const authors = core.items(core.field(bib, "authors"));
        if (authors.len > 0 and authors[0] == .string) gtk.append(text, gtk.label(authors[0].string, l.a(), &.{}));
        gtk.append(text, gtk.label(l.formatLine(bib), l.a(), &.{ "dim-label", "caption" }));
        const status = l.statusLine(entry);
        gtk.append(text, gtk.label(status.text, l.a(), &.{ "caption", status.class }));
        gtk.append(row, text);

        const list_row = c.gtk_list_box_row_new();
        c.gtk_list_box_row_set_child(@ptrCast(@alignCast(list_row)), row);
        c.g_object_set_data(@ptrCast(@alignCast(list_row)), "index", @ptrFromInt(index + 1));
        c.gtk_list_box_append(l.list_box, list_row);
    }

    /// "Blu-ray Disc · 2026"
    fn formatLine(l: *ItemList, bib: ?std.json.Value) []const u8 {
        const code = core.str(bib, "format") orelse "UNKNOWN";
        const name = core.now(l.a(), .{ .op = "formatName", .code = code, .labels = l.window.libraryLabels() });
        const format = if (name) |n| if (n == .string) n.string else code else code;
        const date = core.str(bib, "publicationDate") orelse return format;
        return std.fmt.allocPrint(l.a(), "{s} · {s}", .{ format, year(date) }) catch format;
    }

    const Status = struct { text: []const u8, class: [*:0]const u8 };

    /// The account's relationship to the item if any, else the title's availability.
    fn statusLine(l: *ItemList, entry: std.json.Value) Status {
        const a_ = l.a();
        if (core.field(entry, "accountStatus")) |s| {
            if (std.mem.eql(u8, core.str(s, "kind") orelse "", "checkedOut")) {
                const due = core.str(s, "due") orelse return .{ .text = "Checked out", .class = "copy-held" };
                return .{ .text = std.fmt.allocPrint(a_, "Checked out · due {s}", .{due}) catch "Checked out", .class = "copy-held" };
            }
            if (core.boolean(s, "ready") == true) {
                const hold = core.field(entry, "hold");
                const by = core.str(hold, "pickupByDate");
                const where = core.str(hold, "pickupLocation");
                const text = if (by) |d| std.fmt.allocPrint(a_, "Ready for pickup{s}{s} · by {s}", .{ if (where != null) " at " else "", where orelse "", d }) catch "Ready for pickup" else "Ready for pickup";
                return .{ .text = text, .class = "copy-available" };
            }
            if (core.int(s, "position")) |p| return .{ .text = std.fmt.allocPrint(a_, "On hold · #{d}", .{p}) catch "On hold", .class = "copy-transit" };
            return .{ .text = "On hold", .class = "copy-transit" };
        }
        if (core.field(entry, "history")) |h| {
            if (core.str(h, "returnedDate")) |d| return .{ .text = std.fmt.allocPrint(a_, "Returned {s}", .{d}) catch "", .class = "dim-label" };
            return .{ .text = "", .class = "dim-label" };
        }
        const bib = core.field(entry, "bib");
        const held = core.int(bib, "heldCopies") orelse 0;
        const total = core.int(bib, "totalCopies") orelse 0;
        const status = core.str(bib, "status") orelse "";
        const label: Status = if (std.mem.eql(u8, status, "AVAILABLE"))
            .{ .text = "Available", .class = "copy-available" }
        else if (std.mem.eql(u8, status, "ON_ORDER"))
            .{ .text = "On order", .class = "copy-onOrder" }
        else if (std.mem.eql(u8, status, "UNAVAILABLE") or std.mem.eql(u8, status, "NOT_AVAILABLE"))
            .{ .text = "All copies in use", .class = "copy-out" }
        else
            .{ .text = "", .class = "dim-label" };
        if (total == 0) return label;
        const counts = std.fmt.allocPrint(a_, "{s}{s}{d} holds on {d} copies", .{ label.text, if (label.text.len > 0) " · " else "", held, total }) catch label.text;
        return .{ .text = counts, .class = label.class };
    }

    // MARK: Events

    fn onRow(_: *c.GtkListBox, row: *c.GtkListBoxRow, data: ?*anyopaque) callconv(.c) void {
        const l: *ItemList = @ptrCast(@alignCast(data.?));
        const i = @intFromPtr(c.g_object_get_data(@ptrCast(@alignCast(row)), "index"));
        if (i == 0 or i > l.entries.items.len) return;
        l.window.select(l.entries.items[i - 1]);
    }

    fn onEdge(_: *c.GtkScrolledWindow, pos: c.GtkPositionType, data: ?*anyopaque) callconv(.c) void {
        const l: *ItemList = @ptrCast(@alignCast(data.?));
        if (pos == c.GTK_POS_BOTTOM) l.loadMore();
    }

    fn onSearch(entry: *c.GtkSearchEntry, data: ?*anyopaque) callconv(.c) void {
        const l: *ItemList = @ptrCast(@alignCast(data.?));
        l.query = l.a().dupe(u8, std.mem.span(c.gtk_editable_get_text(@ptrCast(@alignCast(entry))))) catch return;
        l.format = null;
        l.sort = null;
        l.reload();
    }

    /// Searches for `text` (e.g. an author from the details pane).
    pub fn searchFor(l: *ItemList, text: []const u8) void {
        if (l.search) |s| c.gtk_editable_set_text(@ptrCast(@alignCast(s)), gtk.z(l.a(), text));
        l.query = l.a().dupe(u8, text) catch return;
        l.reload();
    }

    fn onSort(dropdown: *c.GtkDropDown, _: ?*c.GParamSpec, data: ?*anyopaque) callconv(.c) void {
        const l: *ItemList = @ptrCast(@alignCast(data.?));
        if (l.updating) return;
        const i = c.gtk_drop_down_get_selected(dropdown);
        if (i >= l.sort_ids.len) return;
        l.sort = l.sort_ids[i];
        l.reload();
    }

    fn onFormat(dropdown: *c.GtkDropDown, _: ?*c.GParamSpec, data: ?*anyopaque) callconv(.c) void {
        const l: *ItemList = @ptrCast(@alignCast(data.?));
        if (l.updating) return;
        const i = c.gtk_drop_down_get_selected(dropdown);
        if (i >= l.format_ids.len) return;
        l.format = if (i == 0) null else l.format_ids[i];
        l.reload();
    }
};

/// A year from "2026", "20261006" or "03/23/2027"; otherwise the date as given.
pub fn year(date: []const u8) []const u8 {
    if (date.len == 4) return date;
    if (date.len == 8 and std.mem.indexOfNone(u8, date, "0123456789") == null) return date[0..4];
    var i: usize = 0;
    while (i + 4 <= date.len) : (i += 1) {
        const y = date[i .. i + 4];
        if (std.mem.indexOfNone(u8, y, "0123456789") != null) continue;
        if ((i > 0 and std.ascii.isDigit(date[i - 1])) or (i + 4 < date.len and std.ascii.isDigit(date[i + 4]))) continue;
        if (y[0] == '1' or (y[0] == '2' and y[1] == '0')) return y;
    }
    return date;
}

const JacketJob = struct { window: *Window, picture: *c.GtkPicture };

/// Loads jacket art through the core (paced like other library requests) into `picture`.
pub fn loadJacket(w: *Window, picture: *c.GtkPicture, url: []const u8) void {
    const job = core.gpa.create(JacketJob) catch return;
    job.* = .{ .window = w, .picture = picture };
    _ = c.g_object_ref(picture);
    w.call(.{ .op = "fetchImage", .url = url }, &onJacket, job);
}

fn onJacket(data: ?*anyopaque, r: *core.Result) void {
    const job: *JacketJob = @ptrCast(@alignCast(data.?));
    const picture = job.picture;
    const w = job.window;
    core.gpa.destroy(job);
    defer c.g_object_unref(picture);
    if (w.finishPending()) return;
    if (!r.ok or r.value != .string) return;
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(r.value.string) catch return;
    const bytes = r.arena.allocator().alloc(u8, size) catch return;
    decoder.decode(bytes, r.value.string) catch return;
    const texture = gtk.texture(bytes) orelse return;
    defer c.g_object_unref(texture);
    c.gtk_picture_set_paintable(picture, @ptrCast(@alignCast(texture)));
}

test year {
    try std.testing.expectEqualStrings("2026", year("20261006"));
    try std.testing.expectEqualStrings("2027", year("03/23/2027"));
    try std.testing.expectEqualStrings("1999", year("c1999"));
    try std.testing.expectEqualStrings("Spring", year("Spring"));
}
