//! The guest window's sign-in sheet: the library's saved users, and Add User… (or, with none
//! saved, the sign-in form). Choosing one opens that login's window where this one left off.

const std = @import("std");
const gtk = @import("gtk.zig");
const c = gtk.c;
const core = @import("core.zig");
const store = @import("store.zig");
const Window = @import("window.zig").Window;
const AddUser = @import("add.zig").AddUser;

pub const SignIn = struct {
    window: *Window,
    /// The dialogs open (the sheet, and the sign-in form over it); freed when none are.
    open_dialogs: u32 = 0,
    /// The sheet of saved users, while it is open.
    dialog: ?*c.AdwDialog = null,

    pub fn present(w: *Window) void {
        const s = core.gpa.create(SignIn) catch return;
        s.* = .{ .window = w };
        // The window outlives the sheet: the sign-in form calls back after the window may close.
        w.pending += 1;
        if (store.users(w.library).len == 0) return s.addUser();
        s.sheet();
    }

    fn sheet(s: *SignIn) void {
        const w = s.window;
        const dialog: *c.AdwDialog = @ptrCast(@alignCast(c.adw_dialog_new()));
        c.adw_dialog_set_title(dialog, "Sign In");
        c.adw_dialog_set_content_width(dialog, 380);
        const toolbar = c.adw_toolbar_view_new();
        c.adw_toolbar_view_add_top_bar(@ptrCast(@alignCast(toolbar)), c.adw_header_bar_new());
        const prefs = c.adw_preferences_page_new();
        const group: *c.AdwPreferencesGroup = @ptrCast(@alignCast(c.adw_preferences_group_new()));
        c.adw_preferences_group_set_description(group, "Choose a user to sign in as. Your search and the item you are looking at stay as they are.");
        const rows = gtk.boxedList(group);
        for (store.users(w.library)) |u| {
            if (u != .string) continue;
            const row = c.adw_action_row_new();
            c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), gtk.z(w.a(), u.string));
            c.adw_action_row_add_prefix(@ptrCast(@alignCast(row)), c.gtk_image_new_from_icon_name("avatar-default-symbolic"));
            if (Window.isOpen(w.subdomain, u.string)) {
                c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), "Open in another window");
                c.gtk_widget_set_sensitive(row, 0);
            } else {
                c.gtk_list_box_row_set_activatable(@ptrCast(@alignCast(row)), 1);
                c.adw_action_row_add_suffix(@ptrCast(@alignCast(row)), c.gtk_image_new_from_icon_name("go-next-symbolic"));
                c.g_object_set_data_full(@ptrCast(@alignCast(row)), "username", c.g_strdup(gtk.z(w.a(), u.string)), c.g_free);
                gtk.connect(row, "activated", &onUser, s);
            }
            c.gtk_list_box_append(rows, row);
        }
        const add = c.adw_button_row_new();
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(add)), "Add User…");
        c.adw_button_row_set_start_icon_name(@ptrCast(@alignCast(add)), "list-add-symbolic");
        gtk.connect(add, "activated", &onAddUser, s);
        c.gtk_list_box_append(rows, add);
        c.adw_preferences_page_add(@ptrCast(@alignCast(prefs)), group);
        c.adw_toolbar_view_set_content(@ptrCast(@alignCast(toolbar)), prefs);
        c.adw_dialog_set_child(dialog, toolbar);
        s.open_dialogs += 1;
        gtk.connect(dialog, "closed", &onSheetClosed, s);
        c.adw_dialog_present(dialog, gtk.widget(w.window));
        s.dialog = dialog;
    }

    fn onUser(row: *c.AdwActionRow, data: ?*anyopaque) callconv(.c) void {
        const s: *SignIn = @ptrCast(@alignCast(data.?));
        const name: [*:0]const u8 = @ptrCast(@alignCast(c.g_object_get_data(@ptrCast(row), "username") orelse return));
        const user = core.gpa.dupe(u8, std.mem.span(name)) catch return;
        defer core.gpa.free(user);
        const w = s.window;
        if (s.dialog) |d| _ = c.adw_dialog_close(d);
        w.continueAs(user);
    }

    fn onAddUser(_: *c.AdwButtonRow, data: ?*anyopaque) callconv(.c) void {
        const s: *SignIn = @ptrCast(@alignCast(data.?));
        s.addUser();
    }

    fn addUser(s: *SignIn) void {
        s.open_dialogs += 1;
        AddUser.present(gtk.widget(s.window.window), s.window.subdomain, s, &onAdded, &onFormClosed);
    }

    fn onAdded(ctx: ?*anyopaque, _: []const u8, username: []const u8) void {
        const s: *SignIn = @ptrCast(@alignCast(ctx.?));
        const w = s.window;
        if (s.dialog) |d| {
            s.dialog = null;
            _ = c.adw_dialog_close(d);
        }
        if (!w.closed) w.continueAs(username);
    }

    fn onFormClosed(ctx: ?*anyopaque) void {
        const s: *SignIn = @ptrCast(@alignCast(ctx.?));
        s.release();
    }

    fn onSheetClosed(_: *c.AdwDialog, data: ?*anyopaque) callconv(.c) void {
        const s: *SignIn = @ptrCast(@alignCast(data.?));
        s.dialog = null;
        s.release();
    }

    fn release(s: *SignIn) void {
        s.open_dialogs -= 1;
        if (s.open_dialogs > 0) return;
        const w = s.window;
        core.gpa.destroy(s);
        _ = w.finishPending();
    }
};
