# Development

How Biblio is built, tested, and released, and what comes next. The requirements are in
[AGENTS.md](AGENTS.md), and how the shared core works is in [core/README.md](core/README.md).
Delete items under Next as they are resolved.

## Requirements

| Platform | Needs |
|---|---|
| All | Zig 0.17 |
| macOS, iOS, iPadOS | Xcode 26 or later |
| GNOME | GTK 4, libadwaita 1.6 or later, libsecret |
| Android | The Android SDK (API 36) and JDK 17 or later; the Gradle wrapper fetches Gradle |
| Windows | The .NET 10 SDK and the Windows App SDK |
| Terminal | Nothing more |

## Building

| Platform | Steps |
|---|---|
| Apple | Open `apple/Biblio.xcodeproj`, choose the **Biblio** scheme, put your signing team in `apple/Local.xcconfig` (one line, `DEVELOPMENT_TEAM = <team ID>`; Git ignores it), and build. Xcode runs `zig build` in `apple/` (see [apple/build.zig](apple/build.zig)), which builds the core as `zig-out/lib/PLATFORM/libbiblio.a` with its `BiblioCore` module in `zig-out/include`, before compiling, even after a clean. |
| GNOME | `cd gnome && zig build run` |
| Android | `cd android && ./gradlew installDebug` |
| Windows | `cd windows/Biblio && dotnet build -p:Platform=x64`; on a Mac, in a guest, as [windows/README.md](windows/README.md) says |
| Terminal | `cd tui && zig build run` |

`zig build cross` at the root cross-compiles the core for Linux, Windows, and Android, plus
the GNOME app for Linux, into `zig-out/cross`. The GNOME app builds against Debian sysroots that
[gnome/debian-sysroot.sh](gnome/debian-sysroot.sh) downloads (it needs a POSIX shell, curl, xz,
and zstd), so it also targets 64-bit Raspberry Pi OS.

## Project layout

| Folder | Contents |
|---|---|
| `core` | libbiblio, the shared Zig core, its C header, and its [developer guide](core/README.md) |
| `apple` | The SwiftUI app for macOS, iOS, and iPadOS, and [its guide](apple/README.md) |
| `gnome` | The GTK 4 and libadwaita app, in Zig |
| `android` | The Jetpack Compose app, and its Zig JNI shim |
| `windows` | The WinUI 3 app, in C#, and [how to build and test it](windows/README.md) |
| `tui` | The terminal app, in Zig |
| `docs` | [Screenshots](docs/screenshots/README.md) and [external specifications](docs/specifications/README.md) |
| `tools` | Developer tools: [blur.swift](tools/blur.swift) blurs private details in screenshots, and [coming-soon.swift](tools/coming-soon.swift) draws the placeholder sketches, and [gif.swift](tools/gif.swift) turns screen recordings into the README's GIFs |

The apps use the same gateway API as the BiblioCommons web app, and account settings go
through the website's own forms; [NOTES-API.md](NOTES-API.md) lists the endpoints. Requests are
throttled to be gentle on library servers.

## Testing

`zig build test` in `core`, `tui`, and `android/native` runs everything that needs no device
or library. CI ([.github/workflows/ci.yml](.github/workflows/ci.yml)) runs those, `zig build
cross`, and each app's build on every push, except one whose commits change only Markdown
files and `docs/`, so there's no need for `[skip ci]`.

- **The mock library:** [core/mock/README.md](core/mock/README.md).
- **Real libraries:** [AGENTS.md](AGENTS.md)'s testing rules.
- **Guests:** [AGENTS.md](AGENTS.md); the Windows guest in [windows/README.md](windows/README.md),
  and the iOS Simulator in [apple/README.md](apple/README.md).
- **Platforms:** iPhone 13 mini, iPhone 17, iPad mini (6th generation), iPad (A16), and iPod
  Touch (7th generation); Fedora Workstation and Raspberry Pi OS (GNOME);
  phone, foldable, and tablet emulators (Android); Windows 11 x64 and ARM64; Terminal.app and
  GNOME Terminal; narrow layouts (GNOME at 360 px, Android phones, Windows' minimum window).

## Releasing

1. Set the version (`X.Y`) in `MARKETING_VERSION` in `apple/Biblio.xcodeproj` (the build
   number follows it), `appVersion` in `android/app/build.gradle.kts` (`versionCode` follows
   it), `<Version>` in `windows/Biblio/Biblio.csproj`, and `core/src/version.zig` (`X.Y.0`),
   and add a `<release>` to `gnome/data/com.rbrian.Biblio.metainfo.xml`.
2. Rename the changelog's Unreleased section to `X.Y — DATE`.
3. Commit, tag `vX.Y`, and push both to `github`.

## Next

### To build

Bring the GNOME, Android, Windows, and terminal apps to the Apple app's features
([AGENTS.md](AGENTS.md)), each by its platform's conventions.

| App | Missing |
|---|---|
| GNOME | guest sign-in sheet; multiple selection; status bar; Library Card button; primary menu, About, and Keyboard Shortcuts; Ctrl+R, Ctrl+F, Ctrl+W, Ctrl+Q; rows' edition and on-order symbol; advanced search and facets beyond format; metainfo screenshots |
| Android | guest sign-in sheet; Code 128 choice; card swiping; multiple selection; About and version footer; "Use System Language"; rows' edition and on-order copies; New Titles filters (hard-codes `f_on_order=false`); advanced search and facets beyond format; `strings.xml` |
| Windows | Code 128 choice on the account page; multiple-selection UI; dragging from item detail and dropping onto search; New Titles filters (hard-codes Just Arrived); rows' and detail's edition and on-order copies; advanced search and facets beyond format; "Use System Language" (guest sheet, About, and status bar are written, unbuilt) |
| Terminal | advanced search; facets beyond format; New Titles' On Order view; About |

| Feature | GNOME | Android | Windows | Terminal |
|---|---|---|---|---|
| Sections | `AdwNavigationSplitView` sidebar | `NavigationSuiteScaffold` | `NavigationView` pane | Tab |
| Item detail | `AdwOverlaySplitView` end pane; `AdwBottomSheet` when narrow | `ListDetailPaneScaffold` | Right-hand pane | Full screen, Esc returns |
| Refresh | Ctrl+R, F5, menu item | `PullToRefreshBox` | `RefreshContainer`, F5 | `r` |
| Multiple selection | Header-bar selection mode, bottom action bar | Long press, contextual top bar | `SelectionMode="Extended"`, `CommandBar` | Space |
| Confirmations | `AdwAlertDialog` | `AlertDialog` | `Flyout` on the control | y/n |
| Notices | `AdwToast` | `Snackbar` | `InfoBar` | Bottom line |
| Library card | Header-bar button, popover | Top-bar action, full screen, raised brightness | Header button, flyout | Account tab |
| Sessions | One per window, Ctrl+N | One per task; split screen on large screens | One per window, Ctrl+N | One per process |
| Guest sign-in | `AdwDialog` of the library's users | Modal bottom sheet | `ContentDialog` | Prompt |
| Drag to hold or search | `GtkDragSource`/`GtkDropTarget` | Within the app; across split screen | `CanDrag`/`AllowDrop` | None |
| Request status | Fading bottom bar | None | Fading status bar | Bottom line |
| About | `AdwAboutDialog` | Settings ▸ About | Version in the sidebar's foot | `--version`, help line |
| Restore at launch | Last windows' logins | Saved state survives process death | Last windows' logins | Last library |
| Branding | Accent color in CSS, contrast-checked | Brand color as scheme seed | Accent color resources | 256-color tint |
| Icon cache | `$XDG_CACHE_HOME/biblio` | `cacheDir` | `LocalCacheFolder` | None |

- **Localization:** Apple has a String Catalog in English only. Add translations, make the
  core's messages localizable, and format dates (due, pickup) with the system locale, by each
  platform's language settings (gettext on GNOME, `strings.xml` on Android, `.resw` on
  Windows), independent of the library account's language.
- **Packaging:** GNOME as a Flatpak on Flathub (x86_64, aarch64) and an RPM spec; Android as a
  signed App Bundle with an adaptive icon; Windows as MSIX for x64 and ARM64 with a winget
  manifest and tile assets; the terminal app as release archives, a Homebrew formula, and an
  RPM spec.

Paused work, uncommitted:

- **Android:** `android/native/src/jni.zig` is ahead of the Kotlin, so item details and
  password changes fail at runtime. `Core.kt` and `Models.kt` need `DetailList`,
  `FetchStatus`, `HttpResponse`, `ByteArray` passwords (zeroed after the call),
  declarations for `nativeYear`, `nativeHoldStatusRank`, `nativeReadableTint`,
  `nativeFormatCodes`, `nativeVersion`, `nativeIncidents`, and `nativeStatus`, and an OkHttp
  `Core.send` installed with `nativeInstallTransport()` after `loadLibrary` (plus an explicit
  `okhttp` dependency). A JDK 17 and the Android SDK are in `~/Library/Caches/biblio-android/`.
- **Windows:** the C# changes have never been compiled. Build first
  (`dotnet build -p:Platform=ARM64` in the guest); riskiest are `biblio_client_new`'s
  `delegate* unmanaged[Cdecl]` parameter, `SafeHandle` parameters beside pointers, the
  `Release<T>` free delegates, and the status bar's `OpacityTransition`.
- **GNOME:** a `window.zig` draft (open leak, destroy notify, login retry banner,
  `G_TYPE_BOOLEAN`, card button, menus, accelerators, sign-in sheet, multiple selection,
  status bar) is at `~/Library/Caches/biblio-gnome-wip/`; it needs `multi.zig`,
  `signin.zig`, and helpers in `main.zig`, `detail.zig`, and `list.zig`.

### Open

#### Builds

- The Android Kotlin, with AGP 8.13.2 and the Gradle wrapper, has never compiled; CI's
  `./gradlew` job is the first check.
- `zig fmt --check` fails on `gnome/src/store.zig`, `main.zig`, and `window.zig`.

#### GNOME

- `window.zig:87`: `Window.open` creates the window before its failure returns, leaking an
  unpresented window that keeps the process alive.
- `detail.zig:346`: if the shown item changes during a hold request, the toast names the new
  item.
- `gtk.zig:19`: handlers get raw pointers with no destroy notify, safe only by free ordering
  in `window.zig`.
- `window.zig:250`: a failed sign-in only toasts; sections show empty states with no retry.
- `window.zig:310`: `holdsChanged` reloads Search and New Titles in full, losing scroll.
- `window.zig:221`: the inspector stays open when the section changes.
- `main.zig:194`: Remove Library and Remove User aren't disabled while that login is open.
- `list.zig:921`: `year` duplicates `biblio_year` (`core.year` wraps it, unused).
- `list.zig:317`, `detail.zig:99`: jackets have no alternative text.
- `window.zig:188`: `g_type_from_name("gboolean")` instead of `G_TYPE_BOOLEAN`.

#### Android

- `ui/SessionScreen.kt:117`: sections share one `ListDetail` without `key(section)`; on a
  phone, switching sections with a detail open shows an empty pane.
- `MainActivity.kt:43`: `Session` lives in `remember`, so rotation re-signs in and leaks a
  scope and client. Hold it in a `ViewModel`.
- `ui/Session.kt:161`: only `Core.Failure` is caught; other throwables crash.
- `data/LibraryStore.kt:80`: decryption failures read as "missing credentials", with no way
  to re-enter the password. `:65`: `key()` isn't synchronized.
- `AndroidManifest.xml:9`: the launcher icon is the system `ic_menu_agenda`, not `icon.png`;
  the theme is platform `Theme.Material.NoActionBar`.
- `core/Models.kt`, `ui/SessionScreen.kt:277`, `ui/LibraryIcon.kt:110`: year, format names,
  availability labels, and the brand color (without `biblio_readable_tint`) duplicate the
  core.
- `ui/SessionScreen.kt:259`: `formatName` makes a JNI call per row per recomposition, and
  the unstable `Session` keeps rows from skipping.
- `ui/AccountScreen.kt:86`: the keyboard hides the password fields; add `imePadding()`.
  `:210`: `fillMaxWidth().widthIn(max = 420.dp)` is in the wrong order. `:215`: barcode bars
  land on fractional pixels.
- `ui/ItemDetail.kt:148`: `remember { session.patron?.preferredPickup }` isn't keyed.
- `ui/Launcher.kt:124`: the partner directory is fetched each time the sheet opens.
- `ui/Session.kt:52`: guests request `locations()`, which fails.
- `ui/SessionScreen.kt:106`: the badge has no TalkBack semantics.

#### Windows

- `Views/Dialogs.cs:14`: a failed first directory fetch is cached forever.
- `Views/DetailPane.cs:177`: the cancel confirmation is a `ContentDialog`, not a `Flyout` on
  the button.

#### Apple (found while taking screenshots)

- A refined format repeats in a row's details when the edition says the same thing ("4K Ultra
  HD Blu-ray · 2024 · 4K Ultra HD Blu-ray").
- In a window with several cards, a list row shows one card's chip even when more than one card
  holds the title; item detail shows each.
- In a window with several cards, there's no "Card" filter (AGENTS.md), and lists select one item
  at a time (no multiple selection).
- On iPad, with the keyboard up in Search, the sidebar's "Biblio 1.9" footer rides up over the
  New Titles row.
- On iPad, after turning a card off in a two-card window, the status bar stayed up over five
  minutes until a refresh, `FetchStatus.active` above 0. `BiblioClient.run` always pairs
  `began` with `finished`, so a core call hadn't returned; not reproduced against the mock. The
  bar now fades after 20 seconds regardless; find the call (sample the process while it shows).
- The mock's Sanctuary Moon serial has no covers.

#### macOS

- **Squashed rows on a list's first visit.** Opening Borrowing History soon after launch
  briefly shows its rows squashed, as if drawn before their heights are measured. A minimum
  row height (`defaultMinListRowHeight`) may fix it, but it would also apply to the lists'
  header rows (search field, filter bars); reproduce it in a macOS guest first.

#### Ideas and checks

- **Lock-screen barcode.** A Lock Screen control now opens the barcode. Showing it
  automatically when in the library needs a Wallet pass (Code128, not Codabar) or similar.
- **Disclose the throttling report.** Tell users, in the README and the About box or a privacy
  note, that Biblio keeps a local log of 429 and 5xx responses (time, status, method, host,
  masked path, retry delay, requests in flight), that nothing is sent unless they copy and
  share the report, and what the risks are: the log persists on the device until the app is
  deleted, and a copied report names the library host and the times of the user's activity.
- **Check the status bar on an iPod Touch.** The bottom status bar (`TITLE [SIZE KiB]`) is
  checked on the iPhone 13 mini, iPhone 17, iPad mini, iPad (A16), and Mac. No iPod Touch
  simulator exists, so look at it on a device. On iPhone the item sheet covers the bar while
  it loads locations.
- **Other library systems.** Polaris, Sierra, Koha, Aspen, and Evergreen, named in [I Built a
  25,000-Disc Netflix You Can Use for Free](https://www.youtube.com/watch?v=qy2FlFQecd8), as
  possible back ends beside BiblioCommons.
- **Windows test layers.** Replace steps 2 to 5 of [windows/README.md](windows/README.md) with
  terrarium layers, each on the one before (`commit` with `--save` or `--clone`; `squash` to
  flatten), keeping 45 GB free for the install's peak:

  | # | Holds | Kept |
  |---|---|---|
  | 0 | Windows 11 ARM64 ISO, in `~/Developer/Images`, read-only | 8.5 GB measured |
  | 1 | Clean install: user `terra`, the helper (`--accept-license --disk 40`) | 16 to 19 GB measured |
  | 2 | First-run quieting: `windows/no-sleep`, `windows/no-lock`, `windows/edge-quiet`, toasts off, OneDrive stopped | small |
  | 3 | Zig 0.17, the .NET 10 SDK ([guest-setup.ps1](windows/guest-setup.ps1)), and a NuGet cache warmed by `dotnet restore -p:Platform=ARM64`, trimmed with `Dism /StartComponentCleanup` | ≤ 8 GB (7.0 measured untrimmed) |
  | 4 | One offline build (`dotnet build -p:Platform=ARM64 --no-restore -m:1 -nodeReuse:false`) and a run against `BIBLIO_MOCK`, discarded | ≤ 4 GB |

  Rebuild layer 3 when the Zig or .NET version changes, layer 2 when the quieting changes,
  and layer 1 only for a new Windows build. To check: layer 3's size after the trim; whether
  tweaks persist in a saved layer; whether `-nodeReuse:false -m:1` always avoids the
  13-minute first-build stall; whether the toast and OneDrive settings apply, since the helper
  may not run as the logged-in user.

### Not planned

- **Input and output lists for Xcode's "Build libbiblio" phase**, in place of
  `alwaysOutOfDate`: Zig tracks its own inputs and its cached build is quick, while Xcode
  can't list `core/src` without a generated file list, and an incomplete one would let a
  stale library through.
- **Compiling the core once for both its static and shared libraries** (`core/build.zig`):
  linking both from one object loses the start code a Windows DLL needs.
