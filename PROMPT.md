* write a native macOS/iOS/iPadOS app using SwiftUI.
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
* user can filter the hold item list by "Ready", "Not Ready", and "On Order".
* lists should do infinite scrolling (instead of page navigation); pre-extend the scrollbar to the approximate length of the whole list (placeholder rows for unfetched pages), fetching only the pages that are actually viewed.
* user can change the sort order of a list of items; some sort orders may trigger background fetching of subsequent pages and animated item reordering.
* user can sort items by people waiting.
* user can select multiple items in item lists and place or cancel holds on all of them.
* user can refresh a list with a pull-down gesture (iOS/iPadOS) or a menu item (macOS); refreshing account lists starts a fresh session, as a workaround for an inconsistently empty checked out list.
* the item count at the bottom of a list reflects the active filters.
* list items show the item's availability status, including "on order" copies.
* user can view details of any item in an inspector view pane.
* item detail fetches "Availability by location" in background; you can omit (or hide into a tooltip) collection and call number columns.
* item detail has a "Hold" button with an appropriate symbol, and a "Cancel Hold" button for items on hold.
* user can drag some part of item detail into hold to add item to hold, including the hold of another window (macOS).
* user can drag some part of item detail into any window's search field to search item in that window.
* draggability is a stealth feature: don't add hints such as "Drag an item's cover here to place a hold" or a "Drag" label.
* the account view shows the library card number as a scannable Codabar barcode.
## settings
* on macOS, account settings live in a Settings menu item (Settings window) rather than the window's sidebar.
* can change account email address setting.
* can change account password setting; this should also update the Keychain.
* can change pickup location setting.
* can change language setting.
* can turn borrowing history on or off (confirm before turning it off, since the library may delete existing history).
## authentication
* the app should remember login credentials via Keychain.
* the app should reauthenticate transparently; sessions expire after inactivity; sessions also expire when another session uses the same login, so the app should avoid concurrent use of the same login (e.g., at most one window per login).
* the app can have multiple windows with isolated sessions (i.e., different logins or different partially-fetched search result lists).
* new windows should present a menu of added libraries and then a menu of added users for the selected library.
* the app may allow unauthenticated guest sessions, with appropriately limited functionality (e.g., unable to hold, unable to change backend settings).
* the "add a library" should only need to prompt a library subdomain (e.g., "wccls" or "multcolib") but may also parse the URL (e.g., "https://smpl.bibliocommons.com/"); the app could fetch (in the background) autocompletions from https://www.bibliocommons.com/libraries-we-work-with and the following "Next" pages.
* user can add multiple libraries.
* user can use multiple user credentials per library.
* hide the navigation to "CMS" content (e.g., "About LIBRARY_NAME", "Using the Library", "Events & Activities", etc.)
* hide item detail "Opinion".
## exploration and testing
* the .env file contains login information only for the duration of answering this prompt.
* you may place holds and remove those holds; you may discover unheld "4K UHD Blu-Ray" format items using "On Order"; adding up to 25 more of these should hit the "too many holds" error; leave the preexisting holds alone.
* you may test changing each account setting (email, password, pickup location, language), restoring the original value afterward.
* test detecting concurrent sessions with the same login.
* be gentle with the library website to avoid potential rate limiting.
## design
* your app should follow "Apple Human Interface Guidelines" and "Designing for macOS" or "Designing for iOS" or "Designing for iPadOS".
* panels and sheets on iOS must fit narrow iPhones (e.g., iPhone 13 mini); keep minimum widths to macOS.
* your app may incorporate branding colors of the library websites; adjust them to keep enough contrast in both light and dark mode (e.g., accent-colored toolbar buttons on a dark toolbar).
* your app may add subtle coloring to the availability status values.
* your app may add subtle coloring to each list item to indicate this account's status of the item (e.g., on hold, ready for pickup, checked out, overdue).
