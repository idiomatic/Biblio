//! The data every Biblio app shows, built from gateway JSON. Field names are the
//! camelCase keys of the JSON the C interface returns (see include/biblio.h).

const std = @import("std");
const J = @import("json.zig").J;
const prettified = @import("json.zig").prettified;
const Allocator = std.mem.Allocator;

/// A catalog record ("bib") as it appears in search results, holds, checkouts and history.
pub const Bib = struct {
    id: []const u8,
    title: []const u8,
    subtitle: ?[]const u8 = null,
    authors: []const []const u8 = &.{},
    format: []const u8 = "UNKNOWN",
    publicationDate: ?[]const u8 = null,
    edition: ?[]const u8 = null,
    callNumber: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    jacketSmall: ?[]const u8 = null,
    jacketLarge: ?[]const u8 = null,
    materialType: []const u8 = "PHYSICAL",
    holdable: bool = false,
    status: ?[]const u8 = null,
    heldCopies: i64 = 0,
    availableCopies: i64 = 0,
    totalCopies: i64 = 0,
    onOrderCopies: i64 = 0,

    /// Builds a bib from a gateway `entities.bibs[id]` value.
    pub fn parse(a: Allocator, j: J) ?Bib {
        const brief = j.get("briefInfo");
        const id = j.get("id").str(a) orelse brief.get("metadataId").str(a) orelse return null;
        const jacket = brief.get("jacket");
        const small = jacket.get("medium").str(a) orelse jacket.get("small").str(a);
        const av = j.get("availability");
        return .{
            .id = id,
            .title = brief.get("title").nonEmpty(a) orelse "Untitled",
            .subtitle = brief.get("subtitle").nonEmpty(a),
            .authors = brief.get("authors").strings(a),
            .format = brief.get("format").str(a) orelse "UNKNOWN",
            .publicationDate = brief.get("publicationDate").nonEmpty(a),
            .edition = brief.get("edition").nonEmpty(a),
            .callNumber = brief.get("callNumber").nonEmpty(a),
            .summary = brief.get("description").nonEmpty(a),
            .jacketSmall = small,
            .jacketLarge = jacket.get("large").str(a) orelse small,
            .materialType = j.path("policy.materialType").str(a) orelse av.get("bibType").str(a) orelse "PHYSICAL",
            .holdable = j.path("policy.holdable").boolean() orelse true,
            .status = av.get("status").str(a),
            .heldCopies = av.get("heldCopies").int() orelse 0,
            .availableCopies = av.get("availableCopies").int() orelse 0,
            .totalCopies = av.get("totalCopies").int() orelse 0,
            .onOrderCopies = av.get("onOrderCopies").int() orelse 0,
        };
    }

    /// Minimal bib for entries whose catalog record was not returned (e.g. old history rows).
    pub fn placeholder(id: []const u8, title: []const u8) Bib {
        return .{ .id = id, .title = title };
    }
};

pub const Hold = struct {
    id: []const u8,
    metadataId: []const u8,
    status: []const u8,
    position: ?i64 = null,
    pickupLocation: ?[]const u8 = null,
    expiryDate: ?[]const u8 = null,
    pickupByDate: ?[]const u8 = null,
    suspendEndDate: ?[]const u8 = null,
    canCancel: bool = false,

    pub fn parse(a: Allocator, j: J) ?Hold {
        const id = j.get("holdsId").str(a) orelse j.get("id").str(a) orelse return null;
        const metadata = j.get("metadataId").str(a) orelse return null;
        const p = j.get("holdsPosition").int();
        var can_cancel = false;
        for (j.get("actions").strings(a)) |s| {
            if (std.mem.eql(u8, s, "cancel")) can_cancel = true;
        }
        return .{
            .id = id,
            .metadataId = metadata,
            .status = j.get("status").str(a) orelse "",
            .position = if (p != null and p.? > 0) p else null,
            .pickupLocation = j.path("pickupLocation.name").nonEmpty(a),
            .expiryDate = j.get("expiryDate").nonEmpty(a),
            .pickupByDate = j.get("pickupByDate").nonEmpty(a),
            .suspendEndDate = j.get("suspendEndDate").nonEmpty(a),
            .canCancel = can_cancel,
        };
    }

    pub fn isReady(self: Hold) bool {
        return std.mem.eql(u8, self.status, "READY_FOR_PICKUP");
    }
};

pub const Checkout = struct {
    id: []const u8,
    metadataId: []const u8,
    status: ?[]const u8 = null,
    dueDate: ?[]const u8 = null,
    checkoutDate: ?[]const u8 = null,
    timesRenewed: ?i64 = null,

    pub fn parse(a: Allocator, j: J) ?Checkout {
        const id = j.get("checkoutId").str(a) orelse j.get("id").str(a) orelse return null;
        const metadata = j.get("metadataId").str(a) orelse return null;
        return .{
            .id = id,
            .metadataId = metadata,
            .status = j.get("status").nonEmpty(a),
            .dueDate = j.get("dueDate").nonEmpty(a),
            .checkoutDate = j.get("checkoutDate").nonEmpty(a) orelse j.get("checkedOutDate").nonEmpty(a),
            .timesRenewed = j.get("timesRenewed").int() orelse j.get("renewals").int(),
        };
    }
};

pub const HistoryEntry = struct {
    id: []const u8,
    metadataId: []const u8,
    checkoutDate: ?[]const u8 = null,
    returnedDate: ?[]const u8 = null,

    pub fn parse(a: Allocator, j: J, fallback_id: []const u8) ?HistoryEntry {
        const metadata = j.get("metadataId").str(a) orelse j.get("bibId").str(a) orelse return null;
        return .{
            .id = j.get("borrowingHistoryId").str(a) orelse j.get("id").str(a) orelse fallback_id,
            .metadataId = metadata,
            .checkoutDate = j.get("checkedoutDate").nonEmpty(a) orelse j.get("checkoutDate").nonEmpty(a) orelse
                j.get("checkedOutDate").nonEmpty(a),
            .returnedDate = j.get("returnedDate").nonEmpty(a) orelse j.get("dateReturned").nonEmpty(a),
        };
    }
};

/// The signed-in account's current relationship to a catalog item.
pub const AccountStatus = struct {
    /// "onHold" or "checkedOut".
    kind: []const u8,
    ready: bool = false,
    position: ?i64 = null,
    due: ?[]const u8 = null,
};

/// One row in any item list. Exactly one of `hold`, `checkout` and `history` is set for
/// account lists; catalog rows set none and may carry the account's status for the item.
pub const ListEntry = struct {
    id: []const u8,
    bib: Bib,
    /// "catalog", "hold", "checkout" or "history".
    kind: []const u8,
    /// Position the server returned this row in, used to keep client sorts stable.
    serverIndex: i64,
    hold: ?Hold = null,
    checkout: ?Checkout = null,
    history: ?HistoryEntry = null,
    accountStatus: ?AccountStatus = null,
};

pub const FacetValue = struct { value: []const u8, count: i64 };
pub const Facet = struct { id: []const u8, values: []const FacetValue };

/// One page of any list.
pub const ListPage = struct {
    entries: []const ListEntry,
    page: i64,
    pages: i64,
    count: i64,
    /// Items per page as reported by the server (25 on the sites seen so far).
    pageSize: i64 = 25,
    facets: []const Facet = &.{},
    sortOptions: []const []const u8 = &.{},
    appliedSort: ?[]const u8 = null,
};

/// "Availability by location" row.
pub const CopyAvailability = struct {
    id: []const u8,
    branch: []const u8,
    status: []const u8,
    isAvailable: bool,
    collection: ?[]const u8 = null,
    callNumber: ?[]const u8 = null,
    dueDate: ?[]const u8 = null,
    /// Ordered but not yet received (worded "On-Order", "In-Process", "5 on order", …).
    isOnOrder: bool = false,
    /// The status grouped from the library's own wording, for its symbol and color:
    /// available, onOrder, out, held, transit, repair, missing, withdrawn, claimsReturned,
    /// libraryUseOnly or other.
    kind: []const u8 = "other",
};

pub fn copyKind(a: Allocator, c: CopyAvailability) []const u8 {
    if (c.isAvailable) return "available";
    if (c.isOnOrder) return "onOrder";
    const s = std.ascii.allocLowerString(a, c.status) catch c.status;
    const has = struct {
        fn f(text: []const u8, words: []const []const u8) bool {
            for (words) |w| if (std.mem.find(u8, text, w) != null) return true;
            return false;
        }
    }.f;
    // Order matters: "Claims Returned" before "returned", "Lost" before "out".
    if (has(s, &.{ "transit", "transfer" })) return "transit";
    if (has(s, &.{ "process", "cataloging", "order" })) return "onOrder";
    if (has(s, &.{ "repair", "damage", "mend", "bindery" })) return "repair";
    if (has(s, &.{"claim"})) return "claimsReturned";
    if (has(s, &.{ "missing", "lost", "trace" })) return "missing";
    if (has(s, &.{ "withdrawn", "discard" })) return "withdrawn";
    if (has(s, &.{ "held", "hold" })) return "held";
    if (has(s, &.{ "library use", "in library", "reference", "non-circ", "noncirc", "not for loan" })) return "libraryUseOnly";
    if (std.mem.eql(u8, s, "out") or has(s, &.{ "checked out", "due", "overdue" }) or c.dueDate != null) return "out";
    return "other";
}

/// Codabar, the symbology most North American library cards use: element widths in narrow
/// units (bar, space, bar, …) for `value` wrapped in A…A guards unless it has its own, with a
/// narrow gap between characters. Null if `value` has characters Codabar can't encode.
pub fn codabar(a: Allocator, value: []const u8) ?[]const f64 {
    const patterns = std.StaticStringMap([]const u8).initComptime(.{
        .{ "0", "0000011" }, .{ "1", "0000110" }, .{ "2", "0001001" }, .{ "3", "1100000" }, .{ "4", "0010010" },
        .{ "5", "1000010" }, .{ "6", "0100001" }, .{ "7", "0100100" }, .{ "8", "0110000" }, .{ "9", "1001000" },
        .{ "-", "0001100" }, .{ "$", "0011000" }, .{ ":", "1000101" }, .{ "/", "1010001" }, .{ ".", "1010100" },
        .{ "+", "0010101" }, .{ "A", "0011010" }, .{ "B", "0101001" }, .{ "C", "0001011" }, .{ "D", "0001110" },
    });
    const body = std.ascii.allocUpperString(a, value) catch return null;
    const guard = struct {
        fn f(ch: u8) bool {
            return ch >= 'A' and ch <= 'D';
        }
    }.f;
    const has_guards = body.len >= 2 and guard(body[0]) and guard(body[body.len - 1]);
    const text = if (has_guards) body else std.fmt.allocPrint(a, "A{s}A", .{body}) catch return null;
    var out: std.ArrayList(f64) = .empty;
    for (text, 0..) |ch, i| {
        const p = patterns.get(&.{ch}) orelse return null;
        if (i > 0) out.append(a, 1) catch return null; // inter-character gap (a space)
        for (p) |e| out.append(a, if (e == '1') 2.5 else 1) catch return null;
    }
    return out.items;
}

/// A labelled detail field from the full catalog record.
pub const DetailField = struct { label: []const u8, values: []const []const u8 };

pub const Location = struct { id: []const u8, name: []const u8 };

/// The signed-in patron.
pub const Patron = struct {
    userId: i64,
    accountId: i64,
    name: []const u8,
    email: ?[]const u8 = null,
    language: []const u8,
    barcode: ?[]const u8 = null,
    preferredPickup: ?[]const u8 = null,
    /// Whether the library keeps this account's borrowing history; null if it didn't say.
    borrowingHistoryEnabled: ?bool = null,

    /// Copies into `gpa` so the patron outlives the request that produced it.
    pub fn clone(self: Patron, gpa: Allocator) !Patron {
        var out = self;
        out.name = try gpa.dupe(u8, self.name);
        out.email = if (self.email) |s| try gpa.dupe(u8, s) else null;
        out.language = try gpa.dupe(u8, self.language);
        out.barcode = if (self.barcode) |s| try gpa.dupe(u8, s) else null;
        out.preferredPickup = if (self.preferredPickup) |s| try gpa.dupe(u8, s) else null;
        return out;
    }

    pub fn free(self: Patron, gpa: Allocator) void {
        gpa.free(self.name);
        if (self.email) |s| gpa.free(s);
        gpa.free(self.language);
        if (self.barcode) |s| gpa.free(s);
        if (self.preferredPickup) |s| gpa.free(s);
    }
};

/// A library the user has added, with branding and labels read from its catalog page.
pub const LibraryInfo = struct {
    subdomain: []const u8,
    name: []const u8,
    shortName: ?[]const u8 = null,
    primaryColor: ?[]const u8 = null,
    /// The library's own website, where its icon comes from.
    website: ?[]const u8 = null,
    /// Selected localized strings (FORMAT.*, AUDIENCE.*, LANGUAGE.*, sort.*) keyed as on the site.
    labels: std.json.ArrayHashMap([]const u8),
    languages: []const []const u8,
    users: []const []const u8 = &.{},
};

// MARK: Parsing gateway responses

/// Account status by metadata id, from the `entities.holds` / `entities.checkouts` that
/// authenticated catalog responses include. Checkouts win over holds.
pub const AccountIndex = struct {
    statuses: std.StringHashMapUnmanaged(AccountStatus) = .empty,
    holds: std.StringHashMapUnmanaged(Hold) = .empty,

    pub fn build(a: Allocator, entities: J) AccountIndex {
        var out: AccountIndex = .{};
        if (entities.get("holds").object()) |o| {
            for (o.values()) |v| {
                const hold = Hold.parse(a, J.of(v)) orelse continue;
                out.statuses.put(a, hold.metadataId, .{ .kind = "onHold", .ready = hold.isReady(), .position = hold.position }) catch {};
                out.holds.put(a, hold.metadataId, hold) catch {};
            }
        }
        if (entities.get("checkouts").object()) |o| {
            for (o.values()) |v| {
                const c = Checkout.parse(a, J.of(v)) orelse continue;
                out.statuses.put(a, c.metadataId, .{ .kind = "checkedOut", .due = c.dueDate }) catch {};
            }
        }
        return out;
    }
};

pub fn searchPage(a: Allocator, json: J, page: i64) ListPage {
    const search = json.get("catalogSearch");
    const bibs = json.path("entities.bibs");
    var index = AccountIndex.build(a, json.get("entities"));
    var entries: std.ArrayList(ListEntry) = .empty;
    for (search.get("results").items(), 0..) |r_value, i| {
        const r = J.of(r_value);
        const id = r.get("representative").str(a) orelse continue;
        const bib = Bib.parse(a, bibs.get(id)) orelse continue;
        var entry: ListEntry = .{ .id = id, .bib = bib, .kind = "catalog", .serverIndex = (page - 1) * 25 + @as(i64, @intCast(i)) };
        // A title can group several editions; any of them held or checked out counts.
        var ids: std.ArrayList([]const u8) = .empty;
        ids.append(a, id) catch {};
        ids.appendSlice(a, r.get("manifestations").strings(a)) catch {};
        for (ids.items) |m| {
            if (entry.accountStatus == null) entry.accountStatus = index.statuses.get(m);
            if (entry.hold == null) entry.hold = index.holds.get(m);
        }
        entries.append(a, entry) catch {};
    }
    var facets: std.ArrayList(Facet) = .empty;
    for (search.get("fields").items()) |f_value| {
        const f = J.of(f_value);
        var values: std.ArrayList(FacetValue) = .empty;
        for (f.get("fieldFilters").items()) |v_value| {
            const v = J.of(v_value);
            const value = v.get("value").str(a) orelse continue;
            values.append(a, .{ .value = value, .count = v.get("count").int() orelse 0 }) catch {};
        }
        facets.append(a, .{ .id = f.get("id").str(a) orelse "", .values = values.items }) catch {};
    }
    var sorts: std.ArrayList([]const u8) = .empty;
    var applied: ?[]const u8 = null;
    for (search.get("sortBys").items()) |s_value| {
        const s = J.of(s_value);
        const id = s.get("id").str(a) orelse continue;
        sorts.append(a, id) catch {};
        if (applied == null and s.get("applied").boolean() == true) applied = id;
    }
    return .{
        .entries = entries.items,
        .page = search.path("pagination.page").int() orelse page,
        .pages = search.path("pagination.pages").int() orelse page,
        .count = search.path("pagination.count").int() orelse @intCast(entries.items.len),
        .pageSize = search.path("pagination.limit").int() orelse 25,
        .facets = facets.items,
        .sortOptions = sorts.items,
        .appliedSort = applied,
    };
}

pub const BorrowingKind = enum { holds, checkouts, history };

/// Shared parsing for the borrowing endpoints, which all return
/// `borrowing.<list>.{items, pagination, sortOptions}` plus `entities.<kind>` and `entities.bibs`.
pub fn borrowingPage(a: Allocator, json: J, kind: BorrowingKind, page: i64) ListPage {
    const list_keys: []const []const u8 = switch (kind) {
        .holds => &.{"holds"},
        .checkouts => &.{ "checkouts", "checkedout", "checkedOut" },
        .history => &.{ "borrowingHistory", "borrowinghistory" },
    };
    const entity_key = switch (kind) {
        .holds => "holds",
        .checkouts => "checkouts",
        .history => "borrowingHistory",
    };
    const borrowing = json.get("borrowing");
    var list = J.null_;
    for (list_keys) |k| {
        if (!borrowing.get(k).isNull()) {
            list = borrowing.get(k);
            break;
        }
    }
    if (list.isNull()) {
        if (borrowing.object()) |o| {
            for (o.values()) |v| {
                if (!J.of(v).get("items").isNull()) {
                    list = J.of(v);
                    break;
                }
            }
        }
    }
    const entities = json.get("entities").get(entity_key);
    const bibs = json.path("entities.bibs");

    var ids = list.get("items").strings(a);
    if (ids.len == 0) ids = list.get("results").strings(a);
    if (ids.len == 0) {
        var from_results: std.ArrayList([]const u8) = .empty;
        for (list.get("results").items()) |r| {
            if (J.of(r).get("id").str(a)) |s| from_results.append(a, s) catch {};
        }
        ids = from_results.items;
    }
    if (ids.len == 0) {
        if (entities.object()) |o| {
            const keys: [][]const u8 = a.dupe([]const u8, o.keys()) catch &.{};
            std.mem.sort([]const u8, keys, {}, lessString);
            ids = keys;
        }
    }

    var entries: std.ArrayList(ListEntry) = .empty;
    for (ids, 0..) |id, i| {
        const e = entities.get(id);
        if (e.isNull()) continue;
        const index = (page - 1) * 25 + @as(i64, @intCast(i));
        const bib_from_entities: ?Bib = if (e.get("metadataId").str(a)) |m| Bib.parse(a, bibs.get(m)) else null;
        const untitled = e.get("bibTitle").str(a) orelse "Untitled";
        switch (kind) {
            .holds => {
                const h = Hold.parse(a, e) orelse continue;
                entries.append(a, .{
                    .id = std.fmt.allocPrint(a, "hold-{s}", .{h.id}) catch continue,
                    .bib = bib_from_entities orelse Bib.placeholder(h.metadataId, untitled),
                    .kind = "hold",
                    .serverIndex = index,
                    .hold = h,
                    .accountStatus = .{ .kind = "onHold", .ready = h.isReady(), .position = h.position },
                }) catch {};
            },
            .checkouts => {
                const c = Checkout.parse(a, e) orelse continue;
                entries.append(a, .{
                    .id = std.fmt.allocPrint(a, "co-{s}", .{c.id}) catch continue,
                    .bib = bib_from_entities orelse Bib.placeholder(c.metadataId, untitled),
                    .kind = "checkout",
                    .serverIndex = index,
                    .checkout = c,
                    .accountStatus = .{ .kind = "checkedOut", .due = c.dueDate },
                }) catch {};
            },
            .history => {
                const fallback = std.fmt.allocPrint(a, "{d}-{d}", .{ page, i }) catch continue;
                const h = HistoryEntry.parse(a, e, fallback) orelse continue;
                entries.append(a, .{
                    .id = std.fmt.allocPrint(a, "bh-{s}", .{h.id}) catch continue,
                    .bib = bib_from_entities orelse Bib.placeholder(h.metadataId, untitled),
                    .kind = "history",
                    .serverIndex = index,
                    .history = h,
                }) catch {};
            },
        }
    }

    var sorts: std.ArrayList([]const u8) = .empty;
    var applied: ?[]const u8 = null;
    for (list.get("sortOptions").items()) |s_value| {
        const s = J.of(s_value);
        const id = s.get("id").str(a) orelse s.str(a) orelse continue;
        sorts.append(a, id) catch {};
        if (applied == null and s.get("applied").boolean() == true) applied = id;
    }
    return .{
        .entries = entries.items,
        .page = list.path("pagination.page").int() orelse page,
        .pages = list.path("pagination.pages").int() orelse page,
        .count = list.path("pagination.count").int() orelse @intCast(entries.items.len),
        .pageSize = list.path("pagination.limit").int() orelse 25,
        .sortOptions = sorts.items,
        .appliedSort = applied,
    };
}

pub fn availability(a: Allocator, json: J) []const CopyAvailability {
    const items_j = json.path("entities.bibItems");
    var ids = json.path("availability.items").strings(a);
    if (ids.len == 0) {
        if (items_j.object()) |o| {
            const keys: [][]const u8 = a.dupe([]const u8, o.keys()) catch &.{};
            std.mem.sort([]const u8, keys, {}, lessString);
            ids = keys;
        }
    }
    var out: std.ArrayList(CopyAvailability) = .empty;
    for (ids) |id| {
        const i = items_j.get(id);
        if (i.isNull()) continue;
        const av = i.get("availability");
        const library_status = av.get("libraryStatus").str(a) orelse "";
        out.append(a, .{
            .id = id,
            .branch = i.get("branchName").nonEmpty(a) orelse i.path("branch.name").nonEmpty(a) orelse "—",
            .status = av.get("libraryStatus").nonEmpty(a) orelse
                (if (av.get("status").str(a)) |s| prettified(a, s) else ""),
            .isAvailable = av.get("statusType").eqlStr("AVAILABLE") or av.get("group").eqlStr("AVAILABLE_ITEMS"),
            .collection = i.get("collection").nonEmpty(a),
            .callNumber = i.get("callNumber").nonEmpty(a),
            .dueDate = i.get("dueDate").nonEmpty(a),
            .isOnOrder = av.get("status").eqlStr("ON_ORDER") or av.get("statusType").eqlStr("ON_ORDER") or
                mentionsOnOrder(library_status),
        }) catch {};
    }
    for (out.items) |*c| c.kind = copyKind(a, c.*);
    std.mem.sort(CopyAvailability, out.items, {}, struct {
        fn less(_: void, x: CopyAvailability, y: CopyAvailability) bool {
            if (x.isAvailable != y.isAvailable) return x.isAvailable;
            return std.mem.order(u8, x.branch, y.branch) == .lt;
        }
    }.less);
    return out.items;
}

/// Matches /on.order/i, as in "On-Order", "On order", "5 on order".
fn mentionsOnOrder(s: []const u8) bool {
    var i: usize = 0;
    while (i + 8 <= s.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(s[i .. i + 2], "on") and std.ascii.eqlIgnoreCase(s[i + 3 .. i + 8], "order")) return true;
    }
    return false;
}

/// Full record fields ("Details", "About", …). Opinion/UGC sections are never requested.
pub fn detailFields(a: Allocator, json: J, metadata_id: []const u8) []const DetailField {
    const record = json.path("entities.catalogBibs").get(metadata_id);
    var out: std.ArrayList(DetailField) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (record.get("fields").items()) |category| {
        for (J.of(category).get("items").items()) |item_v| {
            const item = J.of(item_v);
            const name = item.get("fieldName").str(a) orelse continue;
            // The summary is already shown from the brief record; the title is the header.
            if (std.mem.eql(u8, name, "TITLE") or std.mem.eql(u8, name, "SUMMARY")) continue;
            var values: std.ArrayList([]const u8) = .empty;
            for (item.get("fieldValues").items()) |fv| {
                for (J.of(fv).path("primary.values").strings(a)) |v| {
                    if (!containsString(values.items, v)) values.append(a, v) catch {};
                }
            }
            if (values.items.len == 0) continue;
            const label = prettified(a, name);
            var key: std.ArrayList(u8) = .empty;
            key.appendSlice(a, label) catch {};
            for (values.items) |v| key.appendSlice(a, v) catch {};
            const gop = seen.getOrPut(a, key.items) catch continue;
            if (gop.found_existing) continue;
            out.append(a, .{ .label = label, .values = values.items }) catch {};
        }
    }
    return out.items;
}

pub fn locations(a: Allocator, json: J) []const Location {
    var out: std.ArrayList(Location) = .empty;
    if (json.path("entities.locations").object()) |o| {
        for (o.values()) |v| {
            const l = J.of(v);
            const id = l.get("id").str(a) orelse continue;
            const name = l.get("name").str(a) orelse continue;
            if (l.get("isHidden").boolean() == true) continue;
            out.append(a, .{ .id = id, .name = name }) catch {};
        }
    }
    std.mem.sort(Location, out.items, {}, struct {
        fn less(_: void, x: Location, y: Location) bool {
            return std.mem.order(u8, x.name, y.name) == .lt;
        }
    }.less);
    return out.items;
}

/// The error message a gateway response carries, if any.
pub fn message(a: Allocator, json: J) ?[]const u8 {
    return json.path("error.message").nonEmpty(a) orelse
        json.get("message").nonEmpty(a) orelse
        json.get("errors").at(0).get("message").nonEmpty(a) orelse
        json.get("failures").at(0).get("message").nonEmpty(a);
}

fn containsString(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

pub fn lessString(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

test "copy kinds and codabar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base: CopyAvailability = .{ .id = "1", .branch = "B", .status = "", .isAvailable = false };
    var c = base;
    c.status = "In Transit";
    try std.testing.expectEqualStrings("transit", copyKind(a, c));
    c.status = "Claims Returned";
    try std.testing.expectEqualStrings("claimsReturned", copyKind(a, c));
    c.status = "Checked out";
    try std.testing.expectEqualStrings("out", copyKind(a, c));
    const e = codabar(a, "12").?;
    try std.testing.expectEqual(@as(usize, 4 * 7 + 3), e.len);
    try std.testing.expect(codabar(a, "12#") == null);
}

test "on order wording" {
    try std.testing.expect(mentionsOnOrder("On-Order"));
    try std.testing.expect(mentionsOnOrder("5 on order"));
    try std.testing.expect(!mentionsOnOrder("Checked out"));
}
