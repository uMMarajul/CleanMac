# CleanMac

**Understand everything using your Mac's storage, find what you don't need, and safely get your disk space back.**

CleanMac is a native macOS app, written in Swift and SwiftUI, that measures your disk, explains where the space goes (including the mysterious *System Data*), and cleans junk safely. Everything it removes goes to the Trash first and can be put back from inside the app.

> A demo video and screenshots are coming soon.

## Features

**Storage analysis**
- **Smart Scan** measures your whole data volume in about a minute, using parallel scanning.
- **System Data analyzer** sorts storage into 22 categories (app caches, browser caches, Xcode, simulators, Docker, package caches, logs, mail, backups, VMs, and more). Every byte is counted exactly once. Measured, uncategorized, macOS-volume, and unaccounted space are shown separately, and CleanMac never claims to match Apple's own System Data number.
- **Storage Explorer** lets you browse folders by size, sort, and search.
- **Large Files** shows a sortable table with size and type filters.
- **Duplicate Finder** compares file *contents* (size, then the first 4 KB, then a full SHA-256) and always keeps at least one copy.

**Cleaning**
- **Junk Cleaner** offers Quick Scan (known junk locations) or Deep Scan (the whole disk), with Quick Look previews and a cleanup report.
- **Hidden app caches**: finds the Chromium/Electron caches that apps like Slack, VS Code, Discord, and Claude keep inside Application Support.
- **Developer Cleaner** covers Xcode DerivedData and Archives, device support files, simulator runtimes, Docker images and build cache, and npm, pnpm, Yarn, Gradle, Maven, pip, Poetry, Go, and Cargo caches.
- **Cleanup History** lists everything CleanMac removed, with **Put Back**.

**Applications**
- Lists every installed app with its size, leftover data, last-opened date, and usage label (Recently Used through Long Unused).
- **App details**: see where an app's space goes, drill into its biggest folders, and **Clear Cache** or **Remove Logs** without uninstalling.
- **Complete uninstaller**: removes the app plus its leftovers, matched by exact bundle identifier only, with an option to keep preferences and user data. Shared group containers are never removed.
- **Leftovers of removed apps**: Library files left behind by apps that are no longer installed.

**System**
- **Performance**: live CPU (total and per core), memory and memory pressure, disk and network speed, battery health and cycle count, and a process list with Quit and Force Quit for your own apps.
- **Startup Items**: your launch agents (enable, disable, remove), system-wide agents and daemons, and the full Login Items list (read with your administrator password).
- **Privacy**: browser cache, history, and cookie sizes for Safari, Chrome, Edge, Brave, Arc, Vivaldi, Opera, and Firefox, plus browser extensions, app permissions (camera, microphone, screen recording…), and an exportable privacy report.
- **Automation**: scheduled scans with notifications, optional automatic cleanup of Safe categories only, and low disk space alerts.
- **Menu bar** item with free space, CPU, memory pressure, junk found, and Quick Scan.
- **Recommendations** on the Dashboard suggest the most useful next steps.

## Safety first

Cleaning is only useful if it never breaks anything. CleanMac is built around that:

- **Every item gets a label:** **Safe** (cache or temporary data that apps rebuild), **Review** (may contain your data, so you decide item by item), or **Protected** (never removable).
- **One cleanup engine:** every removal in the app goes through it. It checks the location, permissions, whether the owning app is running, and the current size before anything moves.
- **Trash first:** items go to the Trash and can be put back from Cleanup History. The only permanent actions are Empty Trash and tool-specific cleanups (Docker, simulators). Each asks for explicit confirmation and says it can't be undone.
- **Never touched:** the macOS system volume, system-owned folders, your documents, Keychain items, Docker volumes, source code, or git repositories.
- **Permissions on demand:** Full Disk Access is explained up front, and the administrator password is only asked for when a feature needs it (measuring system-owned folders, reading all login items, removing system-owned apps). macOS asks for the password, never CleanMac.
- **Offline:** all scanning and cleaning work without an internet connection, and nothing leaves your Mac.

## Requirements

- macOS 14 Sonoma or later, on Apple Silicon or Intel
- Xcode to build from source (developed with Xcode 27)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), which generates the Xcode project from `project.yml`

## Build and run

```bash
brew install xcodegen
git clone https://github.com/uMMarajul/CleanMac.git
cd CleanMac
xcodegen generate
open CleanMac.xcodeproj
```

Then press **Run** (⌘R) in Xcode.

### Full Disk Access

CleanMac needs **Full Disk Access** to measure protected folders such as Mail, Messages, and app containers. When it's missing, the app shows a banner that opens the right System Settings page. Turn on CleanMac there, then relaunch it.

macOS ties this permission to the app's code signature. The project signs ad hoc by default, so anyone can build it, but an ad-hoc signature changes with every build and macOS then forgets the permission. To keep it across rebuilds, sign with your own Apple Development certificate:

```bash
security find-identity -v -p codesigning   # find your certificate name
echo 'CLEANMAC_SIGN_IDENTITY = Apple Development: you@example.com (TEAMID)' > Config/Signing.local.xcconfig
xcodegen generate
```

`Config/Signing.local.xcconfig` is ignored by git.

## Tests

```bash
xcodebuild -project CleanMac.xcodeproj -scheme CleanMac test
```

50 unit tests cover the scan engine (size totals, no double counting, inaccessible folders), the cleanup engine (refusals, Trash and Put Back, read-only folders, running apps), app leftover matching, duplicate detection, schedules, recommendations, and the parsers for `simctl`, `docker`, `launchctl`, `sfltool`, and the macOS privacy database.

## Project structure

```
CleanMac/
  App/          App entry point, menu bar, app delegate
  Core/         Scanning, cleanup, apps, developer tools, performance,
                startup items, privacy, automation (no UI code)
  Database/     SwiftData models
  Features/     One folder per screen (Dashboard, System Data, Junk Cleaner, …)
CleanMacTests/  Unit tests
Config/         Code-signing settings
project.yml     XcodeGen project definition
```

Screens never remove files themselves: every removal goes through `Core/Cleanup/CleanupEngine.swift`.

## Roadmap

- **Cache catalog:** recognize more app caches out of the box (Adobe Media Cache, Lightroom previews, DaVinci Resolve, Logic and GarageBand libraries, Android emulators, AI model caches, Conda, Unity, and more).
- A signed and notarized download, so it can be installed without building.
- Premium features.

## Disclaimer

CleanMac moves files to the Trash and, when you explicitly confirm, deletes some data permanently. It's designed to be careful, but you use it at your own risk. Keep backups of anything important.

## License

[MIT](LICENSE) © 2026 Marajul Islam
