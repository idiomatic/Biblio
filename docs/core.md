# libbiblio developer guide

libbiblio is the BiblioCommons client shared by every Biblio app: Apple (Swift), GNOME (Zig),
Android (Kotlin), Windows (C#) and the terminal (Zig). It is written in Zig and lives in [`core/`](../core). The
apps use it for everything that talks to a library:

- signing in, and signing in again when a session expires
- the BiblioCommons gateway API, and the library website's account-settings forms
- library lookup, and the BiblioCommons partner directory
- request pacing, cookies and redirects
- shared display logic: copy-status grouping, format and sort names, Codabar barcodes,
  readable brand colors

Every operation is a C function that takes C arguments and returns C structs, declared in
[`core/include/biblio.h`](../core/include/biblio.h). [PLATFORMS.md](../PLATFORMS.md) says how
each app binds them.

## Contents

1. [Building and linking](#building-and-linking)
2. [Concepts](#concepts)
3. [Clients, memory and transport](#clients-memory-and-transport)
4. [Calling conventions](#calling-conventions)
5. [Operations](#operations)
6. [Result types](#result-types)
7. [Writing a transport](#writing-a-transport)
8. [Using the core from Zig](#using-the-core-from-zig)
9. [Testing](#testing)
10. [Adding an operation](#adding-an-operation)

---

## Building and linking

The core needs Zig 0.17. From `core/`:

| Command | Produces |
|---|---|
| `zig build` | `zig-out/lib/libbiblio.a`, the shared library (`.dylib`, `.so` or `.dll`), `zig-out/include/biblio.h`, and the `biblio` CLI |
| `zig build test` | Runs the unit and fixture tests |
| `zig build -Dtarget=<triple> -Doptimize=safe` | The library for another platform, such as `x86_64-windows-gnu`, `aarch64-linux-android` or `aarch64-linux-gnu` (Raspberry Pi) |
| `zig build apple` | Static libraries for macOS, iOS and the iOS simulator under `zig-out/apple/` |

Each app builds the core in its own way:

| App | How the core is built and linked |
|---|---|
| Apple | [`apple/build-core.sh`](../apple/build-core.sh) packages `BiblioCore.xcframework` with a `BiblioCore` module map. Swift code calls `import BiblioCore`. |
| GNOME | [`gnome/build.zig`](../gnome/build.zig) imports `core/src/root.zig` as the Zig module `biblio`. |
| Terminal | [`tui/build.zig`](../tui/build.zig) does the same. |
| Android | [`android/native/build.zig`](../android/native/build.zig) builds `libbiblio_jni.so` (the core plus a JNI shim) for each ABI. |
| Windows | `Biblio.csproj` runs `zig build` for the target platform and copies `biblio.dll` next to the app. |

---

## Concepts

### Clients and guests

A **client** is one session for a library and a username. A client with an empty username is a
**guest**: it can search the catalog but can't sign in, so account operations fail with
`BIBLIO_SIGN_IN_REQUIRED`.

Some operations need no client at all, such as looking up a library. Pass a null client for
those.

BiblioCommons ends a session when the same login signs in somewhere else. Keep **one client
per login per app**, or two clients will keep signing each other out. The apps enforce this by
allowing one window per login.

### Blocking calls and threads

Every operation blocks until it finishes, which may involve several network requests. Call
operations off the UI thread:

| App | How calls are made |
|---|---|
| Swift | On a dedicated concurrent `DispatchQueue`, resumed through a continuation |
| Kotlin | On `Dispatchers.IO` |
| C# | In `Task.Run` |
| GNOME | On a `std.Thread`, with the result delivered back through `g_idle_add` |
| Terminal | On the main thread, after drawing a "Loading…" line |

Clients are thread-safe, so several calls on one client may run at once. If one call finds
the session has expired, it signs in again, and the other calls wait for that sign-in and use
it.

Operations marked "No" under Network in the tables below return right away. They are safe to call
on the UI thread.

### Pacing

All clients share one throttle, so the apps stay gentle with library sites. At most
**3 requests** are in flight at a time, and each request starts at least **250 ms** after the
one before. Library lookups and image fetches go through the same throttle.

### Sessions and signing in

- Account operations sign in first if needed, by calling the app's password callback.
- If the gateway rejects a request with 401 or 403, or with an error message about the
  session, the core signs in again once and retries the request.
- Pages on the library's website (used for account settings) are retried the same way when
  they redirect to `/user/login`.

The app never sees an expired session. It only sees errors that are left after the retry.

### Cookies and redirects

Each client has its own cookie jar. The core follows up to 5 redirects. A 303, or a 301 or 302
after a POST, is followed as a GET; a 307 or 308 repeats the original method and body. Any
transport the app supplies must therefore **not** follow redirects or store cookies; see
[Writing a transport](#writing-a-transport).

### Transport

The core has a built-in HTTP client (Zig's `std.http`, with TLS). It reads the system's
trusted certificates:

- Linux: `/etc/ssl/certs` and similar locations
- Android: `/system/etc/security/cacerts`
- Windows: the certificate store
- macOS: the system keychain

An app can install its own transport instead. The Apple app does this to use URLSession, which
honors system proxies and VPNs. On iOS there is no built-in transport, so a transport is
required.

### Passwords

The core never stores passwords. When it needs to sign in, it calls the password callback
given to `biblio_client_new`, uses the password once, and wipes its copy. Each app keeps
passwords in its platform's secure store:

| App | Where passwords are kept |
|---|---|
| Apple | Keychain |
| GNOME | Secret Service |
| Terminal | Nowhere: asked for at sign-in and kept in memory while the account is open |
| Android | Android Keystore (AES-GCM) |
| Windows | Credential Locker |

After `biblio_change_password` succeeds, the app must save the new password itself.

### Memory

Memory that crosses the boundary in either direction is allocated with `biblio_alloc` and
freed with `biblio_free`, whichever side frees it:

- The core returns strings and plain arrays this way, and **the app frees them**.
- The app returns passwords and transport responses this way, and **the core frees them**.

Result structs are the exception. Each one is a single allocation that owns all of its
strings, arrays and nested structs, and is freed with its own function, such as
`biblio_list_page_free`. Error messages are released with `biblio_error_clear`.

---

## Clients, memory and transport

```c
void *biblio_alloc(size_t len);
void  biblio_free(void *ptr);
```

Allocates or frees memory that crosses the boundary. `biblio_free(NULL)` does nothing. Don't
pass these pointers to `free`.

```c
const char *biblio_version(void);
```

Returns the core's version, for example `"1.1.0"`. The string is static; don't free it.

```c
typedef char *(*biblio_password_fn)(void *ctx, const char *subdomain, const char *username);

biblio_client *biblio_client_new(const char *subdomain, const char *username,
                                 biblio_password_fn password, void *ctx);
void biblio_client_free(biblio_client *client);
```

Creates or frees a client. `subdomain` is the library's catalog subdomain (`"wccls"` for
wccls.bibliocommons.com). An empty `username` makes a guest.

The password callback:
- runs on whichever thread is making the call;
- returns a NUL-terminated string allocated with `biblio_alloc`, or NULL if no password is
  saved, which fails sign-in with `BIBLIO_MISSING_CREDENTIALS`;
- receives `ctx` unchanged.

`biblio_client_new` returns NULL only if memory runs out. Before calling
`biblio_client_free`, make sure no call on that client is still running; the Windows binding
counts calls in flight and frees the client after the last one.

```c
void biblio_set_transport(biblio_transport_fn transport, void *ctx);
```

Sends every request through the app's HTTP stack. Pass NULL to go back to the built-in
transport. Call this once at startup, before creating any clients, because clients keep the
transport they were created with. See [Writing a transport](#writing-a-transport).

---

## Calling conventions

- **Names.** Each operation is `biblio_` plus its name in snake_case, such as
  `biblio_library_info` or `biblio_cancel_holds`.
- **Results.** A function that can fail returns `biblio_result`, where `BIBLIO_OK` is 0. The
  result arrives through an out-parameter such as `biblio_list_page_t **out`. Pass NULL to
  discard it.
- **Errors.** Pass a `biblio_error` to get the failure's kind, its HTTP status (for
  `BIBLIO_HTTP`) and a message written for people, which can be shown as is. Release the
  message with `biblio_error_clear`. You may pass NULL if the return code is enough.
- **Freeing.** Each result struct has its own free function, such as
  `biblio_list_page_free(page)`. The struct owns everything it points to, so one call frees it
  all. Its first field, `owner`, is the core's bookkeeping; leave it alone.
- **Strings.** Arguments and fields are NUL-terminated UTF-8. A missing optional string is
  NULL. Strings a function returns directly, such as `biblio_format_name`, are freed with
  `biblio_free`.
- **Optional numbers and booleans** come with a flag: `has_position` says whether `position`
  is set.
- **Arrays** are a pointer and a `<name>_count`, such as `entries` and `entries_count`.

| `biblio_result` | Meaning | What apps usually do |
|---|---|---|
| `BIBLIO_OK` | Success | |
| `BIBLIO_SIGN_IN_REQUIRED` | An account operation was called on a guest client | Offer to sign in |
| `BIBLIO_MISSING_CREDENTIALS` | The password callback returned NULL | Ask the user to add the account again |
| `BIBLIO_LOGIN_FAILED` | The library rejected the username or password | Show the message |
| `BIBLIO_HTTP` | The gateway or website returned an error status | Show the message |
| `BIBLIO_NETWORK` | The library couldn't be reached | Show the message; retrying may help |
| `BIBLIO_UNEXPECTED` | The library refused the request (for example, the hold limit was reached) or a page couldn't be read | Show the message |
| `BIBLIO_NOT_A_LIBRARY` | `biblio_library_info` found no BiblioCommons catalog at that subdomain | Show the message |
| `BIBLIO_BAD_REQUEST` | A missing argument or client | A bug in the app |
| `BIBLIO_OUT_OF_MEMORY` | The core ran out of memory | Rare; report it |

### Example

```c
#include "biblio.h"
#include <stdio.h>
#include <string.h>

static char *password(void *ctx, const char *subdomain, const char *username) {
    (void)subdomain, (void)username;
    const char *saved = ctx;  /* a real app reads its secure store */
    size_t n = strlen(saved) + 1;
    char *out = biblio_alloc(n);
    memcpy(out, saved, n);
    return out;
}

void show_holds(void) {
    biblio_client *client = biblio_client_new("wccls", "reader", password, (void *)"1234");
    biblio_list_page_t *page = NULL;
    biblio_error err = {0};
    if (biblio_holds(client, 1, NULL, &page, &err) == BIBLIO_OK) {
        for (size_t i = 0; i < page->entries_count; i++) {
            const biblio_list_entry_t *e = &page->entries[i];
            int ready = e->account_status && e->account_status->ready;
            printf("%s%s\n", e->bib.title, ready ? " (ready for pickup)" : "");
        }
        biblio_list_page_free(page);
    } else {
        fprintf(stderr, "%s\n", err.message);
        biblio_error_clear(&err);
    }
    biblio_client_free(client);
}
```

---

## Operations

Every result type is described under [Result types](#result-types). The tables below use
these columns:

- **Network:** whether the function makes requests. Those without are safe on the UI thread.
- **Sign-in:** whether the client must belong to a signed-in user. Guests get
  `BIBLIO_SIGN_IN_REQUIRED`.

### Without a client

| Function | Arguments | Result | Network |
|---|---|---|---|
| `biblio_subdomain_from` | `input` | String or NULL | No |
| `biblio_library_info` | `subdomain` | `biblio_library_info_t` | Yes |
| `biblio_library_exists` | `subdomain` | `bool` | Yes |
| `biblio_directory_page` | `url` (NULL for the first page) | `biblio_directory_page_t` | Yes |
| `biblio_resolve_subdomain` | `name`, `website` (may be NULL) | String or NULL | Yes |
| `biblio_format_name` | `code`, `labels` (may be NULL) | String | No |
| `biblio_sort_name` | `id`, `labels` (may be NULL) | String | No |
| `biblio_readable_tint` | `hex`, `dark` | `"#RRGGBB"` or NULL | No |
| `biblio_codabar` | `value`, `*count` | `double` array, or NULL | No |
| `biblio_fetch_image` | `url` | Image bytes and their length | Yes |
| `biblio_library_icon` | `website`, `subdomain`, `logo`, `*bytes`, `*len` | `biblio_icon_kind`, and image bytes unless `NONE` | Yes |
| `biblio_logo_bounds` | `pixels`, `width`, `height`, `stride`, `channels`, `bounds[4]` | `true` and the content rectangle, or `false` | No |

**`biblio_subdomain_from`** turns what someone typed into a catalog subdomain. It accepts
`wccls`, `WCCLS`, `https://smpl.bibliocommons.com/` and `smpl.bibliocommons.com/v2/search?…`.
It returns NULL for `www.bibliocommons.com` or for text that can't be a subdomain.

**`biblio_library_info`** reads the library's public search page. It returns the library's
name, short name, brand color, website, the languages its catalog offers, and its catalog
labels (the keys starting `FORMAT.`, `AUDIENCE.`, `FICTION_TYPE.`, `LANGUAGE.`,
`LANGUAGE_NAME.` and `sort.`). `users` is always empty; the app keeps its own. Unknown
subdomains fail with `BIBLIO_NOT_A_LIBRARY`.

**`biblio_library_exists`** checks whether the gateway knows a subdomain, using one small
request.

**`biblio_directory_page`** fetches one page of BiblioCommons' partner list
(bibliocommons.com/libraries-we-work-with). Pass NULL for the first page, then each page's
`next` until it is NULL. The apps use it to autocomplete "Add Library" by name.

**`biblio_resolve_subdomain`** guesses a directory entry's catalog subdomain from its website
and name, and checks each guess with `biblio_library_exists`. That takes one request per
guess, and stops at the first match.

**`biblio_format_name`** and **`biblio_sort_name`** give display names for a format code (such
as `BK` or `BLURAY`) or a sort ID (such as `newly_acquired`). They prefer the library's own
labels, which are localized to the account's language. Without them, they fall back to
built-in English names, and then to the code made readable (`SOME_THING` becomes "Some thing").

**`biblio_readable_tint`** adjusts a library brand color until it has 4.5:1 contrast with a
light bar background (when `dark` is false) or a dark one, changing only lightness. It returns
NULL for a color it can't parse.

**`biblio_codabar`** encodes a library card number as Codabar bar and space widths, in narrow
units, starting with a bar. A wide element is 2.5. The number gets `A…A` start and stop
characters unless it already has its own. Draw it with a quiet zone of 10 units on each side.
It returns NULL if the number has characters Codabar can't encode.

**`biblio_fetch_image`** fetches an image, such as a book jacket, through the shared throttle.
It is for apps without an image loader of their own (GNOME). Apps that have one should use it
instead.

**`biblio_library_icon`** finds a library's icon for its row in the library list. It prefers
the largest square icon on the library's website (an apple-touch-icon or a sized
`rel="icon"`, checking the first three candidates) once it is at least 64 pixels wide. Next
comes `logo`, the wide partner logo from the directory (`BIBLIO_ICON_LOGO`), then a smaller
favicon. With `website` NULL it reads the website from `subdomain`'s catalog. The bytes may
be PNG, ICO, GIF, BMP or JPEG. Apps cache the result on disk, keyed by the website's host, so
each library's site is asked only once.

**`biblio_logo_bounds`** finds the part of a decoded logo that isn't white margin, padded by
a twentieth of its size, so apps can crop it before fitting it on a white tile. Pixels are
rows `stride` bytes apart of `channels` bytes each: three colors in any order, then alpha
when there are four.

### On a client

| Function | Arguments | Result | Network | Sign-in |
|---|---|---|---|---|
| `biblio_configure` | `language`, `sample_account` | — | No | No |
| `biblio_status` | — | `biblio_fetch_status_t` | No | No |
| `biblio_login` | `force` | `biblio_patron_t` | Yes | Yes |
| `biblio_patron` | — | `biblio_patron_t` or NULL | No | No |
| `biblio_search` | `biblio_search_query` | `biblio_list_page_t` | Yes | No |
| `biblio_availability` | `metadata_id` | `biblio_copy_list_t` | Yes | No |
| `biblio_details` | `metadata_id` | `biblio_detail_list_t` | Yes | No |
| `biblio_locations` | — | `biblio_location_list_t` | Yes | No |
| `biblio_holds` | `page`, `sort` | `biblio_list_page_t` | Yes | Yes |
| `biblio_checkouts` | `page`, `sort` | `biblio_list_page_t` | Yes | Yes |
| `biblio_history` | `page`, `sort` | `biblio_list_page_t` | Yes | Yes |
| `biblio_place_hold` | `metadata_id`, `material_type`, `pickup_branch` | — | Yes | Yes |
| `biblio_cancel_holds` | `biblio_hold_ref` array | `biblio_refusal_list_t` | Yes | Yes |
| `biblio_account_settings` | — | `biblio_account_settings_t` | Yes | Yes |
| `biblio_set_pickup` | `branch_id` | — | Yes | Yes |
| `biblio_set_language` | `code` | — | Yes | Yes |
| `biblio_set_borrowing_history` | `enabled` | — | Yes | Yes |
| `biblio_change_email` | `email` | — | Yes | Yes |
| `biblio_change_password` | `current`, `new_password` | — | Yes | Yes |

**`biblio_configure`** sets client options. NULL `language` or a negative `sample_account`
leaves that option unchanged.
- `language` is the app's language, used for requests until a sign-in reports the account's
  own language.
- `sample_account` replaces the card number and email in every patron with samples. It is
  for screenshots.

**`biblio_status`** describes the client's most recent request, for a status bar:
- `active` is how many requests are in flight.
- `title` is the page's `<title>`, or a name for the gateway endpoint such as "Holds" or
  "Availability".
- `url` and `bytes` are the request's URL and response size.

The Apple app calls it after each operation.

**`biblio_login`** signs in if the client isn't signed in, and returns the patron. With
`force` it always signs in again; use that to check a newly entered password.

**`biblio_patron`** returns the patron from the last sign-in without contacting the library,
or sets `*out` to NULL if the client hasn't signed in.

**`biblio_search`** searches the catalog, 25 results per page. Its `biblio_search_query` has:
- `search_type`: NULL or `"smart"` for keyword searches, or `"bl"` for field-qualified queries.
- `filters`: extra form fields as `biblio_pair` entries, such as `f_AUDIENCE` = `adult`.
- `format`: a format code to filter by.
- `sort`: a server sort ID; the first page reports which ones are available.
- `page`: 1-based; 0 means 1.

Signed-in searches also mark results the account already has on hold or checked out, through
any of the title's editions. The New Titles list is a search for `nw:[0 TO 180]` with
`search_type` `"bl"`, the filter `f_on_order` = `false` and the sort `newly_acquired`.

**`biblio_availability`** lists the copies of a title by branch, with available copies first.
Each copy has a `kind` grouping its status (see `biblio_copy_t`), which the apps use for an
icon and color. The status text always appears as well.

**`biblio_details`** returns the full catalog record as labeled fields, leaving out the title
and summary.

**`biblio_locations`** returns the library's visible branches, sorted by name, for pickup
choices.

**`biblio_holds`**, **`biblio_checkouts`** and **`biblio_history`** return the account's lists,
one page at a time, in the same `biblio_list_page_t` as search. `page` is 1-based (0 means 1)
and `sort` may be NULL.

**`biblio_place_hold`** places a hold:
- `material_type` comes from the bib; NULL means `"PHYSICAL"`.
- A NULL `pickup_branch` uses the account's preferred pickup location.
- If the library refuses, the result is `BIBLIO_UNEXPECTED` with the library's reason. For
  example, its message mentions the maximum number of holds when the account is at its limit.

**`biblio_cancel_holds`** cancels several holds in one request and returns the ones the
library refused, with its reasons. Some libraries won't cancel holds that are ready for
pickup. If the library refuses without saying which hold, every requested hold is reported
refused.

**`biblio_account_settings`** reads the current email, preferred pickup branch and language
from the library website's account forms. It makes three page requests.

**`biblio_set_pickup`**, **`biblio_set_language`** and **`biblio_change_email`** submit the
website's account forms. `biblio_set_pickup` also removes the branch from the second and third
preference slots if it was there. Each updates the cached patron, so the next `biblio_patron`
call reflects the change.

**`biblio_set_borrowing_history`** turns the library's record of the account's borrowing
history on or off. The library may delete existing history when it is turned off, so the apps
ask first.

**`biblio_change_password`** changes the PIN or password. **The app must then save the new
password** so the core can sign in again later. Android must also pass it to
`Core.Client.setPassword`.

---

## Result types

Each type is a struct named `biblio_<type>_t`, matching the Zig structs in
[`core/src/models.zig`](../core/src/models.zig) with fields in snake_case. Fields marked `?`
are optional: NULL for strings, or a `has_<name>` flag for numbers and booleans. Lists of
copies, detail fields, locations and refusals come in a struct with `items` and `items_count`,
such as `biblio_copy_list_t`. Each app copies these into its own model types:

| App | Where the model types are |
|---|---|
| Swift | `Models.swift`, built in `CoreModels.swift` |
| Zig (GNOME) | Reads the C structs in place |
| Zig (terminal) | Uses the core's Zig types from `biblio.models` |
| Kotlin | `Models.kt`, built by the JNI shim |
| C# | `Models.cs`, built in `Interop.cs` |

### `biblio_bib_t`

A catalog record.

| Field | Type | Notes |
|---|---|---|
| `id` | string | The metadata ID, such as `S1C2847591` |
| `title` | string | `"Untitled"` if the library has none |
| `subtitle`? | string | |
| `authors` | string array | Primary author first |
| `format` | string | A format code; get the display name with `biblio_format_name` |
| `publication_date`? | string | Shapes vary, such as `"2026"`, `"20261006"` or `"c1999"` |
| `edition`?, `call_number`?, `summary`? | string | |
| `jacket_small`?, `jacket_large`? | string | Image URLs |
| `material_type` | string | Pass it to `biblio_place_hold` |
| `holdable` | bool | |
| `status`? | string | `AVAILABLE`, `UNAVAILABLE`, `ON_ORDER`, … |
| `held_copies`, `available_copies`, `total_copies`, `on_order_copies` | int64 | `held_copies` is how many people are waiting |

### `biblio_list_entry_t`

One row of any list.

| Field | Type | Notes |
|---|---|---|
| `id` | string | Unique within the list: a metadata ID, or `hold-…`, `co-…`, `bh-…` |
| `bib` | `biblio_bib_t` | If the library didn't return the record, a placeholder with the title only |
| `kind` | string | `catalog`, `hold`, `checkout` or `history` |
| `server_index` | int64 | Position in the server's order; use it to keep sorts stable |
| `hold`? | `biblio_hold_t *` | For holds, and for catalog rows the account has on hold |
| `checkout`? | `biblio_checkout_t *` | For checkouts |
| `history`? | `biblio_history_entry_t *` | For history |
| `account_status`? | `biblio_account_status_t *` | The account's relationship to the item |

### `biblio_account_status_t`

| Field | Type | Notes |
|---|---|---|
| `kind` | string | `onHold` or `checkedOut`; a checkout takes precedence over a hold |
| `ready` | bool | The hold is ready for pickup |
| `position`? | int64 | Place in the hold queue |
| `due`? | string | Due date of a checkout |

### `biblio_list_page_t`

| Field | Type | Notes |
|---|---|---|
| `entries` | `biblio_list_entry_t` array | |
| `page`, `pages` | int64 | 1-based |
| `count` | int64 | Total entries across all pages |
| `page_size` | int64 | 25 on the libraries seen so far |
| `facets` | `biblio_facet_t` array | Search only; each has an `id` and `values` (`value`, `count`). `FORMAT` drives the format filter |
| `sort_options` | string array | Server sort IDs |
| `applied_sort`? | string | |

### Holds, checkouts and history

| Type | Fields |
|---|---|
| `biblio_hold_t` | `id`, `metadata_id`, `status` (such as `READY_FOR_PICKUP`, `NOT_YET_AVAILABLE`, `IN_TRANSIT`), `position`?, `pickup_location`?, `expiry_date`?, `pickup_by_date`?, `suspend_end_date`?, `can_cancel` |
| `biblio_checkout_t` | `id`, `metadata_id`, `status`?, `due_date`?, `checkout_date`?, `times_renewed`? |
| `biblio_history_entry_t` | `id`, `metadata_id`, `checkout_date`?, `returned_date`? |

Dates are passed through as the library sends them.

### `biblio_copy_t`

| Field | Type | Notes |
|---|---|---|
| `id`, `branch`, `status` | string | `status` is the library's own wording |
| `is_available`, `is_on_order` | bool | |
| `collection`?, `call_number`?, `due_date`? | string | |
| `kind` | string | See below |

`kind` is one of `available`, `onOrder`, `out`, `held`, `transit`, `repair`, `missing`,
`withdrawn`, `claimsReturned`, `libraryUseOnly` or `other`.

### Other types

| Type | Fields |
|---|---|
| `biblio_detail_field_t` | `label` (readable, such as "Publisher"), `values` (string array) |
| `biblio_location_t` | `id`, `name` |
| `biblio_patron_t` | `user_id`, `account_id`, `name`, `email`?, `language`, `barcode`?, `preferred_pickup`?, `borrowing_history_enabled`? (unset when the library doesn't say) |
| `biblio_library_info_t` | `subdomain`, `name`, `short_name`?, `primary_color`? (`#RRGGBB`), `website`?, `labels` (`biblio_pair` array), `languages` (string array), `users` (always empty) |
| `biblio_directory_page_t` | `entries` (`biblio_directory_entry_t` array: `name`, `website`?, `region`?, `logo`?, a 640×400 partner logo URL), `next`? |
| `biblio_refusal_t` | `hold_id`, `reason` |
| `biblio_account_settings_t` | `email`?, `pickup`?, `language`? |
| `biblio_fetch_status_t` | `active`, `title`?, `url`?, `bytes` |

---

## Writing a transport

```c
typedef struct { const char *name; const char *value; } biblio_header;

typedef struct {
    const char *method;            /* "GET", "POST", "PUT", "DELETE" */
    const char *url;               /* absolute https URL */
    const biblio_header *headers;  /* includes User-Agent, Cookie, Accept, Content-Type, gateway tokens */
    size_t header_count;
    const unsigned char *body;     /* NULL when there is no body */
    size_t body_len;
} biblio_http_request;

typedef struct {
    int status;
    char *headers;                 /* "Name: value\r\n" lines, from biblio_alloc */
    size_t headers_len;
    unsigned char *body;           /* from biblio_alloc */
    size_t body_len;
} biblio_http_response;

typedef int (*biblio_transport_fn)(void *ctx, const biblio_http_request *request,
                                   biblio_http_response *response);
```

A transport sends exactly one request and fills in the response. It runs on the calling
thread, and may block. It must follow these rules:

- **Don't follow redirects.** Return 3xx responses with their `Location` header.
- **Don't store or send cookies of your own.** Send the request's `Cookie` header unchanged,
  and return every `Set-Cookie` on its own line. Some stacks join them with commas; URLSession
  does, so the Apple transport rebuilds the lines with `HTTPCookie.cookies(withResponseHeaderFields:for:)`.
- **Send a body with any method that has one.** That includes `DELETE`, which cancelling holds
  uses.
- **Decompress the body** if the stack negotiates compression.
- **Return 0** with every field filled in, or nonzero if the request couldn't be sent at all.
  A nonzero return becomes a `BIBLIO_NETWORK` error. An HTTP error status is still a success for the
  transport.

Allocate `headers` and `body` with `biblio_alloc`; the core frees them. For a complete
example, see `Transport` in [`apple/Biblio/Net/Core.swift`](../apple/Biblio/Net/Core.swift).

---

## Using the core from Zig

Zig apps import `core/src/root.zig` as a module and call the same functions directly. The
GNOME app does this:

```zig
const biblio = @import("biblio");
const capi = biblio.capi;

const client = biblio.biblio_client_new("wccls", "", password, null);
defer biblio.biblio_client_free(client);
var err: capi.Error = .{};
defer capi.biblio_error_clear(&err);
var page: ?*capi.ListPage = null;
if (capi.biblio_search(client, &.{ .query = "dune" }, &page, &err) != .ok) return;
defer capi.free(page);
```

The operations and result types are in `biblio.capi`, such as `biblio.capi.biblio_search` and
`biblio.capi.ListPage`. `biblio.capi.free(result)` frees any result. Zig code can also skip the
C layer and call the client directly, with Zig types: `biblio.Client` (a handle's `client`) and
`biblio.lookup()`, with result types from `biblio.models` and helpers such as
`biblio.library.formatName`, as the CLI and the terminal app do.

The module also exposes `biblio.sync`, which has the core's `Mutex`, `Condition` and
`allocator`. The Android JNI shim uses them, so it works on every target, including iOS, where
Zig 0.17's `std.Io.Threaded` doesn't compile.

---

## Testing

- **`zig build test`** runs unit tests in each source file, plus
  [`fixtures_test.zig`](../core/src/fixtures_test.zig). The fixture tests run whole
  client operations against a fake transport that serves canned gateway and website responses. They
  cover:
  - sign-in, and signing in again after a 401
  - search with account status, filters and the locale
  - guest restrictions
  - holds parsing, partial cancel refusals and hold-limit errors
  - availability ordering
  - account-form submission with cookies and redirects
  - the C functions' results and errors
- **The `biblio` CLI** (`zig-out/bin/biblio`) makes live calls and prints the results as JSON.
  Each run is one or two requests:
  - `biblio info SUBDOMAIN`
  - `biblio search SUBDOMAIN TEXT`
  - `biblio availability SUBDOMAIN METADATA_ID`
  - `biblio icon SUBDOMAIN`, which prints the icon's kind and size (up to five requests: the
    catalog, the library's website and three icons)
  - `biblio --user NAME holds SUBDOMAIN` (also `checkouts` and `history`), with the password
    in `$BIBLIO_PASSWORD`

  Keep live testing light, and don't change real accounts without meaning to.

When a library's responses change shape, capture a trimmed example as a new fixture before
changing the parser.

---

## Adding an operation

1. Implement it:
   - Library-wide operations go in `library.zig`.
   - Account operations go on `Client` in `client.zig`. Parse responses with the lenient `J`
     reader in `json.zig`, which treats missing or mistyped fields as null instead of failing.
   - On failure, set `failure.*` to a `kind` and a message written for people, then return an
     error.
2. Export it from `capi.zig`. A client method is usually one line with `fetch` or `perform`.
   If it returns a new type, add an `extern struct` with the model's fields in snake_case,
   plus `has_<name>` for optional numbers and booleans and `<name>_count` for arrays.
   `deliver` converts it automatically, and the type's free function goes in the `comptime`
   list at the end of the file.
3. Declare the function, and any new struct, in `include/biblio.h`. Then check that the C and
   Zig layouts match.
4. Add the operation to this guide, and add a fixture test.
5. Use it from each app:
   - Apple: a method in `apple/Biblio/Net/BiblioAPI.swift`, plus a model initializer in
     `CoreModels.swift` for a new type.
   - GNOME: call it with `Job.start` (`gnome/src/core.zig`).
   - Terminal: call the `Client` method from `tui/src/main.zig`.
   - Android: a native method in `android/native/src/jni.zig` and `Core.kt`. A new type needs
     a Kotlin model whose constructor follows the struct, an entry in `className`, and a case
     in the signature test.
   - Windows: the struct and function in `windows/Biblio/Core/Interop.cs`, and a method in
     `Core.cs`.
