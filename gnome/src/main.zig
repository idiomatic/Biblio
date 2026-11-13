//! Biblio for GNOME: a BiblioCommons library app following the GNOME Human Interface
//! Guidelines, built on libadwaita and the shared Zig core (libbiblio).
//!
//! The launcher lists added libraries and their users; each signed-in user (or guest)
//! gets a window of their own, like the Apple app.

const std = @import("std");
const gtk = @import("gtk.zig");
const c = gtk.c;
const core = @import("core.zig");
const store = @import("store.zig");
const icons = @import("icons.zig");
const log = @import("log.zig");
const about = @import("about.zig");
const Window = @import("window.zig").Window;

pub const app_id = "com.rbrian.Biblio";
pub var app: *c.AdwApplication = undefined;

pub fn main() void {
    app = c.adw_application_new(app_id, c.G_APPLICATION_DEFAULT_FLAGS).?;
    gtk.connect(app, "activate", &onActivate, null);
    gtk.connect(app, "startup", &onStartup, null);
    const status = c.g_application_run(@ptrCast(@alignCast(app)), 0, null);
    c.g_object_unref(app);
    std.process.exit(@intCast(status));
}

fn onStartup(_: *c.GApplication, _: ?*anyopaque) callconv(.c) void {
    store.load();
    installStyles();
    // Ctrl+N opens another launcher, for signing in to a second account side by side.
    const actions = [_]struct { name: [*:0]const u8, handler: *const fn (*c.GSimpleAction, ?*c.GVariant, ?*anyopaque) callconv(.c) void }{
        .{ .name = "new-window", .handler = &onNewWindow },
        .{ .name = "about", .handler = &onAbout },
        .{ .name = "copy-log", .handler = &onCopyLog },
        .{ .name = "quit", .handler = &onQuit },
    };
    for (actions) |action| {
        const simple = c.g_simple_action_new(action.name, null);
        gtk.connect(simple, "activate", action.handler, null);
        c.g_action_map_add_action(@ptrCast(@alignCast(app)), @ptrCast(@alignCast(simple)));
        c.g_object_unref(simple);
    }
    accelerate("app.new-window", &.{"<Control>n"});
    accelerate("app.quit", &.{"<Control>q"});
    accelerate("win.refresh", &.{ "<Control>r", "F5" });
    accelerate("win.search", &.{"<Control>f"});
    accelerate("win.advanced-search", &.{"<Control><Shift>f"});
    accelerate("win.show-help-overlay", &.{ "<Control>question", "<Control>F1" });
    accelerate("window.close", &.{"<Control>w"});
}

fn accelerate(action: [*:0]const u8, comptime keys: []const [*:0]const u8) void {
    var list: [keys.len + 1]?[*:0]const u8 = undefined;
    inline for (keys, 0..) |k, i| list[i] = k;
    list[keys.len] = null;
    c.gtk_application_set_accels_for_action(@ptrCast(@alignCast(app)), action, @ptrCast(&list));
}

fn onAbout(_: *c.GSimpleAction, _: ?*c.GVariant, _: ?*anyopaque) callconv(.c) void {
    const active = c.gtk_application_get_active_window(@ptrCast(@alignCast(app)));
    about.present(if (active) |w| gtk.widget(w) else null);
}

fn onCopyLog(_: *c.GSimpleAction, _: ?*c.GVariant, _: ?*anyopaque) callconv(.c) void {
    log.copyReport();
    const active = c.gtk_application_get_active_window(@ptrCast(@alignCast(app)));
    const w = active orelse return;
    // Said in the window's toasts, if it is one of ours.
    if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(w)), c.adw_application_window_get_type()) == 0) return;
    const content = c.adw_application_window_get_content(@ptrCast(@alignCast(w))) orelse return;
    if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(content)), c.adw_toast_overlay_get_type()) == 0) return;
    c.adw_toast_overlay_add_toast(@ptrCast(@alignCast(content)), c.adw_toast_new("The diagnostic log is on your clipboard."));
}

fn onQuit(_: *c.GSimpleAction, _: ?*c.GVariant, _: ?*anyopaque) callconv(.c) void {
    log.sync();
    c.g_application_quit(@ptrCast(@alignCast(app)));
}

/// The header bar's main menu: new window, refresh, shortcuts, About, and the diagnostic log.
/// Launchers have no refresh.
pub fn primaryMenu(with_window_actions: bool) *c.GtkWidget {
    const menu = c.g_menu_new();
    const first = c.g_menu_new();
    c.g_menu_append(first, "_New Window", "app.new-window");
    if (with_window_actions) {
        c.g_menu_append(first, "_Refresh", "win.refresh");
        c.g_menu_append(first, "_Advanced Search…", "win.advanced-search");
    }
    c.g_menu_append_section(menu, null, @ptrCast(@alignCast(first)));
    const second = c.g_menu_new();
    if (with_window_actions) c.g_menu_append(second, "_Keyboard Shortcuts", "win.show-help-overlay");
    c.g_menu_append(second, "_About Biblio", "app.about");
    c.g_menu_append(second, "Copy _Diagnostic Log", "app.copy-log");
    c.g_menu_append(second, "_Quit", "app.quit");
    c.g_menu_append_section(menu, null, @ptrCast(@alignCast(second)));
    const button = c.gtk_menu_button_new();
    c.gtk_menu_button_set_icon_name(@ptrCast(@alignCast(button)), "open-menu-symbolic");
    c.gtk_menu_button_set_menu_model(@ptrCast(@alignCast(button)), @ptrCast(@alignCast(menu)));
    c.gtk_menu_button_set_primary(@ptrCast(@alignCast(button)), 1);
    c.gtk_widget_set_tooltip_text(button, "Main Menu");
    c.g_object_unref(first);
    c.g_object_unref(second);
    c.g_object_unref(menu);
    return button;
}

/// A new Keyboard Shortcuts window for a window's help overlay (each window takes its own).
pub fn shortcutsWindow() *c.GtkShortcutsWindow {
    const xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<interface>
        \\  <object class="GtkShortcutsWindow" id="shortcuts">
        \\    <property name="modal">true</property>
        \\    <child>
        \\      <object class="GtkShortcutsSection">
        \\        <property name="section-name">shortcuts</property>
        \\        <property name="max-height">12</property>
        \\        <child>
        \\          <object class="GtkShortcutsGroup">
        \\            <property name="title">Biblio</property>
        \\            <child><object class="GtkShortcutsShortcut"><property name="title">Search the Catalog</property><property name="accelerator">&lt;Control&gt;f</property></object></child>
        \\            <child><object class="GtkShortcutsShortcut"><property name="title">Advanced Search</property><property name="accelerator">&lt;Control&gt;&lt;Shift&gt;f</property></object></child>
        \\            <child><object class="GtkShortcutsShortcut"><property name="title">Refresh</property><property name="accelerator">&lt;Control&gt;r F5</property></object></child>
        \\            <child><object class="GtkShortcutsShortcut"><property name="title">New Window</property><property name="accelerator">&lt;Control&gt;n</property></object></child>
        \\            <child><object class="GtkShortcutsShortcut"><property name="title">Close Window</property><property name="accelerator">&lt;Control&gt;w</property></object></child>
        \\            <child><object class="GtkShortcutsShortcut"><property name="title">Keyboard Shortcuts</property><property name="accelerator">&lt;Control&gt;question</property></object></child>
        \\            <child><object class="GtkShortcutsShortcut"><property name="title">Quit</property><property name="accelerator">&lt;Control&gt;q</property></object></child>
        \\          </object>
        \\        </child>
        \\        <child>
        \\          <object class="GtkShortcutsGroup">
        \\            <property name="title">Lists</property>
        \\            <child><object class="GtkShortcutsShortcut"><property name="title">Select Several Items</property><property name="accelerator">&lt;Control&gt;space</property></object></child>
        \\            <child><object class="GtkShortcutsShortcut"><property name="title">Select a Range</property><property name="accelerator">&lt;Shift&gt;Down</property></object></child>
        \\            <child><object class="GtkShortcutsShortcut"><property name="title">Select All</property><property name="accelerator">&lt;Control&gt;a</property></object></child>
        \\          </object>
        \\        </child>
        \\      </object>
        \\    </child>
        \\  </object>
        \\</interface>
    ;
    const builder = c.gtk_builder_new_from_string(xml, -1);
    defer c.g_object_unref(builder);
    const obj = c.gtk_builder_get_object(builder, "shortcuts");
    // The builder's reference goes with it; the window needs its own.
    _ = c.g_object_ref(obj);
    return @ptrCast(@alignCast(obj));
}

fn onActivate(_: *c.GApplication, _: ?*anyopaque) callconv(.c) void {
    Launcher.open();
}

fn onNewWindow(_: *c.GSimpleAction, _: ?*c.GVariant, _: ?*anyopaque) callconv(.c) void {
    Launcher.open();
}

/// Copy-status colors from the libadwaita palette; text and icons always say the status too.
fn installStyles() void {
    const css =
        \\.copy-available { color: @success_color; }
        \\.copy-onOrder { color: @accent_color; }
        \\.copy-out, .copy-other { color: @warning_color; }
        \\.copy-held { color: @purple_3; }
        \\.copy-ready { color: @success_color; }
        \\.copy-paused { color: @warning_color; }
        \\.capsule { background: alpha(currentColor, 0.12); border-radius: 999px; padding: 1px 10px; }
        \\.status-bar { padding: 2px 12px; }
        \\.copy-transit { color: @blue_3; }
        \\.copy-repair { color: @brown_3; }
        \\.copy-missing, .copy-claimsReturned { color: @error_color; }
        \\.copy-withdrawn, .copy-libraryUseOnly { color: alpha(currentColor, 0.6); }
        \\.barcode { background: white; border-radius: 8px; padding: 12px; color: black; }
        \\.jacket { border-radius: 4px; }
        \\.library-icon { border-radius: 8px; box-shadow: inset 0 0 0 1px alpha(currentColor, 0.12); }
        \\.library-icon.logo { background: white; }
        \\.library-icon.fallback { background: @accent_bg_color; color: @accent_fg_color; font-weight: bold; }
    ;
    const provider = c.gtk_css_provider_new();
    c.gtk_css_provider_load_from_string(provider, css);
    c.gtk_style_context_add_provider_for_display(c.gdk_display_get_default(), @ptrCast(@alignCast(provider)), c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
}

// MARK: Launcher

/// Chooses a library and a user (or guest), then opens that account's window.
pub const Launcher = struct {
    window: *c.AdwApplicationWindow,
    nav: *c.AdwNavigationView,
    toasts: *c.AdwToastOverlay,
    libraries_group: ?*c.AdwPreferencesGroup = null,
    libraries_list: ?*c.GtkListBox = null,
    root_page: *c.GtkWidget,
    arena: std.heap.ArenaAllocator,
    /// The library pages pushed, which follow windows opening and closing.
    pages: std.ArrayList(*LibraryPage) = .empty,

    var launchers: std.ArrayList(*Launcher) = .empty;

    /// Windows opened or closed: users and libraries in use can't be removed.
    pub fn windowsChanged() void {
        for (launchers.items) |l| for (l.pages.items) |lp| {
            fillUsers(lp);
            lp.updateRemove();
        };
    }

    pub fn open() void {
        const l = core.gpa.create(Launcher) catch return;
        const window: *c.AdwApplicationWindow = @ptrCast(@alignCast(c.adw_application_window_new(@ptrCast(app))));
        c.gtk_window_set_title(@ptrCast(@alignCast(window)), "Biblio");
        c.gtk_window_set_default_size(@ptrCast(@alignCast(window)), 460, 600);
        const toasts: *c.AdwToastOverlay = @ptrCast(@alignCast(c.adw_toast_overlay_new()));
        const nav: *c.AdwNavigationView = @ptrCast(@alignCast(c.adw_navigation_view_new()));
        c.adw_toast_overlay_set_child(toasts, gtk.widget(nav));
        c.adw_application_window_set_content(window, gtk.widget(toasts));
        l.* = .{ .window = window, .nav = nav, .toasts = toasts, .root_page = undefined, .arena = .init(core.gpa) };
        l.root_page = l.librariesPage();
        c.adw_navigation_view_add(nav, @ptrCast(@alignCast(l.root_page)));
        gtk.connect(window, "destroy", &onDestroy, l);
        launchers.append(core.gpa, l) catch {};
        c.gtk_window_present(@ptrCast(@alignCast(window)));
    }

    fn onDestroy(_: *c.GtkWidget, data: ?*anyopaque) callconv(.c) void {
        const l: *Launcher = @ptrCast(@alignCast(data.?));
        for (launchers.items, 0..) |other, i| if (other == l) {
            _ = launchers.swapRemove(i);
            break;
        };
        l.pages.deinit(core.gpa);
        l.arena.deinit();
        core.gpa.destroy(l);
    }

    fn a(l: *Launcher) std.mem.Allocator {
        return l.arena.allocator();
    }

    fn page(title: [*:0]const u8, content: *c.GtkWidget, header_end: ?*c.GtkWidget) *c.GtkWidget {
        const toolbar = c.adw_toolbar_view_new();
        const header = c.adw_header_bar_new();
        if (header_end) |w| c.adw_header_bar_pack_end(@ptrCast(@alignCast(header)), w);
        c.adw_toolbar_view_add_top_bar(@ptrCast(@alignCast(toolbar)), header);
        c.adw_toolbar_view_set_content(@ptrCast(@alignCast(toolbar)), content);
        return gtk.widget(c.adw_navigation_page_new(toolbar, title));
    }

    fn librariesPage(l: *Launcher) *c.GtkWidget {
        const prefs = c.adw_preferences_page_new();
        const group: *c.AdwPreferencesGroup = @ptrCast(@alignCast(c.adw_preferences_group_new()));
        c.adw_preferences_group_set_title(group, "Libraries");
        c.adw_preferences_page_add(@ptrCast(@alignCast(prefs)), group);
        l.libraries_group = group;
        l.libraries_list = gtk.boxedList(group);
        l.fillLibraries();

        const add_group = c.adw_preferences_group_new();
        const add = c.adw_button_row_new();
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(add)), "Add Library…");
        c.adw_button_row_set_start_icon_name(@ptrCast(@alignCast(add)), "list-add-symbolic");
        gtk.connect(add, "activated", &onAddLibrary, l);
        c.adw_preferences_group_add(@ptrCast(@alignCast(add_group)), add);
        c.adw_preferences_page_add(@ptrCast(@alignCast(prefs)), @ptrCast(@alignCast(add_group)));
        return page("Biblio", prefs, primaryMenu(false));
    }

    fn fillLibraries(l: *Launcher) void {
        const group = l.libraries_group orelse return;
        const rows = l.libraries_list orelse return;
        c.gtk_list_box_remove_all(rows);
        c.gtk_widget_set_visible(gtk.widget(rows), @intFromBool(store.libraries.items.len > 0));
        if (store.libraries.items.len == 0) {
            c.adw_preferences_group_set_description(group, "Add your library to search its catalog and manage holds.");
        } else {
            c.adw_preferences_group_set_description(group, null);
        }
        for (store.libraries.items, 0..) |lib, i| {
            const row = c.adw_action_row_new();
            c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), gtk.z(l.a(), store.name(lib)));
            const n = store.users(lib).len;
            const subtitle = if (n == 0) "No users" else if (n == 1) "1 user" else std.fmt.allocPrint(l.a(), "{d} users", .{n}) catch "";
            c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), gtk.z(l.a(), subtitle));
            c.gtk_list_box_row_set_activatable(@ptrCast(@alignCast(row)), 1);
            const sub = store.subdomain(lib);
            c.adw_action_row_add_prefix(@ptrCast(@alignCast(row)), icons.tile(store.name(lib), icons.key(l.a(), store.website(lib), sub), store.website(lib), sub, null));
            c.adw_action_row_add_suffix(@ptrCast(@alignCast(row)), c.gtk_image_new_from_icon_name("go-next-symbolic"));
            c.g_object_set_data(@ptrCast(@alignCast(row)), "index", @ptrFromInt(i + 1));
            gtk.connect(row, "activated", &onLibrary, l);
            c.gtk_list_box_append(rows, row);
        }
    }

    fn onLibrary(row: *c.AdwActionRow, data: ?*anyopaque) callconv(.c) void {
        const l: *Launcher = @ptrCast(@alignCast(data.?));
        const i = @intFromPtr(c.g_object_get_data(@ptrCast(@alignCast(row)), "index")) - 1;
        if (i >= store.libraries.items.len) return;
        c.adw_navigation_view_push(l.nav, @ptrCast(@alignCast(l.libraryPage(store.libraries.items[i]))));
    }

    // MARK: One library

    const LibraryPage = struct {
        launcher: *Launcher,
        subdomain: []const u8,
        users: *c.GtkListBox,
        remove: *c.GtkWidget,

        /// A library with a window open can't be removed.
        fn updateRemove(lp: *LibraryPage) void {
            const open_now = Window.libraryIsOpen(lp.subdomain);
            c.gtk_widget_set_sensitive(lp.remove, @intFromBool(!open_now));
            c.gtk_widget_set_tooltip_text(lp.remove, if (open_now) "Close the library’s windows to remove it." else "Remove Library");
        }
    };

    fn libraryPage(l: *Launcher, lib: std.json.Value) *c.GtkWidget {
        const lp = l.a().create(LibraryPage) catch unreachable;
        const prefs = c.adw_preferences_page_new();
        const users: *c.AdwPreferencesGroup = @ptrCast(@alignCast(c.adw_preferences_group_new()));
        c.adw_preferences_group_set_title(users, "Users");
        c.adw_preferences_page_add(@ptrCast(@alignCast(prefs)), users);
        const remove = c.gtk_button_new_from_icon_name("user-trash-symbolic");
        lp.* = .{ .launcher = l, .subdomain = l.a().dupe(u8, store.subdomain(lib)) catch "", .users = gtk.boxedList(users), .remove = remove };
        l.pages.append(core.gpa, lp) catch {};
        fillUsers(lp);

        const guest_group: *c.AdwPreferencesGroup = @ptrCast(@alignCast(c.adw_preferences_group_new()));
        c.adw_preferences_group_set_description(guest_group, "Guests can search and browse the catalog but can’t place holds or see an account.");
        const guest = c.adw_button_row_new();
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(guest)), "Browse as Guest");
        c.adw_button_row_set_start_icon_name(@ptrCast(@alignCast(guest)), "avatar-default-symbolic");
        gtk.connect(guest, "activated", &onGuest, lp);
        c.adw_preferences_group_add(guest_group, guest);
        c.adw_preferences_page_add(@ptrCast(@alignCast(prefs)), guest_group);

        gtk.connect(remove, "clicked", &onRemoveLibrary, lp);
        lp.updateRemove();
        return page(gtk.z(l.a(), store.shortName(lib)), prefs, remove);
    }

    fn fillUsers(lp: *LibraryPage) void {
        const l = lp.launcher;
        const rows = lp.users;
        c.gtk_list_box_remove_all(rows);
        const i = store.find(lp.subdomain) orelse return;
        for (store.users(store.libraries.items[i])) |u| {
            if (u != .string) continue;
            const row = c.adw_action_row_new();
            c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), gtk.z(l.a(), u.string));
            c.adw_action_row_add_prefix(@ptrCast(@alignCast(row)), c.gtk_image_new_from_icon_name("avatar-default-symbolic"));
            c.gtk_list_box_row_set_activatable(@ptrCast(@alignCast(row)), 1);
            c.g_object_set_data(@ptrCast(@alignCast(row)), "username", @ptrCast(@alignCast(@constCast(gtk.z(l.a(), u.string)))));
            gtk.connect(row, "activated", &onUser, lp);
            const forget = c.gtk_button_new_from_icon_name("edit-delete-symbolic");
            c.gtk_widget_set_valign(forget, c.GTK_ALIGN_CENTER);
            c.gtk_widget_add_css_class(forget, "flat");
            // A login with a window open can't be removed: its session is in use.
            const in_use = Window.isOpen(lp.subdomain, u.string);
            c.gtk_widget_set_sensitive(forget, @intFromBool(!in_use));
            c.gtk_widget_set_tooltip_text(forget, if (in_use) "Close its window to remove this user." else "Remove User");
            if (in_use) c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), "Open in a window");
            c.g_object_set_data(@ptrCast(@alignCast(forget)), "username", @ptrCast(@alignCast(@constCast(gtk.z(l.a(), u.string)))));
            gtk.connect(forget, "clicked", &onRemoveUser, lp);
            c.adw_action_row_add_suffix(@ptrCast(@alignCast(row)), forget);
            c.gtk_list_box_append(rows, row);
        }
        const add = c.adw_button_row_new();
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(add)), "Add User…");
        c.adw_button_row_set_start_icon_name(@ptrCast(@alignCast(add)), "list-add-symbolic");
        gtk.connect(add, "activated", &onAddUser, lp);
        c.gtk_list_box_append(rows, add);
    }

    fn onUser(row: *c.AdwActionRow, data: ?*anyopaque) callconv(.c) void {
        const lp: *LibraryPage = @ptrCast(@alignCast(data.?));
        const name: [*:0]const u8 = @ptrCast(@alignCast(c.g_object_get_data(@ptrCast(row), "username") orelse return));
        if (Window.open(lp.subdomain, std.mem.span(name)) == null) return lp.launcher.toast("Biblio couldn’t open that account.");
        c.gtk_window_close(@ptrCast(@alignCast(lp.launcher.window)));
    }

    fn onGuest(_: *c.AdwButtonRow, data: ?*anyopaque) callconv(.c) void {
        const lp: *LibraryPage = @ptrCast(@alignCast(data.?));
        if (Window.open(lp.subdomain, "") == null) return lp.launcher.toast("Biblio couldn’t open that library.");
        c.gtk_window_close(@ptrCast(@alignCast(lp.launcher.window)));
    }

    fn onRemoveUser(button: *c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const lp: *LibraryPage = @ptrCast(@alignCast(data.?));
        const name: [*:0]const u8 = @ptrCast(@alignCast(c.g_object_get_data(@ptrCast(button), "username") orelse return));
        store.removeUser(lp.subdomain, std.mem.span(name));
        fillUsers(lp);
        lp.launcher.fillLibraries();
    }

    /// Removes at once when no users would be lost; otherwise asks first.
    fn onRemoveLibrary(_: *c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const lp: *LibraryPage = @ptrCast(@alignCast(data.?));
        const i = store.find(lp.subdomain) orelse return;
        if (store.users(store.libraries.items[i]).len == 0) return removeLibrary(lp);
        const heading = std.fmt.allocPrintSentinel(lp.launcher.a(), "Remove {s}?", .{store.name(store.libraries.items[i])}, 0) catch return;
        const dialog = c.adw_alert_dialog_new(heading.ptr, "Its saved users and passwords will also be removed from this device.");
        c.adw_alert_dialog_add_response(@ptrCast(@alignCast(dialog)), "cancel", "_Cancel");
        c.adw_alert_dialog_add_response(@ptrCast(@alignCast(dialog)), "remove", "_Remove");
        c.adw_alert_dialog_set_response_appearance(@ptrCast(@alignCast(dialog)), "remove", c.ADW_RESPONSE_DESTRUCTIVE);
        c.adw_alert_dialog_set_close_response(@ptrCast(@alignCast(dialog)), "cancel");
        gtk.connect(dialog, "response", &onRemoveResponse, lp);
        c.adw_dialog_present(@ptrCast(@alignCast(dialog)), gtk.widget(lp.launcher.window));
    }

    fn onRemoveResponse(_: *c.AdwAlertDialog, response: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
        if (std.mem.eql(u8, std.mem.span(response), "remove")) removeLibrary(@ptrCast(@alignCast(data.?)));
    }

    fn removeLibrary(lp: *LibraryPage) void {
        store.remove(lp.subdomain);
        lp.launcher.fillLibraries();
        _ = c.adw_navigation_view_pop(lp.launcher.nav);
    }

    fn onAddLibrary(_: *c.AdwButtonRow, data: ?*anyopaque) callconv(.c) void {
        const l: *Launcher = @ptrCast(@alignCast(data.?));
        @import("add.zig").AddLibrary.present(l);
    }

    fn onAddUser(_: *c.AdwButtonRow, data: ?*anyopaque) callconv(.c) void {
        const lp: *LibraryPage = @ptrCast(@alignCast(data.?));
        @import("add.zig").AddUser.present(gtk.widget(lp.launcher.window), lp.subdomain, lp, &userAddedFromDialog, null);
    }

    /// Called by the Add Library dialog once the library is saved.
    pub fn libraryAdded(l: *Launcher) void {
        l.fillLibraries();
    }

    /// Called by the Add User dialog after a successful sign-in.
    fn userAddedFromDialog(ctx: ?*anyopaque, subdomain: []const u8, username: []const u8) void {
        const lp: *LibraryPage = @ptrCast(@alignCast(ctx.?));
        const l = lp.launcher;
        fillUsers(lp);
        l.fillLibraries();
        if (Window.open(subdomain, username) == null) return l.toast("Biblio couldn’t open that account.");
        c.gtk_window_close(@ptrCast(@alignCast(l.window)));
    }

    pub fn toast(l: *Launcher, message: []const u8) void {
        gtk.toast(l.toasts, message, l.a());
    }
};
