//
//  VolumesBarView.swift
//  JackMate
//
//  The output-device volume bar: a top bar (à la transport bar) exposing the output
//  device volumes — jackd's output device and "JackMoebius Out" — each with a
//  `JMVolumeSlider`. Pure CoreAudio (no IPC); works even when Jack/JackMoebius is down.
//

import SwiftUI

struct VolumesBarView: View {
    @ObservedObject var manager: OutputVolumeManager

    var body: some View {
        HStack(spacing: 12) {
            ForEach(manager.targets) { target in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(target.name)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(JM.textSecondary)
                            .lineLimit(1)
                        if target.isDefault {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(JM.accentCyan)
                                .help(String(localized: "volumes.default_device"))
                        }
                    }
                    JMVolumeSlider(
                        value: Binding(get: { target.isMuted ? 0 : target.volume },
                                       set: { manager.setVolume(target, to: $0) }),
                        isEnabled: target.hasControl
                    )
                    .frame(width: 168)
                }
                // Grouped-box look (à la System Settings zones): slightly elevated fill
                // + faint rounded border to physically separate the sliders.
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(JM.bgElevated)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(JM.borderFaint, lineWidth: 1))
                )
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(JM.bgBase)
    }
}
