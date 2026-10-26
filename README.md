# Biblio

<img src="icon.png" alt="Biblio app icon" width="128" align="right">

A native SwiftUI app for macOS, iOS and iPadOS that works as a patron front end to any
public library catalog hosted on [BiblioCommons](https://www.bibliocommons.com/libraries-we-work-with)
(`https://LIBRARY.bibliocommons.com/`).

Search the catalog, place and cancel holds, and keep track of checkouts and borrowing
history, all in a native interface that follows Apple's Human Interface Guidelines and
picks up each library's brand colors.

> Biblio is an independent project and isn't affiliated with or endorsed by BiblioCommons
> or any library.

## Features

**Catalog**
- Search and advanced search (keyword, title, author, subject, …), with filters for format,
  availability location, audience, content, language, publication date and date added.
- Explore New Titles: Just Arrived and On Order, with the library's "Filter by" options.
- Infinite scrolling. The scroll bar starts at the full list length, and only the pages you
  actually scroll to are fetched.
- Sort orders, including by number of people waiting.
- An inspector with item details and copy availability by location, loaded in the background.

**Your account**
- Holds: place, cancel (where the library allows it) and filter by Ready, Not Ready and On Order,
  with count badges.
- Checked out items and borrowing history, with counts in the sidebar.
- Select several items in a list to place or cancel holds on all of them at once.
- List rows are subtly tinted to show your status for each item: on hold, ready for pickup,
  checked out or overdue.
- Your library card as a scannable Codabar barcode.
- Settings for email, password, pickup location, language and borrowing history. On macOS they
  live in the Settings window.

**App**
- Multiple windows, each with its own session: different libraries, different accounts, or
  different searches side by side.
- Add a library by its subdomain (`wccls`) or URL, with autocomplete from the BiblioCommons
  directory.
- Credentials are stored in the Keychain, and expired sessions are renewed without
  interrupting you. The app avoids signing in to the same account in two windows at once,
  because the library would end the first session.
- Guest browsing without an account.
- Pull to refresh on iOS and iPadOS; View ▸ Refresh (⌘R) on macOS.
- Drag an item's cover onto Holds to place a hold, or onto a search field to search for it.
  On macOS this also works across windows.

## Requirements

- Xcode 26 or later
- macOS 15 or later, or iOS / iPadOS 18 or later

## Building

1. Open `Biblio.xcodeproj` in Xcode.
2. Choose the **Biblio** scheme and a destination (My Mac, an iPhone or iPad simulator, or a device).
3. Change the signing team under **Signing & Capabilities** to your own.
4. Build and run (⌘R).

To try it, add a library such as `wccls` or `multcolib`, then sign in with a library card and
PIN, or choose **Browse as Guest**.

## Project layout

| Folder | Contents |
|---|---|
| `Biblio/Model` | Data models, per-window session state, and the paged list model that drives infinite scrolling |
| `Biblio/Net` | `BiblioClient` (an actor that handles sign-in and re-authentication), the gateway API calls, account-settings form handling, request throttling, and the library directory |
| `Biblio/Store` | Keychain access, and the saved libraries with their branding |
| `Biblio/Views` | SwiftUI views |

The app uses the same gateway API as the BiblioCommons web app. Account settings go through
the website's own forms. [NOTES-API.md](NOTES-API.md) lists the endpoints. Requests are
throttled to be gentle on library servers.

## How it was made

Biblio was written with [Claude Code](https://claude.com/claude-code).
[PROMPT.md](PROMPT.md) is the original request, and [PROMPT_AFTER.md](PROMPT_AFTER.md)
restates it with the changes made along the way.

## License

[BSD 3-Clause](LICENSE)
