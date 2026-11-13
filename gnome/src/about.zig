//! The About dialog: who made Biblio, who didn't, its version, and Copy Diagnostic Log.

const std = @import("std");
const gtk = @import("gtk.zig");
const c = gtk.c;
const biblio = @import("biblio");
const log = @import("log.zig");
const main = @import("main.zig");

pub const credits = "Biblio was made by people working together with AI assistants. They shared the work of planning, building, and testing the app.";
pub const independence = "Biblio is an independent app. It isn’t made by BiblioCommons or by your library.";

/// The copy link's address; the dialog handles it rather than opening it.
const copy_uri = "biblio:copy-diagnostic-log";

pub fn present(parent: ?*c.GtkWidget) void {
    const dialog: *c.AdwAboutDialog = @ptrCast(@alignCast(c.adw_about_dialog_new()));
    c.adw_about_dialog_set_application_name(dialog, "Biblio");
    c.adw_about_dialog_set_application_icon(dialog, main.app_id);
    c.adw_about_dialog_set_version(dialog, biblio.biblio_version());
    c.adw_about_dialog_set_developer_name(dialog, "Brian Harrison");
    c.adw_about_dialog_set_comments(dialog, credits ++ "\n\n" ++ independence);
    c.adw_about_dialog_set_license_type(dialog, c.GTK_LICENSE_BSD_3);
    c.adw_about_dialog_set_website(dialog, "https://github.com/idiomatic/Biblio");
    c.adw_about_dialog_add_link(dialog, "Copy Diagnostic Log", copy_uri);
    gtk.connect(dialog, "activate-link", &onLink, null);
    c.adw_dialog_present(@ptrCast(@alignCast(dialog)), parent);
}

fn onLink(dialog: *c.AdwAboutDialog, uri: [*:0]const u8, _: ?*anyopaque) callconv(.c) c.gboolean {
    if (!std.mem.eql(u8, std.mem.span(uri), copy_uri)) return 0;
    log.copyReport();
    // Said in the dialog, which covers the window's toasts.
    c.adw_about_dialog_set_comments(dialog, credits ++ "\n\n" ++ independence ++ "\n\nThe diagnostic log is on your clipboard.");
    return 1;
}
