<div align="center">

  ![macOS](https://img.shields.io/badge/macOS-15.0%2B-lightgrey?logo=apple)
  ![Swift](https://img.shields.io/badge/Swift-5.0-orange?logo=swift)
  ![License](https://img.shields.io/badge/license-MIT-green)
  ![Version](https://img.shields.io/badge/version-1.9.1-blue)
  ![Languages](https://img.shields.io/badge/languages-FR%20EN%20DE%20IT%20ES-blueviolet)


  <img src="https://raw.githubusercontent.com/zinc75/JackMate/gh-pages/assets/icon.png" width="128" alt="JackMate icon">
  <h1>JackMate</h1>
  <p>Native macOS app for managing the JACK audio server — from your menu bar or as a standard window.</p>


  **[Documentation](https://zinc75.github.io/JackMate/)** · **[Download](https://github.com/zinc75/JackMate/releases)**


</div>

---

<div align="center">
  <img src="https://zinc75.github.io/JackMate/assets/screencast/screencast.gif" alt="Screencast" width="100%">
</div>

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
- Native macOS menus: View ⌘1/⌘2, Help with documentation link, custom About panel
- Automatic Jack detection at launch and on every app reactivation
- Jack version check: green ✓ badge if up to date, clickable amber ↑ badge if update available
- Installation helper modal when Jack is absent (Homebrew or .pkg, with copyable command)
- 🇫🇷 French · 🇬🇧 English · 🇩🇪 German · 🇮🇹 Italian · 🇪🇸 Spanish — want to add yours? See [`i18n/`](i18n/)

---

## Documentation

Full documentation at **[zinc75.github.io/JackMate](https://zinc75.github.io/JackMate/)**.

---

## Requirements

- macOS 15.0 (Sequoia) or later — Intel and Apple Silicon
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

See [`src/`](src/) for full build instructions, tech stack, and project structure.

---

## Contributing

Contributions are welcome:

- **Localization** — Copy [`i18n/Localizable_template.strings`](i18n/Localizable_template.strings), translate it, and open a pull request. See [`i18n/`](i18n/) for the full guide.
- **Bug reports** — open an issue with your macOS version, JACK version, and steps to reproduce.
- **Pull requests** — please open an issue first to discuss significant changes.

---

## Support

JackMate is free and open source. If it saves you time or fits into your workflow, consider buying me a coffee.

Contributions go toward the **Apple Developer account** ($99/year) required to notarize the app — which would remove the Gatekeeper warning on first launch and make installation seamless for everyone.

<!-- TODO: replace with real Buy Me A Coffee link once account is created -->
<!-- [![Buy Me A Coffee](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://buymeacoffee.com/TODO) -->

*Buy Me A Coffee link coming soon.*

---

## License

JackMate source code is released under the **MIT License**.

JackMate dynamically loads **libjack** (JACK2) at runtime via `dlopen`. JACK2 is distributed under the LGPL 2.1 license. libjack is not bundled with JackMate; it must be installed separately by the user.
