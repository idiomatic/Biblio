# Biblio

<img src="icon.png" alt="Biblio app icon" width="128" align="right">

Native apps for macOS, iOS, iPadOS, GNOME, Android, Windows, and the terminal that work as a
patron front end to any public library catalog hosted on
[BiblioCommons](https://www.bibliocommons.com/libraries-we-work-with)
(`https://LIBRARY.bibliocommons.com/`).

Search the catalog, place and cancel holds, and keep track of checkouts and borrowing
history, all in an interface that follows each platform's own design. The apps share one
core, libbiblio, written in Zig ([developer guide](core/README.md)), and each has a native UI.
[CHANGELOG.md](CHANGELOG.md) lists what changed in each version.

> Biblio is an independent project and isn't affiliated with or endorsed by BiblioCommons
> or any library.

## Screenshots

One patron's visit, from first launch to checking on returns, in the Apple apps. The library, account, and card are made up; the titles and covers come from a real catalog.

### Get started

<table>
<tr>
<td><img src="docs/screenshots/iphone-01-welcome.png" alt="Adding a library by name, with FirstLanding Public Library suggested" width="300"></td>
<td><img src="docs/screenshots/iphone-02-sign-in.png" alt="Signing in with a library card number and PIN" width="300"></td>
</tr>
<tr>
<td align="center">Add your library</td>
<td align="center">Sign in</td>
</tr>
</table>

### Find and hold

<table>
<tr>
<td><img src="docs/screenshots/iphone-03-search.png" alt="Search results for a Sanctuary Moon box set, with the format filter open and its counts" width="220"></td>
<td><img src="docs/screenshots/iphone-04-detail.png" alt="The Rise and Fall of Sanctuary Moon on DVD, with its copies by location and a Hold button" width="220"></td>
<td><img src="docs/screenshots/iphone-05-hold.png" alt="The hold placed, with a Cancel Hold button" width="220"></td>
<td>
<picture>
<source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/android-coming-soon-dark.png">
<img src="docs/screenshots/android-coming-soon.png" alt="Sketch of the Android app, coming soon" width="220">
</picture>
</td>
</tr>
<tr>
<td align="center">Search with filters</td>
<td align="center">Copies by location</td>
<td align="center">Hold placed</td>
<td align="center">Android</td>
</tr>
</table>

<table>
<tr>
<td width="60%"><img src="docs/screenshots/ipad-04-detail.png" alt="Search results for Martha Wells on iPad, with Rogue Protocol and its copies by location in the inspector"></td>
<td><img src="docs/screenshots/windows-04-detail.png" alt="Search results for Martha Wells in the Windows app, with Rogue Protocol and its copies by location in the detail pane"></td>
<td>
<picture>
<source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/gnome-coming-soon-dark.png">
<img src="docs/screenshots/gnome-coming-soon.png" alt="Sketch of the GNOME app, coming soon">
</picture>
</td>
</tr>
<tr>
<td align="center">iPadOS: details in the inspector</td>
<td align="center">Windows: details in the pane</td>
<td align="center">GNOME</td>
</tr>
</table>

### Pick up

<table>
<tr>
<td><img src="docs/screenshots/iphone-06-holds.png" alt="Holds, with the ones ready for pickup first" width="220"></td>
<td><img src="docs/screenshots/iphone-07-card.png" alt="The library card as a scannable barcode" width="220"></td>
<td width="58%"><img src="docs/screenshots/ipad-06-holds.png" alt="Holds on iPad, with a ready Murderbot book in the inspector"></td>
</tr>
<tr>
<td align="center">Holds, ready first</td>
<td align="center">Library card</td>
<td align="center">iPadOS</td>
</tr>
</table>

### Keep track

<table>
<tr>
<td><img src="docs/screenshots/iphone-08-checked-out.png" alt="Checked out films by due date, one overdue" width="220"></td>
<td><img src="docs/screenshots/iphone-09-history.png" alt="Borrowing history" width="220"></td>
<td width="58%"><img src="docs/screenshots/ipad-08-checked-out.png" alt="Checked out books on iPad, with an overdue All Systems Red in the inspector"></td>
</tr>
<tr>
<td align="center">Checked out</td>
<td align="center">Borrowing history</td>
<td align="center">iPadOS</td>
</tr>
</table>

## Features

**Catalog**
- Search and advanced search (keyword, title, author, subject, …), with filters for format,
  availability location, audience, content, language, publication date, and date added.
  - The terminal app has neither advanced search nor facets yet.
- Explore New Titles: Just Arrived and On Order, with the library's "Filter by" options.
- Infinite scrolling. The scroll bar starts at the full list length, and only the pages you
  actually scroll to are fetched.
- Sort orders, including by number of people waiting, and by title, ignoring case and accents
  and putting "Book 2" before "Book 10".
- An inspector with item details and copy availability by location, loaded in the background.

**Your account**
- Holds: place, cancel, and filter by Ready, Not Ready, and On Order, with count badges.
- Checked out items and borrowing history, with counts in the sidebar.
- Select several items in a list to place or cancel holds on all of them at once.
- List rows are subtly tinted to show your status for each item: on hold, ready for pickup,
  checked out, or overdue.
- Your library card as a scannable Codabar or Code 128 barcode, one toolbar button away, or on iPhone from a
  Lock Screen or Control Center control. Choose the barcode type for each library in the account view; swipe between that library's logins' cards.
- On iPhone and iPad, sign in by scanning the barcode on your physical library card with the camera.
- Settings for email, password, pickup location, language, and borrowing history. On macOS they
  live in the Settings window.
  - The terminal app only shows them.

**App**
- Multiple windows, each with its own session: different libraries, different accounts, or
  different searches side by side.
  - The terminal app runs one session per process.
- Add a library by its subdomain (`wccls`) or URL, with autocomplete from the BiblioCommons
  libraries directory.
- Credentials are stored in the Keychain, and expired sessions are renewed without
  interrupting you.
  - GNOME uses the Secret Service, Android the Keystore, and Windows the Credential Locker.
    The terminal app doesn't save passwords.
- Guest browsing without an account.
- Pull to refresh on iOS and iPadOS; View ▸ Refresh (⌘R) on macOS.
- The version at the foot of the sidebar opens the About box (also Biblio ▸ About Biblio on macOS).
- Drag an item's cover onto Holds to place a hold, or onto a search field to search for it.
  On macOS this also works across windows.
  - The terminal app has no drag and drop.

## Requirements

| Platform | Needs |
|---|---|
| All | Zig 0.17 |
| macOS, iOS, iPadOS | Xcode 26 or later; runs on macOS 15 or later, or iOS / iPadOS 18 or later |
| GNOME | GTK 4, libadwaita 1.6 or later, libsecret |
| Android | The Android SDK and a JDK |
| Windows | The .NET 10 SDK and the Windows App SDK |
| Terminal | Nothing more; any xterm-256color terminal on macOS or Linux |

The GNOME and terminal apps also cross-compile for 64-bit Raspberry Pi OS.

## Building

The core's tests: `cd core && zig build test`. Then, per platform:

| Platform | Steps |
|---|---|
| Apple | Open `apple/Biblio.xcodeproj`, choose the **Biblio** scheme, set your signing team, and build. Run `apple/build-core.sh` once after a fresh clone, so Xcode finds the core's xcframework. |
| GNOME | `cd gnome && zig build run` |
| Android | `cd android && gradle installDebug` |
| Windows | `cd windows/Biblio && dotnet build -p:Platform=x64` |
| Terminal | `cd tui && zig build run` |

`zig build cross` at the root cross-compiles the core for Linux, Windows, and Android, plus
the GNOME app for Linux. The GNOME app builds against Debian sysroots that
`gnome/debian-sysroot.sh` downloads, so it also targets 64-bit Raspberry Pi OS.

To try it, add a library such as `wccls` or `multcolib`, then sign in with a library card and
PIN, or choose **Browse as Guest**.

## Project layout

| Folder | Contents |
|---|---|
| `core` | libbiblio, the shared Zig core, its C header, and its [developer guide](core/README.md) |
| `apple` | The SwiftUI app for macOS, iOS, and iPadOS |
| `gnome` | The GTK 4 and libadwaita app, in Zig |
| `android` | The Jetpack Compose app, and its Zig JNI shim |
| `windows` | The WinUI 3 app, in C# |
| `tui` | The terminal app, in Zig |
| `docs` | Screenshots and external specifications |
| `tools` | Developer tools: `blur.swift` blurs private details in screenshots, and `coming-soon.swift` draws the placeholder sketches |

Inside the Apple app:

| Folder | Contents |
|---|---|
| `apple/Biblio/Model` | Data models, per-window session state, and the list model that fetches pages for the core's item list |
| `apple/Biblio/Net` | `BiblioClient` (an actor that handles sign-in and re-authentication), the gateway API calls, account-settings form handling, request throttling, and the library directory |
| `apple/Biblio/Store` | Keychain access, and the saved libraries with their branding |
| `apple/Biblio/Views` | SwiftUI views |

The app uses the same gateway API as the BiblioCommons web app. Account settings go through
the website's own forms. [NOTES-API.md](NOTES-API.md) lists the endpoints. Requests are
throttled to be gentle on library servers.

## How it was made

Biblio was written with [Claude](https://claude.com).

## License

[BSD 3-Clause](LICENSE)
