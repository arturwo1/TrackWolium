# Updates

- **Android:** once a day, only while charging, idle and on an unmetered network, Wolium checks for a release, downloads the APK into its cache and posts a "ready to install" notification. Checks are skipped if one ran in the last 6 hours.
- **Windows:** the background part checks every 6 hours, only on an unmetered connection (Wi-Fi or Ethernet), and prefers moments when the network is already busy. It also checks after wake-up, unlock, a network change, a power-source change, and when a monitor is connected, disconnected or the display configuration changes. Event-driven checks are limited to one per 20 minutes. When the screen comes back and an update is waiting, the notification is repeated at most every 20 minutes.
- **Linux, macOS:** the background part checks every 6 hours and after wake-up, unlock, network or power changes.
- Updates are downloaded quietly. If the Wolium window is closed the update installs silently and a notification confirms it. If the window is open, a banner offers "Restart and apply".
- On Windows nothing is shown or installed while a full-screen app or Focus Assist is active. The check is retried a few minutes later.
- The last check result is written to `update.status` in the data folder.
- Settings has a switch to turn background update checks off.
