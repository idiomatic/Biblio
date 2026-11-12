* write "Biblio" (version 1.8), a patron front-end to https://LIBRARY.bibliocommons.com/: a native SwiftUI app for macOS, iOS, and iPadOS, which this spec describes, plus GNOME, Android, Windows, and terminal apps on the same Zig core, each following its platform's design guidelines.
## views
* holds: view, add, and remove; when the library refuses a removal, say why, including partial refusals.
* checked out items, borrowing history, search, and advanced search.
* New Titles: one "View All New Titles" list, without the recent_arrivals grid; "Just Arrived", "On Order", and "Filter by" may become filters.
* filter lists by format, searches by facets, and holds by "Ready", "Not Ready", and "On Order", with count badges.
* sidebar badges show hold and checked out counts, fetched at launch; lists have no item-count footer.
* lists scroll infinitely, with placeholder rows sizing the scroll bar and only viewed pages fetched; refetch a list shown again over 15 minutes after fetching.
* sort lists, including by people waiting, and by title ignoring case and accents, with numbers by value; client-side sorts may fetch remaining pages in the background and animate reordering.
* list paging, sorting, and filtering live in the shared core (`biblio_list_*`), as does display logic (format and sort names, brand tints, barcodes, and editions); apps don't reimplement it.
* multiple selection places or cancels holds on many items.
* refresh by pull-down (iOS/iPadOS) or menu item (macOS): account lists start a fresh session; stale rows stay, dimmed, until the first page replaces them; the open item's details reload.
* list items show format, year, edition, and availability, including "on order" copies (box symbol).
* list rows and item detail show an item the same way: format, year, and edition in one style (one line, " · " between, in a row; a line each beside the cover in detail), the availability line (status, on order, people waiting, copies), and the account's relationship as one colored capsule (ready for pickup by a date, in transit, paused, or on hold, each with its place in line; or checked out and due).
* items borrowed before, from each card's borrowing history: catalog and hold rows show a quiet mark after the details, fainter for the same work (title and first author) in another format, which item detail names ("You borrowed this in March 2024 · 3 times", "You borrowed on DVD in …"); a "Not Borrowed" filter (search, New Titles, holds), offered once the history is fully read, hides works borrowed in the same format.
* the core indexes borrowing history (`biblio_borrowed_*`): unbounded, read in the background after the other launch requests (while the library keeps it) through the shared throttle, resuming; later reads assume newest first and stop at a known entry, refetching all (and logging it) when a page's dates increase or the count doesn't add up; apps keep it in a private, unbacked-up file per card, deleted on sign-out, and keep nothing while the library's borrowing history is off; a card's page counts the items in its borrowing history beside a small progress bar while it's read ("Updating · 340 of 1,200" on hover) and a symbolic "Refresh Borrowing History" button; on macOS, the sidebar's Borrowing History row shows a small gauge while it's read.
* the core refines formats a library files under a broader code to the BiblioCommons code they have (4K Ultra HD Blu-ray filed as Blu-ray), from a table of rules each skipped for a library that uses the code itself and each recorded with its library in [NOTES-API.md](NOTES-API.md); searches offer refined formats as filters, filtering locally.
* editions drop catalog punctuation: matching square brackets and a closing period, except one ending an abbreviation.
* an inspector shows item detail, closing when the section changes; on macOS its toggle is the rightmost toolbar button.
* item detail fetches "Availability by Location" in the background (collection and call number optional), with a colored symbol per copy status.
* item detail has "Hold" with a pickup location menu (defaulting to the preferred location), or "Cancel Hold" for held items.
* dragging part of item detail onto any window's holds places a hold, or onto its search field searches for it; no drag hints.
* the barcode is the everyday control: on iOS/iPadOS a toolbar button, never inside a menu (macOS has none: nobody brings a Mac to checkout), and the account view shows the library card as a scannable barcode, Codabar or Code 128.
* the account view alone chooses the barcode type, a sticky choice per library that the toolbar button follows.
* on iOS, a Lock Screen and Control Center control opens the barcode for the most recently used login (`biblio://card`), and swiping left or right rotates between that library's logins' cards.
* the app version shows subtly at the foot of the sidebar and opens the About box, which says in everyday words that people made Biblio with AI assistants, and that BiblioCommons and the library didn't, and has a Copy Diagnostic Log button (on Mac, in Help) for the local log of server throttling and failures.
* a bottom status bar shows the latest request as `TITLE [SIZE KiB]` (URL on hover), fading after 2 seconds of inactivity.
## settings
* account settings live on each card's page, opened from the sidebar's Cards rows; macOS has no Settings window.
* change email, password (updating the Keychain), pickup location, and library language, saving on change and reverting on error.
* the library language is the account's preference, not the app's; never set it automatically, but offer "Use System Language" for the closest supported language.
* toggle borrowing history, confirming before turning it off.
## authentication
* remember credentials and library cards in the Keychain; reauthenticate transparently when sessions expire; one window per library, each of its cards in at most one window.
* multiple libraries, each with multiple users; each new window, with its own session, offers a menu of libraries.
* the library is navigation and the card is a property of the window: the library menu is the bottom of the navigation stack, reached by the sidebar's back chevron (on every platform), whatever the number of libraries, so another library can always be chosen or browsed as a guest; choosing a library opens its sidebar, one level down and not a list, on the cards it last showed that no other window has (every free card if none of those is); a library with no saved or no free cards opens as a guest window, whose Sign In picks or adds a card, so every library opens to the same kind of screen; "Browse as Guest" in a library's context menu opens it as a guest even with cards.
* a library window's scope is the set of its cards that are included: one card is an ordinary account window, several are combined; each card is in at most one window, so a card open in another window is disabled, with the reason, and excluding a card releases it to other windows; restored windows keep their scope.
* with two or more saved cards, the sidebar's Cards section lists each as a row (monogram chip and name) that opens its account page, with a standard toggle to include it in the lists (on macOS a checkbox before the chip, as in Safari's Extensions; at least one stays on) and an "Add Card…" row (a single card also has the section, its monogram chip, and "Add Card…", but no toggle); a card that is out of the window dims its icon and name but its row still opens its page, the same page with every section in place: its profile and barcode dimmed, its settings disabled and empty (it has no session here), its appearance, Use a Different Library, and Sign Out (unless another window has it) still usable, and a note above it all saying why (laid out but invisible while the card is on, so nothing moves); the page keeps its scroll position as the card is switched on or off; toggling keeps the window's section, search, and selection, and there is no switching cards by tapping.
* the sidebar's sections (Cards, Catalog, My Library) collapse, remembered per library, starting expanded.
* with exactly one login in the Keychain, open straight into its account: no library or user menus, no toggles, and no library removal in the sidebar; guests still see the library menu.
* a card's account view offers "Use a Different Library" and "Sign Out", which removes that card and its saved password after confirming; File on macOS has "Add Another Card…".
* a combined window interlaces holds, checked out, and history across its cards:
  * each card has a color, a name, used in the sidebar, the launcher, and "Hold for …" (default: the library's contact first name, tidied if all capitals, remembered with the card), and a monogram (default: the name's initial), edited on its page; rows show the monogram chip, while status tints stay.
  * a "Card" filter joins the other filters; card is a secondary sort key; sidebar badges sum the cards, with a per-card breakdown on hover.
  * item detail shows which card holds or borrowed the item (a chip per card), each with its own "Cancel Hold".
  * "Hold" becomes a split button, "Hold for <card>" with a drop-down of the other cards that each hold at once, defaulting to the sticky card, else the card with the fewest holds on that title; dragging to holds uses it, or drop onto a card's sidebar row to hold for that card; multiple selection opens "Place Holds": a section per card, with titles dragged between sections (or a row's "Move to…"), refused where the card already has the title, "Split Evenly", and one button to place them all (a compact screen's Hold button opens it as a sheet).
  * refusals name the card.
  * the barcode shows the most recently used card, and swiping rotates the library's cards.
  * a card's settings are per card, on its page; borrowing history is read-only in a combined window.
  * the core merges per-login sessions in `biblio_list_*` (rows carry `login_id`); the shared throttle paces their requests.
* on macOS, windows restored at launch reopen their login, unless it was removed or is open elsewhere.
* guests may browse, without holds or settings.
* when a guest places a hold (button, drag, or multiple selection), show a sign-in sheet of the library's users plus "Add User…" (or the sign-in form if none); signing in keeps the window's search, section, and selection, and on iPhone reopens the item sheet.
* a guest window's "Sign In" (sidebar on macOS, toolbar on iOS/iPadOS) opens that sheet.
* on iOS/iPadOS devices with a camera, the sign-in form's Scan button reads a physical card's Codabar or Code 128 barcode into the card-number field; the core cleans the value (`biblio_card_normalize`).
* signing in with a card number (digits) tries the username the library gives the patron with the same password and, if that works, saves the card under it (a card already saved under that username keeps the fresher password); an account already saved under another login is refused, naming it.
* add a library by subdomain or URL, autocompleting in the background from https://www.bibliocommons.com/libraries-we-work-with and its "Next" pages; a new library opens as a guest window.
* remove a library, confirming first if its users and passwords go too, from a swipe or context menu in the library menu; disabled, with the reason, while one of its logins is open.
* libraries show square icons: the website's large square icon, else the directory's partner logo trimmed of white margins, else a favicon, else a brand-colored tile; cache them on disk.
* hide "CMS" navigation and item detail "Opinion".
## exploration and testing
* if logins exist in the Keychain, you may test with those accounts; use caution with persistent changes.
* a .env file, if present, holds login information only for answering the current prompt.
* with a login, you may place and remove holds; find unheld "4K UHD Blu-Ray" items under "On Order"; up to 25 more should hit the "too many holds" error; leave preexisting holds alone.
* you may test changing each account setting, restoring the original value; don't turn borrowing history off on a real account.
* test detecting concurrent sessions with the same login.
* be gentle with the library website to avoid rate limiting.
## design
* follow the Apple Human Interface Guidelines.
* Apple typography uses semantic text styles, shared across macOS, iOS, and iPadOS, with no per-platform fonts; fixed sizes only for glyphs drawn to a shape (card chips, icon letters).
* panels and sheets fit narrow iPhones; minimum widths only on macOS.
* confirmation dialogs appear over the control that asked for them.
* use [icon.png](icon.png) as the app icon: full-bleed on iOS, the standard rounded, shadowed shape on macOS.
* may use library branding colors, adjusted for contrast in light and dark mode.
* may subtly color availability statuses, and list items by the account's status.
* build without compiler warnings.
## documentation
* [README.md](README.md) for GitHub, for the apps' users: features, requirements to run, and license (BSD 3-Clause), linking [DEVELOPMENT.md](DEVELOPMENT.md).
* [NOTES-API.md](NOTES-API.md): the BiblioCommons gateway endpoints the app uses.
* [CHANGELOG.md](CHANGELOG.md): user-facing changes per version, tagged `vX.Y` at each version bump.
* [docs/specifications/](docs/specifications/README.md): external specifications.
* [DEVELOPMENT.md](DEVELOPMENT.md), for those working on Biblio: building, project layout, testing, releasing, and next (to build, open, not planned), linking each component's README for its own details; delete items as they're resolved.
* [docs/screenshots/](docs/screenshots): the README's screenshots, one patron's visit from first launch to returns, captured against the fictional mock library (`BIBLIO_MOCK`, [core/mock/](core/mock/README.md)); draw placeholders for apps not yet captured with [tools/coming-soon.swift](tools/coming-soon.swift); turn recordings into GIFs with [tools/gif.swift](tools/gif.swift); blur any private details with [tools/blur.swift](tools/blur.swift); never capture the host Mac's screen.
## cross-platform builds and testing
* root [build.zig](build.zig): `zig build cross`.
* CI: [.github/workflows/ci.yml](.github/workflows/ci.yml).
* Apple apps build only on macOS; [apple/build.zig](apple/build.zig) builds the core as `apple/zig-out/lib/PLATFORM/libbiblio.a` and the `BiblioCore` module in `apple/zig-out/include`, which Xcode builds with `zig build` before compiling, so a clean build needs no prior step.
* run Linux, Windows, and macOS guests with `terrarium` (the Mac app runs ephemeral from the shared layer `macos-27.2-quiet`, on `macos-27.2-base`, with `--memory 4096`; put the app and mock in with `put`, as the mock README says); avoid emulation and keep retained images small; guests are ephemeral, so [windows/README.md](windows/README.md) says how to rebuild the Windows one.
* test the GNOME, Android, Windows, and terminal apps, and capture their screenshots against `BIBLIO_MOCK`, in a guest.
## miscellaneous
* delete .zig-cache and zig-out when cleaning up the workspace.
