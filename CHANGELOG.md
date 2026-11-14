# Changelog

Notable changes to Biblio. Versions follow the Apple app's version number; the other apps share
the core and are not yet released.

## 1.10 — 2026-11-12

### Fixed
- 4K Ultra HD Blu-ray discs no longer read "Unknown" at libraries, such as WCCLS, that file them
  as Blu-ray (since 1.9).
- On a Mac, dragging a list's scroll bar no longer opens the hidden item details pane.
- Android: item details and password changes work again, and Biblio uses the system's network
  settings, including your certificate authorities, proxies, and VPNs.
- Android: refined formats such as 4K Ultra HD Blu-ray are counted exactly, and Borrowing
  History sorts by when you borrowed each item.
- Android: the app no longer crashes loading its native library at launch.
- Android: rotating the screen no longer signs in again, switching sections with an item open
  shows the new section, and a saved password that can't be read asks for it again.
- Windows: Cancel Hold confirms beside the button, notices close themselves, search shows
  Cancel Hold for an item already on hold, and a failed library-directory load is retried.
- GNOME: Cancel Hold asks first, a failed sign-in offers Try Again, the window fits 360 px,
  and a library or user open in a window can't be removed.

### Changed
- Item details no longer offer a pickup location beside Hold, which read as changing a hold's
  location; holds go to your preferred pickup location, set on your card's page.
- A hold's pickup location moved from its row in Holds to its item details, below its status.
- In a window with several cards, Search and New Titles show each card's chip at the right of
  a row, as Holds does, instead of before its hold or checkout.

### Added
- Android: rows show the edition, copies on order, and a colored label for your hold,
  checkout, or due date; the Format filter counts each format exactly.
- Android: long-press to select several items, then place or cancel holds on all of them, with
  the reason for any the library refuses.
- Android: a guest who places a hold picks or adds a card, keeping the search and selection.
- Android: New Titles filters by Just Arrived and On Order, and by audience, language, and
  more; Advanced Search narrows by field, format, audience, language, and year.
- Android: the account screen chooses Codabar or Code 128 per library, swipes between the
  library's cards, and offers Use System Language.
- Android: About says who made Biblio and has Copy Diagnostic Log, with the version at the foot
  of the Libraries and Account screens.
- Android: a new launcher icon, and a theme that follows light and dark mode.
- Windows: rows show the edition, copies on order, and a colored label for your hold,
  checkout, or due date, and the Format filter counts each format exactly.
- Windows: select several items to place or cancel holds on all of them.
- Windows: New Titles filters by Just Arrived and On Order, and by audience, language, and
  more.
- Windows: the account page chooses Codabar or Code 128 and offers Use System Language.
- Windows: a guest who places a hold picks or adds a card; About says who made Biblio and has
  Copy Diagnostic Log; a status bar shows the latest request.
- GNOME: rows show the edition, copies on order, and a colored label for your hold,
  checkout, or due date.
- GNOME: select several items to place or cancel holds on all of them, from a bar at the
  bottom.
- GNOME: a guest who places a hold picks or adds a card, keeping the search and the item.
- GNOME: Advanced Search, and filters by availability, audience, content, language, and
  date; New Titles filters by Just Arrived and On Order.
- GNOME: a main menu with About, Keyboard Shortcuts, and Copy Diagnostic Log; a Library Card
  button; a status bar; and Ctrl+R, F5, Ctrl+F, Ctrl+W, and Ctrl+Q.

## 1.9 — 2026-11-12

### Added
- Items you've borrowed before are marked in search, New Titles, and holds, and item details say
  when ("You borrowed this in March 2024 · 3 times"). The same title in another format is marked
  more faintly and named ("Borrowed on DVD"). A Not Borrowed filter hides what you've already
  borrowed in that format. Biblio reads your borrowing history in the background and keeps it
  privately on the device, only while the library keeps it; Refresh Borrowing History on your
  card's page reads it all again.
- 4K Ultra HD Blu-ray shows as its own format where a library files it as Blu-ray, and search can
  filter by it.
- Each card has an Appearance section on its page: choose its color and monogram, which mark its
  items when several cards show together.
- A library with two or more saved cards lists each in the sidebar with a switch to include it in
  your holds, checked out items, and history. Turn on several to see their items together, each
  marked with its card's colored initial. The library menu is the bottom of the stack, reached with the back button, and opening a library shows the cards you last had on, unless another window has them.
- With only one library card saved, Biblio opens straight into your account, without the library
  and user menus. The sidebar lists your card with Add Card, and the account page offers Use a Different Library and Sign Out.
- On iPhone and iPad, signing in has a Scan button that reads the Codabar or Code 128 barcode on
  your physical library card into the card number field. Biblio asks for camera access the
  first time.

### Changed
- On Mac, account settings are on each card's page in the sidebar, and the Settings window is
  gone: it showed whichever card the window had last used, which was easy to mistake for another.
- On Mac, the toolbar's library card button is gone: nobody brings a Mac to the checkout desk.
  Each card's page still shows its barcode.
- In a window with several cards, search and New Titles mark every card's hold or checkout on an item, each with its card's chip. They marked only the card that ran the search, so the status seemed to come and go. The split Hold button's drop-down no longer repeats the card on the button.
- In a window with several cards, holds, checked out items, and history sorted by Title or Author now interleave the cards by title or author, each card keeping the library's order (they interleaved by position before).
- In a window with several cards, holds sorted by Status show every ready hold first, then in transit, not yet available, and paused, across cards (they interleaved by position before).
- Signing a guest in lists the library's saved cards with their chip and name, and the login underneath.
- On iPad, the Sign In and Add Library sheets no longer hop while you type: they are page sheets, which stay put as the keyboard, the Passwords bar, and the library suggestions change.
- "Hold for …" and the other card names in a window with several cards use the account holder's first name from the library (Kazuko, not kazuko_walib). Each card's page has a Name field to change it, such as to an initial.
- An item with no holds shows just its copies ("4 copies"), not "0 holds on 4 copies".
- In a window with several cards, an item's author link and a search dropped onto the search field now show their results (they did nothing).
- An item's availability, on-order note, and people waiting wrap as whole pieces on a narrow screen, with a small people icon instead of a leading dot.
- On iPad, after the item details are dismissed (or hidden by rotating to portrait), tapping the same row shows them again.
- On a narrow iPhone, a hold's status, place in line, and pickup location wrap onto further lines
  (the location marked with a pin) instead of squeezing each other; an item's availability by
  location and its Details table stack their labels over their values; status icons sit close to
  their text; Advanced Search gives each term's text the full row; a long pickup name moves the Hold button below it; a row's format and edition use two lines instead of cutting off; an item's details keep a readable width in landscape and fit a narrow iPad pane; the status bar's text clears the screen's rounded corners.
- On Mac, saved passwords and library cards move to the data-protection keychain the first time
  they're read, and stay on this device (no backup restores or syncing). If a password can't be
  saved after you change it, Biblio says so.
- The GNOME list shows placeholder rows while pages load, sorts by People Waiting and Title,
  filters holds by Ready, Not Ready, and On Order with counts, filters account lists by format,
  refetches a list shown again after 15 minutes, and has a Refresh button.
- The Android lists do the same, with pull to refresh, and no longer show an item count.
- The Windows lists do the same, with a Refresh button and Ctrl+R.
- The GNOME account page chooses Codabar or Code 128 for the library card, remembered per
  library, and offers Use System Language.
- The terminal app chooses a pickup location when placing a hold (starting on your preferred
  one), sorts by People Waiting and Title, filters by format and holds by Ready, Not Ready, and
  On Order, places or cancels holds on several items marked with Space, changes account
  settings on the Account tab, and shows your card as a Codabar or Code 128 barcode. Its lists
  load only the pages you look at, and its prompts can be edited with the cursor keys.
- The terminal app names each hold's status (In transit, Paused, or On hold) instead of "On
  hold" for all, and placing holds on several items stops at the library's hold limit.
- The terminal app no longer sets the library's language from your system language; it offers
  Use System Language instead.

### Fixed
- A library outage or rate limit while signing in no longer reads as "Check the username and PIN".
- Changing an account setting after the library's web session expired signs in again and retries
  instead of reporting a save that didn't happen.
- Redirects to another site no longer carry your session credentials.
- Android 10 and 11 no longer crash at launch, and closing a session no longer crashes an
  in-flight request.
- The terminal app puts your terminal back after a crash or kill signal, and Ctrl+Z suspends it.
- The terminal app lines up CJK text and emoji, keeps stray control characters in catalog text
  from garbling the screen, reads arrow keys and accented characters that arrive in pieces, and
  keeps long searches and usernames instead of dropping them.
- The GNOME Add Library window no longer crashes if closed while the directory loads.
- In the GNOME app, saving your email while changing your password no longer saves a password
  the library hasn't accepted, and changing the library language reloads the catalog in the
  new language.
- iPad offers the Control Center card control too.
- On iPhone and iPad, the Lock Screen and Control Center card control works when the only
  window is a guest's, and on Mac, opening the card link no longer opens a new window each time.
- On iPhone, item details have a title and a Done button, and each copy shows its collection
  and call number.
- Swiping to remove a library works while another library is open.
- The confirmations for turning off borrowing history and for signing out appear over the
  control that asked.
- Library card barcodes draw with sharp bar edges, which scanners read more reliably.
- On iPhone, the holds filter scrolls instead of overflowing at large text sizes, VoiceOver
  reads banners and names the Advanced Search menus, and counts in messages are pluralized.
- "Couldn't Sign In" no longer reappears the moment you tap Try Again.
- On iPhone, Sign In to Place a Hold in an item's details opens the sign-in sheet (it did
  nothing), and canceling it returns to the item.
- An item's edition statement shows in any library language, not only English.
- Filtering a search to 4K Ultra HD Blu-ray no longer also lists the plain Blu-ray.
- Choosing a search filter no longer shows a clipped sliver of its name while the menu closes.
- On iPad, the toolbar's library card shows the whole card, not a sliver of its barcode.
- In a window with several cards, item details keep their margins when each card's hold has a
  Cancel Hold button, which moves below the hold when it doesn't fit beside it.
- On iPhone and iPad, a selected list row is a rounded highlight inset from the column's
  edges, like the sidebar's, so it no longer smears behind the sidebar and item details.
- Items with the same title no longer swap places each time a list sorts by title.
- A library's error message shows in full, not just its first bold word.
- Placing many holds stops cleanly once the library's hold limit is reached.
- Copies whose status merely mentions an order (such as "Reservation order") no longer show as
  on order.
- French, Spanish, Italian, and German edition statements keep their abbreviations' periods.
- A library's own name for a format is used when it has one.
- Canceling holds before the whole list has loaded no longer leaves items missing.
- Expired cookies are dropped whatever their year, and a library's error that merely mentions a
  session no longer signs you in again.
- Downloads are faster on GNOME, Windows, Android, and in the terminal.
- After you place or cancel a hold, the item's details and its search row show the new number
  of people waiting, and the search row shows your place in line right away (it showed the old
  count, and "On hold" without your place until the search was shown again).
- Search's Format menu counts 4K Ultra HD Blu-ray discs once all the results are in, and no
  longer counts them under Blu-ray Disc too.
- On iPhone, the library card sheet fits the card, without empty space below it.
- The status bar at the bottom of the window fades even if a request never reports back,
  instead of staying up until the next refresh.
- In a window with several cards, Holds has the Ready, Not Ready, and On Order bar with counts
  for all the cards, as a single card's Holds does, and Borrowing History lists every card's
  items newest first (it mixed up the dates).

## 1.8 — 2026-11-09

### Fixed
- The item inspector shows every edition statement of the record ("Collector's edition ·
  4K Ultra HD + Blu-ray edition"), not just the first, and the Details table drops the catalog
  brackets and closing periods from them too.

## 1.7 — 2026-11-04

### Changed
- The library card barcode type (Codabar or Code 128) is chosen only in the account view, and
  remembered per library. The card popup shows the library's choice.
- On iPhone and iPad, swiping the library card rotates between the logins of that library only.
- On iPhone in landscape, the library card barcode is larger.
- Sorting by title ignores accents and ligatures, so "Émile" sorts with "Emile" instead of
  after "Zoolander".
- In advanced search, 4K Ultra HD Blu-ray sorts with the other formats in the Format menu.

## 1.6 — 2026-11-04

### Added
- The Android and Windows (x64 and ARM64) apps build for the first time, checked by continuous
  integration. They are still unreleased and untested on devices.

### Fixed
- On the Mac, switching sections in the sidebar is faster when a list holds many items.

## 1.5 — 2026-11-02

### Added
- The library card barcode can be shown as Code 128 as well as Codabar, for scanners that don't
  read Codabar. Your choice sticks for every card.
- On iPhone, a Library Card control for the Lock Screen and Control Center opens the card's
  barcode for the account you used last.
- On iPhone and iPad, swipe left or right on the library card to rotate between your logins'
  cards.

### Fixed
- On iPhone and iPad, the Add Library and Add User sheets focus their first field when they open,
  and Add User accepts typing.

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
- The core now handles list paging, sorting, and filtering for every app (`biblio_list_*`).

### Fixed
- After a restored launch on iPhone, the sidebar no longer sits under its title.
- On macOS, a guest who signs in keeps the sidebar's toolbar buttons.
- The holds filter bar has even space above and below.

## 1.2 — 2026-10-27

### Added
- libbiblio, a shared core in Zig with a typed C interface, which the Apple app now runs on.
- Apps for GNOME (GTK 4 and libadwaita), Android (Jetpack Compose), Windows (WinUI 3), and the
  terminal, built on the core. Only the Apple app has been run so far.
- Raspberry Pi builds of the core, the terminal app, and the GNOME app.
- Library icons on every graphical platform, found by the core.
- README screenshots for macOS, iPadOS, and iOS.

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
- Biblio for macOS, iOS, and iPadOS: a patron app for any BiblioCommons library.
- Holds, checked out items, and borrowing history.
- Search, advanced search, and new titles.
- An inspector with item details and availability by location.
- Multiple windows with separate sessions, credentials in the Keychain, and guest browsing.
- Account settings.
