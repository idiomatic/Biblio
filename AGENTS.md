* write "Biblio", a native SwiftUI app for macOS, iOS, and iPadOS (version 1.3): a patron front-end to https://LIBRARY.bibliocommons.com/.
## views
* holds: view, add, and remove; when the library disallows removal (e.g., "Ready for pickup"), say why, and handle partial refusals.
* checked out items, borrowing history, search, and advanced search.
* Explore New Titles: skip the recent_arrivals grid; fold the "Just Arrived" and "On Order" tabs and the "Filter by" picker into the "View All New Titles" list (the tabs may become a filter).
* filter item lists by format; filter searches by facets (e.g., availability location, audience, content, language, publication date, date added); filter holds by "Ready", "Not Ready", and "On Order", with counts as badges.
* the sidebar badges hold and checked out counts, fetched at launch; lists show no item-count footer.
* lists scroll infinitely: size the scroll bar to the whole list with placeholder rows, fetching only pages actually viewed; refetch a list shown again more than 15 minutes after it was fetched.
* sort lists, including by people waiting; client-side sorts may fetch remaining pages in the background and animate reordering.
* list paging, sorting, and filtering live in the shared core (`biblio_list_*`), not the app.
* multiple selection to place or cancel holds on many items.
* refresh by pull-down (iOS/iPadOS) or menu item (macOS); refreshing account lists starts a fresh session (works around an intermittently empty checked out list); keep the stale rows, dimmed, until the first page replaces them, and reload the open item's details.
* list items show availability, including "on order" copies (with a box symbol).
* an inspector shows item detail; on macOS its toggle is the rightmost toolbar button.
* item detail fetches "Availability by Location" in the background (collection and call number may be omitted); each copy has a colored symbol for its status (e.g., available, on order or in process, out, held, in transit, repair, missing, withdrawn, claims returned, library use only).
* item detail has a "Hold" button and pickup location menu (defaulting to the preferred location), or "Cancel Hold" for held items.
* drag part of item detail onto holds (any window's) to place a hold, or onto any window's search field to search for it; a stealth feature, so no drag hints.
* the account view, and a barcode toolbar button (in the sidebar's toolbar on macOS), show the library card number as a scannable Codabar barcode.
* the app version shows subtly at the foot of the sidebar and opens the platform's About box, which says in everyday words that people made Biblio working with AI assistants, and that it isn't made by BiblioCommons or the library.
* a bottom status bar shows the latest request as `TITLE [SIZE KiB]` (URL on hover), fading after 2 seconds of inactivity.
## settings
* on macOS, account settings live in the Settings window, not the sidebar.
* change email; change password (updating the Keychain); change pickup location and library language, saving on change and reverting on error.
* the library language is the account's preference, separate from the app's language; never set it automatically, but offer "Use System Language" to copy the closest supported system language.
* toggle borrowing history, confirming before turning it off (the library may delete history).
## authentication
* remember credentials in the Keychain; reauthenticate transparently when sessions expire (after inactivity, or when the same login signs in elsewhere, so allow at most one window per login).
* multiple windows with isolated sessions; each new window offers a menu of added libraries, then of that library's users.
* on macOS, windows restored at launch reopen their login, unless it was removed or is open elsewhere.
* guest sessions may browse with limited functionality (no holds or settings).
* when a guest tries to place a hold (button, drag, or multiple selection), present a lightweight sign-in sheet of the library's users plus "Add User…" (or the sign-in form if none); signing in converts the window, keeping its search, section, and selection; on iPhone, reopen the item sheet afterward.
* on macOS, a guest window's sidebar "Sign In" opens that sheet, and signed-in windows have no "Switch User or Library" (use File ▸ New Window); on iOS/iPadOS, the sidebar returns to the menus ("Sign In or Change Library" for guests, "Switch User or Library" otherwise).
* add a library by subdomain (e.g., "wccls") or URL (e.g., "https://smpl.bibliocommons.com/"), with autocompletions fetched in the background from https://www.bibliocommons.com/libraries-we-work-with and its "Next" pages.
* multiple libraries, each with multiple users.
* remove a library, confirming first if its users and passwords go too: a toolbar button on its user menu (replacing a redundant "Add User" button) and swipe or context menu in the library menu; disabled, with the reason, while one of its logins is open.
* libraries show square icons in the library menu and add-library suggestions: the website's large square icon, else the directory's partner logo trimmed of white margins, else a small favicon, else a brand-colored tile; cache icons on disk.
* hide "CMS" navigation (e.g., "About LIBRARY_NAME", "Using the Library", "Events & Activities") and item detail "Opinion".
## exploration and testing
* if logins exist in the Keychain, you may test with those accounts; use caution when making persistent changes to the account.
* if a .env file is present, it contains login information only to be used for the duration of answering this prompt.
* with a login, you may place holds and remove those holds; you may discover unheld "4K UHD Blu-Ray" format items using "On Order"; adding up to 25 more of these should hit the "too many holds" error; leave the preexisting holds alone.
* you may test changing each account setting, restoring the original value; don't turn borrowing history off on a real account.
* test detecting concurrent sessions with the same login.
* be gentle with the library website to avoid potential rate limiting.
## design
* follow the Apple Human Interface Guidelines for macOS, iOS, and iPadOS.
* panels and sheets must fit narrow iPhones (e.g., iPhone 13 mini); keep minimum widths to macOS.
* confirmation dialogs appear over the screen and control that asked for them.
* use [icon.png](icon.png) as the app icon: full-bleed on iOS, the standard rounded, shadowed shape on macOS.
* may use library branding colors, adjusted for contrast in light and dark mode (e.g., accent-colored toolbar buttons on a dark toolbar).
* may subtly color availability statuses, and list items by this account's status (on hold, ready for pickup, checked out, overdue).
* build without compiler warnings.
## documentation
* [README.md](README.md) for GitHub: features, requirements, building, project layout, and license (BSD 3-Clause).
* [NOTES-API.md](NOTES-API.md): the BiblioCommons gateway endpoints the app uses.
* [CHANGELOG.md](CHANGELOG.md): user-facing changes per version, with a `vX.Y` tag at each version bump.
## miscellaneous
* delete .zig-cache and zig-out when cleaning up the workspace
