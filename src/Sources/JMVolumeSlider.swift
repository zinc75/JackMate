//
//  JMVolumeSlider.swift
//  JackMate
//
//  A horizontal, macOS-style volume slider, themed for JackMate.
//

import SwiftUI
import Foundation

/// macOS square-root volume taper — the exact curve JackMoebius uses (matched against the
/// BuiltInSpeaker curve): `dB = -63.5·(1 − √scalar)`, `gain = 10^(dB/20)`, min -63.5 dB.
///
/// The slider works in **scalar** space (a 0…1 *position*, like CoreAudio `VolumeScalar`).
/// The daemon's `set_volume` speaks **gain** (linear amplitude). These converters bridge
/// the two so a per-app slider lines up with the master (same position for the same level).
enum VolumeTaper {
    static let minDB: Double = -63.5

    /// Linear gain (0…1) → slider position (scalar 0…1).
    static func gainToScalar(_ gain: Double) -> Double {
        guard gain > 0 else { return 0 }
        let root = 1 + 20 * log10(gain) / -minDB   // = 1 + dB/63.5 = √scalar
        let clamped = min(max(root, 0), 1)
        return clamped * clamped
    }

    /// Slider position (scalar 0…1) → linear gain (0…1).
    static func scalarToGain(_ scalar: Double) -> Double {
        let s = min(max(scalar, 0), 1)
        return pow(10, minDB * (1 - sqrt(s)) / 20)
    }
}

/// A horizontal volume slider in the macOS idiom: a **thin track** with a bright white
/// fill and a white **pill-shaped anchor** (capsule) that slides along it. The speaker
/// glyph inside the pill lights its waves in proportion to the level; at the far left
/// (zero = silence) it shows a barred speaker. The value is normalized `0…1`, matching
/// `kAudioDevicePropertyVolumeScalar` (device level) and the per-app `gain`.
///
/// There is **no separate mute control** by design — muting is "drag to zero".
/// `isEnabled == false` renders it greyed and inert (devices with no settable volume,
/// e.g. HDMI or fixed-line DACs).
///
/// Reused by the device output-volume bar and the per-app volume slider.
struct JMVolumeSlider: View {
    /// Normalized volume, `0…1`.
    @Binding var value: Double
    var isEnabled: Bool = true
    /// `false` renders a **passive** slider: shown at full opacity (not greyed) but not
    /// draggable — for the per-app "locked" preview that only mirrors the master.
    var interactive: Bool = true
    /// Overall control height = the pill anchor's height.
    var height: CGFloat = 20

    /// `true` while the pill is pressed/dragged → "liquid glass" treatment.
    @State private var dragging = false

    var body: some View {
        GeometryReader { gr in
            let w        = gr.size.width
            let thumbH   = gr.size.height
            let thumbW   = thumbH * 1.5                     // pill: wider than tall
            let track    = max(3, thumbH * 0.20)            // thin volume line
            let usable   = max(w - thumbW, 1)               // travel range of the pill
            let frac     = CGFloat(min(max(value, 0), 1))
            let thumbX   = frac * usable                    // pill leading offset

            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.20))        // track (thin, vertically centred)
                    .frame(height: track)
                Capsule().fill(.white)                      // fill (thin, up to pill centre)
                    .frame(width: thumbX + thumbW / 2, height: track)
                Capsule()                                   // anchor = horizontal pill
                    // Pressed → bright translucent "liquid glass" (stays light, not a
                    // dark material); resting → solid white.
                    .fill(dragging
                          ? AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.90),
                                                                  .white.opacity(0.68)],
                                                         startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(Color.white))
                    .frame(width: thumbW, height: thumbH)
                    .overlay(                               // top specular sheen (glassy highlight)
                        Capsule().fill(
                            LinearGradient(colors: [.white.opacity(dragging ? 0.6 : 0), .clear],
                                           startPoint: .top, endPoint: .center))
                    )
                    .overlay(Capsule().strokeBorder(.white.opacity(dragging ? 0.85 : 0), lineWidth: 0.8))
                    .overlay(
                        // Waves light up with the volume via the symbol's variable value;
                        // barred speaker at zero (silence).
                        Group {
                            if value <= 0.0001 {
                                Image(systemName: "speaker.slash.fill")
                            } else {
                                Image(systemName: "speaker.wave.3.fill", variableValue: value)
                            }
                        }
                        .font(.system(size: thumbH * 0.5, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.58))
                    )
                    .scaleEffect(dragging ? 1.06 : 1.0)
                    .shadow(color: dragging ? .white.opacity(0.22) : .black.opacity(0.35),
                            radius: dragging ? 4 : 2, y: dragging ? 0 : 1)
                    .offset(x: thumbX)
                    .animation(.easeOut(duration: 0.16), value: dragging)
            }
            .frame(height: thumbH)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.5)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard isEnabled, interactive else { return }
                        if !dragging { dragging = true }
                        // Tap/drag anywhere: map the touch x (pill-centred) to 0…1.
                        let x = min(max(g.location.x - thumbW / 2, 0), usable)
                        value = Double(x / usable)
                    }
                    .onEnded { _ in dragging = false }
            )
        }
        .frame(height: height)
    }
}

