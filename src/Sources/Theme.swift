//
//  Theme.swift
//  JackMate
//
//  Copyright © 2026 Éric Bavu. All rights reserved.
//  Licensed under the MIT License — see LICENSE for details.
//

import SwiftUI

// MARK: - JackMate design tokens

/// Central namespace for all design tokens used across the JackMate UI.
///
/// All colours are defined as `static let` properties to ensure a single source of truth.
/// UI components reference `JM.*` tokens directly — never hardcode raw hex values elsewhere.
enum JM {

    // MARK: Backgrounds

    /// Base application background — darkest surface level.
    static let bgBase        = Color(hex: "#1c1c1e")
    /// Elevated surface, one level above `bgBase` (cards, popovers).
    static let bgElevated    = Color(hex: "#2c2c2e")
    /// Card background — matches `bgBase` for a flush inset look.
    static let bgCard        = Color(hex: "#1c1c1e")
    /// Input field background.
    static let bgField       = Color(hex: "#3a3a3c")
    /// Group header background.
    static let bgGroupHeader = Color(hex: "#2c2c2e")

    // MARK: Borders

    /// Standard separator / stroke.
    static let border      = Color.white.opacity(0.10)
    /// Subtle separator, barely visible.
    static let borderFaint = Color.white.opacity(0.06)

    // MARK: Text

    /// Primary label — near-white, highest contrast.
    static let textPrimary   = Color.white.opacity(0.95)
    /// Secondary label — dimmed.
    static let textSecondary = Color.white.opacity(0.72)
    /// Tertiary label — for hints, metadata, disabled states.
    static let textTertiary  = Color.white.opacity(0.40)

    // MARK: Accent colours

    /// Indigo — used for selection and active states.
    static let accentIndigo = Color(hex: "#6366f1")
    /// Green — used for running / success states.
    static let accentGreen  = Color(hex: "#22c55e")
    /// Red — used for stop / error states.
    static let accentRed    = Color(hex: "#ef4444")
    /// Amber — used for warnings and studio indicators.
    static let accentAmber  = Color(hex: "#f59e0b")
    /// Blue — used for informational highlights.
    static let accentBlue   = Color(hex: "#3b82f6")
    /// Purple — used for MIDI-related elements.
    static let accentPurple = Color(hex: "#a855f7")
    /// Orange — used for destructive hover states.
    static let accentOrange = Color(hex: "#f97316")
    /// Teal — used for CV/audio auxiliary elements.
    static let accentTeal   = Color(hex: "#14b8a6")
    /// Pink — used for decorative accents.
    static let accentPink   = Color(hex: "#ec4899")
    /// Cyan — used for secondary audio highlights.
    static let accentCyan   = Color(hex: "#06b6d4")

    // MARK: Tinted icon backgrounds

    /// Tinted indigo background for icon capsules.
    static let tintIndigo = Color(hex: "#6366f1").opacity(0.28)
    /// Tinted blue background for icon capsules.
    static let tintBlue   = Color(hex: "#3b82f6").opacity(0.28)
    /// Tinted purple background for icon capsules.
    static let tintPurple = Color(hex: "#a855f7").opacity(0.28)
    /// Tinted green background for icon capsules.
    static let tintGreen  = Color(hex: "#22c55e").opacity(0.25)
    /// Tinted amber background for icon capsules.
    static let tintAmber  = Color(hex: "#f59e0b").opacity(0.28)
    /// Tinted red background for icon capsules.
    static let tintRed    = Color(hex: "#ef4444").opacity(0.25)
    /// Tinted orange background for icon capsules.
    static let tintOrange = Color(hex: "#f97316").opacity(0.28)
    /// Tinted teal background for icon capsules.
    static let tintTeal   = Color(hex: "#14b8a6").opacity(0.25)
    /// Tinted pink background for icon capsules.
    static let tintPink   = Color(hex: "#ec4899").opacity(0.25)
    /// Tinted cyan background for icon capsules.
    static let tintCyan   = Color(hex: "#06b6d4").opacity(0.25)

    // MARK: Button tokens

    /// Start button fill colour (semi-transparent green).
    static let btnStartBg   = Color(hex: "#22c55e").opacity(0.20)
    /// Start button glow shadow colour.
    static let btnStartGlow = Color(hex: "#22c55e").opacity(0.30)
    /// Stop button fill colour (semi-transparent red).
    static let btnStopBg    = Color(hex: "#ef4444").opacity(0.20)
    /// Stop button glow shadow colour.
    static let btnStopGlow  = Color(hex: "#ef4444").opacity(0.25)

    // MARK: Near-black tinted surfaces

    /// Near-black with a faint amber tint — used for amber-tinted dark areas.
    static let darkAmber = Color(hex: "#0c0800")
    /// Near-black with a faint cyan tint.
    static let darkCyan  = Color(hex: "#00090b")
    /// Near-black with a faint green tint.
    static let darkGreen = Color(hex: "#020a05")
    /// Near-black with a faint red tint.
    static let darkRed   = Color(hex: "#0c0303")

    // MARK: Command syntax highlight

    /// Colour for the Jack executable token in the generated command display.
    static let cmdExec  = Color(hex: "#818cf8")
    /// Colour for flag tokens (arguments starting with `-`).
    static let cmdFlag  = Color(hex: "#f59e0b")
    /// Colour for value tokens (arguments without `-` prefix).
    static let cmdValue = Color(hex: "#22c55e")
}

// MARK: - Color hex initialiser

extension Color {
    /// Initialises a `Color` from a CSS-style hex string.
    ///
    /// Accepts formats `"RRGGBB"` and `"#RRGGBB"`. The `opacity` parameter
    /// allows an alpha override independent of the hex value.
    ///
    /// - Parameters:
    ///   - hex: A hex colour string, with or without a leading `#`.
    ///   - opacity: Alpha value in the range `0.0 … 1.0`. Defaults to `1.0`.
    init(hex: String, opacity: Double = 1.0) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >>  8) & 0xFF) / 255
        let b = Double( int        & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}
