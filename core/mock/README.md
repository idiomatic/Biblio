# Mock library

A fictional library, FirstLanding Public Library, for screenshots and demos, themed on Martha Wells's Murderbot Diaries. Setting `BIBLIO_MOCK` to a fixtures directory puts [mock.zig](../src/mock.zig) in front of libbiblio's transport: the gateway and website of the `firstlanding` library are served from these files, and every other request goes to the real transport. Every app gets it, because the core owns the transport.

It is compiled out of `ReleaseFast` and `ReleaseSmall` builds (and Windows), so shipped apps ignore the variable.

## Using it

```sh
BIBLIO_MOCK=$PWD/core/mock/video  open Biblio.app    # DVD, Blu-ray, 4K (with a fictional serial, Sanctuary Moon)
BIBLIO_MOCK=$PWD/core/mock/books  open Biblio.app    # Murderbot and other science-fiction books
```

* iOS simulator: `SIMCTL_CHILD_BIBLIO_MOCK=… xcrun simctl launch DEVICE com.rbrian.Biblio`.
* Add the library by typing `first`, then sign in as `perihelion` with any password (the password `wrong` fails).
* Holds, settings, and borrowing history change in memory; relaunching resets them.
* Titles, covers, and call numbers come from a real catalog; covers load from their live URLs, so the network is needed.

## Files

| File | Holds |
|---|---|
| `shared/library.json` | name, brand color, labels, branches, and the patron |
| `video/`, `books/` | a theme: `catalog.json` (titles, copies by branch, people waiting, new or on order) and `account.json` (holds, checkouts, history, as day offsets from today) |

Each catalog also carries in-universe media in other formats, appended after the main titles: Murderbot audiobook CDs, the fictional serial's soundtrack (`Music CD`), and large print where the source library has it.

`generate.mjs` rebuilds `video/` and `books/` from a live library's public catalog (`node generate.mjs [subdomain]`, default `wccls`), inventing the copies and the account deterministically.

## Not covered

Advanced search, other account settings than email, pickup location, language, and borrowing history, and paging past 25 rows of search results beyond the fixtures' size.
