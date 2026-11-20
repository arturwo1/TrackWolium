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

## Resource metrics

Off by default. When enabled they are kept in memory and written to the database together with the regular batch, so there is no extra background disk activity. They are recorded only for apps with a visible window. Settings shows the expected monthly database growth for your current activity.
