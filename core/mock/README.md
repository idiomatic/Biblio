# Mock library

A fictional library, FirstLanding Public Library, for screenshots and demos, themed on Martha Wells's Murderbot Diaries. Setting `BIBLIO_MOCK` to a fixtures directory puts [mock.zig](../src/mock.zig) in front of libbiblio's transport: the gateway and website of the `firstlanding` library are served from these files, and every other request goes to the real transport. Every app but Android gets it, because the core owns the transport.

It is compiled out of `ReleaseFast` and `ReleaseSmall` builds, and out of every Android build, so shipped apps and the Android app ignore the variable. (Outside Windows it also needs libc, which every app's Debug and ReleaseSafe build links.)

## Using it

```sh
BIBLIO_MOCK=$PWD/core/mock/video  open Biblio.app    # DVD, Blu-ray, 4K (with a fictional serial, Sanctuary Moon)
BIBLIO_MOCK=$PWD/core/mock/books  open Biblio.app    # Murderbot and other science-fiction books
```

* iOS simulator: `SIMCTL_CHILD_BIBLIO_MOCK=… xcrun simctl launch DEVICE com.rbrian.Biblio`.
* Add the library by typing `first`, then sign in as `perihelion` or `gurathin` (a second patron, with her own holds, checkouts, and history) with any password (the password `wrong` fails). A patron can also sign in by card number (`21168012345678`, `21168087654321`); any other username is refused, as a typo would be. Signing in with the password `boom`, or launching with `BIBLIO_MOCK_BOOM` set, makes holds fail the way a real library has: the hold is placed, then answered with a 500.
* Holds, settings, and borrowing history change in memory; relaunching resets them.
* The Mac app is sandboxed, so it can't read fixtures from an arbitrary folder (it says "fixtures not loaded" and uses the real network). Put the fixtures inside the app (`Biblio.app/Contents/Resources/mock`), re-sign it (`codesign --force --deep --sign - --preserve-metadata=entitlements`), and point `BIBLIO_MOCK` at `…/Resources/mock/books`.
* Titles, covers, and call numbers come from a real catalog; covers load from their live URLs, so the network is needed.

## Files

| File | Holds |
|---|---|
| `shared/library.json` | name, brand color, labels, branches, and the patrons (`patron`, then `patrons`) |
| `video/`, `books/` | a theme: `catalog.json` (titles, copies by branch, people waiting, new or on order), `account.json` and `account-2.json` (each patron's holds, checkouts, history, as day offsets from today; neither holds a title the other does, since a list row shows one card's chip; `perihelion`'s history includes a title held again and, in books, a held title's audiobook, for "borrowed before") |

Each catalog also carries in-universe media in other formats, appended after the main titles: Murderbot audiobook CDs, the fictional serial's soundtrack (`Music CD`), and large print where the source library has it. The books theme also has, as new arrivals, the formats of a library's New Titles: eBook and Downloadable Audiobook (`materialType` `DIGITAL`, their copies licenses at "Online"), Graphic Novel, Picture Book, and soundtrack Music CDs.

`generate.mjs` rebuilds `video/` and `books/` from a live library's public catalog (`node generate.mjs [subdomain]`, default `wccls`), inventing the copies and the account deterministically. `node generate.mjs --append` adds only the books theme's other formats to its existing catalog, leaving everything else as it is.

## Not covered

Account settings pages (the website, which carries no token) act on the patron who signed in last.

Advanced search, other account settings than email, pickup location, language, and borrowing history, and paging past 25 rows of search results beyond the fixtures' size.
