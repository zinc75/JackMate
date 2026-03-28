# JackMate

A native macOS app (Swift/SwiftUI) for managing the JACK audio server from your menu bar or as a standard window.

**Current version: 1.7.3** — Actively developed.

<!-- TODO: add badges once repo is public -->
<!-- ![macOS](https://img.shields.io/badge/macOS-15.7%2B-blue) -->
<!-- ![Swift](https://img.shields.io/badge/Swift-5.0-orange) -->
<!-- [![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-support-yellow)](https://buymeacoffee.com/TODO) -->

---

<!-- TODO: add a screenshot or short GIF here showcasing the patchbay + menubar -->

---

## Features

### JACK Server Control
- Start / stop jackd with full custom configuration (sample rate, buffer size, I/O device, hog mode, clock drift, channel selection)
- Real-time display of the generated command, with a one-click copy button
- Automatic detection of the Jack executable name (`jackd` or `jackdmp`)
- Automatic switch between Configuration and Patchbay views based on Jack state

### Studios
- Full session capture: Jack parameters, clients, connections, node positions
- Smart loading: full command comparison (all parameters, channel selection), restarts Jack only if necessary
- Graceful shutdown of all clients (GUI and CLI) before switching studios
- Automatic save and relaunch of CLI clients (full command with arguments)
- Progress modal during studio loading

### Patchbay
- Visual editor for Jack client connections
- Node drag & drop, group drag (move selected clients together)
- Node collapse/expand, meta-cables
- Connect-All: bulk connection between two clients with canvas preview
- Automatic layout (Sugiyama / tidy algorithm)
- Multi-selection (Shift+click, ⌘A), selection overlay
- Out-of-view node indicators, zoom reset, haptic feedback

### JACK Transport
- Play / Pause / Stop / Seek
- BBT, HMS, Frames display
- Timebase master, BPM

### Interface
- Menu bar mode and standard window mode
- Dynamic minimum size depending on active view (880×800 Configuration, 1100×780 Patchbay)
- Native macOS menus: View ⌘1/⌘2, Help with documentation link, custom About panel
- About panel: version, copyright, MIT licence, GitHub link and Buy Me a Coffee
- Automatic Jack detection at launch and on every app reactivation
- Jack version check: green ✓ badge if up to date, clickable amber ↑ badge if update available (GitHub API, 24h cache)
- Installation helper modal when Jack is absent: choose between Homebrew or .pkg, with copyable command
- Start button and studio loading disabled when Jack is not installed
- Light and Dark mode support

---

## Requirements

- macOS 15.7 (Sequoia) or later — Intel and Apple Silicon
- [JACK2](https://jackaudio.org/downloads/) installed (`/usr/local/lib/libjack.dylib` or `/opt/homebrew/lib/libjack.dylib`)

---

## Installation

### Download a pre-built release (recommended)

Head to the [Releases](https://github.com/zinc75/JackMate/releases) page, download the latest `JackMate-x.x.x-Installer.dmg`, and drag JackMate to your Applications folder.

> **Note:** The app is not yet notarized. On first launch, macOS may block it.
> Right-click → Open → Open anyway, or run:
> ```bash
> xattr -rd com.apple.quarantine /Applications/JackMate.app
> ```
>
> Notarization requires a paid Apple Developer account ($99/year). If you find JackMate useful,
> [buying me a coffee](#support) helps cover that cost — and gets everyone a smoother install experience.

### Build from source

**Requirements:** Xcode (full install, not just Command Line Tools) — install from the [Mac App Store](https://apps.apple.com/app/xcode/id497799835).

Clone the repository and build:

```bash
git clone https://github.com/zinc75/JackMate.git
cd JackMate
./build.sh
```

This produces a universal binary (Intel + Apple Silicon) at `build/JackMate.app`.

> **Compilation time:** the Swift step compiles both architectures sequentially.
> Expect roughly **3–4 minutes on Intel**, and **1–2 minutes on Apple Silicon**.
> The build script compiles x86_64 code even on an M-series Mac — this is standard
> cross-compilation: the compiler generates x86_64 machine code as output without
> needing to run it, so Rosetta is not involved.

```bash
open build/JackMate.app
```

The `--debug` flag produces a non-optimized build with debug symbols:

```bash
./build.sh --debug
```

---

## Tech stack

- Swift 5.0 / SwiftUI + AppKit (`NSViewRepresentable` for the patchbay canvas)
- macOS 15.7+ — Universal binary (Intel x86_64 + Apple Silicon arm64)
- No Swift Package Manager dependencies
- JACK Audio Connection Kit (jack2 1.9.22+) loaded at runtime via `dlopen` — no static linking
- C bridge (`JackBridge.c` / `JackBridge.h`) exposed to Swift via Bridging Header

---

## Project structure

```
JackMate/
├── build.sh                           — build script (universal binary, no Xcode GUI needed)
├── CHANGELOG.md
├── LICENSE
├── README.md
├── src/
│   ├── Sources/
│   │   ├── JackMateApp.swift          — app entry point, AppDelegate
│   │   ├── JackManager.swift          — Jack lifecycle (start/stop/monitoring)
│   │   ├── JackBridge.c / .h          — C bridge (dlopen/dlsym)
│   │   ├── JackBridgeWrapper.swift    — Swift wrapper for the C bridge
│   │   ├── JackMate-Bridging-Header.h — Objective-C bridging header
│   │   ├── ProcessHelper.swift        — process introspection (PID, command line)
│   │   ├── Patchbaymanager.swift      — Jack connection management
│   │   ├── Studiomanager.swift        — studios (save/load/lifecycle)
│   │   ├── ContentView.swift          — main UI (Configuration + Patchbay + Sidebar)
│   │   ├── Patchbayview.swift         — patchbay canvas (NSViewRepresentable)
│   │   ├── MenuBarView.swift          — menu bar mode view
│   │   ├── ConnectAllSheet.swift      — bulk connection sheet
│   │   ├── TransportBarView.swift     — JACK transport bar
│   │   ├── TransportObserver.swift    — transport state polling
│   │   ├── CoreAudioManager.swift     — audio device enumeration
│   │   ├── NotificationManager.swift  — system notifications
│   │   ├── JackNotInstalledView.swift — installation helper modal
│   │   ├── WindowDelegate.swift       — window lifecycle
│   │   └── Theme.swift                — shared colors and styles
│   ├── Assets.xcassets/               — app icon and accent color
│   ├── Info.plist                     — bundle configuration template
│   ├── VERSION                        — current version string
│   ├── en.lproj/InfoPlist.strings
│   ├── fr.lproj/InfoPlist.strings
│   ├── de.lproj/InfoPlist.strings
│   ├── it.lproj/InfoPlist.strings
│   └── es.lproj/InfoPlist.strings
└── build/                             — generated by build.sh (git-ignored)
    └── JackMate.app
```

---

## Contributing

Contributions are welcome. Some areas that could use community help:

- **Localization** — UI strings are not yet externalized (coming soon). Once available, translations into additional languages will be ideal first contributions.
- **Bug reports** — open an issue with your macOS version, JACK version, and steps to reproduce.
- **Pull requests** — please open an issue first to discuss significant changes.

---

## Support

JackMate is free and open source. If it saves you time or fits into your workflow, consider buying me a coffee.

Beyond the warm feeling, contributions go toward the **Apple Developer account** ($99/year) required to notarize the app — which would remove the Gatekeeper warning on first launch and make installation seamless for everyone.

<!-- TODO: replace with real Buy Me A Coffee link once account is created -->
<!-- [![Buy Me A Coffee](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://buymeacoffee.com/TODO) -->

*Buy Me A Coffee link coming soon.*

---

## License

JackMate source code is released under the **MIT License**.

JackMate dynamically loads **libjack** (JACK2) at runtime via `dlopen`. JACK2 is distributed under the LGPL 2.1 license. libjack is not bundled with JackMate; it must be installed separately by the user.
