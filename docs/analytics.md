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

- Min. seconds hides apps below the threshold in the table and chart.
- Average draws the mean of the non-empty buckets in view.
- Previous period overlays the same range shifted back by its own length.
- Launches in the app detail tooltip counts focus sessions in the bucket.

## Hotkeys (Windows)

- Ctrl+Shift+W opens or raises the window.
- Ctrl+Shift+P pauses or resumes tracking.
- If another program owns a combination, it is silently skipped.
