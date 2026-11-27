import AppKit
import CoreAudio
import Observation

nonisolated struct AudioApp: Identifiable, Hashable, Sendable {
    let bundleID: String
    let name: String
    let isPlaying: Bool

    var id: String { bundleID }
}

nonisolated enum AudioProcessReader {
    static func isPlaying(_ process: AudioObjectID) -> Bool {
        (CoreAudioHardware.value(process, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0) != 0
    }

    static func pid(of process: AudioObjectID) -> pid_t? {
        CoreAudioHardware.value(process, kAudioProcessPropertyPID, initial: pid_t(-1)).flatMap { $0 > 0 ? $0 : nil }
    }

    static func ownProcess() -> AudioObjectID? {
        dispatchPrecondition(condition: .onQueue(CoreAudioHardware.queue))
        var pid = ProcessInfo.processInfo.processIdentifier
        var address = CoreAudioHardware.propertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(CoreAudioHardware.systemObject, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static func ownerBundleID(of process: AudioObjectID, running: RunningApps) -> String? {
        let identifier = CoreAudioHardware.bundleIdentifier(of: process)
        if let identifier, identifier.hasPrefix("com.apple.WebKit"), running.contains("com.apple.Safari") {
            return "com.apple.Safari"
        }
        if let pid = pid(of: process), let owner = running.bundleID(of: pid) {
            return owner
        }
        guard let identifier else { return nil }
        return running.identifiers.filter { identifier.hasPrefix($0 + ".") }.max { $0.count < $1.count } ?? identifier
    }

    static func displayName(of bundleID: String, running: RunningApps? = nil) -> String {
        if let name = running?.name(of: bundleID) ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }
}

nonisolated final class RunningApps {
    private let apps: [(identifier: String, app: NSRunningApplication)]
    private let byPID: [pid_t: (identifier: String, app: NSRunningApplication)]
    private var policies: [pid_t: NSApplication.ActivationPolicy] = [:]
    let identifiers: [String]

    init() {
        apps = NSWorkspace.shared.runningApplications.compactMap { app in
            app.bundleIdentifier.map { ($0, app) }
        }
        byPID = Dictionary(apps.map { ($0.app.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        identifiers = apps.map(\.identifier)
    }

    func contains(_ bundleID: String) -> Bool {
        apps.contains { $0.identifier == bundleID }
    }

    func bundleID(of pid: pid_t) -> String? {
        guard let entry = byPID[pid], policy(of: entry.app) != .prohibited else { return nil }
        return entry.identifier
    }

    func isRegular(_ bundleID: String) -> Bool {
        apps.contains { $0.identifier == bundleID && policy(of: $0.app) == .regular }
    }

    func name(of bundleID: String) -> String? {
        apps.first { $0.identifier == bundleID }?.app.localizedName
    }

    private func policy(of app: NSRunningApplication) -> NSApplication.ActivationPolicy {
        if let policy = policies[app.processIdentifier] {
            return policy
        }
        let policy = app.activationPolicy
        policies[app.processIdentifier] = policy
        return policy
    }
}

@Observable
final class AudioProcessMonitor {
    private(set) var apps: [AudioApp] = []
    private(set) var ownProcess: AudioObjectID?
    private(set) var processesByBundleID: [String: [AudioObjectID]] = [:]

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var listener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var processIDs: Set<AudioObjectID> = []
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var refreshPending = false

    func start() {
        guard listener == nil else { return }
        listener = CoreAudioHardware.addListener(to: CoreAudioHardware.systemObject, selector: kAudioHardwarePropertyProcessObjectList) { [weak self] in
            self?.refresh()
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func icon(for bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    func processes(for bundleID: String) -> [AudioObjectID] {
        processesByBundleID[bundleID] ?? []
    }

    private func refresh() {
        guard !isRefreshing else {
            refreshPending = true
            return
        }
        isRefreshing = true
        CoreAudioHardware.queue.async { [weak self] in
            let own = Bundle.main.bundleIdentifier
            let objects = CoreAudioHardware.processObjects()
            let ownProcess = AudioProcessReader.ownProcess()
            let running = RunningApps()
            CoreAudioHardware.forgetBundleIdentifiers(except: objects)
            var byBundleID: [String: [AudioObjectID]] = [:]
            var playing: [String: Bool] = [:]
            for object in objects {
                guard let identifier = AudioProcessReader.ownerBundleID(of: object, running: running) else { continue }
                byBundleID[identifier, default: []].append(object)
                guard identifier != own else { continue }
                playing[identifier] = (playing[identifier] ?? false) || AudioProcessReader.isPlaying(object)
            }
            let fresh = playing.filter { running.isRegular($0.key) }.map { AudioApp(bundleID: $0.key, name: AudioProcessReader.displayName(of: $0.key, running: running), isPlaying: $0.value) }
                .sorted { lhs, rhs in
                    if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            let processes = byBundleID
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let idsChanged = Set(objects) != self.processIDs || ownProcess != self.ownProcess || processes != self.processesByBundleID
                self.processIDs = Set(objects)
                self.ownProcess = ownProcess
                self.processesByBundleID = processes
                if fresh != self.apps {
                    self.apps = fresh
                }
                if idsChanged {
                    self.onChange?()
                }
                self.isRefreshing = false
                if self.refreshPending {
                    self.refreshPending = false
                    self.refresh()
                }
            }
        }
    }
}
