//! The selected item's details: jacket, title, this account's status, holds, availability
//! by location (color-coded, always with words and icons too) and the full record.

const std = @import("std");
const gtk = @import("gtk.zig");
const c = gtk.c;
const core = @import("core.zig");
const Window = @import("window.zig").Window;
const list = @import("list.zig");

pub const Detail = struct {
    window: *Window,
    root: *c.GtkWidget,
    content: *c.GtkWidget,
    arena: std.heap.ArenaAllocator,
    entry: std.json.Value = .null,
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

    pub fn showEntry(d: *Detail, entry: std.json.Value) void {
        d.generation +%= 1;
        gtk.clearBox(d.content);
        _ = d.arena.reset(.retain_capacity);
        // Keep a copy: the list the entry came from may reload while it is shown.
        const text = std.json.Stringify.valueAlloc(d.a(), entry, .{}) catch return;
        d.entry = std.json.parseFromSliceLeaky(std.json.Value, d.a(), text, .{}) catch return;
        d.pickup = null;
        d.hold_button = null;
        d.build();
        const bib = core.field(d.entry, "bib");
        const id = core.str(bib, "id") orelse return;
        d.request(.{ .op = "availability", .metadataId = id }, &onAvailability);
        d.request(.{ .op = "details", .metadataId = id }, &onDetails);
    }

    const Ticket = struct { detail: *Detail, generation: u32 };

    fn request(d: *Detail, req: anytype, callback: core.Callback) void {
        const t = core.gpa.create(Ticket) catch return;
        t.* = .{ .detail = d, .generation = d.generation };
        d.window.call(req, callback, t);
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
        const entry = d.entry;
        const bib = core.field(entry, "bib");

        const top = gtk.box(false, 16);
        const jacket: *c.GtkPicture = @ptrCast(@alignCast(c.gtk_picture_new()));
        c.gtk_picture_set_content_fit(jacket, c.GTK_CONTENT_FIT_CONTAIN);
        c.gtk_widget_set_size_request(gtk.widget(jacket), 110, 165);
        c.gtk_widget_set_valign(gtk.widget(jacket), c.GTK_ALIGN_START);
        c.gtk_widget_add_css_class(gtk.widget(jacket), "jacket");
        if (core.str(bib, "jacketLarge") orelse core.str(bib, "jacketSmall")) |url| list.loadJacket(w, jacket, url);
        gtk.append(top, gtk.widget(jacket));
        const heading = gtk.box(true, 4);
        c.gtk_widget_set_hexpand(heading, 1);
        gtk.append(heading, gtk.label(core.str(bib, "title") orelse "Untitled", d.a(), &.{"title-2"}));
        if (core.str(bib, "subtitle")) |s| gtk.append(heading, gtk.label(s, d.a(), &.{"dim-label"}));
        const authors = core.items(core.field(bib, "authors"));
        if (authors.len > 0 and authors[0] == .string) {
            // Authors link to a search for their other works.
            const author = c.gtk_button_new_with_label(gtk.z(d.a(), authors[0].string));
            c.gtk_widget_add_css_class(author, "flat");
            c.gtk_widget_set_halign(author, c.GTK_ALIGN_START);
            c.gtk_widget_set_tooltip_text(author, "Search for this author");
            c.g_object_set_data_full(@ptrCast(@alignCast(author)), "author", c.g_strdup(gtk.z(d.a(), authors[0].string)), c.g_free);
            gtk.connect(author, "clicked", &onAuthor, d);
            gtk.append(heading, author);
        }
        const code = core.str(bib, "format") orelse "UNKNOWN";
        const format = core.now(d.a(), .{ .op = "formatName", .code = code, .labels = w.libraryLabels() });
        var meta: []const u8 = if (format) |f| if (f == .string) f.string else code else code;
        if (core.str(bib, "publicationDate")) |date| meta = std.fmt.allocPrint(d.a(), "{s} · {s}", .{ meta, list.year(date) }) catch meta;
        gtk.append(heading, gtk.label(meta, d.a(), &.{"dim-label"}));
        gtk.append(top, heading);
        gtk.append(d.content, top);

        d.buildActions();

        if (core.str(bib, "summary")) |summary| {
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
        const bib = core.field(entry, "bib");
        const row = gtk.box(false, 8);

        const hold = core.field(entry, "hold");
        if (hold != null) {
            const status = gtk.label(if (core.boolean(core.field(entry, "accountStatus"), "ready") == true) "Ready for pickup" else "On hold", d.a(), &.{"heading"});
            c.gtk_widget_set_hexpand(status, 1);
            gtk.append(row, status);
            if (core.boolean(hold, "canCancel") != false) {
                const cancel = c.gtk_button_new_with_mnemonic("_Cancel Hold");
                c.gtk_widget_add_css_class(cancel, "destructive-action");
                c.gtk_widget_add_css_class(cancel, "pill");
                gtk.connect(cancel, "clicked", &onCancelHold, d);
                gtk.append(row, cancel);
                d.hold_button = cancel;
            }
        } else if (core.field(entry, "checkout")) |checkout| {
            const due = core.str(checkout, "dueDate");
            const text = if (due) |dd| std.fmt.allocPrint(d.a(), "Checked out · due {s}", .{dd}) catch "Checked out" else "Checked out";
            gtk.append(row, gtk.label(text, d.a(), &.{"heading"}));
        } else if (w.isGuest()) {
            gtk.append(row, gtk.label("Sign in to place holds.", d.a(), &.{"dim-label"}));
        } else if (core.boolean(bib, "holdable") != false) {
            // Pickup location, defaulting to the account's preferred one.
            var names: std.ArrayList(?[*:0]const u8) = .empty;
            var ids: std.ArrayList([]const u8) = .empty;
            var selected: c.guint = 0;
            const preferred = core.str(w.patron, "preferredPickup");
            for (w.locations) |loc| {
                const id = core.str(loc, "id") orelse continue;
                if (preferred) |p| if (std.mem.eql(u8, p, id)) {
                    selected = @intCast(ids.items.len);
                };
                ids.append(d.a(), id) catch continue;
                names.append(d.a(), gtk.z(d.a(), core.str(loc, "name") orelse id)) catch {};
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
        const copies = core.items(r.value);
        if (copies.len == 0) c.adw_preferences_group_set_description(group, "No copies listed.");
        for (copies) |copy| {
            const row = c.adw_action_row_new();
            c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), gtk.z(d.a(), core.str(copy, "branch") orelse "—"));
            var parts: std.ArrayList(u8) = .empty;
            for ([_][]const u8{ "collection", "callNumber" }) |key| if (core.str(copy, key)) |v| {
                if (parts.items.len > 0) parts.appendSlice(d.a(), " · ") catch {};
                parts.appendSlice(d.a(), v) catch {};
            };
            if (core.str(copy, "dueDate")) |due| {
                if (parts.items.len > 0) parts.appendSlice(d.a(), " · ") catch {};
                parts.print(d.a(), "due {s}", .{due}) catch {};
            }
            if (parts.items.len > 0) c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), gtk.z(d.a(), parts.items));
            const kind = core.str(copy, "kind") orelse "other";
            const class = gtk.z(d.a(), std.fmt.allocPrint(d.a(), "copy-{s}", .{kind}) catch "copy-other");
            const icon = c.gtk_image_new_from_icon_name(kindIcon(kind));
            c.gtk_widget_add_css_class(icon, class);
            c.adw_action_row_add_prefix(@ptrCast(@alignCast(row)), icon);
            const status = gtk.label(core.str(copy, "status") orelse "", d.a(), &.{class});
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
        for (core.items(r.value)) |f| {
            var values: std.ArrayList(u8) = .empty;
            for (core.items(core.field(f, "values"))) |v| if (v == .string) {
                if (values.items.len > 0) values.append(d.a(), '\n') catch {};
                values.appendSlice(d.a(), v.string) catch {};
            };
            const row = c.adw_action_row_new();
            c.adw_action_row_set_subtitle_selectable(@ptrCast(@alignCast(row)), 1);
            c.gtk_widget_add_css_class(row, "property");
            c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), gtk.z(d.a(), core.str(f, "label") orelse ""));
            c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), gtk.z(d.a(), values.items));
            c.adw_preferences_group_add(group, row);
        }
        c.gtk_widget_set_visible(gtk.widget(group), @intFromBool(core.items(r.value).len > 0));
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
        const bib = core.field(d.entry, "bib");
        var pickup: ?[]const u8 = null;
        if (d.pickup) |dd| {
            const i = c.gtk_drop_down_get_selected(dd);
            if (i < d.pickup_ids.len) pickup = d.pickup_ids[i];
        }
        c.gtk_widget_set_sensitive(gtk.widget(button), 0);
        d.request(.{
            .op = "placeHold",
            .metadataId = core.str(bib, "id") orelse "",
            .materialType = core.str(bib, "materialType") orelse "PHYSICAL",
            .pickupBranch = pickup,
        }, &onHoldPlaced);
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
        const title = core.str(core.field(d.entry, "bib"), "title") orelse "the item";
        w.toast(std.fmt.allocPrint(d.a(), "Hold placed on “{s}”.", .{title}) catch "Hold placed.");
        if (same) if (d.hold_button) |b| c.gtk_widget_set_visible(b, 0);
        w.holdsChanged();
    }

    fn onCancelHold(button: *c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const d: *Detail = @ptrCast(@alignCast(data.?));
        const hold = core.field(d.entry, "hold") orelse return;
        c.gtk_widget_set_sensitive(gtk.widget(button), 0);
        const Ref = struct { id: []const u8, metadataId: []const u8 };
        const refs = [_]Ref{.{ .id = core.str(hold, "id") orelse "", .metadataId = core.str(hold, "metadataId") orelse "" }};
        d.request(.{ .op = "cancelHolds", .holds = refs }, &onHoldCancelled);
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
        const refused = core.items(core.field(r.value, "refused"));
        if (refused.len > 0) return w.toast(core.str(refused[0], "reason") orelse "The library didn’t cancel this hold.");
        w.toast("Hold cancelled.");
        if (same) w.hideDetail();
        w.holdsChanged();
    }
};
