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
    %LOCALAPPDATA%\DTSys\Wolium\   usage.db, lang, consent (outside the install folder, never touched by install or update)

Installing into a folder with existing files replaces the files from the package and keeps everything else, and the data folder.

What lives outside the folder: the Start menu and desktop shortcuts and, if autostart is enabled, a `HKCU\...\Run` value. Deleting the folder by hand removes the program and its data, but leaves those shortcuts and the autostart value (harmless, they just point to nothing). `uninstall.exe` removes them too. It asks whether to remove the data folder as well (Yes: remove everything, No: remove the app and keep my data). It deletes only files listed in `manifest.txt`, so files of your own in the folder survive.

The service keeps counters in RAM and writes them to `usage.db` (WAL) every 3 minutes, on focus change, on exit, and when the UI asks. The heartbeat lives in shared memory, not on disk, and the UI reads it from there. Service flags: `--background`, `--db PATH`, `--no-db`, `--interval MS`.

## Localization

No user-facing text is hardcoded in code. C++ strings live in `i18n/include/tw/lang/<code>.def` (one file per language, `en.def` is the reference and the fallback), Flutter strings in `ui/lib/l10n.dart`. The chosen language is stored in `%LOCALAPPDATA%\DTSys\Wolium\lang` and shared by the installer, uninstaller, tray menu and UI. A test checks that every language has every key. To add a language: add `<code>.def`, one line in `i18n.hpp` and one map in `l10n.dart`.

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

## Runtime layout

Installed by default to `%LOCALAPPDATA%\Programs\DTSys\Wolium` (any folder can be chosen).

| File | Role |
|---|---|
| `trackwolium.exe` | Guard: tray icon + supervisor. Starts at Windows logon (`--background`), restarts the core, notifies if it dies. |
| `trackwolium-core.exe` | Collector. Runs only after consent. |
| `wolium.exe` | Flutter UI. Starts the service if it is not running. |
| `uninstall.exe` | Uninstaller (optionally keeps `userdata`). |
| `%LOCALAPPDATA%\DTSys\Wolium\` | `consent`, `lang`, `paused`, `usage.db`. |

Privacy: nothing is recorded and no tray is started until the consent file exists
(created by accepting the policy in the UI/installer, removed by withdrawing it in Settings).

Language: the installer and apps pick the system UI language (Russian or English fallback);
the choice is stored in `%LOCALAPPDATA%\DTSys\Wolium\lang`. Add a language with a new `i18n/include/tw/lang/<code>.def`.

Tray states: Active, Paused, Updating, Error (a colored dot on the icon).

Tray death watch: the core watches the tray process. If it exits without the clean-exit event (crash, End task), the core shows its own tray icon and a notification; clicking restores the tray.
Installer: knows the installed version (`version.txt`) and offers Reinstall when the same version is already installed.

Activity graph: the core also stores a 5-minute timeline (`timeline` table, visible states only). The UI draws focus time per 15 minutes as a smooth spline with a tooltip; clicking an app row filters the graph to that app.
Windows integration: the installer registers `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\DTSys.Wolium` (removed by `uninstall.exe`). Setup has three states: Install, Update (installed version older), Reinstall (same version), plus an Uninstall button when installed.

Graph interaction: wheel zooms time, left-drag pans, middle click or double click resets, hover the line for a cursor-attached tooltip, click to pin it (then rows are clickable and open the session list). On touch: tap shows an anchored tooltip, pinch zooms, one finger pans, double tap resets. App icons come from the exe path stored in the `apps` table.
Versions: CI builds as `<tag>.<run number>`, so every build is newer than the previous one and the installer offers Update.
