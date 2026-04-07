# Changelog — JackMate

All notable changes to this project are documented here.

Format: [Semantic Versioning](https://semver.org). Versions 0.x cover the initial development phase (before stabilization). Version 1.0 marks the first stable and complete release.

---

## [1.8.7] — 2026-04-07

### Fixed
- Help menu: removed default "JackMate Help" item (was pointing to a non-existent help book)

---

## [1.8.6] — 2026-04-07

### Changed
- Help menu Documentation link now points to `https://zinc75.github.io/JackMate/`

---

## [infra] — 2026-04-07

### Documentation
- Full Quarto documentation site: home page + 6 guide pages (Configuration, Patchbay, Studios, Transport, Menu Bar, Alternatives)
- Published via `gh-pages` branch — available at [zinc75.github.io/JackMate](https://zinc75.github.io/JackMate/) once GitHub Pages is activated

---

## [1.8.5] — 2026-04-04

### Added
- Full Spanish (ES) translation: 251/261 keys in `Localizable.xcstrings`
  (10 remaining are empty technical literal keys with no translatable content)
- `es.lproj/InfoPlist.strings`: `NSMicrophoneUsageDescription` localised in ES

---

## [1.8.4] — 2026-04-03

### Added
- Full Italian (IT) translation: 248/261 keys in `Localizable.xcstrings`
  (13 remaining are empty technical literal keys with no translatable content)
- `it.lproj/InfoPlist.strings`: `NSMicrophoneUsageDescription` localised in IT
- Structural fix: added `fr` source value to `organiser`, `%lld hors vue`, `auto-launch` keys (missing value caused them to be skipped in future language exports)

---

## [1.8.3] — 2026-04-03

### Refactored
- `JackState` enum introduced (`ready`, `starting`, `running`, `external`, `startFailed`, `stopping`, `stopped`, `stoppedExternal`, `alreadyRunning`, `executableNotFound`)
- Transitional state detection in `MenuBarView` and `ContentView` moved from `statusMessage.contains("💈")` to `jackState == .starting || .stopping`
- Emoji prefixes `💈` / `💨` removed from `jack.status.*` strings in `Localizable.xcstrings` (FR, EN, DE)

---

## [1.8.2] — 2026-04-03

### Added
- Full German (DE) translation: 249/262 keys in `Localizable.xcstrings`
  (13 remaining are empty technical literal keys with no translatable content)
- `%lld hors vue`: EN (`%lld out of view`) and DE (`%lld außerhalb des Sichtbereichs`) translations added
- `de.lproj/InfoPlist.strings`: `NSMicrophoneUsageDescription` already present in DE

### Fixed
- `JackBridge.c`: last 3 French error messages translated to English (`"Missing symbol"`, `"libjack.dylib not found"`, `"Null client"`)
- `Hog mode` and `Clock drift correction` labels kept in English for DE (standard audio terminology)

---

## [1.8.1] — 2026-04-03

### Added
- Full English translation: 100% of UI strings translated (262 keys in `Localizable.xcstrings`)
- `InfoPlist.xcstrings`: localized `NSMicrophoneUsageDescription` (EN + FR)
- Proper plural forms for selection count (`canvas.selection.count`): "1 client selected" / "N clients selected"

### Changed
- `config.hog_mode.description` EN: "Takes exclusive access of the audio device" (aligned with Jack man page)
- Error message in Jack bridge translated to English
- `statusMessage` default value and `StudioManager.summary` now properly localized

---

## [1.8.0] — 2026-04-02

### Added
- Full i18n infrastructure: all UI strings externalized into `Localizable.xcstrings` (~272 keys), source language French
- `String(localized:)` / `Text("key")` applied across the entire codebase (JackMateApp, NotificationManager, MenuBarView, TransportBarView, JackNotInstalledView, ConnectAllSheet, JackManager, JackBridgeWrapper, PatchbayView, PatchbayManager, StudioManager, ContentView)
- Key naming convention: `vue.composant.etat` snake_case, shared keys under `common.*`
- Distribution build pipeline updated: `sync_to_distribution.sh` copies `Localizable.xcstrings`; `build.sh` compiles it to per-language `Localizable.strings` at build time (step [4/6])

---

## [1.7.4] — 2026-03-28

### Fixed
- Patchbay client info sheet (click on the 2-letter badge): CLI clients (jack_metro, a2jmidid, etc.) are not visible to `NSWorkspace` — added fallback via `ProcessHelper.findPID(forJackClient:)` to display their executable path, full command line, and PID

---

## [1.7.3] — 2026-03-28

### Fixed
- Patchbay client names empty in Release build: `String(cString:)` moved inside `withUnsafeBytes` closures in `getPorts()` and `getConnections()` — the C pointer is only valid for the duration of the closure; using it after the closure returns is undefined behaviour exploited by the Release optimizer
- `PatchbayManager`: `bridge` property now captured explicitly on the main actor before dispatching to background queues — prevents a `@MainActor` property access from a `nonisolated` context in Release builds
- `windowShouldClose` annotated `@MainActor` for compatibility with command-line builds

### Build
- `build.sh`: animated progress spinner (braille) on each compilation step, ✓ checkmark on completion
- `build.sh`: `actool` output cleaned up — system-level `dyld` noise suppressed, XML summary hidden, real warnings still surfaced

---

## [1.7.2] — 2026-03-27

### Documentation
- English `///` docstrings added to all public and internal types, properties, and methods across the entire codebase
- All `//` and `///` code comments translated to English (UI strings unchanged)
- Files covered: `ContentView.swift`, `Patchbayview.swift`, `Patchbaymanager.swift`, `JackBridgeWrapper.swift`, `JackBridge.c/h`, `Studiomanager.swift`, `JackManager.swift`, `ConnectAllSheet.swift`, `CoreAudioManager.swift`, `MenuBarView.swift`, `TransportBarView.swift`, `TransportObserver.swift`, `NotificationManager.swift`, `JackMateApp.swift`, `WindowDelegate.swift`, `Theme.swift`, `JackNotInstalledView.swift`, `ProcessHelper.swift`

---

## [1.7.1] — 2026-03-27

### Added
- Parsing of the installed Jack version via `jackd --version`
- GitHub API call (`jackaudio/jack2-releases`) with 24h UserDefaults cache
- Version badge in the Configuration header: green ✓ if up to date, clickable amber ↑ if an update is available
- Semantic version comparison (major.minor.patch), silent if no network or Jack is absent

---

## [1.7.0] — 2026-03-27

### Added
- Jack detection at launch and on every app reactivation: `jackInstalled`, `recheckInstallation()`
- `JackNotInstalledView` modal: installation helper with Homebrew or .pkg choice, copyable command, and colored glow on the command block
- Generated command block adapts its title and content to installation state and chosen method
- Start Jack button and studio loading grayed out / disabled when Jack is absent
- Automatic re-display of the modal when opening the window from the menu bar (custom `mainWindowDidOpen` notification)

---

## [1.6.2] — 2026-03-27

### Added
- Custom About panel (SwiftUI NSPanel): app icon, version/build, copyright, MIT licence, GitHub and Buy Me a Coffee links
- Services menu removed
- View menu: ⌘1 Configuration / ⌘2 Patchbay navigation
- Help menu: link to JackMate documentation
- Minimum Configuration window height raised to 880×800

---

## [1.6.1] — 2026-03-27

### Added
- `NSAlert` (with "Don't show again" checkbox) when selecting an aggregate device — suggests configuring clock sync in Audio MIDI Setup, with a direct Open button
- `NSAlert` (with "Don't show again" checkbox) when enabling Clock drift correction — suggests the macOS aggregate device as an alternative
- Clock drift correction toggle grayed out and forced to `false` when input and output are the same physical hardware (same UID, or two built-in devices)

---

## [1.6.0] — 2026-03-27

### Added
- Aggregate device constraint: if an aggregate device is selected on input or output, the other side is automatically forced to the same device
- `isBuiltIn: Bool` added to `AudioDeviceInfo` (built-in transport detection)

---

## [1.5.1] — 2026-03-27

### Fixed
- Xrun counter automatically reset to zero on Jack stop and start (voluntary stop, crash, or external cause)

---

## [1.5.0] — 2026-03-27

### Added
- Explicit input/output channel selection via LED picker (`--input-list` / `--output-list`)
- Sheet modal with numbered clickable LED rows, green glow on active channels
- Minimum 1 active channel guaranteed, reset to all channels on each toggle activation
- Footer: permanent channel chips (`N/Nmax ch` with selected range details)
- `JackSnapshot` extended: `limitChannels`, `selectedInChannels`, `selectedOutChannels` — backward-compatible JSON

---

## [1.4.1] — 2026-03-27

### Fixed
- MIDI (coremidi) toggle grayed out and disabled — experimental option causing instabilities

---

## [1.4.0] — 2026-03-27

### Added
- "Audio MIDI Setup" button in the Configuration toolbar (left of the terminal icon) — opens the native macOS Audio MIDI Setup app, `pianokeys` icon, tooltip on hover
- Minimum Patchbay view width raised to 1100px

---

## [1.3.1] — 2026-03-27

### Fixed
- Appearance forced to dark mode (`NSApp.appearance = .darkAqua`) — sidebar, log, and menubar popover stable in macOS Light mode
- Log panel: semi-transparent background via SwiftUI opacity (VisualEffectView incompatible with ZStack overlay)
- Menu bar info icons switched to monochrome

---

## [1.3.0] — 2026-03-27

### Added
- Detection of CLI Jack clients by scanning the process table (`proc_listallpids` + `proc_pidpath` + `sysctl KERN_PROCARGS2`)
- `ProcessHelper`: new file — `findPID(forJackClient:)`, `commandLine(for:)`, `executablePath(for:)`, `terminate(pid:)`
- Automatic save of CLI client launch commands in the studio JSON at `buildStudio()`
- Automatic relaunch of CLI clients when loading a studio
- `terminateAllJackClients()`: closes all Jack clients (GUI via NSWorkspace + CLI via PID scan)
- `stopJackGracefully()`: SIGTERM → 3s delay → SIGKILL → stopJack (correct order)
- `suppressJackStopCleanup` flag to avoid double-kill during a studio load with Jack restart

### Changed
- "Stop Jack" button (interface, menu bar, JackMateApp) now uses `stopJackGracefully()` everywhere
- Stop Studio now also closes CLI clients

---

## [1.2.0] — 2026-03-26

### Added
- Full Jack command comparison on studio load (all parameters, options, devices) — order-independent token comparison
- Closure of ALL clients (GUI + CLI from the studio) before loading a new studio
- Jack restart only if configuration differs or Jack was started outside JackMate
- 1.5s delay between stop and start Jack to allow system resource release
- Studio loading progress modal with auto-close
- `StudioManager.cliProcesses`: tracking of processes launched by `launchCLI()`
- `JackSnapshot` extended: `hogMode`, `clockDrift`, `midiEnabled` with backward-compatible decoding

### Fixed
- Studios saved with older JSON versions still readable (`decodeIfPresent` + default values)
- Race condition: `isRunning` forced to `false` before `startJack()` to prevent guard deadlock

---

## [1.1.0] — 2026-03-26

### Added
- Real executable name displayed in the generated command (`jackd` or `jackdmp` depending on installation)
- Subtle copy button with animated checkmark feedback

---

## [1.0.0] — 2026-03-26

### Fixed / Stabilized
- Fixed patchbay reconnection bug after Stop/Start Jack (root cause: Jack 1.9.11 → updated to 1.9.22)
- Defensive Combine/retry improvements retained as a safety net
- `.removeDuplicates()` on `$isRunning`, `retryConnectTask`, `handleJackStopped()` unified

---

## [0.9.0] — 2026-03-23

### Added — JACK Transport
- Transport bar: Play / Pause / Stop / Seek
- BBT, HMS, Frames display
- Timebase master, BPM
- C bridge + Swift wrapper + transport state polling

---

## [0.8.0] — 2026-03-23

### Added — Group drag & advanced selection
- Group drag: selected clients move together
- Multi-selection: Shift+click, ⌘A
- Selection badge on collapse/expand button
- Actionable selection overlay
- Out-of-view node indicators with direction arrows
- 100% zoom reset (toolbar button + double-tap)

---

## [0.7.0] — 2026-03-22

### Added — Toolbar, Connect-All, automatic layout (Sugiyama)
- Automatic patchbay node layout (Sugiyama algorithm)
- Partial tidy selection (Shift+click)
- Connect-All: bulk connection between two clients
- Patchbay-accurate canvas preview in ConnectAllSheet
- Unified 40px toolbar, mass collapse/expand
- Repositioning toast, homogenized overlays

---

## [0.6.0] — 2026-03-22

### Added — Visual polish + node collapse
- Node collapse/expand, meta-cables
- Port pills on hover, pill for unconnected nodes, click-to-connect
- Diagonal gradient border on cards and nodes
- MenuBarView visual overhaul
- Dynamic minimum size based on active view
- Automatic Configuration ↔ Patchbay switch

---

## [0.5.0] — 2026-03-21

### Added — Full studios
- Full studio capture (Jack parameters + clients + connections + node positions)
- Robust load/save, stabilized patchbay
- Stop Studio: quit apps + disconnect cables
- Studio inspection modal
- Marquee on long studio names
- Auto-switch to Patchbay on studio load

---

## [0.4.0] — 2026-03-20

### Added — Improved patchbay + StudioManager foundations
- Patchbay spatial consistency (centering, drag constraints)
- Collision management
- StudioManager beginnings
- Stability overhaul: xrun counts, improved Jack handling

---

## [0.3.0] — 2026-03-19

### Added — Functional patchbay
- Cables, animations, real-time updates
- JackBridge for patchbay
- Physical input source selector

---

## [0.2.0] — 2026-03-18

### Added — UI + logs
- System notifications
- Semi-transparent log window
- Initial look and feel

---

## [0.1.0] — 2026-03-18

### First working version
- Start / stop Jack from the menu bar
- Basic configuration
