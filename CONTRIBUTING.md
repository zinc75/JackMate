# Contributing to JackMate

Thank you for your interest in contributing to JackMate!

## Ways to contribute

- **Bug reports** — use the [Bug Report](.github/ISSUE_TEMPLATE/bug_report.yml) issue template
- **Feature requests** — use the [Feature Request](.github/ISSUE_TEMPLATE/feature_request.yml) issue template
- **Translations** — use the [Localization](.github/ISSUE_TEMPLATE/localization.yml) issue template
- **Documentation** — use the [Documentation](.github/ISSUE_TEMPLATE/docs.yml) issue template
- **Code** — open a pull request (see below)

## Building from source

Requirements:
- macOS 15.0 or later
- Xcode 26 or later (available on the Mac App Store)
- [JACK2](https://jackaudio.org/downloads/) installed

```bash
git clone https://github.com/zinc75/JackMate.git
cd JackMate
./build.sh
open build/JackMate.app
```

If macOS blocks the app (unidentified developer):
```bash
xattr -rd com.apple.quarantine build/JackMate.app
```

## Submitting a pull request

1. Fork the repository and create a branch from `main`
2. Make your changes — keep them focused and atomic
3. Test your build with `./build.sh`
4. Open a pull request with a clear description of what changes and why

For significant changes, please open an issue first to discuss the approach.

## Code style

- Swift 5 / SwiftUI + AppKit
- Public API: `///` docstrings in English
- Code comments in English
- No external Swift Package Manager dependencies

## Localization

JackMate supports EN · FR · DE · IT · ES via `Localizable.xcstrings`.
If you'd like to improve an existing translation or add a new language,
open a [Localization issue](https://github.com/zinc75/JackMate/issues/new?template=localization.yml) first.
