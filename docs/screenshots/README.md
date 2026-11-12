# Screenshots

The [README](../../README.md)'s screenshots: one patron's visit, from first launch to returns, captured against the fictional FirstLanding Public Library ([core/mock/](../../core/mock/README.md)). Multiple libraries and accounts get at most one frame. No real account or catalog data appears.

## Frames

Files are `DEVICE-NN-slug.png`.

| Step | Slug | Shows | iPhone | iPad | Windows |
|---|---|---|---|---|---|
| 1 | `welcome` | Add a library, search filled in, suggestion showing | ✓ | | |
| 2 | `sign-in` | Sign-in form, sample card number, password hidden | ✓ | | |
| 3 | `search` | Search filtered by format, with counts | ✓ | | |
| 4 | `detail` | Availability by Location, pickup menu beside "Hold" | ✓ | ✓ (search "Wells", inspector open) | ✓ (search "Wells", detail pane open) |
| 5 | `hold` | Hold placed, "Cancel Hold" showing | ✓ | | |
| 6 | `holds` | Ready, Not Ready, and On Order counts, status tinting | ✓ | ✓ (inspector open) | |
| 7 | `card` | Library card barcode | ✓ | | |
| 8 | `checked-out` | Sorted by due date, one overdue | ✓ | ✓ (inspector open) | |
| 9 | `history` | Borrowing history | ✓ | | |

Skip a step on a device where another frame already shows it; the README never repeats a step on the same device.

Android and GNOME have `PLATFORM-coming-soon.png` and `-dark.png` placeholders, matching the real frames' size and aspect ratio. Generate them with [tools/coming-soon.swift](../../tools/coming-soon.swift), and replace each with its real frame when that app can be captured.

## Devices and data

* **iPhone 17** uses the physical-video theme (`core/mock/video`: DVD, Blu-ray, and 4K Blu-ray), steps 1–9.
* **iPad (A16)**, landscape, uses the books theme (`core/mock/books`: Murderbot Diaries and other science fiction).
* **Mac** frames need a VM, never the host's screen.
* **Windows** uses the books theme in a terrarium guest ([windows/README.md](../../windows/README.md)): the app maximized on the guest's 1024×768 display, cropped above the taskbar to 1024×720, so frames aren't downscaled. Full-screen captures stay in `raw/`.
* Light mode only.

## Capture

1. Build the core as Debug, since `ReleaseFast` and `ReleaseSmall` compile the mock out, then the app for the simulator: `CONFIGURATION=Debug zig build` in `apple/`, then `xcodebuild … -configuration Debug -destination id=UDID`.
2. Set a fixed clock and full battery: `xcrun simctl status_bar UDID override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3`; clear it afterward.
3. Launch with an absolute fixtures path: `SIMCTL_CHILD_BIBLIO_MOCK=$PWD/core/mock/video xcrun simctl launch UDID com.rbrian.Biblio`.
4. Add the library by typing `first`, then sign in as `perihelion` (any password).
5. Screenshot with `xcrun simctl io UDID screenshot`, then downscale with `sips --resampleWidth`: 600 px for phones, 1400 px for tablets and desktops.
6. Wait for "Availability by Location" to load before capturing a detail.

Holds, settings, and history change in memory, so relaunch to reset. Step 5's placed hold makes the sidebar's Holds badge one higher in later iPhone frames.

Raw captures go in `raw/`, which Git ignores. Blur any frame that leaks real details with [tools/blur.swift](../../tools/blur.swift); mock data needs none.

## Pending

* macOS frames, once a VM can drive the app reliably.
* A frame for step 10, two accounts: two windows on macOS, or the user menu on iOS.
* A dark-mode pair for step 3.
* Frames for the in-universe formats (audiobook CD, soundtrack Music CD): the format filter, and a Sanctuary Moon search.
