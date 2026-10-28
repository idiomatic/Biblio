//! Small conveniences over the GTK, libadwaita and GLib C APIs.

const std = @import("std");
pub const c = @import("c");

pub fn widget(p: anytype) *c.GtkWidget {
    return @ptrCast(@alignCast(p));
}

pub fn object(p: anytype) *c.GObject {
    return @ptrCast(@alignCast(p));
}

pub fn as(comptime T: type, p: anytype) *T {
    return @ptrCast(@alignCast(p));
}

/// Connects a signal handler. `handler` must use the C calling convention.
pub fn connect(instance: anytype, signal: [*:0]const u8, handler: anytype, data: ?*anyopaque) void {
    _ = c.g_signal_connect_data(@ptrCast(@alignCast(instance)), signal, @ptrCast(@alignCast(handler)), data, null, 0);
}

/// Copies `s` into a NUL-terminated string for GTK, in the given arena.
pub fn z(a: std.mem.Allocator, s: []const u8) [*:0]const u8 {
    return (a.dupeSentinel(u8, s, 0) catch return "").ptr;
}

pub fn label(text: []const u8, a: std.mem.Allocator, classes: []const [*:0]const u8) *c.GtkWidget {
    const l = c.gtk_label_new(z(a, text));
    c.gtk_label_set_xalign(as(c.GtkLabel, l), 0);
    c.gtk_label_set_wrap(as(c.GtkLabel, l), 1);
    for (classes) |cls| c.gtk_widget_add_css_class(l, cls);
    return l;
}

pub fn box(vertical: bool, spacing: c_int) *c.GtkWidget {
    return c.gtk_box_new(if (vertical) c.GTK_ORIENTATION_VERTICAL else c.GTK_ORIENTATION_HORIZONTAL, spacing);
}

pub fn append(parent: *c.GtkWidget, child: *c.GtkWidget) void {
    c.gtk_box_append(as(c.GtkBox, parent), child);
}

pub fn margins(w: *c.GtkWidget, m: c_int) void {
    c.gtk_widget_set_margin_top(w, m);
    c.gtk_widget_set_margin_bottom(w, m);
    c.gtk_widget_set_margin_start(w, m);
    c.gtk_widget_set_margin_end(w, m);
}

/// Removes every child of a GtkBox.
pub fn clearBox(container: *c.GtkWidget) void {
    while (c.gtk_widget_get_first_child(container)) |child| c.gtk_box_remove(as(c.GtkBox, container), child);
}

pub fn toast(overlay: *c.AdwToastOverlay, message: []const u8, a: std.mem.Allocator) void {
    c.adw_toast_overlay_add_toast(overlay, c.adw_toast_new(z(a, message)));
}

/// Runs `func(data)` on the main loop once.
pub fn idle(func: *const fn (?*anyopaque) callconv(.c) c.gboolean, data: ?*anyopaque) void {
    _ = c.g_idle_add(func, data);
}

pub fn texture(bytes: []const u8) ?*c.GdkTexture {
    const gbytes = c.g_bytes_new(bytes.ptr, bytes.len);
    defer c.g_bytes_unref(gbytes);
    var err: ?*c.GError = null;
    const t = c.gdk_texture_new_from_bytes(gbytes, &err);
    if (err) |e| c.g_error_free(e);
    return t;
}

/// A boxed list inside a preferences group, whose rows can be replaced wholesale
/// (AdwPreferencesGroup has no way to enumerate the rows it was given).
pub fn boxedList(group: *c.AdwPreferencesGroup) *c.GtkListBox {
    const list: *c.GtkListBox = @ptrCast(@alignCast(c.gtk_list_box_new()));
    c.gtk_list_box_set_selection_mode(list, c.GTK_SELECTION_NONE);
    c.gtk_widget_add_css_class(widget(list), "boxed-list");
    c.adw_preferences_group_add(group, widget(list));
    return list;
}
