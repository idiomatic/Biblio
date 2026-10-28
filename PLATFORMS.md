# Biblio on Apple, Android, GNOME, Windows and the terminal

Every Biblio app shares one core, **libbiblio**, written in Zig (`core/`). The core is the
BiblioCommons client:

- signing in, and signing in again when a session expires
- the cookie jar
- the gateway API and the library website's Rails account forms
- library lookup and the partner directory
- request pacing
- copy-status grouping, Codabar barcode encoding and brand-color contrast

Each platform has a native UI that follows that platform's design guidelines. The graphical
apps call the core's typed C functions, which take C arguments and return C structs, documented
in [core/include/biblio.h](core/include/biblio.h) and [docs/core.md](docs/core.md):

| Platform | How it calls the core |
|---|---|
| Apple | Swift calls the C functions directly; `apple/Biblio/Net/CoreModels.swift` copies the structs into the app's models. |
| GNOME | Zig calls `biblio.capi` and reads the structs in place. |
| Android | A Zig JNI shim (`android/native/src/jni.zig`) has a native method per operation and builds the Kotlin models with their constructors. |
| Windows | C# P/Invoke with blittable copies of the structs (`windows/Biblio/Core/Interop.cs`). |
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
runs `apple/build-core.sh`, which builds `apple/build/BiblioCore.xcframework`. Run that script
once by hand after a fresh clone, so Xcode finds the framework.

**GNOME.** Needs `gtk4`, `libadwaita-1` (1.6 or later) and `libsecret-1`:

```bash
cd gnome && zig build run
```

`gnome/com.rbrian.Biblio.json` is a Flatpak manifest.

**Android.** Needs Zig on `PATH`, plus the Android SDK and a JDK. Run `gradle wrapper` once,
or open the project in Android Studio. Then:

```bash
cd android && ./gradlew installDebug
```

Gradle builds `libbiblio_jni.so` for arm64-v8a and x86_64 with `android/native/build.zig`.

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

## Status on this branch

| Part | Checked |
|---|---|
| Core | 20 unit and fixture tests pass; the C header's 27 structs match the core's layout. Live guest requests work (library info, search, availability, directory). Cross-compiles for macOS, iOS, the iOS simulator, Linux, Android and Windows. |
| Apple | Builds for macOS and the iOS simulator. On iPhone 17, sign-in, search, item details and availability, the holds list and the holds and checkout counts work through the core's typed functions. |
| GNOME | Type-checks against GTK 4.18, libadwaita 1.7 and libsecret headers. Run it with `zig build check -Dtarget=x86_64-linux-gnu -Dheaders=<sysroot>`, where the sysroot holds headers extracted from Debian's -dev packages. Not linked or run yet. |
| Android | The JNI library builds for both ABIs. `zig build test` in `android/native` checks its constructor signatures against the Kotlin models and builds models through a stand-in JVM. The Kotlin has not been compiled. |
| Terminal | Builds for macOS and cross-compiles for x86_64 Linux; 6 tests pass (keys, text fitting and wrapping, colors, status lines). Driven through a pseudo-terminal against WCCLS as a guest: adding the library, search, item details and availability, New Titles, paging, sorting and quitting work. Signed-in screens and holds haven't been tried against a live account. |
| Windows | The core builds for x86_64 and aarch64 Windows. The C# structs in `Interop.cs` match the C header's layout (25 structs, checked by script). The C# has not been compiled. |

## Notes

- Zig 0.17's `std.Io.Threaded` does not compile for iOS, so the core uses pthreads there
  (`core/src/sync.zig`). iOS always uses the app's URLSession transport.
- Apple features not yet on the other platforms:
  - drag and drop between windows
  - multi-select bulk holds
  - the "people waiting" client sort
  - placeholder rows for unloaded pages
  - library icons
  - the hold-status filter
- The terminal app shows account settings but doesn't change them, and has no format filter
  or advanced search yet.
- Packaging is still to do: Flathub, Play Store, MSIX/winget, and icons.
