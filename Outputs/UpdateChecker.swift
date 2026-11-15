import Foundation
import Observation

struct AvailableUpdate: Equatable {
    let version: String
    let pageURL: URL
    let downloadURL: URL?
    var sha256: String?
}

@Observable
final class UpdateChecker {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(AvailableUpdate)
        case failed
    }

    static let interval: Duration = .seconds(24 * 60 * 60)
    private static let lastCheckedKey = "lastUpdateCheck"
    private static let latestReleaseKey = "latestReleaseVersion"
    static let launchDelay: Duration = .seconds(2)
    static let retryInterval: Duration = .seconds(5 * 60)
    nonisolated private static let endpoint = URL(string: "https://api.github.com/repos/theoron-apps/Outputs/releases?per_page=30")!

    let installer = UpdateInstaller()

    private(set) var status: Status = .idle
    private(set) var lastChecked = UserDefaults.standard.object(forKey: UpdateChecker.lastCheckedKey) as? Date
    private(set) var latestRelease = UserDefaults.standard.string(forKey: UpdateChecker.latestReleaseKey)
    private(set) var availableBeta: AvailableUpdate?

    @ObservationIgnored var onUpdateFound: ((AvailableUpdate) -> Void)?
    @ObservationIgnored var onBetaFound: ((AvailableUpdate) -> Void)?
    @ObservationIgnored var isEnabled: () -> Bool = { true }
    @ObservationIgnored private var loopTask: Task<Void, Never>?

    var available: AvailableUpdate? {
        if case .available(let update) = status {
            return update
        }
        return nil
    }

    var isBeta: Bool {
        if Self.betaNumber != nil {
            return true
        }
        guard let latestRelease else { return false }
        return Self.isVersion(Self.currentTag, newerThan: latestRelease)
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static let betaNumber: Int? = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "ODBetaNumber") as? String,
              let number = Int(value), number > 0 else { return nil }
        return number
    }()

    static var currentTag: String {
        betaNumber.map { "\(currentVersion)-beta.\($0)" } ?? currentVersion
    }

    static var currentDisplayVersion: String {
        displayName(of: currentTag)
    }

    static func displayName(of tag: String) -> String {
        let core = core(of: tag)
        guard tag.contains("-") else { return core }
        guard let number = betaNumber(of: tag), number > 0 else {
            return String(localized: "\(core) бета")
        }
        return String(localized: "\(core) бета \(number)")
    }

    func start() {
        guard loopTask == nil else { return }
        installer.cleanUp()
        loopTask = Task { [weak self] in
            try? await Task.sleep(for: Self.launchDelay)
            while !Task.isCancelled {
                if self?.isEnabled() == true {
                    await self?.check(notify: true)
                }
                let wait = self?.status == .failed ? Self.retryInterval : Self.interval
                try? await Task.sleep(for: wait)
            }
        }
    }

    func checkNow() {
        Task { [weak self] in
            await self?.check(notify: false)
        }
    }

    private func check(notify: Bool) async {
        guard status != .checking else { return }
        status = .checking
        guard let releases = await Self.fetchReleases() else {
            status = .failed
            return
        }
        lastChecked = .now
        UserDefaults.standard.set(lastChecked, forKey: Self.lastCheckedKey)
        let stable = Self.newest(releases.filter { !$0.isPrerelease })
        let beta = Self.newest(releases.filter(\.isPrerelease))
        latestRelease = stable?.update.version
        UserDefaults.standard.set(latestRelease, forKey: Self.latestReleaseKey)
        let current = Self.currentTag
        if let beta, Self.isVersion(beta.update.version, newerThan: current),
           stable.map({ Self.isVersion(beta.update.version, newerThan: $0.update.version) }) ?? true {
            availableBeta = beta.update
        } else {
            availableBeta = nil
        }
        guard let stable, Self.isVersion(stable.update.version, newerThan: current) else {
            status = .upToDate
            if notify, let availableBeta {
                onBetaFound?(availableBeta)
            }
            return
        }
        status = .available(stable.update)
        if notify {
            onUpdateFound?(stable.update)
        }
    }

    private static func newest(_ releases: [FetchedRelease]) -> FetchedRelease? {
        releases.max { isVersion($1.update.version, newerThan: $0.update.version) }
    }

    @concurrent
    private static func fetchReleases() async -> [FetchedRelease]? {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Outputs", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let releases = try? JSONDecoder().decode([Release].self, from: data) else {
            return nil
        }
        return releases.compactMap { release in
            guard !release.draft, let page = URL(string: release.htmlURL) else { return nil }
            let version = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            let dmg = release.assets.first { $0.name.lowercased().hasSuffix(".dmg") }
            let sha256 = dmg?.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
            let update = AvailableUpdate(version: version, pageURL: page, downloadURL: dmg.flatMap { URL(string: $0.downloadURL) }, sha256: sha256)
            return FetchedRelease(update: update, isPrerelease: release.prerelease)
        }
    }

    nonisolated static func core(of version: String) -> String {
        String(version.split(separator: "-").first ?? "")
    }

    nonisolated static func betaNumber(of tag: String) -> Int? {
        guard let suffix = tag.split(separator: "-", maxSplits: 1).dropFirst().first else { return nil }
        return Int(suffix.filter(\.isNumber)) ?? 0
    }

    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let lhs = core(of: candidate).split(separator: ".").map { Int($0) ?? 0 } + [betaNumber(of: candidate) ?? .max]
        let rhs = core(of: current).split(separator: ".").map { Int($0) ?? 0 } + [betaNumber(of: current) ?? .max]
        let width = max(lhs.count, rhs.count)
        let left = Array(lhs.dropLast()) + Array(repeating: 0, count: width - lhs.count) + [lhs.last ?? .max]
        let right = Array(rhs.dropLast()) + Array(repeating: 0, count: width - rhs.count) + [rhs.last ?? .max]
        for (a, b) in zip(left, right) where a != b {
            return a > b
        }
        return false
    }

    private nonisolated struct FetchedRelease {
        let update: AvailableUpdate
        let isPrerelease: Bool
    }

    private nonisolated struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let downloadURL: String
            let digest: String?

            enum CodingKeys: String, CodingKey {
                case name
                case downloadURL = "browser_download_url"
                case digest
            }
        }

        let tagName: String
        let htmlURL: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft
            case prerelease
            case assets
        }
    }
}
