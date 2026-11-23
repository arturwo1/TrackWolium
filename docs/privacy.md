# Privacy and data

Data is stored in a local SQLite file and never uploaded. Nothing is recorded until you accept the privacy policy: https://wolium.netlify.app/privacy-policy/

| Platform | Data folder |
|---|---|
| Windows | `%LOCALAPPDATA%\DTSys\Wolium` |
| Linux | `~/.local/share/DTSys/Wolium` |
| macOS | `~/Library/Application Support/DTSys/Wolium` |
| Android | app storage, included in Android's own backup when enabled |

Updating never touches your data, uninstalling asks first.

Each device gets a random `device_id` (UUIDv4, no hardware identifiers) and an editable name in Settings, stored in the data folder.

## Resource metrics, power states & browser titles

- **Resource & hardware metrics**: Off by default on desktop collectors. When enabled they are kept in memory and written to the database together with the regular batch (`res` and `sysmon` tables), so there is no extra background disk activity. Settings shows the expected monthly database growth for your current activity.
- **Power states**: `sys_events` records timestamps and durations of local sleep, hibernate, lock, reboot, and shutdown transitions.
- **Browser website tracking**: Only recorded when you explicitly install the local browser extension (desktop) or enable Wolium's Accessibility Service on Android. Stores domain, sanitized page title, active URL, and duration locally in `browser_usage` and `browser_timeline`.
- **LAN P2P sync**: Devices sync directly over your local network only with peers explicitly paired using a short-lived 6-digit PIN; no external servers are involved.

