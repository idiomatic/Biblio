//! Account settings: library card barcode, email, password, pickup location, language and
//! borrowing history, as a GNOME preferences page.

const std = @import("std");
const gtk = @import("gtk.zig");
const c = gtk.c;
const core = @import("core.zig");
const store = @import("store.zig");
const Window = @import("window.zig").Window;

pub const Account = struct {
    window: *Window,
    root: *c.GtkWidget,
    page: ?*c.GtkWidget = null,
    holder: *c.GtkWidget,
    arena: std.heap.ArenaAllocator,
    barcode: []const f64 = &.{},
    email: ?*c.AdwEntryRow = null,
    current_password: ?*c.AdwPasswordEntryRow = null,
    new_password: ?*c.AdwPasswordEntryRow = null,
    confirm_password: ?*c.AdwPasswordEntryRow = null,
    pickup_ids: []const []const u8 = &.{},
    language_ids: []const []const u8 = &.{},
    history: ?*c.AdwSwitchRow = null,
    /// Set while rows are filled in, so their change signals don't save anything.
    filling: bool = false,
    pending_password: ?[]u8 = null,

    pub fn create(w: *Window) *Account {
        const acc = core.gpa.create(Account) catch unreachable;
        const toolbar = c.adw_toolbar_view_new();
        const header = c.adw_header_bar_new();
        c.adw_header_bar_set_title_widget(@ptrCast(@alignCast(header)), c.adw_window_title_new("Account", ""));
        c.adw_toolbar_view_add_top_bar(@ptrCast(@alignCast(toolbar)), header);
        const holder = gtk.box(true, 0);
        c.adw_toolbar_view_set_content(@ptrCast(@alignCast(toolbar)), holder);
        acc.* = .{ .window = w, .root = toolbar, .holder = holder, .arena = .init(core.gpa) };
        return acc;
    }

    pub fn free(acc: *Account) void {
        if (acc.pending_password) |p| {
            std.crypto.secureZero(u8, p);
            core.gpa.free(p);
        }
        acc.arena.deinit();
        core.gpa.destroy(acc);
    }

    fn a(acc: *Account) std.mem.Allocator {
        return acc.arena.allocator();
    }

    /// Rebuilds the page from the signed-in patron.
    pub fn refresh(acc: *Account) void {
        const w = acc.window;
        const patron = w.patron orelse return;
        acc.filling = true;
        defer acc.filling = false;
        if (acc.page) |p| c.gtk_box_remove(@ptrCast(@alignCast(acc.holder)), p);
        _ = acc.arena.reset(.retain_capacity);
        const page = c.adw_preferences_page_new();
        c.gtk_widget_set_vexpand(page, 1);
        acc.page = page;
        gtk.append(acc.holder, page);

        const profile = group("Profile", null);
        addInfo(acc, profile, "Name", core.str(patron, "name") orelse w.username);
        addInfo(acc, profile, "Library", store.name(w.library));
        c.adw_preferences_page_add(@ptrCast(@alignCast(page)), profile);

        if (core.str(patron, "barcode")) |barcode| {
            const card = group("Library Card", "Show this at the library’s self-checkout or desk.");
            const elements = core.now(acc.a(), .{ .op = "codabar", .value = barcode });
            var widths: std.ArrayList(f64) = .empty;
            for (core.items(elements)) |e| widths.append(acc.a(), switch (e) {
                .float => |f| f,
                .integer => |i| @floatFromInt(i),
                else => 1,
            }) catch {};
            acc.barcode = widths.items;
            const box = gtk.box(true, 6);
            c.gtk_widget_add_css_class(box, "barcode");
            if (widths.items.len > 0) {
                const area = c.gtk_drawing_area_new();
                c.gtk_widget_set_size_request(area, 300, 64);
                c.gtk_drawing_area_set_draw_func(@ptrCast(@alignCast(area)), &drawBarcode, acc, null);
                gtk.append(box, area);
            }
            const number = gtk.label(barcode, acc.a(), &.{"monospace"});
            c.gtk_label_set_xalign(@ptrCast(@alignCast(number)), 0.5);
            gtk.append(box, number);
            c.gtk_accessible_update_property(@ptrCast(@alignCast(box)), c.GTK_ACCESSIBLE_PROPERTY_LABEL, gtk.z(acc.a(), std.fmt.allocPrint(acc.a(), "Library card barcode {s}", .{barcode}) catch ""), @as(c_int, -1));
            c.adw_preferences_group_add(@ptrCast(@alignCast(card)), box);
            c.adw_preferences_page_add(@ptrCast(@alignCast(page)), card);
        }

        const email_group = group("Email", null);
        const email: *c.AdwEntryRow = @ptrCast(@alignCast(c.adw_entry_row_new()));
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(email)), "Email address");
        c.gtk_editable_set_text(@ptrCast(@alignCast(email)), gtk.z(acc.a(), core.str(patron, "email") orelse ""));
        c.adw_entry_row_set_show_apply_button(email, 1);
        c.adw_entry_row_set_input_purpose(email, c.GTK_INPUT_PURPOSE_EMAIL);
        gtk.connect(email, "apply", &onEmail, acc);
        c.adw_preferences_group_add(@ptrCast(@alignCast(email_group)), gtk.widget(email));
        acc.email = email;
        c.adw_preferences_page_add(@ptrCast(@alignCast(page)), email_group);

        const password_group = group("Password", null);
        acc.current_password = passwordRow(password_group, "Current password");
        acc.new_password = passwordRow(password_group, "New password");
        acc.confirm_password = passwordRow(password_group, "Confirm new password");
        const change = c.adw_button_row_new();
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(change)), "Change Password");
        gtk.connect(change, "activated", &onChangePassword, acc);
        c.adw_preferences_group_add(@ptrCast(@alignCast(password_group)), change);
        c.adw_preferences_page_add(@ptrCast(@alignCast(page)), password_group);

        const holds = group("Holds", "Used for new holds unless you choose another location when placing one.");
        var pickup_names: std.ArrayList(?[*:0]const u8) = .empty;
        var pickup_ids: std.ArrayList([]const u8) = .empty;
        var pickup_selected: c.guint = c.GTK_INVALID_LIST_POSITION;
        for (w.locations) |loc| {
            const id = core.str(loc, "id") orelse continue;
            if (core.str(patron, "preferredPickup")) |p| if (std.mem.eql(u8, p, id)) {
                pickup_selected = @intCast(pickup_ids.items.len);
            };
            pickup_ids.append(acc.a(), id) catch continue;
            pickup_names.append(acc.a(), gtk.z(acc.a(), core.str(loc, "name") orelse id)) catch {};
        }
        pickup_names.append(acc.a(), null) catch {};
        acc.pickup_ids = pickup_ids.items;
        const pickup = c.adw_combo_row_new();
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(pickup)), "Pickup location");
        c.adw_combo_row_set_model(@ptrCast(@alignCast(pickup)), @ptrCast(@alignCast(c.gtk_string_list_new(@ptrCast(pickup_names.items.ptr)))));
        c.adw_combo_row_set_selected(@ptrCast(@alignCast(pickup)), pickup_selected);
        gtk.connect(pickup, "notify::selected", &onPickup, acc);
        c.adw_preferences_group_add(@ptrCast(@alignCast(holds)), pickup);
        c.adw_preferences_page_add(@ptrCast(@alignCast(page)), holds);

        const language_group = group("Language", null);
        var language_names: std.ArrayList(?[*:0]const u8) = .empty;
        var language_ids: std.ArrayList([]const u8) = .empty;
        var language_selected: c.guint = 0;
        const labels = w.libraryLabels();
        if (w.library.object.get("languages")) |langs| for (core.items(langs)) |l| {
            if (l != .string) continue;
            if (std.mem.eql(u8, l.string, core.str(patron, "language") orelse "")) language_selected = @intCast(language_ids.items.len);
            const key = std.fmt.allocPrint(acc.a(), "LANGUAGE_NAME.{s}", .{l.string}) catch l.string;
            const name = core.str(labels, key) orelse l.string;
            language_ids.append(acc.a(), l.string) catch continue;
            language_names.append(acc.a(), gtk.z(acc.a(), name)) catch {};
        };
        language_names.append(acc.a(), null) catch {};
        acc.language_ids = language_ids.items;
        const language = c.adw_combo_row_new();
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(language)), "Language");
        c.adw_combo_row_set_model(@ptrCast(@alignCast(language)), @ptrCast(@alignCast(c.gtk_string_list_new(@ptrCast(language_names.items.ptr)))));
        c.adw_combo_row_set_selected(@ptrCast(@alignCast(language)), language_selected);
        gtk.connect(language, "notify::selected", &onLanguage, acc);
        c.adw_preferences_group_add(@ptrCast(@alignCast(language_group)), language);
        c.adw_preferences_page_add(@ptrCast(@alignCast(page)), language_group);

        acc.history = null;
        if (core.boolean(patron, "borrowingHistoryEnabled")) |enabled| {
            const history_group = group("Borrowing History", "When on, the library keeps a list of the items you check out.");
            const history: *c.AdwSwitchRow = @ptrCast(@alignCast(c.adw_switch_row_new()));
            c.adw_preferences_row_set_title(@ptrCast(@alignCast(history)), "Keep borrowing history");
            c.adw_switch_row_set_active(history, @intFromBool(enabled));
            gtk.connect(history, "notify::active", &onHistory, acc);
            c.adw_preferences_group_add(@ptrCast(@alignCast(history_group)), gtk.widget(history));
            c.adw_preferences_page_add(@ptrCast(@alignCast(page)), history_group);
            acc.history = history;
        }
    }

    fn group(title: [*:0]const u8, description: ?[*:0]const u8) *c.AdwPreferencesGroup {
        const g: *c.AdwPreferencesGroup = @ptrCast(@alignCast(c.adw_preferences_group_new()));
        c.adw_preferences_group_set_title(g, title);
        if (description) |d| c.adw_preferences_group_set_description(g, d);
        return g;
    }

    fn addInfo(acc: *Account, g: *c.AdwPreferencesGroup, title: [*:0]const u8, value: []const u8) void {
        const row = c.adw_action_row_new();
        c.gtk_widget_add_css_class(row, "property");
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), title);
        c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), gtk.z(acc.a(), value));
        c.adw_preferences_group_add(g, row);
    }

    fn passwordRow(g: *c.AdwPreferencesGroup, title: [*:0]const u8) *c.AdwPasswordEntryRow {
        const row: *c.AdwPasswordEntryRow = @ptrCast(@alignCast(c.adw_password_entry_row_new()));
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), title);
        c.adw_preferences_group_add(g, gtk.widget(row));
        return row;
    }

    /// Black bars on white with quiet zones, scannable in dark mode too.
    fn drawBarcode(_: [*c]c.GtkDrawingArea, cr: ?*c.cairo_t, width: c_int, height: c_int, data: ?*anyopaque) callconv(.c) void {
        const acc: *Account = @ptrCast(@alignCast(data.?));
        const quiet = 10.0;
        var total: f64 = 2 * quiet;
        for (acc.barcode) |e| total += e;
        const unit = @as(f64, @floatFromInt(width)) / total;
        c.cairo_set_source_rgb(cr, 1, 1, 1);
        c.cairo_paint(cr);
        c.cairo_set_source_rgb(cr, 0, 0, 0);
        var x = quiet * unit;
        // Elements alternate bar, space, …; the gap after each character is a space, so even indices are bars.
        for (acc.barcode, 0..) |e, i| {
            if (i % 2 == 0) c.cairo_rectangle(cr, x, 0, e * unit, @floatFromInt(height));
            x += e * unit;
        }
        c.cairo_fill(cr);
    }

    // MARK: Saving

    fn run(acc: *Account, request: anytype) void {
        acc.window.call(request, &onSaved, acc);
    }

    fn onSaved(data: ?*anyopaque, r: *core.Result) void {
        const acc: *Account = @ptrCast(@alignCast(data.?));
        const w = acc.window;
        if (w.finishPending()) return;
        if (!r.ok) {
            if (acc.pending_password) |p| {
                std.crypto.secureZero(u8, p);
                core.gpa.free(p);
                acc.pending_password = null;
            }
            w.toast(r.message);
            return w.call(.{ .op = "patron" }, &onPatron, acc); // put the rows back
        }
        if (acc.pending_password) |p| {
            // Keep the keyring in step so signing in again automatically still works.
            _ = store.storePassword(w.subdomain, w.username, p);
            std.crypto.secureZero(u8, p);
            core.gpa.free(p);
            acc.pending_password = null;
            w.toast("Password changed.");
        } else {
            w.toast("Saved.");
        }
        w.call(.{ .op = "patron" }, &onPatron, acc);
    }

    fn onPatron(data: ?*anyopaque, r: *core.Result) void {
        const acc: *Account = @ptrCast(@alignCast(data.?));
        const w = acc.window;
        if (w.finishPending()) return;
        if (!r.ok or r.value != .object) return;
        w.patron = r.value;
        w.keep(r);
        acc.refresh();
    }

    fn onEmail(row: *c.AdwEntryRow, data: ?*anyopaque) callconv(.c) void {
        const acc: *Account = @ptrCast(@alignCast(data.?));
        const email = std.mem.span(c.gtk_editable_get_text(@ptrCast(@alignCast(row))));
        if (std.mem.findScalar(u8, email, '@') == null) return acc.window.toast("Enter a valid email address.");
        acc.run(.{ .op = "changeEmail", .email = email });
    }

    fn onChangePassword(_: *c.AdwButtonRow, data: ?*anyopaque) callconv(.c) void {
        const acc: *Account = @ptrCast(@alignCast(data.?));
        const current = std.mem.span(c.gtk_editable_get_text(@ptrCast(@alignCast(acc.current_password.?))));
        const new = std.mem.span(c.gtk_editable_get_text(@ptrCast(@alignCast(acc.new_password.?))));
        const confirm = std.mem.span(c.gtk_editable_get_text(@ptrCast(@alignCast(acc.confirm_password.?))));
        if (current.len == 0 or new.len == 0) return;
        if (!std.mem.eql(u8, new, confirm)) return acc.window.toast("The new passwords don’t match.");
        acc.pending_password = core.gpa.dupe(u8, new) catch return;
        acc.run(.{ .op = "changePassword", .current = current, .new = new });
    }

    fn onPickup(row: *c.AdwComboRow, _: ?*c.GParamSpec, data: ?*anyopaque) callconv(.c) void {
        const acc: *Account = @ptrCast(@alignCast(data.?));
        if (acc.filling) return;
        const i = c.adw_combo_row_get_selected(row);
        if (i >= acc.pickup_ids.len) return;
        acc.run(.{ .op = "setPickup", .branchId = acc.pickup_ids[i] });
    }

    fn onLanguage(row: *c.AdwComboRow, _: ?*c.GParamSpec, data: ?*anyopaque) callconv(.c) void {
        const acc: *Account = @ptrCast(@alignCast(data.?));
        if (acc.filling) return;
        const i = c.adw_combo_row_get_selected(row);
        if (i >= acc.language_ids.len) return;
        acc.run(.{ .op = "setLanguage", .code = acc.language_ids[i] });
        // Catalog text (formats, sort names) comes back in the new language.
        for ([_]@import("window.zig").Section{ .search, .new_titles }) |s| if (acc.window.list(s)) |l| l.reloadIfLoaded();
    }

    /// Turning history off can delete it, so it asks first.
    fn onHistory(row: *c.AdwSwitchRow, _: ?*c.GParamSpec, data: ?*anyopaque) callconv(.c) void {
        const acc: *Account = @ptrCast(@alignCast(data.?));
        if (acc.filling) return;
        if (c.adw_switch_row_get_active(row) != 0) return acc.run(.{ .op = "setBorrowingHistory", .enabled = true });
        const dialog = c.adw_alert_dialog_new("Turn Off Borrowing History?", "The library may permanently delete your existing borrowing history.");
        c.adw_alert_dialog_add_response(@ptrCast(@alignCast(dialog)), "keep", "_Keep History");
        c.adw_alert_dialog_add_response(@ptrCast(@alignCast(dialog)), "off", "_Turn Off");
        c.adw_alert_dialog_set_response_appearance(@ptrCast(@alignCast(dialog)), "off", c.ADW_RESPONSE_DESTRUCTIVE);
        c.adw_alert_dialog_set_default_response(@ptrCast(@alignCast(dialog)), "keep");
        c.adw_alert_dialog_set_close_response(@ptrCast(@alignCast(dialog)), "keep");
        gtk.connect(dialog, "response", &onHistoryResponse, acc);
        c.adw_dialog_present(@ptrCast(@alignCast(dialog)), gtk.widget(acc.window.window));
    }

    fn onHistoryResponse(_: *c.AdwAlertDialog, response: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
        const acc: *Account = @ptrCast(@alignCast(data.?));
        if (std.mem.eql(u8, std.mem.span(response), "off")) {
            acc.run(.{ .op = "setBorrowingHistory", .enabled = false });
        } else if (acc.history) |h| {
            acc.filling = true;
            c.adw_switch_row_set_active(h, 1);
            acc.filling = false;
        }
    }
};
