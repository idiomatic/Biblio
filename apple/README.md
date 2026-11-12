# Biblio for Apple platforms

The SwiftUI app for macOS, iOS, and iPadOS, over libbiblio, the shared Zig core. Building is in
[DEVELOPMENT.md](../DEVELOPMENT.md).

## Layout

| Folder | Contents |
|---|---|
| `Biblio/Model` | Data models, per-window session state, and the list model that fetches pages for the core's item list |
| `Biblio/Net` | `BiblioClient` (an actor that handles sign-in and re-authentication), the gateway API calls, account-settings form handling, request throttling, and the library directory |
| `Biblio/Store` | Keychain access, and the saved libraries with their branding |
| `Biblio/Views` | SwiftUI views |
| `Shared` | Code shared by the app and its Lock Screen control |
| `BiblioControls` | The iOS Lock Screen and Control Center control that opens the library card |
| `build.zig` | Builds the core for Xcode, which runs it before compiling |
| `Signing.xcconfig` | Includes the Git-ignored `Local.xcconfig` that names your signing team |

## Driving the iOS Simulator

From the repository root:

- **Build and install:** `xcodebuild -project apple/Biblio.xcodeproj -scheme Biblio
  -destination 'platform=iOS Simulator,name=iPad (A16)' -derivedDataPath DIR build`, then
  `xcrun simctl install UDID DIR/Build/Products/Debug-iphonesimulator/Biblio.app`.
- **Launch on the mock library:** `SIMCTL_CHILD_BIBLIO_MOCK=$PWD/core/mock/video xcrun simctl
  launch UDID com.rbrian.Biblio`. The Claude desktop app's iOS Simulator tool can't pass
  environment variables; Xcode's `DeviceInteractionInstallAndRun` (in a workspace session)
  can.
- **Tapping:** Xcode's device-interaction tools (`tools.xcode.DeviceInteraction*`) need a
  session on the UDID and a subagent that loads the `device-interaction` skill; sessions
  close when idle, and text entry wasn't found. The desktop app's tool (Code tab only) taps,
  types, rotates, and screenshots.
- **Appearance:** `xcrun simctl ui UDID appearance dark|light`.
- An unsigned build can't read or save Keychain passwords, so saved cards ask for theirs.
