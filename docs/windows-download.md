# Windows: download blocked or deleted

Wolium is not code-signed yet. Windows decides whether to trust an unsigned `.exe` by reputation, and a brand-new file has none. This is not specific to Wolium and does not mean the file is malicious, but you should still verify it before running.

Wording differs a little between Windows builds.

## What can block it

| Where | What you see | Why |
|---|---|---|
| Edge / Chrome download | "isn't commonly downloaded" or the file disappears | SmartScreen download reputation |
| Opening the file | "Windows protected your PC" | SmartScreen, file has the internet *Mark of the Web* |
| Fresh Windows 11 | "Smart App Control blocked part of this app" | Smart App Control blocks unsigned apps, no override per file |
| Defender | file quarantined | cloud reputation of a new file |

## Step 1: verify the file

Download `SHA256SUMS.txt` from the same release and compare:

    certutil -hashfile WoliumSetup.exe SHA256

The printed hash must match the `WoliumSetup.exe` line in `SHA256SUMS.txt`.

Every release also has a GitHub build attestation proving the file was built from this repository by the release workflow:

    gh attestation verify WoliumSetup.exe --repo arturwo1/trackwolium

Do not continue if either check fails.

## Step 2: allow the file

**Edge:** open Downloads (`Ctrl+J`), open the `...` menu next to the file, choose *Keep*, then *Show more* and *Keep anyway*.

**Chrome:** in the download bubble choose *Keep*.

**Windows protected your PC:** choose *More info*, then *Run anyway*.

**File Explorer:** right-click `WoliumSetup.exe`, *Properties*, tick *Unblock* at the bottom of the General tab, *OK*.

**Defender quarantined it:** Windows Security, *Virus & threat protection*, *Protection history*, select the item, *Actions*, *Allow on device*. Download again if the file was removed.

## Smart App Control

On some fresh Windows 11 installs Smart App Control starts in evaluation mode and then blocks unsigned apps with no "Run anyway" option. Your choices:

- turn it off: Windows Security, *App & browser control*, *Smart App Control settings*, *Off*. Windows does not let you turn it back on without reinstalling, so decide consciously
- wait for a signed release
- build from source, see [Building](building.md)

## Why not just sign it

A code-signing certificate costs money every year and a new publisher still needs time to build reputation. Signing is planned, until then the hash and attestation checks above are the way to confirm the file.
