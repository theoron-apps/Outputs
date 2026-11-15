import Foundation

nonisolated enum ThemePreference: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark
}

nonisolated enum EqualizerPreset: String, CaseIterable, Sendable {
    case flat
    case bass
    case voice
    case bright

    var gains: [Float] {
        switch self {
        case .flat: [0, 0, 0, 0, 0]
        case .bass: [6, 3, 0, 0, 0]
        case .voice: [-3, -1, 3, 3, -1]
        case .bright: [0, 0, 0, 3, 6]
        }
    }

    var title: String {
        switch self {
        case .flat: String(localized: "РОВНО")
        case .bass: String(localized: "БАС+")
        case .voice: String(localized: "ГОЛОС")
        case .bright: String(localized: "ЯРКО")
        }
    }
}

nonisolated struct OutputSettings: Codable, Hashable, Sendable {
    var volume: Float = 0.8
    var equalizer: [Float] = [0, 0, 0, 0, 0]
    var name: String = ""
}

nonisolated struct StoredSettings: Codable, Sendable {
    var isOn = false
    var selected: [String] = []
    var outputs: [String: OutputSettings] = [:]
    var delays: [String: [String: Float]] = [:]
    var appRoutes: [String: [String]] = [:]
    var theme: ThemePreference = .system
    var onboardingDone = false
    var unplugged: [String] = []
    var appVolumes: [String: Float] = [:]

    private static let key = "settings.v1"

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isOn = try container.decodeIfPresent(Bool.self, forKey: .isOn) ?? false
        selected = try container.decodeIfPresent([String].self, forKey: .selected) ?? []
        outputs = try container.decodeIfPresent([String: OutputSettings].self, forKey: .outputs) ?? [:]
        delays = try container.decodeIfPresent([String: [String: Float]].self, forKey: .delays) ?? [:]
        appRoutes = try container.decodeIfPresent([String: [String]].self, forKey: .appRoutes) ?? [:]
        theme = try container.decodeIfPresent(ThemePreference.self, forKey: .theme) ?? .system
        onboardingDone = try container.decodeIfPresent(Bool.self, forKey: .onboardingDone) ?? false
        unplugged = try container.decodeIfPresent([String].self, forKey: .unplugged) ?? []
        appVolumes = try container.decodeIfPresent([String: Float].self, forKey: .appVolumes) ?? [:]
    }

    static func load() -> StoredSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(StoredSettings.self, from: data) else {
            return StoredSettings()
        }
        return settings
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
