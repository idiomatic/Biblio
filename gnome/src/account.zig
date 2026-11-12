//! Account settings: library card barcode, email, password, pickup location, language and
//! borrowing history, as a GNOME preferences page.

const std = @import("std");
const gtk = @import("gtk.zig");
const c = gtk.c;
const core = @import("core.zig");
const capi = core.capi;
const store = @import("store.zig");
const Window = @import("window.zig").Window;
const borrowed = @import("borrowed.zig");
const barcode = @import("barcode.zig");

pub const Account = struct {
    window: *Window,
    root: *c.GtkWidget,
    page: ?*c.GtkWidget = null,
    holder: *c.GtkWidget,
    arena: std.heap.ArenaAllocator,
    /// The library card's barcode, redrawn when its type changes.
    card_holder: ?*c.GtkWidget = null,
    card_value: []const u8 = "",
    email: ?*c.AdwEntryRow = null,
    current_password: ?*c.AdwPasswordEntryRow = null,
    new_password: ?*c.AdwPasswordEntryRow = null,
    confirm_password: ?*c.AdwPasswordEntryRow = null,
    pickup_ids: []const []const u8 = &.{},
    language_ids: []const []const u8 = &.{},
    history: ?*c.AdwSwitchRow = null,
    /// Refresh Borrowing History, and its progress while the index syncs.
    refresh_history: ?*c.GtkWidget = null,
    progress_row: ?*c.GtkWidget = null,
    progress_bar: ?*c.GtkProgressBar = null,
    /// Pulses the progress bar while the history's size is unknown.
    pulse: c.guint = 0,
    /// Set while rows are filled in, so their change signals don't save anything.
    filling: bool = false,
    /// A password change is under way; another waits for it.
    changing_password: bool = false,
    change_password: ?*c.GtkWidget = null,
    language_row: ?*c.AdwComboRow = null,
    system_language: ?*c.GtkWidget = null,

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
        if (acc.pulse != 0) _ = c.g_source_remove(acc.pulse);
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
        const name = std.mem.span(patron.name);
        addInfo(acc, profile, "Name", if (name.len > 0) name else w.username);
        addInfo(acc, profile, "Library", store.name(w.library));
        c.adw_preferences_page_add(@ptrCast(@alignCast(page)), profile);

        acc.card_holder = null;
        if (core.str(patron.barcode)) |value| {
            const card = group("Library Card", "Show this at the library’s self-checkout or desk.");
            const holder = gtk.box(true, 0);
            c.adw_preferences_group_add(@ptrCast(@alignCast(card)), holder);
            acc.card_holder = holder;
            acc.card_value = acc.a().dupe(u8, value) catch "";
            acc.showCard();
            // The type the library's scanners read, for every card of this library.
            const kinds = [_:null]?[*:0]const u8{ "Codabar", "Code 128" };
            const kind: *c.GtkDropDown = @ptrCast(@alignCast(c.gtk_drop_down_new_from_strings(&kinds)));
            c.gtk_drop_down_set_selected(kind, @intFromBool(store.barcodeType(w.subdomain) == .code128));
            c.gtk_widget_set_tooltip_text(gtk.widget(kind), "Barcode type");
            c.gtk_accessible_update_property(@ptrCast(@alignCast(kind)), c.GTK_ACCESSIBLE_PROPERTY_LABEL, "Barcode type", @as(c_int, -1));
            c.gtk_widget_set_valign(gtk.widget(kind), c.GTK_ALIGN_CENTER);
            gtk.connect(kind, "notify::selected", &onBarcodeType, acc);
            c.adw_preferences_group_set_header_suffix(card, gtk.widget(kind));
            c.adw_preferences_page_add(@ptrCast(@alignCast(page)), card);
        }

        const email_group = group("Email", null);
        const email: *c.AdwEntryRow = @ptrCast(@alignCast(c.adw_entry_row_new()));
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(email)), "Email address");
        c.gtk_editable_set_text(@ptrCast(@alignCast(email)), patron.email orelse "");
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
        c.gtk_widget_set_sensitive(change, @intFromBool(!acc.changing_password));
        c.adw_preferences_group_add(@ptrCast(@alignCast(password_group)), change);
        acc.change_password = change;
        c.adw_preferences_page_add(@ptrCast(@alignCast(page)), password_group);

        const holds = group("Holds", "Used for new holds unless you choose another location when placing one.");
        var pickup_names: std.ArrayList(?[*:0]const u8) = .empty;
        var pickup_ids: std.ArrayList([]const u8) = .empty;
        var pickup_selected: c.guint = c.GTK_INVALID_LIST_POSITION;
        for (w.locations) |loc| {
            const id = std.mem.span(loc.id);
            if (core.str(patron.preferred_pickup)) |p| if (std.mem.eql(u8, p, id)) {
                pickup_selected = @intCast(pickup_ids.items.len);
            };
            pickup_ids.append(acc.a(), id) catch continue;
            pickup_names.append(acc.a(), loc.name) catch {};
        }
        pickup_names.append(acc.a(), null) catch {};
        acc.pickup_ids = pickup_ids.items;
        const pickup = c.adw_combo_row_new();
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(pickup)), "Pickup location");
        const pickup_model = c.gtk_string_list_new(@ptrCast(pickup_names.items.ptr));
        c.adw_combo_row_set_model(@ptrCast(@alignCast(pickup)), @ptrCast(@alignCast(pickup_model)));
        c.g_object_unref(pickup_model);
        c.adw_combo_row_set_selected(@ptrCast(@alignCast(pickup)), pickup_selected);
        gtk.connect(pickup, "notify::selected", &onPickup, acc);
        c.adw_preferences_group_add(@ptrCast(@alignCast(holds)), pickup);
        c.adw_preferences_page_add(@ptrCast(@alignCast(page)), holds);

        const language_group = group("Language", null);
        var language_names: std.ArrayList(?[*:0]const u8) = .empty;
        var language_ids: std.ArrayList([]const u8) = .empty;
        var language_selected: c.guint = 0;
        if (w.library.object.get("languages")) |langs| if (langs == .array) for (langs.array.items) |l| {
            if (l != .string) continue;
            if (std.mem.eql(u8, l.string, std.mem.span(patron.language))) language_selected = @intCast(language_ids.items.len);
            const key = std.fmt.allocPrint(acc.a(), "LANGUAGE_NAME.{s}", .{l.string}) catch l.string;
            const language_name = store.label(w.library, key) orelse l.string;
            language_ids.append(acc.a(), l.string) catch continue;
            language_names.append(acc.a(), gtk.z(acc.a(), language_name)) catch {};
        };
        language_names.append(acc.a(), null) catch {};
        acc.language_ids = language_ids.items;
        const language = c.adw_combo_row_new();
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(language)), "Language");
        const language_model = c.gtk_string_list_new(@ptrCast(language_names.items.ptr));
        c.adw_combo_row_set_model(@ptrCast(@alignCast(language)), @ptrCast(@alignCast(language_model)));
        c.g_object_unref(language_model);
        c.adw_combo_row_set_selected(@ptrCast(@alignCast(language)), language_selected);
        gtk.connect(language, "notify::selected", &onLanguage, acc);
        c.adw_preferences_group_add(@ptrCast(@alignCast(language_group)), language);
        acc.language_row = @ptrCast(@alignCast(language));
        // The account's preference, never set for it: offered, for the closest supported language.
        const system = c.adw_button_row_new();
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(system)), "Use System Language");
        gtk.connect(system, "activated", &onSystemLanguage, acc);
        c.adw_preferences_group_add(@ptrCast(@alignCast(language_group)), system);
        acc.system_language = system;
        acc.updateSystemLanguage();
        c.adw_preferences_page_add(@ptrCast(@alignCast(page)), language_group);

        acc.history = null;
        acc.refresh_history = null;
        acc.progress_row = null;
        acc.progress_bar = null;
        if (patron.has_borrowing_history_enabled or w.borrowed != null) {
            const history_group = group("Borrowing History", "When on, the library keeps a list of the items you check out.");
            if (patron.has_borrowing_history_enabled) {
                const history: *c.AdwSwitchRow = @ptrCast(@alignCast(c.adw_switch_row_new()));
                c.adw_preferences_row_set_title(@ptrCast(@alignCast(history)), "Keep borrowing history");
                c.adw_switch_row_set_active(history, @intFromBool(patron.borrowing_history_enabled));
                gtk.connect(history, "notify::active", &onHistory, acc);
                c.adw_preferences_group_add(@ptrCast(@alignCast(history_group)), gtk.widget(history));
                acc.history = history;
            }
            if (w.borrowed != null) {
                // "Updating · 340 of 1,200" while the borrowed-before index syncs.
                const progress = c.adw_action_row_new();
                const bar: *c.GtkProgressBar = @ptrCast(@alignCast(c.gtk_progress_bar_new()));
                c.gtk_widget_set_valign(gtk.widget(bar), c.GTK_ALIGN_CENTER);
                c.gtk_widget_set_size_request(gtk.widget(bar), 120, -1);
                c.adw_action_row_add_suffix(@ptrCast(@alignCast(progress)), gtk.widget(bar));
                c.adw_preferences_group_add(@ptrCast(@alignCast(history_group)), progress);
                acc.progress_row = progress;
                acc.progress_bar = bar;
                const refresh_history = c.adw_button_row_new();
                c.adw_preferences_row_set_title(@ptrCast(@alignCast(refresh_history)), "Refresh Borrowing History");
                c.adw_button_row_set_start_icon_name(@ptrCast(@alignCast(refresh_history)), "view-refresh-symbolic");
                gtk.connect(refresh_history, "activated", &onRefreshHistory, acc);
                c.adw_preferences_group_add(@ptrCast(@alignCast(history_group)), refresh_history);
                acc.refresh_history = refresh_history;
            }
            c.adw_preferences_page_add(@ptrCast(@alignCast(page)), history_group);
        }
        acc.borrowedChanged();
    }

    /// Follows the borrowed-before index's sync.
    pub fn borrowedChanged(acc: *Account) void {
        const b = acc.window.borrowed orelse return;
        const row = acc.progress_row orelse return;
        const p = b.progress();
        if (acc.refresh_history) |r| c.gtk_widget_set_sensitive(r, @intFromBool(!p.syncing and !b.off and b.started));
        c.gtk_widget_set_visible(row, @intFromBool(p.syncing));
        const unknown = p.syncing and p.total <= 0;
        if (unknown and acc.pulse == 0) acc.pulse = c.g_timeout_add(100, &onPulse, acc);
        if (!unknown and acc.pulse != 0) {
            _ = c.g_source_remove(acc.pulse);
            acc.pulse = 0;
        }
        if (!p.syncing) return;
        var buf: [256]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const fa = fba.allocator();
        const title = if (unknown) "Updating…" else std.fmt.allocPrint(fa, "Updating · {s} of {s}", .{ borrowed.grouped(fa, p.fetched), borrowed.grouped(fa, p.total) }) catch "Updating…";
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), gtk.z(fa, title));
        if (acc.progress_bar) |bar| {
            if (!unknown) c.gtk_progress_bar_set_fraction(bar, @min(1.0, @as(f64, @floatFromInt(p.fetched)) / @as(f64, @floatFromInt(p.total))));
            c.gtk_accessible_update_property(@ptrCast(@alignCast(bar)), c.GTK_ACCESSIBLE_PROPERTY_LABEL, gtk.z(fa, title), @as(c_int, -1));
        }
    }

    fn onPulse(data: ?*anyopaque) callconv(.c) c.gboolean {
        const acc: *Account = @ptrCast(@alignCast(data.?));
        if (acc.progress_bar) |bar| c.gtk_progress_bar_pulse(bar);
        return 1; // G_SOURCE_CONTINUE
    }

    fn onRefreshHistory(_: *c.AdwButtonRow, data: ?*anyopaque) callconv(.c) void {
        const acc: *Account = @ptrCast(@alignCast(data.?));
        if (acc.window.borrowed) |b| b.rebuild();
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

    /// Draws the card in the library's barcode type.
    fn showCard(acc: *Account) void {
        const holder = acc.card_holder orelse return;
        gtk.clearBox(holder);
        gtk.append(holder, barcode.card(acc.card_value, store.barcodeType(acc.window.subdomain), 64));
    }

    fn onBarcodeType(dropdown: *c.GtkDropDown, _: ?*c.GParamSpec, data: ?*anyopaque) callconv(.c) void {
        const acc: *Account = @ptrCast(@alignCast(data.?));
        if (acc.filling) return;
        store.setBarcodeType(acc.window.subdomain, if (c.gtk_drop_down_get_selected(dropdown) == 1) .code128 else .codabar);
        acc.showCard();
    }

    /// The library language closest to the system's, if the library supports one.
    fn systemLanguage(acc: *Account) ?usize {
        const names = c.g_get_language_names();
        var best: ?usize = null;
        var i: usize = 0;
        // Most preferred first: "fr_CA.UTF-8", "fr_CA", "fr.UTF-8", "fr", ..., "C".
        while (names[i]) |name| : (i += 1) {
            var locale: []const u8 = std.mem.span(name);
            if (std.mem.indexOfAny(u8, locale, ".@")) |end| locale = locale[0..end];
            if (locale.len < 2 or std.mem.eql(u8, locale, "C") or std.mem.eql(u8, locale, "POSIX")) continue;
            const language = locale[0 .. std.mem.indexOfScalar(u8, locale, '_') orelse locale.len];
            for (acc.language_ids, 0..) |id, j| {
                const id_language = id[0 .. std.mem.indexOfAny(u8, id, "-_") orelse id.len];
                if (sameLocale(id, locale)) return j;
                if (best == null and std.ascii.eqlIgnoreCase(id_language, language)) best = j;
            }
            if (best != null) return best;
        }
        return best;
    }

    /// "en-US" and "en_US" name the same locale.
    fn sameLocale(x: []const u8, y: []const u8) bool {
        if (x.len != y.len) return false;
        for (x, y) |p, q| {
            const pn = if (p == '_') '-' else std.ascii.toLower(p);
            const qn = if (q == '_') '-' else std.ascii.toLower(q);
            if (pn != qn) return false;
        }
        return true;
    }

    fn updateSystemLanguage(acc: *Account) void {
        const button = acc.system_language orelse return;
        const row = acc.language_row orelse return;
        const match = acc.systemLanguage();
        const current = c.adw_combo_row_get_selected(row);
        c.gtk_widget_set_sensitive(button, @intFromBool(match != null and match.? != current));
        c.gtk_widget_set_tooltip_text(button, if (match == null) "The library doesn’t offer your system’s language." else null);
    }

    fn onSystemLanguage(_: *c.AdwButtonRow, data: ?*anyopaque) callconv(.c) void {
        const acc: *Account = @ptrCast(@alignCast(data.?));
        const i = acc.systemLanguage() orelse return;
        // Selecting it saves it, like choosing it from the menu.
        if (acc.language_row) |row| c.adw_combo_row_set_selected(row, @intCast(i));
    }

    // MARK: Saving

    /// One save in flight. A new password belongs to its own change, so no other save can
    /// store it before the library has accepted it.
    const Save = struct {
        account: *Account,
        kind: enum { setting, language, password },
        password: ?[]u8 = null,

        fn destroy(s: *Save) void {
            if (s.password) |p| {
                std.crypto.secureZero(u8, p);
                core.gpa.free(p);
            }
            core.gpa.destroy(s);
        }
    };

    /// A call that saves a setting, then shows the patron again.
    fn job(acc: *Account) ?*core.Job {
        return acc.saveJob(.{ .account = acc, .kind = .setting });
    }

    fn saveJob(acc: *Account, save: Save) ?*core.Job {
        const s = core.gpa.create(Save) catch return null;
        s.* = save;
        return acc.window.job(&onSaved, s) orelse {
            s.password = null; // still the caller's
            s.destroy();
            return null;
        };
    }

    fn reloadPatron(acc: *Account) void {
        const w = acc.window;
        if (w.job(&onPatron, acc)) |j| j.start(capi.biblio_patron, .{w.client});
    }

    fn onSaved(data: ?*anyopaque, r: *core.Result) void {
        const s: *Save = @ptrCast(@alignCast(data.?));
        defer s.destroy();
        const acc = s.account;
        const w = acc.window;
        if (w.finishPending()) return;
        if (s.kind == .password) {
            acc.changing_password = false;
            if (acc.change_password) |b| c.gtk_widget_set_sensitive(b, 1);
        }
        if (!r.ok) {
            w.toast(r.message);
            return acc.reloadPatron(); // put the rows back
        }
        switch (s.kind) {
            .password => {
                // Keep the keyring in step so signing in again automatically still works.
                if (s.password) |p| _ = store.storePassword(w.subdomain, w.username, p);
                for ([_]?*c.AdwPasswordEntryRow{ acc.current_password, acc.new_password, acc.confirm_password }) |row| {
                    if (row) |e| c.gtk_editable_set_text(@ptrCast(@alignCast(e)), "");
                }
                w.toast("Password changed.");
            },
            .language => {
                w.toast("Saved.");
                // Catalog text (formats, sort names) comes back in the new language.
                for ([_]@import("window.zig").Section{ .search, .new_titles }) |sec| if (w.list(sec)) |l| l.reloadIfLoaded();
            },
            .setting => w.toast("Saved."),
        }
        acc.reloadPatron();
    }

    fn onPatron(data: ?*anyopaque, r: *core.Result) void {
        const acc: *Account = @ptrCast(@alignCast(data.?));
        const w = acc.window;
        if (w.finishPending()) return;
        if (!r.ok) return;
        const patron = r.keep(capi.Patron) orelse return;
        w.setPatron(patron);
        // Borrowing history turned on syncs the index; turned off, it is cleared.
        if (w.borrowed) |b| b.patronChanged(patron);
        acc.refresh();
    }

    fn onEmail(row: *c.AdwEntryRow, data: ?*anyopaque) callconv(.c) void {
        const acc: *Account = @ptrCast(@alignCast(data.?));
        const email = std.mem.span(c.gtk_editable_get_text(@ptrCast(@alignCast(row))));
        if (std.mem.findScalar(u8, email, '@') == null) return acc.window.toast("Enter a valid email address.");
        const j = acc.job() orelse return;
        j.start(capi.biblio_change_email, .{ acc.window.client, j.z(email) });
    }

    fn onChangePassword(_: *c.AdwButtonRow, data: ?*anyopaque) callconv(.c) void {
        const acc: *Account = @ptrCast(@alignCast(data.?));
        const current = std.mem.span(c.gtk_editable_get_text(@ptrCast(@alignCast(acc.current_password.?))));
        const new = std.mem.span(c.gtk_editable_get_text(@ptrCast(@alignCast(acc.new_password.?))));
        const confirm = std.mem.span(c.gtk_editable_get_text(@ptrCast(@alignCast(acc.confirm_password.?))));
        if (current.len == 0 or new.len == 0) return;
        if (!std.mem.eql(u8, new, confirm)) return acc.window.toast("The new passwords don’t match.");
        if (acc.changing_password) return;
        const password = core.gpa.dupe(u8, new) catch return;
        const j = acc.saveJob(.{ .account = acc, .kind = .password, .password = password }) orelse {
            std.crypto.secureZero(u8, password);
            return core.gpa.free(password);
        };
        acc.changing_password = true;
        if (acc.change_password) |b| c.gtk_widget_set_sensitive(b, 0);
        j.start(capi.biblio_change_password, .{ acc.window.client, j.z(current), j.z(new) });
    }

    fn onPickup(row: *c.AdwComboRow, _: ?*c.GParamSpec, data: ?*anyopaque) callconv(.c) void {
        const acc: *Account = @ptrCast(@alignCast(data.?));
        if (acc.filling) return;
        const i = c.adw_combo_row_get_selected(row);
        if (i >= acc.pickup_ids.len) return;
        const j = acc.job() orelse return;
        j.start(capi.biblio_set_pickup, .{ acc.window.client, j.z(acc.pickup_ids[i]) });
    }

    fn onLanguage(row: *c.AdwComboRow, _: ?*c.GParamSpec, data: ?*anyopaque) callconv(.c) void {
        const acc: *Account = @ptrCast(@alignCast(data.?));
        if (acc.filling) return;
        const i = c.adw_combo_row_get_selected(row);
        if (i >= acc.language_ids.len) return;
        acc.updateSystemLanguage();
        // The catalog lists reload once the library has the new language.
        const j = acc.saveJob(.{ .account = acc, .kind = .language }) orelse return;
        j.start(capi.biblio_set_language, .{ acc.window.client, j.z(acc.language_ids[i]) });
    }

    fn setHistory(acc: *Account, enabled: bool) void {
        const j = acc.job() orelse return;
        j.start(capi.biblio_set_borrowing_history, .{ acc.window.client, enabled });
    }

    /// Turning history off can delete it, so it asks first.
    fn onHistory(row: *c.AdwSwitchRow, _: ?*c.GParamSpec, data: ?*anyopaque) callconv(.c) void {
        const acc: *Account = @ptrCast(@alignCast(data.?));
        if (acc.filling) return;
        if (c.adw_switch_row_get_active(row) != 0) return acc.setHistory(true);
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
            acc.setHistory(false);
        } else if (acc.history) |h| {
            acc.filling = true;
            c.adw_switch_row_set_active(h, 1);
            acc.filling = false;
        }
    }
};
