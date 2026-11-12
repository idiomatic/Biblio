//! Biblio in the terminal: the libraries you've added, then one account's catalog search, new
//! titles, holds, checkouts, borrowing history and account settings, with item details,
//! availability by location, placing and canceling holds (one or many, at a pickup location
//! you choose), sorting and filtering, what you borrowed before, and your card's barcode.
//! Runs in any xterm-256color terminal; needs nothing beyond libbiblio and libc.
//!
//! Lists are libbiblio's item lists (`biblio.item_list`), shared with the other apps: they say
//! which pages to fetch and which rows to show. Core calls block, so each one the screen waits
//! for is preceded by a "Loading…" frame; only the pages a screen shows are fetched. Pages
//! that client sorts and local filters need, and borrowing history for "borrowed before", are
//! fetched on other threads while the app stays responsive.

const std = @import("std");
const biblio = @import("biblio");
const models = biblio.models;
const library = biblio.library;
const item_list = biblio.item_list;
const term = @import("term.zig");
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const Key = term.Key;
const Frame = term.Frame;

const gpa = std.heap.c_allocator;

const color = struct {
    const dim: term.Color = 245;
    /// Quieter than `dim`: a work borrowed in another format.
    const faint: term.Color = 241;
    const selected: term.Color = 237;
    const panel: term.Color = 235;
    const failure: term.Color = 203;
    const success: term.Color = 114;
    const brand: term.Color = 24;
    const white: term.Color = 231;
    const black: term.Color = 16;

    /// Matches the other apps' copy-status colors; the words always appear too.
    fn kind(k: []const u8) term.Color {
        const map = std.StaticStringMap(term.Color).initComptime(.{
            .{ "available", 114 },
            .{ "onOrder", 75 },
            .{ "out", 214 },
            .{ "held", 141 },
            .{ "transit", 141 },
            .{ "repair", 203 },
            .{ "missing", 203 },
            .{ "withdrawn", 245 },
            .{ "claimsReturned", 203 },
            .{ "libraryUseOnly", 180 },
        });
        return map.get(k) orelse dim;
    }
};

/// A panic leaves the terminal usable before printing its message.
pub const panic = std.debug.FullPanic(panicRestoring);

fn panicRestoring(msg: []const u8, first_trace_addr: ?usize) noreturn {
    term.restore();
    std.debug.defaultPanic(msg, first_trace_addr);
}

pub fn main(init: std.process.Init) !void {
    var t = try term.Terminal.init(init.io);
    defer t.deinit();
    var app: App = .{ .term = &t, .store = Store.load(init.io, gpa, init.environ_map), .system_language = systemLanguage(init.environ_map) };
    app.run();
}

/// "en-US" from LANG=en_US.UTF-8. The library language is the account's own preference: this
/// is only offered, as "Use System Language", never applied by itself.
fn systemLanguage(env: *const std.process.Environ.Map) ?[]const u8 {
    const lang = env.get("LC_ALL") orelse env.get("LC_MESSAGES") orelse env.get("LANG") orelse return null;
    const code = lang[0 .. std.mem.indexOfAny(u8, lang, ".@") orelse lang.len];
    if (code.len < 2 or std.mem.eql(u8, code, "C") or std.mem.eql(u8, code, "POSIX")) return null;
    const out = gpa.dupe(u8, code) catch return null;
    std.mem.replaceScalar(u8, out, '_', '-');
    return out;
}

/// The library's language closest to `system`: the same code, else the same language.
fn closestLanguage(system: []const u8, languages: []const []const u8) ?[]const u8 {
    for (languages) |l| if (std.ascii.eqlIgnoreCase(l, system)) return l;
    const base = system[0 .. std.mem.indexOfScalar(u8, system, '-') orelse system.len];
    for (languages) |l| {
        const lb = l[0 .. std.mem.indexOfScalar(u8, l, '-') orelse l.len];
        if (std.ascii.eqlIgnoreCase(lb, base)) return l;
    }
    return null;
}

/// Milliseconds on a monotonic clock, for list ages.
fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divFloor(@as(i64, ts.nsec), 1_000_000);
}

// MARK: App

/// A one-line text field in the status row, with a cursor.
const Prompt = struct {
    label: []const u8,
    input: std.ArrayList(u8) = .empty,
    /// The cursor, as a byte offset into `input`.
    cursor: usize = 0,
    secret: bool = false,
    action: enum { add_library, add_user_name, add_user_password, sign_in_password, search, email, new_password, confirm_password },

    fn deinit(p: *Prompt) void {
        if (p.secret) std.crypto.secureZero(u8, p.input.items);
        p.input.deinit(gpa);
    }

    /// Starts with `text`, the cursor at its end.
    fn set(p: *Prompt, text: []const u8) void {
        p.input.appendSlice(gpa, text) catch {};
        p.cursor = p.input.items.len;
    }

    fn before(p: *const Prompt, i: usize) usize {
        var j = i;
        while (j > 0) {
            j -= 1;
            if (p.input.items[j] & 0xc0 != 0x80) break;
        }
        return j;
    }

    fn after(p: *const Prompt, i: usize) usize {
        if (i >= p.input.items.len) return i;
        return @min(p.input.items.len, i + term.decode(p.input.items, i).len);
    }

    /// Applies an editing key: typing, ←→, Home and End (or ^A and ^E), Backspace, Delete,
    /// and ^U and ^K (clear before or after the cursor).
    fn edit(p: *Prompt, key: Key) void {
        const items = p.input.items;
        switch (key) {
            .left => p.cursor = p.before(p.cursor),
            .right => p.cursor = p.after(p.cursor),
            .home => p.cursor = 0,
            .end => p.cursor = items.len,
            .backspace => if (p.cursor > 0) {
                const from = p.before(p.cursor);
                p.input.replaceRangeAssumeCapacity(from, p.cursor - from, &.{});
                p.cursor = from;
            },
            .delete => if (p.cursor < items.len) {
                p.input.replaceRangeAssumeCapacity(p.cursor, p.after(p.cursor) - p.cursor, &.{});
            },
            .char => |c| switch (c) {
                1 => p.cursor = 0,
                5 => p.cursor = items.len,
                21 => {
                    if (p.secret) std.crypto.secureZero(u8, items[0..p.cursor]);
                    p.input.replaceRangeAssumeCapacity(0, p.cursor, &.{});
                    p.cursor = 0;
                },
                11 => {
                    if (p.secret) std.crypto.secureZero(u8, items[p.cursor..]);
                    p.input.shrinkRetainingCapacity(p.cursor);
                },
                else => if (c >= 0x20 and !(c >= 0x7f and c < 0xa0)) {
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(c, &buf) catch return;
                    p.input.insertSlice(gpa, p.cursor, buf[0..n]) catch return;
                    p.cursor += n;
                },
            },
            else => {},
        }
    }
};

const Confirm = struct {
    action: enum { cancel_holds, remove_user, remove_library, history_off },
};

/// A menu over the screen: pickup locations, languages, sorts, or filters.
const Picker = struct {
    arena: std.heap.ArenaAllocator,
    title: []const u8 = "",
    options: std.ArrayList(Option) = .empty,
    cursor: usize = 0,
    top: usize = 0,
    action: enum { hold_pickup, default_pickup, language, sort, filter },
    /// For `hold_pickup`: what to place holds on.
    targets: []const Target = &.{},

    const Option = struct {
        label: []const u8,
        id: []const u8 = "",
        /// A section heading, which can't be chosen.
        heading: bool = false,
        checked: bool = false,
        /// For `filter`: whether it sets the hold status (else the format).
        status: bool = false,
    };

    fn init(action: @FieldType(Picker, "action")) Picker {
        return .{ .arena = .init(gpa), .action = action };
    }

    fn deinit(p: *Picker) void {
        p.arena.deinit();
    }

    fn a(p: *Picker) std.mem.Allocator {
        return p.arena.allocator();
    }

    fn add(p: *Picker, option: Option) void {
        var o = option;
        o.label = p.a().dupe(u8, o.label) catch return;
        o.id = p.a().dupe(u8, o.id) catch return;
        p.options.append(p.a(), o) catch {};
    }

    /// Puts the cursor on the checked option, else the first that can be chosen.
    fn settle(p: *Picker) void {
        for (p.options.items, 0..) |o, i| if (o.checked and !o.heading) {
            p.cursor = i;
            return;
        };
        p.cursor = 0;
        while (p.cursor < p.options.items.len and p.options.items[p.cursor].heading) p.cursor += 1;
    }

    fn move(p: *Picker, delta: isize) void {
        const n = p.options.items.len;
        if (n == 0) return;
        var i: isize = @intCast(p.cursor);
        var steps = @abs(delta);
        const dir: isize = if (delta < 0) -1 else 1;
        while (steps > 0) : (steps -= 1) {
            var j = i + dir;
            while (j >= 0 and j < n and p.options.items[@intCast(j)].heading) j += dir;
            if (j < 0 or j >= n) break;
            i = j;
        }
        p.cursor = @intCast(i);
    }
};

/// An item to place a hold on, or whose hold to cancel.
const Target = struct {
    id: []const u8,
    material_type: []const u8,
    title: []const u8,
    hold: ?models.Hold = null,
};

/// A row on the libraries screen: one of a library's users, or its guest row.
const Row = struct { library: usize, user: ?[]const u8 };

const App = struct {
    term: *term.Terminal,
    store: Store,
    system_language: ?[]const u8,
    cursor: usize = 0,
    session: ?*Session = null,
    prompt: ?Prompt = null,
    confirm: ?Confirm = null,
    picker: ?Picker = null,
    question_buf: [512]u8 = undefined,
    question: []const u8 = "",
    message_buf: [1024]u8 = undefined,
    message: []const u8 = "",
    message_is_error: bool = false,
    /// The library and username an Add User or sign-in prompt is for.
    pending_library: usize = 0,
    pending_user: []u8 = &.{},
    quit: bool = false,

    fn run(app: *App) void {
        var last = app.term.size();
        app.draw();
        while (!app.quit) {
            const key = app.term.readKey(250) orelse {
                const now = app.term.size();
                const synced = if (app.session) |s| s.poll() else false;
                if (synced or now.rows != last.rows or now.cols != last.cols) {
                    last = now;
                    if (app.session) |s| s.fetchVisible();
                    app.draw();
                }
                continue;
            };
            app.handle(key);
            if (app.session) |s| {
                _ = s.poll();
                s.fetchVisible();
            }
            if (!app.quit) app.draw();
        }
        if (app.session) |s| s.close();
        gpa.free(app.pending_user);
    }

    /// Formats into `buf`, cut short (at a character) if it doesn't fit.
    fn format(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        w.print(fmt, args) catch {};
        var out = w.buffered();
        if (out.len == buf.len) {
            var end = out.len;
            while (end > 0 and out[end - 1] & 0xc0 == 0x80) end -= 1;
            if (end > 0 and out[end - 1] >= 0xc0) end -= 1;
            out = out[0..end];
        }
        return out;
    }

    fn say(app: *App, comptime fmt: []const u8, args: anytype) void {
        app.message = format(&app.message_buf, fmt, args);
        app.message_is_error = false;
    }

    fn fail(app: *App, comptime fmt: []const u8, args: anytype) void {
        app.say(fmt, args);
        app.message_is_error = true;
    }

    fn ask(app: *App, action: @FieldType(Confirm, "action"), comptime fmt: []const u8, args: anytype) void {
        app.question = format(&app.question_buf, fmt, args);
        app.confirm = .{ .action = action };
    }

    /// Shows `text` before a blocking call.
    fn busy(app: *App, text: []const u8) void {
        app.say("{s}", .{text});
        app.draw();
    }

    fn handle(app: *App, key: Key) void {
        app.message = "";
        if (key == .ctrl_c) {
            app.quit = true;
        } else if (app.prompt != null) {
            app.handlePrompt(key);
        } else if (app.picker != null) {
            app.handlePicker(key);
        } else if (app.confirm) |c| {
            app.confirm = null;
            if (key == .char and (key.char == 'y' or key.char == 'Y')) app.confirmed(c);
        } else if (app.session) |s| {
            s.handle(key);
        } else {
            app.handleLibraries(key);
        }
    }

    // Prompts

    fn startPrompt(app: *App, prompt: Prompt) void {
        app.prompt = prompt;
    }

    fn handlePrompt(app: *App, key: Key) void {
        const p = &app.prompt.?;
        switch (key) {
            .escape => {
                p.deinit();
                app.prompt = null;
                if (app.session) |s| s.forgetNewPassword();
            },
            .enter => {
                var done = app.prompt.?;
                app.prompt = null;
                defer done.deinit();
                app.submitted(done.action, std.mem.trim(u8, done.input.items, " "));
            },
            else => p.edit(key),
        }
    }

    fn setPendingUser(app: *App, user: []const u8) bool {
        const copy = gpa.dupe(u8, user) catch return false;
        gpa.free(app.pending_user);
        app.pending_user = copy;
        return true;
    }

    fn submitted(app: *App, action: @FieldType(Prompt, "action"), input: []const u8) void {
        switch (action) {
            .add_library => app.addLibrary(input),
            .add_user_name => {
                if (input.len == 0 or !app.setPendingUser(input)) return;
                app.startPrompt(.{ .label = "PIN or password", .secret = true, .action = .add_user_password });
            },
            .add_user_password => if (input.len > 0) {
                if (app.open(app.pending_library, app.pending_user, input, true)) app.store.addUser(app.pending_library, app.pending_user);
            },
            .sign_in_password => if (input.len > 0) {
                _ = app.open(app.pending_library, app.pending_user, input, false);
            },
            .search => if (app.session) |s| s.search(input),
            .email => if (app.session) |s| s.changeEmail(input),
            .new_password => if (app.session) |s| s.newPassword(input),
            .confirm_password => if (app.session) |s| s.confirmPassword(input),
        }
    }

    // Pickers

    fn handlePicker(app: *App, key: Key) void {
        const p = &app.picker.?;
        const page: isize = @intCast(@max(1, app.term.size().rows / 2));
        switch (key) {
            .escape, .backspace => app.closePicker(),
            .up => p.move(-1),
            .down => p.move(1),
            .page_up => p.move(-page),
            .page_down => p.move(page),
            .home => p.move(-@as(isize, @intCast(p.options.items.len))),
            .end => p.move(@intCast(p.options.items.len)),
            .char => |c| if (c == 'q') app.closePicker(),
            .enter => {
                if (p.options.items.len == 0) return app.closePicker();
                var done = app.picker.?;
                app.picker = null;
                defer done.deinit();
                const option = done.options.items[done.cursor];
                if (app.session) |s| s.picked(&done, option);
            },
            else => {},
        }
    }

    fn closePicker(app: *App) void {
        if (app.picker) |*p| p.deinit();
        app.picker = null;
    }

    fn confirmed(app: *App, c: Confirm) void {
        switch (c.action) {
            .cancel_holds => if (app.session) |s| s.cancelHolds(),
            .history_off => if (app.session) |s| s.setBorrowingHistory(false),
            .remove_user => if (app.rowAt(app.cursor)) |row| {
                app.store.removeUser(row.library, row.user.?);
                app.cursor -|= 1;
            },
            .remove_library => if (app.rowAt(app.cursor)) |row| {
                app.store.remove(row.library);
                app.cursor = 0;
            },
        }
    }

    // Libraries screen

    fn rowCount(app: *const App) usize {
        var n: usize = 0;
        for (app.store.libraries.items) |lib| n += lib.users.len + 1;
        return n;
    }

    fn rowAt(app: *const App, index: usize) ?Row {
        var i: usize = 0;
        for (app.store.libraries.items, 0..) |lib, l| {
            for (lib.users) |u| {
                if (i == index) return .{ .library = l, .user = u };
                i += 1;
            }
            if (i == index) return .{ .library = l, .user = null };
            i += 1;
        }
        return null;
    }

    fn handleLibraries(app: *App, key: Key) void {
        const count = app.rowCount();
        switch (key) {
            .up => app.cursor -|= 1,
            .down => app.cursor = @min(app.cursor + 1, count -| 1),
            .home => app.cursor = 0,
            .end => app.cursor = count -| 1,
            .escape => app.quit = true,
            .enter => if (app.rowAt(app.cursor)) |row| {
                if (row.user) |u| {
                    app.pending_library = row.library;
                    if (!app.setPendingUser(u)) return;
                    app.startPrompt(.{ .label = "Password for ", .secret = true, .action = .sign_in_password });
                } else {
                    _ = app.open(row.library, "", null, false);
                }
            },
            .char => |c| switch (c) {
                'q' => app.quit = true,
                'a' => app.startPrompt(.{ .label = "Library (such as wccls or its catalog address)", .action = .add_library }),
                'u' => if (app.rowAt(app.cursor)) |row| {
                    app.pending_library = row.library;
                    app.startPrompt(.{ .label = "Username or card number", .action = .add_user_name });
                },
                'd' => if (app.rowAt(app.cursor)) |row| {
                    const name = displayName(app.store.libraries.items[row.library]);
                    if (row.user) |u|
                        app.ask(.remove_user, "Remove {s} from {s}?", .{ u, name })
                    else
                        app.ask(.remove_library, "Remove {s} and its users?", .{name});
                },
                else => {},
            },
            else => {},
        }
    }

    fn addLibrary(app: *App, input: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const subdomain = library.subdomainFrom(a, input) orelse
            return app.fail("Enter the name before “.bibliocommons.com”, such as wccls.", .{});
        app.busy("Looking up the library…");
        var message: []const u8 = "The library could not be reached.";
        const info = biblio.lookup().info(a, subdomain, &message) catch return app.fail("{s}", .{message});
        app.store.upsert(info);
        app.say("Added {s}. Press u to add a user, or Enter to browse as a guest.", .{displayName(info)});
        var i: usize = 0;
        while (app.rowAt(i)) |row| : (i += 1) {
            if (std.mem.eql(u8, app.store.libraries.items[row.library].subdomain, subdomain) and row.user == null) app.cursor = i;
        }
    }

    /// Opens an account (or a guest, with an empty username), signing in first. False if
    /// signing in failed.
    fn open(app: *App, lib: usize, username: []const u8, password: ?[]const u8, force: bool) bool {
        const s = Session.create(app, lib, username, password) catch {
            app.fail("Not enough memory to open {s}.", .{displayName(app.store.libraries.items[lib])});
            return false;
        };
        if (!s.start(force)) {
            s.close();
            return false;
        }
        app.session = s;
        return true;
    }

    // Drawing

    fn draw(app: *App) void {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var f = Frame.begin(arena.allocator(), app.term.size());
        if (app.session) |s| s.draw(&f) else app.drawLibraries(&f);
        if (app.picker) |*p| drawPicker(&f, p);
        app.drawStatus(&f);
        app.term.write(f.out.items);
    }

    fn drawLibraries(app: *App, f: *Frame) void {
        f.at(0, 0);
        f.style(.{ .fg = color.white, .bg = color.brand, .bold = true });
        f.fill(f.text(" Biblio", f.size.cols, false));
        f.style(.{});
        if (app.store.libraries.items.len == 0) {
            f.at(2, 2);
            _ = f.text("No libraries yet. Press a to add one, such as wccls.", f.size.cols -| 4, false);
            return;
        }
        // Lines: a heading per library, then its rows.
        const Line = struct { row: ?usize, lib: usize };
        var lines: std.ArrayList(Line) = .empty;
        var r: usize = 0;
        for (app.store.libraries.items, 0..) |lib, l| {
            lines.append(f.a, .{ .row = null, .lib = l }) catch {};
            for (0..lib.users.len + 1) |_| {
                lines.append(f.a, .{ .row = r, .lib = l }) catch {};
                r += 1;
            }
        }
        const height = f.size.rows -| 3;
        var selected_line: usize = 0;
        for (lines.items, 0..) |line, i| if (line.row == app.cursor) {
            selected_line = i;
        };
        const top = if (selected_line + 1 > height) selected_line + 1 - height else 0;
        for (lines.items[top..@min(lines.items.len, top + height)], 0..) |line, i| {
            f.at(2 + i, 0);
            const lib = app.store.libraries.items[line.lib];
            if (line.row) |row_index| {
                const row = app.rowAt(row_index).?;
                const selected = row_index == app.cursor;
                f.style(.{ .bg = if (selected) color.selected else null, .bold = selected });
                const label = row.user orelse "Browse as Guest";
                var used = f.text(if (selected) "  ▸ " else "    ", 4, false);
                used += f.text(label, f.size.cols -| used, false);
                f.fill(used);
            } else {
                f.style(.{ .bold = true });
                const used = f.text(lib.name, f.size.cols -| 2, false);
                f.style(.{ .fg = color.dim });
                _ = f.text(std.fmt.allocPrint(f.a, "  {s}.bibliocommons.com", .{lib.subdomain}) catch "", f.size.cols -| used, false);
            }
            f.style(.{});
        }
    }

    fn drawStatus(app: *App, f: *Frame) void {
        f.at(f.size.rows -| 1, 0);
        const width = f.size.cols;
        if (app.prompt) |p| {
            f.style(.{ .bold = true });
            var used = f.text(p.label, width, false);
            if (p.action == .sign_in_password) used += f.text(app.pending_user, width -| used, false);
            used += f.text(": ", width -| used, false);
            f.style(.{});
            drawInput(f, p, width -| used);
        } else if (app.confirm != null) {
            f.style(.{ .bold = true });
            const used = f.text(app.question, width -| 6, false);
            _ = f.text(" (y/n)", width -| used, false);
        } else if (app.message.len > 0) {
            f.style(.{ .fg = if (app.message_is_error) color.failure else null });
            _ = f.text(app.message, width, false);
        } else {
            f.style(.{ .fg = color.dim });
            const hints = if (app.picker != null)
                "↑↓ move  Enter choose  Esc cancel"
            else if (app.session) |s|
                s.hints()
            else
                "↑↓ move  Enter open  a add library  u add user  d remove  q quit";
            _ = f.text(hints, width, false);
        }
        f.style(.{});
    }
};

/// A prompt's text in `room` columns, scrolled to keep the cursor (a reversed cell) in view.
fn drawInput(f: *Frame, p: Prompt, room: usize) void {
    if (room == 0) return;
    // Secrets show a dot per character.
    const text = if (p.secret) blk: {
        var dots: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < p.input.items.len) : (i += term.decode(p.input.items, i).len) dots.appendSlice(f.a, "•") catch {};
        break :blk dots.items;
    } else p.input.items;
    const cursor = if (p.secret) blk: {
        var n: usize = 0;
        var i: usize = 0;
        while (i < p.cursor) : (i += term.decode(p.input.items, i).len) n += "•".len;
        break :blk n;
    } else p.cursor;
    // Skip characters from the start until the cursor's cell fits.
    var start: usize = 0;
    while (start < cursor and term.columns(text[start..cursor]) + 1 > room) start += term.decode(text, start).len;
    var used = f.text(text[start..cursor], room, false);
    const at_end = cursor >= text.len;
    const under = if (at_end) " " else text[cursor .. cursor + term.decode(text, cursor).len];
    f.style(.{ .reverse = true });
    used += f.text(under, room -| used, false);
    f.style(.{});
    if (!at_end) _ = f.text(text[cursor + under.len ..], room -| used, false);
}

/// A picker as a box over the middle of the screen.
fn drawPicker(f: *Frame, p: *Picker) void {
    var width: usize = term.columns(p.title) + 6;
    for (p.options.items) |o| width = @max(width, term.columns(o.label) + 8);
    width = @min(@max(width, 24), f.size.cols);
    const room = f.size.rows -| 4;
    const shown = @min(p.options.items.len, room);
    if (shown == 0 or width < 6) return;
    if (p.cursor < p.top) p.top = p.cursor;
    if (p.cursor >= p.top + shown) p.top = p.cursor + 1 - shown;
    const top = (f.size.rows -| (shown + 2)) / 2;
    const left = (f.size.cols - width) / 2;
    const inner = width - 2;
    f.at(top, left);
    f.style(.{ .bg = color.panel, .bold = true });
    var used = f.text("┌ ", 2, false);
    used += f.text(p.title, inner -| 2, false);
    used += f.text(" ", width -| used -| 1, false);
    while (used < width - 1) : (used += 1) f.raw("─");
    f.raw("┐");
    for (p.options.items[p.top .. p.top + shown], p.top..) |o, i| {
        f.at(top + 1 + (i - p.top), left);
        f.style(.{ .bg = color.panel });
        f.raw("│");
        const selected = i == p.cursor;
        f.style(if (o.heading) .{ .bg = color.panel, .fg = color.dim, .bold = true } else if (selected) .{ .bg = color.selected, .bold = true } else .{ .bg = color.panel });
        var w: usize = 0;
        if (o.heading) {
            w += f.text(" ", inner, false);
        } else {
            w += f.text(if (selected) "▸" else " ", inner, false);
            w += f.text(if (o.checked) "✓ " else "  ", inner -| w, false);
        }
        _ = f.text(o.label, inner -| w, true);
        f.style(.{ .bg = color.panel });
        f.raw("│");
    }
    f.at(top + 1 + shown, left);
    f.style(.{ .bg = color.panel });
    f.raw("└");
    for (0..inner) |_| f.raw("─");
    f.raw("┘");
    f.style(.{});
}

fn displayName(lib: models.LibraryInfo) []const u8 {
    return lib.shortName orelse lib.name;
}

// MARK: Session

const Tab = enum {
    search,
    new_titles,
    holds,
    checkouts,
    history,
    account,

    fn title(t: Tab) []const u8 {
        return switch (t) {
            .search => "Search",
            .new_titles => "New Titles",
            .holds => "Holds",
            .checkouts => "Checked Out",
            .history => "History",
            .account => "Account",
        };
    }

    fn isCatalog(t: Tab) bool {
        return t == .search or t == .new_titles;
    }

    fn isAccount(t: Tab) bool {
        return t == .holds or t == .checkouts or t == .history;
    }
};

/// What to fetch for a list's pages.
const Request = struct {
    tab: Tab,
    query: []const u8 = "",
    sort: ?[]const u8 = null,
    format: ?[]const u8 = null,

    fn dupe(r: Request, a: std.mem.Allocator) !Request {
        return .{
            .tab = r.tab,
            .query = try a.dupe(u8, r.query),
            .sort = if (r.sort) |x| try a.dupe(u8, x) else null,
            .format = if (r.format) |x| try a.dupe(u8, x) else null,
        };
    }

    fn fetch(r: Request, c: *biblio.Client, a: std.mem.Allocator, page: i64, failure: *biblio.Failure) anyerror!models.ListPage {
        return switch (r.tab) {
            .search => c.search(a, .{ .query = r.query, .page = page, .sort = r.sort, .format = r.format }, failure),
            .new_titles => blk: {
                var filters: std.json.ArrayHashMap([]const u8) = .{};
                filters.map.put(a, "f_on_order", "false") catch {};
                break :blk c.search(a, .{
                    .query = "nw:[0 TO 180]",
                    .searchType = "bl",
                    .filters = filters,
                    .page = page,
                    .sort = r.sort orelse "newly_acquired",
                    .format = r.format,
                }, failure);
            },
            .holds => c.borrowing(a, .holds, page, r.sort, failure),
            .checkouts => c.borrowing(a, .checkouts, page, r.sort, failure),
            .history => c.borrowing(a, .history, page, r.sort, failure),
            .account => unreachable,
        };
    }
};

/// A page fetched on its own thread; the main thread polls `done`, then takes the page's
/// arena (keeping its entries) or discards it.
const PageFetch = struct {
    client: *biblio.Client,
    request: Request,
    page: i64,
    /// The list's generation when asked; a page for an older one is discarded.
    generation: u64,
    arena: std.heap.ArenaAllocator,
    thread: std.Thread = undefined,
    result: ?models.ListPage = null,
    message: []const u8 = "",
    done: std.atomic.Value(bool) = .init(false),

    fn start(c: *biblio.Client, request: Request, page: i64, generation: u64) ?*PageFetch {
        const job = gpa.create(PageFetch) catch return null;
        job.* = .{ .client = c, .request = undefined, .page = page, .generation = generation, .arena = .init(gpa) };
        job.request = request.dupe(job.arena.allocator()) catch {
            job.arena.deinit();
            gpa.destroy(job);
            return null;
        };
        job.thread = std.Thread.spawn(.{}, run, .{job}) catch {
            job.arena.deinit();
            gpa.destroy(job);
            return null;
        };
        return job;
    }

    fn run(job: *PageFetch) void {
        var failure: biblio.Failure = undefined;
        const a = job.arena.allocator();
        job.result = job.request.fetch(job.client, a, job.page, &failure) catch blk: {
            job.message = a.dupe(u8, failure.message) catch "";
            break :blk null;
        };
        job.done.store(true, .release);
    }

    /// Waits for the fetch to end, then frees it.
    fn discard(job: *PageFetch) void {
        job.thread.join();
        job.arena.deinit();
        gpa.destroy(job);
    }

    /// Frees the job but keeps its arena, which holds the page; the fetch must be done.
    fn take(job: *PageFetch) std.heap.ArenaAllocator {
        job.thread.join();
        const arena = job.arena;
        gpa.destroy(job);
        return arena;
    }
};

/// One section's list: the core item list, and the fetched entries it shows.
const List = struct {
    tab: Tab,
    core: item_list.List,
    /// The fetched pages' entries, each page in its own arena, kept until the list reloads.
    pages: std.ArrayList(std.heap.ArenaAllocator) = .empty,
    by_id: std.StringHashMapUnmanaged(models.ListEntry) = .empty,
    /// From the first page.
    sort_options: []const []const u8 = &.{},
    applied_sort: ?[]const u8 = null,
    /// Searches' format choices, from the first page's FORMAT facet.
    facet_formats: []const models.FacetValue = &.{},
    query: []u8 = &.{},
    /// The server sort chosen; null for the default. Client sorts are the core list's.
    sort: ?[]u8 = null,
    format: ?[]u8 = null,
    hold_filter: item_list.HoldFilter = .none,
    /// "Not Borrowed": hides works borrowed before in the same format.
    not_borrowed: bool = false,
    /// The borrowed index generation "Not Borrowed" last filtered with.
    filtered_generation: u64 = 0,
    /// Marked items (by id), to place or cancel holds on together.
    marked: std.StringArrayHashMapUnmanaged(void) = .empty,
    cursor: usize = 0,
    top: usize = 0,
    /// A page failed to load: its placeholders wait for r rather than retrying on every key.
    failed: bool = false,
    /// The page being fetched in the background, for client sorts, local filters and holds.
    job: ?*PageFetch = null,
    background: bool = false,

    fn init(tab: Tab) List {
        const kind: item_list.Kind = switch (tab) {
            .holds => .holds,
            .checkouts => .checkouts,
            .history => .history,
            else => .search,
        };
        return .{ .tab = tab, .core = .init(gpa, kind) };
    }

    fn deinit(l: *List) void {
        if (l.job) |job| job.discard();
        l.job = null;
        l.releasePages();
        l.pages.deinit(gpa);
        l.by_id.deinit(gpa);
        l.clearMarks();
        l.marked.deinit(gpa);
        l.core.deinit();
        gpa.free(l.query);
        if (l.sort) |x| gpa.free(x);
        if (l.format) |x| gpa.free(x);
    }

    fn releasePages(l: *List) void {
        l.by_id.clearRetainingCapacity();
        for (l.pages.items) |*arena| arena.deinit();
        l.pages.clearRetainingCapacity();
        l.sort_options = &.{};
        l.applied_sort = null;
    }

    fn clearMarks(l: *List) void {
        for (l.marked.keys()) |k| gpa.free(k);
        l.marked.clearRetainingCapacity();
    }

    fn request(l: *const List) Request {
        return .{ .tab = l.tab, .query = l.query, .sort = l.sort, .format = l.format };
    }

    fn rows(l: *const List) []const item_list.Row {
        return l.core.rows.items;
    }

    fn entryAt(l: *const List, i: usize) ?models.ListEntry {
        if (i >= l.rows().len) return null;
        const id = l.rows()[i].id orelse return null;
        return l.by_id.get(std.mem.span(id));
    }

    fn pageOf(l: *const List, position: i64) i64 {
        return @divFloor(position, l.core.page_size) + 1;
    }

    /// Keeps the cursor in the list and on screen.
    fn scroll(l: *List, visible: usize) void {
        l.cursor = @min(l.cursor, l.rows().len -| 1);
        if (l.cursor < l.top) l.top = l.cursor;
        if (l.cursor >= l.top + visible) l.top = l.cursor + 1 - visible;
    }

    /// The selected item's id, to find it again after the rows change.
    fn selectedId(l: *const List) ?[]u8 {
        if (l.cursor >= l.rows().len) return null;
        const id = l.rows()[l.cursor].id orelse return null;
        return gpa.dupe(u8, std.mem.span(id)) catch null;
    }

    fn reselect(l: *List, id: ?[]u8) void {
        const want = id orelse return;
        defer gpa.free(want);
        for (l.rows(), 0..) |r, i| if (r.id) |x| if (std.mem.eql(u8, std.mem.span(x), want)) {
            l.cursor = i;
            return;
        };
    }

    /// Takes a fetched page; frees `arena` if the list was reloaded since it was asked for.
    fn keep(l: *List, arena: std.heap.ArenaAllocator, page: i64, generation: u64, result: models.ListPage) void {
        var owned = arena;
        const items = gpa.alloc(item_list.Item, result.entries.len) catch return owned.deinit();
        defer gpa.free(items);
        for (items, result.entries) |*it, e| it.* = .from(e);
        l.pages.append(gpa, owned) catch return owned.deinit();
        const selected = l.selectedId();
        const applied = l.core.apply(generation, page, items, result.count, result.pageSize, nowMs()) catch false;
        if (!applied) {
            if (selected) |x| gpa.free(x);
            var dropped = l.pages.pop().?;
            return dropped.deinit();
        }
        // An item that moved between pages while fetching keeps its first position.
        for (result.entries) |e| {
            const gop = l.by_id.getOrPut(gpa, e.id) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = e;
        }
        if (page == 1) {
            l.sort_options = result.sortOptions;
            l.applied_sort = result.appliedSort;
            l.facet_formats = &.{};
            for (result.facets) |facet| if (std.mem.eql(u8, facet.id, "FORMAT")) {
                l.facet_formats = facet.values;
            };
        }
        l.reselect(selected);
    }
};

const Detail = struct {
    arena: std.heap.ArenaAllocator,
    entry: models.ListEntry,
    from: Tab,
    copies: []const models.CopyAvailability = &.{},
    copies_error: ?[]const u8 = null,
    fields: []const models.DetailField = &.{},
    scroll: usize = 0,
};

/// The Account tab's rows; the ones after `card` can be changed.
const Setting = enum {
    name,
    library,
    card,
    email,
    password,
    pickup,
    language,
    history,

    fn label(s: Setting) []const u8 {
        return switch (s) {
            .name => "Name",
            .library => "Library",
            .card => "Card number",
            .email => "Email",
            .password => "PIN or password",
            .pickup => "Pickup location",
            .language => "Language",
            .history => "Borrowing history",
        };
    }

    const first_editable: Setting = .email;
};

const Session = struct {
    app: *App,
    info: models.LibraryInfo,
    username: []u8,
    password: ?[]u8,
    core: *biblio.Handle,
    arena: std.heap.ArenaAllocator,
    labels: std.json.Value = .null,
    patron: ?models.Patron = null,
    locations: []const models.Location = &.{},
    tab: Tab = .search,
    lists: [5]List,
    detail: ?Detail = null,
    /// The Account tab's selected setting.
    setting: Setting = Setting.first_editable,
    /// A new password typed once, waiting to be typed again.
    new_password: ?[]u8 = null,
    /// What this account borrowed before; null for guests and while borrowing history is off.
    borrowed: ?biblio.borrowed.Index = null,
    borrowed_path: []const u8 = "",
    /// The history page being fetched for `borrowed`, off the main thread.
    fetch: ?*PageFetch = null,

    fn create(app: *App, lib: usize, username: []const u8, password: ?[]const u8) !*Session {
        const s = try gpa.create(Session);
        errdefer gpa.destroy(s);
        const info = app.store.libraries.items[lib];
        const user_copy = try gpa.dupe(u8, username);
        errdefer gpa.free(user_copy);
        const password_copy = if (password) |p| try gpa.dupe(u8, p) else null;
        errdefer if (password_copy) |p| {
            std.crypto.secureZero(u8, p);
            gpa.free(p);
        };
        s.* = .{
            .app = app,
            .info = info,
            .username = user_copy,
            .password = password_copy,
            .core = undefined,
            .arena = .init(gpa),
            .lists = undefined,
        };
        errdefer s.arena.deinit();
        for (&s.lists, 0..) |*l, i| l.* = .init(@fromBackingInt(@intCast(i)));
        errdefer for (&s.lists) |*l| l.deinit();
        const a = s.arena.allocator();
        const sub = try a.dupeSentinel(u8, info.subdomain, 0);
        const user = try a.dupeSentinel(u8, username, 0);
        // The client speaks the account's language once signed in; never the system's unasked.
        s.core = biblio.biblio_client_new(sub.ptr, user.ptr, passwordFor, s) orelse return error.OutOfMemory;
        // formatName and sortName read the labels as JSON.
        var map: std.json.ObjectMap = .empty;
        var it = info.labels.map.iterator();
        while (it.next()) |e| map.put(a, e.key_ptr.*, .{ .string = e.value_ptr.* }) catch {};
        s.labels = .{ .object = map };
        return s;
    }

    fn passwordFor(ctx: ?*anyopaque, _: [*:0]const u8, _: [*:0]const u8) callconv(.c) ?[*:0]u8 {
        const s: *Session = @ptrCast(@alignCast(ctx.?));
        const p = s.password orelse return null;
        const out = biblio.biblio_alloc(p.len + 1) orelse return null;
        @memcpy(out[0..p.len], p);
        out[p.len] = 0;
        return @ptrCast(out);
    }

    fn close(s: *Session) void {
        if (s.app.picker) |*p| p.deinit();
        s.app.picker = null;
        if (s.fetch) |job| job.discard();
        // The lists' fetches end before the client goes.
        for (&s.lists) |*l| l.deinit();
        if (s.borrowed) |*ix| ix.deinit();
        biblio.biblio_client_free(s.core);
        if (s.password) |p| {
            std.crypto.secureZero(u8, p);
            gpa.free(p);
        }
        s.forgetNewPassword();
        gpa.free(s.username);
        if (s.detail) |*d| d.arena.deinit();
        s.arena.deinit();
        if (s.app.session == s) s.app.session = null;
        gpa.destroy(s);
    }

    fn isGuest(s: *const Session) bool {
        return s.username.len == 0;
    }

    fn client(s: *Session) *biblio.Client {
        return s.core.client;
    }

    /// Signs in (unless a guest), then loads branches and, for accounts, the hold and checkout
    /// counts.
    fn start(s: *Session, force: bool) bool {
        const app = s.app;
        const a = s.arena.allocator();
        var failure: biblio.Failure = undefined;
        if (!s.isGuest()) {
            app.busy("Signing in…");
            s.patron = s.client().login(a, force, &failure) catch {
                app.fail("{s}", .{failure.message});
                return false;
            };
        }
        app.busy("Loading branches…");
        s.locations = s.client().locations(a, &failure) catch &.{};
        app.session = s;
        if (!s.isGuest()) {
            s.reload(.holds);
            s.reload(.checkouts);
            s.startBorrowed();
        }
        app.say("Signed in to {s}{s}{s}. Press / to search.", .{ displayName(s.info), if (s.isGuest()) " as a guest" else " as ", s.username });
        return true;
    }

    fn list(s: *Session, tab: Tab) *List {
        return &s.lists[@backingInt(tab)];
    }

    fn tabs(s: *const Session) []const Tab {
        return if (s.isGuest()) &.{ .search, .new_titles } else std.enums.values(Tab);
    }

    // Loading

    /// Fetches a page the core list has in flight, while the screen waits.
    fn loadPage(s: *Session, l: *List, page: i64) void {
        const app = s.app;
        app.busy(if (page > 1) "Loading more…" else "Loading…");
        const generation = l.core.generation;
        var arena = std.heap.ArenaAllocator.init(gpa);
        var failure: biblio.Failure = undefined;
        const result = l.request().fetch(s.client(), arena.allocator(), page, &failure) catch {
            app.fail("{s} Press r to try again.", .{failure.message});
            arena.deinit();
            _ = l.core.fail(generation, page) catch {};
            l.failed = true;
            return;
        };
        app.message = "";
        s.took(l, arena, page, generation, result);
    }

    /// A fetched page: into the list, then the rest of the pages if it needs them all.
    fn took(s: *Session, l: *List, arena: std.heap.ArenaAllocator, page: i64, generation: u64, result: models.ListPage) void {
        l.keep(arena, page, generation, result);
        if (page == 1 and l.core.wantsAllPages()) s.startBackground(l);
    }

    /// Starts again from the first page.
    fn reload(s: *Session, tab: Tab) void {
        const l = s.list(tab);
        // A fetch still running for the old pages is discarded when it ends.
        l.background = false;
        l.failed = false;
        l.cursor = 0;
        l.top = 0;
        l.clearMarks();
        l.releasePages();
        if (tab == .search and std.mem.trim(u8, l.query, " ").len == 0) {
            l.core.clear() catch {};
            return;
        }
        l.core.reload(false) catch return;
        s.loadPage(l, 1);
    }

    /// Fetches the pages of the placeholders on screen.
    fn fetchVisible(s: *Session) void {
        if (s.detail != null or s.tab == .account or s.app.picker != null) return;
        const l = s.list(s.tab);
        if (l.failed or !l.core.loaded) return;
        const visible = s.visibleEntries();
        l.scroll(visible);
        var i = l.top;
        while (i < @min(l.rows().len, l.top + visible)) : (i += 1) {
            const row = l.rows()[i];
            if (row.id != null) continue;
            const page = l.pageOf(row.position);
            if (!(l.core.request(page) catch false)) continue;
            s.loadPage(l, page);
            if (l.failed) return;
        }
    }

    fn startBackground(s: *Session, l: *List) void {
        if (!l.core.beginBackground()) return;
        l.background = true;
        s.nextBackground(l);
    }

    fn nextBackground(s: *Session, l: *List) void {
        if (l.job != null) return; // when it ends, `poll` asks for the next page
        const page = l.core.nextBackgroundPage() catch 0;
        if (page <= 0) {
            l.background = false;
            return;
        }
        l.job = PageFetch.start(s.client(), l.request(), page, l.core.generation) orelse {
            _ = l.core.fail(l.core.generation, page) catch {};
            l.core.endBackground();
            l.background = false;
            return;
        };
    }

    /// Takes in a list's background page, if one is in. True if the screen needs drawing.
    fn pollList(s: *Session, l: *List) bool {
        const job = l.job orelse return false;
        if (!job.done.load(.acquire)) return false;
        l.job = null;
        if (job.generation != l.core.generation) {
            job.discard();
            if (l.background) s.nextBackground(l);
            return false;
        }
        const result = job.result orelse {
            s.app.fail("{s}", .{job.message});
            _ = l.core.fail(job.generation, job.page) catch {};
            l.core.endBackground();
            l.background = false;
            job.discard();
            return true;
        };
        const page = job.page;
        const generation = job.generation;
        s.took(l, job.take(), page, generation, result);
        if (l.background) s.nextBackground(l);
        return true;
    }

    fn search(s: *Session, query: []const u8) void {
        const l = s.list(.search);
        const copy = gpa.dupe(u8, query) catch return;
        gpa.free(l.query);
        l.query = copy;
        // A new search starts with the default sort and no format filter.
        if (l.sort) |x| gpa.free(x);
        l.sort = null;
        if (l.format) |x| gpa.free(x);
        l.format = null;
        l.core.setSort(.server) catch {};
        l.core.setFormat(null) catch {};
        s.tab = .search;
        s.reload(.search);
    }

    fn select(s: *Session, tab: Tab) void {
        s.tab = tab;
        if (tab == .account or tab == .search) return;
        const l = s.list(tab);
        // Shown again over 15 minutes after it was fetched, a list is fetched again.
        if (!l.core.loaded or l.core.isStale(nowMs())) s.reload(tab);
    }

    /// r: account lists start a fresh session first, then every list reloads.
    fn refresh(s: *Session) void {
        if (s.tab.isAccount() and !s.isGuest()) {
            s.app.busy("Signing in…");
            var failure: biblio.Failure = undefined;
            if (s.client().login(s.arena.allocator(), true, &failure)) |p| {
                s.patron = p;
            } else |_| return s.app.fail("{s}", .{failure.message});
        }
        s.reload(s.tab);
        if (s.tab.isAccount()) s.syncBorrowed();
    }

    fn hints(s: *const Session) []const u8 {
        if (s.detail) |d| {
            const e = d.entry;
            if (e.hold != null and e.hold.?.canCancel) return "↑↓ scroll  c cancel hold  Esc back";
            if (s.canHold(e)) return "↑↓ scroll  h place hold  Esc back";
            return "↑↓ scroll  Esc back";
        }
        if (s.tab == .account) {
            if (s.isGuest()) return "Tab section  Esc libraries  ^C quit";
            return "↑↓ move  Enter change  t barcode type  b refresh borrowing history  Tab section  Esc libraries";
        }
        const l = &s.lists[@backingInt(s.tab)];
        if (l.marked.count() > 0) return switch (s.tab) {
            .search, .new_titles => "Space mark  h place holds on marked  Esc clear marks",
            .holds => "Space mark  c cancel marked holds  Esc clear marks",
            else => "Space mark  Esc clear marks",
        };
        return switch (s.tab) {
            .search, .new_titles => if (s.isGuest())
                "↑↓ move  Enter details  Tab section  / search  s sort  f filter  r reload  Esc libraries"
            else
                "↑↓ move  Enter details  Space mark  h hold  / search  s sort  f filter  n not borrowed  r reload  Esc libraries",
            .holds => "↑↓ move  Enter details  Space mark  c cancel  s sort  f filter  n not borrowed  r reload  Esc libraries",
            else => "↑↓ move  Enter details  Tab section  / search  s sort  f filter  r reload  Esc libraries",
        };
    }

    fn handle(s: *Session, key: Key) void {
        if (s.detail != null) return s.handleDetail(key);
        const tabs_ = s.tabs();
        const index = std.mem.indexOfScalar(Tab, tabs_, s.tab) orelse 0;
        const has_marks = s.tab != .account and s.list(s.tab).marked.count() > 0;
        switch (key) {
            .tab, .right => return s.select(tabs_[(index + 1) % tabs_.len]),
            .back_tab, .left => return s.select(tabs_[(index + tabs_.len - 1) % tabs_.len]),
            .escape => return if (has_marks) s.list(s.tab).clearMarks() else s.close(),
            .char => |c| switch (c) {
                '1'...'6' => if (c - '1' < tabs_.len) return s.select(tabs_[@intCast(c - '1')]),
                'q' => return s.close(),
                '/' => {
                    var prompt: Prompt = .{ .label = "Search", .action = .search };
                    prompt.set(s.list(.search).query);
                    return s.app.startPrompt(prompt);
                },
                else => {},
            },
            else => {},
        }
        if (s.tab == .account) return s.handleAccount(key);
        const l = s.list(s.tab);
        const n = l.rows().len;
        const page = s.visibleEntries();
        switch (key) {
            .up => l.cursor -|= 1,
            .down => l.cursor = @min(l.cursor + 1, n -| 1),
            .page_up => l.cursor -|= page,
            .page_down => l.cursor = @min(l.cursor + page, n -| 1),
            .home => l.cursor = 0,
            .end => l.cursor = n -| 1,
            .enter => if (l.entryAt(l.cursor)) |e| s.openDetail(e),
            .char => |c| switch (c) {
                'r' => s.refresh(),
                'n' => if (s.notBorrowedOffered(s.tab)) {
                    l.not_borrowed = !l.not_borrowed;
                    s.applyNotBorrowed(l);
                },
                's' => s.pickSort(l),
                'f' => s.pickFilter(l),
                ' ' => if (!s.isGuest()) if (l.entryAt(l.cursor)) |e| {
                    if (l.marked.fetchSwapRemove(e.id)) |kv| {
                        gpa.free(kv.key);
                    } else if (gpa.dupe(u8, e.id)) |id| {
                        l.marked.put(gpa, id, {}) catch gpa.free(id);
                    } else |_| {}
                    l.cursor = @min(l.cursor + 1, n -| 1);
                },
                'h' => if (s.tab.isCatalog()) s.holdTargets(l),
                'c' => if (s.tab == .holds) s.cancelTargets(l),
                else => {},
            },
            else => {},
        }
    }

    fn visibleEntries(s: *const Session) usize {
        return @max(1, (s.app.term.size().rows -| 4) / 2);
    }

    // Sorting and filtering

    fn pickSort(s: *Session, l: *List) void {
        if (!l.core.loaded) return;
        var p: Picker = .init(.sort);
        p.title = "Sort by";
        const a = p.a();
        const client_sort = l.core.sort;
        const current = l.sort orelse l.applied_sort orelse "";
        var has_title = false;
        for (l.sort_options) |o| {
            if (std.mem.eql(u8, o, "title")) has_title = true;
            p.add(.{ .label = library.sortName(a, .of(s.labels), o), .id = o, .checked = client_sort == .server and std.mem.eql(u8, o, current) });
        }
        // Client sorts, which need every page.
        p.add(.{ .label = "People Waiting", .id = "~people", .checked = client_sort == .people_waiting });
        if (!has_title) p.add(.{ .label = "Title", .id = "~title", .checked = client_sort == .title });
        p.settle();
        s.app.picker = p;
    }

    fn pickFilter(s: *Session, l: *List) void {
        if (!l.core.loaded) return;
        var p: Picker = .init(.filter);
        p.title = "Filter";
        const a = p.a();
        if (s.tab == .holds) {
            p.add(.{ .label = "Status", .heading = true });
            const filters = [_]struct { item_list.HoldFilter, []const u8 }{
                .{ .none, "All Holds" },
                .{ .ready, "Ready" },
                .{ .not_ready, "Not Ready" },
                .{ .on_order, "On Order" },
            };
            for (filters) |f| p.add(.{
                .label = std.fmt.allocPrint(a, "{s} ({d})", .{ f[1], l.core.holdCount(f[0]) }) catch f[1],
                .id = @tagName(f[0]),
                .checked = l.hold_filter == f[0],
                .status = true,
            });
            p.add(.{ .label = "Format", .heading = true });
        }
        p.add(.{ .label = "All Formats", .checked = l.format == null });
        if (s.tab.isCatalog()) {
            for (l.facet_formats) |v| s.addFormat(&p, l, v.value, v.count);
            // A refined format filtered locally may not be among the server's.
            if (l.format) |f| if (!hasOption(&p, f)) s.addFormat(&p, l, f, -1);
        } else {
            for (l.core.formats.items) |fc| s.addFormat(&p, l, std.mem.span(fc.format), fc.count);
        }
        p.settle();
        s.app.picker = p;
    }

    fn hasOption(p: *const Picker, id: []const u8) bool {
        for (p.options.items) |o| if (!o.status and std.mem.eql(u8, o.id, id)) return true;
        return false;
    }

    fn addFormat(s: *Session, p: *Picker, l: *const List, code: []const u8, count: i64) void {
        const name = library.formatName(p.a(), .of(s.labels), code);
        // A refined format's count is unknown (-1) until its pages are fetched.
        const label = if (count < 0) name else std.fmt.allocPrint(p.a(), "{s} ({d})", .{ name, count }) catch name;
        p.add(.{ .label = label, .id = code, .checked = if (l.format) |f| std.mem.eql(u8, f, code) else false });
    }

    fn setSort(s: *Session, l: *List, id: []const u8) void {
        if (std.mem.eql(u8, id, "~people") or std.mem.eql(u8, id, "~title")) {
            const selected = l.selectedId();
            l.core.setSort(if (std.mem.eql(u8, id, "~people")) .people_waiting else .title) catch {};
            l.reselect(selected);
            return s.startBackground(l);
        }
        const copy = gpa.dupe(u8, id) catch return;
        if (l.sort) |x| gpa.free(x);
        l.sort = copy;
        l.core.setSort(.server) catch {};
        s.reload(l.tab);
    }

    fn setFormat(s: *Session, l: *List, code: []const u8) void {
        const copy: ?[]u8 = if (code.len == 0) null else gpa.dupe(u8, code) catch return;
        if (l.format) |x| gpa.free(x);
        l.format = copy;
        const selected = l.selectedId();
        // Searches send the format to the server too; the list filters refined ones locally.
        l.core.setFormat(l.format) catch {};
        if (l.tab.isCatalog()) {
            if (selected) |x| gpa.free(x);
            return s.reload(l.tab);
        }
        l.reselect(selected);
        if (l.core.needsAllPages()) s.startBackground(l);
    }

    fn setHoldFilter(s: *Session, l: *List, filter: item_list.HoldFilter) void {
        l.hold_filter = filter;
        const selected = l.selectedId();
        l.core.setHoldFilter(filter) catch {};
        l.reselect(selected);
        if (l.core.needsAllPages()) s.startBackground(l);
    }

    /// Filters "Not Borrowed" with the index as it is now, or stops.
    fn applyNotBorrowed(s: *Session, l: *List) void {
        const selected = l.selectedId();
        if (l.not_borrowed) if (s.borrowed) |*ix| {
            const indexes = [_]*const biblio.borrowed.Index{ix};
            l.core.setNotBorrowed(&indexes) catch {};
            l.filtered_generation = ix.generation;
        } else {
            l.core.setNotBorrowed(&.{}) catch {};
        } else {
            l.core.setNotBorrowed(&.{}) catch {};
        }
        l.reselect(selected);
        if (l.core.needsAllPages()) s.startBackground(l);
    }

    /// A choice from a picker.
    fn picked(s: *Session, p: *Picker, option: Picker.Option) void {
        if (option.heading) return;
        switch (p.action) {
            .hold_pickup => s.placeHolds(p.targets, option.id),
            .default_pickup => s.setPickup(option.id),
            .language => s.setLanguage(option.id),
            .sort => if (s.tab != .account) s.setSort(s.list(s.tab), option.id),
            .filter => if (s.tab != .account) {
                const l = s.list(s.tab);
                if (option.status) {
                    s.setHoldFilter(l, std.meta.stringToEnum(item_list.HoldFilter, option.id) orelse .none);
                } else {
                    s.setFormat(l, option.id);
                }
            },
        }
    }

    // Details

    fn openDetail(s: *Session, entry: models.ListEntry) void {
        s.detail = .{ .arena = .init(gpa), .entry = entry, .from = s.tab };
        const d = &s.detail.?;
        const a = d.arena.allocator();
        var failure: biblio.Failure = undefined;
        s.app.busy("Loading availability…");
        d.copies = s.client().availability(a, entry.bib.id, &failure) catch blk: {
            d.copies_error = a.dupe(u8, failure.message) catch "";
            break :blk &.{};
        };
        d.fields = s.client().detailFields(a, entry.bib.id, &failure) catch &.{};
        s.app.message = "";
    }

    fn closeDetail(s: *Session) void {
        if (s.detail) |*d| d.arena.deinit();
        s.detail = null;
    }

    fn handleDetail(s: *Session, key: Key) void {
        const d = &s.detail.?;
        const e = d.entry;
        switch (key) {
            .escape, .left, .backspace => s.closeDetail(),
            .up => d.scroll -|= 1,
            .down => d.scroll += 1,
            .page_up => d.scroll -|= s.app.term.size().rows / 2,
            .page_down => d.scroll += s.app.term.size().rows / 2,
            .home => d.scroll = 0,
            .char => |c| switch (c) {
                'q' => s.closeDetail(),
                'h' => if (s.canHold(e)) s.pickPickup(&.{target(e)}),
                'c' => if (e.hold) |h| if (h.canCancel) {
                    s.askCancel(&.{target(e)});
                },
                else => {},
            },
            else => {},
        }
    }

    fn canHold(s: *const Session, e: models.ListEntry) bool {
        return !s.isGuest() and e.hold == null and e.checkout == null and e.accountStatus == null and e.bib.holdable;
    }

    fn target(e: models.ListEntry) Target {
        return .{ .id = e.bib.id, .material_type = e.bib.materialType, .title = e.bib.title, .hold = e.hold };
    }

    // Holds

    /// h in a catalog list: the marked items, else the selected one.
    fn holdTargets(s: *Session, l: *List) void {
        var targets: std.ArrayList(Target) = .empty;
        defer targets.deinit(gpa);
        var skipped: usize = 0;
        if (l.marked.count() > 0) {
            for (l.marked.keys()) |id| {
                const e = l.by_id.get(id) orelse continue;
                if (s.canHold(e)) targets.append(gpa, target(e)) catch {} else skipped += 1;
            }
        } else if (l.entryAt(l.cursor)) |e| {
            if (s.canHold(e)) targets.append(gpa, target(e)) catch {} else skipped += 1;
        }
        if (targets.items.len == 0) return s.app.fail("{s}", .{if (skipped > 1) "You have these already, or they can't be held." else "You have this already, or it can't be held."});
        s.pickPickup(targets.items);
    }

    /// c in Holds: the marked holds, else the selected one.
    fn cancelTargets(s: *Session, l: *List) void {
        var targets: std.ArrayList(Target) = .empty;
        defer targets.deinit(gpa);
        if (l.marked.count() > 0) {
            for (l.marked.keys()) |id| {
                const e = l.by_id.get(id) orelse continue;
                if (e.hold) |h| if (h.canCancel) targets.append(gpa, target(e)) catch {};
            }
        } else if (l.entryAt(l.cursor)) |e| {
            if (e.hold) |h| if (h.canCancel) targets.append(gpa, target(e)) catch {};
        }
        if (targets.items.len == 0) return s.app.fail("The library doesn't allow canceling {s}.", .{if (l.marked.count() > 1) "these holds" else "this hold"});
        s.askCancel(targets.items);
    }

    /// Asks where to pick up holds, starting at the preferred location.
    fn pickPickup(s: *Session, targets: []const Target) void {
        var p: Picker = .init(.hold_pickup);
        const a = p.a();
        p.targets = a.dupe(Target, targets) catch return;
        p.title = if (targets.len == 1)
            std.fmt.allocPrint(a, "Pick up “{s}” at", .{targets[0].title}) catch ""
        else
            std.fmt.allocPrint(a, "Pick up {d} holds at", .{targets.len}) catch "";
        s.addLocations(&p);
        if (p.options.items.len == 0) p.add(.{ .label = s.pickupName(), .checked = true });
        p.settle();
        s.app.picker = p;
    }

    fn addLocations(s: *Session, p: *Picker) void {
        const preferred = if (s.patron) |pt| pt.preferredPickup orelse "" else "";
        for (s.locations) |loc| p.add(.{ .label = loc.name, .id = loc.id, .checked = std.mem.eql(u8, loc.id, preferred) });
    }

    /// The confirmation's targets, until it's answered.
    var cancel_targets: std.ArrayList(Target) = .empty;
    var cancel_arena: std.heap.ArenaAllocator = .init(gpa);

    fn askCancel(s: *Session, targets: []const Target) void {
        _ = cancel_arena.reset(.retain_capacity);
        cancel_targets = .empty;
        cancel_targets.appendSlice(cancel_arena.allocator(), targets) catch return;
        if (targets.len == 1)
            s.app.ask(.cancel_holds, "Cancel your hold on “{s}”?", .{targets[0].title})
        else
            s.app.ask(.cancel_holds, "Cancel {d} holds?", .{targets.len});
    }

    fn pickupName(s: *const Session) []const u8 {
        const id = (s.patron orelse return "your preferred branch").preferredPickup orelse return "your preferred branch";
        return s.locationName(id);
    }

    fn locationName(s: *const Session, id: []const u8) []const u8 {
        for (s.locations) |loc| if (std.mem.eql(u8, loc.id, id)) return loc.name;
        return id;
    }

    fn placeHolds(s: *Session, targets: []const Target, branch: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var placed: usize = 0;
        var refusal: ?[]const u8 = null;
        var refused: usize = 0;
        for (targets, 0..) |t, i| {
            if (targets.len > 1) {
                var buf: [64]u8 = undefined;
                s.app.busy(App.format(&buf, "Placing holds… {d} of {d}", .{ i + 1, targets.len }));
            } else s.app.busy("Placing hold…");
            var failure: biblio.Failure = undefined;
            s.client().placeHold(a, t.id, t.material_type, if (branch.len > 0) branch else null, &failure) catch {
                // At the account's hold limit, the rest would be refused too.
                if (std.mem.eql(u8, failure.kind, "holdLimit")) {
                    refused += targets.len - i;
                    refusal = std.fmt.allocPrint(a, "“{s}”: {s}", .{ t.title, failure.message }) catch failure.message;
                    break;
                }
                refused += 1;
                if (refusal == null) refusal = std.fmt.allocPrint(a, "“{s}”: {s}", .{ t.title, failure.message }) catch failure.message;
                continue;
            };
            placed += 1;
            // Show the hold on catalog rows without reloading them.
            for ([_]Tab{ .search, .new_titles }) |tab| {
                var it = s.list(tab).by_id.valueIterator();
                while (it.next()) |e| if (std.mem.eql(u8, e.bib.id, t.id)) {
                    e.accountStatus = .{ .kind = "onHold" };
                };
            }
        }
        // The items live in the lists they came from, which stay loaded.
        s.closeDetail();
        s.list(.search).clearMarks();
        s.list(.new_titles).clearMarks();
        const where = s.locationName(branch);
        var buf: [512]u8 = undefined;
        const outcome = if (refusal) |r|
            if (placed == 0 and refused == 1) App.format(&buf, "{s}", .{r}) else App.format(&buf, "Placed {d}, refused {d}. {s}", .{ placed, refused, r })
        else if (placed == 1)
            App.format(&buf, "Hold placed on “{s}” for pickup at {s}.", .{ targets[0].title, where })
        else
            App.format(&buf, "Placed {d} holds for pickup at {s}.", .{ placed, where });
        if (placed > 0) s.reload(.holds);
        if (refusal != null) s.app.fail("{s}", .{outcome}) else s.app.say("{s}", .{outcome});
    }

    fn cancelHolds(s: *Session) void {
        const targets = cancel_targets.items;
        if (targets.len == 0) return;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var refs: std.ArrayList(biblio.Client.HoldRef) = .empty;
        for (targets) |t| if (t.hold) |h| refs.append(a, .{ .id = h.id, .metadataId = h.metadataId }) catch {};
        var failure: biblio.Failure = undefined;
        s.app.busy(if (refs.items.len == 1) "Canceling hold…" else "Canceling holds…");
        const refused = s.client().cancelHolds(a, refs.items, &failure) catch
            return s.app.fail("{s}", .{failure.message});
        for (targets) |t| {
            const h = t.hold orelse continue;
            const kept = for (refused) |r| {
                if (std.mem.eql(u8, r.holdId, h.id)) break true;
            } else false;
            if (kept) continue;
            for ([_]Tab{ .search, .new_titles }) |tab| {
                var it = s.list(tab).by_id.valueIterator();
                while (it.next()) |e| if (std.mem.eql(u8, e.bib.id, t.id)) {
                    e.accountStatus = null;
                    e.hold = null;
                };
            }
        }
        // The library may refuse some (say, holds ready for pickup): name them, and why.
        var buf: [512]u8 = undefined;
        const canceled = refs.items.len - @min(refs.items.len, refused.len);
        const outcome = if (refused.len > 0) blk: {
            const title = for (targets) |t| {
                if (t.hold) |h| if (std.mem.eql(u8, h.id, refused[0].holdId)) break t.title;
            } else "A hold";
            break :blk if (refs.items.len == 1)
                App.format(&buf, "“{s}” wasn't canceled: {s}", .{ title, refused[0].reason })
            else
                App.format(&buf, "Canceled {d}; {d} refused. “{s}”: {s}", .{ canceled, refused.len, title, refused[0].reason });
        } else if (canceled == 1) App.format(&buf, "Hold canceled.", .{}) else App.format(&buf, "Canceled {d} holds.", .{canceled});
        const failed = refused.len > 0;
        s.closeDetail();
        s.reload(.holds);
        if (failed) s.app.fail("{s}", .{outcome}) else s.app.say("{s}", .{outcome});
    }

    // Account settings

    fn handleAccount(s: *Session, key: Key) void {
        if (s.isGuest()) return;
        const last = @backingInt(Setting.history);
        const first = @backingInt(Setting.first_editable);
        var i = @backingInt(s.setting);
        switch (key) {
            .up => i = @max(first, i -| 1),
            .down => i = @min(last, i + 1),
            .home => i = first,
            .end => i = last,
            .enter => s.changeSetting(),
            .char => |c| switch (c) {
                'b' => s.rebuildBorrowed(),
                't' => {
                    const now = s.app.store.symbology(s.info.subdomain);
                    s.app.store.setSymbology(s.info.subdomain, if (now == .codabar) .code128 else .codabar);
                },
                else => {},
            },
            else => {},
        }
        s.setting = @fromBackingInt(@intCast(i));
    }

    fn changeSetting(s: *Session) void {
        const p = s.patron orelse return;
        switch (s.setting) {
            .email => {
                var prompt: Prompt = .{ .label = "Email", .action = .email };
                prompt.set(p.email orelse "");
                s.app.startPrompt(prompt);
            },
            .password => s.app.startPrompt(.{ .label = "New PIN or password", .secret = true, .action = .new_password }),
            .pickup => {
                var picker: Picker = .init(.default_pickup);
                picker.title = "Pickup location";
                s.addLocations(&picker);
                picker.settle();
                s.app.picker = picker;
            },
            .language => {
                var picker: Picker = .init(.language);
                picker.title = "Library language";
                const a = picker.a();
                // Offered, never chosen by itself.
                if (s.app.system_language) |sys| if (closestLanguage(sys, s.info.languages)) |code| {
                    picker.add(.{ .label = std.fmt.allocPrint(a, "Use System Language ({s})", .{s.languageName(a, code)}) catch "Use System Language", .id = code });
                };
                for (s.info.languages) |code| picker.add(.{ .label = s.languageName(a, code), .id = code, .checked = std.mem.eql(u8, code, p.language) });
                picker.settle();
                s.app.picker = picker;
            },
            .history => if (p.borrowingHistoryEnabled orelse true)
                s.app.ask(.history_off, "Turn off borrowing history? The library forgets what you borrowed.", .{})
            else
                s.setBorrowingHistory(true),
            else => {},
        }
    }

    fn languageName(s: *const Session, a: std.mem.Allocator, code: []const u8) []const u8 {
        return s.info.labels.map.get(std.fmt.allocPrint(a, "LANGUAGE_NAME.{s}", .{code}) catch "") orelse code;
    }

    /// The patron as the client has it after a change.
    fn refreshPatron(s: *Session) void {
        if (s.client().currentPatron(s.arena.allocator())) |p| s.patron = p;
    }

    fn changeEmail(s: *Session, email: []const u8) void {
        if (email.len == 0) return;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var failure: biblio.Failure = undefined;
        s.app.busy("Saving…");
        s.client().changeEmail(arena.allocator(), email, &failure) catch return s.app.fail("{s}", .{failure.message});
        s.refreshPatron();
        s.app.say("Email changed.", .{});
    }

    fn forgetNewPassword(s: *Session) void {
        const p = s.new_password orelse return;
        std.crypto.secureZero(u8, p);
        gpa.free(p);
        s.new_password = null;
    }

    fn newPassword(s: *Session, input: []const u8) void {
        if (input.len == 0) return;
        s.forgetNewPassword();
        s.new_password = gpa.dupe(u8, input) catch return;
        s.app.startPrompt(.{ .label = "The same again", .secret = true, .action = .confirm_password });
    }

    fn confirmPassword(s: *Session, input: []const u8) void {
        const new = s.new_password orelse return;
        defer s.forgetNewPassword();
        if (!std.mem.eql(u8, new, input)) return s.app.fail("The two didn't match; the password is unchanged.", .{});
        const current = s.password orelse return;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var failure: biblio.Failure = undefined;
        s.app.busy("Saving…");
        s.client().changePassword(arena.allocator(), current, new, &failure) catch return s.app.fail("{s}", .{failure.message});
        // Signing in again uses the new one.
        const copy = gpa.dupe(u8, new) catch return;
        std.crypto.secureZero(u8, current);
        gpa.free(current);
        s.password = copy;
        s.app.say("Password changed.", .{});
    }

    fn setPickup(s: *Session, id: []const u8) void {
        if (id.len == 0) return;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var failure: biblio.Failure = undefined;
        s.app.busy("Saving…");
        s.client().setDefaultPickupLocation(arena.allocator(), id, &failure) catch return s.app.fail("{s}", .{failure.message});
        s.refreshPatron();
        s.app.say("New holds are picked up at {s}.", .{s.locationName(id)});
    }

    fn setLanguage(s: *Session, code: []const u8) void {
        if (code.len == 0) return;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var failure: biblio.Failure = undefined;
        s.app.busy("Saving…");
        s.client().changeLanguage(a, code, &failure) catch return s.app.fail("{s}", .{failure.message});
        s.refreshPatron();
        s.app.say("The library speaks {s} to you now.", .{s.languageName(a, code)});
    }

    fn setBorrowingHistory(s: *Session, on: bool) void {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var failure: biblio.Failure = undefined;
        s.app.busy("Saving…");
        s.client().setBorrowingHistory(arena.allocator(), on, &failure) catch return s.app.fail("{s}", .{failure.message});
        s.refreshPatron();
        if (on) {
            s.startBorrowed();
        } else {
            // Nothing is kept while the library keeps no history.
            if (s.fetch) |job| job.discard();
            s.fetch = null;
            if (s.borrowed) |*ix| ix.deinit();
            s.borrowed = null;
            s.app.store.deleteBorrowed(s.borrowed_path);
            for (&s.lists) |*l| if (l.not_borrowed) {
                l.not_borrowed = false;
                s.applyNotBorrowed(l);
            };
        }
        s.reload(.history);
        s.app.say("Borrowing history is {s}.", .{if (on) "on" else "off"});
    }

    // Borrowed before

    /// Reads the saved index and brings it up to date, unless the library keeps no borrowing
    /// history for the account: then nothing is kept.
    fn startBorrowed(s: *Session) void {
        if (s.borrowed_path.len == 0) s.borrowed_path = s.app.store.borrowedPath(s.arena.allocator(), s.info.subdomain, s.username);
        const on = if (s.patron) |p| p.borrowingHistoryEnabled orelse true else true;
        if (!on) return s.app.store.deleteBorrowed(s.borrowed_path);
        if (s.borrowed != null) return s.syncBorrowed();
        s.borrowed = .init(gpa);
        const ix = &s.borrowed.?;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        if (s.app.store.readBorrowed(arena.allocator(), s.borrowed_path)) |bytes| _ = ix.importJson(bytes) catch false;
        s.fetchHistory(ix.beginSync());
    }

    /// Catches up on borrowing history, as when account lists reload.
    fn syncBorrowed(s: *Session) void {
        if (s.borrowed) |*ix| s.fetchHistory(ix.beginSync());
    }

    /// Forgets the index and reads the whole history again.
    fn rebuildBorrowed(s: *Session) void {
        const ix = if (s.borrowed) |*x| x else return;
        if (ix.isSyncing()) return;
        const page = ix.rebuild();
        s.saveBorrowed();
        s.fetchHistory(page);
    }

    /// Fetches a history page for the index, unless `page` is 0 (the sync is done).
    fn fetchHistory(s: *Session, page: i64) void {
        if (page <= 0 or s.fetch != null) return;
        s.fetch = PageFetch.start(s.client(), .{ .tab = .history }, page, 0) orelse return s.borrowed.?.fail();
    }

    /// Takes in fetched pages, if any are in, and fetches the next. True if the screen needs
    /// drawing again.
    fn poll(s: *Session) bool {
        var changed = false;
        for (&s.lists) |*l| changed = s.pollList(l) or changed;
        return s.pollHistory() or changed;
    }

    fn pollHistory(s: *Session) bool {
        const job = s.fetch orelse return false;
        if (!job.done.load(.acquire)) return false;
        s.fetch = null;
        defer job.discard();
        const ix = if (s.borrowed) |*x| x else return false;
        const page = job.result orelse {
            ix.fail();
            return true;
        };
        const a = job.arena.allocator();
        const sources = a.alloc(biblio.borrowed.Source, page.entries.len) catch return true;
        for (sources, page.entries) |*src, e| {
            const h = e.history;
            src.* = .{
                .id = if (h) |x| x.id else e.id,
                .metadata_id = if (h) |x| x.metadataId else e.bib.id,
                .checkout_date = if (h) |x| x.checkoutDate orelse "" else "",
                .returned_date = if (h) |x| x.returnedDate orelse "" else "",
                .format = e.bib.format,
                .library_format = e.bib.libraryFormat,
                .title = e.bib.title,
                .author = if (e.bib.authors.len > 0) e.bib.authors[0] else "",
            };
        }
        const next = ix.apply(job.page, sources, page.count, page.pageSize) catch {
            ix.fail();
            return true;
        };
        s.saveBorrowed();
        // "Not Borrowed" follows the index.
        for (&s.lists) |*l| if (l.not_borrowed and l.filtered_generation != ix.generation) s.applyNotBorrowed(l);
        s.fetchHistory(next);
        return true;
    }

    fn saveBorrowed(s: *Session) void {
        const ix = if (s.borrowed) |*x| x else return;
        const bytes = ix.exportJson(gpa) catch return;
        defer gpa.free(bytes);
        s.app.store.writeBorrowed(s.borrowed_path, bytes);
    }

    /// Whether the account borrowed the item, or the same work in another format.
    fn borrowedMatch(s: *const Session, bib: models.Bib) ?biblio.borrowed.Borrowed {
        const ix = if (s.borrowed) |*x| x else return null;
        const b = ix.lookup(bib.id, bib.format, bib.title, if (bib.authors.len > 0) bib.authors[0] else "");
        return if (b.match == .none) null else b;
    }

    /// "the audiobook", "on Blu-ray Disc", "the book", or "as Kit".
    fn borrowedFormat(s: *const Session, a: std.mem.Allocator, code: ?[*:0]const u8) []const u8 {
        const c = if (code) |x| std.mem.span(x) else "";
        return borrowedPhrase(a, c, library.formatName(a, .of(s.labels), c));
    }

    /// "Not Borrowed" is offered once the whole history is read, and stays while it's on.
    fn notBorrowedOffered(s: *const Session, tab: Tab) bool {
        if (tab != .search and tab != .new_titles and tab != .holds) return false;
        if (s.lists[@backingInt(tab)].not_borrowed) return true;
        const ix = if (s.borrowed) |*x| x else return false;
        return ix.complete;
    }

    // Drawing

    fn draw(s: *Session, f: *Frame) void {
        const brand = if (s.info.primaryColor) |c| term.color256(c) orelse color.brand else color.brand;
        f.at(0, 0);
        f.style(.{ .fg = color.white, .bg = brand, .bold = true });
        const who = if (s.isGuest()) "Guest" else if (s.patron) |p| p.name else s.username;
        f.fill(f.text(std.fmt.allocPrint(f.a, " {s} · {s}", .{ displayName(s.info), who }) catch "", f.size.cols, false));
        f.style(.{});
        if (s.detail) |*d| return s.drawDetail(f, d);

        // Tabs, with counts for holds and checkouts.
        f.at(1, 0);
        var used: usize = 0;
        for (s.tabs(), 1..) |t, n| {
            const l = if (t == .account) null else s.list(t);
            const count = if (l) |x| if (x.core.loaded and (t == .holds or t == .checkouts)) std.fmt.allocPrint(f.a, " {d}", .{x.core.total}) catch "" else "" else "";
            f.style(if (t == s.tab) .{ .reverse = true, .bold = true } else .{ .fg = color.dim });
            used += f.text(std.fmt.allocPrint(f.a, " {d} {s}{s} ", .{ n, t.title(), count }) catch "", f.size.cols -| used, false);
            f.style(.{});
            used += f.text(" ", f.size.cols -| used, false);
        }

        if (s.tab == .account) return s.drawAccount(f);
        const l = s.list(s.tab);
        f.at(2, 0);
        f.style(.{ .fg = color.dim });
        if (s.tab == .search and l.query.len == 0) {
            _ = f.text(std.fmt.allocPrint(f.a, " Press / to search {s}.", .{displayName(s.info)}) catch "", f.size.cols, false);
        } else if (l.core.loaded) {
            _ = f.text(s.summary(f.a, l), f.size.cols, false);
        }
        f.style(.{});

        const rows = l.rows();
        if (l.core.loaded and rows.len == 0) {
            f.at(4, 2);
            const filtered = l.core.total > 0;
            const more = l.background or l.core.hasMore();
            _ = f.text(if (filtered) (if (more) "Nothing so far matches the filters. Still looking…" else "Nothing matches the filters.") else switch (s.tab) {
                .search => "No results.",
                .new_titles => "No new titles.",
                .holds => "No holds.",
                .checkouts => "Nothing checked out.",
                else => "No borrowing history. If it's off, the library doesn't keep one.",
            }, f.size.cols -| 4, false);
            return;
        }

        // Catalog and hold rows mark what was borrowed before.
        const marks = s.tab == .search or s.tab == .new_titles or s.tab == .holds;
        const visible = s.visibleEntries();
        l.scroll(visible);
        const end = @min(rows.len, l.top + visible);
        for (l.top..end) |i| {
            const selected = i == l.cursor;
            const row = 3 + (i - l.top) * 2;
            const bg: ?term.Color = if (selected) color.selected else null;
            const entry = l.entryAt(i) orelse {
                // A placeholder until its page is fetched.
                f.at(row, 0);
                f.style(.{ .bg = bg, .fg = color.dim });
                var w = f.text(if (selected) " ▸ " else "   ", 3, false);
                w += f.text(if (l.failed) "Not loaded. Press r to try again." else "…", f.size.cols -| w, false);
                f.fill(w);
                f.at(row + 1, 0);
                f.fill(0);
                f.style(.{});
                continue;
            };
            const marked = l.marked.contains(entry.id);
            f.at(row, 0);
            f.style(.{ .bg = bg, .bold = true });
            var w = f.text(if (marked) "✓" else " ", 1, false);
            w += f.text(if (selected) "▸ " else "  ", 2, false);
            w += f.text(entry.bib.title, f.size.cols -| w, false);
            if (entry.bib.authors.len > 0) {
                f.style(.{ .bg = bg, .fg = color.dim });
                w += f.text(std.fmt.allocPrint(f.a, " — {s}", .{entry.bib.authors[0]}) catch "", f.size.cols -| w, false);
            }
            f.fill(w);
            f.at(row + 1, 0);
            f.style(.{ .bg = bg, .fg = color.dim });
            w = f.text("   ", 3, false);
            w += f.text(s.formatLine(f.a, entry.bib), f.size.cols -| w, false);
            const borrowed = if (marks) s.borrowedMatch(entry.bib) else null;
            const mark_color = if (borrowed) |b| if (b.match == .same) color.dim else color.faint else color.dim;
            if (borrowed != null) {
                f.style(.{ .bg = bg, .fg = mark_color });
                w += f.text(" " ++ borrowed_mark, f.size.cols -| w, false);
            }
            const st = statusLine(f.a, entry);
            if (st.text.len > 0) {
                w += f.text("  ", f.size.cols -| w, false);
                f.style(.{ .bg = bg, .fg = st.color });
                w += f.text(st.text, f.size.cols -| w, false);
            }
            // The selected row spells out its mark, as a tooltip would.
            if (selected) if (borrowed) |b| {
                f.style(.{ .bg = bg, .fg = mark_color });
                w += f.text("  ", f.size.cols -| w, false);
                w += f.text(borrowedShort(f.a, b, s.borrowedFormat(f.a, b.format)), f.size.cols -| w, false);
            };
            f.fill(w);
            f.style(.{});
        }
    }

    /// The line above a list: what it is, how many, and how it's sorted and filtered.
    fn summary(s: *Session, a: std.mem.Allocator, l: *const List) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        out.append(a, ' ') catch {};
        if (s.tab == .search) out.print(a, "“{s}”: ", .{l.query}) catch {};
        // Filtered here, the server's count doesn't apply: count what's shown.
        const local = l.not_borrowed or l.hold_filter != .none or (l.format != null and !l.tab.isCatalog()) or
            (l.format != null and biblio.formats.isRefined(l.format.?));
        if (local) {
            out.print(a, "{d} shown{s}", .{ l.rows().len, if (l.background or l.core.hasMore()) " so far" else "" }) catch {};
        } else {
            out.print(a, "{d} {s}", .{ l.core.total, if (l.core.total == 1) "item" else "items" }) catch {};
        }
        const sort_name: ?[]const u8 = switch (l.core.sort) {
            .people_waiting => "People Waiting",
            .title => "Title",
            .server => if (l.sort orelse l.applied_sort) |id| library.sortName(a, .of(s.labels), id) else null,
            else => null,
        };
        if (sort_name) |n| out.print(a, " · sorted by {s}", .{n}) catch {};
        if (l.format) |code| out.print(a, " · {s}", .{library.formatName(a, .of(s.labels), code)}) catch {};
        if (l.hold_filter != .none) out.print(a, " · {s}", .{switch (l.hold_filter) {
            .ready => "Ready",
            .not_ready => "Not Ready",
            .on_order => "On Order",
            .none => "",
        }}) catch {};
        if (l.not_borrowed) out.appendSlice(a, " · not borrowed") catch {};
        if (s.tab == .holds) out.print(a, "   Ready {d} · Not Ready {d} · On Order {d}", .{ l.core.holdCount(.ready), l.core.holdCount(.not_ready), l.core.holdCount(.on_order) }) catch {};
        if (l.marked.count() > 0) out.print(a, "   {d} marked", .{l.marked.count()}) catch {};
        if (l.background) out.appendSlice(a, "   loading…") catch {};
        return out.items;
    }

    /// "Blu-ray Disc · 2026"
    fn formatLine(s: *const Session, a: std.mem.Allocator, bib: models.Bib) []const u8 {
        const format = library.formatName(a, .of(s.labels), bib.format);
        const date = bib.publicationDate orelse return format;
        return std.fmt.allocPrint(a, "{s} · {s}", .{ format, models.year(date) }) catch format;
    }

    fn drawAccount(s: *Session, f: *Frame) void {
        const p = s.patron orelse {
            f.at(3, 2);
            f.style(.{ .fg = color.dim });
            _ = f.text("Browsing as a guest. Choose a user in the library list to sign in.", f.size.cols -| 4, false);
            f.style(.{});
            return;
        };
        const values = [_][]const u8{
            p.name,
            s.info.name,
            p.barcode orelse "—",
            p.email orelse "—",
            "••••••",
            s.pickupName(),
            s.languageName(f.a, p.language),
            if (p.borrowingHistoryEnabled) |on| if (on) "On" else "Off" else "—",
        };
        for (values, 0..) |value, i| {
            const setting: Setting = @fromBackingInt(@intCast(i));
            const selected = setting == s.setting;
            f.at(3 + i, 0);
            f.style(.{ .bg = if (selected) color.selected else null, .fg = color.dim });
            var used = f.text(if (selected) " ▸ " else "   ", 3, false);
            used += f.text(setting.label(), 20, true);
            f.style(.{ .bg = if (selected) color.selected else null, .bold = selected });
            used += f.text(value, f.size.cols -| used, false);
            // Beside borrowing history: "Updating · 340 of 1,200" with a small gauge.
            if (setting == .history) if (s.borrowed) |*ix| if (ix.isSyncing()) {
                f.style(.{ .bg = if (selected) color.selected else null, .fg = color.dim });
                const fetched: i64 = @intCast(ix.entries.items.len);
                if (ix.total > 0) {
                    used += f.text(std.fmt.allocPrint(f.a, "   Updating · {s} of {s}  ", .{ grouped(f.a, @min(fetched, ix.total)), grouped(f.a, ix.total) }) catch "", f.size.cols -| used, false);
                    const cells = 12;
                    const filled: usize = @intCast(@divFloor(@min(fetched, ix.total) * cells, ix.total));
                    f.style(.{ .bg = if (selected) color.selected else null, .fg = 75 });
                    for (0..cells) |cell| {
                        if (cell == filled) f.style(.{ .bg = if (selected) color.selected else null, .fg = color.panel });
                        used += f.text("━", f.size.cols -| used, false);
                    }
                } else {
                    used += f.text("   Updating…", f.size.cols -| used, false);
                }
            };
            if (selected) f.fill(used);
            f.style(.{});
        }
        s.drawBarcode(f, 3 + values.len + 1, p.barcode orelse return);
    }

    /// The card as a barcode a scanner can read off the screen: two bar modules per column.
    fn drawBarcode(s: *Session, f: *Frame, row: usize, value: []const u8) void {
        const symbology = s.app.store.symbology(s.info.subdomain);
        const name = if (symbology == .codabar) "Codabar" else "Code 128";
        const lines = 4;
        f.at(row, 3);
        f.style(.{ .fg = color.dim });
        _ = f.text(std.fmt.allocPrint(f.a, "Library card · {s} (t switches)", .{name}) catch "", f.size.cols -| 3, false);
        f.style(.{});
        const widths = models.barcode(f.a, symbology, value) orelse {
            f.at(row + 1, 3);
            _ = f.text(std.fmt.allocPrint(f.a, "This card number can't be shown as {s}.", .{name}) catch "", f.size.cols -| 3, false);
            return;
        };
        const bars = barcodeText(f.a, widths, 10);
        const cols = term.columns(bars);
        if (cols + 3 > f.size.cols or row + lines + 2 > f.size.rows) {
            f.at(row + 1, 3);
            _ = f.text(std.fmt.allocPrint(f.a, "Make the window {d} columns wide to show the barcode{s}.", .{ cols + 3, if (symbology == .codabar) ", or press t for Code 128, which is narrower" else "" }) catch "", f.size.cols -| 3, false);
            return;
        }
        // Dark bars on a light ground, whatever the terminal's colors.
        for (0..lines) |i| {
            f.at(row + 1 + i, 3);
            f.style(.{ .fg = color.black, .bg = color.white });
            f.raw(bars);
            f.style(.{});
        }
        f.at(row + 1 + lines, 3 + (cols -| term.columns(value)) / 2);
        _ = f.text(value, f.size.cols -| 3, false);
    }

    fn drawDetail(s: *Session, f: *Frame, d: *Detail) void {
        // `mark` starts a copy's row with a colored dot; `indent` lines up its wrapped lines.
        const Line = struct { text: []const u8, style: term.Style = .{}, mark: ?term.Color = null, indent: bool = false };
        var lines: std.ArrayList(Line) = .empty;
        const a = f.a;
        const width = f.size.cols -| 4;
        const add = struct {
            fn add(l: *std.ArrayList(Line), alloc: std.mem.Allocator, text: []const u8, w: usize, style: term.Style) void {
                for (term.wrap(alloc, text, w)) |t| l.append(alloc, .{ .text = t, .style = style }) catch {};
            }
        }.add;
        const e = d.entry;
        const bib = e.bib;
        add(&lines, a, bib.title, width, .{ .bold = true });
        if (bib.subtitle) |sub| add(&lines, a, sub, width, .{});
        if (bib.authors.len > 0) add(&lines, a, std.mem.join(a, "; ", bib.authors) catch "", width, .{ .fg = 75 });
        add(&lines, a, s.formatLine(a, bib), width, .{ .fg = color.dim });
        if (bib.edition) |ed| add(&lines, a, ed, width, .{ .fg = color.dim });
        const st = statusLine(a, e);
        if (st.text.len > 0) add(&lines, a, st.text, width, .{ .fg = st.color });
        if (d.from != .history) if (s.borrowedMatch(bib)) |b| {
            const text = std.fmt.allocPrint(a, borrowed_mark ++ " {s}", .{borrowedSentence(a, b, s.borrowedFormat(a, b.format))}) catch "";
            add(&lines, a, text, width, .{ .fg = if (b.match == .same) color.dim else color.faint });
        };
        if (bib.summary) |summary_| {
            lines.append(a, .{ .text = "" }) catch {};
            add(&lines, a, summary_, width, .{});
        }
        lines.append(a, .{ .text = "" }) catch {};
        add(&lines, a, "Availability by location", width, .{ .bold = true, .underline = true });
        if (d.copies_error) |m| add(&lines, a, m, width, .{ .fg = color.failure });
        if (d.copies.len == 0 and d.copies_error == null) add(&lines, a, "No copies listed.", width, .{ .fg = color.dim });
        for (d.copies) |c| {
            var detail: std.ArrayList(u8) = .empty;
            detail.print(a, "{s} — {s}", .{ c.branch, c.status }) catch {};
            for ([_]?[]const u8{ c.collection, c.callNumber }) |v| if (v) |x| detail.print(a, " · {s}", .{x}) catch {};
            if (c.dueDate) |due| detail.print(a, " · due {s}", .{due}) catch {};
            const wrapped = term.wrap(a, detail.items, width -| 2);
            for (wrapped, 0..) |t, i| lines.append(a, .{ .text = t, .mark = if (i == 0) color.kind(c.kind) else null, .indent = i > 0 }) catch {};
        }
        if (d.fields.len > 0) {
            lines.append(a, .{ .text = "" }) catch {};
            add(&lines, a, "Details", width, .{ .bold = true, .underline = true });
            for (d.fields) |field| {
                add(&lines, a, field.label, width, .{ .fg = color.dim });
                for (field.values) |v| add(&lines, a, v, width -| 2, .{});
            }
        }

        const height = f.size.rows -| 2;
        d.scroll = @min(d.scroll, lines.items.len -| height);
        for (lines.items[d.scroll..@min(lines.items.len, d.scroll + height)], 0..) |line, i| {
            f.at(1 + i, 2);
            if (line.mark) |m| {
                f.style(.{ .fg = m });
                f.raw("● ");
            } else if (line.indent) {
                f.raw("  ");
            }
            f.style(line.style);
            _ = f.text(line.text, if (line.mark != null or line.indent) width -| 2 else width, false);
            f.style(.{});
        }
    }
};

/// Bars as half-block characters, two modules per column (a module per narrow unit, wide
/// elements rounded), with `quiet` blank modules on each side.
fn barcodeText(a: std.mem.Allocator, widths: []const f64, quiet: usize) []const u8 {
    var modules: std.ArrayList(bool) = .empty;
    modules.appendNTimes(a, false, quiet) catch return "";
    for (widths, 0..) |w, i| {
        const n: usize = @intFromFloat(@max(1, @round(w)));
        modules.appendNTimes(a, i % 2 == 0, n) catch return "";
    }
    modules.appendNTimes(a, false, quiet) catch return "";
    if (modules.items.len % 2 == 1) modules.append(a, false) catch return "";
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < modules.items.len) : (i += 2) {
        const left = modules.items[i];
        const right = modules.items[i + 1];
        out.appendSlice(a, if (left and right) "█" else if (left) "▌" else if (right) "▐" else " ") catch return "";
    }
    return out.items;
}

const Status = struct { text: []const u8, color: term.Color };

/// The account's relationship to the item if any, else the title's availability.
fn statusLine(a: std.mem.Allocator, e: models.ListEntry) Status {
    if (e.accountStatus) |s| {
        if (std.mem.eql(u8, s.kind, "checkedOut")) {
            const due = s.due orelse return .{ .text = "Checked out", .color = 141 };
            return .{ .text = std.fmt.allocPrint(a, "Checked out · due {s}", .{due}) catch "Checked out", .color = 141 };
        }
        if (s.ready) {
            const hold = e.hold orelse return .{ .text = "Ready for pickup", .color = color.success };
            const where = if (hold.pickupLocation) |l| std.fmt.allocPrint(a, " at {s}", .{l}) catch "" else "";
            const by = if (hold.pickupByDate) |d| std.fmt.allocPrint(a, " · by {s}", .{d}) catch "" else "";
            return .{ .text = std.fmt.allocPrint(a, "Ready for pickup{s}{s}", .{ where, by }) catch "Ready for pickup", .color = color.success };
        }
        // "On hold", "In transit", or "Paused", as the core names the hold's status.
        const name = if (e.hold) |h| std.mem.span(biblio.capi.biblio_hold_status_name((a.dupeSentinel(u8, h.status, 0) catch null))) else "On hold";
        if (s.position orelse if (e.hold) |h| h.position else null) |p|
            return .{ .text = std.fmt.allocPrint(a, "{s} · #{d} in line", .{ name, p }) catch name, .color = 75 };
        return .{ .text = name, .color = 75 };
    }
    if (e.history) |h| {
        const d = h.returnedDate orelse return .{ .text = "", .color = color.dim };
        return .{ .text = std.fmt.allocPrint(a, "Returned {s}", .{d}) catch "", .color = color.dim };
    }
    const bib = e.bib;
    const status = bib.status orelse "";
    const label: Status = if (std.mem.eql(u8, status, "AVAILABLE"))
        .{ .text = "Available", .color = color.success }
    else if (std.mem.eql(u8, status, "ON_ORDER"))
        .{ .text = "On order", .color = 75 }
    else if (std.mem.eql(u8, status, "UNAVAILABLE") or std.mem.eql(u8, status, "NOT_AVAILABLE"))
        .{ .text = "All copies in use", .color = 214 }
    else
        .{ .text = "", .color = color.dim };
    if (bib.totalCopies == 0) return label;
    const copies = if (bib.totalCopies == 1) "copy" else "copies";
    const holds = if (bib.heldCopies == 1) "hold" else "holds";
    return .{
        .text = std.fmt.allocPrint(a, "{s}{s}{d} {s} on {d} {s}", .{ label.text, if (label.text.len > 0) " · " else "", bib.heldCopies, holds, bib.totalCopies, copies }) catch label.text,
        .color = label.color,
    };
}

// MARK: Borrowed before

/// Follows the details of a row borrowed before.
const borrowed_mark = "↺";

/// How "borrowed" reads for a format: "the audiobook", "on Blu-ray Disc", "the book", or
/// "as Kit", given the format's code and name.
fn borrowedPhrase(a: std.mem.Allocator, code: []const u8, name: []const u8) []const u8 {
    const Kind = enum { audio, video, print };
    const kinds = std.StaticStringMap(Kind).initComptime(.{
        .{ "AB", .audio },
        .{ "BOOK_CD", .audio },
        .{ "PLAYAWAY_AUDIOBOOK", .audio },
        .{ "AUDIOBOOK", .audio },
        .{ "DVD", .video },
        .{ "BLURAY", .video },
        .{ "UK", .video },
        .{ "DVD_PBLURAY", .video },
        .{ "VIDEO_ONLINE", .video },
        .{ "BK", .print },
        .{ "LPRINT", .print },
        .{ "EBOOK", .print },
    });
    return switch (kinds.get(code) orelse return std.fmt.allocPrint(a, "as {s}", .{name}) catch name) {
        .audio => "the audiobook",
        .video => std.fmt.allocPrint(a, "on {s}", .{name}) catch name,
        .print => std.fmt.allocPrint(a, "the {s}", .{std.ascii.allocLowerString(a, name) catch name}) catch name,
    };
}

/// For a row: "Borrowed before · returned Mar 2024", or "Borrowed the audiobook · Mar 2024".
fn borrowedShort(a: std.mem.Allocator, b: biblio.borrowed.Borrowed, phrase: []const u8) []const u8 {
    const when = monthYear(a, b.last_returned orelse b.last_checkout, false);
    if (b.match == .same) {
        const verb = if (b.last_returned != null) "returned" else "borrowed";
        const w = when orelse return "Borrowed before";
        return std.fmt.allocPrint(a, "Borrowed before · {s} {s}", .{ verb, w }) catch "Borrowed before";
    }
    const what = std.fmt.allocPrint(a, "Borrowed {s}", .{phrase}) catch "Borrowed before";
    const w = when orelse return what;
    return std.fmt.allocPrint(a, "{s} · {s}", .{ what, w }) catch what;
}

/// For item detail: "You borrowed this in March 2024 · 3 times", or "You borrowed on DVD in
/// March 2024".
fn borrowedSentence(a: std.mem.Allocator, b: biblio.borrowed.Borrowed, phrase: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.print(a, "You borrowed {s}", .{if (b.match == .same) "this" else phrase}) catch {};
    if (monthYear(a, b.last_checkout orelse b.last_returned, true)) |when| out.print(a, " in {s}", .{when}) catch {};
    if (b.count > 1) out.print(a, " · {d} times", .{b.count}) catch {};
    return out.items;
}

/// "March 2024" (or "Mar 2024") from a date starting "2024-03".
fn monthYear(a: std.mem.Allocator, date: ?[*:0]const u8, full: bool) ?[]const u8 {
    const d = std.mem.span(date orelse return null);
    if (d.len < 7 or d[4] != '-' or std.mem.indexOfNone(u8, d[0..4], "0123456789") != null) return null;
    const m = std.fmt.parseInt(u8, d[5..7], 10) catch return null;
    if (m < 1 or m > 12) return null;
    const months = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
    const name = if (full) months[m - 1] else months[m - 1][0..3];
    return std.fmt.allocPrint(a, "{s} {s}", .{ name, d[0..4] }) catch null;
}

/// "1,200"
fn grouped(a: std.mem.Allocator, n: i64) []const u8 {
    const digits = std.fmt.allocPrint(a, "{d}", .{@abs(n)}) catch return "";
    var out: std.ArrayList(u8) = .empty;
    if (n < 0) out.append(a, '-') catch {};
    for (digits, 0..) |c, i| {
        if (i > 0 and (digits.len - i) % 3 == 0) out.append(a, ',') catch {};
        out.append(a, c) catch {};
    }
    return out.items;
}

test {
    _ = term;
}

test "Prompt.edit" {
    var p: Prompt = .{ .label = "", .action = .search };
    defer p.deinit();
    for ("Dne") |c| p.edit(.{ .char = c });
    p.edit(.left);
    p.edit(.left);
    p.edit(.{ .char = 'u' });
    try std.testing.expectEqualStrings("Dune", p.input.items);
    p.edit(.end);
    p.edit(.{ .char = 'é' });
    try std.testing.expectEqual(@as(usize, 6), p.cursor);
    p.edit(.left);
    try std.testing.expectEqual(@as(usize, 4), p.cursor);
    p.edit(.delete);
    try std.testing.expectEqualStrings("Dune", p.input.items);
    p.edit(.home);
    p.edit(.delete);
    p.edit(.backspace);
    try std.testing.expectEqualStrings("une", p.input.items);
    p.edit(.right);
    p.edit(.{ .char = 21 }); // ^U
    try std.testing.expectEqualStrings("ne", p.input.items);
    try std.testing.expectEqual(@as(usize, 0), p.cursor);
    // Control characters aren't typed.
    p.edit(.{ .char = 0x1b });
    try std.testing.expectEqualStrings("ne", p.input.items);
    // Long entries aren't cut off.
    for (0..600) |_| p.edit(.{ .char = 'x' });
    try std.testing.expectEqual(@as(usize, 602), p.input.items.len);
}

test barcodeText {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Bar 1, space 1, bar 2.5 (rounded to 3), space 1: modules 1 0 1 1 1 0.
    try std.testing.expectEqualStrings("▌█▌", barcodeText(a, &.{ 1, 1, 2.5, 1 }, 0));
    // Quiet 1, bar 1, space 1, bar 1, quiet 1, padding: modules 0 1 0 1 0 0.
    try std.testing.expectEqualStrings("▐▐ ", barcodeText(a, &.{ 1, 1, 1 }, 1));
    const card = models.barcode(a, .code128, "21168012345678").?;
    try std.testing.expect(term.columns(barcodeText(a, card, 10)) <= 80);
}

test closestLanguage {
    const languages = [_][]const u8{ "en-US", "es", "fr-CA" };
    try std.testing.expectEqualStrings("en-US", closestLanguage("en-US", &languages).?);
    try std.testing.expectEqualStrings("en-US", closestLanguage("en-GB", &languages).?);
    try std.testing.expectEqualStrings("es", closestLanguage("es-MX", &languages).?);
    try std.testing.expectEqualStrings("fr-CA", closestLanguage("fr", &languages).?);
    try std.testing.expectEqual(null, closestLanguage("de-DE", &languages));
}

test "App.format cuts at a character" {
    var buf: [5]u8 = undefined;
    try std.testing.expectEqualStrings("abc", App.format(&buf, "abc{s}", .{"日本"}));
    try std.testing.expectEqualStrings("ab", App.format(&buf, "ab", .{}));
}

test borrowedSentence {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const same: biblio.borrowed.Borrowed = .{ .match = .same, .format = "BK", .count = 3, .last_checkout = "2024-03-02", .last_returned = "2024-03-20" };
    try std.testing.expectEqualStrings("You borrowed this in March 2024 · 3 times", borrowedSentence(a, same, borrowedPhrase(a, "BK", "Book")));
    try std.testing.expectEqualStrings("Borrowed before · returned Mar 2024", borrowedShort(a, same, ""));
    const dvd: biblio.borrowed.Borrowed = .{ .match = .other_format, .format = "DVD", .count = 1, .last_checkout = "2023-11-05" };
    try std.testing.expectEqualStrings("You borrowed on DVD in November 2023", borrowedSentence(a, dvd, borrowedPhrase(a, "DVD", "DVD")));
    try std.testing.expectEqualStrings("Borrowed the audiobook · Nov 2023", borrowedShort(a, dvd, borrowedPhrase(a, "AB", "Audiobook CD")));
    try std.testing.expectEqualStrings("the large print", borrowedPhrase(a, "LPRINT", "Large Print"));
    try std.testing.expectEqualStrings("as Kit", borrowedPhrase(a, "KIT", "Kit"));
    try std.testing.expectEqualStrings("1,200", grouped(a, 1200));
    try std.testing.expectEqualStrings("340", grouped(a, 340));
}

test statusLine {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const entry: models.ListEntry = .{
        .id = "S1",
        .bib = .{ .id = "S1", .title = "Dune", .status = "AVAILABLE", .heldCopies = 1, .totalCopies = 13 },
        .kind = "catalog",
        .serverIndex = 0,
    };
    try std.testing.expectEqualStrings("Available · 1 hold on 13 copies", statusLine(arena.allocator(), entry).text);
    var held = entry;
    held.hold = .{ .id = "H1", .metadataId = "S1", .status = "IN_TRANSIT", .position = 2 };
    held.accountStatus = .{ .kind = "onHold" };
    try std.testing.expectEqualStrings("In transit · #2 in line", statusLine(arena.allocator(), held).text);
    try std.testing.expectEqualStrings("2019", models.year("c2019."));
}
