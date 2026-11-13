//! A paged, infinitely scrolling list of catalog search results, new titles, holds,
//! checkouts or borrowing history, with sorting, filtering, and multiple selection.
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
const store = @import("store.zig");
const borrowed = @import("borrowed.zig");
const Multi = @import("multi.zig").Multi;
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

/// A catalog facet offered as a filter menu, beside Format.
const FacetKind = struct {
    id: [:0]const u8,
    title: [:0]const u8,
    /// Shown for searches only, not New Titles.
    search_only: bool = false,
};

const facet_kinds = [_]FacetKind{
    .{ .id = "STATUS", .title = "Available At", .search_only = true },
    .{ .id = "AUDIENCE", .title = "Audience" },
    .{ .id = "FICTION_TYPE", .title = "Content" },
    .{ .id = "LANGUAGE", .title = "Language" },
    .{ .id = "PUBLISHED_DATE", .title = "Published", .search_only = true },
    .{ .id = "NEWLY_ACQUIRED", .title = "Added", .search_only = true },
};

/// A facet's values from the latest first page, NUL-terminated for the core.
const FacetCopy = struct { id: []const u8, values: []const [:0]const u8, counts: []const i64 };

/// A facet filter in force (the server's `f_<id>` field).
const Filter = struct { id: []const u8, value: []const u8 };

pub const ItemList = struct {
    window: *Window,
    section: Section,
    root: *c.GtkWidget,
    stack: *c.GtkStack,
    view: *c.GtkListView,
    model: *c.GtkStringList,
    selection: *c.GtkSelectionModel,
    status: *c.AdwStatusPage,
    title: *c.AdwWindowTitle,
    search: ?*c.GtkSearchEntry = null,
    /// The header's Advanced Search button, hidden when the window is narrow (the menu has it).
    advanced_button: ?*c.GtkWidget = null,
    sort_dropdown: *c.GtkDropDown,
    format_dropdown: *c.GtkDropDown,
    spinner: *c.GtkWidget,
    /// The bottom bar for several selected rows (catalog lists and holds).
    multi: ?*Multi = null,
    /// "Select", for choosing several rows by touch.
    select_button: ?*c.GtkWidget = null,
    /// Rows' clicks toggle their selection, and their check boxes show.
    selecting: bool = false,
    hold_filters: [3]?*c.GtkWidget = @splat(null),
    /// The "Not Borrowed" toggle, for catalog lists and holds of signed-in windows.
    not_borrowed: ?*c.GtkWidget = null,
    /// Catalog lists' filter bar: Format, the facets, and Clear.
    filter_bar: ?*c.GtkWidget = null,
    facet_dropdowns: [facet_kinds.len]?*c.GtkDropDown = @splat(null),
    /// Each facet menu's values, parallel to its entries after "Any …".
    facet_values: [facet_kinds.len][]const []const u8 = @splat(&.{}),
    clear_button: ?*c.GtkWidget = null,
    /// New Titles: Just Arrived or On Order.
    arrival: ?*c.GtkDropDown = null,
    on_order: bool = false,
    /// Bound item rows, whose check boxes and borrowed-before marks follow along.
    bound: std.AutoHashMapUnmanaged(*c.GtkWidget, void) = .empty,
    borrowed_generation: u64 = 0,
    arena: std.heap.ArenaAllocator,
    sort_arena: std.heap.ArenaAllocator,
    format_arena: std.heap.ArenaAllocator,
    facet_arena: std.heap.ArenaAllocator,
    list: *biblio.item_list.List,
    /// Each page's result; released on reload (or when a refresh's first page replaces them).
    pages: std.ArrayList(*capi.ListPage) = .empty,
    /// Fetched entries by id, pointing into `pages`.
    by_id: std.StringHashMapUnmanaged(*const capi.ListEntry) = .empty,
    /// What the model holds: "i<position> <id>" for a fetched item, "p<position>" for a placeholder.
    shown: std.ArrayList([:0]u8) = .empty,
    /// Holds placed (true) or canceled (false) here since the rows were fetched, by bib id.
    held: std.StringHashMapUnmanaged(bool) = .empty,
    query: []const u8 = "",
    /// "bl" for an advanced (field-qualified) search; null for a keyword search.
    search_type: ?[]const u8 = null,
    filters: std.ArrayList(Filter) = .empty,
    /// The server sort chosen, if any; client sorts live in the core list.
    sort: ?[]const u8 = null,
    /// The client-side sort chosen (`sort_people` or `sort_title`), which the core list applies.
    client_sort: ?[]const u8 = null,
    sort_ids: []const []const u8 = &.{},
    format_ids: []const []const u8 = &.{},
    format_counts: []const i64 = &.{},
    /// The latest first page's facets, in `facet_arena`.
    facets: []const FacetCopy = &.{},
    /// The format filter: a facet for searches, applied locally for account lists.
    format: ?[]const u8 = null,
    background: bool = false,
    dwell: c.guint = 0,
    /// Set while the dropdowns are being refilled, so their change signals are ignored.
    updating: bool = false,
    /// Set while the model is spliced, so selection changes it causes are ignored.
    syncing: bool = false,

    pub fn create(w: *Window, section: Section) *ItemList {
        const l = core.gpa.create(ItemList) catch unreachable;
        const catalog = section == .search or section == .new_titles;
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
        c.gtk_actionable_set_action_name(@ptrCast(@alignCast(refresh_button)), "win.refresh");
        const spinner = c.adw_spinner_new();
        c.gtk_widget_set_visible(spinner, 0);
        c.adw_header_bar_pack_end(@ptrCast(@alignCast(header)), refresh_button);
        c.adw_header_bar_pack_start(@ptrCast(@alignCast(header)), spinner);
        c.adw_toolbar_view_add_top_bar(@ptrCast(@alignCast(toolbar)), header);

        const model = c.gtk_string_list_new(null);
        const selection: *c.GtkSelectionModel = @ptrCast(@alignCast(c.gtk_multi_selection_new(@ptrCast(@alignCast(c.g_object_ref(model))))));
        const factory = c.gtk_signal_list_item_factory_new();
        const view: *c.GtkListView = @ptrCast(@alignCast(c.gtk_list_view_new(selection, @ptrCast(@alignCast(factory)))));
        c.gtk_list_view_set_enable_rubberband(view, 1);
        c.gtk_widget_add_css_class(gtk.widget(view), "boxed-list");

        l.* = .{
            .window = w,
            .section = section,
            .root = toolbar,
            .stack = @ptrCast(@alignCast(c.gtk_stack_new())),
            .view = view,
            .model = @ptrCast(@alignCast(model)),
            .selection = selection,
            .status = @ptrCast(@alignCast(c.adw_status_page_new())),
            .title = title,
            .sort_dropdown = sort_dropdown,
            .format_dropdown = format_dropdown,
            .spinner = spinner,
            .arena = .init(core.gpa),
            .sort_arena = .init(core.gpa),
            .format_arena = .init(core.gpa),
            .facet_arena = .init(core.gpa),
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
            const advanced = c.gtk_button_new_from_icon_name("edit-find-replace-symbolic");
            c.gtk_widget_set_tooltip_text(advanced, "Advanced Search");
            gtk.connect(advanced, "clicked", &onAdvanced, l);
            c.adw_header_bar_pack_start(@ptrCast(@alignCast(header)), advanced);
            l.advanced_button = advanced;
        } else {
            c.adw_header_bar_set_title_widget(@ptrCast(@alignCast(header)), gtk.widget(title));
        }
        // Several rows at once: places holds from the catalog, cancels them from Holds.
        if (catalog or section == .holds) {
            const select = c.gtk_toggle_button_new();
            c.gtk_button_set_icon_name(@ptrCast(@alignCast(select)), "selection-mode-symbolic");
            c.gtk_widget_set_tooltip_text(select, "Select");
            gtk.connect(select, "toggled", &onSelectMode, l);
            c.adw_header_bar_pack_end(@ptrCast(@alignCast(header)), select);
            l.select_button = select;
            l.multi = Multi.create(w, l);
            c.adw_toolbar_view_add_bottom_bar(@ptrCast(@alignCast(toolbar)), l.multi.?.root);
        }
        // "Not Borrowed", offered once the borrowing history is fully read.
        if (!w.isGuest() and (catalog or section == .holds)) {
            const toggle = c.gtk_toggle_button_new_with_label("Not Borrowed");
            c.gtk_widget_set_tooltip_text(toggle, "Hide items you borrowed before in the same format");
            c.gtk_widget_set_visible(toggle, 0);
            gtk.connect(toggle, "toggled", &onNotBorrowed, l);
            l.not_borrowed = toggle;
        }
        if (catalog) l.buildFilterBar(toolbar);
        if (!catalog) {
            // Sort, Format, and (for holds) the status filters share a row that scrolls
            // sideways, so the header bar stays narrow enough for a phone.
            const filters = gtk.box(false, 12);
            gtk.margins(filters, 6);
            c.gtk_widget_set_halign(filters, c.GTK_ALIGN_CENTER);
            if (section == .holds) l.buildHoldFilters(filters);
            gtk.append(filters, gtk.widget(format_dropdown));
            gtk.append(filters, gtk.widget(sort_dropdown));
            c.adw_toolbar_view_add_top_bar(@ptrCast(@alignCast(toolbar)), controlRow(filters));
        }

        gtk.connect(factory, "setup", &onSetup, l);
        gtk.connect(factory, "bind", &onBind, l);
        gtk.connect(factory, "unbind", &onUnbind, l);
        gtk.connect(view, "activate", &onActivate, l);
        gtk.connect(selection, "selection-changed", &onSelectionChanged, l);
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

    /// A row of controls that scrolls sideways when the window is too narrow for it.
    fn controlRow(bar: *c.GtkWidget) *c.GtkWidget {
        const scroll = c.gtk_scrolled_window_new();
        c.gtk_scrolled_window_set_policy(@ptrCast(@alignCast(scroll)), c.GTK_POLICY_AUTOMATIC, c.GTK_POLICY_NEVER);
        c.gtk_scrolled_window_set_propagate_natural_height(@ptrCast(@alignCast(scroll)), 1);
        c.gtk_scrolled_window_set_child(@ptrCast(@alignCast(scroll)), bar);
        return scroll;
    }

    /// "Ready", "Not Ready" and "On Order", each with a count (at most one is on), and
    /// "Not Borrowed".
    fn buildHoldFilters(l: *ItemList, row: *c.GtkWidget) void {
        const bar = gtk.box(false, 0);
        c.gtk_widget_add_css_class(bar, "linked");
        for (&l.hold_filters, 0..) |*slot, i| {
            const button = c.gtk_toggle_button_new_with_label("");
            c.g_object_set_data(@ptrCast(@alignCast(button)), "filter", @ptrFromInt(i + 1));
            gtk.connect(button, "toggled", &onHoldFilter, l);
            gtk.append(bar, button);
            slot.* = button;
        }
        gtk.append(row, bar);
        if (l.not_borrowed) |toggle| gtk.append(row, toggle);
    }

    /// Format, the other facets, and Clear, in a row that scrolls sideways on a phone.
    fn buildFilterBar(l: *ItemList, toolbar: *c.GtkWidget) void {
        const bar = gtk.box(false, 6);
        gtk.margins(bar, 6);
        const prompt = gtk.label("Filter by", std.heap.c_allocator, &.{ "dim-label", "caption" });
        c.gtk_label_set_wrap(@ptrCast(@alignCast(prompt)), 0);
        gtk.append(bar, prompt);
        if (l.section == .new_titles) {
            const choices = [_:null]?[*:0]const u8{ "Just Arrived", "On Order" };
            const arrival: *c.GtkDropDown = @ptrCast(@alignCast(c.gtk_drop_down_new_from_strings(&choices)));
            c.gtk_widget_set_tooltip_text(gtk.widget(arrival), "Arrival");
            gtk.connect(arrival, "notify::selected", &onArrival, l);
            gtk.append(bar, gtk.widget(arrival));
            l.arrival = arrival;
        }
        gtk.append(bar, gtk.widget(l.format_dropdown));
        for (facet_kinds, 0..) |kind, i| {
            if (kind.search_only and l.section != .search) continue;
            const dropdown: *c.GtkDropDown = @ptrCast(@alignCast(c.gtk_drop_down_new(null, null)));
            c.gtk_widget_set_tooltip_text(gtk.widget(dropdown), kind.title.ptr);
            c.gtk_widget_set_visible(gtk.widget(dropdown), 0);
            c.g_object_set_data(@ptrCast(@alignCast(dropdown)), "facet", @ptrFromInt(i + 1));
            gtk.connect(dropdown, "notify::selected", &onFacet, l);
            gtk.append(bar, gtk.widget(dropdown));
            l.facet_dropdowns[i] = dropdown;
        }
        gtk.append(bar, gtk.widget(l.sort_dropdown));
        if (l.not_borrowed) |toggle| gtk.append(bar, toggle);
        const clear = c.gtk_button_new_with_mnemonic("C_lear");
        c.gtk_widget_add_css_class(clear, "flat");
        c.gtk_widget_set_tooltip_text(clear, "Clear Filters");
        c.gtk_widget_set_visible(clear, 0);
        gtk.connect(clear, "clicked", &onClearFilters, l);
        gtk.append(bar, clear);
        l.clear_button = clear;
        const clamp = c.adw_clamp_new();
        c.adw_clamp_set_maximum_size(@ptrCast(@alignCast(clamp)), 900);
        c.adw_clamp_set_child(@ptrCast(@alignCast(clamp)), controlRow(bar));
        c.gtk_widget_set_margin_start(clamp, 6);
        c.gtk_widget_set_margin_end(clamp, 6);
        // New Titles always has its arrival menu; a search's bar waits for its first results.
        c.gtk_widget_set_visible(clamp, @intFromBool(l.section == .new_titles));
        c.adw_toolbar_view_add_top_bar(@ptrCast(@alignCast(toolbar)), clamp);
        l.filter_bar = clamp;
    }

    pub fn free(l: *ItemList) void {
        if (l.dwell != 0) _ = c.g_source_remove(l.dwell);
        if (l.multi) |m| m.free();
        capi.biblio_list_free(l.list);
        l.releasePages();
        l.pages.deinit(core.gpa);
        l.by_id.deinit(core.gpa);
        l.bound.deinit(core.gpa);
        l.clearHeld();
        l.held.deinit(core.gpa);
        for (l.shown.items) |k| core.gpa.free(k);
        l.shown.deinit(core.gpa);
        c.g_object_unref(l.model);
        l.arena.deinit();
        l.sort_arena.deinit();
        l.format_arena.deinit();
        l.facet_arena.deinit();
        core.gpa.destroy(l);
    }

    fn a(l: *ItemList) std.mem.Allocator {
        return l.arena.allocator();
    }

    fn releasePages(l: *ItemList) void {
        l.by_id.clearRetainingCapacity();
        for (l.pages.items) |page| core.release(page);
        l.pages.clearRetainingCapacity();
        // Fetched afresh, the rows say whether each title is held.
        l.clearHeld();
    }

    fn clearHeld(l: *ItemList) void {
        var keys = l.held.keyIterator();
        while (keys.next()) |k| core.gpa.free(k.*);
        l.held.clearRetainingCapacity();
    }

    fn showEmpty(l: *ItemList) void {
        const s = l.status;
        c.adw_status_page_set_child(s, null);
        switch (l.section) {
            .search => {
                c.adw_status_page_set_icon_name(s, "system-search-symbolic");
                const blank = std.mem.trim(u8, l.query, " ").len == 0;
                const t = std.fmt.allocPrint(l.a(), "Search {s}", .{store.shortName(l.window.library)}) catch "Search";
                c.adw_status_page_set_title(s, if (blank) gtk.z(l.a(), t) else "No Results");
                c.adw_status_page_set_description(s, if (blank) "Find books, movies, music, and more." else "Try other words, or fewer filters.");
                const advanced = c.gtk_button_new_with_mnemonic("_Advanced Search…");
                c.gtk_widget_add_css_class(advanced, "pill");
                c.gtk_widget_set_halign(advanced, c.GTK_ALIGN_CENTER);
                gtk.connect(advanced, "clicked", &onAdvanced, l);
                c.adw_status_page_set_child(s, advanced);
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
                c.adw_status_page_set_title(s, if (l.on_order) "Nothing on Order" else "No New Titles");
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

    /// Refresh (Ctrl+R): account lists start a fresh session first (the gateway can keep
    /// serving one session a wrong list), then everything reloads with the old rows dimmed.
    pub fn refresh(l: *ItemList) void {
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

    /// The search's form fields: the facet filters, and New Titles' arrival.
    fn searchFilters(l: *ItemList, j: *core.Job) []const capi.Pair {
        var pairs: std.ArrayList(capi.Pair) = .empty;
        if (l.section == .new_titles) pairs.append(j.a(), .{ .key = "f_on_order", .value = if (l.on_order) "true" else "false" }) catch {};
        for (l.filters.items) |f| {
            const key = std.fmt.allocPrintSentinel(j.a(), "f_{s}", .{f.id}, 0) catch continue;
            pairs.append(j.a(), .{ .key = key.ptr, .value = j.z(f.value) }) catch {};
        }
        return pairs.items;
    }

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
            .search, .new_titles => {
                const filters = l.searchFilters(j);
                j.start(capi.biblio_search, .{ w.client, j.new(capi.SearchQuery{
                    .query = if (l.section == .new_titles) "nw:[0 TO 180]" else j.z(l.query),
                    .search_type = if (l.section == .new_titles) "bl" else j.optZ(l.search_type),
                    .filters = filters.ptr,
                    .filter_count = filters.len,
                    .page = page,
                    .sort = j.optZ(sort),
                    .format = j.optZ(l.format),
                }) });
            },
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
            if (result.facets_count > 0 and (t.page == 1 or l.facets.len == 0)) l.keepFacets(result);
        }
        l.sync();
        // The details' Hold controls know this account's hold once the holds list does.
        if (l.section == .holds and t.page == 1) l.window.detail.refresh();
        l.window.selectPending(l);
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
        if (removals > 0 or added.len > 0) l.splice(prefix, removals, added);
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
        if (l.section == .search or l.section == .new_titles) {
            l.updateFacetFormats();
        } else {
            l.updateLocalFormats();
        }
        l.updateFilterBar();
    }

    fn splice(l: *ItemList, position: usize, removals: usize, added: []const [:0]u8) void {
        const additions = core.gpa.alloc(?[*:0]const u8, added.len + 1) catch return;
        defer core.gpa.free(additions);
        for (added, 0..) |k, i| additions[i] = k.ptr;
        additions[added.len] = null;
        l.syncing = true;
        defer l.syncing = false;
        c.gtk_string_list_splice(l.model, @intCast(position), @intCast(removals), @ptrCast(additions.ptr));
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

    /// Keeps a first page's facets (they describe the whole search) and refills their menus.
    fn keepFacets(l: *ItemList, page: *const capi.ListPage) void {
        _ = l.facet_arena.reset(.retain_capacity);
        const fa = l.facet_arena.allocator();
        var facets: std.ArrayList(FacetCopy) = .empty;
        for (core.items(capi.Facet, page.facets, page.facets_count)) |server_facet| {
            const source = core.items(capi.FacetValue, server_facet.values, server_facet.values_count);
            const values = fa.alloc([:0]const u8, source.len) catch continue;
            const counts = fa.alloc(i64, source.len) catch continue;
            for (source, values, counts) |v, *value, *count| {
                value.* = fa.dupeSentinel(u8, std.mem.span(v.value), 0) catch "";
                count.* = v.count;
            }
            facets.append(fa, .{ .id = fa.dupe(u8, std.mem.span(server_facet.id)) catch continue, .values = values, .counts = counts }) catch {};
        }
        l.facets = facets.items;
        l.updateFacetMenus();
    }

    fn facet(l: *ItemList, id: []const u8) ?FacetCopy {
        for (l.facets) |f| if (std.mem.eql(u8, f.id, id)) return f;
        return null;
    }

    fn filterValue(l: *ItemList, id: []const u8) ?[]const u8 {
        for (l.filters.items) |f| if (std.mem.eql(u8, f.id, id)) return f.value;
        return null;
    }

    /// Catalog lists' Format menu, from the FORMAT facet, with refined formats' counts made
    /// exact by the core once every item is in.
    fn updateFacetFormats(l: *ItemList) void {
        const f = l.facet("FORMAT") orelse return l.setFormatMenu(&.{});
        var fba = std.heap.FixedBufferAllocator.init(&scratch);
        const sa = fba.allocator();
        const counts = sa.dupe(i64, f.counts) catch return;
        const values = sa.alloc([*:0]const u8, f.values.len) catch return;
        for (values, f.values) |*p, v| p.* = v.ptr;
        capi.biblio_list_format_facet_counts(l.list, values.ptr, counts.ptr, values.len);
        var choices: std.ArrayList(Choice) = .empty;
        defer choices.deinit(core.gpa);
        for (f.values, counts) |v, n| choices.append(core.gpa, .{ .id = v, .count = n }) catch {};
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
        // The chosen format stays choosable when a new page's facets leave it out.
        if (l.format) |f| if (selected == 0) {
            selected = @intCast(ids.items.len);
            ids.append(fa, fa.dupe(u8, f) catch "") catch {};
            names.append(fa, gtk.z(fa, core.formatName(fa, f, l.window.labels))) catch {};
        };
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

    /// The facet menus beside Format: "Any Audience", then each value with its count.
    fn updateFacetMenus(l: *ItemList) void {
        l.updating = true;
        defer l.updating = false;
        const fa = l.facet_arena.allocator();
        for (facet_kinds, 0..) |kind, i| {
            const dropdown = l.facet_dropdowns[i] orelse continue;
            // Locations name the copies' branches; without them (guests) the ids mean nothing.
            const f: FacetCopy = if (std.mem.eql(u8, kind.id, "STATUS") and l.window.locations.len == 0)
                .{ .id = kind.id, .values = &.{}, .counts = &.{} }
            else
                l.facet(kind.id) orelse .{ .id = kind.id, .values = &.{}, .counts = &.{} };
            const chosen = l.filterValue(kind.id);
            var ids: std.ArrayList([]const u8) = .empty;
            var names: std.ArrayList(?[*:0]const u8) = .empty;
            names.append(fa, gtk.z(fa, std.fmt.allocPrint(fa, "Any {s}", .{kind.title}) catch kind.title)) catch {};
            var selected: c.guint = 0;
            for (f.values, f.counts) |v, n| {
                if (chosen) |ch| if (std.mem.eql(u8, ch, v)) {
                    selected = @intCast(ids.items.len + 1);
                };
                ids.append(fa, v) catch continue;
                const name = l.facetName(fa, kind.id, v);
                names.append(fa, gtk.z(fa, std.fmt.allocPrint(fa, "{s} ({d})", .{ name, n }) catch name)) catch {};
            }
            if (chosen) |ch| if (selected == 0) {
                selected = @intCast(ids.items.len + 1);
                ids.append(fa, fa.dupe(u8, ch) catch "") catch {};
                names.append(fa, gtk.z(fa, l.facetName(fa, kind.id, ch))) catch {};
            };
            names.append(fa, null) catch {};
            l.facet_values[i] = ids.items;
            const model = c.gtk_string_list_new(@ptrCast(names.items.ptr));
            c.gtk_drop_down_set_model(dropdown, @ptrCast(@alignCast(model)));
            c.g_object_unref(model);
            c.gtk_drop_down_set_selected(dropdown, selected);
            const shown = ids.items.len > 0;
            c.gtk_widget_set_visible(gtk.widget(dropdown), @intFromBool(shown));
        }
        if (l.clear_button) |b| c.gtk_widget_set_visible(b, @intFromBool(l.filters.items.len > 0 or l.format != null));
        l.updateFilterBar();
    }

    /// The filter bar shows with New Titles, and with a search that has results (or filters to
    /// clear) and something to filter by.
    fn updateFilterBar(l: *ItemList) void {
        const bar = l.filter_bar orelse return;
        var show = l.section == .new_titles;
        if (!show and (l.shown.items.len > 0 or l.filters.items.len > 0 or l.format != null)) {
            show = c.gtk_widget_get_visible(gtk.widget(l.format_dropdown)) != 0 or
                c.gtk_widget_get_visible(gtk.widget(l.sort_dropdown)) != 0;
            for (l.facet_dropdowns) |dropdown| if (dropdown) |d| {
                show = show or c.gtk_widget_get_visible(gtk.widget(d)) != 0;
            };
            if (l.not_borrowed) |toggle| show = show or c.gtk_widget_get_visible(toggle) != 0;
        }
        c.gtk_widget_set_visible(bar, @intFromBool(show));
    }

    /// A facet value's name: the library's label, else the value tidied.
    fn facetName(l: *ItemList, fa: std.mem.Allocator, id: []const u8, value: []const u8) []const u8 {
        const lib = l.window.library;
        if (std.mem.eql(u8, id, "STATUS")) {
            if (std.mem.eql(u8, value, "_online_")) return "Online";
            if (std.mem.eql(u8, value, "_physical_")) return "Any Location";
            for (l.window.locations) |loc| if (std.mem.eql(u8, std.mem.span(loc.id), value)) return std.mem.span(loc.name);
            return value;
        }
        if (std.mem.eql(u8, id, "LANGUAGE")) {
            const key = std.fmt.allocPrint(fa, "LANGUAGE.{s}", .{value}) catch return value;
            return store.label(lib, key) orelse value;
        }
        if (std.mem.eql(u8, id, "AUDIENCE") or std.mem.eql(u8, id, "FICTION_TYPE")) {
            const lower = std.ascii.allocLowerString(fa, value) catch return value;
            const key = std.fmt.allocPrint(fa, "{s}.{s}", .{ id, lower }) catch return value;
            return store.label(lib, key) orelse prettified(fa, value);
        }
        if (std.mem.eql(u8, id, "NEWLY_ACQUIRED")) {
            const rest = if (std.mem.startsWith(u8, value, "PAST_")) value[5..] else return prettified(fa, value);
            return std.fmt.allocPrint(fa, "Past {s}", .{prettified(fa, rest)}) catch value;
        }
        return value;
    }

    // MARK: Rows

    /// One row's widgets, reached through the row's object data.
    const Cells = struct {
        check: *c.GtkCheckButton,
        jacket: *c.GtkPicture,
        title: *c.GtkLabel,
        subtitle: *c.GtkLabel,
        author: *c.GtkLabel,
        format: *c.GtkLabel,
        /// "Borrowed before", after the format line.
        mark: *c.GtkWidget,
        availability: *c.GtkWidget,
        status_icon: *c.GtkImage,
        status: *c.GtkLabel,
        order: *c.GtkWidget,
        order_label: *c.GtkLabel,
        waiting: *c.GtkLabel,
        /// The account's relationship: on hold, ready, in transit, paused, checked out.
        capsule: *c.GtkLabel,
    };

    fn put(parent: *c.GtkWidget, comptime name: [:0]const u8, child: anytype) void {
        c.g_object_set_data(@ptrCast(@alignCast(parent)), name, child);
    }

    fn cell(comptime name: [:0]const u8, parent: *c.GtkWidget, text_box: *c.GtkWidget, classes: []const [*:0]const u8) *c.GtkLabel {
        const label = gtk.label("", std.heap.c_allocator, classes);
        gtk.append(text_box, label);
        put(parent, name, label);
        return @ptrCast(@alignCast(label));
    }

    fn onSetup(_: *c.GtkListItemFactory, item: *c.GtkListItem, data: ?*anyopaque) callconv(.c) void {
        const l: *ItemList = @ptrCast(@alignCast(data.?));
        const row = gtk.box(false, 12);
        gtk.margins(row, 10);
        c.gtk_widget_set_size_request(row, -1, 96);
        put(row, "item", item);
        const check = c.gtk_check_button_new();
        c.gtk_widget_set_valign(check, c.GTK_ALIGN_CENTER);
        c.gtk_widget_set_can_target(check, 0);
        c.gtk_widget_set_can_focus(check, 0);
        c.gtk_widget_set_visible(check, @intFromBool(l.selecting));
        gtk.append(row, check);
        put(row, "check", check);
        const jacket = gtk.jacket(48, 72);
        gtk.append(row, gtk.clampWidth(jacket, 48));
        put(row, "jacket", jacket);
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
        put(row, "mark", mark);

        // Availability: status, copies on order, and people waiting.
        const availability = gtk.box(false, 4);
        c.gtk_widget_add_css_class(availability, "caption");
        gtk.append(text, availability);
        put(row, "availability", availability);
        const status_icon = c.gtk_image_new();
        c.gtk_image_set_pixel_size(@ptrCast(@alignCast(status_icon)), 12);
        gtk.append(availability, status_icon);
        put(row, "status_icon", status_icon);
        _ = cell("status", row, availability, &.{});
        const order = gtk.box(false, 3);
        c.gtk_widget_add_css_class(order, "copy-onOrder");
        c.gtk_widget_set_margin_start(order, 4);
        const box_icon = c.gtk_image_new_from_icon_name("package-x-generic-symbolic");
        c.gtk_image_set_pixel_size(@ptrCast(@alignCast(box_icon)), 12);
        gtk.append(order, box_icon);
        gtk.append(availability, order);
        put(row, "order", order);
        _ = cell("order_label", row, order, &.{});
        const waiting = cell("waiting", row, availability, &.{"dim-label"});
        c.gtk_widget_set_margin_start(gtk.widget(waiting), 4);
        c.gtk_label_set_ellipsize(waiting, c.PANGO_ELLIPSIZE_END);
        c.gtk_label_set_wrap(waiting, 0);

        const capsule = gtk.label("", std.heap.c_allocator, &.{ "capsule", "caption" });
        c.gtk_label_set_wrap(@ptrCast(@alignCast(capsule)), 0);
        c.gtk_widget_set_halign(capsule, c.GTK_ALIGN_START);
        c.gtk_widget_set_margin_top(capsule, 2);
        gtk.append(text, capsule);
        put(row, "capsule", capsule);
        c.gtk_list_item_set_child(item, row);

        // While selecting, a click toggles the row; otherwise a click on the shown row shows
        // its details again (after the pane was closed).
        const click = c.gtk_gesture_click_new();
        c.gtk_event_controller_set_propagation_phase(@ptrCast(@alignCast(click)), c.GTK_PHASE_CAPTURE);
        gtk.connect(click, "pressed", &onRowPressed, l);
        c.gtk_widget_add_controller(row, @ptrCast(@alignCast(click)));
    }

    fn cells(row: *c.GtkWidget) Cells {
        const get = struct {
            fn f(w: *c.GtkWidget, name: [*:0]const u8) *anyopaque {
                return c.g_object_get_data(@ptrCast(@alignCast(w)), name).?;
            }
        }.f;
        return .{
            .check = @ptrCast(@alignCast(get(row, "check"))),
            .jacket = @ptrCast(@alignCast(get(row, "jacket"))),
            .title = @ptrCast(@alignCast(get(row, "title"))),
            .subtitle = @ptrCast(@alignCast(get(row, "subtitle"))),
            .author = @ptrCast(@alignCast(get(row, "author"))),
            .format = @ptrCast(@alignCast(get(row, "format"))),
            .mark = @ptrCast(@alignCast(get(row, "mark"))),
            .availability = @ptrCast(@alignCast(get(row, "availability"))),
            .status_icon = @ptrCast(@alignCast(get(row, "status_icon"))),
            .status = @ptrCast(@alignCast(get(row, "status"))),
            .order = @ptrCast(@alignCast(get(row, "order"))),
            .order_label = @ptrCast(@alignCast(get(row, "order_label"))),
            .waiting = @ptrCast(@alignCast(get(row, "waiting"))),
            .capsule = @ptrCast(@alignCast(get(row, "capsule"))),
        };
    }

    fn setText(label: *c.GtkLabel, a_: std.mem.Allocator, text: []const u8) void {
        c.gtk_label_set_text(label, gtk.z(a_, text));
        c.gtk_widget_set_visible(gtk.widget(label), @intFromBool(text.len > 0));
    }

    const status_classes = [_][*:0]const u8{ "copy-available", "copy-onOrder", "copy-out", "copy-held", "copy-transit", "copy-ready", "copy-paused", "dim-label" };

    fn onBind(_: *c.GtkListItemFactory, item: *c.GtkListItem, data: ?*anyopaque) callconv(.c) void {
        const l: *ItemList = @ptrCast(@alignCast(data.?));
        const key = std.mem.span(c.gtk_string_object_get_string(@ptrCast(@alignCast(c.gtk_list_item_get_item(item)))));
        const row = gtk.as(c.GtkWidget, c.gtk_list_item_get_child(item));
        const cl = cells(row);
        var fba = std.heap.FixedBufferAllocator.init(&scratch);
        const sa = fba.allocator();
        const refreshing = capi.biblio_list_state(l.list).refreshing;
        c.gtk_picture_set_paintable(cl.jacket, null);
        for (status_classes) |cls| {
            c.gtk_widget_remove_css_class(gtk.widget(cl.status), cls);
            c.gtk_widget_remove_css_class(gtk.widget(cl.status_icon), cls);
            c.gtk_widget_remove_css_class(gtk.widget(cl.capsule), cls);
        }
        c.g_object_set_data(@ptrCast(@alignCast(row)), "placeholder", null);
        c.g_object_set_data(@ptrCast(@alignCast(row)), "entry", null);
        c.gtk_widget_set_visible(cl.mark, 0);
        l.bound.put(core.gpa, row, {}) catch {};
        c.gtk_widget_set_visible(gtk.widget(cl.check), @intFromBool(l.selecting));
        c.gtk_check_button_set_active(cl.check, c.gtk_list_item_get_selected(item));
        if (key.len > 0 and key[0] == 'p') {
            const position = std.fmt.parseInt(i64, key[1..], 10) catch 0;
            for ([_]*c.GtkLabel{ cl.title, cl.subtitle, cl.author, cl.format, cl.capsule }) |label| setText(label, sa, "");
            c.gtk_widget_set_visible(cl.availability, 0);
            c.gtk_picture_set_alternative_text(cl.jacket, null);
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
        l.bindAvailability(sa, cl, entry);
        const rel = relationship(sa, entry, l.heldMark(bib));
        setText(cl.capsule, sa, rel.text);
        c.gtk_widget_add_css_class(gtk.widget(cl.capsule), rel.class);
        c.gtk_picture_set_alternative_text(cl.jacket, gtk.z(sa, std.fmt.allocPrint(sa, "Cover of {s}", .{bibTitle(bib)}) catch "Cover"));
        if (core.str(bib.jacket_small)) |url| loadJacket(l.window, cl.jacket, url);
        c.g_object_set_data_full(@ptrCast(@alignCast(row)), "entry", c.g_strdup(entry.id), c.g_free);
        if (l.not_borrowed != null) l.markRow(row);
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

    /// "Available", "N on order", and "N holds on M copies", for catalog rows and holds.
    fn bindAvailability(l: *ItemList, sa: std.mem.Allocator, cl: Cells, entry: capi.ListEntry) void {
        const shown = l.section == .search or l.section == .new_titles or l.section == .holds;
        c.gtk_widget_set_visible(cl.availability, @intFromBool(shown));
        if (!shown) return;
        const bib = entry.bib;
        const status = core.str(bib.status) orelse "";
        const label: struct { text: []const u8, icon: ?[*:0]const u8, class: [*:0]const u8 } = if (std.mem.eql(u8, status, "AVAILABLE"))
            .{ .text = "Available", .icon = "object-select-symbolic", .class = "copy-available" }
        else if (std.mem.eql(u8, status, "ON_ORDER"))
            .{ .text = "On order", .icon = "package-x-generic-symbolic", .class = "copy-onOrder" }
        else if (std.mem.eql(u8, status, "UNAVAILABLE") or std.mem.eql(u8, status, "NOT_AVAILABLE"))
            .{ .text = "All copies in use", .icon = "alarm-symbolic", .class = "copy-out" }
        else
            .{ .text = prettified(sa, status), .icon = null, .class = "dim-label" };
        setText(cl.status, sa, label.text);
        c.gtk_widget_add_css_class(gtk.widget(cl.status), label.class);
        c.gtk_widget_add_css_class(gtk.widget(cl.status_icon), label.class);
        c.gtk_image_set_from_icon_name(cl.status_icon, label.icon);
        c.gtk_widget_set_visible(gtk.widget(cl.status_icon), @intFromBool(label.icon != null));
        // "On order" when the title has no copies yet, "N on order" when more are coming.
        const more = !std.mem.eql(u8, status, "ON_ORDER") and bib.on_order_copies > 0;
        c.gtk_widget_set_visible(cl.order, @intFromBool(more));
        if (more) setText(cl.order_label, sa, std.fmt.allocPrint(sa, "{d} on order", .{bib.on_order_copies}) catch "On order");
        setText(cl.waiting, sa, peopleWaiting(sa, bib));
    }

    /// The hold this list placed (true) or canceled (false) on a title since fetching it.
    fn heldMark(l: *ItemList, bib: capi.Bib) ?bool {
        return l.held.get(std.mem.span(bib.id));
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
        l.updateFilterBar();
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

    // MARK: Other parts of the window

    /// The fetched entry for a title, if this list has one.
    pub fn entryForBib(l: *ItemList, bib_id: []const u8) ?*const capi.ListEntry {
        var it = l.by_id.valueIterator();
        while (it.next()) |entry| if (std.mem.eql(u8, std.mem.span(entry.*.bib.id), bib_id)) return entry.*;
        return null;
    }

    /// Marks titles held (or not) at once, before the lists are fetched again.
    pub fn markHeld(l: *ItemList, bib_ids: []const []const u8, held: bool) void {
        for (bib_ids) |id| {
            const gop = l.held.getOrPut(core.gpa, id) catch continue;
            if (!gop.found_existing) gop.key_ptr.* = core.gpa.dupe(u8, id) catch {
                l.held.removeByPtr(gop.key_ptr);
                continue;
            };
            gop.value_ptr.* = held;
        }
        // Rebind the rows showing those titles.
        for (l.shown.items, 0..) |key, i| {
            const space = std.mem.indexOfScalar(u8, key, ' ') orelse continue;
            const entry = l.by_id.get(key[space + 1 ..]) orelse continue;
            for (bib_ids) |id| if (std.mem.eql(u8, std.mem.span(entry.bib.id), id)) {
                l.splice(i, 1, &.{key});
                break;
            };
        }
    }

    /// Takes away entries (holds just canceled) without fetching the list again.
    pub fn removeEntries(l: *ItemList, ids: []const []const u8) void {
        if (ids.len == 0) return;
        var fba = std.heap.FixedBufferAllocator.init(&scratch);
        const sa = fba.allocator();
        const ptrs = sa.alloc([*:0]const u8, ids.len) catch return l.reload();
        for (ptrs, ids) |*p, id| p.* = gtk.z(sa, id);
        _ = capi.biblio_list_remove(l.list, ptrs.ptr, ptrs.len);
        l.sync();
    }

    pub fn openAdvanced(l: *ItemList) void {
        @import("advanced.zig").Advanced.present(l);
    }

    pub fn focusSearch(l: *ItemList) void {
        if (l.search) |s| _ = c.gtk_widget_grab_focus(gtk.widget(s));
    }

    /// Takes over another window's search: its words, kind, filters, and sort.
    pub fn continueFrom(l: *ItemList, from: *ItemList) void {
        l.query = l.a().dupe(u8, from.query) catch "";
        l.search_type = if (from.search_type) |t| l.a().dupe(u8, t) catch null else null;
        l.filters = .empty;
        for (from.filters.items) |f| l.setFilter(f.id, f.value);
        l.format = if (from.format) |f| l.a().dupe(u8, f) catch null else null;
        l.sort = if (from.sort) |s| l.a().dupe(u8, s) catch null else null;
        if (l.search) |s| c.gtk_editable_set_text(@ptrCast(@alignCast(s)), gtk.z(l.a(), l.query));
        var fba = std.heap.FixedBufferAllocator.init(&scratch);
        capi.biblio_list_set_format(l.list, if (l.format) |f| gtk.z(fba.allocator(), f) else null);
        if (std.mem.trim(u8, l.query, " ").len > 0) l.reloadWith(false);
    }

    /// Runs an advanced search: a field-qualified query, with the format and facet filters chosen.
    pub fn advancedSearch(l: *ItemList, query: []const u8, format: ?[]const u8, filters: []const Filter) void {
        if (l.search) |s| c.gtk_editable_set_text(@ptrCast(@alignCast(s)), gtk.z(l.a(), query));
        l.query = l.a().dupe(u8, query) catch return;
        l.resetSearch();
        l.search_type = "bl";
        for (filters) |f| l.setFilter(f.id, f.value);
        l.format = if (format) |f| l.a().dupe(u8, f) catch null else null;
        var fba = std.heap.FixedBufferAllocator.init(&scratch);
        capi.biblio_list_set_format(l.list, if (l.format) |f| gtk.z(fba.allocator(), f) else null);
        l.reloadWith(false);
    }

    fn setFilter(l: *ItemList, id: []const u8, value: ?[]const u8) void {
        for (l.filters.items, 0..) |f, i| if (std.mem.eql(u8, f.id, id)) {
            _ = l.filters.orderedRemove(i);
            break;
        };
        const v = value orelse return;
        l.filters.append(l.a(), .{ .id = l.a().dupe(u8, id) catch return, .value = l.a().dupe(u8, v) catch return }) catch {};
    }

    // MARK: Selection

    /// The fetched entries selected, in list order.
    fn selectedEntries(l: *ItemList, out: *std.ArrayList(*const capi.ListEntry)) void {
        const set = c.gtk_selection_model_get_selection(l.selection) orelse return;
        defer c.gtk_bitset_unref(set);
        const n = c.gtk_bitset_get_size(set);
        var i: u64 = 0;
        while (i < n) : (i += 1) {
            const position: usize = c.gtk_bitset_get_nth(set, @intCast(i));
            if (position >= l.shown.items.len) continue;
            const key = l.shown.items[position];
            const space = std.mem.indexOfScalar(u8, key, ' ') orelse continue;
            const entry = l.by_id.get(key[space + 1 ..]) orelse continue;
            out.append(core.gpa, entry) catch {};
        }
    }

    fn onSelectionChanged(_: *c.GtkSelectionModel, _: c.guint, _: c.guint, data: ?*anyopaque) callconv(.c) void {
        const l: *ItemList = @ptrCast(@alignCast(data.?));
        // Check boxes follow the selection.
        var rows = l.bound.keyIterator();
        while (rows.next()) |row| {
            const item: *c.GtkListItem = @ptrCast(@alignCast(c.g_object_get_data(@ptrCast(@alignCast(row.*)), "item") orelse continue));
            c.gtk_check_button_set_active(cells(row.*).check, c.gtk_list_item_get_selected(item));
        }
        if (l.syncing) return;
        l.showSelection();
    }

    /// One selected item shows its details; several, what can be done with them all.
    pub fn showSelection(l: *ItemList) void {
        var entries: std.ArrayList(*const capi.ListEntry) = .empty;
        defer entries.deinit(core.gpa);
        l.selectedEntries(&entries);
        if (l.multi) |m| m.update(entries.items);
        switch (entries.items.len) {
            0 => if (l.selecting) l.window.hideDetail(),
            1 => if (!l.selecting) l.window.select(entries.items[0]),
            else => l.window.selectMany(l.section, entries.items),
        }
    }

    /// Unselects everything (after the selection's holds are placed or canceled).
    pub fn clearSelection(l: *ItemList) void {
        _ = c.gtk_selection_model_unselect_all(l.selection);
    }

    fn onRowPressed(gesture: *c.GtkGestureClick, _: c_int, _: f64, _: f64, data: ?*anyopaque) callconv(.c) void {
        const l: *ItemList = @ptrCast(@alignCast(data.?));
        const row = c.gtk_event_controller_get_widget(@ptrCast(@alignCast(gesture)));
        const item: *c.GtkListItem = @ptrCast(@alignCast(c.g_object_get_data(@ptrCast(@alignCast(row)), "item") orelse return));
        const position = c.gtk_list_item_get_position(item);
        if (position == c.GTK_INVALID_LIST_POSITION) return;
        if (l.selecting) {
            _ = c.gtk_gesture_set_state(@ptrCast(@alignCast(gesture)), c.GTK_EVENT_SEQUENCE_CLAIMED);
            if (c.gtk_list_item_get_selected(item) != 0) {
                _ = c.gtk_selection_model_unselect_item(l.selection, position);
            } else {
                _ = c.gtk_selection_model_select_item(l.selection, position, 0);
            }
            return;
        }
        // Pressing the one selected row again brings its details back.
        if (c.gtk_list_item_get_selected(item) != 0 and l.selectedCount() == 1) l.showSelection();
    }

    fn selectedCount(l: *ItemList) u64 {
        const set = c.gtk_selection_model_get_selection(l.selection) orelse return 0;
        defer c.gtk_bitset_unref(set);
        return c.gtk_bitset_get_size(set);
    }

    fn onSelectMode(button: *c.GtkToggleButton, data: ?*anyopaque) callconv(.c) void {
        const l: *ItemList = @ptrCast(@alignCast(data.?));
        l.selecting = c.gtk_toggle_button_get_active(button) != 0;
        var rows = l.bound.keyIterator();
        while (rows.next()) |row| c.gtk_widget_set_visible(gtk.widget(cells(row.*).check), @intFromBool(l.selecting));
        if (!l.selecting) {
            l.clearSelection();
            l.window.hideDetail();
        }
        l.showSelection();
    }

    /// Leaves selection mode (the section changed, or the selection's work is done).
    pub fn endSelecting(l: *ItemList) void {
        if (l.select_button) |b| c.gtk_toggle_button_set_active(@ptrCast(@alignCast(b)), 0);
    }

    // MARK: Events

    fn onActivate(_: *c.GtkListView, position: c.guint, data: ?*anyopaque) callconv(.c) void {
        const l: *ItemList = @ptrCast(@alignCast(data.?));
        if (position >= l.shown.items.len) return;
        const key = l.shown.items[position];
        if (key.len == 0 or key[0] != 'i') return;
        const space = std.mem.indexOfScalar(u8, key, ' ') orelse return;
        const entry = l.by_id.get(key[space + 1 ..]) orelse return;
        l.window.select(entry);
    }

    fn onSearch(entry: *c.GtkSearchEntry, data: ?*anyopaque) callconv(.c) void {
        const l: *ItemList = @ptrCast(@alignCast(data.?));
        l.query = l.a().dupe(u8, std.mem.span(c.gtk_editable_get_text(@ptrCast(@alignCast(entry))))) catch return;
        l.newSearch();
    }

    fn onAdvanced(_: *c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const l: *ItemList = @ptrCast(@alignCast(data.?));
        @import("advanced.zig").Advanced.present(l);
    }

    /// Searches for `text` (e.g. an author from the details pane).
    pub fn searchFor(l: *ItemList, text: []const u8) void {
        if (l.search) |s| c.gtk_editable_set_text(@ptrCast(@alignCast(s)), gtk.z(l.a(), text));
        l.query = l.a().dupe(u8, text) catch return;
        l.newSearch();
    }

    /// A new keyword query starts with the default sort and no filters.
    fn newSearch(l: *ItemList) void {
        l.resetSearch();
        l.reloadWith(false);
    }

    fn resetSearch(l: *ItemList) void {
        l.format = null;
        l.sort = null;
        l.client_sort = null;
        l.search_type = null;
        l.filters = .empty;
        l.sort_ids = &.{};
        l.format_ids = &.{};
        l.facets = &.{};
        capi.biblio_list_set_sort(l.list, .server);
        capi.biblio_list_set_format(l.list, null);
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
        l.format = if (i == 0) null else l.a().dupe(u8, l.format_ids[i]) catch null;
        var fba = std.heap.FixedBufferAllocator.init(&scratch);
        // Searches send the format to the server too; the list filters refined ones locally.
        capi.biblio_list_set_format(l.list, if (l.format) |f| gtk.z(fba.allocator(), f) else null);
        if (l.section == .search or l.section == .new_titles) {
            if (l.clear_button) |b| c.gtk_widget_set_visible(b, @intFromBool(l.filters.items.len > 0 or l.format != null));
            return l.reloadWith(true);
        }
        l.sync();
        if (capi.biblio_list_needs_all_pages(l.list)) l.startBackground();
    }

    fn onFacet(dropdown: *c.GtkDropDown, _: ?*c.GParamSpec, data: ?*anyopaque) callconv(.c) void {
        const l: *ItemList = @ptrCast(@alignCast(data.?));
        if (l.updating) return;
        const index = @intFromPtr(c.g_object_get_data(@ptrCast(@alignCast(dropdown)), "facet"));
        if (index == 0) return;
        const kind = facet_kinds[index - 1];
        const values = l.facet_values[index - 1];
        const i = c.gtk_drop_down_get_selected(dropdown);
        if (i > values.len) return;
        l.setFilter(kind.id, if (i == 0) null else values[i - 1]);
        if (l.clear_button) |b| c.gtk_widget_set_visible(b, @intFromBool(l.filters.items.len > 0 or l.format != null));
        l.reloadWith(true);
    }

    fn onClearFilters(_: *c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const l: *ItemList = @ptrCast(@alignCast(data.?));
        l.filters = .empty;
        l.format = null;
        capi.biblio_list_set_format(l.list, null);
        l.format_ids = &.{};
        l.updateFacetMenus();
        if (l.clear_button) |b| c.gtk_widget_set_visible(b, 0);
        l.reloadWith(true);
    }

    fn onArrival(dropdown: *c.GtkDropDown, _: ?*c.GParamSpec, data: ?*anyopaque) callconv(.c) void {
        const l: *ItemList = @ptrCast(@alignCast(data.?));
        l.on_order = c.gtk_drop_down_get_selected(dropdown) == 1;
        c.adw_window_title_set_subtitle(l.title, if (l.on_order) "On Order" else "");
        l.reloadWith(false);
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

pub const FilterValue = Filter;

/// The bib's title, or "Untitled" if it has none.
pub fn bibTitle(bib: capi.Bib) []const u8 {
    const t = std.mem.span(bib.title);
    return if (t.len > 0) t else "Untitled";
}

/// "Blu-ray Disc · 2026 · Special edition": format, year, and edition, as rows and item detail
/// show them. The edition is left out when it only repeats the format's name.
pub fn formatLine(a: std.mem.Allocator, labels: []const capi.Pair, bib: capi.Bib) []const u8 {
    var parts: std.ArrayList(u8) = .empty;
    const format = core.formatName(a, std.mem.span(bib.format), labels);
    parts.appendSlice(a, format) catch return format;
    if (core.str(bib.publication_date)) |date| parts.print(a, " · {s}", .{core.year(a, date)}) catch {};
    if (core.str(bib.edition)) |edition| if (!std.ascii.eqlIgnoreCase(edition, format)) {
        parts.print(a, " · {s}", .{edition}) catch {};
    };
    return parts.items;
}

/// "2 holds on 3 copies", "3 copies", or "2 holds": only what there is to say.
pub fn peopleWaiting(a: std.mem.Allocator, bib: capi.Bib) []const u8 {
    const held = bib.held_copies;
    const total = bib.total_copies;
    if (held == 0 and total == 0) return "";
    const copies = std.fmt.allocPrint(a, "{d} {s}", .{ total, if (total == 1) "copy" else "copies" }) catch return "";
    if (held == 0) return copies;
    const waiting = std.fmt.allocPrint(a, "{d} {s}", .{ held, if (held == 1) "hold" else "holds" }) catch return "";
    if (total == 0) return waiting;
    return std.fmt.allocPrint(a, "{s} on {s}", .{ waiting, copies }) catch waiting;
}

pub const Relationship = struct { text: []const u8, class: [*:0]const u8, icon: [*:0]const u8 = "bookmark-new-symbolic" };

/// The account's relationship to an item, for its capsule: ready for pickup by a date, in
/// transit, paused, or on hold (each with its place in line), or checked out and due. `held`
/// is a hold placed (true) or canceled (false) since the row was fetched.
pub fn relationship(a: std.mem.Allocator, entry: capi.ListEntry, held: ?bool) Relationship {
    if (held) |h| return if (h) .{ .text = "On hold", .class = "copy-held" } else .{ .text = "", .class = "dim-label" };
    if (entry.hold) |h| {
        const name = std.mem.span(capi.biblio_hold_status_name(h.status));
        const place = if (h.has_position) std.fmt.allocPrint(a, " · #{d} in line", .{h.position}) catch "" else "";
        return switch (capi.biblio_hold_status_rank(h.status)) {
            .ready => .{
                .text = if (core.str(h.pickup_by_date)) |d| std.fmt.allocPrint(a, "{s} by {s}", .{ name, d }) catch name else name,
                .class = "copy-ready",
                .icon = "object-select-symbolic",
            },
            .in_transit => .{ .text = std.fmt.allocPrint(a, "{s}{s}", .{ name, place }) catch name, .class = "copy-transit", .icon = "package-x-generic-symbolic" },
            .paused => .{ .text = std.fmt.allocPrint(a, "{s}{s}", .{ name, place }) catch name, .class = "copy-paused", .icon = "media-playback-pause-symbolic" },
            .waiting => .{ .text = std.fmt.allocPrint(a, "{s}{s}", .{ name, place }) catch name, .class = "copy-held" },
        };
    }
    if (entry.checkout) |co| {
        const due = core.str(co.due_date) orelse return .{ .text = "Checked out", .class = "copy-out", .icon = "alarm-symbolic" };
        return .{ .text = std.fmt.allocPrint(a, "Checked out · due {s}", .{due}) catch "Checked out", .class = "copy-out", .icon = "alarm-symbolic" };
    }
    if (entry.history) |h| {
        if (core.str(h.returned_date)) |d| return .{ .text = std.fmt.allocPrint(a, "Returned {s}", .{d}) catch "", .class = "dim-label" };
        return .{ .text = "", .class = "dim-label" };
    }
    // A catalog row of a title this account holds or has out.
    if (entry.account_status) |s| {
        if (std.mem.eql(u8, std.mem.span(s.kind), "checkedOut")) {
            const due = core.str(s.due) orelse return .{ .text = "Checked out", .class = "copy-out", .icon = "alarm-symbolic" };
            return .{ .text = std.fmt.allocPrint(a, "Checked out · due {s}", .{due}) catch "Checked out", .class = "copy-out", .icon = "alarm-symbolic" };
        }
        if (s.ready) return .{ .text = "Ready for pickup", .class = "copy-ready", .icon = "object-select-symbolic" };
        if (s.has_position) return .{ .text = std.fmt.allocPrint(a, "On hold · #{d} in line", .{s.position}) catch "On hold", .class = "copy-held" };
        return .{ .text = "On hold", .class = "copy-held" };
    }
    return .{ .text = "", .class = "dim-label" };
}

/// "ADULT" as "Adult", "NOT_AVAILABLE" as "Not available".
pub fn prettified(a: std.mem.Allocator, value: []const u8) []const u8 {
    const out = a.alloc(u8, value.len) catch return value;
    for (value, out, 0..) |ch, *o, i| o.* = if (ch == '_') ' ' else if (i == 0) std.ascii.toUpper(ch) else std.ascii.toLower(ch);
    return out;
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

test prettified {
    var buf: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    try std.testing.expectEqualStrings("Not available", prettified(fba.allocator(), "NOT_AVAILABLE"));
}
