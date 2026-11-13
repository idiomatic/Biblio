//! Several selected rows: a bottom action bar under the list (GNOME's pattern for selection
//! mode, wrapping onto a second line when narrow) that places holds on the catalog's selection, or cancels the selected holds.
//!
//! Holds are placed one request at a time (the core paces them), stopping at the library's
//! limit, and the result says what was and wasn't done, and why.

const std = @import("std");
const gtk = @import("gtk.zig");
const c = gtk.c;
const core = @import("core.zig");
const capi = core.capi;
const Window = @import("window.zig").Window;
const ItemList = @import("list.zig").ItemList;

/// What the bar needs of a selected row, copied so it outlives the list's pages.
const Item = struct {
    bib_id: []const u8,
    material: []const u8,
    title: []const u8,
    /// A hold's id, its title's id, and its row's id in the holds list.
    hold_id: []const u8 = "",
    metadata_id: []const u8 = "",
    entry_id: []const u8 = "",
    /// Can have a hold placed (catalog) or canceled (holds).
    eligible: bool,
};

pub const Multi = struct {
    window: *Window,
    list: *ItemList,
    root: *c.GtkWidget,
    label: *c.GtkLabel,
    pickup: ?*c.GtkDropDown = null,
    primary: *c.GtkWidget,
    spinner: *c.GtkWidget,
    /// The current selection.
    selection_arena: std.heap.ArenaAllocator,
    items: []const Item = &.{},
    /// Pickup locations in the menu, rebuilt when the window learns them.
    pickup_ids: []const []const u8 = &.{},
    /// The batch under way.
    batch_arena: std.heap.ArenaAllocator,
    batch: []const Item = &.{},
    pickup_choice: ?[]const u8 = null,
    next: usize = 0,
    placed: std.ArrayList([]const u8) = .empty,
    failures: usize = 0,
    first_failure: []const u8 = "",
    limit_reached: bool = false,
    skipped: usize = 0,
    busy: bool = false,

    pub fn create(w: *Window, l: *ItemList) *Multi {
        const m = core.gpa.create(Multi) catch unreachable;
        // A GtkActionBar asks for the width of everything in it, hidden or not; a wrap box
        // asks only for its widest child.
        const bar = c.adw_wrap_box_new();
        c.adw_wrap_box_set_child_spacing(@ptrCast(@alignCast(bar)), 12);
        c.adw_wrap_box_set_line_spacing(@ptrCast(@alignCast(bar)), 6);
        c.gtk_widget_add_css_class(bar, "toolbar");
        const label: *c.GtkLabel = @ptrCast(@alignCast(c.gtk_label_new("")));
        c.gtk_widget_add_css_class(gtk.widget(label), "heading");
        c.gtk_widget_set_valign(gtk.widget(label), c.GTK_ALIGN_CENTER);
        c.adw_wrap_box_append(@ptrCast(@alignCast(bar)), gtk.widget(label));
        const spinner = c.adw_spinner_new();
        c.gtk_widget_set_visible(spinner, 0);
        c.adw_wrap_box_append(@ptrCast(@alignCast(bar)), spinner);
        const holds = l.section == .holds;
        const primary = c.gtk_button_new_with_mnemonic(if (holds) "_Cancel Holds" else "Place _Holds");
        c.gtk_widget_add_css_class(primary, if (holds) "destructive-action" else "suggested-action");
        c.adw_wrap_box_append(@ptrCast(@alignCast(bar)), primary);
        m.* = .{
            .window = w,
            .list = l,
            .root = bar,
            .label = label,
            .primary = primary,
            .spinner = spinner,
            .selection_arena = .init(core.gpa),
            .batch_arena = .init(core.gpa),
        };
        if (!holds and !w.isGuest()) {
            const dropdown: *c.GtkDropDown = @ptrCast(@alignCast(c.gtk_drop_down_new(null, null)));
            c.gtk_widget_set_tooltip_text(gtk.widget(dropdown), "Pickup location");
            c.adw_wrap_box_append(@ptrCast(@alignCast(bar)), gtk.widget(dropdown));
            m.pickup = dropdown;
        }
        gtk.connect(primary, "clicked", &onPrimary, m);
        const separator = c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL);
        const column = gtk.box(true, 0);
        gtk.append(column, separator);
        gtk.append(column, bar);
        const revealer = c.gtk_revealer_new();
        c.gtk_revealer_set_transition_type(@ptrCast(@alignCast(revealer)), c.GTK_REVEALER_TRANSITION_TYPE_SLIDE_UP);
        c.gtk_revealer_set_child(@ptrCast(@alignCast(revealer)), column);
        m.root = revealer;
        return m;
    }

    pub fn free(m: *Multi) void {
        m.selection_arena.deinit();
        m.batch_arena.deinit();
        if (m.pickup_ids.len > 0) core.gpa.free(m.pickup_ids);
        core.gpa.destroy(m);
    }

    // MARK: The selection

    /// The selected rows changed (or selection mode did).
    pub fn update(m: *Multi, entries: []const *const capi.ListEntry) void {
        if (m.busy) return;
        const show = m.list.selecting or entries.len >= 2;
        c.gtk_revealer_set_reveal_child(@ptrCast(@alignCast(m.root)), @intFromBool(show));
        _ = m.selection_arena.reset(.retain_capacity);
        const sa = m.selection_arena.allocator();
        var items: std.ArrayList(Item) = .empty;
        var eligible: usize = 0;
        for (entries) |entry| {
            const holds = m.list.section == .holds;
            const can = if (holds)
                (if (entry.hold) |h| h.can_cancel else false)
            else
                entry.bib.holdable and entry.hold == null and entry.checkout == null and entry.account_status == null and
                    !(m.list.held.get(std.mem.span(entry.bib.id)) orelse false);
            const hold = entry.hold;
            items.append(sa, .{
                .bib_id = sa.dupe(u8, std.mem.span(entry.bib.id)) catch continue,
                .material = sa.dupe(u8, std.mem.span(entry.bib.material_type)) catch continue,
                .title = sa.dupe(u8, std.mem.span(entry.bib.title)) catch continue,
                .hold_id = if (hold) |h| sa.dupe(u8, std.mem.span(h.id)) catch continue else "",
                .metadata_id = if (hold) |h| sa.dupe(u8, std.mem.span(h.metadata_id)) catch continue else "",
                .entry_id = sa.dupe(u8, std.mem.span(entry.id)) catch continue,
                .eligible = can,
            }) catch {};
            if (can) eligible += 1;
        }
        m.items = items.items;
        m.showCounts(entries.len, eligible);
    }

    fn showCounts(m: *Multi, selected: usize, eligible: usize) void {
        var buf: [256]u8 = undefined;
        const holds = m.list.section == .holds;
        const text = if (selected == 0)
            "Select Items"
        else if (selected == 1)
            "1 Selected"
        else
            std.fmt.bufPrint(&buf, "{d} Selected", .{selected}) catch "Selected";
        var z: [256]u8 = undefined;
        @memcpy(z[0..text.len], text);
        z[text.len] = 0;
        c.gtk_label_set_text(m.label, @ptrCast(&z));
        if (m.window.isGuest()) {
            c.gtk_button_set_label(@ptrCast(@alignCast(m.primary)), "_Sign In to Place Holds");
            c.gtk_button_set_use_underline(@ptrCast(@alignCast(m.primary)), 1);
            c.gtk_widget_set_sensitive(m.primary, @intFromBool(selected > 0));
            return;
        }
        var label_buf: [64]u8 = undefined;
        const word = if (holds) "Cancel" else "Place";
        const noun = if (eligible == 1) "Hold" else "Holds";
        const button = if (eligible > 1)
            std.fmt.bufPrintSentinel(&label_buf, "_{s} {d} {s}", .{ word, eligible, noun }, 0) catch "_Place Holds"
        else
            std.fmt.bufPrintSentinel(&label_buf, "_{s} {s}", .{ word, noun }, 0) catch "_Place Holds";
        c.gtk_button_set_label(@ptrCast(@alignCast(m.primary)), button.ptr);
        c.gtk_button_set_use_underline(@ptrCast(@alignCast(m.primary)), 1);
        c.gtk_widget_set_sensitive(m.primary, @intFromBool(eligible > 0));
        m.fillPickup();
    }

    /// The pickup menu: the library's locations, the account's preferred one first chosen.
    fn fillPickup(m: *Multi) void {
        const dropdown = m.pickup orelse return;
        const w = m.window;
        if (w.locations.len == 0 or m.pickup_ids.len == w.locations.len) return;
        const sa = m.selection_arena.allocator();
        var ids: std.ArrayList([]const u8) = .empty;
        var names: std.ArrayList(?[*:0]const u8) = .empty;
        var selected: c.guint = 0;
        const preferred = if (w.patron) |p| core.str(p.preferred_pickup) else null;
        for (w.locations) |loc| {
            const id = std.mem.span(loc.id);
            if (preferred) |p| if (std.mem.eql(u8, p, id)) {
                selected = @intCast(ids.items.len);
            };
            ids.append(core.gpa, id) catch continue;
            names.append(sa, loc.name) catch {};
        }
        names.append(sa, null) catch {};
        if (m.pickup_ids.len > 0) core.gpa.free(m.pickup_ids);
        m.pickup_ids = ids.toOwnedSlice(core.gpa) catch &.{};
        c.gtk_drop_down_set_model(dropdown, @ptrCast(@alignCast(c.gtk_string_list_new(@ptrCast(names.items.ptr)))));
        c.gtk_drop_down_set_selected(dropdown, selected);
    }

    fn onPrimary(_: *c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const m: *Multi = @ptrCast(@alignCast(data.?));
        if (m.busy) return;
        if (m.window.isGuest()) return m.window.requestSignIn();
        if (m.list.section == .holds) return m.confirmCancel();
        m.startPlacing();
    }

    fn setBusy(m: *Multi, busy: bool) void {
        m.busy = busy;
        c.gtk_widget_set_visible(m.spinner, @intFromBool(busy));
        c.gtk_widget_set_sensitive(m.primary, @intFromBool(!busy));
        if (m.pickup) |p| c.gtk_widget_set_sensitive(gtk.widget(p), @intFromBool(!busy));
    }

    /// Copies the selection's eligible items into a batch.
    fn startBatch(m: *Multi) bool {
        _ = m.batch_arena.reset(.retain_capacity);
        const ba = m.batch_arena.allocator();
        var items: std.ArrayList(Item) = .empty;
        m.skipped = 0;
        for (m.items) |item| {
            if (!item.eligible) {
                m.skipped += 1;
                continue;
            }
            var copy = item;
            inline for (.{ "bib_id", "material", "title", "hold_id", "metadata_id", "entry_id" }) |field| {
                @field(copy, field) = ba.dupe(u8, @field(item, field)) catch return false;
            }
            items.append(ba, copy) catch return false;
        }
        m.batch = items.items;
        m.placed = .empty;
        m.next = 0;
        m.failures = 0;
        m.first_failure = "";
        m.limit_reached = false;
        return m.batch.len > 0;
    }

    // MARK: Placing holds

    fn startPlacing(m: *Multi) void {
        if (!m.startBatch()) return;
        m.pickup_choice = null;
        if (m.pickup) |dd| {
            const i = c.gtk_drop_down_get_selected(dd);
            if (i < m.pickup_ids.len) m.pickup_choice = m.batch_arena.allocator().dupe(u8, m.pickup_ids[i]) catch null;
        }
        m.setBusy(true);
        m.placeNext();
    }

    fn placeNext(m: *Multi) void {
        if (m.next >= m.batch.len or m.limit_reached) return m.finishPlacing();
        const item = m.batch[m.next];
        const j = m.window.job(&onPlaced, m) orelse return m.finishPlacing();
        j.start(capi.biblio_place_hold, .{ m.window.client, j.z(item.bib_id), j.z(item.material), j.optZ(m.pickup_choice) });
    }

    fn onPlaced(data: ?*anyopaque, r: *core.Result) void {
        const m: *Multi = @ptrCast(@alignCast(data.?));
        if (m.window.finishPending()) return;
        const ba = m.batch_arena.allocator();
        const item = m.batch[m.next];
        m.next += 1;
        if (r.ok) {
            m.placed.append(ba, item.bib_id) catch {};
        } else {
            m.failures += 1;
            if (m.first_failure.len == 0) m.first_failure = ba.dupe(u8, r.message) catch "";
            if (r.kind == .hold_limit) m.limit_reached = true;
        }
        m.placeNext();
    }

    fn finishPlacing(m: *Multi) void {
        const w = m.window;
        m.setBusy(false);
        const placed = m.placed.items.len;
        var buf: [1024]u8 = undefined;
        var message: []const u8 = undefined;
        if (placed == 0) {
            message = if (m.first_failure.len > 0) m.first_failure else "No holds were placed.";
        } else {
            const holds = if (placed == 1) "hold" else "holds";
            const skipped = if (m.skipped > 0) std.fmt.bufPrint(buf[512..], " {d} skipped: already held or not holdable.", .{m.skipped}) catch "" else "";
            message = if (m.failures == 0)
                std.fmt.bufPrint(&buf, "Placed {d} {s}.{s}", .{ placed, holds, skipped }) catch "Holds placed."
            else
                std.fmt.bufPrint(&buf, "Placed {d} {s}, but {d} failed: {s}{s}", .{ placed, holds, m.failures, m.first_failure, skipped }) catch "Some holds failed.";
        }
        w.toast(message);
        if (placed > 0) w.holdsPlaced(m.placed.items);
        m.list.endSelecting();
        m.list.clearSelection();
        m.list.showSelection();
    }

    // MARK: Canceling holds

    /// Asks first, over the button: canceling loses places in line.
    fn confirmCancel(m: *Multi) void {
        var eligible: usize = 0;
        for (m.items) |item| {
            if (item.eligible) eligible += 1;
        }
        if (eligible == 0) return;
        var buf: [128]u8 = undefined;
        const heading = std.fmt.bufPrintSentinel(&buf, "Cancel {d} {s}?", .{ eligible, if (eligible == 1) "Hold" else "Holds" }, 0) catch "Cancel Holds?";
        const dialog = c.adw_alert_dialog_new(heading.ptr, "You will lose your places in line.");
        c.adw_alert_dialog_add_response(@ptrCast(@alignCast(dialog)), "keep", "_Keep Holds");
        c.adw_alert_dialog_add_response(@ptrCast(@alignCast(dialog)), "cancel", "_Cancel Holds");
        c.adw_alert_dialog_set_response_appearance(@ptrCast(@alignCast(dialog)), "cancel", c.ADW_RESPONSE_DESTRUCTIVE);
        c.adw_alert_dialog_set_default_response(@ptrCast(@alignCast(dialog)), "keep");
        c.adw_alert_dialog_set_close_response(@ptrCast(@alignCast(dialog)), "keep");
        gtk.connect(dialog, "response", &onCancelResponse, m);
        c.adw_dialog_present(@ptrCast(@alignCast(dialog)), m.primary);
    }

    fn onCancelResponse(_: *c.AdwAlertDialog, response: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
        const m: *Multi = @ptrCast(@alignCast(data.?));
        if (!std.mem.eql(u8, std.mem.span(response), "cancel") or m.busy) return;
        if (!m.startBatch()) return;
        m.setBusy(true);
        const j = m.window.job(&onCanceled, m) orelse return m.setBusy(false);
        const refs = j.a().alloc(capi.HoldRef, m.batch.len) catch return m.setBusy(false);
        for (refs, m.batch) |*ref, item| ref.* = .{ .id = j.z(item.hold_id), .metadata_id = j.z(item.metadata_id) };
        j.start(capi.biblio_cancel_holds, .{ m.window.client, refs.ptr, refs.len });
    }

    fn onCanceled(data: ?*anyopaque, r: *core.Result) void {
        const m: *Multi = @ptrCast(@alignCast(data.?));
        const w = m.window;
        if (w.finishPending()) return;
        m.setBusy(false);
        if (!r.ok) return w.toast(r.message);
        const refused = if (r.get(capi.RefusalList)) |l| core.items(capi.Refusal, l.items, l.items_count) else &.{};
        const ba = m.batch_arena.allocator();
        var entry_ids: std.ArrayList([]const u8) = .empty;
        var bib_ids: std.ArrayList([]const u8) = .empty;
        for (m.batch) |item| {
            const declined = for (refused) |refusal| {
                if (std.mem.eql(u8, std.mem.span(refusal.hold_id), item.hold_id)) break true;
            } else false;
            if (declined) continue;
            entry_ids.append(ba, item.entry_id) catch {};
            bib_ids.append(ba, item.bib_id) catch {};
        }
        var buf: [1024]u8 = undefined;
        const canceled = entry_ids.items.len;
        const message = if (refused.len == 0)
            std.fmt.bufPrint(&buf, "Canceled {d} {s}.", .{ canceled, if (canceled == 1) "hold" else "holds" }) catch "Holds canceled."
        else if (canceled == 0)
            std.fmt.bufPrint(&buf, "The library kept your holds: {s}", .{std.mem.span(refused[0].reason)}) catch "The library kept your holds."
        else
            std.fmt.bufPrint(&buf, "Canceled {d}; the library kept {d}: {s}", .{ canceled, refused.len, std.mem.span(refused[0].reason) }) catch "Some holds were kept.";
        w.toast(message);
        if (canceled > 0) w.holdsCanceled(entry_ids.items, bib_ids.items);
        m.list.endSelecting();
        m.list.clearSelection();
        m.list.showSelection();
    }
};
