//! The library card as a scannable barcode (Codabar or Code 128, the library's sticky choice),
//! on the account page and in the window's Library Card dialog.

const std = @import("std");
const gtk = @import("gtk.zig");
const c = gtk.c;
const core = @import("core.zig");
const Symbology = @import("biblio").models.Symbology;

/// Black bars on white with quiet zones, scannable in dark mode too, with the number under
/// them. `height` is the bars' height.
pub fn card(value: []const u8, symbology: Symbology, height: c_int) *c.GtkWidget {
    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const box = gtk.box(true, 6);
    c.gtk_widget_add_css_class(box, "barcode");
    if (bars(value, symbology)) |area| {
        c.gtk_widget_set_size_request(area, 300, height);
        gtk.append(box, area);
    }
    const number = gtk.label(value, fba.allocator(), &.{"monospace"});
    c.gtk_label_set_xalign(@ptrCast(@alignCast(number)), 0.5);
    gtk.append(box, number);
    fba.reset();
    const description = std.fmt.allocPrint(fba.allocator(), "Library card barcode {s}", .{value}) catch "Library card barcode";
    c.gtk_accessible_update_property(@ptrCast(@alignCast(box)), c.GTK_ACCESSIBLE_PROPERTY_LABEL, gtk.z(fba.allocator(), description), @as(c_int, -1));
    return box;
}

const Bars = struct { widths: []const f64 };

/// A drawing area of the value's bars, or null if it can't be encoded.
fn bars(value: []const u8, symbology: Symbology) ?*c.GtkWidget {
    const widths = core.barcode(core.gpa, value, symbology);
    if (widths.len == 0) return null;
    const b = core.gpa.create(Bars) catch {
        core.gpa.free(widths);
        return null;
    };
    b.* = .{ .widths = widths };
    const area = c.gtk_drawing_area_new();
    c.gtk_drawing_area_set_draw_func(@ptrCast(@alignCast(area)), &draw, b, &freeBars);
    return area;
}

fn freeBars(data: ?*anyopaque) callconv(.c) void {
    const b: *Bars = @ptrCast(@alignCast(data.?));
    core.gpa.free(b.widths);
    core.gpa.destroy(b);
}

fn draw(_: [*c]c.GtkDrawingArea, cr: ?*c.cairo_t, width: c_int, height: c_int, data: ?*anyopaque) callconv(.c) void {
    const b: *Bars = @ptrCast(@alignCast(data.?));
    const quiet = 10.0;
    var total: f64 = 2 * quiet;
    for (b.widths) |e| total += e;
    // Whole device pixels per unit where they fit, so bars don't blur at the scanner.
    const exact = @as(f64, @floatFromInt(width)) / total;
    const unit = if (exact >= 1) @floor(exact) else exact;
    c.cairo_set_source_rgb(cr, 1, 1, 1);
    c.cairo_paint(cr);
    c.cairo_set_source_rgb(cr, 0, 0, 0);
    var x = @round((@as(f64, @floatFromInt(width)) - total * unit) / 2) + quiet * unit;
    // Elements alternate bar, space, …; the gap after each character is a space, so even indices are bars.
    for (b.widths, 0..) |e, i| {
        if (i % 2 == 0) c.cairo_rectangle(cr, x, 0, e * unit, @floatFromInt(height));
        x += e * unit;
    }
    c.cairo_fill(cr);
}
