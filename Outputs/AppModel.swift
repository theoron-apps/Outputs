import AppKit
import Observation
import ServiceManagement

@Observable
final class AppModel {
    enum Status: Equatable {
        case off
        case starting
        case running
        case noOutputs
        case failed(String)
    }

    let devices = AudioDeviceMonitor()
    let processes = AudioProcessMonitor()
    let updates = UpdateChecker()

    private(set) var settings = StoredSettings.load()
    private(set) var status: Status = .off
    private(set) var levels: [String: Float] = [:]
    private(set) var isTesting = false
    private(set) var powerToken = 0
    private(set) var launchesAtLogin = SMAppService.mainApp.status == .enabled

    @ObservationIgnored private let engine = RoutingEngine()
    @ObservationIgnored private var runningPlan: RoutingEngine.Plan?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var request = 0
    @ObservationIgnored var onStateChange: (() -> Void)?

    var isOn: Bool { settings.isOn }

    var activeOutputs: [AudioOutputDevice] {
        settings.selected.compactMap { devices.device(uid: $0) }
    }

    var missingOutputs: [String] {
        settings.selected.filter { devices.device(uid: $0) == nil }
    }

    var availableOutputs: [AudioOutputDevice] {
        devices.devices.filter { !settings.selected.contains($0.uid) }
    }

    var isPlaying: Bool {
        status == .running && levels.values.contains { $0 > 0.02 }
    }

    var peakLevel: Float {
        levels.values.max() ?? 0
    }

    private var setKey: String {
        activeOutputs.map(\.uid).sorted().joined(separator: "|")
    }

    func start() {
        devices.onChange = { [weak self] in self?.devicesChanged() }
        devices.onVolumeChange = { [weak self] in self?.pushParameters() }
        processes.onChange = { [weak self] in
            guard let self, !self.settings.appRoutes.isEmpty else { return }
            self.apply()
        }
        devices.start()
        processes.start()
        applyTheme()
        apply()
    }

    func shutdown() {
        request += 1
        retryTask?.cancel()
        startupTask?.cancel()
        engine.stopNow()
    }

    func toggle() {
        setOn(!settings.isOn)
    }

    func setOn(_ on: Bool) {
        if on, !settings.isOn {
            powerToken += 1
        }
        update { $0.isOn = on }
        if !on {
            isTesting = false
            engine.setTestClicks(false)
        }
        apply()
    }

    func name(of uid: String) -> String {
        devices.device(uid: uid)?.name ?? settings.outputs[uid]?.name ?? uid
    }

    func outputSettings(_ uid: String) -> OutputSettings {
        settings.outputs[uid] ?? OutputSettings()
    }

    func addOutput(_ uid: String) {
        guard !settings.selected.contains(uid) else { return }
        update { settings in
            settings.selected.append(uid)
            var output = settings.outputs[uid] ?? OutputSettings()
            output.name = name(of: uid)
            settings.outputs[uid] = output
        }
        apply()
    }

    func removeOutput(_ uid: String) {
        update { settings in
            settings.selected.removeAll { $0 == uid }
            for key in settings.appRoutes.keys {
                settings.appRoutes[key]?.removeAll { $0 == uid }
                if settings.appRoutes[key]?.isEmpty == true {
                    settings.appRoutes[key] = nil
                }
            }
        }
        apply()
    }

    func moveOutput(_ uid: String, by offset: Int) {
        guard let index = settings.selected.firstIndex(of: uid) else { return }
        let target = min(max(index + offset, 0), settings.selected.count - 1)
        guard target != index else { return }
        update { $0.selected.swapAt(index, target) }
        apply()
    }

    func setVolume(_ volume: Float, for uid: String) {
        update { $0.outputs[uid, default: OutputSettings()].volume = min(max(volume, 0), 1) }
        pushParameters()
    }

    func setEqualizer(_ gains: [Float], for uid: String) {
        update { $0.outputs[uid, default: OutputSettings()].equalizer = gains.map { min(max($0, -12), 12) } }
        pushParameters()
    }

    func autoDelay(for uid: String) -> Float {
        0
    }

    func delay(for uid: String) -> Float {
        settings.delays[setKey]?[uid] ?? autoDelay(for: uid)
    }

    func isAutoDelay(_ uid: String) -> Bool {
        settings.delays[setKey]?[uid] == nil
    }

    func setDelay(_ milliseconds: Float, for uid: String) {
        let key = setKey
        update { $0.delays[key, default: [:]][uid] = min(max(milliseconds.rounded(), 0), Float(OD_MAX_DELAY_MS)) }
        pushParameters()
    }

    func resetDelays() {
        let key = setKey
        update { $0.delays[key] = nil }
        pushParameters()
    }

    func removeSavedDelays(_ key: String) {
        update { $0.delays[key] = nil }
        pushParameters()
    }

    func routes(for bundleID: String) -> [String]? {
        settings.appRoutes[bundleID]
    }

    func toggleRoute(_ bundleID: String, to uid: String) {
        update { settings in
            var current = settings.appRoutes[bundleID] ?? []
            if current.contains(uid) {
                current.removeAll { $0 == uid }
            } else {
                current.append(uid)
            }
            settings.appRoutes[bundleID] = current.isEmpty ? nil : current
        }
        apply()
    }

    func isUnplugged(_ uid: String) -> Bool {
        settings.unplugged.contains(uid)
    }

    func setPlugged(_ uid: String, _ plugged: Bool) {
        update { settings in
            settings.unplugged.removeAll { $0 == uid }
            if !plugged {
                settings.unplugged.append(uid)
            }
        }
        pushParameters()
    }

    func appVolume(for bundleID: String) -> Float {
        settings.appVolumes[bundleID] ?? 1
    }

    func setAppVolume(_ volume: Float, for bundleID: String) {
        let value = min(max(volume, 0), 1.5)
        update { $0.appVolumes[bundleID] = abs(value - 1) < 0.005 ? nil : value }
        apply()
    }

    func moveRoute(_ bundleID: String, from old: String, to new: String) {
        update { settings in
            var current = settings.appRoutes[bundleID] ?? []
            current.removeAll { $0 == old || $0 == new }
            current.append(new)
            settings.appRoutes[bundleID] = current
        }
        apply()
    }

    func resetRoute(_ bundleID: String) {
        update { $0.appRoutes[bundleID] = nil }
        apply()
    }

    func setTesting(_ testing: Bool) {
        isTesting = testing
        if testing, !settings.isOn {
            setOn(true)
        }
        engine.setTestClicks(testing)
    }

    func setTheme(_ theme: ThemePreference) {
        update { $0.theme = theme }
        applyTheme()
    }

    func finishOnboarding() {
        update { $0.onboardingDone = true }
    }

    func restartOnboarding() {
        update { $0.onboardingDone = false }
    }

    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSSound.beep()
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func applyTheme() {
        switch settings.theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func update(_ change: (inout StoredSettings) -> Void) {
        change(&settings)
        saveTask?.cancel()
        let snapshot = settings
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            snapshot.save()
        }
        onStateChange?()
    }

    private func devicesChanged() {
        for device in devices.devices where settings.selected.contains(device.uid) && settings.outputs[device.uid]?.name != device.name {
            update { $0.outputs[device.uid, default: OutputSettings()].name = device.name }
        }
        apply()
    }

    private func gain(for uid: String) -> Float {
        let volume = outputSettings(uid).volume
        let curve = volume * volume
        let master = uid == devices.defaultDeviceUID ? 1 : devices.masterVolume
        return curve * master
    }

    private func parameters(for plan: RoutingEngine.Plan) -> RoutingEngine.Parameters {
        RoutingEngine.Parameters(
            gains: plan.outputs.map { gain(for: $0.uid) },
            delays: plan.outputs.map { delay(for: $0.uid) },
            equalizers: plan.outputs.map { outputSettings($0.uid).equalizer },
            running: plan.outputs.map { !settings.unplugged.contains($0.uid) },
            sourceGains: plan.sources.map { $0.bundleID.map(appVolume(for:)) ?? 1 }
        )
    }

    private func pushParameters() {
        guard let plan = runningPlan else { return }
        engine.update(parameters(for: plan))
    }

    private func makePlan() -> RoutingEngine.Plan? {
        guard let own = processes.ownProcess else { return nil }
        let outputs = activeOutputs.prefix(Int(OD_MAX_OUTPUTS)).map {
            RoutingEngine.Output(uid: $0.uid, device: $0.id, isWireless: $0.isWireless, sampleRate: $0.sampleRate)
        }
        let indices = Dictionary(uniqueKeysWithValues: outputs.enumerated().map { ($0.element.uid, $0.offset) })
        var excluded = [own]
        var sources = [RoutingEngine.Source(bundleID: nil, processes: [], isGlobal: true, outputs: Array(outputs.indices))]
        let custom = Set(settings.appRoutes.keys).union(settings.appVolumes.keys)
        for bundleID in custom.sorted() where sources.count < Int(OD_MAX_SOURCES) {
            let rule = settings.appRoutes[bundleID]
            let targets = rule.map { $0.compactMap { indices[$0] }.sorted() } ?? Array(outputs.indices)
            let objects = processes.processes(for: bundleID).filter { $0 != own }
            guard !objects.isEmpty, !targets.isEmpty else { continue }
            excluded.append(contentsOf: objects)
            sources.append(RoutingEngine.Source(bundleID: bundleID, processes: objects, isGlobal: false, outputs: targets))
        }
        return RoutingEngine.Plan(outputs: Array(outputs), sources: sources, excluded: excluded.sorted())
    }

    func apply() {
        retryTask?.cancel()
        guard settings.isOn else {
            request += 1
            runningPlan = nil
            engine.stop()
            setStatus(.off)
            return
        }
        guard !activeOutputs.isEmpty else {
            request += 1
            runningPlan = nil
            engine.stop()
            setStatus(.noOutputs)
            return
        }
        guard let plan = makePlan() else {
            request += 1
            startupTask?.cancel()
            startupTask = nil
            runningPlan = nil
            engine.stop()
            setStatus(.starting)
            retryTask?.cancel()
            retryTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self?.apply()
            }
            return
        }
        if plan == runningPlan, status == .running || status == .starting {
            pushParameters()
            return
        }
        startupTask?.cancel()
        runningPlan = plan
        request += 1
        let current = request
        setStatus(.starting)
        engine.run(plan, parameters: parameters(for: plan)) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.request == current else { return }
                if let error {
                    self.runningPlan = nil
                    self.setStatus(.failed(String(describing: error)))
                } else {
                    self.setStatus(.running)
                }
            }
        }
        startupTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, self.request == current, self.status == .starting else { return }
            self.request += 1
            self.runningPlan = nil
            self.engine.stop()
            self.setStatus(.failed("timeout"))
        }
    }

    private func setStatus(_ new: Status) {
        if new != .starting {
            startupTask?.cancel()
            startupTask = nil
        }
        status = new
        if new == .running {
            startMeters()
        } else {
            meterTask?.cancel()
            meterTask = nil
            levels = [:]
        }
        onStateChange?()
    }

    private func startMeters() {
        guard meterTask == nil else { return }
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let plan = self.runningPlan else { return }
                let values = self.engine.levels(outputs: plan.outputs.count)
                var fresh: [String: Float] = [:]
                for (index, output) in plan.outputs.enumerated() {
                    fresh[output.uid] = values[safe: index] ?? 0
                }
                let wasPlaying = self.isPlaying
                self.levels = fresh
                if wasPlaying != self.isPlaying {
                    self.onStateChange?()
                }
                try? await Task.sleep(for: .milliseconds(66))
            }
        }
    }
}
