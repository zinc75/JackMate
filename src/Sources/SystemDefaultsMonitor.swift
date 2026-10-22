//
//  SystemDefaultsMonitor.swift
//  JackMate
//
//  Copyright © 2026 Éric Bavu. All rights reserved.
//  Licensed under the MIT License — see LICENSE for details.
//
//  Watches the macOS default input and output devices (CoreAudio, event-driven, no polling) so
//  JackMate can tell when they are not JackMoebius while apps depend on it. JackMoebius sets them
//  itself when it starts and while an app is in shared input mode; a change made later in System
//  Settings silently cuts those apps off, which is what the notice strip points out.
//

import Foundation
import CoreAudio
import Combine

@MainActor
final class SystemDefaultsMonitor: ObservableObject {

    /// Stable CoreAudio UID of the JackMoebius system device.
    static let jackMoebiusUID = "com.jackmoebius.device"

    /// Name and identity of the current default output / input devices.
    @Published private(set) var outputName: String? = nil
    @Published private(set) var outputIsJackMoebius = true
    @Published private(set) var inputName: String? = nil
    @Published private(set) var inputIsJackMoebius = true

    private var registrations: [(addr: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private var systemObject: AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }

    init() {
        refresh()
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice] {
            var addr = AudioObjectPropertyAddress(mSelector: selector,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
            if AudioObjectAddPropertyListenerBlock(systemObject, &addr, DispatchQueue.main, block) == noErr {
                registrations.append((addr, block))
            }
        }
    }

    /// Re-reads both defaults.
    func refresh() {
        let out = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let inp = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        outputName = out.flatMap { string($0, kAudioObjectPropertyName) }
        outputIsJackMoebius = out.flatMap { string($0, kAudioDevicePropertyDeviceUID) } == Self.jackMoebiusUID
        inputName = inp.flatMap { string($0, kAudioObjectPropertyName) }
        inputIsJackMoebius = inp.flatMap { string($0, kAudioDevicePropertyDeviceUID) } == Self.jackMoebiusUID
    }

    /// Makes JackMoebius the default output of the Mac. Always an explicit user action.
    func chooseJackMoebiusOutput() { setDefault(kAudioHardwarePropertyDefaultOutputDevice) }

    /// Makes JackMoebius the default input of the Mac. Always an explicit user action.
    func chooseJackMoebiusInput() { setDefault(kAudioHardwarePropertyDefaultInputDevice) }

    // MARK: CoreAudio helpers

    private func setDefault(_ selector: AudioObjectPropertySelector) {
        guard var id = deviceID(forUID: Self.jackMoebiusUID) else { return }
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(systemObject, &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        refresh()
    }

    private func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &id)
        return err == noErr && id != 0 ? id : nil
    }

    /// `kAudioHardwarePropertyTranslateUIDToDevice`: the device with this UID, if it exists.
    private func deviceID(forUID uid: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = withUnsafeMutablePointer(to: &cfUID) { qualifier in
            AudioObjectGetPropertyData(systemObject, &addr,
                                       UInt32(MemoryLayout<CFString>.size), qualifier, &size, &id)
        }
        return err == noErr && id != kAudioObjectUnknown ? id : nil
    }

    private func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
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
}
