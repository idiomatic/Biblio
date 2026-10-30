# Changelog

Notable changes to Biblio. Versions follow the Apple app's version number; the other apps share
the core and are not yet released.

## 1.4 — 2026-10-29

### Added
- List items show the edition after the format and year.

### Changed
- Editions read as written, without the square brackets and closing period of library
  catalogs ("[First edition]." reads "First edition", "4K Ultra HD [edition]" reads
  "4K Ultra HD edition").
- Switching sections closes the item inspector, instead of leaving the last list's item open.

## 1.3 — 2026-10-29

### Added
- An About box: Biblio ▸ About Biblio on macOS, and the version at the foot of the sidebar on
  every Apple platform.
- The app version at the foot of the sidebar.
- Use System Language in the library language menu, which sets the account's language to the
  closest one the library offers.
- A barcode toolbar button that shows the library card (in the sidebar's toolbar on macOS).

### Changed
- Account ▸ Language is now Library Language, with a note that it's separate from the device's
  language.
- Refreshing a list dims it until the new rows arrive, instead of blanking it.
- Refreshing a list also reloads the open item's availability and details.
- On iPhone, multiple selection uses a bottom bar with only the actions that apply, and item
  details show as a sheet.
- Checked Out and Borrowing History select one item at a time.
- The core now handles list paging, sorting and filtering for every app (`biblio_list_*`).

### Fixed
- After a restored launch on iPhone, the sidebar no longer sits under its title.
- On macOS, a guest who signs in keeps the sidebar's toolbar buttons.
- The holds filter bar has even space above and below.

## 1.2 — 2026-10-27

### Added
- libbiblio, a shared core in Zig with a typed C interface, which the Apple app now runs on.
- Apps for GNOME (GTK 4 and libadwaita), Android (Jetpack Compose), Windows (WinUI 3) and the
  terminal, built on the core. Only the Apple app has been run so far.
- Raspberry Pi builds of the core, the terminal app and the GNOME app.
- Library icons on every graphical platform, found by the core.
- README screenshots for macOS, iPadOS and iOS.

### Changed
- Guests sign in from a toolbar button, and guest lists select one item at a time.
- Removing a library asks for confirmation only when it would also delete saved users and
  passwords.

## 1.1 — 2026-10-27

### Added
- Library icons in Choose a Library and in Add Library suggestions, cached on disk.
- Removing a library, disabled while a window is signed in to it.
- Guest sign-in when placing a hold, keeping the search and selected item.
- On macOS, windows restored at launch reopen their login.
- A fading status bar showing the latest request to the library.
- A symbol and color for each copy status in item details.

### Changed
- Item lists are fetched again when shown more than 15 minutes after loading.
- Pickup location and language save as soon as they change.
- Lists no longer show an item count footer.

## 1.0 — 2026-10-25

### Added
- Biblio for macOS, iOS and iPadOS: a patron app for any BiblioCommons library.
- Holds, checked out items and borrowing history.
- Search, advanced search and new titles.
- An inspector with item details and availability by location.
- Multiple windows with separate sessions, credentials in the Keychain, and guest browsing.
- Account settings.
