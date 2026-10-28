//! The selected item's details: jacket, title, this account's status, holds, availability
//! by location (color-coded, always with words and icons too) and the full record.

const std = @import("std");
const gtk = @import("gtk.zig");
const c = gtk.c;
const core = @import("core.zig");
const capi = core.capi;
const Window = @import("window.zig").Window;
const list = @import("list.zig");

pub const Detail = struct {
    window: *Window,
    root: *c.GtkWidget,
    content: *c.GtkWidget,
    arena: std.heap.ArenaAllocator,
    /// A copy of the shown row, in `arena`.
    entry: capi.ListEntry = undefined,
    generation: u32 = 0,
    pickup: ?*c.GtkDropDown = null,
    pickup_ids: []const []const u8 = &.{},
    hold_button: ?*c.GtkWidget = null,
    availability: ?*c.AdwPreferencesGroup = null,
    details: ?*c.AdwPreferencesGroup = null,

    pub fn create(w: *Window) *Detail {
        const d = core.gpa.create(Detail) catch unreachable;
        const toolbar = c.adw_toolbar_view_new();
        const header = c.adw_header_bar_new();
        c.adw_header_bar_set_show_title(@ptrCast(@alignCast(header)), 0);
        const close = c.gtk_button_new_from_icon_name("sidebar-show-right-symbolic");
        c.gtk_widget_set_tooltip_text(close, "Hide Details");
        c.adw_header_bar_pack_end(@ptrCast(@alignCast(header)), close);
        c.adw_header_bar_set_show_end_title_buttons(@ptrCast(@alignCast(header)), 0);
        c.adw_toolbar_view_add_top_bar(@ptrCast(@alignCast(toolbar)), header);
        const content = gtk.box(true, 18);
        gtk.margins(content, 18);
        const scroll = c.gtk_scrolled_window_new();
        c.gtk_scrolled_window_set_policy(@ptrCast(@alignCast(scroll)), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
        c.gtk_scrolled_window_set_child(@ptrCast(@alignCast(scroll)), content);
        c.adw_toolbar_view_set_content(@ptrCast(@alignCast(toolbar)), scroll);
        d.* = .{ .window = w, .root = toolbar, .content = content, .arena = .init(core.gpa) };
        gtk.connect(close, "clicked", &onClose, d);
        return d;
    }

    pub fn free(d: *Detail) void {
        d.arena.deinit();
        core.gpa.destroy(d);
    }

    fn a(d: *Detail) std.mem.Allocator {
        return d.arena.allocator();
    }

    fn onClose(_: *c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const d: *Detail = @ptrCast(@alignCast(data.?));
        d.window.hideDetail();
    }

    pub fn showEntry(d: *Detail, entry: *const capi.ListEntry) void {
        d.generation +%= 1;
        gtk.clearBox(d.content);
        _ = d.arena.reset(.retain_capacity);
        // Keep a copy: the list the entry came from may reload while it is shown.
        d.entry = core.copy(d.a(), entry.*);
        d.pickup = null;
        d.hold_button = null;
        d.build();
        const id = std.mem.span(d.entry.bib.id);
        if (d.job(&onAvailability)) |j| j.start(capi.biblio_availability, .{ d.window.client, j.z(id) });
        if (d.job(&onDetails)) |j| j.start(capi.biblio_details, .{ d.window.client, j.z(id) });
    }

    const Ticket = struct { detail: *Detail, generation: u32 };

    /// A window call whose callback gets this detail's ticket.
    fn job(d: *Detail, callback: core.Callback) ?*core.Job {
        const t = core.gpa.create(Ticket) catch return null;
        t.* = .{ .detail = d, .generation = d.generation };
        return d.window.job(callback, t);
    }

    /// The detail for a finished call, or null if the window closed or another item is shown.
    fn current(data: ?*anyopaque) ?*Detail {
        const t: *Ticket = @ptrCast(@alignCast(data.?));
        const d = t.detail;
        const generation = t.generation;
        core.gpa.destroy(t);
        if (d.window.finishPending()) return null;
        return if (generation == d.generation) d else null;
    }

    fn build(d: *Detail) void {
        const w = d.window;
        const bib = d.entry.bib;

        const top = gtk.box(false, 16);
        const jacket: *c.GtkPicture = @ptrCast(@alignCast(c.gtk_picture_new()));
        c.gtk_picture_set_content_fit(jacket, c.GTK_CONTENT_FIT_CONTAIN);
        c.gtk_widget_set_size_request(gtk.widget(jacket), 110, 165);
        c.gtk_widget_set_valign(gtk.widget(jacket), c.GTK_ALIGN_START);
        c.gtk_widget_add_css_class(gtk.widget(jacket), "jacket");
        if (core.str(bib.jacket_large) orelse core.str(bib.jacket_small)) |url| list.loadJacket(w, jacket, url);
        gtk.append(top, gtk.widget(jacket));
        const heading = gtk.box(true, 4);
        c.gtk_widget_set_hexpand(heading, 1);
        gtk.append(heading, gtk.label(list.bibTitle(bib), d.a(), &.{"title-2"}));
        if (core.str(bib.subtitle)) |s| gtk.append(heading, gtk.label(s, d.a(), &.{"dim-label"}));
        const authors = core.items([*:0]const u8, bib.authors, bib.authors_count);
        if (authors.len > 0) {
            // Authors link to a search for their other works.
            const author = c.gtk_button_new_with_label(authors[0]);
            c.gtk_widget_add_css_class(author, "flat");
            c.gtk_widget_set_halign(author, c.GTK_ALIGN_START);
            c.gtk_widget_set_tooltip_text(author, "Search for this author");
            c.g_object_set_data_full(@ptrCast(@alignCast(author)), "author", c.g_strdup(authors[0]), c.g_free);
            gtk.connect(author, "clicked", &onAuthor, d);
            gtk.append(heading, author);
        }
        var meta = core.formatName(d.a(), std.mem.span(bib.format), w.labels);
        if (core.str(bib.publication_date)) |date| meta = std.fmt.allocPrint(d.a(), "{s} · {s}", .{ meta, list.year(date) }) catch meta;
        gtk.append(heading, gtk.label(meta, d.a(), &.{"dim-label"}));
        gtk.append(top, heading);
        gtk.append(d.content, top);

        d.buildActions();

        if (core.str(bib.summary)) |summary| {
            const l = gtk.label(summary, d.a(), &.{"body"});
            c.gtk_label_set_selectable(@ptrCast(@alignCast(l)), 1);
            gtk.append(d.content, l);
        }

        const availability: *c.AdwPreferencesGroup = @ptrCast(@alignCast(c.adw_preferences_group_new()));
        c.adw_preferences_group_set_title(availability, "Availability by Location");
        const loading = c.adw_spinner_new();
        c.adw_preferences_group_set_header_suffix(availability, loading);
        gtk.append(d.content, gtk.widget(availability));
        d.availability = availability;

        const details: *c.AdwPreferencesGroup = @ptrCast(@alignCast(c.adw_preferences_group_new()));
        c.adw_preferences_group_set_title(details, "Details");
        c.gtk_widget_set_visible(gtk.widget(details), 0);
        gtk.append(d.content, gtk.widget(details));
        d.details = details;
    }

    /// Place a hold (choosing where to pick it up), or cancel this account's hold.
    fn buildActions(d: *Detail) void {
        const w = d.window;
        const entry = d.entry;
        const row = gtk.box(false, 8);

        if (entry.hold) |hold| {
            const ready = if (entry.account_status) |s| s.ready else false;
            const status = gtk.label(if (ready) "Ready for pickup" else "On hold", d.a(), &.{"heading"});
            c.gtk_widget_set_hexpand(status, 1);
            gtk.append(row, status);
            if (hold.can_cancel) {
                const cancel = c.gtk_button_new_with_mnemonic("_Cancel Hold");
                c.gtk_widget_add_css_class(cancel, "destructive-action");
                c.gtk_widget_add_css_class(cancel, "pill");
                gtk.connect(cancel, "clicked", &onCancelHold, d);
                gtk.append(row, cancel);
                d.hold_button = cancel;
            }
        } else if (entry.checkout) |checkout| {
            const due = core.str(checkout.due_date);
            const text = if (due) |dd| std.fmt.allocPrint(d.a(), "Checked out · due {s}", .{dd}) catch "Checked out" else "Checked out";
            gtk.append(row, gtk.label(text, d.a(), &.{"heading"}));
        } else if (w.isGuest()) {
            gtk.append(row, gtk.label("Sign in to place holds.", d.a(), &.{"dim-label"}));
        } else if (entry.bib.holdable) {
            // Pickup location, defaulting to the account's preferred one.
            var names: std.ArrayList(?[*:0]const u8) = .empty;
            var ids: std.ArrayList([]const u8) = .empty;
            var selected: c.guint = 0;
            const preferred = if (w.patron) |p| core.str(p.preferred_pickup) else null;
            for (w.locations) |loc| {
                const id = std.mem.span(loc.id);
                if (preferred) |p| if (std.mem.eql(u8, p, id)) {
                    selected = @intCast(ids.items.len);
                };
                ids.append(d.a(), id) catch continue;
                names.append(d.a(), loc.name) catch {};
            }
            names.append(d.a(), null) catch {};
            d.pickup_ids = ids.items;
            if (ids.items.len > 0) {
                const dropdown: *c.GtkDropDown = @ptrCast(@alignCast(c.gtk_drop_down_new(@ptrCast(c.gtk_string_list_new(@ptrCast(names.items.ptr))), null)));
                c.gtk_drop_down_set_selected(dropdown, selected);
                c.gtk_widget_set_tooltip_text(gtk.widget(dropdown), "Pickup location");
                c.gtk_widget_set_hexpand(gtk.widget(dropdown), 1);
                gtk.append(row, gtk.widget(dropdown));
                d.pickup = dropdown;
            }
            const place = c.gtk_button_new_with_mnemonic("Place _Hold");
            c.gtk_widget_add_css_class(place, "suggested-action");
            c.gtk_widget_add_css_class(place, "pill");
            gtk.connect(place, "clicked", &onPlaceHold, d);
            gtk.append(row, place);
            d.hold_button = place;
        }
        gtk.append(d.content, row);
    }

    // MARK: Results

    fn onAvailability(data: ?*anyopaque, r: *core.Result) void {
        const d = current(data) orelse return;
        const group = d.availability orelse return;
        c.adw_preferences_group_set_header_suffix(group, null);
        if (!r.ok) {
            c.adw_preferences_group_set_description(group, gtk.z(d.a(), r.message));
            return;
        }
        const copies = if (r.get(capi.CopyList)) |l| core.items(capi.Copy, l.items, l.items_count) else &.{};
        if (copies.len == 0) c.adw_preferences_group_set_description(group, "No copies listed.");
        for (copies) |copy| {
            const row = c.adw_action_row_new();
            const branch = std.mem.span(copy.branch);
            c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), if (branch.len > 0) copy.branch else "—");
            var parts: std.ArrayList(u8) = .empty;
            for ([_]?[*:0]const u8{ copy.collection, copy.call_number }) |field| if (core.str(field)) |v| {
                if (parts.items.len > 0) parts.appendSlice(d.a(), " · ") catch {};
                parts.appendSlice(d.a(), v) catch {};
            };
            if (core.str(copy.due_date)) |due| {
                if (parts.items.len > 0) parts.appendSlice(d.a(), " · ") catch {};
                parts.print(d.a(), "due {s}", .{due}) catch {};
            }
            if (parts.items.len > 0) c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), gtk.z(d.a(), parts.items));
            const kind = std.mem.span(copy.kind);
            const class = gtk.z(d.a(), std.fmt.allocPrint(d.a(), "copy-{s}", .{kind}) catch "copy-other");
            const icon = c.gtk_image_new_from_icon_name(kindIcon(kind));
            c.gtk_widget_add_css_class(icon, class);
            c.adw_action_row_add_prefix(@ptrCast(@alignCast(row)), icon);
            const status = gtk.label(std.mem.span(copy.status), d.a(), &.{class});
            c.gtk_label_set_wrap(@ptrCast(@alignCast(status)), 0);
            c.adw_action_row_add_suffix(@ptrCast(@alignCast(row)), status);
            c.adw_preferences_group_add(group, row);
        }
    }

    fn kindIcon(kind: []const u8) [*:0]const u8 {
        const map = std.StaticStringMap([*:0]const u8).initComptime(.{
            .{ "available", "object-select-symbolic" },
            .{ "onOrder", "package-x-generic-symbolic" },
            .{ "out", "alarm-symbolic" },
            .{ "held", "bookmark-new-symbolic" },
            .{ "transit", "media-playlist-shuffle-symbolic" },
            .{ "repair", "applications-engineering-symbolic" },
            .{ "missing", "dialog-question-symbolic" },
            .{ "withdrawn", "window-close-symbolic" },
            .{ "claimsReturned", "dialog-warning-symbolic" },
            .{ "libraryUseOnly", "user-home-symbolic" },
        });
        return map.get(kind) orelse "media-record-symbolic";
    }

    fn onDetails(data: ?*anyopaque, r: *core.Result) void {
        const d = current(data) orelse return;
        const group = d.details orelse return;
        if (!r.ok) return;
        const fields = if (r.get(capi.DetailList)) |l| core.items(capi.DetailField, l.items, l.items_count) else &.{};
        for (fields) |f| {
            var values: std.ArrayList(u8) = .empty;
            for (core.items([*:0]const u8, f.values, f.values_count)) |v| {
                if (values.items.len > 0) values.append(d.a(), '\n') catch {};
                values.appendSlice(d.a(), std.mem.span(v)) catch {};
            }
            const row = c.adw_action_row_new();
            c.adw_action_row_set_subtitle_selectable(@ptrCast(@alignCast(row)), 1);
            c.gtk_widget_add_css_class(row, "property");
            c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), f.label);
            c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), gtk.z(d.a(), values.items));
            c.adw_preferences_group_add(group, row);
        }
        c.gtk_widget_set_visible(gtk.widget(group), @intFromBool(fields.len > 0));
    }

    // MARK: Actions

    fn onAuthor(button: *c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const d: *Detail = @ptrCast(@alignCast(data.?));
        const author: [*:0]const u8 = @ptrCast(@alignCast(c.g_object_get_data(@ptrCast(button), "author") orelse return));
        const search = d.window.list(.search) orelse return;
        d.window.show(.search);
        search.searchFor(std.mem.span(author));
    }

    fn onPlaceHold(button: *c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const d: *Detail = @ptrCast(@alignCast(data.?));
        const bib = d.entry.bib;
        var pickup: ?[]const u8 = null;
        if (d.pickup) |dd| {
            const i = c.gtk_drop_down_get_selected(dd);
            if (i < d.pickup_ids.len) pickup = d.pickup_ids[i];
        }
        c.gtk_widget_set_sensitive(gtk.widget(button), 0);
        const j = d.job(&onHoldPlaced) orelse return;
        j.start(capi.biblio_place_hold, .{ d.window.client, j.z(std.mem.span(bib.id)), j.z(std.mem.span(bib.material_type)), j.optZ(pickup) });
    }

    fn onHoldPlaced(data: ?*anyopaque, r: *core.Result) void {
        const t: *Ticket = @ptrCast(@alignCast(data.?));
        const d = t.detail;
        const w = d.window;
        const same = t.generation == d.generation;
        core.gpa.destroy(t);
        if (w.finishPending()) return;
        if (same) if (d.hold_button) |b| c.gtk_widget_set_sensitive(b, 1);
        if (!r.ok) return w.toast(r.message);
        const title = list.bibTitle(d.entry.bib);
        w.toast(std.fmt.allocPrint(d.a(), "Hold placed on “{s}”.", .{title}) catch "Hold placed.");
        if (same) if (d.hold_button) |b| c.gtk_widget_set_visible(b, 0);
        w.holdsChanged();
    }

    fn onCancelHold(button: *c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const d: *Detail = @ptrCast(@alignCast(data.?));
        const hold = d.entry.hold orelse return;
        c.gtk_widget_set_sensitive(gtk.widget(button), 0);
        const j = d.job(&onHoldCancelled) orelse return;
        const refs = j.new([1]capi.HoldRef{.{ .id = j.z(std.mem.span(hold.id)), .metadata_id = j.z(std.mem.span(hold.metadata_id)) }}) orelse return;
        j.start(capi.biblio_cancel_holds, .{ d.window.client, refs, refs.len });
    }

    fn onHoldCancelled(data: ?*anyopaque, r: *core.Result) void {
        const t: *Ticket = @ptrCast(@alignCast(data.?));
        const d = t.detail;
        const w = d.window;
        const same = t.generation == d.generation;
        core.gpa.destroy(t);
        if (w.finishPending()) return;
        if (same) if (d.hold_button) |b| c.gtk_widget_set_sensitive(b, 1);
        if (!r.ok) return w.toast(r.message);
        const refused = if (r.get(capi.RefusalList)) |l| core.items(capi.Refusal, l.items, l.items_count) else &.{};
        if (refused.len > 0) return w.toast(std.mem.span(refused[0].reason));
        w.toast("Hold cancelled.");
        if (same) w.hideDetail();
        w.holdsChanged();
    }
};
