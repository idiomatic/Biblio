# Biblio on Apple, Android, GNOME, Windows and the terminal

Every Biblio app shares one core, **libbiblio**, written in Zig ([`core/`](core)). The core is the
BiblioCommons client:

- signing in, and signing in again when a session expires
- the cookie jar
- the gateway API and the library website's Rails account forms
- library lookup and the partner directory
- request pacing
- paged item lists: which pages to fetch, placeholder rows, client sorts and local filters
- copy-status grouping, Codabar barcode encoding and brand-color contrast

Each platform has a native UI that follows that platform's design guidelines. The graphical
apps call the core's typed C functions, which take C arguments and return C structs, documented
in [core/include/biblio.h](core/include/biblio.h) and [docs/core.md](docs/core.md):

| Platform | How it calls the core |
|---|---|
| Apple | Swift calls the C functions directly; [`apple/Biblio/Net/CoreModels.swift`](apple/Biblio/Net/CoreModels.swift) copies the structs into the app's models. |
| GNOME | Zig calls `biblio.capi` and reads the structs in place. |
| Android | A Zig JNI shim ([`android/native/src/jni.zig`](android/native/src/jni.zig)) has a native method per operation and builds the Kotlin models with their constructors. |
| Windows | C# P/Invoke with blittable copies of the structs ([`windows/Biblio/Core/Interop.cs`](windows/Biblio/Core/Interop.cs)). |
| Terminal | Zig calls the core's `Client` directly, with Zig types, like the `biblio` CLI. |

| Platform | UI | Language | Passwords | HTTP |
|---|---|---|---|---|
| macOS, iOS, iPadOS | SwiftUI | Swift | Keychain | URLSession, through the core's transport hook |
| GNOME (Linux) | GTK 4 + libadwaita, GNOME HIG | Zig | Secret Service (libsecret) | Zig `std.http` |
| Android | Jetpack Compose, Material 3 | Kotlin + a Zig JNI shim | Android Keystore (AES-GCM) | Zig `std.http` (reads the system CA store) |
| Windows | WinUI 3, Fluent | C# | Credential Locker | Zig `std.http` (reads the Windows cert store) |
| Terminal (macOS, Linux) | xterm-256color escape sequences, no libraries beyond libc | Zig | Not saved: asked for at sign-in, kept in memory | Zig `std.http` |

The Android and Windows UIs are not written in Zig. Their toolkits (Compose, WinUI) are only
usable from Kotlin and C#, so the Zig there is limited to the core and the JNI shim.

## Building

The core needs Zig 0.17.

```bash
cd core && zig build test
```

`zig build` also produces `zig-out/bin/biblio`, a command-line tool for trying the core
against a live library. Use it sparingly:

```bash
core/zig-out/bin/biblio search wccls "project hail mary"
```

**Apple.** Open `apple/Biblio.xcodeproj`, choose the **Biblio** scheme and a destination, set
your own signing team under **Signing & Capabilities**, and build. The "Build libbiblio" phase
runs [`apple/build-core.sh`](apple/build-core.sh), which builds `apple/build/BiblioCore.xcframework`. Run that script
once by hand after a fresh clone, so Xcode finds the framework.

**GNOME.** Needs `gtk4`, `libadwaita-1` (1.6 or later) and `libsecret-1`:

```bash
cd gnome && zig build run
```

[`gnome/com.rbrian.Biblio.json`](gnome/com.rbrian.Biblio.json) is a Flatpak manifest.

**Android.** Needs Zig on `PATH`, plus the Android SDK and a JDK. Run `gradle wrapper` once,
or open the project in Android Studio. Then:

```bash
cd android && ./gradlew installDebug
```

Gradle builds `libbiblio_jni.so` for arm64-v8a and x86_64 with [`android/native/build.zig`](android/native/build.zig).

**Windows.** Needs Zig on `PATH`, the .NET 8 SDK and the Windows App SDK workload:

```bash
cd windows/Biblio && dotnet build -p:Platform=x64
```

MSBuild builds `biblio.dll` with Zig and copies it next to the app.

**Terminal.** Needs only Zig, and a terminal that handles xterm-256color:

```bash
cd tui && zig build run
```

Or run `tui/zig-out/bin/biblio-tui` after `zig build`. Libraries and usernames are saved in
`$XDG_CONFIG_HOME/biblio/tui.json` (or `~/.config/biblio/tui.json`). Keys are listed on the
bottom line; `/` searches, Tab switches sections, Enter opens an item, and `h` and `c` place
and cancel holds. Character widths are counted one column per code point, so wide (CJK)
characters can misalign a row.

**Raspberry Pi.** The core, the terminal app and the GNOME app cross-compile for 64-bit
Raspberry Pi OS (Pi 3, 4, 5 and Zero 2 W) from any machine with Zig, as `aarch64-linux-gnu`.
The core and the terminal app need nothing else:

```bash
cd core && zig build -Dtarget=aarch64-linux-gnu -Doptimize=safe
cd tui && zig build -Dtarget=aarch64-linux-gnu -Doptimize=safe
```

The GNOME app links against GTK, so it builds against a Debian 13 (trixie) sysroot, the base
of current Raspberry Pi OS. [`gnome/debian-sysroot.sh`](gnome/debian-sysroot.sh) downloads the packages from Debian and
unpacks them (about 25 MB to download, 160 MB on disk; it needs curl, xz, ar and tar, not dpkg):

```bash
cd gnome
./debian-sysroot.sh arm64 /tmp/sysroot-arm64
zig build -Dtarget=aarch64-linux-gnu -Dsysroot=/tmp/sysroot-arm64/root -Doptimize=safe
```

Copy `zig-out/` to the Pi. The binaries need glibc 2.28 or later; the GNOME app also needs
the `libgtk-4-1`, `libadwaita-1-0` and `libsecret-1-0` packages, which come with Raspberry Pi
OS's desktop (Bookworm's libadwaita 1.2 is too old). The same script with `amd64` builds an
x86_64 Linux sysroot. 32-bit Raspberry Pi OS isn't supported.

## Status

| Part | Checked |
|---|---|
| Core | 32 unit and fixture tests pass, including the item list's. The C header's original 27 structs match the core's layout. Live guest requests work (library info, search, availability, directory). Cross-compiles for macOS, iOS, the iOS simulator, x86_64 and aarch64 Linux (Raspberry Pi), Android and Windows. |
| Apple | Builds for macOS and the iOS simulator. On iPhone 17, sign-in, search, item details and availability, the holds and checkout counts, and lists (paging, placeholders, hold filters and the people-waiting sort, through the core's item list) work. |
| GNOME | Links for x86_64 and aarch64 Linux (Raspberry Pi) against Debian trixie sysroots from [`gnome/debian-sysroot.sh`](gnome/debian-sysroot.sh) (GTK 4.18, libadwaita 1.7). `zig build check -Dsysroot=<sysroot>` type-checks without linking. Not run yet. |
| Android | The JNI library builds for both ABIs. `zig build test` in `android/native` checks its constructor signatures against the Kotlin models and builds models through a stand-in JVM. The Kotlin has not been compiled. |
| Terminal | Builds for macOS and cross-compiles for x86_64 and aarch64 Linux (Raspberry Pi); 6 tests pass (keys, text fitting and wrapping, colors, status lines). Driven through a pseudo-terminal against WCCLS as a guest: adding the library, search, item details and availability, New Titles, paging, sorting and quitting work. Signed-in screens and holds haven't been tried against a live account. |
| Windows | The core builds for x86_64 and aarch64 Windows. The C# structs in [`Interop.cs`](windows/Biblio/Core/Interop.cs) match the C header's layout as of before the item list (25 structs, checked by script). The C# has not been compiled. |

Zig 0.17's `std.Io.Threaded` does not compile for iOS, so the core uses pthreads there
([`core/src/sync.zig`](core/src/sync.zig)). iOS always uses the app's URLSession transport.

## Porting Plan

Bring the GNOME, Android, Windows and terminal apps to the Apple app's features ([AGENTS.md](AGENTS.md)),
each following its own platform's conventions.

### Targets

| App | Targets | Test on |
|---|---|---|
| Apple | macOS, iOS, iPadOS | iPhone 13 mini, iPhone 17, iPad (A16) |
| GNOME | Linux x86_64 and aarch64, glibc and musl | Fedora Workstation, Alpine Linux (GNOME), Raspberry Pi OS |
| Android | arm64-v8a, x86_64 | Phone, foldable and tablet emulators |
| Windows | x64, ARM64 | Windows 11 |
| Terminal | macOS and Linux, x86_64 and aarch64, glibc and musl | Terminal.app, GNOME Terminal on Fedora, Alpine console |

### 1. Build and run every port

- Compile the Kotlin and C# for the first time, and fix them.
- Move each port's lists onto the core's item list, which brings placeholder rows, the
  people-waiting sort and the hold filters.
- Run the GNOME app on Fedora and Alpine. Alpine needs `*-linux-musl` builds against its own
  packages; keep the Debian sysroot for Raspberry Pi OS.
- Build the terminal app for musl too.
- Add CI: macOS (Apple, terminal), a Fedora container (GNOME, terminal, core tests), Alpine
  (musl), Android (Gradle), and Windows x64 and ARM64 runners. Builds have no warnings.

### 2. Features, by platform convention

| Feature | GNOME | Android | Windows | Terminal |
|---|---|---|---|---|
| Sections | `AdwNavigationSplitView` sidebar | `NavigationSuiteScaffold` (bar on phones, rail on larger screens) | `NavigationView` pane | Tab cycles sections |
| Item detail | `AdwOverlaySplitView` end pane; `AdwBottomSheet` when narrow | `ListDetailPaneScaffold` | Right-hand detail pane | Full-screen detail, Esc to return |
| Refresh | Ctrl+R and F5, menu item | `PullToRefreshBox` | `RefreshContainer`, F5 | `r` |
| Multiple selection | Selection mode button in the header bar; action bar at the bottom | Long press starts selection; contextual top app bar | `SelectionMode="Extended"` and a `CommandBar` | Space marks rows |
| Confirmations | `AdwAlertDialog` | `AlertDialog` | `ContentDialog` | y/n on the bottom line |
| Notices | `AdwToast` | `Snackbar` | `InfoBar` | Bottom line |
| Settings | `AdwPreferencesDialog` (Ctrl+,) | Settings screen | Settings page in the `NavigationView` footer | Account screen, editable |
| Library card | Header-bar button with a popover | Top-app-bar action, full-screen with raised brightness | Header button with a flyout | Account screen |
| Windows and sessions | One session per window, Ctrl+N | One session per task; new task in split screen on large screens | One session per window, Ctrl+N | One session per process |
| Sign in from guest | `AdwDialog` of the library's users | Modal bottom sheet | `ContentDialog` | Prompt |
| Drag to hold or search | `GtkDragSource`/`GtkDropTarget`, across windows | Within the app, and across windows in split screen | `CanDrag`/`AllowDrop`, across windows | None |
| Request status | Fading bar at the window's bottom | None (not a platform convention) | Fading status bar | Bottom line |
| Version and About | `AdwAboutDialog` | Settings ▸ About | Settings ▸ About | `--version` and the help line |
| Restore at launch | Reopen the last windows' logins | Saved state survives process death | Reopen the last windows' logins | Last library |
| Branding | Library accent color in CSS, checked for contrast | Brand color as the color scheme seed | Accent color resources | 256-color tint |
| Icon cache | `$XDG_CACHE_HOME/biblio` | `cacheDir` | `ApplicationData.LocalCacheFolder` | None |

Every port also needs the rest of [AGENTS.md](AGENTS.md):

- advanced search and search facets (the terminal app has neither yet)
- Explore New Titles with its filters
- hold, cancel and partial refusals
- availability by location with status symbols
- pickup location menu
- adding and removing libraries with suggestions and icons
- account settings that save on change and revert on error, with confirmation before turning
  history off (the terminal app only shows them)
- transparent reauthentication, and one window per login
- hidden CMS navigation and "Opinion"

### 3. Localization

Do [TODO.md](TODO.md)'s localization item on every platform, following its language settings:
gettext on GNOME, `strings.xml` on Android, `.resw` on Windows. The library account's language
stays a separate setting.

### 4. Packaging

| App | Package |
|---|---|
| GNOME | Flatpak on Flathub (x86_64, aarch64); APKBUILD for Alpine; RPM spec for Fedora |
| Android | Signed App Bundle for Google Play |
| Windows | MSIX for x64 and ARM64, and a winget manifest |
| Terminal | Release archives per target; Homebrew formula, Alpine package |

Each needs icon.png in the platform's sizes and shape: the GNOME HIG icon style, an Android
adaptive icon, and Windows tile assets.

### Testing

- With the Keychain or .env logins, follow [AGENTS.md](AGENTS.md)'s testing rules on every platform.
- Check narrow layouts: GNOME at 360 px, Android phones, Windows' minimum window size.
- Update the status table above and [README.md](README.md)'s screenshots as each port reaches parity.
