//! The selected item's details: jacket, title, this account's status, holds, availability
//! by location (color-coded, always with words and icons too) and the full record.

const std = @import("std");
const gtk = @import("gtk.zig");
const c = gtk.c;
const core = @import("core.zig");
const capi = core.capi;
const Window = @import("window.zig").Window;
const list = @import("list.zig");

const HoldRef = struct { id: [:0]const u8, metadata_id: [:0]const u8, entry_id: []const u8, can_cancel: bool };

pub const Detail = struct {
    window: *Window,
    root: *c.GtkWidget,
    content: *c.GtkWidget,
    arena: std.heap.ArenaAllocator,
    /// A copy of the shown row, in `arena`.
    entry: capi.ListEntry = undefined,
    has_entry: bool = false,
    /// This account's hold on the shown title, if it has one (from the row, else the holds list).
    hold: ?HoldRef = null,
    /// Where the Hold controls go, so they can be rebuilt when the pickup locations arrive.
    actions: ?*c.GtkWidget = null,
    /// A hold was just placed here, before the holds list could say so.
    placed: bool = false,
    generation: u32 = 0,
    pickup: ?*c.GtkDropDown = null,
    pickup_ids: []const []const u8 = &.{},
    hold_button: ?*c.GtkWidget = null,
    /// "You borrowed this in March 2024", under the hold controls.
    borrowed_line: ?*c.GtkWidget = null,
    borrowed_generation: ?u64 = null,
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
        d.borrowed_line = null;
        d.actions = null;
        d.has_entry = true;
        d.placed = false;
        d.hold = d.findHold();
        d.build();
        const id = std.mem.span(d.entry.bib.id);
        if (d.job(&onAvailability)) |j| j.start(capi.biblio_availability, .{ d.window.client, j.z(id) });
        if (d.job(&onDetails)) |j| j.start(capi.biblio_details, .{ d.window.client, j.z(id) });
    }

    /// What a call remembers of the item it was for: the item may change before it returns.
    const Ticket = struct { detail: *Detail, generation: u32, title: [:0]u8, bib_id: [:0]u8, hold_entry_id: []u8 };

    /// A window call whose callback gets this detail's ticket.
    fn job(d: *Detail, callback: core.Callback) ?*core.Job {
        const t = core.gpa.create(Ticket) catch return null;
        const title = core.gpa.dupeSentinel(u8, list.bibTitle(d.entry.bib), 0) catch {
            core.gpa.destroy(t);
            return null;
        };
        const bib_id = core.gpa.dupeSentinel(u8, std.mem.span(d.entry.bib.id), 0) catch {
            core.gpa.destroy(t);
            return null;
        };
        const hold_entry_id = core.gpa.dupe(u8, if (d.hold) |h| h.entry_id else "") catch {
            core.gpa.destroy(t);
            return null;
        };
        t.* = .{ .detail = d, .generation = d.generation, .title = title, .bib_id = bib_id, .hold_entry_id = hold_entry_id };
        return d.window.job(callback, t);
    }

    fn freeTicket(t: *Ticket) void {
        core.gpa.free(t.title);
        core.gpa.free(t.bib_id);
        core.gpa.free(t.hold_entry_id);
        core.gpa.destroy(t);
    }

    /// The detail for a finished call, or null if the window closed or another item is shown.
    fn current(data: ?*anyopaque) ?*Detail {
        const t: *Ticket = @ptrCast(@alignCast(data.?));
        const d = t.detail;
        const generation = t.generation;
        freeTicket(t);
        if (d.window.finishPending()) return null;
        return if (generation == d.generation) d else null;
    }

    /// The shown row, if any.
    pub fn shown(d: *Detail) ?*const capi.ListEntry {
        return if (d.has_entry) &d.entry else null;
    }

    /// The patron or the pickup locations changed: the Hold controls follow.
    pub fn refresh(d: *Detail) void {
        const slot = d.actions orelse return;
        gtk.clearBox(slot);
        d.pickup = null;
        d.hold_button = null;
        d.hold = d.findHold();
        d.buildActions();
    }

    /// The account's hold on the shown title: the row's own, else the holds list's.
    fn findHold(d: *Detail) ?HoldRef {
        const from_row = d.entry.hold;
        const row_entry: ?*const capi.ListEntry = if (from_row != null) &d.entry else d.window.holdFor(std.mem.span(d.entry.bib.id));
        const hold = (if (row_entry) |e| e.hold else null) orelse return null;
        return .{
            .id = d.a().dupeSentinel(u8, std.mem.span(hold.id), 0) catch return null,
            .metadata_id = d.a().dupeSentinel(u8, std.mem.span(hold.metadata_id), 0) catch return null,
            .entry_id = d.a().dupe(u8, std.mem.span(row_entry.?.id)) catch return null,
            .can_cancel = hold.can_cancel,
        };
    }

    fn build(d: *Detail) void {
        const w = d.window;
        const bib = d.entry.bib;

        const top = gtk.box(false, 16);
        const jacket = gtk.jacket(110, 165);
        c.gtk_picture_set_alternative_text(jacket, gtk.z(d.a(), std.fmt.allocPrint(d.a(), "Cover of {s}", .{list.bibTitle(bib)}) catch "Cover"));
        if (core.str(bib.jacket_large) orelse core.str(bib.jacket_small)) |url| list.loadJacket(w, jacket, url);
        gtk.append(top, gtk.clampWidth(jacket, 110));
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
        // Format, year, and edition, a line each beside the cover.
        const format = core.formatName(d.a(), std.mem.span(bib.format), w.labels);
        gtk.append(heading, gtk.label(format, d.a(), &.{"dim-label"}));
        if (core.str(bib.publication_date)) |date| gtk.append(heading, gtk.label(core.year(d.a(), date), d.a(), &.{"dim-label"}));
        if (core.str(bib.edition)) |edition| if (!std.ascii.eqlIgnoreCase(edition, format)) gtk.append(heading, gtk.label(edition, d.a(), &.{"dim-label"}));
        gtk.append(top, heading);
        gtk.append(d.content, top);

        const slot = gtk.box(true, 0);
        gtk.append(d.content, slot);
        d.actions = slot;
        d.buildActions();
        if (w.borrowed != null) {
            const line = gtk.box(false, 6);
            gtk.append(line, c.gtk_image_new_from_icon_name("document-open-recent-symbolic"));
            gtk.append(line, gtk.label("", d.a(), &.{}));
            c.gtk_widget_add_css_class(line, "dim-label");
            gtk.append(d.content, line);
            d.borrowed_line = line;
            d.borrowed_generation = null;
            d.borrowedChanged();
        }

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

    /// The account's relationship to the item (a capsule), then Place Hold with a pickup
    /// location, Cancel Hold, or, for a guest, Sign In to place one.
    fn buildActions(d: *Detail) void {
        const w = d.window;
        const entry = d.entry;
        const slot = d.actions orelse return;
        // Wraps onto more lines when the pane is narrow (a phone).
        const row: *c.GtkWidget = c.adw_wrap_box_new();
        c.adw_wrap_box_set_child_spacing(@ptrCast(@alignCast(row)), 8);
        c.adw_wrap_box_set_line_spacing(@ptrCast(@alignCast(row)), 8);
        const status_kind = if (entry.account_status) |s| std.mem.span(s.kind) else "";
        const checked_out = entry.checkout != null or std.mem.eql(u8, status_kind, "checkedOut");
        const on_hold = d.placed or d.hold != null or entry.hold != null or (entry.account_status != null and !checked_out);
        var rel = list.relationship(d.a(), entry, null);
        if (rel.text.len == 0 and on_hold) rel = .{ .text = "On hold", .class = "copy-held" };
        if (rel.text.len > 0) {
            const capsule = gtk.label(rel.text, d.a(), &.{ "capsule", "caption" });
            c.gtk_widget_add_css_class(capsule, rel.class);
            c.gtk_label_set_wrap(@ptrCast(@alignCast(capsule)), 0);
            c.gtk_widget_set_halign(capsule, c.GTK_ALIGN_START);
            c.gtk_widget_set_valign(capsule, c.GTK_ALIGN_CENTER);
            c.adw_wrap_box_append(@ptrCast(@alignCast(row)), capsule);
        }

        if (on_hold) {
            if (d.hold) |h| if (h.can_cancel) {
                const cancel = c.gtk_button_new_with_mnemonic("_Cancel Hold");
                c.gtk_widget_add_css_class(cancel, "destructive-action");
                c.gtk_widget_add_css_class(cancel, "pill");
                gtk.connect(cancel, "clicked", &onCancelHold, d);
                c.adw_wrap_box_append(@ptrCast(@alignCast(row)), cancel);
                d.hold_button = cancel;
            };
        } else if (checked_out) {
            // Nothing to do from here.
        } else if (w.isGuest()) {
            if (entry.bib.holdable) {
                const sign_in = c.gtk_button_new_with_mnemonic("_Sign In to Place Hold");
                c.gtk_widget_add_css_class(sign_in, "suggested-action");
                c.gtk_widget_add_css_class(sign_in, "pill");
                gtk.connect(sign_in, "clicked", &onGuestHold, d);
                c.adw_wrap_box_append(@ptrCast(@alignCast(row)), sign_in);
            }
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
                c.adw_wrap_box_append(@ptrCast(@alignCast(row)), gtk.widget(dropdown));
                d.pickup = dropdown;
            }
            const place = c.gtk_button_new_with_mnemonic("Place _Hold");
            c.gtk_widget_add_css_class(place, "suggested-action");
            c.gtk_widget_add_css_class(place, "pill");
            gtk.connect(place, "clicked", &onPlaceHold, d);
            c.adw_wrap_box_append(@ptrCast(@alignCast(row)), place);
            d.hold_button = place;
        }
        gtk.append(slot, row);
    }

    /// Says whether the shown item was borrowed before, following the index.
    pub fn borrowedChanged(d: *Detail) void {
        const line = d.borrowed_line orelse return;
        const b = d.window.borrowed orelse return;
        const generation = b.generation();
        if (d.borrowed_generation) |previous| if (previous == generation) return;
        d.borrowed_generation = generation;
        const result = b.lookup(d.entry.bib);
        c.gtk_widget_set_visible(line, @intFromBool(result.match != .none));
        if (result.match == .none) return;
        var buf: [1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const text = @import("borrowed.zig").detailText(fba.allocator(), result, d.window.labels);
        c.gtk_label_set_text(@ptrCast(@alignCast(c.gtk_widget_get_last_child(line))), gtk.z(fba.allocator(), text));
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

    fn onGuestHold(_: *c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const d: *Detail = @ptrCast(@alignCast(data.?));
        d.window.requestSignIn();
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
        defer freeTicket(t);
        const d = t.detail;
        const w = d.window;
        const same = t.generation == d.generation;
        if (w.finishPending()) return;
        if (same) if (d.hold_button) |b| c.gtk_widget_set_sensitive(b, 1);
        if (!r.ok) return w.toast(r.message);
        var buf: [1024]u8 = undefined;
        w.toast(std.fmt.bufPrint(&buf, "Hold placed on “{s}”.", .{t.title}) catch "Hold placed.");
        if (same) {
            d.placed = true;
            d.refresh();
        }
        w.holdsPlaced(&[_][]const u8{t.bib_id});
    }

    /// Asks first, over the button: canceling loses the place in line.
    fn onCancelHold(button: *c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const d: *Detail = @ptrCast(@alignCast(data.?));
        const body = std.fmt.allocPrintSentinel(d.a(), "You will lose your place in line for “{s}”.", .{list.bibTitle(d.entry.bib)}, 0) catch return;
        const dialog = c.adw_alert_dialog_new("Cancel Hold?", body.ptr);
        c.adw_alert_dialog_add_response(@ptrCast(@alignCast(dialog)), "keep", "_Keep Hold");
        c.adw_alert_dialog_add_response(@ptrCast(@alignCast(dialog)), "cancel", "_Cancel Hold");
        c.adw_alert_dialog_set_response_appearance(@ptrCast(@alignCast(dialog)), "cancel", c.ADW_RESPONSE_DESTRUCTIVE);
        c.adw_alert_dialog_set_default_response(@ptrCast(@alignCast(dialog)), "keep");
        c.adw_alert_dialog_set_close_response(@ptrCast(@alignCast(dialog)), "keep");
        gtk.connect(dialog, "response", &onCancelResponse, d);
        c.adw_dialog_present(@ptrCast(@alignCast(dialog)), gtk.widget(button));
    }

    fn onCancelResponse(_: *c.AdwAlertDialog, response: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
        const d: *Detail = @ptrCast(@alignCast(data.?));
        if (!std.mem.eql(u8, std.mem.span(response), "cancel")) return;
        const hold = d.hold orelse return;
        if (d.hold_button) |b| c.gtk_widget_set_sensitive(b, 0);
        const j = d.job(&onHoldCanceled) orelse return;
        const refs = j.new([1]capi.HoldRef{.{ .id = j.z(hold.id), .metadata_id = j.z(hold.metadata_id) }}) orelse return;
        j.start(capi.biblio_cancel_holds, .{ d.window.client, refs, refs.len });
    }

    fn onHoldCanceled(data: ?*anyopaque, r: *core.Result) void {
        const t: *Ticket = @ptrCast(@alignCast(data.?));
        defer freeTicket(t);
        const d = t.detail;
        const w = d.window;
        const same = t.generation == d.generation;
        if (w.finishPending()) return;
        if (same) if (d.hold_button) |b| c.gtk_widget_set_sensitive(b, 1);
        if (!r.ok) return w.toast(r.message);
        const refused = if (r.get(capi.RefusalList)) |l| core.items(capi.Refusal, l.items, l.items_count) else &.{};
        if (refused.len > 0) return w.toast(std.mem.span(refused[0].reason));
        w.toast("Hold canceled.");
        if (same) w.hideDetail();
        const entry_ids: []const []const u8 = if (t.hold_entry_id.len > 0) &[_][]const u8{t.hold_entry_id} else &.{};
        w.holdsCanceled(entry_ids, &[_][]const u8{t.bib_id});
    }
};
