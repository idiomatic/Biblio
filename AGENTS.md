* write "Biblio", a native SwiftUI app for macOS, iOS, and iPadOS (version 1.3): a patron front-end to https://LIBRARY.bibliocommons.com/.
## views
* holds: view, add, and remove; when the library refuses a removal (e.g., "Ready for pickup"), say why, including partial refusals.
* checked out items, borrowing history, search, and advanced search.
* New Titles: one "View All New Titles" list, without the recent_arrivals grid; its "Just Arrived" and "On Order" tabs and "Filter by" picker may become filters.
* filter lists by format, searches by facets (e.g., location, audience, language, publication date), and holds by "Ready", "Not Ready", and "On Order", with count badges.
* sidebar badges show hold and checked out counts, fetched at launch; lists have no item-count footer.
* lists scroll infinitely, with placeholder rows sizing the scroll bar and only viewed pages fetched; refetch a list shown again over 15 minutes after fetching.
* sort lists, including by people waiting; client-side sorts may fetch remaining pages in the background and animate reordering.
* list paging, sorting, and filtering live in the shared core (`biblio_list_*`).
* multiple selection places or cancels holds on many items.
* refresh by pull-down (iOS/iPadOS) or menu item (macOS): account lists start a fresh session; stale rows stay, dimmed, until the first page replaces them; the open item's details reload.
* list items show format, year, edition, and availability, including "on order" copies (with a box symbol).
* editions drop catalog punctuation: enclosing square brackets and a closing period, except one ending an abbreviation.
* an inspector shows item detail; on macOS its toggle is the rightmost toolbar button.
* item detail fetches "Availability by Location" in the background (collection and call number are optional), with a colored symbol for each copy's status (e.g., available, on order, out, in transit, missing).
* item detail has "Hold" with a pickup location menu (defaulting to the preferred location), or "Cancel Hold" for held items.
* dragging part of item detail onto any window's holds places a hold, or onto its search field searches for it; no drag hints.
* the account view and a barcode toolbar button (in the sidebar's toolbar on macOS) show the library card as a scannable Codabar barcode.
* the app version shows subtly at the foot of the sidebar and opens the About box, which says in everyday words that people made Biblio with AI assistants, and that BiblioCommons and the library didn't.
* a bottom status bar shows the latest request as `TITLE [SIZE KiB]` (URL on hover), fading after 2 seconds of inactivity.
## settings
* on macOS, account settings live in the Settings window.
* change email, password (updating the Keychain), pickup location, and library language, saving on change and reverting on error.
* the library language is the account's preference, not the app's language; never set it automatically, but offer "Use System Language" to pick the closest supported system language.
* toggle borrowing history, confirming before turning it off.
## authentication
* remember credentials in the Keychain; reauthenticate transparently when sessions expire (after inactivity, or when the login signs in elsewhere, so allow one window per login).
* multiple libraries, each with multiple users; each new window, with its own session, offers a menu of libraries, then of that library's users.
* on macOS, windows restored at launch reopen their login, unless it was removed or is open elsewhere.
* guests may browse, without holds or settings.
* when a guest places a hold (button, drag, or multiple selection), show a sign-in sheet of the library's users plus "Add User…" (or the sign-in form if none); signing in keeps the window's search, section, and selection, and on iPhone reopens the item sheet.
* on macOS, a guest window's sidebar "Sign In" opens that sheet, and signed-in windows have no "Switch User or Library" (use File ▸ New Window); on iOS/iPadOS, the sidebar returns to the menus ("Sign In or Change Library" for guests, "Switch User or Library" otherwise).
* add a library by subdomain (e.g., "wccls") or URL, autocompleting in the background from https://www.bibliocommons.com/libraries-we-work-with and its "Next" pages.
* remove a library, confirming first if its users and passwords go too, from a toolbar button on its user menu (instead of "Add User") or swipe or context menu in the library menu; disabled, with the reason, while one of its logins is open.
* libraries show square icons in the library menu and suggestions: the website's large square icon, else the directory's partner logo trimmed of white margins, else a favicon, else a brand-colored tile; cache them on disk.
* hide "CMS" navigation (e.g., "Using the Library", "Events & Activities") and item detail "Opinion".
## exploration and testing
* if logins exist in the Keychain, you may test with those accounts; use caution with persistent changes.
* a .env file, if present, holds login information only for answering the current prompt.
* with a login, you may place and remove holds; find unheld "4K UHD Blu-Ray" items under "On Order"; up to 25 more should hit the "too many holds" error; leave preexisting holds alone.
* you may test changing each account setting, restoring the original value; don't turn borrowing history off on a real account.
* test detecting concurrent sessions with the same login.
* be gentle with the library website to avoid rate limiting.
## design
* follow the Apple Human Interface Guidelines.
* panels and sheets fit narrow iPhones (e.g., iPhone 13 mini); minimum widths only on macOS.
* confirmation dialogs appear over the control that asked for them.
* use [icon.png](icon.png) as the app icon: full-bleed on iOS, the standard rounded, shadowed shape on macOS.
* may use library branding colors, adjusted for contrast in light and dark mode.
* may subtly color availability statuses, and list items by the account's status (on hold, ready for pickup, checked out, overdue).
* build without compiler warnings.
## documentation
* [README.md](README.md) for GitHub: features, requirements, building, project layout, and license (BSD 3-Clause).
* [NOTES-API.md](NOTES-API.md): the BiblioCommons gateway endpoints the app uses.
* [CHANGELOG.md](CHANGELOG.md): user-facing changes per version, tagged `vX.Y` at each version bump.
## miscellaneous
* delete .zig-cache and zig-out when cleaning up the workspace.
