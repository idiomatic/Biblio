# Biblio on Apple, Android, GNOME and Windows

Every Biblio app shares one core, **libbiblio**, written in Zig (`core/`). The core is the
BiblioCommons client:

- signing in, and signing in again when a session expires
- the cookie jar
- the gateway API and the library website's Rails account forms
- library lookup and the partner directory
- request pacing
- copy-status grouping, Codabar barcode encoding and brand-color contrast

Each platform has a native UI that follows that platform's design guidelines. Each UI talks
to the core through one JSON-in, JSON-out C function, documented in
[core/include/biblio.h](core/include/biblio.h) and [docs/core.md](docs/core.md).

| Platform | UI | Language | Passwords | HTTP |
|---|---|---|---|---|
| macOS, iOS, iPadOS | SwiftUI | Swift | Keychain | URLSession, through the core's transport hook |
| GNOME (Linux) | GTK 4 + libadwaita, GNOME HIG | Zig | Secret Service (libsecret) | Zig `std.http` |
| Android | Jetpack Compose, Material 3 | Kotlin + a Zig JNI shim | Android Keystore (AES-GCM) | Zig `std.http` (reads the system CA store) |
| Windows | WinUI 3, Fluent | C# | Credential Locker | Zig `std.http` (reads the Windows cert store) |

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

**Apple.** Open `Biblio.xcodeproj` and build. The "Build libbiblio" phase runs
`apple/build-core.sh`, which builds `apple/build/BiblioCore.xcframework`. Run that script once
by hand after a fresh clone, so Xcode finds the framework.

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

## Status on this branch

| Part | Checked |
|---|---|
| Core | 17 unit and fixture tests pass. Live guest requests work (library info, search, availability, directory). Cross-compiles for macOS, iOS, the iOS simulator, Linux, Android and Windows. |
| Apple | Builds for macOS and the iOS simulator. On iPhone 17, sign-in, search, item details and availability, and the holds and checkout counts work through the core. |
| GNOME | Type-checks against GTK 4.18, libadwaita 1.7 and libsecret headers. Run it with `zig build check -Dtarget=x86_64-linux-gnu -Dheaders=<sysroot>`, where the sysroot holds headers extracted from Debian's -dev packages. Not linked or run yet. |
| Android | The JNI library builds for both ABIs. The Kotlin has not been compiled. |
| Windows | The core builds for x86_64 and aarch64 Windows. The C# has not been compiled. |

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
- Packaging is still to do: Flathub, Play Store, MSIX/winget, and icons.
