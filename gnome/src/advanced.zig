//! Advanced search: field-qualified terms joined by AND, OR, or NOT (`title:(dune) AND
//! contributor:(herbert)`), limited by format, audience, language, and years published.

const std = @import("std");
const gtk = @import("gtk.zig");
const c = gtk.c;
const core = @import("core.zig");
const capi = core.capi;
const ItemList = @import("list.zig").ItemList;
const list = @import("list.zig");

/// A search term's field, as the "bl" query language names it, with its label.
const fields = [_]struct { id: []const u8, title: [*:0]const u8 }{
    .{ .id = "anywhere", .title = "Keyword" },
    .{ .id = "title", .title = "Title" },
    .{ .id = "contributor", .title = "Author" },
    .{ .id = "subject", .title = "Subject" },
    .{ .id = "series", .title = "Series" },
    .{ .id = "genre", .title = "Genre" },
    .{ .id = "publisher", .title = "Publisher" },
    .{ .id = "isbn", .title = "ISBN" },
    .{ .id = "callnumber", .title = "Call Number" },
};

const operators = [_][:0]const u8{ "AND", "OR", "NOT" };

const audiences = [_]struct { id: []const u8, title: [*:0]const u8 }{
    .{ .id = "adult", .title = "Adult" },
    .{ .id = "teen", .title = "Teen" },
    .{ .id = "juvenile", .title = "Children" },
};

const languages = [_][]const u8{ "eng", "spa", "chi", "fre", "ger", "jpn", "kor", "rus", "vie", "ara", "hin", "por", "tgl", "ita" };

const Term = struct {
    row: *c.GtkWidget,
    op: ?*c.GtkDropDown,
    field: *c.GtkDropDown,
    entry: *c.GtkEntry,
};

pub const Advanced = struct {
    list: *ItemList,
    dialog: *c.AdwDialog,
    terms_box: *c.GtkWidget,
    terms: std.ArrayList(Term) = .empty,
    format_row: *c.AdwComboRow,
    audience_row: *c.AdwComboRow,
    language_row: *c.AdwComboRow,
    from_year: *c.AdwEntryRow,
    to_year: *c.AdwEntryRow,
    preview: *c.GtkLabel,
    search_button: *c.GtkWidget,
    arena: std.heap.ArenaAllocator,
    /// Format codes in the Format menu after "Any".
    format_codes: []const []const u8 = &.{},

    pub fn present(l: *ItemList) void {
        const d = core.gpa.create(Advanced) catch return;
        const dialog: *c.AdwDialog = @ptrCast(@alignCast(c.adw_dialog_new()));
        c.adw_dialog_set_title(dialog, "Advanced Search");
        c.adw_dialog_set_content_width(dialog, 480);
        c.adw_dialog_set_content_height(dialog, 640);

        const prefs = c.adw_preferences_page_new();
        const terms_group: *c.AdwPreferencesGroup = @ptrCast(@alignCast(c.adw_preferences_group_new()));
        c.adw_preferences_group_set_title(terms_group, "Search For");
        const terms_box = gtk.box(true, 8);
        c.adw_preferences_group_add(terms_group, terms_box);
        const add = c.gtk_button_new();
        const add_content = c.adw_button_content_new();
        c.adw_button_content_set_icon_name(@ptrCast(@alignCast(add_content)), "list-add-symbolic");
        c.adw_button_content_set_label(@ptrCast(@alignCast(add_content)), "_Add Term");
        c.adw_button_content_set_use_underline(@ptrCast(@alignCast(add_content)), 1);
        c.gtk_button_set_child(@ptrCast(@alignCast(add)), add_content);
        c.gtk_widget_add_css_class(add, "flat");
        c.gtk_widget_set_halign(add, c.GTK_ALIGN_START);
        c.adw_preferences_group_add(terms_group, add);
        c.adw_preferences_page_add(@ptrCast(@alignCast(prefs)), terms_group);

        const limit_group: *c.AdwPreferencesGroup = @ptrCast(@alignCast(c.adw_preferences_group_new()));
        c.adw_preferences_group_set_title(limit_group, "Limit To");
        const format_row: *c.AdwComboRow = @ptrCast(@alignCast(c.adw_combo_row_new()));
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(format_row)), "Format");
        const audience_row: *c.AdwComboRow = @ptrCast(@alignCast(c.adw_combo_row_new()));
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(audience_row)), "Audience");
        const language_row: *c.AdwComboRow = @ptrCast(@alignCast(c.adw_combo_row_new()));
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(language_row)), "Language");
        const from_year: *c.AdwEntryRow = @ptrCast(@alignCast(c.adw_entry_row_new()));
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(from_year)), "Published From (Year)");
        c.gtk_text_set_input_purpose(@ptrCast(@alignCast(c.gtk_editable_get_delegate(@ptrCast(@alignCast(from_year))))), c.GTK_INPUT_PURPOSE_DIGITS);
        const to_year: *c.AdwEntryRow = @ptrCast(@alignCast(c.adw_entry_row_new()));
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(to_year)), "Published To (Year)");
        c.gtk_text_set_input_purpose(@ptrCast(@alignCast(c.gtk_editable_get_delegate(@ptrCast(@alignCast(to_year))))), c.GTK_INPUT_PURPOSE_DIGITS);
        for ([_]*c.GtkWidget{ gtk.widget(format_row), gtk.widget(audience_row), gtk.widget(language_row), gtk.widget(from_year), gtk.widget(to_year) }) |row| {
            c.adw_preferences_group_add(limit_group, row);
        }
        c.adw_preferences_page_add(@ptrCast(@alignCast(prefs)), limit_group);

        const query_group: *c.AdwPreferencesGroup = @ptrCast(@alignCast(c.adw_preferences_group_new()));
        c.adw_preferences_group_set_title(query_group, "Query");
        const preview: *c.GtkLabel = @ptrCast(@alignCast(c.gtk_label_new("")));
        c.gtk_label_set_xalign(preview, 0);
        c.gtk_label_set_wrap(preview, 1);
        c.gtk_label_set_selectable(preview, 1);
        c.gtk_widget_add_css_class(gtk.widget(preview), "monospace");
        c.gtk_widget_add_css_class(gtk.widget(preview), "dim-label");
        c.adw_preferences_group_add(query_group, gtk.widget(preview));
        c.adw_preferences_page_add(@ptrCast(@alignCast(prefs)), query_group);

        const toolbar = c.adw_toolbar_view_new();
        const header = c.adw_header_bar_new();
        c.adw_header_bar_set_show_end_title_buttons(@ptrCast(@alignCast(header)), 0);
        c.adw_header_bar_set_show_start_title_buttons(@ptrCast(@alignCast(header)), 0);
        const cancel = c.gtk_button_new_with_mnemonic("_Cancel");
        const search = c.gtk_button_new_with_mnemonic("_Search");
        c.gtk_widget_add_css_class(search, "suggested-action");
        c.adw_header_bar_pack_start(@ptrCast(@alignCast(header)), cancel);
        c.adw_header_bar_pack_end(@ptrCast(@alignCast(header)), search);
        c.adw_toolbar_view_add_top_bar(@ptrCast(@alignCast(toolbar)), header);
        c.adw_toolbar_view_set_content(@ptrCast(@alignCast(toolbar)), prefs);
        c.adw_dialog_set_child(dialog, toolbar);
        c.adw_dialog_set_default_widget(dialog, search);

        d.* = .{
            .list = l,
            .dialog = dialog,
            .terms_box = terms_box,
            .format_row = format_row,
            .audience_row = audience_row,
            .language_row = language_row,
            .from_year = from_year,
            .to_year = to_year,
            .preview = preview,
            .search_button = search,
            .arena = .init(core.gpa),
        };
        d.fillMenus();
        for ([_][]const u8{ "anywhere", "title", "contributor" }) |field| d.addTerm(field);

        gtk.connect(add, "clicked", &onAddTerm, d);
        gtk.connect(cancel, "clicked", &onCancel, d);
        gtk.connect(search, "clicked", &onSearch, d);
        gtk.connect(dialog, "closed", &onClosed, d);
        for ([_]*c.GtkWidget{ gtk.widget(format_row), gtk.widget(audience_row), gtk.widget(language_row) }) |row| {
            gtk.connect(row, "notify::selected", &onNotifySelected, d);
        }
        gtk.connect(from_year, "changed", &onChanged, d);
        gtk.connect(to_year, "changed", &onChanged, d);
        d.update();
        c.adw_dialog_present(dialog, gtk.widget(l.window.window));
    }

    fn a(d: *Advanced) std.mem.Allocator {
        return d.arena.allocator();
    }

    fn model(names: []const ?[*:0]const u8) *c.GtkStringList {
        return c.gtk_string_list_new(@ptrCast(names.ptr)).?;
    }

    fn fillMenus(d: *Advanced) void {
        const w = d.list.window;
        const sa = d.a();
        const Named = struct { code: []const u8, name: []const u8 };
        var formats: std.ArrayList(Named) = .empty;
        var count: usize = 0;
        const codes = capi.biblio_format_codes(&count);
        for (codes[0..count]) |code| {
            const id = std.mem.span(code);
            formats.append(sa, .{ .code = id, .name = core.formatName(sa, id, w.labels) }) catch {};
        }
        std.mem.sort(Named, formats.items, {}, struct {
            fn less(_: void, x: Named, y: Named) bool {
                return std.ascii.lessThanIgnoreCase(x.name, y.name);
            }
        }.less);
        var ids: std.ArrayList([]const u8) = .empty;
        var names: std.ArrayList(?[*:0]const u8) = .empty;
        names.append(sa, "Any") catch {};
        for (formats.items) |f| {
            ids.append(sa, f.code) catch continue;
            names.append(sa, gtk.z(sa, f.name)) catch {};
        }
        names.append(sa, null) catch {};
        d.format_codes = ids.items;
        c.adw_combo_row_set_model(d.format_row, @ptrCast(@alignCast(model(names.items))));

        names = .empty;
        names.append(sa, "Any") catch {};
        for (audiences) |aud| {
            var key_buf: [64]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "AUDIENCE.{s}", .{aud.id}) catch "";
            const label = @import("store.zig").label(w.library, key);
            names.append(sa, if (label) |t| gtk.z(sa, t) else aud.title) catch {};
        }
        names.append(sa, null) catch {};
        c.adw_combo_row_set_model(d.audience_row, @ptrCast(@alignCast(model(names.items))));

        names = .empty;
        names.append(sa, "Any") catch {};
        for (languages) |code| {
            var key_buf: [64]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "LANGUAGE.{s}", .{code}) catch "";
            const name = @import("store.zig").label(w.library, key) orelse code;
            names.append(sa, gtk.z(sa, name)) catch {};
        }
        names.append(sa, null) catch {};
        c.adw_combo_row_set_model(d.language_row, @ptrCast(@alignCast(model(names.items))));
    }

    // MARK: Terms

    fn addTerm(d: *Advanced, field: []const u8) void {
        const first = d.terms.items.len == 0;
        const row = gtk.box(true, 4);
        c.gtk_widget_add_css_class(row, "card");
        gtk.margins(row, 0);
        const inner = gtk.box(true, 6);
        gtk.margins(inner, 8);
        gtk.append(row, inner);

        // The operator and field menus share a line; the terms get a line as wide as the sheet.
        const menus = gtk.box(false, 6);
        var op: ?*c.GtkDropDown = null;
        if (!first) {
            const choices = [_:null]?[*:0]const u8{ "and", "or", "not" };
            const dropdown: *c.GtkDropDown = @ptrCast(@alignCast(c.gtk_drop_down_new_from_strings(&choices)));
            c.gtk_widget_set_tooltip_text(gtk.widget(dropdown), "Operator");
            gtk.connect(dropdown, "notify::selected", &onNotifySelected, d);
            gtk.append(menus, gtk.widget(dropdown));
            op = dropdown;
        }
        var names: [fields.len + 1]?[*:0]const u8 = undefined;
        var selected: c.guint = 0;
        for (fields, 0..) |f, i| {
            names[i] = f.title;
            if (std.mem.eql(u8, f.id, field)) selected = @intCast(i);
        }
        names[fields.len] = null;
        const field_dropdown: *c.GtkDropDown = @ptrCast(@alignCast(c.gtk_drop_down_new_from_strings(@ptrCast(&names))));
        c.gtk_drop_down_set_selected(field_dropdown, selected);
        c.gtk_widget_set_tooltip_text(gtk.widget(field_dropdown), "Search in");
        c.gtk_widget_set_hexpand(gtk.widget(field_dropdown), 1);
        gtk.connect(field_dropdown, "notify::selected", &onNotifySelected, d);
        gtk.append(menus, gtk.widget(field_dropdown));
        const remove = c.gtk_button_new_from_icon_name("list-remove-symbolic");
        c.gtk_widget_add_css_class(remove, "flat");
        c.gtk_widget_set_tooltip_text(remove, "Remove Term");
        gtk.append(menus, remove);
        gtk.append(inner, menus);

        const entry: *c.GtkEntry = @ptrCast(@alignCast(c.gtk_entry_new()));
        c.gtk_entry_set_placeholder_text(entry, "Terms");
        c.gtk_entry_set_input_purpose(entry, c.GTK_INPUT_PURPOSE_FREE_FORM);
        gtk.connect(entry, "changed", &onChanged, d);
        gtk.connect(entry, "activate", &onEntryActivate, d);
        gtk.append(inner, gtk.widget(entry));

        d.terms.append(core.gpa, .{ .row = row, .op = op, .field = field_dropdown, .entry = entry }) catch return;
        c.g_object_set_data(@ptrCast(@alignCast(remove)), "term", row);
        gtk.connect(remove, "clicked", &onRemoveTerm, d);
        gtk.append(d.terms_box, row);
    }

    fn onAddTerm(_: *c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const d: *Advanced = @ptrCast(@alignCast(data.?));
        d.addTerm("anywhere");
        d.update();
    }

    fn onRemoveTerm(button: *c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const d: *Advanced = @ptrCast(@alignCast(data.?));
        const row: *c.GtkWidget = @ptrCast(@alignCast(c.g_object_get_data(@ptrCast(button), "term") orelse return));
        // The first term has no operator; the next one takes its place without one.
        for (d.terms.items, 0..) |term, i| if (term.row == row) {
            _ = d.terms.orderedRemove(i);
            c.gtk_box_remove(gtk.as(c.GtkBox, d.terms_box), row);
            if (i == 0 and d.terms.items.len > 0) {
                if (d.terms.items[0].op) |op| c.gtk_widget_set_visible(gtk.widget(op), 0);
            }
            break;
        };
        d.update();
    }

    // MARK: The query

    fn text(entry: *c.GtkEntry) []const u8 {
        return std.mem.trim(u8, std.mem.span(c.gtk_editable_get_text(@ptrCast(@alignCast(entry)))), " ");
    }

    fn year(row: *c.AdwEntryRow) ?u32 {
        return std.fmt.parseInt(u32, std.mem.trim(u8, std.mem.span(c.gtk_editable_get_text(@ptrCast(@alignCast(row)))), " "), 10) catch null;
    }

    /// `title:(dune) AND contributor:(herbert)`, empty until a term has text.
    fn query(d: *Advanced, qa: std.mem.Allocator) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        var first = true;
        for (d.terms.items) |term| {
            const t = text(term.entry);
            if (t.len == 0) continue;
            const field = fields[@min(c.gtk_drop_down_get_selected(term.field), fields.len - 1)].id;
            const op: []const u8 = if (term.op) |dd| operators[@min(c.gtk_drop_down_get_selected(dd), operators.len - 1)] else "AND";
            if (first) {
                if (std.mem.eql(u8, op, "NOT")) out.appendSlice(qa, "NOT ") catch {};
            } else {
                out.print(qa, " {s} ", .{op}) catch {};
            }
            out.print(qa, "{s}:({s})", .{ field, t }) catch {};
            first = false;
        }
        const from = year(d.from_year);
        const to = year(d.to_year);
        if ((from != null or to != null) and out.items.len > 0) {
            out.appendSlice(qa, " AND pubyear:[") catch {};
            if (from) |f| out.print(qa, "{d}", .{f}) catch {} else out.append(qa, '*') catch {};
            out.appendSlice(qa, " TO ") catch {};
            if (to) |t| out.print(qa, "{d}", .{t}) catch {} else out.append(qa, '*') catch {};
            out.append(qa, ']') catch {};
        }
        return out.items;
    }

    fn update(d: *Advanced) void {
        var scratch = std.heap.ArenaAllocator.init(core.gpa);
        defer scratch.deinit();
        const q = d.query(scratch.allocator());
        c.gtk_label_set_text(d.preview, if (q.len == 0) "Enter at least one term." else gtk.z(scratch.allocator(), q));
        c.gtk_widget_set_sensitive(d.search_button, @intFromBool(q.len > 0));
    }

    fn onNotifySelected(_: *c.GObject, _: ?*c.GParamSpec, data: ?*anyopaque) callconv(.c) void {
        const d: *Advanced = @ptrCast(@alignCast(data.?));
        d.update();
    }

    fn onChanged(_: *c.GtkEditable, data: ?*anyopaque) callconv(.c) void {
        const d: *Advanced = @ptrCast(@alignCast(data.?));
        d.update();
    }

    fn onEntryActivate(_: *c.GtkEntry, data: ?*anyopaque) callconv(.c) void {
        onSearch(null, data);
    }

    fn onSearch(_: ?*c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const d: *Advanced = @ptrCast(@alignCast(data.?));
        var scratch = std.heap.ArenaAllocator.init(core.gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const q = d.query(sa);
        if (q.len == 0) return;
        var filters: std.ArrayList(list.FilterValue) = .empty;
        const audience = c.adw_combo_row_get_selected(d.audience_row);
        if (audience > 0 and audience <= audiences.len) filters.append(sa, .{ .id = "AUDIENCE", .value = audiences[audience - 1].id }) catch {};
        const language = c.adw_combo_row_get_selected(d.language_row);
        if (language > 0 and language <= languages.len) filters.append(sa, .{ .id = "LANGUAGE", .value = languages[language - 1] }) catch {};
        const format_index = c.adw_combo_row_get_selected(d.format_row);
        // Copied: the dialog's arena goes when it closes.
        const format: ?[]const u8 = if (format_index > 0 and format_index <= d.format_codes.len) (sa.dupe(u8, d.format_codes[format_index - 1]) catch null) else null;
        const l = d.list;
        _ = c.adw_dialog_close(d.dialog);
        l.window.show(.search);
        c.adw_navigation_split_view_set_show_content(l.window.split, 1);
        l.advancedSearch(q, format, filters.items);
    }

    fn onCancel(_: *c.GtkButton, data: ?*anyopaque) callconv(.c) void {
        const d: *Advanced = @ptrCast(@alignCast(data.?));
        _ = c.adw_dialog_close(d.dialog);
    }

    fn onClosed(_: *c.AdwDialog, data: ?*anyopaque) callconv(.c) void {
        const d: *Advanced = @ptrCast(@alignCast(data.?));
        d.terms.deinit(core.gpa);
        d.arena.deinit();
        core.gpa.destroy(d);
    }
};
