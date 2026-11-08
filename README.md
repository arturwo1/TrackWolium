# TrackWolium

Modular tracker of running applications. The core is C++17 with no dependencies.

## App states

- focused: the window has focus
- open: a window is open but not focused
- minimized: the window is minimized
- background: the process runs without a window

## Install layout

Users download a single `WoliumSetup.exe` from a GitHub Release. The installer lets you pick the language (English, Russian) and the folder (default `%LOCALAPPDATA%\Programs\Wolium`) and puts everything there:

    <folder>\trackwolium.exe   service with tray icon: tracks time, writes SQLite, tray menu
    <folder>\wolium.exe        Flutter UI (plus Flutter dlls and data)
    <folder>\uninstall.exe     uninstaller
    <folder>\manifest.txt      list of installed files
    <folder>\userdata\         usage.db, ui.json, lang (never touched by install or update)

Installing into a folder with existing files replaces the files from the package and keeps everything else, including `userdata`.

What lives outside the folder: the Start menu and desktop shortcuts and, if autostart is enabled, a `HKCU\...\Run` value. Deleting the folder by hand removes the program and its data, but leaves those shortcuts and the autostart value (harmless, they just point to nothing). `uninstall.exe` removes them too. It asks whether to remove the data as well or keep `userdata` (Yes: remove everything, No: remove the app and keep my data). It deletes only files listed in `manifest.txt`, so files of your own in the folder survive.

The service writes history to `userdata\usage.db` every 3 seconds, the UI reads it read-only. If the file has not been updated for 30 seconds, the UI shows a warning. Service flags: `--background`, `--db PATH`, `--no-db`, `--interval MS`.

## Localization

No user-facing text is hardcoded in code. C++ strings live in `i18n/include/tw/lang/<code>.def` (one file per language, `en.def` is the reference and the fallback), Flutter strings in `ui/lib/l10n.dart`. The chosen language is stored in `userdata\lang` and shared by the installer, uninstaller, tray menu and UI. A test checks that every language has every key. To add a language: add `<code>.def`, one line in `i18n.hpp` and one map in `l10n.dart`.

## Icon

`tools/make_icon.py` generates `assets/icon/wolium.ico` and PNGs (128, 256, 512) for Android and Linux. The ico is embedded into all exe files (`res/*.rc`, also version info shown in Task Manager) and into the Flutter runner (`ui/tool/patch_windows.py`).

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
- i18n: language tables (en, ru) and language selection
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
