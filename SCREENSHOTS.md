# Screenshots

How to regenerate the [README](README.md) screenshots in [docs/screenshots](docs/screenshots).

## Shots

| File | Device | Screen | Blur |
|---|---|---|---|
| `iphone-search.png` | iPhone 17 | Search "dune", Format: Book | — |
| `iphone-facets.png` | iPhone 17 | Search "dune", Format menu open | — |
| `iphone-detail.png` | iPhone 17 | Dune (2019) item sheet, Availability by Location | — |
| `iphone-new-titles.png` | iPhone 17 | New Titles, Just Arrived | — |
| `iphone-holds.png` | iPhone 17 | Holds, All | covers, titles, subtitles, authors, format lines |
| `iphone-account.png` | iPhone 17 | Account | Name value |
| `iphone-add-library.png` | iPhone 17 | Add Library, "county" typed | — |
| `ipad-new-titles.png` | iPad (A16), landscape | New Titles sorted by People Waiting, top item in the inspector, scrolled to Availability by Location | sidebar username |
| `ipad-holds.png` | iPad (A16), landscape | Holds, All, no inspector | as `iphone-holds.png`, plus sidebar username |
| `mac-*.png` | macOS | as the README's alt text says | titles and usernames, as above |

Output widths: iPhone 600 px, iPad 1400 px, macOS 1400 px (settings 700 px), with `sips --resampleWidth`.

## Setup

* Build Debug for `generic/platform=iOS Simulator` and install on both simulators.
* `xcrun simctl status_bar <device> override --time "9:41" --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 --dataNetwork wifi`.
* Launch with `xcrun simctl launch <device> com.rbrian.Biblio -SampleAccount YES` (sample card number and email).
* Sign in as the existing WCCLS user; never type credentials.
* Rotate the iPad left for landscape.

## Capture

* `xcrun simctl io <device> screenshot --mask=alpha` (rounded screen corners).
* Landscape iPad captures arrive in portrait; fix with `sips -r 270`. Taps stay in the portrait frame: for an upright point (X, Y), tap (820 − Y, X).
* The simulator renders taps 1–2 s late; screenshot after a pause.
* Typing before a field gains focus is lost: tap, wait, then type.
* A focused field's cursor blinks: take a burst and keep a frame without it.
* Wait for the bottom status bar (`TITLE [SIZE KiB]`) to fade, 2 s after the last request.
* Sorting by People Waiting fetches every page for about a minute and reorders rows; wait until the list settles.
* Switching sections closes the inspector, so `ipad-holds.png` has none.
* The catalog changes; pick current titles and update the README's alt text to match.

## Privacy

* Blur with [blur.swift](docs/screenshots/blur.swift): `swift docs/screenshots/blur.swift IN OUT POINT_WIDTH x,y,w,h…` (rects in points; iPhone 17 is 402 pt wide, landscape iPad (A16) 1180 pt).
* On holds, blur covers and every text line except the status line.
* Never capture the host Mac's screen; the user takes macOS shots into `docs/screenshots/raw` (ignored by Git), then blur and resize them.
