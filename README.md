<div align="center">

<img src="assets/icon/wolium_128.png" width="96" alt="Wolium">

# Wolium

**Private activity tracker. Your data stays on your device.**

<a href="https://github.com/arturwo1/trackwolium/releases/latest/download/WoliumSetup.exe"><img src="https://img.shields.io/badge/Windows-WoliumSetup.exe-0078D4?style=for-the-badge&logo=data:image/svg%2Bxml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0id2hpdGUiPjxwYXRoIGQ9Ik0wIDMuNDQ5TDkuNzUgMi4xdjkuNDUxSDBtMTAuOTQ5LTkuNjAyTDI0IDB2MTEuNEgxMC45NDlNMCAxMi42aDkuNzV2OS40NTFMMCAyMC42OTlNMTAuOTQ5IDEyLjZIMjRWMjRsLTEzLjA1MS0xLjg1MSIvPjwvc3ZnPg%3D%3D" alt="Download for Windows"></a>
<a href="https://github.com/arturwo1/trackwolium/releases/latest/download/Wolium.apk"><img src="https://img.shields.io/badge/Android-Wolium.apk-3DDC84?style=for-the-badge&logo=android&logoColor=white" alt="Download for Android"></a>
<a href="https://github.com/arturwo1/trackwolium/releases/latest/download/Wolium-linux-x86_64.tar.gz"><img src="https://img.shields.io/badge/Linux-tar.gz-FCC624?style=for-the-badge&logo=linux&logoColor=black" alt="Download for Linux"></a>
<a href="https://github.com/arturwo1/trackwolium/releases/latest/download/Wolium-macos.dmg"><img src="https://img.shields.io/badge/macOS-Wolium.dmg-000000?style=for-the-badge&logo=apple&logoColor=white" alt="Download for macOS"></a>

<img src="assets/screenshot.png" width="860" alt="Wolium preview">

</div>

> [!NOTE]
> **100% local.** No account, no cloud, no telemetry. Nothing is recorded until you accept the privacy policy, and your history never leaves your device.

## Why Wolium

| | |
|---|---|
| **See where the time goes** | Interactive graph and per-app table: focused, open, minimized, background |
| **Zero background load** | No periodic disk writes, a quiet native core and a separate UI process |
| **Resources, if you want them** | CPU, RAM and disk I/O per app on the same graph, off by default |
| **Everywhere** | Windows, Linux, macOS and Android, English and Russian |
| **Yours to use** | CSV export, local API with an OBS widget, Discord activity cards |

## Install

| Platform | |
|---|---|
| Windows 10 / 11 | Run `WoliumSetup.exe` |
| Android 8+ | Open `Wolium.apk`, then grant *Usage access* |
| Linux | Extract the archive, run `./install.sh` |
| macOS 11+ | Open the `.dmg`, drag to Applications |

> [!WARNING]
> Wolium is not code-signed yet, so Windows and macOS warn on first start. On a fresh Windows 11 the download may even be blocked before you can open it. See the [Windows download guide](docs/windows-download.md) for the safe way through and how to verify the file.

<details>
<summary><b>Other formats and store builds</b></summary>

| File | What it is |
|---|---|
| [`Wolium.msix`](https://github.com/arturwo1/TrackWolium/releases/latest/download/Wolium.msix) | Microsoft Store package, no built-in updater, optional start with Windows |
| [`Wolium.aab`](https://github.com/arturwo1/TrackWolium/releases/latest/download/Wolium.aab) | Google Play bundle, no self-updater, no install permission |
| [`SHA256SUMS.txt`](https://github.com/arturwo1/TrackWolium/releases/latest/download/SHA256SUMS.txt) | Checksums of every release file |

Store builds update through the store. Details in [Building](docs/building.md).

<!--
<a href="https://apps.microsoft.com/detail/REPLACE_WITH_STORE_ID"><img src="https://img.shields.io/badge/Microsoft_Store-Get_it-0078D4?style=for-the-badge&logo=microsoft&logoColor=white" alt="Get it from Microsoft Store"></a>
<a href="https://play.google.com/store/apps/details?id=io.github.arturwo1.wolium"><img src="https://img.shields.io/badge/Google_Play-Get_it-34A853?style=for-the-badge&logo=googleplay&logoColor=white" alt="Get it on Google Play"></a>
-->

</details>

<details>
<summary><b>Graph controls</b></summary>

| Action | Mouse | Touch |
|---|---|---|
| Zoom | wheel | pinch |
| Pan | drag | drag |
| Reset | middle or double click | double tap |
| Details | hover the line, click to pin | tap, or long press and drag |

</details>

<details>
<summary><b>What differs by platform</b></summary>

| | Windows | Linux | macOS | Android |
|---|---|---|---|---|
| Four activity states | yes | yes | yes | focused only |
| Resource metrics | yes | yes | yes | no |
| Local API | yes | yes | yes | yes |
| Discord activity | yes | yes | yes | no |

More in [platforms](docs/platforms.md).

</details>

## Documentation

| | |
|---|---|
| [Windows download and SmartScreen](docs/windows-download.md) | blocked or deleted installer, hash and attestation check |
| [Local API](docs/local-api.md) | endpoints, parameters, OBS widget |
| [Platforms](docs/platforms.md) | Android, Linux Wayland, macOS notes |
| [Updates](docs/updates.md) | when and how Wolium checks for updates |
| [Analytics, AFK, categories](docs/analytics.md) | real focus, categories, chart options, hotkeys |
| [Privacy and data](docs/privacy.md) | what is stored and where |
| [Architecture](docs/architecture.md) | core, UI, storage |
| [Building](docs/building.md) | build, tests, translations, CI |

## License

Proprietary, see [LICENSE](LICENSE). Contributions: [CONTRIBUTING.md](CONTRIBUTING.md).
