//! A paged, infinitely scrolling list of catalog search results, new titles, holds,
//! checkouts or borrowing history, with sorting and filtering.
//!
//! Paging, sorting and filtering are libbiblio's item list (`biblio_list_*`), shared with the
//! other apps: it says which pages to fetch and which rows to show, and this file fetches those
//! pages and keeps their entries. Rows that aren't fetched yet are placeholders, so the scroll
//! bar has its final length once the first page reports the total.

const std = @import("std");
const biblio = @import("biblio");
const gtk = @import("gtk.zig");
const c = gtk.c;
const core = @import("core.zig");
const capi = core.capi;
const borrowed = @import("borrowed.zig");
const win = @import("window.zig");
const Window = win.Window;
const Section = win.Section;

/// How long placeholders must stay on screen before their page is fetched, so dragging the
/// scroll bar across a long list doesn't request every page it passes.
const placeholder_dwell_ms = 300;

/// Marks the sort menu's client-side entries (the server's own are its sort ids).
const sort_people = "~people";
const sort_title = "~title";

var scratch: [8192]u8 = undefined;

fn now() i64 {
    return @divTrunc(c.g_get_monotonic_time(), 1000);
}

pub const ItemList = struct {
    window: *Window,
    section: Section,
    root: *c.GtkWidget,
    stack: *c.GtkStack,
    view: *c.GtkListView,
    model: *c.GtkStringList,
    status: *c.AdwStatusPage,
    title: *c.AdwWindowTitle,
    search: ?*c.GtkSearchEntry = null,
    sort_dropdown: *c.GtkDropDown,
    format_dropdown: *c.GtkDropDown,
    spinner: *c.GtkWidget,
    hold_filters: [3]?*c.GtkWidget = @splat(null),
    /// The "Not Borrowed" toggle, for catalog lists and holds of signed-in windows.
    not_borrowed: ?*c.GtkWidget = null,
    /// Bound item rows, whose borrowed-before marks follow the index.
    bound: std.AutoHashMapUnmanaged(*c.GtkWidget, void) = .empty,
    borrowed_generation: u64 = 0,
    arena: std.heap.ArenaAllocator,
    sort_arena: std.heap.ArenaAllocator,
    format_arena: std.heap.ArenaAllocator,
    list: *biblio.item_list.List,
    /// Each page's result; released on reload (or when a refresh's first page replaces them).
    pages: std.ArrayList(*capi.ListPage) = .empty,
    /// Fetched entries by id, pointing into `pages`.
    by_id: std.StringHashMapUnmanaged(*const capi.ListEntry) = .empty,
    /// What the model holds: "i<position> <id>" for a fetched item, "p<position>" for a placeholder.
    shown: std.ArrayList([:0]u8) = .empty,
    query: []const u8 = "",
    /// The server sort chosen, if any; client sorts live in the core list.
    sort: ?[]const u8 = null,
    /// The client-side sort chosen (`sort_people` or `sort_title`), which the core list applies.
    client_sort: ?[]const u8 = null,
    sort_ids: []const []const u8 = &.{},
    format_ids: []const []const u8 = &.{},
    format_counts: []const i64 = &.{},
    /// The format filter: a facet for searches, applied locally for account lists.
    format: ?[]const u8 = null,
    background: bool = false,
    dwell: c.guint = 0,
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
        c.gtk_widget_set_visible(gtk.widget(sort_dropdown), 0);
        const refresh_button = c.gtk_button_new_from_icon_name("view-refresh-symbolic");
        c.gtk_widget_set_tooltip_text(refresh_button, "Refresh");
        const spinner = c.adw_spinner_new();
        c.gtk_widget_set_visible(spinner, 0);
        c.adw_header_bar_pack_end(@ptrCast(@alignCast(header)), refresh_button);
        c.adw_header_bar_pack_end(@ptrCast(@alignCast(header)), gtk.widget(sort_dropdown));
        c.adw_header_bar_pack_end(@ptrCast(@alignCast(header)), gtk.widget(format_dropdown));
        c.adw_header_bar_pack_start(@ptrCast(@alignCast(header)), spinner);
        c.adw_toolbar_view_add_top_bar(@ptrCast(@alignCast(toolbar)), header);

        const model = c.gtk_string_list_new(null);
        const selection = c.gtk_single_selection_new(@ptrCast(@alignCast(c.g_object_ref(model))));
        c.gtk_single_selection_set_autoselect(selection, 0);
        c.gtk_single_selection_set_can_unselect(selection, 1);
        const factory = c.gtk_signal_list_item_factory_new();
        const view: *c.GtkListView = @ptrCast(@alignCast(c.gtk_list_view_new(@ptrCast(@alignCast(selection)), @ptrCast(@alignCast(factory)))));
        c.gtk_list_view_set_single_click_activate(view, 1);
        c.gtk_widget_add_css_class(gtk.widget(view), "boxed-list");

        l.* = .{
            .window = w,
            .section = section,
            .root = toolbar,
            .stack = @ptrCast(@alignCast(c.gtk_stack_new())),
            .view = view,
            .model = @ptrCast(@alignCast(model)),
            .status = @ptrCast(@alignCast(c.adw_status_page_new())),
            .title = title,
            .sort_dropdown = sort_dropdown,
            .format_dropdown = format_dropdown,
            .spinner = spinner,
            .arena = .init(core.gpa),
            .sort_arena = .init(core.gpa),
            .format_arena = .init(core.gpa),
            .list = capi.biblio_list_new(if (section == .holds) .holds else if (section == .checkouts) .checkouts else if (section == .history) .history else .search).?,
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
        // "Not Borrowed", offered once the borrowing history is fully read.
        if (!w.isGuest() and (section == .search or section == .new_titles or section == .holds)) {
            const toggle = c.gtk_toggle_button_new_with_label("Not Borrowed");
            c.gtk_widget_set_tooltip_text(toggle, "Hide items you borrowed before in the same format");
            c.gtk_widget_set_visible(toggle, 0);
            gtk.connect(toggle, "toggled", &onNotBorrowed, l);
            if (section != .holds) c.adw_header_bar_pack_end(@ptrCast(@alignCast(header)), toggle);
            l.not_borrowed = toggle;
        }
        if (section == .holds) {
            // "Ready", "Not Ready" and "On Order", each with a count; at most one is on.
            const bar = gtk.box(false, 0);
            c.gtk_widget_add_css_class(bar, "linked");
            for (&l.hold_filters, 0..) |*slot, i| {
                const button = c.gtk_toggle_button_new_with_label("");
                c.g_object_set_data(@ptrCast(@alignCast(button)), "filter", @ptrFromInt(i + 1));
                gtk.connect(button, "toggled", &onHoldFilter, l);
                gtk.append(bar, button);
                slot.* = button;
            }
            const filters = gtk.box(false, 12);
            c.gtk_widget_set_halign(filters, c.GTK_ALIGN_CENTER);
            gtk.margins(filters, 6);
            gtk.append(filters, bar);
            if (l.not_borrowed) |toggle| gtk.append(filters, toggle);
            c.adw_toolbar_view_add_top_bar(@ptrCast(@alignCast(toolbar)), filters);
        }

        gtk.connect(factory, "setup", &onSetup, l);
        gtk.connect(factory, "bind", &onBind, l);
        gtk.connect(factory, "unbind", &onUnbind, l);
        gtk.connect(view, "activate", &onActivate, l);
        gtk.connect(refresh_button, "clicked", &onRefresh, l);
        const scroll = c.gtk_scrolled_window_new();
        c.gtk_scrolled_window_set_child(@ptrCast(@alignCast(scroll)), gtk.widget(view));
        c.gtk_scrolled_window_set_policy(@ptrCast(@alignCast(scroll)), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
        // The clamp goes around the scrolled window: a list view only recycles rows if it scrolls itself.
        const clamp = c.adw_clamp_new();
        c.adw_clamp_set_maximum_size(@ptrCast(@alignCast(clamp)), 900);
        c.adw_clamp_set_child(@ptrCast(@alignCast(clamp)), scroll);
        gtk.margins(clamp, 12);
        _ = c.gtk_stack_add_named(l.stack, clamp, "list");
        _ = c.gtk_stack_add_named(l.stack, gtk.widget(l.status), "status");
        c.adw_toolbar_view_set_content(@ptrCast(@alignCast(toolbar)), gtk.widget(l.stack));

        gtk.connect(sort_dropdown, "notify::selected", &onSort, l);
        gtk.connect(format_dropdown, "notify::selected", &onFormat, l);
        l.showEmpty();
        return l;
    }

    pub fn free(l: *ItemList) void {
        if (l.dwell != 0) _ = c.g_source_remove(l.dwell);
        capi.biblio_list_free(l.list);
        l.releasePages();
        l.pages.deinit(core.gpa);
        l.by_id.deinit(core.gpa);
        l.bound.deinit(core.gpa);
        for (l.shown.items) |k| core.gpa.free(k);
        l.shown.deinit(core.gpa);
        l.arena.deinit();
        l.sort_arena.deinit();
        l.format_arena.deinit();
        core.gpa.destroy(l);
    }

    fn a(l: *ItemList) std.mem.Allocator {
        return l.arena.allocator();
    }

    fn releasePages(l: *ItemList) void {
        l.by_id.clearRetainingCapacity();
        for (l.pages.items) |page| core.release(page);
        l.pages.clearRetainingCapacity();
    }

    fn showEmpty(l: *ItemList) void {
        const s = l.status;
        switch (l.section) {
            .search => {
                c.adw_status_page_set_icon_name(s, "system-search-symbolic");
                const t = std.fmt.allocPrint(l.a(), "Search {s}", .{@import("store.zig").shortName(l.window.library)}) catch "Search";
                c.adw_status_page_set_title(s, gtk.z(l.a(), t));
                c.adw_status_page_set_description(s, if (std.mem.trim(u8, l.query, " ").len == 0) "Find books, movies, music, and more." else "No results.");
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

    /// Loads a list that hasn't been fetched yet, or refetches one older than 15 minutes.
    pub fn loadIfNeeded(l: *ItemList) void {
        const state = capi.biblio_list_state(l.list);
        if (state.loading) return;
        if (!state.loaded) {
            l.reloadWith(false);
        } else if (capi.biblio_list_is_stale(l.list, now())) {
            l.reloadWith(true);
        }
    }

    pub fn reloadIfLoaded(l: *ItemList) void {
        if (capi.biblio_list_state(l.list).loaded) l.reloadWith(true);
    }

    /// Starts again from the first page, keeping the rows (dimmed) until it arrives.
    pub fn reload(l: *ItemList) void {
        l.reloadWith(true);
    }

    /// Starts again from page 1. `keep` leaves the current rows, stale, until the first page
    /// replaces them all at once.
    fn reloadWith(l: *ItemList, keep: bool) void {
        l.background = false;
        if (l.dwell != 0) {
            _ = c.g_source_remove(l.dwell);
            l.dwell = 0;
        }
        if (l.section == .search and std.mem.trim(u8, l.query, " ").len == 0) {
            capi.biblio_list_clear(l.list);
            l.releasePages();
            return l.sync();
        }
        if (!keep) l.releasePages();
        const generation = capi.biblio_list_reload(l.list, keep);
        l.sync();
        l.fetchPage(1, generation, false);
    }

    /// Refresh button: account lists start a fresh session first (the gateway can keep serving
    /// one session a wrong list), then everything reloads with the old rows dimmed.
    fn refresh(l: *ItemList) void {
        if (l.section == .search or l.section == .new_titles) return l.reloadWith(true);
        capi.biblio_list_begin_refresh(l.list);
        l.sync();
        const w = l.window;
        const j = w.job(&onRefreshed, l) orelse return l.reloadWith(true);
        j.start(capi.biblio_login, .{ w.client, true });
    }

    fn onRefreshed(data: ?*anyopaque, _: *core.Result) void {
        const l: *ItemList = @ptrCast(@alignCast(data.?));
        if (l.window.finishPending()) return;
        l.reloadWith(true);
        // Returns since the last sync join the borrowed-before index.
        if (l.window.borrowed) |b| b.sync();
    }

    const Ticket = struct { list: *ItemList, generation: u64, page: i64, background: bool };

    const new_titles_filters = [_]capi.Pair{.{ .key = "f_on_order", .value = "false" }};

    /// Fetches a page the core list asked for (it is in flight there).
    fn fetchPage(l: *ItemList, page: i64, generation: u64, background: bool) void {
        if (l.section == .account) return;
        const ticket = core.gpa.create(Ticket) catch return;
        ticket.* = .{ .list = l, .generation = generation, .page = page, .background = background };
        const w = l.window;
        const j = w.job(&onPage, ticket) orelse return core.gpa.destroy(ticket);
        const default_sort: ?[]const u8 = if (l.section == .new_titles) "newly_acquired" else null;
        const sort = l.sort orelse default_sort;
        switch (l.section) {
            .search => j.start(capi.biblio_search, .{ w.client, j.new(capi.SearchQuery{
                .query = j.z(l.query),
                .page = page,
                .sort = j.optZ(sort),
                .format = j.optZ(l.format),
            }) }),
            .new_titles => j.start(capi.biblio_search, .{ w.client, j.new(capi.SearchQuery{
                .query = "nw:[0 TO 180]",
                .search_type = "bl",
                .filters = &new_titles_filters,
                .filter_count = new_titles_filters.len,
                .page = page,
                .sort = j.optZ(sort),
                .format = j.optZ(l.format),
            }) }),
            .holds => j.start(capi.biblio_holds, .{ w.client, page, j.optZ(sort) }),
            .checkouts => j.start(capi.biblio_checkouts, .{ w.client, page, j.optZ(sort) }),
            .history => j.start(capi.biblio_history, .{ w.client, page, j.optZ(sort) }),
            .account => unreachable,
        }
    }

    fn onPage(data: ?*anyopaque, r: *core.Result) void {
        const ticket: *Ticket = @ptrCast(@alignCast(data.?));
        const l = ticket.list;
        const t = ticket.*;
        core.gpa.destroy(ticket);
        if (l.window.finishPending()) return;
        const before = capi.biblio_list_state(l.list);
        if (t.generation != before.generation) return;
        if (!r.ok) {
            _ = capi.biblio_list_fail(l.list, t.generation, t.page);
            if (t.background) {
                capi.biblio_list_end_background(l.list);
                l.background = false;
            }
            l.window.toast(r.message);
            return l.sync();
        }
        const result = r.keep(capi.ListPage) orelse return;
        // The first page of a refresh replaces the stale entries.
        if (t.page == 1 and before.refreshing) l.releasePages();
        l.pages.append(core.gpa, result) catch {
            core.release(result);
            _ = capi.biblio_list_fail(l.list, t.generation, t.page);
            return;
        };
        // An item that moved between pages while fetching keeps its first position.
        for (core.items(capi.ListEntry, result.entries, result.entries_count)) |*entry| {
            const gop = l.by_id.getOrPut(core.gpa, std.mem.span(entry.id)) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = entry;
        }
        _ = capi.biblio_list_apply_page(l.list, t.generation, t.page, result, now());
        if (result.sort_options_count > 0 and (t.page == 1 or l.sort_ids.len == 0)) l.updateSortMenu(result);
        if (l.section == .search or l.section == .new_titles) {
            if (result.facets_count > 0 and (t.page == 1 or l.format_ids.len <= 1)) l.updateFormatMenu(result);
        }
        l.sync();
        if (t.page == 1 and capi.biblio_list_wants_all_pages(l.list)) l.startBackground();
        if (t.background) l.nextBackground();
    }

    /// Fetches the remaining pages, one at a time, for client sorts, local filters, and the
    /// holds list (whose filter counts need every hold).
    fn startBackground(l: *ItemList) void {
        if (!capi.biblio_list_begin_background(l.list)) return;
        l.background = true;
        l.nextBackground();
    }

    fn nextBackground(l: *ItemList) void {
        const page = capi.biblio_list_next_background_page(l.list);
        if (page <= 0) {
            l.background = false;
            return l.sync();
        }
        l.fetchPage(page, capi.biblio_list_state(l.list).generation, true);
    }

    // MARK: Showing the core list

    /// Brings the model, controls, and badges up to date with the core list after any change.
    fn sync(l: *ItemList) void {
        const state = capi.biblio_list_state(l.list);
        var n: usize = 0;
        const rows = capi.biblio_list_rows(l.list, &n);
        var keys: std.ArrayList([:0]u8) = .empty;
        defer keys.deinit(core.gpa);
        for (rows[0..n]) |row| {
            const key = if (row.id) |id| blk: {
                const s = std.mem.span(id);
                if (!l.by_id.contains(s)) continue;
                break :blk std.fmt.allocPrintSentinel(core.gpa, "i{d} {s}", .{ row.position, s }, 0) catch continue;
            } else std.fmt.allocPrintSentinel(core.gpa, "p{d}", .{row.position}, 0) catch continue;
            keys.append(core.gpa, key) catch core.gpa.free(key);
        }

        // Replace only the rows that changed, so the scroll position holds.
        const old = l.shown.items;
        var prefix: usize = 0;
        while (prefix < old.len and prefix < keys.items.len and std.mem.eql(u8, old[prefix], keys.items[prefix])) prefix += 1;
        var suffix: usize = 0;
        while (suffix < old.len - prefix and suffix < keys.items.len - prefix and
            std.mem.eql(u8, old[old.len - 1 - suffix], keys.items[keys.items.len - 1 - suffix])) suffix += 1;
        const removals = old.len - prefix - suffix;
        const added = keys.items[prefix .. keys.items.len - suffix];
        if (removals > 0 or added.len > 0) {
            const additions = core.gpa.alloc(?[*:0]const u8, added.len + 1) catch null;
            defer if (additions) |buf| core.gpa.free(buf);
            if (additions) |buf| {
                for (added, 0..) |k, i| buf[i] = k.ptr;
                buf[added.len] = null;
                c.gtk_string_list_splice(l.model, @intCast(prefix), @intCast(removals), @ptrCast(buf.ptr));
            }
        }
        for (l.shown.items) |k| core.gpa.free(k);
        l.shown.deinit(core.gpa);
        l.shown = keys;
        keys = .empty;

        const blank = l.section == .search and std.mem.trim(u8, l.query, " ").len == 0;
        if (l.shown.items.len == 0 and !state.loading and !state.refreshing and (state.loaded or blank or !state.has_more)) {
            l.showEmpty();
        } else {
            c.gtk_stack_set_visible_child_name(l.stack, "list");
        }
        c.gtk_widget_set_visible(l.spinner, @intFromBool(state.loading or l.background));
        c.gtk_widget_set_opacity(gtk.widget(l.view), if (state.refreshing) 0.5 else 1.0);
        if (state.loaded) switch (l.section) {
            .holds, .checkouts => l.window.setCount(l.section, state.total),
            else => {},
        };
        if (l.section == .holds or l.section == .checkouts) if (l.window.borrowed) |b| b.badgesLoaded();
        if (l.section == .holds) l.updateHoldFilters();
        if (l.section != .search and l.section != .new_titles) l.updateLocalFormats();
    }

    fn updateHoldFilters(l: *ItemList) void {
        const names = [_][]const u8{ "Ready", "Not Ready", "On Order" };
        const filters = [_]biblio.item_list.HoldFilter{ .ready, .not_ready, .on_order };
        var fba = std.heap.FixedBufferAllocator.init(&scratch);
        for (l.hold_filters, names, filters) |button, name, filter| {
            const text = std.fmt.allocPrint(fba.allocator(), "{s} {d}", .{ name, capi.biblio_list_hold_count(l.list, filter) }) catch name;
            c.gtk_button_set_label(@ptrCast(@alignCast(button.?)), gtk.z(fba.allocator(), text));
        }
    }

    /// The sort menu: the server's options, then the client sorts the site doesn't offer.
    fn updateSortMenu(l: *ItemList, page: *const capi.ListPage) void {
        l.updating = true;
        defer l.updating = false;
        _ = l.sort_arena.reset(.retain_capacity);
        const sa = l.sort_arena.allocator();
        var ids: std.ArrayList([]const u8) = .empty;
        var names: std.ArrayList(?[*:0]const u8) = .empty;
        const chosen = l.client_sort orelse l.sort orelse core.str(page.applied_sort) orelse "";
        var selected: c.guint = 0;
        var has_title = false;
        for (core.items([*:0]const u8, page.sort_options, page.sort_options_count)) |option| {
            const s = std.mem.span(option);
            if (std.mem.eql(u8, s, "title")) has_title = true;
            if (std.mem.eql(u8, s, chosen)) selected = @intCast(ids.items.len);
            ids.append(sa, sa.dupe(u8, s) catch continue) catch {};
            names.append(sa, gtk.z(sa, core.sortName(sa, s, l.window.labels))) catch {};
        }
        if (std.mem.eql(u8, chosen, sort_people)) selected = @intCast(ids.items.len);
        ids.append(sa, sort_people) catch {};
        names.append(sa, "People Waiting") catch {};
        if (!has_title) {
            if (std.mem.eql(u8, chosen, sort_title)) selected = @intCast(ids.items.len);
            ids.append(sa, sort_title) catch {};
            names.append(sa, "Title") catch {};
        }
        names.append(sa, null) catch {};
        l.sort_ids = ids.items;
        const model = c.gtk_string_list_new(@ptrCast(names.items.ptr));
        c.gtk_drop_down_set_model(l.sort_dropdown, @ptrCast(@alignCast(model)));
        c.g_object_unref(model);
        c.gtk_drop_down_set_selected(l.sort_dropdown, selected);
        c.gtk_widget_set_visible(gtk.widget(l.sort_dropdown), 1);
    }

    /// Format choices for catalog lists, from the FORMAT facet.
    fn updateFormatMenu(l: *ItemList, page: *const capi.ListPage) void {
        var choices: std.ArrayList(Choice) = .empty;
        defer choices.deinit(core.gpa);
        for (core.items(capi.Facet, page.facets, page.facets_count)) |facet| {
            if (!std.mem.eql(u8, std.mem.span(facet.id), "FORMAT")) continue;
            for (core.items(capi.FacetValue, facet.values, facet.values_count)) |v| {
                choices.append(core.gpa, .{ .id = std.mem.span(v.value), .count = v.count }) catch {};
            }
        }
        l.setFormatMenu(choices.items);
    }

    /// Format choices for account lists: the formats of the rows loaded so far.
    fn updateLocalFormats(l: *ItemList) void {
        var n: usize = 0;
        const formats = capi.biblio_list_formats(l.list, &n);
        var choices: std.ArrayList(Choice) = .empty;
        defer choices.deinit(core.gpa);
        for (formats[0..n]) |f| choices.append(core.gpa, .{ .id = std.mem.span(f.format), .count = f.count }) catch {};
        l.setFormatMenu(choices.items);
    }

    const Choice = struct { id: []const u8, count: i64 };

    fn setFormatMenu(l: *ItemList, choices: []const Choice) void {
        // Unchanged choices leave the menu (and its open popover) alone.
        if (l.format_ids.len == choices.len + 1) {
            var same = true;
            for (choices, l.format_ids[1..]) |ch, id| same = same and std.mem.eql(u8, ch.id, id);
            if (same and !l.formatCountsChanged(choices)) return;
        }
        l.updating = true;
        defer l.updating = false;
        _ = l.format_arena.reset(.retain_capacity);
        const fa = l.format_arena.allocator();
        var ids: std.ArrayList([]const u8) = .empty;
        var names: std.ArrayList(?[*:0]const u8) = .empty;
        ids.append(fa, "") catch {};
        names.append(fa, "All Formats") catch {};
        var selected: c.guint = 0;
        for (choices) |ch| {
            if (l.format) |f| if (std.mem.eql(u8, f, ch.id)) {
                selected = @intCast(ids.items.len);
            };
            const text = core.formatName(fa, ch.id, l.window.labels);
            ids.append(fa, fa.dupe(u8, ch.id) catch continue) catch {};
            // A refined format's count is unknown (-1) until its pages are fetched.
            const name = if (ch.count < 0) text else std.fmt.allocPrint(fa, "{s} ({d})", .{ text, ch.count }) catch text;
            names.append(fa, gtk.z(fa, name)) catch {};
        }
        names.append(fa, null) catch {};
        l.format_ids = ids.items;
        l.format_counts = fa.dupe(i64, blk: {
            var counts: std.ArrayList(i64) = .empty;
            for (choices) |ch| counts.append(fa, ch.count) catch {};
            break :blk counts.items;
        }) catch &.{};
        const model = c.gtk_string_list_new(@ptrCast(names.items.ptr));
        c.gtk_drop_down_set_model(l.format_dropdown, @ptrCast(@alignCast(model)));
        c.g_object_unref(model);
        c.gtk_drop_down_set_selected(l.format_dropdown, selected);
        c.gtk_widget_set_visible(gtk.widget(l.format_dropdown), @intFromBool(ids.items.len > 1 or l.format != null));
    }

    fn formatCountsChanged(l: *ItemList, choices: []const Choice) bool {
        if (l.format_counts.len != choices.len) return true;
        for (choices, l.format_counts) |ch, n| if (ch.count != n) return true;
        return false;
    }

    // MARK: Rows

    /// One row's widgets, reached through the row's object data.
    const Cells = struct {
        jacket: *c.GtkPicture,
        title: *c.GtkLabel,
        subtitle: *c.GtkLabel,
        author: *c.GtkLabel,
        format: *c.GtkLabel,
        /// "Borrowed before", after the format line.
        mark: *c.GtkWidget,
        status: *c.GtkLabel,
    };

    fn cell(comptime name: [:0]const u8, parent: *c.GtkWidget, text_box: *c.GtkWidget, classes: []const [*:0]const u8) *c.GtkLabel {
        const label = gtk.label("", std.heap.c_allocator, classes);
        gtk.append(text_box, label);
        c.g_object_set_data(@ptrCast(@alignCast(parent)), name, label);
        return @ptrCast(@alignCast(label));
    }

    fn onSetup(_: *c.GtkListItemFactory, item: *c.GtkListItem, _: ?*anyopaque) callconv(.c) void {
        const row = gtk.box(false, 12);
        gtk.margins(row, 10);
        c.gtk_widget_set_size_request(row, -1, 96);
        const jacket: *c.GtkPicture = @ptrCast(@alignCast(c.gtk_picture_new()));
        c.gtk_picture_set_content_fit(jacket, c.GTK_CONTENT_FIT_CONTAIN);
        c.gtk_widget_set_size_request(gtk.widget(jacket), 48, 72);
        c.gtk_widget_set_valign(gtk.widget(jacket), c.GTK_ALIGN_START);
        c.gtk_widget_add_css_class(gtk.widget(jacket), "jacket");
        gtk.append(row, gtk.widget(jacket));
        c.g_object_set_data(@ptrCast(@alignCast(row)), "jacket", jacket);
        const text = gtk.box(true, 2);
        c.gtk_widget_set_hexpand(text, 1);
        gtk.append(row, text);
        _ = cell("title", row, text, &.{"heading"});
        _ = cell("subtitle", row, text, &.{"dim-label"});
        _ = cell("author", row, text, &.{});
        const details = gtk.box(false, 6);
        gtk.append(text, details);
        _ = cell("format", row, details, &.{ "dim-label", "caption" });
        const mark = c.gtk_image_new_from_icon_name("document-open-recent-symbolic");
        c.gtk_image_set_pixel_size(@ptrCast(@alignCast(mark)), 12);
        c.gtk_widget_add_css_class(mark, "dim-label");
        c.gtk_widget_set_visible(mark, 0);
        gtk.append(details, mark);
        c.g_object_set_data(@ptrCast(@alignCast(row)), "mark", mark);
        _ = cell("status", row, text, &.{"caption"});
        c.gtk_list_item_set_child(item, row);
    }

    fn cells(row: *c.GtkWidget) Cells {
        const get = struct {
            fn f(w: *c.GtkWidget, name: [*:0]const u8) *anyopaque {
                return c.g_object_get_data(@ptrCast(@alignCast(w)), name).?;
            }
        }.f;
        return .{
            .jacket = @ptrCast(@alignCast(get(row, "jacket"))),
            .title = @ptrCast(@alignCast(get(row, "title"))),
            .subtitle = @ptrCast(@alignCast(get(row, "subtitle"))),
            .author = @ptrCast(@alignCast(get(row, "author"))),
            .format = @ptrCast(@alignCast(get(row, "format"))),
            .mark = @ptrCast(@alignCast(get(row, "mark"))),
            .status = @ptrCast(@alignCast(get(row, "status"))),
        };
    }

    fn setText(label: *c.GtkLabel, a_: std.mem.Allocator, text: []const u8) void {
        c.gtk_label_set_text(label, gtk.z(a_, text));
        c.gtk_widget_set_visible(gtk.widget(label), @intFromBool(text.len > 0));
    }

    const status_classes = [_][*:0]const u8{ "copy-available", "copy-onOrder", "copy-out", "copy-held", "copy-transit", "dim-label" };

    fn onBind(_: *c.GtkListItemFactory, item: *c.GtkListItem, data: ?*anyopaque) callconv(.c) void {
        const l: *ItemList = @ptrCast(@alignCast(data.?));
        const key = std.mem.span(c.gtk_string_object_get_string(@ptrCast(@alignCast(c.gtk_list_item_get_item(item)))));
        const row = gtk.as(c.GtkWidget, c.gtk_list_item_get_child(item));
        const cl = cells(row);
        var fba = std.heap.FixedBufferAllocator.init(&scratch);
        const sa = fba.allocator();
        const refreshing = capi.biblio_list_state(l.list).refreshing;
        c.gtk_picture_set_paintable(cl.jacket, null);
        for (status_classes) |cls| c.gtk_widget_remove_css_class(gtk.widget(cl.status), cls);
        c.g_object_set_data(@ptrCast(@alignCast(row)), "placeholder", null);
        c.g_object_set_data(@ptrCast(@alignCast(row)), "entry", null);
        c.gtk_widget_set_visible(cl.mark, 0);
        if (key.len > 0 and key[0] == 'p') {
            const position = std.fmt.parseInt(i64, key[1..], 10) catch 0;
            for ([_]*c.GtkLabel{ cl.title, cl.subtitle, cl.author, cl.format, cl.status }) |label| setText(label, sa, "");
            c.g_object_set_data(@ptrCast(@alignCast(row)), "placeholder", @ptrFromInt(@as(usize, @intCast(position)) + 1));
            if (!refreshing) {
                capi.biblio_list_placeholder_appeared(l.list, position);
                l.scheduleDwell();
            }
            return;
        }
        const space = std.mem.indexOfScalar(u8, key, ' ') orelse return;
        const position = std.fmt.parseInt(i64, key[1..space], 10) catch 0;
        const entry = (l.by_id.get(key[space + 1 ..]) orelse return).*;
        const bib = entry.bib;
        setText(cl.title, sa, bibTitle(bib));
        setText(cl.subtitle, sa, core.str(bib.subtitle) orelse "");
        const authors = core.items([*:0]const u8, bib.authors, bib.authors_count);
        setText(cl.author, sa, if (authors.len > 0) std.mem.span(authors[0]) else "");
        setText(cl.format, sa, formatLine(sa, l.window.labels, bib));
        const status = statusLine(sa, entry);
        setText(cl.status, sa, status.text);
        c.gtk_widget_add_css_class(gtk.widget(cl.status), status.class);
        if (core.str(bib.jacket_small)) |url| loadJacket(l.window, cl.jacket, url);
        if (l.not_borrowed != null) {
            c.g_object_set_data_full(@ptrCast(@alignCast(row)), "entry", c.g_strdup(entry.id), c.g_free);
            l.bound.put(core.gpa, row, {}) catch {};
            l.markRow(row);
        }
        if (!refreshing) {
            // Nearing the placeholders after this item: prefetch their page.
            const page = capi.biblio_list_item_appeared(l.list, position);
            if (page > 0) l.fetchPage(page, capi.biblio_list_state(l.list).generation, false);
        }
    }

    fn onUnbind(_: *c.GtkListItemFactory, item: *c.GtkListItem, data: ?*anyopaque) callconv(.c) void {
        const l: *ItemList = @ptrCast(@alignCast(data.?));
        const row = gtk.as(c.GtkWidget, c.gtk_list_item_get_child(item));
        const marked = @intFromPtr(c.g_object_get_data(@ptrCast(@alignCast(row)), "placeholder"));
        if (marked != 0) capi.biblio_list_placeholder_disappeared(l.list, @intCast(marked - 1));
        c.g_object_set_data(@ptrCast(@alignCast(row)), "placeholder", null);
        c.g_object_set_data(@ptrCast(@alignCast(row)), "entry", null);
        _ = l.bound.remove(row);
    }

    /// Shows whether a bound row's item was borrowed before: fainter for another format.
    fn markRow(l: *ItemList, row: *c.GtkWidget) void {
        const mark = cells(row).mark;
        const b = l.window.borrowed orelse return;
        const id: [*:0]const u8 = @ptrCast(c.g_object_get_data(@ptrCast(@alignCast(row)), "entry") orelse return c.gtk_widget_set_visible(mark, 0));
        const entry = l.by_id.get(std.mem.span(id)) orelse return c.gtk_widget_set_visible(mark, 0);
        const result = b.lookup(entry.bib);
        c.gtk_widget_set_visible(mark, @intFromBool(result.match != .none));
        if (result.match == .none) return;
        c.gtk_widget_set_opacity(mark, if (result.match == .same) 1.0 else 0.5);
        var buf: [1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const text = gtk.z(fba.allocator(), borrowed.markText(fba.allocator(), result, l.window.labels));
        c.gtk_widget_set_tooltip_text(mark, text);
        c.gtk_accessible_update_property(@ptrCast(@alignCast(mark)), c.GTK_ACCESSIBLE_PROPERTY_LABEL, text, @as(c_int, -1));
    }

    /// The borrowed-before index changed: re-mark the rows, and refilter with "Not Borrowed".
    pub fn borrowedChanged(l: *ItemList) void {
        const toggle = l.not_borrowed orelse return;
        const b = l.window.borrowed orelse return;
        if (b.off and c.gtk_toggle_button_get_active(@ptrCast(@alignCast(toggle))) != 0) {
            c.gtk_toggle_button_set_active(@ptrCast(@alignCast(toggle)), 0);
        }
        const on = c.gtk_toggle_button_get_active(@ptrCast(@alignCast(toggle))) != 0;
        c.gtk_widget_set_visible(toggle, @intFromBool(b.complete() or on));
        const generation = b.generation();
        if (generation == l.borrowed_generation) return;
        l.borrowed_generation = generation;
        var rows = l.bound.keyIterator();
        while (rows.next()) |row| l.markRow(row.*);
        if (on) l.applyNotBorrowed(true);
    }

    fn applyNotBorrowed(l: *ItemList, on: bool) void {
        const b = l.window.borrowed orelse return;
        const indexes = [_]*const borrowed.Index{b.index};
        capi.biblio_list_set_not_borrowed(l.list, &indexes, if (on) indexes.len else 0);
        l.sync();
        if (capi.biblio_list_needs_all_pages(l.list)) l.startBackground();
    }

    fn scheduleDwell(l: *ItemList) void {
        if (l.dwell == 0) l.dwell = c.g_timeout_add(placeholder_dwell_ms, &onDwell, l);
    }

    /// Placeholders stayed in view: fetch their pages.
    fn onDwell(data: ?*anyopaque) callconv(.c) c.gboolean {
        const l: *ItemList = @ptrCast(@alignCast(data.?));
        l.dwell = 0;
        var pages: [64]i64 = undefined;
        const n = capi.biblio_list_take_visible_requests(l.list, &pages, pages.len);
        const generation = capi.biblio_list_state(l.list).generation;
        for (pages[0..n]) |page| l.fetchPage(page, generation, false);
        return 0; // G_SOURCE_REMOVE
    }

    /// "Blu-ray Disc · 2026"
    fn formatLine(a_: std.mem.Allocator, labels: []const capi.Pair, bib: capi.Bib) []const u8 {
        const format = core.formatName(a_, std.mem.span(bib.format), labels);
        const date = core.str(bib.publication_date) orelse return format;
        return std.fmt.allocPrint(a_, "{s} · {s}", .{ format, year(date) }) catch format;
    }

    const Status = struct { text: []const u8, class: [*:0]const u8 };

    /// The account's relationship to the item if any, else the title's availability.
    fn statusLine(a_: std.mem.Allocator, entry: capi.ListEntry) Status {
        if (entry.account_status) |s| {
            if (std.mem.eql(u8, std.mem.span(s.kind), "checkedOut")) {
                const due = core.str(s.due) orelse return .{ .text = "Checked out", .class = "copy-held" };
                return .{ .text = std.fmt.allocPrint(a_, "Checked out · due {s}", .{due}) catch "Checked out", .class = "copy-held" };
            }
            if (s.ready) {
                const by = if (entry.hold) |h| core.str(h.pickup_by_date) else null;
                const where = if (entry.hold) |h| core.str(h.pickup_location) else null;
                const text = if (by) |d| std.fmt.allocPrint(a_, "Ready for pickup{s}{s} · by {s}", .{ if (where != null) " at " else "", where orelse "", d }) catch "Ready for pickup" else "Ready for pickup";
                return .{ .text = text, .class = "copy-available" };
            }
            if (s.has_position) return .{ .text = std.fmt.allocPrint(a_, "On hold · #{d}", .{s.position}) catch "On hold", .class = "copy-transit" };
            return .{ .text = "On hold", .class = "copy-transit" };
        }
        if (entry.history) |h| {
            if (core.str(h.returned_date)) |d| return .{ .text = std.fmt.allocPrint(a_, "Returned {s}", .{d}) catch "", .class = "dim-label" };
            return .{ .text = "", .class = "dim-label" };
        }
        const bib = entry.bib;
        const held = bib.held_copies;
        const total = bib.total_copies;
        const status = core.str(bib.status) orelse "";
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

    fn onActivate(_: *c.GtkListView, position: c.guint, data: ?*anyopaque) callconv(.c) void {
        const l: *ItemList = @ptrCast(@alignCast(data.?));
        const key = std.mem.span(c.gtk_string_list_get_string(l.model, position) orelse return);
        if (key.len == 0 or key[0] != 'i') return;
        const space = std.mem.indexOfScalar(u8, key, ' ') orelse return;
        const entry = l.by_id.get(key[space + 1 ..]) orelse return;
        l.window.select(entry);
    }

    fn onRefresh(_: *c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const l: *ItemList = @ptrCast(@alignCast(data.?));
        l.refresh();
    }

    fn onSearch(entry: *c.GtkSearchEntry, data: ?*anyopaque) callconv(.c) void {
        const l: *ItemList = @ptrCast(@alignCast(data.?));
        l.query = l.a().dupe(u8, std.mem.span(c.gtk_editable_get_text(@ptrCast(@alignCast(entry))))) catch return;
        l.newSearch();
    }

    /// Searches for `text` (e.g. an author from the details pane).
    pub fn searchFor(l: *ItemList, text: []const u8) void {
        if (l.search) |s| c.gtk_editable_set_text(@ptrCast(@alignCast(s)), gtk.z(l.a(), text));
        l.query = l.a().dupe(u8, text) catch return;
        l.newSearch();
    }

    /// A new query starts with the default sort and no format filter.
    fn newSearch(l: *ItemList) void {
        l.format = null;
        l.sort = null;
        l.client_sort = null;
        l.sort_ids = &.{};
        l.format_ids = &.{};
        capi.biblio_list_set_sort(l.list, .server);
        capi.biblio_list_set_format(l.list, null);
        l.reloadWith(false);
    }

    fn onSort(dropdown: *c.GtkDropDown, _: ?*c.GParamSpec, data: ?*anyopaque) callconv(.c) void {
        const l: *ItemList = @ptrCast(@alignCast(data.?));
        if (l.updating) return;
        const i = c.gtk_drop_down_get_selected(dropdown);
        if (i >= l.sort_ids.len) return;
        const id = l.sort_ids[i];
        if (std.mem.eql(u8, id, sort_people) or std.mem.eql(u8, id, sort_title)) {
            l.client_sort = if (std.mem.eql(u8, id, sort_people)) sort_people else sort_title;
            capi.biblio_list_set_sort(l.list, if (std.mem.eql(u8, id, sort_people)) .people_waiting else .title);
            l.sync();
            l.startBackground();
        } else {
            capi.biblio_list_set_sort(l.list, .server);
            l.client_sort = null;
            l.sort = id;
            l.reloadWith(true);
        }
    }

    fn onFormat(dropdown: *c.GtkDropDown, _: ?*c.GParamSpec, data: ?*anyopaque) callconv(.c) void {
        const l: *ItemList = @ptrCast(@alignCast(data.?));
        if (l.updating) return;
        const i = c.gtk_drop_down_get_selected(dropdown);
        if (i >= l.format_ids.len) return;
        l.format = if (i == 0) null else l.format_ids[i];
        var fba = std.heap.FixedBufferAllocator.init(&scratch);
        // Searches send the format to the server too; the list filters refined ones locally.
        capi.biblio_list_set_format(l.list, if (l.format) |f| gtk.z(fba.allocator(), f) else null);
        if (l.section == .search or l.section == .new_titles) return l.reloadWith(true);
        l.sync();
        if (capi.biblio_list_needs_all_pages(l.list)) l.startBackground();
    }

    fn onHoldFilter(button: *c.GtkToggleButton, data: ?*anyopaque) callconv(.c) void {
        const l: *ItemList = @ptrCast(@alignCast(data.?));
        if (l.updating) return;
        l.updating = true;
        const on = c.gtk_toggle_button_get_active(button) != 0;
        // At most one filter is on: turning one on turns the others off.
        for (l.hold_filters) |other| {
            if (other.? != gtk.widget(button)) c.gtk_toggle_button_set_active(@ptrCast(@alignCast(other.?)), 0);
        }
        l.updating = false;
        const index = @intFromPtr(c.g_object_get_data(@ptrCast(@alignCast(button)), "filter"));
        const filter: biblio.item_list.HoldFilter = if (!on) .none else switch (index) {
            1 => .ready,
            2 => .not_ready,
            else => .on_order,
        };
        capi.biblio_list_set_hold_filter(l.list, filter);
        l.sync();
        if (capi.biblio_list_needs_all_pages(l.list)) l.startBackground();
    }

    fn onNotBorrowed(button: *c.GtkToggleButton, data: ?*anyopaque) callconv(.c) void {
        const l: *ItemList = @ptrCast(@alignCast(data.?));
        const on = c.gtk_toggle_button_get_active(button) != 0;
        l.applyNotBorrowed(on);
        // Turned off where it isn't offered: hide it.
        if (!on) l.borrowedChanged();
    }
};

/// The bib's title, or "Untitled" if it has none.
pub fn bibTitle(bib: capi.Bib) []const u8 {
    const t = std.mem.span(bib.title);
    return if (t.len > 0) t else "Untitled";
}

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

const JacketJob = struct { window: *Window, picture: *c.GtkPicture, url: [:0]u8 };

/// Jackets already fetched, by URL, so rows recycled by the list view don't refetch them.
var jacket_cache: std.StringHashMapUnmanaged(*c.GdkTexture) = .empty;

/// Loads jacket art through the core (paced like other library requests) into `picture`.
pub fn loadJacket(w: *Window, picture: *c.GtkPicture, url: []const u8) void {
    if (jacket_cache.get(url)) |texture| return c.gtk_picture_set_paintable(picture, @ptrCast(@alignCast(texture)));
    const job = core.gpa.create(JacketJob) catch return;
    const copy = core.gpa.dupeSentinel(u8, url, 0) catch return core.gpa.destroy(job);
    job.* = .{ .window = w, .picture = picture, .url = copy };
    // A recycled row's picture asks for another jacket; only the latest request may fill it.
    c.g_object_set_data_full(@ptrCast(@alignCast(picture)), "jacket-url", c.g_strdup(copy.ptr), c.g_free);
    _ = c.g_object_ref(picture);
    const j = w.job(&onJacket, job) orelse {
        c.g_object_unref(picture);
        core.gpa.free(copy);
        return core.gpa.destroy(job);
    };
    j.fetchImage(url);
}

fn onJacket(data: ?*anyopaque, r: *core.Result) void {
    const job: *JacketJob = @ptrCast(@alignCast(data.?));
    const picture = job.picture;
    const w = job.window;
    const url = job.url;
    core.gpa.destroy(job);
    defer {
        c.g_object_unref(picture);
        core.gpa.free(url);
    }
    if (w.finishPending()) return;
    if (!r.ok) return;
    const texture = gtk.texture(r.bytes) orelse return;
    if (jacket_cache.count() < 2000) {
        if (core.gpa.dupe(u8, url)) |key| {
            jacket_cache.put(core.gpa, key, @ptrCast(@alignCast(c.g_object_ref(texture)))) catch {
                c.g_object_unref(texture);
                core.gpa.free(key);
            };
        } else |_| {}
    }
    defer c.g_object_unref(texture);
    const current = c.g_object_get_data(@ptrCast(@alignCast(picture)), "jacket-url") orelse return;
    if (!std.mem.eql(u8, std.mem.span(@as([*:0]const u8, @ptrCast(current))), url)) return;
    c.gtk_picture_set_paintable(picture, @ptrCast(@alignCast(texture)));
}

test year {
    try std.testing.expectEqualStrings("2026", year("20261006"));
    try std.testing.expectEqualStrings("2027", year("03/23/2027"));
    try std.testing.expectEqualStrings("1999", year("c1999"));
    try std.testing.expectEqualStrings("Spring", year("Spring"));
}
