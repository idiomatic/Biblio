# Screenshots

The [README](../../README.md)'s screenshots: one patron's visit, from first launch to returns, captured against the fictional FirstLanding Public Library ([core/mock/](../../core/mock/README.md)), for the apps' users. An animated GIF shows the typical flow at human speed; stills show each step; a few combination shots show features the flow doesn't reach. No real account or catalog data appears.

## Rules

* Still frames never repeat a step on the same device; the GIF may replay steps the stills show.
* Several libraries or accounts get at most one frame (step 10).
* Light mode, except one dark-mode pair (step 3), shown by the reader's GitHub theme with `<picture>`.
* Frames are `DEVICE-NN-slug.png`; GIFs are `DEVICE-NN-slug.gif`, numbered by the step they start at.

## Frames

✓ exists.

| Step | Slug | Shows | iPhone | iPad | Mac | Windows |
|---|---|---|---|---|---|---|
| 1 | `welcome` | Add a library, search filled in, suggestion showing | ✓ | | | |
| 2 | `sign-in` | Sign-in form, sample card number, password hidden | ✓ | | | |
| 3 | `search` (iPad: `new-titles`) | Search with the format filter open, with counts; on iPad, New Titles (Just Arrived, sorted by title) with its many formats | ✓ (and dark) | ✓ | | |
| 4 | `detail` | Availability by Location, pickup menu beside "Hold" | ✓ | ✓ (search "Wells", inspector on a title borrowed before) | | ✓ (search "Wells", detail pane open) |
| 5 | `hold` | Hold placed, "Cancel Hold" showing | ✓ | | | |
| 6 | `holds` | Ready, Not Ready, and On Order counts, place in line, status tinting | ✓ | ✓ (inspector open) | | |
| 7 | `card` | Library card barcode | ✓ | | | |
| 8 | `checked-out` | Sorted by due date, one overdue | ✓ | ✓ (inspector open) | | |
| 9 | `history` | Borrowing history | ✓ | | | |
| 10 | `household` | A combined window of two cards (`perihelion` and `gurathin`): the sidebar's Cards toggles, holds interleaved with card chips, and the inspector on a title one card holds, with that card's chip and Cancel Hold and "Hold for" the other (not a title both hold: the list shows one chip a row, so it would confuse) | | ✓ | | |
| 11 | `drag` | One window: search "station eleven", drag the cover onto Holds (GIF) | | | ✓ | |
| 12 | `everywhere` | Later, with the other platforms: the same title, Rogue Protocol, open on each, as a composite still or a GIF of about 3 seconds a platform | | | | |

The README groups them as Get started (1, 2), Find and hold (3 to 5), Pick up (6, 7), Keep track (8, 9), and And more (10 to 12), beside the GIF.

Apple's apps come first; the other platforms wait. Android and GNOME keep their `PLATFORM-coming-soon.png` and `-dark.png` placeholders, as wide as the real frames (Android's 600×1300 like the iPhone's 600×1304, GNOME's 1400×875 like the iPad's 1400 px), drawn with [tools/coming-soon.swift](../../tools/coming-soon.swift), and Windows keeps its existing frame, until step 12 replaces them.

## The GIF

`iphone-03-flow.gif`, at the top of the README: on iPhone 17 with the video theme, type "interstellar" a key at a time, filter to 4K Ultra HD Blu-ray, open it as Availability by Location fills in, Hold, Done, open Holds (ready first, tinted), then the sidebar's Library Card and its barcode, held at the end. (Sanctuary Moon, the fictional serial, has no covers.)

* Human speed: about 1 s still after each change, keys 60 to 120 ms apart; about 20 s in all, looping, with 2 s on the last frame. It reads without pausing, since GitHub can't pause a GIF.
* 300 px wide in the README, from 600 px; GIF89a, at most 8 fps, about 4 MB; alt text tells the whole sequence.
* Each loop fades in from white at its start and out to white at its end (black for a dark-mode GIF, shown with `<picture>`), so the jump back to the beginning reads as a new take.
* Each tap shows as a ring, as terrarium's `record --clicks` draws one, since the simulator's recording shows no touches.
* Made with `tools/gif.swift` from `xcrun simctl io UDID recordVideo`, driving the simulator with Xcode's device-interaction tools and logging each tap's call time and point: `swift tools/gif.swift flow.mov iphone-03-flow.gif --width 600 --fps 8 --max-hold 0.9 --taps flow.taps --snap --pace 1.3 --final-hold 2.5 --fade 0.5` (with `--start` and `--end` to trim).
* Send each tap and its wait as separate calls: `t X Y w S` in one call holds the touch down for S, and buttons act only on release. A tap lands about 0.6 s after its call starts, so log call time plus 0.55 s and let `--snap` find the screen's response.
* Start from a known screen: a relaunch restores the last one, so navigate (Back, Search, clear the field) before recording, and let the launch's borrowing-history read finish so the status bar has faded.

Desktop GIFs (step 11) use terrarium's `record` (with `--clicks`, and `--crop` to the window) and its human-speed input (`type --interval 95`, `move --duration`, and `click --duration`; a drag of 3.5 s keeps macOS's drag image under the pointer), then `swift tools/gif.swift drag.mov mac-11-drag.gif --width 800 --fps 12 --max-hold 1.2 --final-hold 2.5 --fade 0.5`.

## Devices and data

* **iPhone 17** uses the physical-video theme (`core/mock/video`: DVD, Blu-ray, and 4K Blu-ray), steps 1–9.
* **iPad (A16)**, landscape, uses the books theme (`core/mock/books`: Murderbot Diaries and other science fiction).
* **Mac** frames come from a terrarium guest, never the host's screen: the shared layer `macos-27.2-quiet`, ephemeral, with `--memory 4096`, and the mock inside the app bundle, as [core/mock/README.md](../../core/mock/README.md) says.
* **Windows** uses the books theme in a terrarium guest ([windows/README.md](../../windows/README.md)): the app maximized on the guest's 1024×768 display, cropped above the taskbar to 1024×720, so frames aren't downscaled. Full-screen captures stay in `raw/`.
* **GNOME and the terminal app** come from a terrarium Linux guest, the terminal app in GNOME Terminal. **Android** needs an emulator, which a guest may not host; it stays a placeholder until one runs.

## Capture

1. Build the core with `CONFIGURATION=Debug zig build` in `apple/`, which builds it ReleaseSafe (ReleaseFast and ReleaseSmall compile the mock out), then the app for the simulator: `xcodebuild … -configuration Debug -destination id=UDID`.
2. Set a fixed clock and full battery: `xcrun simctl status_bar UDID override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3`; clear it afterward.
3. Launch with an absolute fixtures path: `SIMCTL_CHILD_BIBLIO_MOCK=$PWD/core/mock/video xcrun simctl launch UDID com.rbrian.Biblio`.
4. Add the library by typing `first`, then sign in as `perihelion` (any password); step 10 adds `gurathin`.
5. Screenshot with `xcrun simctl io UDID screenshot`, then downscale with `sips --resampleWidth`: 600 px for phones, 1400 px for tablets and desktops. Record the GIF with `xcrun simctl io UDID recordVideo`; in a guest, `terrarium shot` (and `record`, once it ships).
6. Wait for "Availability by Location" to load before capturing a detail. A guest's display lags input by seconds, so capture until two consecutive shots match.

Holds, settings, and history change in memory, so relaunch to reset. Step 5's placed hold makes the sidebar's Holds badge one higher in later iPhone frames.

Raw captures go in `raw/`, which Git ignores. Blur any frame that leaks real details with [tools/blur.swift](../../tools/blur.swift): `swift tools/blur.swift IN OUT POINT_WIDTH x,y,w,h…` blurs each rectangle, given in points from the top left of an image POINT_WIDTH points wide, and writes OUT as PNG, JPEG, or HEIC by its extension. Mock data needs none.

## To build

* **A UI-test target, `BiblioScreenshots`**, driving the mock library through steps 1–10 at the GIF's pace and taking the stills at each step, so a UI change is recaptured with one command.
