import CoreAudio
import Foundation
import Observation

nonisolated struct AudioOutputDevice: Identifiable, Hashable, Sendable {
    enum Kind: Sendable {
        case builtIn
        case bluetooth
        case usb
        case airPlay
        case display
        case virtual
        case other
    }

    let id: AudioObjectID
    let uid: String
    let name: String
    let kind: Kind
    let channels: Int
    let sampleRate: Double
    let latency: Double

    var isWireless: Bool {
        kind == .bluetooth || kind == .airPlay
    }

    var shortKind: String {
        switch kind {
        case .builtIn: String(localized: "MAC")
        case .bluetooth: String(localized: "BT")
        case .usb: String(localized: "USB")
        case .airPlay: String(localized: "AIRPLAY")
        case .display: String(localized: "HDMI")
        case .virtual: String(localized: "VIRT")
        case .other: String(localized: "JACK")
        }
    }

    var symbolName: String {
        switch kind {
        case .builtIn: "laptopcomputer"
        case .bluetooth: "headphones"
        case .usb: "cable.connector"
        case .airPlay: "airplayaudio"
        case .display: "display"
        case .virtual: "waveform"
        case .other: "headphones"
        }
    }
}

nonisolated enum AudioDeviceReader {
    static func outputDevices() -> [AudioOutputDevice] {
        dispatchPrecondition(condition: .onQueue(CoreAudioHardware.queue))
        var address = CoreAudioHardware.propertyAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(CoreAudioHardware.systemObject, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(CoreAudioHardware.systemObject, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.compactMap(device(for:))
    }

    static func device(for id: AudioObjectID) -> AudioOutputDevice? {
        let transport = CoreAudioHardware.value(id, kAudioDevicePropertyTransportType, initial: UInt32(0)) ?? 0
        guard transport != kAudioDeviceTransportTypeAggregate, transport != kAudioDeviceTransportTypeAutoAggregate else { return nil }
        let channels = channelCount(id, scope: kAudioObjectPropertyScopeOutput)
        guard channels > 0,
              let uid = CoreAudioHardware.string(id, kAudioDevicePropertyDeviceUID),
              let name = CoreAudioHardware.string(id, kAudioObjectPropertyName) else { return nil }
        let rate = CoreAudioHardware.value(id, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)) ?? 0
        var kind = kind(of: transport)
        if kind == .builtIn, isHeadphoneJack(id) {
            kind = .other
        }
        return AudioOutputDevice(
            id: id,
            uid: uid,
            name: name,
            kind: kind,
            channels: channels,
            sampleRate: rate,
            latency: estimatedLatency(id, sampleRate: rate)
        )
    }

    static func channelCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        streamChannels(id, scope: scope).reduce(0, +)
    }

    static func streamChannels(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> [Int] {
        dispatchPrecondition(condition: .onQueue(CoreAudioHardware.queue))
        var address = CoreAudioHardware.propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        guard let id = CoreAudioHardware.value(CoreAudioHardware.systemObject, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(kAudioObjectUnknown)),
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func volume(of id: AudioObjectID) -> Float? {
        dispatchPrecondition(condition: .onQueue(CoreAudioHardware.queue))
        if isMuted(id) {
            return 0
        }
        let scope = kAudioObjectPropertyScopeOutput
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: scope, mElement: element)
            guard AudioObjectHasProperty(id, &address) else { continue }
            var value = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr {
                return value
            }
        }
        return nil
    }

    static func isMuted(_ id: AudioObjectID) -> Bool {
        dispatchPrecondition(condition: .onQueue(CoreAudioHardware.queue))
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &address) else { return false }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func isHeadphoneJack(_ id: AudioObjectID) -> Bool {
        let source = CoreAudioHardware.value(id, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput, initial: UInt32(0)) ?? 0
        return source == 0x6864_706E
    }

    private static func kind(of transport: UInt32) -> AudioOutputDevice.Kind {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
        case kAudioDeviceTransportTypeUSB: .usb
        case kAudioDeviceTransportTypeAirPlay: .airPlay
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: .display
        case kAudioDeviceTransportTypeVirtual: .virtual
        default: .other
        }
    }

    private static func estimatedLatency(_ id: AudioObjectID, sampleRate: Double) -> Double {
        guard sampleRate > 0 else { return 0 }
        let scope = kAudioObjectPropertyScopeOutput
        let device = CoreAudioHardware.value(id, kAudioDevicePropertyLatency, scope: scope, initial: UInt32(0)) ?? 0
        let safety = CoreAudioHardware.value(id, kAudioDevicePropertySafetyOffset, scope: scope, initial: UInt32(0)) ?? 0
        let buffer = CoreAudioHardware.value(id, kAudioDevicePropertyBufferFrameSize, initial: UInt32(0)) ?? 0
        let stream = firstStream(id, scope: scope).flatMap {
            CoreAudioHardware.value($0, kAudioStreamPropertyLatency, initial: UInt32(0))
        } ?? 0
        return Double(device + safety + buffer + stream) / sampleRate * 1000
    }

    private static func firstStream(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> AudioObjectID? {
        dispatchPrecondition(condition: .onQueue(CoreAudioHardware.queue))
        var address = CoreAudioHardware.propertyAddress(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var streams = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &streams) == noErr else { return nil }
        return streams.first
    }
}

@Observable
final class AudioDeviceMonitor {
    private(set) var devices: [AudioOutputDevice] = []
    private(set) var defaultDevice: AudioObjectID?
    private(set) var defaultDeviceUID: String?
    private(set) var masterVolume: Float = 1

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onVolumeChange: (() -> Void)?
    @ObservationIgnored private var deviceListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var defaultListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var volumeListeners: [(AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyScope, AudioObjectPropertyElement, AudioObjectPropertyListenerBlock)] = []
    @ObservationIgnored private var rateListeners: [(AudioObjectID, AudioObjectPropertyListenerBlock)] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var devicesPending = false
    @ObservationIgnored private var notifyPending = false

    func start() {
        guard deviceListener == nil else { return }
        deviceListener = CoreAudioHardware.addListener(to: CoreAudioHardware.systemObject, selector: kAudioHardwarePropertyDevices) { [weak self] in
            self?.scheduleRefresh()
        }
        defaultListener = CoreAudioHardware.addListener(to: CoreAudioHardware.systemObject, selector: kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            self?.refreshDefault()
        }
        refresh()
    }

    func device(uid: String) -> AudioOutputDevice? {
        devices.first { $0.uid == uid }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func refresh() {
        requestRefresh(includeDevices: true, notify: false)
    }

    private func requestRefresh(includeDevices: Bool, notify: Bool) {
        guard !isRefreshing else {
            refreshPending = true
            devicesPending = devicesPending || includeDevices
            notifyPending = notifyPending || notify
            return
        }
        isRefreshing = true
        CoreAudioHardware.queue.async { [weak self] in
            let fresh = includeDevices ? AudioDeviceReader.outputDevices().sorted { lhs, rhs in
                if lhs.kind == .builtIn, rhs.kind != .builtIn { return true }
                if rhs.kind == .builtIn, lhs.kind != .builtIn { return false }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            } : nil
            let current = AudioDeviceReader.defaultOutputDevice()
            let uid = current.flatMap { CoreAudioHardware.string($0, kAudioDevicePropertyDeviceUID) }
            let volume = current.flatMap(AudioDeviceReader.volume(of:)) ?? 1
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let changed = fresh.map { $0 != self.devices } ?? false
                if let fresh {
                    self.devices = fresh
                    self.watchSampleRates()
                }
                let switched = current != self.defaultDevice
                let volumeChanged = volume != self.masterVolume
                self.defaultDevice = current
                self.defaultDeviceUID = uid
                self.masterVolume = volume
                if switched {
                    self.watchVolume()
                }
                if volumeChanged, notify {
                    self.onVolumeChange?()
                }
                if switched, notify {
                    self.onVolumeChange?()
                }
                if changed {
                    self.onChange?()
                }
                self.isRefreshing = false
                if self.refreshPending {
                    let includeDevices = self.devicesPending
                    let notify = self.notifyPending
                    self.refreshPending = false
                    self.devicesPending = false
                    self.notifyPending = false
                    self.requestRefresh(includeDevices: includeDevices, notify: notify)
                }
            }
        }
    }

    private func watchSampleRates() {
        for (id, block) in rateListeners {
            CoreAudioHardware.removeListener(block, from: id, selector: kAudioDevicePropertyNominalSampleRate)
        }
        rateListeners = devices.map { device in
            (device.id, CoreAudioHardware.addListener(to: device.id, selector: kAudioDevicePropertyNominalSampleRate) { [weak self] in
                self?.scheduleRefresh()
            })
        }
    }

    private func refreshDefault(notify: Bool = true) {
        requestRefresh(includeDevices: false, notify: notify)
    }

    private func watchVolume() {
        for (id, selector, scope, element, block) in volumeListeners {
            CoreAudioHardware.removeListener(block, from: id, selector: selector, scope: scope, element: element)
        }
        volumeListeners = []
        guard let device = defaultDevice else { return }
        let scope = kAudioObjectPropertyScopeOutput
        let targets: [(AudioObjectPropertySelector, AudioObjectPropertyElement)] = [
            (kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain),
            (kAudioDevicePropertyVolumeScalar, 1),
            (kAudioDevicePropertyVolumeScalar, 2),
            (kAudioDevicePropertyMute, kAudioObjectPropertyElementMain)
        ]
        for (selector, element) in targets {
            let block = CoreAudioHardware.addListener(to: device, selector: selector, scope: scope, element: element) { [weak self] in
                self?.updateVolume(notify: true)
            }
            volumeListeners.append((device, selector, scope, element, block))
        }
    }

    private func updateVolume(notify: Bool) {
        refreshDefault(notify: notify)
    }
}
