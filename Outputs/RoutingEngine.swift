import CoreAudio
import Foundation
import os

nonisolated struct EngineError: Error, CustomStringConvertible {
    let step: String
    let status: OSStatus

    var description: String {
        "\(step) failed with status \(status)"
    }
}

nonisolated struct EnginePointer: @unchecked Sendable {
    let raw: OpaquePointer
}

nonisolated final class RoutingEngine: @unchecked Sendable {
    struct Output: Equatable, Sendable {
        let uid: String
        let device: AudioObjectID
        let isWireless: Bool
        let sampleRate: Double
    }

    struct Source: Equatable, Sendable {
        let bundleID: String?
        let processes: [AudioObjectID]
        let isGlobal: Bool
        let outputs: [Int]
    }

    struct Plan: Equatable, Sendable {
        let outputs: [Output]
        let sources: [Source]
        let excluded: [AudioObjectID]
    }

    struct Parameters: Sendable {
        var gains: [Float]
        var delays: [Float]
        var equalizers: [[Float]]
        var running: [Bool]
        var sourceGains: [Float]
    }

    private struct Shared {
        var engine: EnginePointer?
        var parameters = Parameters(gains: [], delays: [], equalizers: [], running: [], sourceGains: [])
        var testClicks = false
        var generation = 0

        func push(immediate: Bool = false) {
            guard let engine = engine?.raw else { return }
            for (index, running) in parameters.running.enumerated() {
                if immediate {
                    od_set_output_running_immediate(engine, Int32(index), running ? 1 : 0)
                } else {
                    od_set_output_running(engine, Int32(index), running ? 1 : 0)
                }
            }
            for (index, gain) in parameters.sourceGains.enumerated() {
                od_set_source_gain(engine, Int32(index), gain)
            }
            for (index, gain) in parameters.gains.enumerated() {
                od_set_output_gain(engine, Int32(index), gain)
            }
            for (index, delay) in parameters.delays.enumerated() {
                od_set_output_delay_ms(engine, Int32(index), delay)
            }
            for (index, bands) in parameters.equalizers.enumerated() where bands.count == Int(OD_EQ_BANDS) {
                bands.withUnsafeBufferPointer { od_set_output_eq(engine, Int32(index), $0.baseAddress) }
            }
            od_set_test_clicks(engine, testClicks ? 1 : 0)
        }
    }

    private static let maxFrames: UInt32 = 4096
    private static let bufferFrames: UInt32 = 512
    private static let logger = Logger(subsystem: "devplaceholder.WAZ2022C.Outputs", category: "engine")

    private let queue = DispatchQueue(label: "Outputs.Engine", qos: .userInitiated)
    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private var taps: [AudioObjectID] = []
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var dsp: OpaquePointer?

    func run(_ plan: Plan, parameters: Parameters, completion: @escaping @Sendable (Error?) -> Void) {
        let generation = shared.withLock { state in
            state.generation += 1
            state.parameters = parameters
            return state.generation
        }
        queue.async { [self] in
            guard shared.withLock({ $0.generation }) == generation else { return }
            teardown()
            do {
                try build(plan)
                completion(nil)
            } catch {
                Self.logger.error("\(String(describing: error), privacy: .public)")
                teardown()
                completion(error)
            }
        }
    }

    func stop(completion: (@Sendable () -> Void)? = nil) {
        let generation = shared.withLock { state in
            state.generation += 1
            return state.generation
        }
        queue.async { [self] in
            guard shared.withLock({ $0.generation }) == generation else { return }
            teardown()
            completion?()
        }
    }

    func stopNow() {
        shared.withLock { $0.generation += 1 }
        queue.sync { teardown() }
    }

    func update(_ parameters: Parameters) {
        shared.withLock { state in
            state.parameters = parameters
            state.push()
        }
    }

    func setTestClicks(_ enabled: Bool) {
        shared.withLock { state in
            state.testClicks = enabled
            state.push()
        }
    }

    func levels(outputs: Int) -> [Float] {
        shared.withLock { state in
            guard let engine = state.engine?.raw else { return Array(repeating: 0, count: outputs) }
            return (0..<outputs).map { od_output_level(engine, Int32($0)) }
        }
    }

    private func build(_ plan: Plan) throws {
        guard !plan.outputs.isEmpty, !plan.sources.isEmpty,
              plan.outputs.count <= Int(OD_MAX_OUTPUTS), plan.sources.count <= Int(OD_MAX_SOURCES) else {
            throw EngineError(step: "plan", status: kAudioHardwareIllegalOperationError)
        }
        var tapUIDs: [String] = []
        for source in plan.sources {
            let description = source.isGlobal
                ? CATapDescription(stereoGlobalTapButExcludeProcesses: plan.excluded)
                : CATapDescription(stereoMixdownOfProcesses: source.processes)
            description.uuid = UUID()
            description.name = "Outputs"
            description.isPrivate = true
            description.muteBehavior = .muted
            var tap = AudioObjectID(kAudioObjectUnknown)
            try check(AudioHardwareCreateProcessTap(description, &tap), "AudioHardwareCreateProcessTap")
            taps.append(tap)
            tapUIDs.append(description.uuid.uuidString)
        }

        let main = plan.outputs.first { !$0.isWireless } ?? plan.outputs[0]
        let subdevices: [[String: Any]] = plan.outputs.map { output in
            [
                kAudioSubDeviceUIDKey: output.uid,
                kAudioSubDeviceDriftCompensationKey: output.uid == main.uid ? 0 : 1
            ]
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Outputs",
            kAudioAggregateDeviceUIDKey: "Outputs-" + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: main.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: subdevices,
            kAudioAggregateDeviceTapListKey: tapUIDs.map { [kAudioSubTapUIDKey: $0, kAudioSubTapDriftCompensationKey: true] }
        ]
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID), "AudioHardwareCreateAggregateDevice")
        CoreAudioHardware.setValue(Self.bufferFrames, on: aggregateID, kAudioDevicePropertyBufferFrameSize)

        let outputStreams = AudioDeviceReader.streamChannels(aggregateID, scope: kAudioObjectPropertyScopeOutput)
        let inputStreams = AudioDeviceReader.streamChannels(aggregateID, scope: kAudioObjectPropertyScopeInput)
        var outputBuffer: [Int32] = []
        var outputOffset: [Int32] = []
        var outputChannels: [Int32] = []
        var cursor = 0
        for output in plan.outputs {
            let streams = AudioDeviceReader.streamChannels(output.device, scope: kAudioObjectPropertyScopeOutput)
            guard let channels = streams.first, cursor < outputStreams.count, outputStreams[cursor] == channels else {
                throw EngineError(step: "output layout \(outputStreams)", status: kAudioHardwareBadStreamError)
            }
            outputBuffer.append(Int32(cursor))
            outputOffset.append(0)
            outputChannels.append(Int32(channels))
            cursor += streams.count
        }
        guard cursor == outputStreams.count, inputStreams.count >= taps.count,
              inputStreams.suffix(taps.count).allSatisfy({ $0 >= 1 }) else {
            throw EngineError(step: "stream layout in \(inputStreams) out \(outputStreams)", status: kAudioHardwareBadStreamError)
        }
        let firstTapStream = inputStreams.count - taps.count
        let sourceBuffer = (0..<taps.count).map { Int32(firstTapStream + $0) }
        let sourceOffset = Array(repeating: Int32(0), count: taps.count)
        Self.logger.info("aggregate in \(inputStreams, privacy: .public) out \(outputStreams, privacy: .public) taps \(self.taps.count)")

        let rate = CoreAudioHardware.value(aggregateID, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)) ?? 48000
        guard let engine = od_create(rate > 0 ? rate : 48000, Self.maxFrames) else {
            throw EngineError(step: "od_create", status: kAudioHardwareUnspecifiedError)
        }
        dsp = engine
        sourceBuffer.withUnsafeBufferPointer { buffers in
            sourceOffset.withUnsafeBufferPointer { offsets in
                od_set_source_layout(engine, Int32(taps.count), buffers.baseAddress, offsets.baseAddress)
            }
        }
        outputBuffer.withUnsafeBufferPointer { buffers in
            outputOffset.withUnsafeBufferPointer { offsets in
                outputChannels.withUnsafeBufferPointer { channels in
                    od_set_output_layout(engine, Int32(plan.outputs.count), buffers.baseAddress, offsets.baseAddress, channels.baseAddress)
                }
            }
        }
        for (index, source) in plan.sources.enumerated() {
            for output in source.outputs {
                od_set_route(engine, Int32(index), Int32(output), 1)
            }
        }
        try check(
            AudioDeviceCreateIOProcID(aggregateID, od_ioproc, UnsafeMutableRawPointer(engine), &ioProcID),
            "AudioDeviceCreateIOProcID"
        )
        disableDeviceInputs(streams: inputStreams.count, firstTap: firstTapStream)
        let pointer = EnginePointer(raw: engine)
        shared.withLock { state in
            state.engine = pointer
            state.push(immediate: true)
        }
        try check(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")
    }

    private func disableDeviceInputs(streams: Int, firstTap: Int) {
        guard streams > 0, firstTap > 0, let ioProcID else { return }
        let size = MemoryLayout<AudioHardwareIOProcStreamUsage>.size + max(streams - 1, 0) * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        let usage = raw.bindMemory(to: AudioHardwareIOProcStreamUsage.self, capacity: 1)
        usage.pointee.mIOProc = unsafeBitCast(ioProcID, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(streams)
        let flags = raw.advanced(by: MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!).bindMemory(to: UInt32.self, capacity: streams)
        for index in 0..<streams {
            flags[index] = index >= firstTap ? 1 : 0
        }
        var address = CoreAudioHardware.propertyAddress(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
        let status = AudioObjectSetPropertyData(aggregateID, &address, 0, nil, UInt32(size), raw)
        if status != noErr {
            Self.logger.error("IOProcStreamUsage failed with status \(status)")
        }
    }

    private func teardown() {
        var released = true
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            released = AudioDeviceDestroyIOProcID(aggregateID, ioProcID) == noErr
        }
        ioProcID = nil
        shared.withLock { $0.engine = nil }
        if aggregateID != kAudioObjectUnknown {
            if AudioHardwareDestroyAggregateDevice(aggregateID) != noErr {
                Self.logger.error("AudioHardwareDestroyAggregateDevice failed")
            }
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        for tap in taps where AudioHardwareDestroyProcessTap(tap) != noErr {
            Self.logger.error("AudioHardwareDestroyProcessTap failed")
        }
        taps = []
        if let dsp, released {
            od_destroy(dsp)
        }
        dsp = nil
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else {
            throw EngineError(step: step, status: status)
        }
    }
}

nonisolated extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
