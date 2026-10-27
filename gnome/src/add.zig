//! The "Add Library" and "Add User" dialogs.

const std = @import("std");
const gtk = @import("gtk.zig");
const c = gtk.c;
const core = @import("core.zig");
const store = @import("store.zig");
const Launcher = @import("main.zig").Launcher;

/// Finds a library by catalog subdomain or address, or by name from BiblioCommons' partner directory.
pub const AddLibrary = struct {
    launcher: *Launcher,
    dialog: *c.AdwDialog,
    entry: *c.AdwEntryRow,
    suggestions: *c.AdwPreferencesGroup,
    suggestion_rows: *c.GtkListBox,
    error_label: *c.GtkWidget,
    spinner: *c.GtkWidget,
    arena: std.heap.ArenaAllocator,
    /// The partner directory, loaded page by page in the background.
    directory: std.ArrayList(std.json.Value) = .empty,
    directory_arenas: std.ArrayList(*std.heap.ArenaAllocator) = .empty,
    busy: bool = false,
    closed: bool = false,

    pub fn present(l: *Launcher) void {
        const d = core.gpa.create(AddLibrary) catch return;
        const dialog: *c.AdwDialog = @ptrCast(@alignCast(c.adw_dialog_new()));
        c.adw_dialog_set_title(dialog, "Add Library");
        c.adw_dialog_set_content_width(dialog, 440);
        c.adw_dialog_set_content_height(dialog, 520);

        const prefs = c.adw_preferences_page_new();
        const group = c.adw_preferences_group_new();
        c.adw_preferences_group_set_description(@ptrCast(@alignCast(group)), "Enter the name before “.bibliocommons.com” in your library’s catalog address, or search by library name.");
        const entry: *c.AdwEntryRow = @ptrCast(@alignCast(c.adw_entry_row_new()));
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(entry)), "Library");
        c.adw_preferences_group_add(@ptrCast(@alignCast(group)), gtk.widget(entry));
        const error_label = gtk.label("", std.heap.c_allocator, &.{"error"});
        c.gtk_widget_set_visible(error_label, 0);
        c.gtk_widget_set_margin_top(error_label, 12);
        c.adw_preferences_group_add(@ptrCast(@alignCast(group)), error_label);
        c.adw_preferences_page_add(@ptrCast(@alignCast(prefs)), @ptrCast(@alignCast(group)));
        const suggestions: *c.AdwPreferencesGroup = @ptrCast(@alignCast(c.adw_preferences_group_new()));
        c.adw_preferences_page_add(@ptrCast(@alignCast(prefs)), suggestions);

        const toolbar = c.adw_toolbar_view_new();
        const header = c.adw_header_bar_new();
        c.adw_header_bar_set_show_end_title_buttons(@ptrCast(@alignCast(header)), 0);
        c.adw_header_bar_set_show_start_title_buttons(@ptrCast(@alignCast(header)), 0);
        const cancel = c.gtk_button_new_with_mnemonic("_Cancel");
        const add = c.gtk_button_new_with_mnemonic("_Add");
        c.gtk_widget_add_css_class(add, "suggested-action");
        const spinner = c.adw_spinner_new();
        c.gtk_widget_set_visible(spinner, 0);
        c.adw_header_bar_pack_start(@ptrCast(@alignCast(header)), cancel);
        c.adw_header_bar_pack_end(@ptrCast(@alignCast(header)), add);
        c.adw_header_bar_pack_end(@ptrCast(@alignCast(header)), spinner);
        c.adw_toolbar_view_add_top_bar(@ptrCast(@alignCast(toolbar)), header);
        c.adw_toolbar_view_set_content(@ptrCast(@alignCast(toolbar)), prefs);
        c.adw_dialog_set_child(dialog, toolbar);

        d.* = .{ .launcher = l, .dialog = dialog, .entry = entry, .suggestions = suggestions, .suggestion_rows = gtk.boxedList(suggestions), .error_label = error_label, .spinner = spinner, .arena = .init(core.gpa) };
        gtk.connect(cancel, "clicked", &onCancel, d);
        gtk.connect(add, "clicked", &onAdd, d);
        gtk.connect(entry, "entry-activated", &onEntryActivated, d);
        gtk.connect(entry, "changed", &onChanged, d);
        gtk.connect(dialog, "closed", &onClosed, d);
        c.adw_dialog_present(dialog, gtk.widget(l.window));
        d.loadDirectory(null);
    }

    fn a(d: *AddLibrary) std.mem.Allocator {
        return d.arena.allocator();
    }

    fn onClosed(_: *c.AdwDialog, data: ?*anyopaque) callconv(.c) void {
        const d: *AddLibrary = @ptrCast(@alignCast(data.?));
        d.closed = true;
        // Directory pages still loading call back into `d`, so it is freed when they finish.
        if (!d.busy) d.free();
    }

    fn free(d: *AddLibrary) void {
        for (d.directory_arenas.items) |arena| core.release(arena);
        d.directory_arenas.deinit(core.gpa);
        d.directory.deinit(core.gpa);
        d.arena.deinit();
        core.gpa.destroy(d);
    }

    fn loadDirectory(d: *AddLibrary, url: ?[]const u8) void {
        d.busy = true;
        core.call(null, .{ .op = "directoryPage", .url = url }, &onDirectoryPage, d);
    }

    fn onDirectoryPage(data: ?*anyopaque, r: *core.Result) void {
        const d: *AddLibrary = @ptrCast(@alignCast(data.?));
        d.busy = false;
        if (d.closed) return d.free();
        if (!r.ok) return;
        const entries = core.items(core.field(r.value, "entries"));
        if (entries.len == 0) return;
        d.directory_arenas.append(core.gpa, r.keep()) catch {};
        d.directory.appendSlice(core.gpa, entries) catch {};
        d.showSuggestions();
        if (core.str(r.value, "next")) |next| d.loadDirectory(next);
    }

    fn text(d: *AddLibrary) []const u8 {
        return std.mem.span(c.gtk_editable_get_text(@ptrCast(@alignCast(d.entry))));
    }

    fn onChanged(_: *c.GtkEditable, data: ?*anyopaque) callconv(.c) void {
        const d: *AddLibrary = @ptrCast(@alignCast(data.?));
        d.showSuggestions();
    }

    /// Up to twelve directory entries whose name or website contains the typed text.
    fn showSuggestions(d: *AddLibrary) void {
        const group = d.suggestions;
        const rows = d.suggestion_rows;
        c.gtk_list_box_remove_all(rows);
        c.gtk_widget_set_visible(gtk.widget(group), 0);
        const t = std.mem.trim(u8, d.text(), " ");
        if (t.len < 2) return;
        var shown: usize = 0;
        for (d.directory.items, 0..) |entry, i| {
            const name = core.str(entry, "name") orelse continue;
            const site = core.str(entry, "website") orelse "";
            if (std.ascii.findIgnoreCase(name, t) == null and std.ascii.findIgnoreCase(site, t) == null) continue;
            const row = c.adw_action_row_new();
            c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), gtk.z(d.a(), name));
            if (core.str(entry, "region")) |region| c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), gtk.z(d.a(), region));
            c.gtk_list_box_row_set_activatable(@ptrCast(@alignCast(row)), 1);
            c.g_object_set_data(@ptrCast(@alignCast(row)), "index", @ptrFromInt(i + 1));
            gtk.connect(row, "activated", &onSuggestion, d);
            c.gtk_list_box_append(rows, row);
            shown += 1;
            if (shown == 12) break;
        }
        c.adw_preferences_group_set_title(group, "Libraries Using BiblioCommons");
        c.gtk_widget_set_visible(gtk.widget(group), @intFromBool(shown > 0));
    }

    fn onSuggestion(row: *c.AdwActionRow, data: ?*anyopaque) callconv(.c) void {
        const d: *AddLibrary = @ptrCast(@alignCast(data.?));
        const i = @intFromPtr(c.g_object_get_data(@ptrCast(@alignCast(row)), "index")) - 1;
        if (i >= d.directory.items.len or d.busy) return;
        const entry = d.directory.items[i];
        d.setWorking(true);
        core.call(null, .{ .op = "resolveSubdomain", .name = core.str(entry, "name") orelse "", .website = core.str(entry, "website") }, &onResolved, d);
    }

    fn onResolved(data: ?*anyopaque, r: *core.Result) void {
        const d: *AddLibrary = @ptrCast(@alignCast(data.?));
        if (d.closed) {
            d.busy = false;
            return d.free();
        }
        if (r.ok and r.value == .string) return d.lookUp(r.value.string);
        d.setWorking(false);
        d.showError("Couldn’t find that library’s catalog. Enter its subdomain instead.");
    }

    fn onEntryActivated(_: *c.AdwEntryRow, data: ?*anyopaque) callconv(.c) void {
        onAdd(null, data);
    }

    fn onAdd(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const d: *AddLibrary = @ptrCast(@alignCast(data.?));
        if (d.busy) return;
        var scratch = std.heap.ArenaAllocator.init(core.gpa);
        defer scratch.deinit();
        const sub = core.now(scratch.allocator(), .{ .op = "subdomainFrom", .input = d.text() }) orelse return d.showError("Enter a library name or catalog address.");
        if (sub != .string) return d.showError("Enter a library name or catalog address.");
        d.setWorking(true);
        d.lookUp(d.a().dupe(u8, sub.string) catch return);
    }

    fn lookUp(d: *AddLibrary, subdomain: []const u8) void {
        d.busy = true;
        core.call(null, .{ .op = "libraryInfo", .subdomain = subdomain }, &onInfo, d);
    }

    fn onInfo(data: ?*anyopaque, r: *core.Result) void {
        const d: *AddLibrary = @ptrCast(@alignCast(data.?));
        if (d.closed) {
            d.busy = false;
            return d.free();
        }
        d.setWorking(false);
        if (!r.ok) return d.showError(r.message);
        store.upsert(r.value);
        d.launcher.libraryAdded();
        _ = c.adw_dialog_close(d.dialog);
    }

    fn setWorking(d: *AddLibrary, working: bool) void {
        d.busy = working;
        c.gtk_widget_set_visible(d.spinner, @intFromBool(working));
        c.gtk_widget_set_sensitive(gtk.widget(d.entry), @intFromBool(!working));
        if (working) c.gtk_widget_set_visible(d.error_label, 0);
    }

    fn showError(d: *AddLibrary, message: []const u8) void {
        c.gtk_label_set_text(@ptrCast(@alignCast(d.error_label)), gtk.z(d.a(), message));
        c.gtk_widget_set_visible(d.error_label, 1);
    }

    fn onCancel(_: *c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const d: *AddLibrary = @ptrCast(@alignCast(data.?));
        _ = c.adw_dialog_close(d.dialog);
    }
};

/// Signs in once to check the username and password, then saves them (password in the keyring).
pub const AddUser = struct {
    launcher: *Launcher,
    library_page: *anyopaque,
    subdomain: []const u8,
    dialog: *c.AdwDialog,
    username: *c.AdwEntryRow,
    password: *c.AdwPasswordEntryRow,
    error_label: *c.GtkWidget,
    sign_in: *c.GtkWidget,
    arena: std.heap.ArenaAllocator,
    client: ?*core.Client = null,
    user: []const u8 = "",
    /// The password saved before this sign-in, put back if it fails.
    previous: ?[]u8 = null,
    closed: bool = false,
    busy: bool = false,

    pub fn present(l: *Launcher, subdomain: []const u8, library_page: *anyopaque) void {
        const u = core.gpa.create(AddUser) catch return;
        const dialog: *c.AdwDialog = @ptrCast(@alignCast(c.adw_dialog_new()));
        c.adw_dialog_set_title(dialog, "Add User");
        c.adw_dialog_set_content_width(dialog, 400);

        const prefs = c.adw_preferences_page_new();
        const group = c.adw_preferences_group_new();
        c.adw_preferences_group_set_description(@ptrCast(@alignCast(group)), "Your password is stored in your keyring and used to sign in again automatically when the library ends your session.");
        const username: *c.AdwEntryRow = @ptrCast(@alignCast(c.adw_entry_row_new()));
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(username)), "Username or card number");
        const password: *c.AdwPasswordEntryRow = @ptrCast(@alignCast(c.adw_password_entry_row_new()));
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(password)), "PIN or password");
        c.adw_preferences_group_add(@ptrCast(@alignCast(group)), gtk.widget(username));
        c.adw_preferences_group_add(@ptrCast(@alignCast(group)), gtk.widget(password));
        const error_label = gtk.label("", std.heap.c_allocator, &.{"error"});
        c.gtk_widget_set_visible(error_label, 0);
        c.gtk_widget_set_margin_top(error_label, 12);
        c.adw_preferences_group_add(@ptrCast(@alignCast(group)), error_label);
        c.adw_preferences_page_add(@ptrCast(@alignCast(prefs)), @ptrCast(@alignCast(group)));

        const toolbar = c.adw_toolbar_view_new();
        const header = c.adw_header_bar_new();
        c.adw_header_bar_set_show_end_title_buttons(@ptrCast(@alignCast(header)), 0);
        c.adw_header_bar_set_show_start_title_buttons(@ptrCast(@alignCast(header)), 0);
        const cancel = c.gtk_button_new_with_mnemonic("_Cancel");
        const sign_in = c.gtk_button_new_with_mnemonic("_Sign In");
        c.gtk_widget_add_css_class(sign_in, "suggested-action");
        c.adw_header_bar_pack_start(@ptrCast(@alignCast(header)), cancel);
        c.adw_header_bar_pack_end(@ptrCast(@alignCast(header)), sign_in);
        c.adw_toolbar_view_add_top_bar(@ptrCast(@alignCast(toolbar)), header);
        c.adw_toolbar_view_set_content(@ptrCast(@alignCast(toolbar)), prefs);
        c.adw_dialog_set_child(dialog, toolbar);

        u.* = .{
            .launcher = l,
            .library_page = library_page,
            .subdomain = subdomain,
            .dialog = dialog,
            .username = username,
            .password = password,
            .error_label = error_label,
            .sign_in = sign_in,
            .arena = .init(core.gpa),
        };
        gtk.connect(cancel, "clicked", &onCancel, u);
        gtk.connect(sign_in, "clicked", &onSignIn, u);
        gtk.connect(password, "entry-activated", &onSignIn, u);
        gtk.connect(dialog, "closed", &onClosed, u);
        c.adw_dialog_present(dialog, gtk.widget(l.window));
    }

    fn onClosed(_: *c.AdwDialog, data: ?*anyopaque) callconv(.c) void {
        const u: *AddUser = @ptrCast(@alignCast(data.?));
        u.closed = true;
        if (!u.busy) u.free();
    }

    fn free(u: *AddUser) void {
        u.arena.deinit();
        core.gpa.destroy(u);
    }

    fn onSignIn(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
        const u: *AddUser = @ptrCast(@alignCast(data.?));
        if (u.busy) return;
        const user = std.mem.trim(u8, std.mem.span(c.gtk_editable_get_text(@ptrCast(@alignCast(u.username)))), " ");
        const pw = std.mem.span(c.gtk_editable_get_text(@ptrCast(@alignCast(u.password))));
        if (user.len == 0 or pw.len == 0) return;
        if (@import("window.zig").Window.isOpen(u.subdomain, user)) {
            // Signing in again would end the session of the window already using this login.
            return u.showError("This user is already signed in in another window. Close that window first.");
        }
        u.user = u.arena.allocator().dupe(u8, user) catch return;
        if (store.lookupPassword(u.subdomain, u.user)) |p| {
            u.previous = core.gpa.dupe(u8, std.mem.span(p)) catch null;
            store.freePassword(p);
        }
        if (!store.storePassword(u.subdomain, u.user, pw)) return u.showError("Biblio couldn’t save the password to your keyring.");
        u.busy = true;
        c.gtk_widget_set_sensitive(u.sign_in, 0);
        c.gtk_widget_set_visible(u.error_label, 0);
        u.client = core.client(u.subdomain, u.user);
        core.call(u.client, .{ .op = "login", .force = true }, &onLogin, u);
    }

    fn onLogin(data: ?*anyopaque, r: *core.Result) void {
        const u: *AddUser = @ptrCast(@alignCast(data.?));
        u.busy = false;
        if (u.client) |cl| @import("biblio").biblio_client_free(cl);
        u.client = null;
        if (!r.ok) {
            if (u.previous) |p| _ = store.storePassword(u.subdomain, u.user, p) else store.clearPassword(u.subdomain, u.user);
        }
        if (u.previous) |p| {
            std.crypto.secureZero(u8, p);
            core.gpa.free(p);
            u.previous = null;
        }
        if (u.closed) return u.free();
        c.gtk_widget_set_sensitive(u.sign_in, 1);
        if (!r.ok) return u.showError(r.message);
        store.addUser(u.subdomain, u.user);
        const launcher = u.launcher;
        const page = u.library_page;
        const subdomain = u.subdomain;
        const user = core.gpa.dupe(u8, u.user) catch return;
        defer core.gpa.free(user);
        _ = c.adw_dialog_close(u.dialog);
        launcher.userAdded(page, subdomain, user);
    }

    fn showError(u: *AddUser, message: []const u8) void {
        c.gtk_label_set_text(@ptrCast(@alignCast(u.error_label)), gtk.z(u.arena.allocator(), message));
        c.gtk_widget_set_visible(u.error_label, 1);
    }

    fn onCancel(_: *c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const u: *AddUser = @ptrCast(@alignCast(data.?));
        _ = c.adw_dialog_close(u.dialog);
    }
};
