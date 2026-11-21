import CoreAudio
import Foundation
import os

nonisolated enum CoreAudioHardware {
    static let queue = DispatchQueue(label: "Outputs.CoreAudio", qos: .userInitiated)
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private static let bundleIdentifiers = OSAllocatedUnfairLock(initialState: [AudioObjectID: String]())

    static func propertyAddress(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func value<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        initial: T
    ) -> T? {
        dispatchPrecondition(condition: .onQueue(queue))
        var address = propertyAddress(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        var result = initial
        let status = withUnsafeMutablePointer(to: &result) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? result : nil
    }

    static func isSettable(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        var address = propertyAddress(selector, scope: scope)
        guard AudioObjectHasProperty(object, &address) else { return false }
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
    }

    @discardableResult
    static func setValue<T>(
        _ newValue: T,
        on object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        var address = propertyAddress(selector, scope: scope)
        var data = newValue
        let size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &data) { pointer in
            AudioObjectSetPropertyData(object, &address, 0, nil, size, pointer)
        } == noErr
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        dispatchPrecondition(condition: .onQueue(queue))
        var address = propertyAddress(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var result: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr else {
            return nil
        }
        return result?.takeRetainedValue() as String?
    }

    static func processObjects() -> [AudioObjectID] {
        dispatchPrecondition(condition: .onQueue(queue))
        var address = propertyAddress(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else {
            return []
        }
        guard size > 0 else {
            bundleIdentifiers.withLock { $0.removeAll(keepingCapacity: true) }
            return []
        }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &objects) == noErr else {
            return []
        }
        objects = Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
        let current = Set(objects)
        bundleIdentifiers.withLock { cache in
            cache = cache.filter { current.contains($0.key) }
        }
        return objects
    }

    static func bundleIdentifier(of process: AudioObjectID) -> String? {
        bundleIdentifiers.withLock { cache in
            if let identifier = cache[process] {
                return identifier
            }
            guard let identifier = string(process, kAudioProcessPropertyBundleID), !identifier.isEmpty else { return nil }
            cache[process] = identifier
            return identifier
        }
    }

    static func processObjects(matchingBundleIdentifier bundleIdentifier: String) -> [AudioObjectID] {
        processObjects(matchingBundleIdentifiers: [bundleIdentifier])
    }

    static func processObjects(matchingBundleIdentifiers identifiers: [String]) -> [AudioObjectID] {
        guard !identifiers.isEmpty else { return [] }
        let processes = processObjects()
        return processes.filter { process in
            guard let identifier = self.bundleIdentifier(of: process) else { return false }
            return identifiers.contains { identifier == $0 || identifier.hasPrefix($0 + ".") }
        }.sorted()
    }

    static func defaultOutputDeviceUID() -> String? {
        guard let device = value(systemObject, kAudioHardwarePropertyDefaultSystemOutputDevice, initial: AudioObjectID(kAudioObjectUnknown)),
              device != kAudioObjectUnknown else {
            return nil
        }
        return string(device, kAudioDevicePropertyDeviceUID)
    }

    static func addListener(
        to object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        handler: @escaping @MainActor @Sendable () -> Void
    ) -> AudioObjectPropertyListenerBlock {
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            DispatchQueue.main.async {
                handler()
            }
        }
        queue.async {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
            guard AudioObjectHasProperty(object, &address) else { return }
            AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
        }
        return block
    }

    static func removeListener(
        _ block: @escaping AudioObjectPropertyListenerBlock,
        from object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) {
        queue.async {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        }
    }
}
