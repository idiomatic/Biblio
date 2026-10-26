* write a native macOS/iOS/iPadOS app named "Biblio" using SwiftUI.
* the app is a patron front-end to the website https://LIBRARY.bibliocommons.com/
## views
* user can view holds.
* user can add items to hold.
* user can remove items from hold, unless the library disallows it (e.g., some libraries disallow cancelling "Ready for pickup" holds); explain why when it is disallowed, and handle partial refusals.
* user can view checked out items.
* user can search.
* user can advanced search.
* user can view borrowing history.
* user can Explore New Titles; skip the recent_arrivals grid and integrate the "Just Arrived" tab, "On Order" tab, and "Filter by" picker with the "View All New Titles" item list; the tabs may be redesigned as a filter.
* user can filter format in item list.
* user can filter the search item list (e.g., format, availability location, audience, content, language, publication date, date added).
* user can filter the hold item list by "Ready", "Not Ready", and "On Order"; each filter shows its count as a badge (not in parentheses).
* the sidebar badges the hold and checked out counts, fetched at launch without waiting for those lists to be opened.
* don't show an item count at the bottom of a list; the badges already show it.
* lists should do infinite scrolling instead of page navigation; pre-extend the scrollbar to the approximate length of the whole list (placeholder rows for unfetched pages), fetching only the pages that are actually viewed.
* user can change the sort order of a list of items; some sort orders may trigger background fetching of subsequent pages and animated item reordering.
* user can sort items by people waiting.
* user can select multiple items in item lists and place or cancel holds on all of them.
* user can refresh a list with a pull-down gesture (iOS/iPadOS) or a menu item (macOS); refreshing account lists starts a fresh session, as a workaround for an inconsistently empty checked out list.
* list items show the item's availability status, including "on order" copies.
* user can view details of any item in an inspector view pane; on macOS, the inspector toggle is the rightmost toolbar button.
* item detail fetches "Availability by location" in background; you can omit collection and call number columns.
* item detail has a "Hold" button with an appropriate symbol and a pickup location menu (defaulting to the account's preferred location), and a "Cancel Hold" button for items on hold.
* user can drag some part of item detail into hold to add item to hold, including the hold of another window.
* user can drag some part of item detail into any window's search field to perform search for item in that window.
* draggability is a stealth feature: don't add hints such as "Drag an item's cover here to place a hold" or a "Drag" label.
* the account view shows the library card number as a scannable Codabar barcode.
## settings
* on macOS, account settings live in a Settings menu item (Settings window) rather than the window's sidebar.
* can change account email address setting.
* can change account password setting; this should also update the Keychain.
* can change pickup location setting; save as soon as changed; reverting on error.
* can change language setting; save as soon as changed; reverting on error.
* can toggle borrowing history; confirm before turning it off, since the library may delete existing history.
## authentication
* the app should remember login credentials via Keychain.
* the app should reauthenticate transparently; sessions expire after inactivity; sessions also expire when another session uses the same login, so the app should avoid concurrent use of the same login (e.g., at most one window per login).
* the app can have multiple windows with isolated sessions (i.e., different logins).
* new windows should present a menu of added libraries and then a menu of added users for the selected library.
* on macOS, windows restored at launch reopen the login they had open (unless it was removed or is open in another window).
* the app may allow unauthenticated guest sessions, with appropriately limited functionality (e.g., unable to hold, unable to change backend settings).
* when a guest tries to place a hold (the item detail's "Sign In to Place a Hold…" button, a drag onto holds, or a multiple selection), present a lightweight sign-in sheet listing the library's added users plus "Add User…" (or the sign-in form directly when there are none); signing in turns that window into the user's session, keeping its search, section, and selected item; on iPhone, reopen the item sheet afterward.
* on macOS, a guest window's sidebar "Sign In" opens the same sign-in sheet, and signed-in windows have no "Switch User or Library" item (File ▸ New Window serves instead); on iOS/iPadOS, the sidebar returns to the library and user menus ("Sign In or Change Library" for guests, "Switch User or Library" otherwise).
* the "add a library" should only need to prompt a library subdomain (e.g., "wccls" or "multcolib") but may also parse the URL (e.g., "https://smpl.bibliocommons.com/"); the app could fetch (in the background) autocompletions from https://www.bibliocommons.com/libraries-we-work-with and the following "Next" pages.
* user can add multiple libraries.
* user can remove a library, after confirming that its saved users and passwords will be removed too; offer it as a toolbar button on the library's user menu (instead of redundant "Add User" toolbar button) and by swipe or context menu in the library menu; disable it while one of the library's logins is open in a window, and say why.
* libraries show a square icon in the library menu and in the add-library suggestions: prefer the library website's own large square icon (apple-touch-icon or a sized icon link), then the directory's partner logo trimmed of its white margins, then a small favicon, then a tile in the library's brand color; cache icons on disk so each site is asked once.
* user can use multiple user credentials per library.
* hide the navigation to "CMS" content (e.g., "About LIBRARY_NAME", "Using the Library", "Events & Activities", etc.)
* hide item detail "Opinion".
## exploration and testing
* if logins exist in the Keychain, you may test with those accounts; use caution when making persistent changes to the account.
* if a .env file is present, it contains login information only to be used for the duration of answering this prompt.
* with a login, you may place holds and remove those holds; you may discover unheld "4K UHD Blu-Ray" format items using "On Order"; adding up to 25 more of these should hit the "too many holds" error; leave the preexisting holds alone.
* you may test changing each account setting (email, password, pickup location, language), restoring the original value afterward; don't turn borrowing history off on a real account.
* test detecting concurrent sessions with the same login.
* be gentle with the library website to avoid potential rate limiting.
## design
* your app should follow "Apple Human Interface Guidelines" and "Designing for macOS" or "Designing for iOS" or "Designing for iPadOS".
* panels and sheets on iOS must fit narrow iPhones (e.g., iPhone 13 mini); keep minimum widths to macOS.
* confirmation dialogs should appear over the screen and control that asked for them.
* use icon.png for the app icon: full-bleed on iOS, and the standard rounded, shadowed macOS shape on macOS.
* your app may incorporate branding colors of the library websites; adjust them to keep enough contrast in both light and dark mode (e.g., accent-colored toolbar buttons on a dark toolbar).
* your app may add subtle coloring to the availability status values.
* your app may add subtle coloring to each list item to indicate this account's status of the item (e.g., on hold, ready for pickup, checked out, overdue).
* the project should build without compiler warnings.
## documentation
* write a README.md for GitHub: features, requirements, building, project layout, and license (BSD 3-Clause).
* list the BiblioCommons gateway endpoints the app uses in NOTES-API.md.
