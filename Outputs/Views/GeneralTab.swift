import SwiftUI

struct GeneralTab: View {
    let model: AppModel
    let router: WindowRouter

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionTitle(String(localized: "ОСНОВНЫЕ"))
            group {
                row(String(localized: "ТЕМА")) {
                    HStack(spacing: 6) {
                        ForEach(ThemePreference.allCases, id: \.self) { theme in
                            Button(title(of: theme)) { model.setTheme(theme) }
                                .buttonStyle(TactileButtonStyle(kind: model.settings.theme == theme ? .filled : .plain))
                        }
                    }
                }
                row(String(localized: "ЗАПУСК ПРИ ВХОДЕ")) {
                    PowerSwitch(isOn: model.launchesAtLogin) { model.setLaunchesAtLogin(!model.launchesAtLogin) }
                }
                row(String(localized: "ЯЗЫК")) {
                    Button("КАК В СИСТЕМЕ ↗") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!)
                    }
                    .buttonStyle(.tactile)
                }
                row(String(localized: "ГАЙД ПЕРВОГО ЗАПУСКА")) {
                    Button("ПОКАЗАТЬ СНОВА") { router.openOnboarding() }
                        .buttonStyle(.tactile)
                }
            }
            SectionTitle(String(localized: "ОБНОВЛЕНИЯ"), detail: String(localized: "Outputs раз в день проверяет новые версии на GitHub."))
            group {
                row(String(localized: "ВЕРСИЯ")) {
                    Text(UpdateChecker.currentDisplayVersion.uppercased()).font(Theme.mono(11))
                }
                row(updateStatus) {
                    if let update = model.updates.available {
                        Button(installTitle(update)) { model.updates.installer.install(update) }
                            .buttonStyle(.tactileAccent)
                            .disabled(model.updates.installer.state.isBusy)
                    } else {
                        Button("ПРОВЕРИТЬ") { model.updates.checkNow() }
                            .buttonStyle(.tactile)
                    }
                }
            }
            Button("ВЫЙТИ ИЗ OUTPUTS") { NSApp.terminate(nil) }
                .buttonStyle(.tactile)
        }
    }

    private var updateStatus: String {
        switch model.updates.status {
        case .idle: String(localized: "ЕЩЁ НЕ ПРОВЕРЯЛ")
        case .checking: String(localized: "ПРОВЕРЯЮ…")
        case .upToDate: String(localized: "ПОСЛЕДНЯЯ ВЕРСИЯ")
        case .available(let update): String(localized: "ДОСТУПНА \(update.version)")
        case .failed: String(localized: "НЕ УДАЛОСЬ ПРОВЕРИТЬ")
        }
    }

    private func installTitle(_ update: AvailableUpdate) -> String {
        if case .downloading(let fraction) = model.updates.installer.state {
            return String(localized: "СКАЧИВАЮ \(Int(fraction * 100))%")
        }
        return String(localized: "УСТАНОВИТЬ \(update.version)")
    }

    private func title(of theme: ThemePreference) -> String {
        switch theme {
        case .system: String(localized: "КАК В СИСТЕМЕ")
        case .light: String(localized: "СВЕТЛАЯ")
        case .dark: String(localized: "ТЁМНАЯ")
        }
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .panel()
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Text(title).font(Theme.mono(11))
            Spacer()
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 0.5).opacity(0.6)
        }
    }
}

struct WhatsNewTab: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(String(localized: "ЧТО НОВОГО"))
            ForEach(ChangelogRelease.all) { release in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("OUTPUTS \(release.version)").font(Theme.mono(12, .medium))
                        if release.version == UpdateChecker.currentVersion {
                            Text("УСТАНОВЛЕНА")
                                .font(Theme.mono(9))
                                .foregroundStyle(Theme.onAccent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.accent, in: Capsule())
                        }
                    }
                    list(String(localized: "ДОБАВЛЕНО"), release.added)
                    list(String(localized: "ИЗМЕНЕНО"), release.changed)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panel()
            }
        }
    }

    @ViewBuilder
    private func list(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(Theme.mono(9)).foregroundStyle(Theme.muted)
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(Theme.accent).frame(width: 4, height: 4)
                        Text(item).font(Theme.mono(11)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
