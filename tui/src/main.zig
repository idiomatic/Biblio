//! Biblio in the terminal: the libraries you've added, then one account's catalog search, new
//! titles, holds, checkouts, borrowing history and account details, with item details,
//! availability by location, and placing and cancelling holds. Runs in any xterm-256color
//! terminal; needs nothing beyond libbiblio and libc.
//!
//! Core calls block, so each is preceded by a "Loading…" frame. Keep requests few: each
//! screen loads once, and lists load a page at a time.

const std = @import("std");
const biblio = @import("biblio");
const models = biblio.models;
const library = biblio.library;
const term = @import("term.zig");
const Store = @import("store.zig").Store;
const Key = term.Key;
const Frame = term.Frame;

const gpa = std.heap.c_allocator;

const color = struct {
    const dim: term.Color = 245;
    const selected: term.Color = 237;
    const failure: term.Color = 203;
    const success: term.Color = 114;
    const brand: term.Color = 24;
    const white: term.Color = 231;

    /// Matches the other apps' copy-status colors; the words always appear too.
    fn kind(k: []const u8) term.Color {
        const map = std.StaticStringMap(term.Color).initComptime(.{
            .{ "available", 114 },      .{ "onOrder", 75 },         .{ "out", 214 },     .{ "held", 141 },
            .{ "transit", 141 },        .{ "repair", 203 },         .{ "missing", 203 }, .{ "withdrawn", 245 },
            .{ "claimsReturned", 203 }, .{ "libraryUseOnly", 180 },
        });
        return map.get(k) orelse dim;
    }
};

pub fn main(init: std.process.Init) !void {
    var t = try term.Terminal.init(init.io);
    defer t.deinit();
    var app: App = .{ .term = &t, .store = Store.load(init.io, gpa, init.environ_map), .language = language(init.environ_map) };
    app.run();
}

/// "en-US" from LANG=en_US.UTF-8, for catalog text until a sign-in reports the account's own.
fn language(env: *const std.process.Environ.Map) ?[]const u8 {
    const lang = env.get("LC_ALL") orelse env.get("LANG") orelse return null;
    const code = lang[0 .. std.mem.indexOfAny(u8, lang, ".@") orelse lang.len];
    if (code.len < 2 or std.mem.eql(u8, code, "C") or std.mem.eql(u8, code, "POSIX")) return null;
    const out = gpa.dupe(u8, code) catch return null;
    std.mem.replaceScalar(u8, out, '_', '-');
    return out;
}

// MARK: App

const Prompt = struct {
    label: []const u8,
    input: std.ArrayList(u8) = .empty,
    secret: bool = false,
    action: enum { add_library, add_user_name, add_user_password, sign_in_password, search },

    fn deinit(p: *Prompt) void {
        if (p.secret) std.crypto.secureZero(u8, p.input.items);
        p.input.deinit(gpa);
    }
};

const Confirm = struct {
    action: enum { place_hold, cancel_hold, remove_user, remove_library },
};

/// A row on the libraries screen: one of a library's users, or its guest row.
const Row = struct { library: usize, user: ?[]const u8 };

const App = struct {
    term: *term.Terminal,
    store: Store,
    language: ?[]const u8,
    cursor: usize = 0,
    session: ?*Session = null,
    prompt: ?Prompt = null,
    confirm: ?Confirm = null,
    question_buf: [512]u8 = undefined,
    question: []const u8 = "",
    message_buf: [512]u8 = undefined,
    message: []const u8 = "",
    message_is_error: bool = false,
    /// The library and username an Add User or sign-in prompt is for.
    pending_library: usize = 0,
    pending_user_buf: [256]u8 = undefined,
    pending_user: []const u8 = "",
    quit: bool = false,

    fn run(app: *App) void {
        var last = app.term.size();
        app.draw();
        while (!app.quit) {
            const key = app.term.readKey(250) orelse {
                const now = app.term.size();
                if (now.rows != last.rows or now.cols != last.cols) {
                    last = now;
                    app.draw();
                }
                continue;
            };
            app.handle(key);
            if (!app.quit) app.draw();
        }
        if (app.session) |s| s.close();
    }

    fn say(app: *App, comptime fmt: []const u8, args: anytype) void {
        app.message = std.fmt.bufPrint(&app.message_buf, fmt, args) catch "";
        app.message_is_error = false;
    }

    fn fail(app: *App, comptime fmt: []const u8, args: anytype) void {
        app.say(fmt, args);
        app.message_is_error = true;
    }

    fn ask(app: *App, action: @FieldType(Confirm, "action"), comptime fmt: []const u8, args: anytype) void {
        app.question = std.fmt.bufPrint(&app.question_buf, fmt, args) catch "";
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
            },
            .backspace => {
                var i = p.input.items.len;
                while (i > 0) {
                    i -= 1;
                    if (p.input.items[i] & 0xc0 != 0x80) break;
                }
                p.input.shrinkRetainingCapacity(i);
            },
            .char => |c| if (c >= 0x20) {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c, &buf) catch return;
                p.input.appendSlice(gpa, buf[0..n]) catch {};
            },
            .enter => {
                var done = app.prompt.?;
                app.prompt = null;
                defer done.deinit();
                app.submitted(done.action, std.mem.trim(u8, done.input.items, " "));
            },
            else => {},
        }
    }

    fn submitted(app: *App, action: @FieldType(Prompt, "action"), input: []const u8) void {
        switch (action) {
            .add_library => app.addLibrary(input),
            .add_user_name => {
                if (input.len == 0) return;
                app.pending_user = std.fmt.bufPrint(&app.pending_user_buf, "{s}", .{input}) catch return;
                app.startPrompt(.{ .label = "PIN or password", .secret = true, .action = .add_user_password });
            },
            .add_user_password => if (input.len > 0) {
                if (app.open(app.pending_library, app.pending_user, input, true)) app.store.addUser(app.pending_library, app.pending_user);
            },
            .sign_in_password => if (input.len > 0) {
                _ = app.open(app.pending_library, app.pending_user, input, false);
            },
            .search => if (app.session) |s| s.search(input),
        }
    }

    fn confirmed(app: *App, c: Confirm) void {
        switch (c.action) {
            .place_hold => if (app.session) |s| s.placeHold(),
            .cancel_hold => if (app.session) |s| s.cancelHold(),
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
                    app.pending_user = std.fmt.bufPrint(&app.pending_user_buf, "{s}", .{u}) catch return;
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
        const s = Session.create(app, lib, username, password) orelse return false;
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
            if (p.secret) {
                for (0..term.columns(p.input.items)) |_| used += f.text("•", width -| used, false);
            } else {
                // Show the end of a long entry.
                const cols = term.columns(p.input.items);
                const room = width -| used -| 1;
                var start: usize = 0;
                var skip = cols -| room;
                while (skip > 0 and start < p.input.items.len) : (skip -= 1) start += std.unicode.utf8ByteSequenceLength(p.input.items[start]) catch 1;
                used += f.text(p.input.items[start..], room, false);
            }
            f.style(.{ .reverse = true });
            f.raw(" ");
            f.style(.{});
        } else if (app.confirm != null) {
            f.style(.{ .bold = true });
            const used = f.text(app.question, width -| 6, false);
            _ = f.text(" (y/n)", width -| used, false);
        } else if (app.message.len > 0) {
            f.style(.{ .fg = if (app.message_is_error) color.failure else null });
            _ = f.text(app.message, width, false);
        } else {
            f.style(.{ .fg = color.dim });
            const hints = if (app.session) |s| s.hints() else "↑↓ move  Enter open  a add library  u add user  d remove  q quit";
            _ = f.text(hints, width, false);
        }
        f.style(.{});
    }
};

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
};

/// One page-at-a-time list of entries.
const List = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(models.ListEntry) = .empty,
    loaded: bool = false,
    page: i64 = 0,
    pages: i64 = 0,
    count: i64 = 0,
    sort_options: []const []const u8 = &.{},
    applied_sort: ?[]const u8 = null,
    sort_buf: [64]u8 = undefined,
    sort: ?[]const u8 = null,
    query_buf: [256]u8 = undefined,
    query: []const u8 = "",
    cursor: usize = 0,
    top: usize = 0,

    fn reset(l: *List) void {
        _ = l.arena.reset(.retain_capacity);
        l.entries = .empty;
        l.loaded = false;
        l.page = 0;
        l.pages = 0;
        l.count = 0;
        l.sort_options = &.{};
        l.applied_sort = null;
        l.cursor = 0;
        l.top = 0;
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

    fn create(app: *App, lib: usize, username: []const u8, password: ?[]const u8) ?*Session {
        const s = gpa.create(Session) catch return null;
        const info = app.store.libraries.items[lib];
        s.* = .{
            .app = app,
            .info = info,
            .username = gpa.dupe(u8, username) catch return null,
            .password = if (password) |p| gpa.dupe(u8, p) catch return null else null,
            .core = undefined,
            .arena = .init(gpa),
            .lists = undefined,
        };
        for (&s.lists) |*l| l.* = .{ .arena = .init(gpa) };
        const a = s.arena.allocator();
        const sub = a.dupeSentinel(u8, info.subdomain, 0) catch return null;
        const user = a.dupeSentinel(u8, username, 0) catch return null;
        s.core = biblio.biblio_client_new(sub.ptr, user.ptr, passwordFor, s) orelse return null;
        if (app.language) |l| s.core.client.setLanguage(l);
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
        biblio.biblio_client_free(s.core);
        if (s.password) |p| {
            std.crypto.secureZero(u8, p);
            gpa.free(p);
        }
        gpa.free(s.username);
        if (s.detail) |*d| d.arena.deinit();
        for (&s.lists) |*l| l.arena.deinit();
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
            s.load(.holds, 1);
            s.load(.checkouts, 1);
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

    fn load(s: *Session, tab: Tab, page: i64) void {
        const app = s.app;
        const l = s.list(tab);
        const a = l.arena.allocator();
        app.busy(if (page > 1) "Loading more…" else "Loading…");
        var failure: biblio.Failure = undefined;
        const result = switch (tab) {
            .search => s.client().search(a, .{ .query = l.query, .page = page, .sort = l.sort }, &failure),
            .new_titles => blk: {
                var filters: std.json.ArrayHashMap([]const u8) = .{};
                filters.map.put(a, "f_on_order", "false") catch {};
                break :blk s.client().search(a, .{
                    .query = "nw:[0 TO 180]",
                    .searchType = "bl",
                    .filters = filters,
                    .page = page,
                    .sort = l.sort orelse "newly_acquired",
                }, &failure);
            },
            .holds => s.client().borrowing(a, .holds, page, l.sort, &failure),
            .checkouts => s.client().borrowing(a, .checkouts, page, l.sort, &failure),
            .history => s.client().borrowing(a, .history, page, l.sort, &failure),
            .account => unreachable,
        } catch return app.fail("{s}", .{failure.message});
        l.entries.appendSlice(a, result.entries) catch {};
        l.loaded = true;
        l.page = result.page;
        l.pages = result.pages;
        l.count = result.count;
        if (page == 1) {
            l.sort_options = result.sortOptions;
            l.applied_sort = result.appliedSort;
        }
        app.message = "";
    }

    fn reload(s: *Session, tab: Tab) void {
        const l = s.list(tab);
        l.reset();
        if (tab == .search and l.query.len == 0) return;
        s.load(tab, 1);
    }

    fn search(s: *Session, query: []const u8) void {
        const l = s.list(.search);
        l.query = std.fmt.bufPrint(&l.query_buf, "{s}", .{query}) catch return;
        l.sort = null;
        s.tab = .search;
        s.reload(.search);
    }

    fn select(s: *Session, tab: Tab) void {
        s.tab = tab;
        if (tab == .account or tab == .search) return;
        if (!s.list(tab).loaded) s.load(tab, 1);
    }

    fn hints(s: *const Session) []const u8 {
        if (s.detail) |d| {
            const e = d.entry;
            if (e.hold != null and e.hold.?.canCancel) return "↑↓ scroll  c cancel hold  Esc back";
            if (!s.isGuest() and e.hold == null and e.checkout == null and e.bib.holdable) return "↑↓ scroll  h place hold  Esc back";
            return "↑↓ scroll  Esc back";
        }
        if (s.tab == .account) return "Tab section  Esc libraries  ^C quit";
        return "↑↓ move  Enter details  Tab section  / search  s sort  r reload  Esc libraries";
    }

    fn handle(s: *Session, key: Key) void {
        if (s.detail != null) return s.handleDetail(key);
        const tabs_ = s.tabs();
        const index = std.mem.indexOfScalar(Tab, tabs_, s.tab) orelse 0;
        switch (key) {
            .tab, .right => return s.select(tabs_[(index + 1) % tabs_.len]),
            .back_tab, .left => return s.select(tabs_[(index + tabs_.len - 1) % tabs_.len]),
            .escape => return s.close(),
            .char => |c| switch (c) {
                '1'...'6' => if (c - '1' < tabs_.len) return s.select(tabs_[@intCast(c - '1')]),
                'q' => return s.close(),
                '/' => {
                    var prompt: Prompt = .{ .label = "Search", .action = .search };
                    prompt.input.appendSlice(gpa, s.list(.search).query) catch {};
                    return s.app.startPrompt(prompt);
                },
                else => {},
            },
            else => {},
        }
        if (s.tab == .account) return;
        const l = s.list(s.tab);
        const n = l.entries.items.len;
        const page = s.visibleEntries();
        switch (key) {
            .up => l.cursor -|= 1,
            .down => l.cursor = @min(l.cursor + 1, n -| 1),
            .page_up => l.cursor -|= page,
            .page_down => l.cursor = @min(l.cursor + page, n -| 1),
            .home => l.cursor = 0,
            .end => l.cursor = n -| 1,
            .enter => if (n > 0) s.openDetail(l.entries.items[l.cursor]),
            .char => |c| switch (c) {
                'r' => s.reload(s.tab),
                's' => if (l.sort_options.len > 1) {
                    const current = l.sort orelse l.applied_sort orelse "";
                    var next: usize = 0;
                    for (l.sort_options, 0..) |o, i| if (std.mem.eql(u8, o, current)) {
                        next = (i + 1) % l.sort_options.len;
                    };
                    l.sort = std.fmt.bufPrint(&l.sort_buf, "{s}", .{l.sort_options[next]}) catch null;
                    s.reload(s.tab);
                },
                else => {},
            },
            else => {},
        }
        // Near the end: the next page.
        if (l.loaded and l.cursor + 1 >= n and l.page < l.pages and key != .up) s.load(s.tab, l.page + 1);
    }

    fn visibleEntries(s: *const Session) usize {
        return @max(1, (s.app.term.size().rows -| 4) / 2);
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
                'h' => if (!s.isGuest() and e.hold == null and e.checkout == null and e.bib.holdable) {
                    s.app.ask(.place_hold, "Place a hold on “{s}” for pickup at {s}?", .{ e.bib.title, s.pickupName() });
                },
                'c' => if (e.hold) |h| if (h.canCancel) {
                    s.app.ask(.cancel_hold, "Cancel your hold on “{s}”?", .{e.bib.title});
                },
                else => {},
            },
            else => {},
        }
    }

    fn pickupName(s: *const Session) []const u8 {
        const id = (s.patron orelse return "your preferred branch").preferredPickup orelse return "your preferred branch";
        for (s.locations) |loc| if (std.mem.eql(u8, loc.id, id)) return loc.name;
        return id;
    }

    fn placeHold(s: *Session) void {
        const d = s.detail orelse return;
        const bib = d.entry.bib;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var failure: biblio.Failure = undefined;
        s.app.busy("Placing hold…");
        s.client().placeHold(arena.allocator(), bib.id, bib.materialType, null, &failure) catch
            return s.app.fail("{s}", .{failure.message});
        // Show the hold on catalog rows without reloading them.
        for ([_]Tab{ .search, .new_titles }) |t| for (s.list(t).entries.items) |*entry| {
            if (std.mem.eql(u8, entry.bib.id, bib.id)) entry.accountStatus = .{ .kind = "onHold" };
        };
        // The title lives in the list the item came from, which stays loaded.
        s.closeDetail();
        s.reload(.holds);
        s.app.say("Hold placed on “{s}”.", .{bib.title});
    }

    fn cancelHold(s: *Session) void {
        const d = s.detail orelse return;
        const hold = d.entry.hold orelse return;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var failure: biblio.Failure = undefined;
        s.app.busy("Cancelling hold…");
        const refused = s.client().cancelHolds(arena.allocator(), &.{.{ .id = hold.id, .metadataId = hold.metadataId }}, &failure) catch
            return s.app.fail("{s}", .{failure.message});
        if (refused.len > 0) return s.app.fail("{s}", .{refused[0].reason});
        for ([_]Tab{ .search, .new_titles }) |t| for (s.list(t).entries.items) |*entry| {
            if (std.mem.eql(u8, entry.bib.id, d.entry.bib.id)) {
                entry.accountStatus = null;
                entry.hold = null;
            }
        };
        s.closeDetail();
        s.reload(.holds);
        s.app.say("Hold cancelled.", .{});
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
            const count = if (l) |x| if (x.loaded and (t == .holds or t == .checkouts)) std.fmt.allocPrint(f.a, " {d}", .{x.count}) catch "" else "" else "";
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
        } else if (l.loaded) {
            const sort = l.sort orelse l.applied_sort;
            const sort_name = if (sort) |id| library.sortName(f.a, .of(s.labels), id) else "";
            const what = if (s.tab == .search) std.fmt.allocPrint(f.a, "“{s}”: ", .{l.query}) catch "" else "";
            _ = f.text(std.fmt.allocPrint(f.a, " {s}{d} {s}{s}{s}", .{
                what,                                  l.count,
                if (l.count == 1) "item" else "items",
                if (sort != null) " · sorted by " else "",
                sort_name,
            }) catch "", f.size.cols, false);
        }
        f.style(.{});

        if (l.loaded and l.entries.items.len == 0) {
            f.at(4, 2);
            _ = f.text(switch (s.tab) {
                .search => "No results.",
                .new_titles => "No new titles.",
                .holds => "No holds.",
                .checkouts => "Nothing checked out.",
                else => "No borrowing history. If it's off, the library doesn't keep one.",
            }, f.size.cols -| 4, false);
            return;
        }

        const visible = s.visibleEntries();
        if (l.cursor < l.top) l.top = l.cursor;
        if (l.cursor >= l.top + visible) l.top = l.cursor + 1 - visible;
        const end = @min(l.entries.items.len, l.top + visible);
        for (l.entries.items[l.top..end], l.top..) |entry, i| {
            const selected = i == l.cursor;
            const row = 3 + (i - l.top) * 2;
            const bg: ?term.Color = if (selected) color.selected else null;
            f.at(row, 0);
            f.style(.{ .bg = bg, .bold = true });
            var w = f.text(if (selected) " ▸ " else "   ", 3, false);
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
            const st = statusLine(f.a, entry);
            if (st.text.len > 0) {
                w += f.text("  ", f.size.cols -| w, false);
                f.style(.{ .bg = bg, .fg = st.color });
                w += f.text(st.text, f.size.cols -| w, false);
            }
            f.fill(w);
            f.style(.{});
        }
    }

    /// "Blu-ray Disc · 2026"
    fn formatLine(s: *const Session, a: std.mem.Allocator, bib: models.Bib) []const u8 {
        const format = library.formatName(a, .of(s.labels), bib.format);
        const date = bib.publicationDate orelse return format;
        return std.fmt.allocPrint(a, "{s} · {s}", .{ format, year(date) }) catch format;
    }

    fn drawAccount(s: *Session, f: *Frame) void {
        const p = s.patron orelse return;
        const language_name = s.info.labels.map.get(std.fmt.allocPrint(f.a, "LANGUAGE_NAME.{s}", .{p.language}) catch "") orelse p.language;
        const rows = [_][2][]const u8{
            .{ "Name", p.name },
            .{ "Library", s.info.name },
            .{ "Card number", p.barcode orelse "—" },
            .{ "Email", p.email orelse "—" },
            .{ "Pickup location", s.pickupName() },
            .{ "Language", language_name },
            .{ "Borrowing history", if (p.borrowingHistoryEnabled) |on| if (on) "On" else "Off" else "—" },
        };
        for (rows, 0..) |r, i| {
            f.at(3 + i * 2, 2);
            f.style(.{ .fg = color.dim });
            _ = f.text(r[0], 20, true);
            f.style(.{});
            _ = f.text(r[1], f.size.cols -| 22, false);
        }
        f.at(3 + rows.len * 2 + 1, 2);
        f.style(.{ .fg = color.dim });
        _ = f.text("Change these settings in the Apple, GNOME, Android or Windows app, or on the library's website.", f.size.cols -| 4, false);
        f.style(.{});
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
        if (bib.summary) |summary| {
            lines.append(a, .{ .text = "" }) catch {};
            add(&lines, a, summary, width, .{});
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
            _ = f.text(line.text, width, false);
            f.style(.{});
        }
    }
};

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
        if (s.position orelse if (e.hold) |h| h.position else null) |p|
            return .{ .text = std.fmt.allocPrint(a, "On hold · #{d} in line", .{p}) catch "On hold", .color = 75 };
        return .{ .text = "On hold", .color = 75 };
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

/// A year from "2026", "20261006" or "03/23/2027"; otherwise the date as given.
fn year(date: []const u8) []const u8 {
    if (date.len == 4) return date;
    if (date.len == 8 and std.mem.indexOfNone(u8, date, "0123456789") == null) return date[0..4];
    var i: usize = 0;
    while (i + 4 <= date.len) : (i += 1) {
        const y = date[i .. i + 4];
        if (std.mem.indexOfNone(u8, y, "0123456789") != null) continue;
        if ((i > 0 and std.ascii.isDigit(date[i - 1])) or (i + 4 < date.len and std.ascii.isDigit(date[i + 4]))) continue;
        if (y[0] == '1' or (y[0] == '2' and y[1] == '0')) return y;
    }
    return date;
}

test {
    _ = term;
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
    try std.testing.expectEqualStrings("2027", year("03/23/2027"));
}
