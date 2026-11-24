# Analytics, AFK and categories

## Real focus (AFK)

- The core compares the time since the last keyboard or mouse input with the AFK threshold (Settings, default 5 min, can be off).
- Focus time spent beyond the threshold is stored separately in the `afk` table, in RAM until the regular batch flush, so there is no extra disk traffic.
- Options, "Show only real focus" subtracts it from the chart and the table. It needs time collection to be on.
- Idle source: Windows `GetLastInputInfo`, Linux X11 via libXss (not available on Wayland), macOS `CGEventSourceSecondsSinceLastEventType`.
- Android has no idle input counter. Sessions already end when the screen turns off or the keyguard appears, so Android time is real focus.
- With real focus on, the chart uses 5-minute buckets instead of exact sessions.

## Categories

- Settings, App categories: name, colour, preset icon or your own image, and the apps in it. An app belongs to one category.
- Apps can also be assigned from a row's context menu (long press on Android).
- The chart and the table can be filtered by category; the table has a sortable Category column; the summary under the chart shows time per category.
- Stored in `categories.json` (images in `catimg/`) in the data folder.

## Chart options

- **Min. / Max. seconds**: filters apps in the table and across all chart lines (time, opens, notifications, CPU/resource lines, including when time collection is off), and filters duration-based power state lines (`sleep`, `hibernate`, `lock`).
- **Average**: draws the mean of the non-empty buckets in view.
- **Previous period**: overlays the same range shifted back by its own length.
- **Launches**: in the app detail tooltip counts focus sessions in the bucket.

## System power states

- Tracks `sleep`, `hibernate`, `lock`, `reboot`, and `shutdown` events in `sys_events` with timestamps and durations where available:
  - **Windows**: `WM_POWERBROADCAST` (`PBT_APMSUSPEND` / resume), `WTS_SESSION_LOCK` / `UNLOCK`, `WM_QUERYENDSESSION` / `WM_ENDSESSION`, and clean boot/reboot detection.
  - **Linux**: systemd-logind / D-Bus signals (`PrepareForSleep`, `PrepareForShutdown`, `Session.Lock` / `Unlock`).
  - **macOS**: `NSWorkspace` sleep/wake, session lock/unlock notifications, and reboot/shutdown detection.
  - **Android**: screen off / keyguard / shutdown usage events recorded into `sys_events`.
- Selectable individually as chart lines (`power_sleep`, `power_hibernate`, `power_lock`, `power_reboot`, `power_shutdown`).

## Battery & power telemetry

- **System battery charge (`battery`)**: sampled on Android (via WorkManager / active bridge) and laptops/UPS systems on Windows, Linux, and macOS (`sysmon` `kind = 'battery'`, storing percentage and charging flag), rendered on a 0–100% chart scale and shown in the Global summary.
- **Per-app battery drain (`appbattery`)**: attributed from Android active screen/foreground battery discharge (`app_stats` / `slot_stats` `kind = 'battery'`, stored in tenths of %), available as a chart line, sortable table column, Global summary total, and CSV export column across paired devices.

## Global system values & multi-device LAN sync

- Below the chart, segmented tabs (**Applications** / **Global system values**, also swipeable horizontally on narrow screens) switch between the apps view and the system summary:
  - Latest **RAM** (total, used, free), **Battery** (current charge/charging state and estimated app battery drain), and per-mount **Disk** capacity (total, used, free).
  - Period **Activity totals** (focused, visible, total, AFK, opens, notifications, unlocks).
  - **Power states** table with counts and total durations for sleep, hibernate, lock, reboot, and shutdown.
- Peer-to-peer LAN synchronization transfers the **entire recorded database history** (without artificial day caps), and automatically refreshes stale peers (older than 60 minutes) on app launch, foreground resume, and periodic background `SyncWorker` runs.
- When paired remote devices are toggled on, their full columns (`focused`, `realcol`, `open`, `minimized`, `background`, `appbattery`, `cpu`, `ram`, `peak`, `ior`, `iow`), chart lines, sorting options, and CSV export columns unlock dynamically.

## Hotkeys (Windows)

- Ctrl+Shift+W opens or raises the window.
- Ctrl+Shift+P pauses or resumes tracking.
- If another program owns a combination, it is silently skipped.

