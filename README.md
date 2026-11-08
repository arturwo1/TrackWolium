# TrackWolium

Modular tracker of running applications. The core is C++17 with no dependencies.

## App states

- focused: the window has focus
- open: a window is open but not focused
- minimized: the window is minimized
- background: the process runs without a window

## Install layout

Users download a single `WoliumSetup.exe` from a GitHub Release. The installer asks for a folder and puts everything there:

    <folder>\trackwolium.exe   service with tray icon: tracks time, writes SQLite, tray menu "Open" and "Exit"
    <folder>\wolium.exe        Flutter UI (plus Flutter dlls and data)
    <folder>\uninstall.exe     uninstaller
    <folder>\userdata\         usage.db, ui.json

Deleting the folder (or running `uninstall.exe`) removes Wolium. Outside the folder there are only shortcuts and, if autostart is enabled, a `HKCU\...\Run` value. If the chosen folder is not empty and does not contain Wolium, the installer uses a `Wolium` subfolder. The uninstaller only deletes a folder that contains both `trackwolium.exe` and `uninstall.exe`.

The service writes history to `userdata\usage.db` every 3 seconds, the UI reads it read-only. If the file has not been updated for 30 seconds, the UI shows "The service is not responding". Service flags: `--background`, `--db PATH`, `--no-db`, `--interval MS`.

## Build

    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
    cmake --build build --config Release

`.github/workflows/release.yml` builds a release on a `v*` tag: Flutter UI, service, installer, uninstaller. `tools/pack_installer.py` appends a zip with the files to `WoliumSetup.exe`; extraction uses the `tar.exe` built into Windows 10+.

## Console (for debugging)

`trackwolium-console` shows the same table in a terminal and also works on Linux. Flags: `--interval MS`, `--top N`, `--for SECONDS`, `--no-color`, `--system`, `--all`, `--ignore a.exe,b.exe`, `--db PATH`, `--no-db`, `--history N`, `--standalone`.

Apps that never had a window and Windows shell helpers are hidden by default. `--all` shows everything. Where the platform cannot see windows (Linux for now) the filter is disabled automatically.

## SmartScreen

The blue screen appears for unsigned exe files marked as downloaded from the internet. For your own use: right-click the file or zip, Properties, "Unblock" (or `Unblock-File`), or build locally. For distribution see code signing options (Microsoft Store MSIX, Azure Artifact Signing, OV certificate).

## Tests

    ctest --test-dir build --output-on-failure

## Modules

- core: types, Tracker (time per state), Engine (loop), filter, IProbe and ISink interfaces
- platform: IProbe implementations (windows, linux), data paths
- storage: SQLite (vendored amalgamation) and SqliteStore
- ipc: named pipe between the service and a console viewer (Windows)
- ui_console: ConsoleSink, table output
- capi: C ABI for Flutter FFI, JNI and other languages
- app: `trackwolium-console`
- app_win: service with tray icon `trackwolium` (Windows)
- installer: `WoliumSetup` and `uninstall` (Windows)
- ui: Flutter interface
- tests: tests without external libraries

## New platform

Implement IProbe and return it from `make_native_probe`, or feed data from outside through PushProbe (this is how Android works: Kotlin collects UsageEvents and passes them via `tw_add_sample` and `tw_step`).

## Checking Linux and Android without installing them

`.github/workflows/ci.yml` builds and tests the project on windows-latest and ubuntu-latest, and builds the core with the C API for Android arm64 via the NDK.
