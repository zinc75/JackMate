//
//  CoreAudioManager.swift
//  JackMate
//
//  Copyright © 2026 Éric Bavu. All rights reserved.
//  Licensed under the MIT License — see LICENSE for details.
//
//  Enumerates CoreAudio devices, filters them to Jack-compatible
//  physical hardware, and monitors plug/unplug events.
//

import Foundation
import CoreAudio
import Combine

// MARK: - AudioDeviceInfo

/// A snapshot of a CoreAudio device's properties, pre-computed for use in the UI.
struct AudioDeviceInfo: Identifiable, Hashable {
    /// The CoreAudio `AudioObjectID` that uniquely identifies this device.
    let id: AudioObjectID
    /// Human-readable device name as reported by CoreAudio.
    let name: String
    /// Persistent UID string (e.g. `"AppleUSBAudioEngine:..."`).
    let uid: String
    /// `true` if the device has at least one input channel.
    let isInput: Bool
    /// `true` if the device has at least one output channel.
    let isOutput: Bool
    /// `true` if this is a CoreAudio aggregate device.
    let isAggregate: Bool
    /// `true` if this device uses the built-in transport type (internal mic / speaker).
    let isBuiltIn: Bool
    /// Total number of input channels across all input streams.
    let inputChannels: Int
    /// Total number of output channels across all output streams.
    let outputChannels: Int
    /// All sample rates the device can be configured to run at.
    let nominalSampleRates: [Double]
    /// The sample rate currently active on the device.
    var currentSampleRate: Double
}

// MARK: - CoreAudioManager

/// Observes the CoreAudio hardware graph and exposes filtered device lists.
///
/// Only Jack-compatible physical transports are included (built-in, USB,
/// Thunderbolt, FireWire, PCI, HDMI, DisplayPort, aggregate).
/// Bluetooth, AirPlay, and virtual devices (Teams, Zoom, etc.) are excluded.
///
/// Device lists are refreshed with a 150 ms debounce to handle rapid
/// plug/unplug sequences gracefully.
@MainActor
final class CoreAudioManager: ObservableObject {

    /// Devices that have at least one input channel.
    @Published var inputDevices:  [AudioDeviceInfo] = []
    /// Devices that have at least one output channel.
    @Published var outputDevices: [AudioDeviceInfo] = []
    /// All Jack-compatible devices, regardless of direction.
    @Published var allDevices:    [AudioDeviceInfo] = []

    init() {
        refresh()
        startMonitoring()
    }

    deinit {
        cleanup()
    }

    /// Removes the CoreAudio property listener registered by `startMonitoring()`.
    nonisolated func cleanup() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            { _, _ in })
    }

    // MARK: - Refresh

    private var refreshTask: DispatchWorkItem?

    /// Schedules a debounced device list refresh.
    ///
    /// Cancels any pending refresh and waits 150 ms before executing, so that
    /// rapid back-to-back notifications (e.g. USB hub enumeration) only trigger
    /// a single fetch.
    func refresh() {
        refreshTask?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.doRefresh()
        }
        refreshTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func doRefresh() {
        let devices = fetchAllDevices()
        allDevices    = devices
        inputDevices  = devices.filter { $0.inputChannels  > 0 }
        outputDevices = devices.filter { $0.outputChannels > 0 }
    }

    // MARK: - Compatible sample rates

    /// Returns the sample rates supported by the selected input and output devices.
    ///
    /// - If both devices are selected: the intersection of their rate lists.
    /// - If only one is selected: that device's rate list.
    /// - If neither is selected: a standard fallback list.
    ///
    /// - Parameters:
    ///   - inputUID:  UID of the selected input device, or an empty string if none.
    ///   - outputUID: UID of the selected output device, or an empty string if none.
    /// - Returns: A sorted array of compatible sample rates in Hz.
    func compatibleSampleRates(inputUID: String, outputUID: String) -> [Double] {
        let inputDevice  = allDevices.first { $0.uid == inputUID  && $0.inputChannels  > 0 }
        let outputDevice = allDevices.first { $0.uid == outputUID && $0.outputChannels > 0 }

        switch (inputDevice, outputDevice) {
        case let (input?, output?):
            let common = Set(input.nominalSampleRates)
                .intersection(Set(output.nominalSampleRates))
                .sorted()
            return common.isEmpty ? fallbackRates() : common

        case let (input?, nil):
            let rates = input.nominalSampleRates
            return rates.isEmpty ? fallbackRates() : rates

        case let (nil, output?):
            let rates = output.nominalSampleRates
            return rates.isEmpty ? fallbackRates() : rates

        case (nil, nil):
            return fallbackRates()
        }
    }

    /// Standard sample rates used when device information is unavailable.
    private func fallbackRates() -> [Double] {
        [44100, 48000, 88200, 96000, 176400, 192000]
    }

    // MARK: - Device enumeration

    private func fetchAllDevices() -> [AudioDeviceInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize, &deviceIDs) == noErr else { return [] }

        return deviceIDs.compactMap { makeDeviceInfo(id: $0) }
    }

    private func makeDeviceInfo(id: AudioObjectID) -> AudioDeviceInfo? {
        guard id != kAudioObjectUnknown else { return nil }

        // Filter by transport type first. Only keep physical hardware compatible
        // with Jack: built-in, USB, Thunderbolt, FireWire, PCI, HDMI, DisplayPort.
        // Excluded: Bluetooth, AirPlay, virtual devices (Teams, Zoom, Webex…).
        let transport = transportType(id: id)
        let physicalTransports: Set<UInt32> = [
            kAudioDeviceTransportTypeBuiltIn,
            kAudioDeviceTransportTypeUSB,
            kAudioDeviceTransportTypeThunderbolt,
            kAudioDeviceTransportTypeFireWire,
            kAudioDeviceTransportTypePCI,
            kAudioDeviceTransportTypeHDMI,
            kAudioDeviceTransportTypeDisplayPort,
            kAudioDeviceTransportTypeAggregate,  // may combine multiple physical devices
        ]
        guard physicalTransports.contains(transport) else { return nil }

        guard let name = stringProperty(id: id,
            selector: kAudioObjectPropertyName,
            scope: kAudioObjectPropertyScopeGlobal) else { return nil }

        let uid = stringProperty(id: id,
            selector: kAudioDevicePropertyDeviceUID,
            scope: kAudioObjectPropertyScopeGlobal) ?? ""

        guard !uid.isEmpty else { return nil }

        let inputCh  = channelCount(id: id, scope: kAudioDevicePropertyScopeInput)
        let outputCh = channelCount(id: id, scope: kAudioDevicePropertyScopeOutput)

        guard inputCh > 0 || outputCh > 0 else { return nil }

        let sampleRates = nominalSampleRates(id: id)
        let currentSR   = currentSampleRate(id: id)

        return AudioDeviceInfo(
            id:                 id,
            name:               name,
            uid:                uid,
            isInput:            inputCh > 0,
            isOutput:           outputCh > 0,
            isAggregate:        transport == kAudioDeviceTransportTypeAggregate,
            isBuiltIn:          transport == kAudioDeviceTransportTypeBuiltIn,
            inputChannels:      inputCh,
            outputChannels:     outputCh,
            nominalSampleRates: sampleRates,
            currentSampleRate:  currentSR
        )
    }

    // MARK: - CoreAudio property helpers

    private func stringProperty(id: AudioObjectID,
                                selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString>.size)
        var value: Unmanaged<CFString>? = nil
        let err = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size,
                UnsafeMutableRawPointer($0))
        }
        guard err == noErr, let str = value else { return nil }
        return str.takeRetainedValue() as String
    }

    private func channelCount(id: AudioObjectID,
                              scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size > 0 else { return 0 }
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, bufferList) == noErr
        else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func transportType(id: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }

    private func nominalSampleRates(id: AudioObjectID) -> [Double] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr
        else { return [] }
        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &ranges) == noErr
        else { return [] }
        return ranges.map { $0.mMinimum }.sorted()
    }

    private func currentSampleRate(id: AudioObjectID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }

    /// Sets the nominal sample rate on a CoreAudio device.
    ///
    /// - Parameters:
    ///   - rate:     Desired sample rate in Hz.
    ///   - deviceID: Target `AudioObjectID`.
    func setSampleRate(_ rate: Double, for deviceID: AudioObjectID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = rate
        AudioObjectSetPropertyData(deviceID, &address, 0, nil,
            UInt32(MemoryLayout<Float64>.size), &value)
    }

    // MARK: - Hot-plug monitoring

    private func startMonitoring() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain)

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main
        ) { [weak self] _, _ in
            self?.refresh()
        }
    }
}
