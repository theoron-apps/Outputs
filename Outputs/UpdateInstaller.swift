import AppKit
import Observation

@Observable
final class UpdateInstaller {
    enum State: Equatable {
        case idle
        case downloading(Double)
        case failed(String)

        var isBusy: Bool {
            if case .downloading = self {
                return true
            }
            return false
        }
    }

    private static let pendingKey = "pendingUpdateInstall"
    private static let cleanupDelay: Duration = .seconds(8)
    private static let quitDelay: Duration = .seconds(1.5)

    private(set) var state: State = .idle

    @ObservationIgnored private var task: Task<Void, Never>?

    func install(_ update: AvailableUpdate) {
        guard !state.isBusy else { return }
        guard let source = update.downloadURL, let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            NSWorkspace.shared.open(update.downloadURL ?? update.pageURL)
            return
        }
        let destination = folder.appendingPathComponent(Self.fileName(of: source, version: update.version))
        state = .downloading(0)
        task = Task { [weak self] in
            do {
                let temporaryFolder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
                defer { try? FileManager.default.removeItem(at: temporaryFolder) }
                let temporary = temporaryFolder.appendingPathComponent(destination.lastPathComponent)
                let digest = try await UpdateDownload(destination: temporary) { fraction in
                    Task { @MainActor in
                        self?.state = .downloading(fraction)
                    }
                }
                .run(source)
                guard let self, !Task.isCancelled else { return }
                if let expected = update.sha256, expected.lowercased() != digest {
                    self.state = .failed(String(localized: "Контрольная сумма файла не совпала, установка отменена"))
                    return
                }
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                }
                self.state = .idle
                self.finish(update: update, file: destination)
            } catch {
                self?.state = .failed(String(localized: "Не удалось скачать обновление"))
            }
        }
    }

    func cleanUp() {
        guard let pending = UserDefaults.standard.dictionary(forKey: Self.pendingKey),
              let version = pending["version"] as? String, let path = pending["path"] as? String,
              !UpdateChecker.isVersion(version, newerThan: UpdateChecker.currentVersion) else { return }
        Task {
            try? await Task.sleep(for: Self.cleanupDelay)
            Self.ejectMountedImages()
            try? FileManager.default.removeItem(atPath: path)
            UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        }
    }

    private func finish(update: AvailableUpdate, file: URL) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Обновление \(update.version) скачано и проверено")
        alert.informativeText = String(localized: "Outputs закроется и откроет образ диска. Перетащите Outputs в папку «Программы» и выберите «Заменить»: ваши настройки сохранятся.")
        alert.addButton(withTitle: String(localized: "Продолжить"))
        alert.addButton(withTitle: String(localized: "Позже"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        UserDefaults.standard.set(["version": update.version, "path": file.path], forKey: Self.pendingKey)
        NSWorkspace.shared.open(file)
        Task {
            try? await Task.sleep(for: Self.quitDelay)
            NSApp.terminate(nil)
        }
    }

    private static func fileName(of url: URL, version: String) -> String {
        let name = url.lastPathComponent
        let allowed = name.lowercased().hasSuffix(".dmg") && !name.contains("/") && !name.hasPrefix(".")
        return allowed ? name : "Outputs-\(version).dmg"
    }

    private static func ejectMountedImages() {
        let own = Bundle.main.bundleURL.path
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey], options: [.skipHiddenVolumes]) ?? []
        for volume in volumes where volume.path.hasPrefix("/Volumes/Outputs") && !own.hasPrefix(volume.path) {
            try? NSWorkspace.shared.unmountAndEjectDevice(at: volume)
        }
    }
}
