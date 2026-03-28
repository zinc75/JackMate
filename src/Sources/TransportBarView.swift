//
//  TransportBarView.swift
//  JackMate
//
//  Copyright © 2026 Éric Bavu. All rights reserved.
//  Licensed under the MIT License — see LICENSE for details.
//
//  Jack transport bar: play/pause/stop/seek, position display,
//  timebase master toggle, and editable BPM field.
//  Appears below the main toolbar on the Patchbay tab.
//

import SwiftUI

// MARK: - TransportBarView

/// The Jack transport control bar.
///
/// Displays play/pause, stop, seek buttons, the current transport position
/// (HMS / BBT / frames), a timebase master toggle, and an editable BPM field.
///
/// Uses a dedicated `TransportObserver` so that only this view re-renders on
/// each polling tick — the Patchbay canvas is unaffected.
struct TransportBarView: View {

    @EnvironmentObject var patchbayManager: PatchbayManager
    /// Isolated observer — only this view subscribes; the patchbay canvas does not re-render.
    @ObservedObject var observer: TransportObserver

    /// The three position display modes available for the time counter.
    enum TimeMode { case hms, bbt, frames }

    @State private var timeMode:          TimeMode = .hms
    @State private var showLocatePopover: Bool     = false
    @State private var locateInput:       String   = ""
    @State private var locateError:       String?  = nil
    @State private var hoveredBtn:        String?  = nil
    @State private var bpmText:           String   = "120.0"
    @FocusState private var bpmFocused:   Bool

    // MARK: - Convenience accessors

    private var pos:       JackTransportPosition { observer.position }
    private var isMaster:  Bool                  { observer.isMaster }
    private var isRolling: Bool                  { patchbayManager.isTransportRolling }

    // MARK: - Time formatting

    private var timeString: String {
        switch timeMode {
        case .hms:
            let s = Int(pos.seconds)
            return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        case .bbt:
            guard pos.bbtValid else { return "---|--.----" }
            return String(format: "%03d|%02d|%04d", pos.bar, pos.beat, pos.tick)
        case .frames:
            return "\(pos.frame)"
        }
    }

    // MARK: - Locate input parsing

    /// Parses a position string typed by the user into an absolute sample frame.
    ///
    /// Supports the three time modes:
    /// - HMS: `"hh:mm:ss"` or `"mm:ss"`
    /// - BBT: `"bar|beat|tick"` (requires an active timebase master)
    /// - Frames: raw integer string
    ///
    /// - Parameter input: The raw string entered by the user.
    /// - Returns: Target sample frame, or `nil` if the format is invalid.
    private func parseLocate(_ input: String) -> UInt32? {
        let s = input.trimmingCharacters(in: .whitespaces)
        let sr = pos.sampleRate > 0 ? pos.sampleRate : 44100
        switch timeMode {
        case .hms:
            let p = s.split(separator: ":").compactMap { Double($0) }
            if p.count == 3 { return UInt32((p[0]*3600 + p[1]*60 + p[2]) * Double(sr)) }
            if p.count == 2 { return UInt32((p[0]*60   + p[1])           * Double(sr)) }
            return nil
        case .bbt:
            guard pos.bbtValid, pos.bpm > 0 else { return nil }
            let p = s.split(separator: "|").compactMap { Int($0) }
            guard p.count >= 2 else { return nil }
            let bar = p[0]; let beat = p[1]; let tick = p.count >= 3 ? p[2] : 0
            let bpb = Double(pos.beatsPerBar > 0 ? pos.beatsPerBar : 4)
            let tpb = 1920.0
            let totalTicks = (Double(bar-1)*bpb + Double(beat-1)) * tpb + Double(tick)
            let framesPerTick = (Double(sr) * 60.0 / pos.bpm) / tpb
            return UInt32(max(0, totalTicks * framesPerTick))
        case .frames:
            return UInt32(s)
        }
    }

    private func confirmLocate() {
        guard let frame = parseLocate(locateInput) else {
            locateError = "Format invalide"
            return
        }
        patchbayManager.transportLocate(frame: frame)
        showLocatePopover = false
        locateInput = ""
        locateError = nil
    }

    // MARK: - Seek

    /// Seeks the transport by a relative time offset in seconds.
    ///
    /// - Parameter delta: Positive to seek forward, negative to seek backward.
    private func seek(_ delta: Double) {
        let sr  = pos.sampleRate > 0 ? pos.sampleRate : 44100
        let off = UInt32(abs(delta) * Double(sr))
        if delta < 0 {
            patchbayManager.transportLocate(frame: pos.frame > off ? pos.frame - off : 0)
        } else {
            patchbayManager.transportLocate(frame: pos.frame + off)
        }
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 0) {

            // ── Transport controls ─────────────────────────────────────────────
            HStack(spacing: 2) {
                // Play / Pause
                tBtn("play", icon: isRolling ? "pause.fill" : "play.fill") {
                    isRolling ? patchbayManager.transportPause()
                              : patchbayManager.transportPlay()
                }
                // Stop and rewind to frame 0
                tBtn("stop", icon: "stop.fill") { patchbayManager.transportStop() }
                    .opacity(isRolling || pos.frame > 0 ? 1 : 0.3)
                // Seek −2.5 s
                tBtn("bwd", icon: "backward.fill") { seek(-2.5) }
                // Seek +2.5 s
                tBtn("fwd", icon: "forward.fill")  { seek(+2.5) }
            }
            .padding(.horizontal, 8)

            barSep

            // ── Position display (click → locate popover, right-click → mode) ──
            Button { showLocatePopover.toggle() } label: {
                Text(timeString)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(isRolling ? JM.textPrimary : JM.textSecondary)
                    .frame(minWidth: 80)
                    .padding(.horizontal, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Cliquer pour aller à une position · Clic droit pour changer le format")
            .popover(isPresented: $showLocatePopover, arrowEdge: .bottom) {
                LocatePopoverView(
                    timeMode: timeMode,
                    input:    $locateInput,
                    error:    locateError,
                    onConfirm: confirmLocate,
                    onCancel:  { showLocatePopover = false; locateInput = ""; locateError = nil }
                )
            }
            .contextMenu {
                Button("HMS (hh:mm:ss)")          { timeMode = .hms    }
                Button("BBT (mesure|temps|tick)") { timeMode = .bbt    }
                Button("Frames")                  { timeMode = .frames }
            }

            barSep

            // ── Timebase master toggle ─────────────────────────────────────────
            Button { patchbayManager.toggleTimebaseMaster() } label: {
                HStack(spacing: 5) {
                    Image(systemName: isMaster ? "metronome.fill" : "metronome")
                        .font(.system(size: 13))
                        .foregroundStyle(isMaster ? JM.accentTeal : JM.textTertiary)
                    if isMaster {
                        Text("Master")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(JM.accentTeal)
                    }
                }
                .padding(.horizontal, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isMaster ? "Relâcher le rôle de Timebase Master"
                           : "Devenir Timebase Master (fournit BPM et BBT aux autres clients)")

            barSep

            // ── BPM display / editor ───────────────────────────────────────────
            HStack(spacing: 4) {
                if isMaster {
                    // Editable when JackMate holds the timebase master role
                    TextField("120.0", text: $bpmText)
                        .font(.system(size: 13, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.plain)
                        .frame(width: 52)
                        .focused($bpmFocused)
                        .onSubmit {
                            if let v = Double(bpmText), v >= 20, v <= 999 {
                                patchbayManager.updateBPM(v)
                            } else {
                                bpmText = String(format: "%.1f", pos.bpm > 0 ? pos.bpm : 120)
                            }
                            bpmFocused = false
                        }
                        // Do not overwrite the field while the user is typing
                        .onChange(of: pos.bpm) { _, newBPM in
                            if !bpmFocused, newBPM > 0 {
                                bpmText = String(format: "%.1f", newBPM)
                            }
                        }
                        .onAppear {
                            let b = pos.bpm > 0 ? pos.bpm : 120
                            bpmText = String(format: "%.1f", b)
                        }
                } else {
                    // Read-only display when another client is timebase master
                    Text(pos.bbtValid ? String(format: "%.1f", pos.bpm) : "--")
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(pos.bbtValid ? JM.textSecondary : JM.textTertiary)
                        .frame(width: 52, alignment: .trailing)
                }
                Text("BPM")
                    .font(.system(size: 12))
                    .foregroundStyle(JM.textTertiary)
            }
            .padding(.horizontal, 10)

            Spacer()
        }
        .frame(height: 36)
        .background(JM.bgBase)
    }

    // MARK: - View helpers

    /// A small icon button with a hover highlight, used for transport controls.
    @ViewBuilder
    private func tBtn(_ id: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(hoveredBtn == id ? JM.textPrimary : JM.textSecondary)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .onHover { hoveredBtn = $0 ? id : nil }
    }

    /// A thin vertical separator dividing sections of the transport bar.
    private var barSep: some View {
        Rectangle().fill(JM.borderFaint)
            .frame(width: 0.5)
            .frame(maxHeight: .infinity)
    }
}

// MARK: - LocatePopoverView

/// A popover that lets the user type a target position and jump there.
///
/// The input format matches the currently active `TimeMode` (HMS, BBT, or frames).
struct LocatePopoverView: View {
    /// The time mode determines the expected input format and placeholder text.
    let timeMode:  TransportBarView.TimeMode
    /// The user's current text input.
    @Binding var input: String
    /// An error message to display when the input cannot be parsed.
    let error:     String?
    /// Called when the user confirms the locate operation.
    let onConfirm: () -> Void
    /// Called when the user cancels.
    let onCancel:  () -> Void

    @FocusState private var focused: Bool

    private var placeholder: String {
        switch timeMode {
        case .hms:    return "0:00:00"
        case .bbt:    return "1|1|0"
        case .frames: return "0"
        }
    }

    private var formatLabel: String {
        switch timeMode {
        case .hms:    return "hh:mm:ss"
        case .bbt:    return "mesure|temps|tick"
        case .frames: return "frames"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Aller à")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(JM.textSecondary)

            HStack(spacing: 6) {
                TextField(placeholder, text: $input)
                    .font(.system(size: 13, design: .monospaced))
                    .textFieldStyle(.plain)
                    .frame(width: 130)
                    .padding(5)
                    .background(JM.bgField, in: RoundedRectangle(cornerRadius: 5))
                    .focused($focused)
                    .onSubmit { onConfirm() }
                    .onAppear { focused = true }

                Button("OK", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(input.isEmpty)

                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12))
                        .foregroundStyle(JM.textTertiary)
                }
                .buttonStyle(.plain)
            }

            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(JM.accentRed)
            }

            Text("Format : \(formatLabel)")
                .font(.system(size: 12))
                .foregroundStyle(JM.textTertiary)
        }
        .padding(14)
        .background(JM.bgBase)
    }
}
