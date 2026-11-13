# Biblio for Windows

A WinUI 3 app on .NET 10 and Windows App SDK 1.8, over libbiblio, the shared Zig core. `dotnet build` builds the core first (`BuildCore` in [Biblio.csproj](Biblio/Biblio.csproj)) with the `zig` on `PATH`.

## Building

On Windows (x64 or ARM64) with the .NET 10 SDK and Zig 0.17+ (the CI's `ZIG_VERSION`):

```
cd windows\Biblio
dotnet build -p:Platform=ARM64
```

Use `-p:Platform=x64` on x64. The first build restores NuGet packages and takes about 6 minutes.

## Building on a Mac, in a terrarium guest

Windows 11 ARM64 runs as a `terrarium` guest on Apple silicon. Guests are ephemeral: a VM's changes are discarded when it stops unless committed. To rebuild the prepared guest from nothing:

1. **Pull the installer** once (Microsoft's Windows 11 ARM64 ISO), and note its name from `terrarium images`:

   ```
   terrarium pull ~/Downloads/Win11_Arm64.iso
   ```

2. **Install** (about 5 minutes). This accepts Microsoft's license terms, creates the administrator `terra` with automatic login, and prints its random password. The disk must be at least 40 GB. Queue the commit right away, or the installer's shutdown discards the guest:

   ```
   mkdir -p ~/vms
   terrarium start IMAGE --install windows \
     --accept-license --disk 40
   terrarium commit ID ~/vms/win-installed --on-stop
   ```

   Wait until `terrarium ps` no longer lists the VM; `~/vms/win-installed.guest` (about 16 GB) is the clean base.

3. **Prepare** (about 5 minutes for first boot):

   ```
   terrarium start ~/vms/win-installed.guest \
     --tweak windows/no-sleep --tweak windows/no-lock
   ```

   `terrarium ps` shows `tweaking`, then `running`. Poll `terrarium exec --vm ID cmd /c ver` until it answers; `running` alone doesn't mean the helper is up.

4. **Install the toolchain.** Serve [guest-setup.ps1](guest-setup.ps1) from a scratch directory on the Mac and run it in the guest (the host is `192.168.64.1`):

   ```
   mkdir -p /tmp/serve
   cp windows/guest-setup.ps1 /tmp/serve
   python3 -m http.server 8765 \
     --bind 192.168.64.1 --directory /tmp/serve
   terrarium exec --vm ID powershell -NoProfile -Command \
     "iwr -UseBasicParsing http://192.168.64.1:8765/guest-setup.ps1 -OutFile C:\setup.ps1; powershell -ExecutionPolicy Bypass -File C:\setup.ps1"
   ```

   Stop the server, then save the guest, shutting Windows down cleanly so the disk is consistent:

   ```
   terrarium exec --vm ID powershell -NoProfile -Command \
     "Remove-Item C:\setup.ps1"
   terrarium commit ID ~/vms/win-dev --on-stop
   terrarium exec --vm ID shutdown /s /t 0
   ```

   `~/vms/win-dev.guest` (about 23 GB) holds Zig, the .NET SDK, and the NuGet cache.

   If the guest can't download (`dot.net` closed the connection), fetch the toolchain on the Mac instead: the Zig 0.17.1 `aarch64-windows` zip from <https://ziglang.org/download/index.json> and the .NET 10 SDK `win-arm64` zip from <https://builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json>, checking each hash. `put` them in, expand them with `tar -xf` under `C:\tools\zig` and `C:\tools\dotnet`, and set the machine `Path` and `DOTNET_ROOT` as `guest-setup.ps1` does. NuGet restores from inside the guest.

5. **Build.** Start the prepared guest and wait for `exec` as above. Send the source as a tarball through the same scratch directory and server (`COPYFILE_DISABLE=1` keeps macOS `._*` files, which MSBuild reads as extra projects, out of it; leave out `.git`, `apple`, `android`, `gnome`, and build outputs), then build in the guest:

   ```
   COPYFILE_DISABLE=1 tar -czf /tmp/serve/biblio.tgz \
     --exclude=.git --exclude=apple --exclude=android \
     --exclude=gnome --exclude=docs --exclude=bin \
     --exclude=obj --exclude=native --exclude=.zig-cache .
   terrarium exec --vm ID powershell -NoProfile -Command \
     "mkdir C:\src; iwr -UseBasicParsing http://192.168.64.1:8765/biblio.tgz -OutFile C:\b.tgz; tar -xzf C:\b.tgz -C C:\src; cd C:\src\windows\Biblio; dotnet build -p:Platform=ARM64"
   ```

   Long builds outlast one `exec`: start them detached with a log file and poll it, through a scheduled task as under Troubleshooting. The first build takes about 5 minutes; later ones, under 30 seconds. A tarball expanded over an earlier one keeps the Mac's file times, which the guest may read as older than its build output, so MSBuild skips the changed files: set each source file's `LastWriteTime` to now after expanding.

## Screenshots

Frames follow [docs/screenshots/README.md](../docs/screenshots/README.md). In a prepared guest with the app built:

1. Silence notifications and kill OneDrive, which draws toasts over the app: `Set-ItemProperty HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications ToastEnabled 0` (creating the key first if needed) and `Stop-Process -Name OneDrive`.
2. Start `Biblio.exe` with `BIBLIO_MOCK=C:\src\core\mock\books`, add `first…` (FirstLanding), and choose Browse as Guest, which opens a second window.
3. Maximize that window. The guest display is fixed at 1024×768 (the VirtIO GPU's resolution setting is greyed out), and the app opens at 1200×800 with a minimum height beyond the screen, so it can't be placed smaller.
4. Search `Wells` and select Rogue Protocol.
5. Park the pointer on the taskbar, which is cropped out, then press Alt+Tab to give the window focus back (a click on the taskbar leaves its title bar buttons grey).
6. Capture with `terrarium shot --vm ID > full.png` repeatedly until two consecutive captures are identical (the display lags input by several seconds), then crop the top 1024×720.

## Troubleshooting

* Don't change the guest's DNS servers or toggle its adapter. Doing so dropped the DHCP lease (a `169.254.x.x` address); `Restart-NetAdapter -Name Ethernet` restores it.
* `Biblio.exe` finds no .NET unless `DOTNET_ROOT` is set (`guest-setup.ps1` sets it machine-wide, for new sessions).
* A process started in the background through `terrarium exec` (`Start-Process`) is killed when the `exec` returns; to start `Biblio.exe` on the desktop, register a scheduled task that runs interactively and start it.
* Launch `Biblio.exe` itself, from its output folder (`bin\ARM64\Debug\net10.0-windows10.0.22621.0`). Starting `Biblio.dll` through `dotnet.exe` crashes in `Microsoft.UI.Xaml.dll` (stowed exception `0xc000027b`).
* The core is copied beside the app as `libbiblio.dll`, because Windows file names ignore case and `biblio.dll` collided with the app's own `Biblio.dll`.
* Windows shows notifications (OneDrive, for one) over the app and takes clicks meant for it; dismiss them first.
* To screenshot against the mock library, set `BIBLIO_MOCK=C:\src\core\mock\books` (or `video`) in the environment of the process that starts `Biblio.exe`, then add `firstlanding`.
