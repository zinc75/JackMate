//
//  OutputVolumeManager.swift
//  JackMate
//
//  Device-level output volumes, driven purely through the CoreAudio HAL (no IPC).
//  Reads/writes `kAudioDevicePropertyVolumeScalar` on any device by AudioObjectID —
//  selected in macOS or not — and follows live changes (F11/F12, System Settings ▸
//  Sound) via property listeners.
//

import Foundation
import CoreAudio
import Combine

/// One output device whose volume the "Volumes" bar controls.
struct OutputVolumeTarget: Identifiable, Equatable {
    enum Role { case jackOutput, jackMoebiusOut }
    let deviceID: AudioDeviceID
    let role: Role
    let name: String
    /// Normalized volume `0…1` (0 when there is no control).
    var volume: Double
    /// `true` when the device is muted (F10 / mute property) — the slider shows 0.
    var isMuted: Bool
    /// `true` when the device exposes a settable volume (else the slider is greyed).
    var hasControl: Bool
    /// `true` when this is the current system default output device.
    var isDefault: Bool
    var id: AudioDeviceID { deviceID }
}

/// Publishes the output devices shown in the Volumes bar (jackd's output + "JackMoebius
/// Out") and drives their volume through CoreAudio. Grafts onto `JackManager` only to
/// learn which device jackd currently drives.
@MainActor
final class OutputVolumeManager: ObservableObject {

    /// The devices shown in the bar, in display order.
    @Published private(set) var targets: [OutputVolumeTarget] = []

    /// Live "JackMoebius Out" master volume — the value a *locked* per-app slider mirrors.
    var jackMoebiusOutVolume: Double? {
        targets.first { $0.role == .jackMoebiusOut }?.volume
    }

    /// Whether "JackMoebius Out" is muted (F10) — per-app sliders then show 0, like the
    /// device sliders, since everything routed through it is silenced.
    var jackMoebiusOutMuted: Bool {
        targets.first { $0.role == .jackMoebiusOut }?.isMuted ?? false
    }

    /// Whether the Volumes bar is shown. Persisted, and **open by default** so the
    /// feature is discovered on first launch of 2.0.
    @Published var showVolumesBar: Bool =
        (UserDefaults.standard.object(forKey: "showVolumesBar") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(showVolumesBar, forKey: "showVolumesBar") }
    }

    /// Exact CoreAudio name of the JackMoebius virtual output device.
    private let jackMoebiusOutName = "JackMoebius Out"

    private weak var jackManager: JackManager?

    /// Registered CoreAudio listeners, kept so they can be removed.
    private struct Registration { let id: AudioObjectID; var addr: AudioObjectPropertyAddress; let block: AudioObjectPropertyListenerBlock }
    private var registrations: [Registration] = []

    // MARK: Lifecycle

    /// Wires the manager to `JackManager` (for jackd's current output device) and builds
    /// the initial target list + listeners.
    func configure(jackManager: JackManager) {
        self.jackManager = jackManager
        rebuild()
    }

    /// Removes all CoreAudio listeners. Call before releasing the manager.
    func cleanup() { removeAllListeners() }

    // MARK: Public API

    /// Sets a target's device volume (master, else channels 1&2) and mirrors it locally.
    /// Dragging up un-mutes: a muted device (F10) maps the slider to 0, so any move above
    /// zero clears the mute.
    func setVolume(_ target: OutputVolumeTarget, to value: Double) {
        let v = min(max(value, 0), 1)
        if v > 0 { writeMute(target.deviceID, false) }
        writeVolume(target.deviceID, v)
        if let i = targets.firstIndex(where: { $0.id == target.id }) {
            targets[i].volume = v
            if v > 0 { targets[i].isMuted = false }
        }
    }

    /// Re-reads every target's live volume + mute + default flag (no full rebuild).
    func refreshVolumes() {
        let def = defaultOutputDeviceID()
        for i in targets.indices {
            if let (v, settable) = readVolume(targets[i].deviceID) {
                targets[i].volume = v
                targets[i].hasControl = settable
            }
            targets[i].isMuted   = readMute(targets[i].deviceID)
            targets[i].isDefault = (targets[i].deviceID == def)
        }
    }

    // MARK: Studio snapshot

    /// Captures the current output device volumes for saving into a studio. Only devices
    /// that expose a settable volume (`hasControl`) are captured; returns `nil` when none
    /// is available so the studio carries no output-volume state.
    func snapshotOutputVolumes() -> StudioOutputVolumes? {
        func capture(_ role: OutputVolumeTarget.Role) -> StudioDeviceVolume? {
            guard let t = targets.first(where: { $0.role == role && $0.hasControl }) else { return nil }
            return StudioDeviceVolume(volume: t.volume, muted: t.isMuted)
        }
        let physical = capture(.jackOutput)
        let moebius  = capture(.jackMoebiusOut)
        guard physical != nil || moebius != nil else { return nil }
        return StudioOutputVolumes(physicalOut: physical, jackMoebiusOut: moebius)
    }

    /// Restores saved output device volumes into the live devices (used when loading a
    /// studio). Rebuilds the target list first so it points at the studio's freshly applied
    /// jackd output device. Devices absent or without a settable volume are skipped.
    func restore(_ saved: StudioOutputVolumes) {
        rebuild()
        if let v = saved.physicalOut    { apply(v, to: .jackOutput) }
        if let v = saved.jackMoebiusOut { apply(v, to: .jackMoebiusOut) }
    }

    /// Writes one saved volume + mute onto the matching target, then reads the device back
    /// so the local mirror holds the device's actual (possibly quantized) value.
    private func apply(_ v: StudioDeviceVolume, to role: OutputVolumeTarget.Role) {
        guard let i = targets.firstIndex(where: { $0.role == role && $0.hasControl }) else { return }
        let id = targets[i].deviceID
        writeVolume(id, v.volume)
        writeMute(id, v.muted)
        targets[i].volume  = readVolume(id)?.0 ?? v.volume
        targets[i].isMuted = readMute(id)
    }

    // MARK: Target list

    /// Rebuilds the target list (jackd output + JackMoebius Out) and re-registers the
    /// per-device + hardware listeners.
    private func rebuild() {
        let defaultID = defaultOutputDeviceID()
        let outputs   = outputDeviceIDs()

        var result: [OutputVolumeTarget] = []
        var seen = Set<AudioDeviceID>()

        // 1. jackd's output device: the configured UID, else the system default.
        let jackUID = jackManager?.prefs.outputDeviceUID ?? ""
        let jackID  = jackUID.isEmpty ? defaultID : outputs.first { deviceUID($0) == jackUID }
        if let jackID, let t = makeTarget(jackID, role: .jackOutput, defaultID: defaultID) {
            result.append(t); seen.insert(jackID)
        }

        // 2. JackMoebius Out (a virtual device → matched by exact name).
        if let jmID = outputs.first(where: { deviceName($0) == jackMoebiusOutName }),
           !seen.contains(jmID),
           let t = makeTarget(jmID, role: .jackMoebiusOut, defaultID: defaultID) {
            result.append(t); seen.insert(jmID)
        }

        targets = result
        registerListeners()
    }

    private func makeTarget(_ id: AudioDeviceID, role: OutputVolumeTarget.Role,
                            defaultID: AudioDeviceID?) -> OutputVolumeTarget? {
        let name = role == .jackMoebiusOut ? jackMoebiusOutName : (deviceName(id) ?? "—")
        let (volume, hasControl) = readVolume(id) ?? (0, false)
        return OutputVolumeTarget(deviceID: id, role: role, name: name,
                                  volume: volume, isMuted: readMute(id), hasControl: hasControl,
                                  isDefault: id == defaultID)
    }

    // MARK: CoreAudio — volume read / write (master → channels 1&2 fallback)

    private func volumeAddress(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: element)
    }

    /// Reads `(volume 0…1, settable)` from the master element, else the average of
    /// channels 1&2. Returns `nil` when the device exposes no volume control.
    private func readVolume(_ id: AudioDeviceID) -> (Double, Bool)? {
        var master = volumeAddress(kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(id, &master), let v = getFloat(id, &master) {
            return (Double(v), isSettable(id, &master))
        }
        var values: [Float] = []
        var settable = false
        for ch: AudioObjectPropertyElement in [1, 2] {
            var addr = volumeAddress(ch)
            guard AudioObjectHasProperty(id, &addr) else { continue }
            settable = settable || isSettable(id, &addr)
            if let v = getFloat(id, &addr) { values.append(v) }
        }
        guard !values.isEmpty else { return nil }
        return (Double(values.reduce(0, +) / Float(values.count)), settable)
    }

    private func writeVolume(_ id: AudioDeviceID, _ value: Double) {
        var scalar = Float32(min(max(value, 0), 1))
        let size = UInt32(MemoryLayout<Float32>.size)
        var master = volumeAddress(kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(id, &master), isSettable(id, &master) {
            AudioObjectSetPropertyData(id, &master, 0, nil, size, &scalar)
            return
        }
        for ch: AudioObjectPropertyElement in [1, 2] {
            var addr = volumeAddress(ch)
            guard AudioObjectHasProperty(id, &addr), isSettable(id, &addr) else { continue }
            AudioObjectSetPropertyData(id, &addr, 0, nil, size, &scalar)
        }
    }

    private func getFloat(_ id: AudioObjectID, _ addr: inout AudioObjectPropertyAddress) -> Float? {
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private func isSettable(_ id: AudioObjectID, _ addr: inout AudioObjectPropertyAddress) -> Bool {
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(id, &addr, &settable) == noErr && settable.boolValue
    }

    private func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// Reads the device's master mute flag (`false` when the device has no mute control).
    private func readMute(_ id: AudioDeviceID) -> Bool {
        var addr = muteAddress()
        guard AudioObjectHasProperty(id, &addr) else { return false }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &muted) == noErr && muted != 0
    }

    private func writeMute(_ id: AudioDeviceID, _ muted: Bool) {
        var addr = muteAddress()
        guard AudioObjectHasProperty(id, &addr), isSettable(id, &addr) else { return }
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    // MARK: CoreAudio — device enumeration

    private var systemObject: AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }

    private func outputDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { hasOutputChannels($0) }
    }

    private func hasOutputChannels(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private func defaultOutputDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &id) == noErr ? id : nil
    }

    private func deviceName(_ id: AudioDeviceID) -> String? { getString(id, kAudioObjectPropertyName) }
    private func deviceUID(_ id: AudioDeviceID)  -> String? { getString(id, kAudioDevicePropertyDeviceUID) }

    private func getString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var size = UInt32(MemoryLayout<CFString>.size)
        var value: Unmanaged<CFString>? = nil
        let err = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, UnsafeMutableRawPointer($0))
        }
        guard err == noErr, let str = value else { return nil }
        return str.takeRetainedValue() as String
    }

    // MARK: CoreAudio — listeners (live sync with F11/F12, System Settings, hot-plug)

    private var pendingRebuild: DispatchWorkItem?
    private var pendingRefresh: DispatchWorkItem?

    /// Coalesces a burst of device-topology notifications into a single rebuild, so device
    /// churn (e.g. a daemon repeatedly grabbing/releasing CoreAudio devices) can't saturate
    /// the main thread with back-to-back synchronous `rebuild()` calls.
    private func scheduleRebuild() {
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild() }
        pendingRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Coalesces a burst of volume / mute notifications into a single refresh.
    private func scheduleRefreshVolumes() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshVolumes() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: work)
    }

    private func registerListeners() {
        removeAllListeners()
        // Rebuild when the default output device or the device list changes. The block
        // is dispatched on the main queue (as in CoreAudioManager), so it can touch
        // `@Published` state and call main-actor methods directly.
        let onHardware: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRebuild() }
        addBlock(systemObject, kAudioHardwarePropertyDefaultOutputDevice,
                 kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain, onHardware)
        addBlock(systemObject, kAudioHardwarePropertyDevices,
                 kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain, onHardware)
        // Follow each target's live volume (master + channels 1&2).
        let onVolume: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRefreshVolumes() }
        for target in targets {
            for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
                addBlock(target.deviceID, kAudioDevicePropertyVolumeScalar,
                         kAudioDevicePropertyScopeOutput, element, onVolume)
            }
            // F10 mute toggles a separate property → follow it too.
            addBlock(target.deviceID, kAudioDevicePropertyMute,
                     kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain, onVolume)
        }
    }

    private func addBlock(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          _ scope: AudioObjectPropertyScope, _ element: AudioObjectPropertyElement,
                          _ block: @escaping AudioObjectPropertyListenerBlock) {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        guard AudioObjectHasProperty(id, &addr) else { return }
        if AudioObjectAddPropertyListenerBlock(id, &addr, DispatchQueue.main, block) == noErr {
            registrations.append(Registration(id: id, addr: addr, block: block))
        }
    }

    private func removeAllListeners() {
        pendingRebuild?.cancel(); pendingRebuild = nil
        pendingRefresh?.cancel(); pendingRefresh = nil
        for var reg in registrations {
            AudioObjectRemovePropertyListenerBlock(reg.id, &reg.addr, DispatchQueue.main, reg.block)
        }
        registrations.removeAll()
    }
}
