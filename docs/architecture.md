# Architecture

Two separate processes:

- **Core** (C++17): samples the foreground window and process state, keeps counters in RAM and flushes them to SQLite in batches. Platform code lives in `platform/` and the `app_*` folders.
- **UI** (Flutter, `ui/`): reads the database read-only and talks to the core through small flag files in the data folder and a local RPC.

The core keeps running when the UI is closed.

| Folder | Role |
|---|---|
| `core/` | engine, trackers, process statistics, local API routing |
| `platform/` | window and process probes for Windows, Linux, macOS |
| `storage/` | SQLite store |
| `ipc/` | core to UI RPC |
| `i18n/` | translations, generated from `i18n/translations/*.json` |
| `app_win/`, `app_linux/` | executables: core, guard, installer |
| `ui/` | Flutter UI and Android templates |

## Flag files

The UI and the core coordinate through plain files in the data folder: `consent`, `localapi`, `discordrpc`, `noupdates`, `paused`, `metrics`. The UI also keeps `columns` and `colwidths` for the table.

## Windows control

Focusing and closing apps from the UI uses native Win32 calls through Dart FFI. No PowerShell or other helper processes are involved.

## Resource metrics

A per-process tracker computes deltas per PID every 10 seconds, results are summed per app in 5-minute slots and flushed with the regular batch. Memory is private memory, CPU is normalized by logical core count.
