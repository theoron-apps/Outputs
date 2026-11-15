import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @Bindable var router: WindowRouter

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.line).frame(width: 0.5)
            ScrollView {
                content
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.never)
        }
        .padding(.top, 28)
        .background(WindowBackground())
        .foregroundStyle(Theme.ink)
        .ignoresSafeArea()
        .environment(\.powerToken, model.powerToken)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                PowerLED(isOn: model.isOn)
                Text("OUTPUTS").font(Theme.mono(12, .medium))
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
            ForEach(Array(SettingsTab.allCases.enumerated()), id: \.element) { index, tab in
                Button {
                    router.settingsTab = tab
                } label: {
                    Text(String(format: "%02d ", index + 1) + tab.title)
                        .font(Theme.mono(11))
                        .foregroundStyle(router.settingsTab == tab ? Theme.inverse : Theme.ink)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(router.settingsTab == tab ? Theme.ink : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            PowerSwitch(isOn: model.isOn) { model.toggle() }
                .padding(.horizontal, 8)
        }
        .padding(12)
        .frame(width: 210)
    }

    @ViewBuilder
    private var content: some View {
        switch router.settingsTab {
        case .outputs: OutputsTab(model: model)
        case .apps: AppsTab(model: model)
        case .equalizer: EqualizerTab(model: model)
        case .sync: SyncTab(model: model, router: router)
        case .general: GeneralTab(model: model, router: router)
        case .whatsNew: WhatsNewTab()
        }
    }
}

struct SectionTitle: View {
    let text: String
    var detail: String?

    init(_ text: String, detail: String? = nil) {
        self.text = text
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text).font(Theme.mono(12, .medium))
            if let detail {
                Text(detail)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct OutputsTab: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(String(localized: "КУДА ИГРАЕТ MAC"), detail: String(localized: "Звук идёт во все выходы сразу. Порядок задаёт цвет кабеля, первый проводной выход ведёт часы."))
            if !model.settings.selected.isEmpty {
                PatchBay(source: "MAC", nodes: nodes, rowHeight: 46) { model.setPlugged($0, $1) }
                    .opacity(model.isOn ? 1 : 0.55)
            }
            VStack(spacing: 8) {
                ForEach(Array(model.settings.selected.enumerated()), id: \.element) { index, uid in
                    row(uid: uid, index: index)
                }
            }
            if !model.availableOutputs.isEmpty {
                SectionTitle(String(localized: "ДОСТУПНЫЕ ВЫХОДЫ"))
                VStack(spacing: 6) {
                    ForEach(model.availableOutputs) { device in
                        HStack {
                            Image(systemName: device.symbolName).frame(width: 18)
                            Text(device.name.uppercased()).font(Theme.mono(11)).lineLimit(1)
                            Text(device.shortKind).font(Theme.mono(9)).foregroundStyle(Theme.muted)
                            Spacer()
                            Button("+ ДОБАВИТЬ") { model.addOutput(device.uid) }
                                .buttonStyle(.tactile)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .panel()
                    }
                }
            }
        }
    }

    private var nodes: [CableNode] {
        model.settings.selected.enumerated().map { index, uid in
            let device = model.devices.device(uid: uid)
            return CableNode(
                id: uid,
                title: model.name(of: uid),
                subtitle: device == nil ? String(localized: "НЕ ПОДКЛЮЧЕНО") : (model.isUnplugged(uid) ? String(localized: "ВЫДЕРНУТ · ВСТАВЬТЕ ШТЕКЕР") : device?.shortKind ?? ""),
                missing: device == nil,
                unplugged: model.isUnplugged(uid),
                level: model.levels[uid] ?? 0
            )
        }
    }

    private func row(uid: String, index: Int) -> some View {
        let device = model.devices.device(uid: uid)
        let settings = model.outputSettings(uid)
        return HStack(spacing: 12) {
            Circle().fill(device == nil ? Theme.line : Theme.cableColor(index)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name(of: uid).uppercased()).font(Theme.mono(11)).lineLimit(1)
                Text(device.map { "\($0.shortKind) · \(Int($0.sampleRate / 1000)) KHZ · \(Int($0.latency)) MS" } ?? String(localized: "НЕ ПОДКЛЮЧЕНО · ВЕРНЁТСЯ САМ"))
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.muted)
            }
            .frame(width: 250, alignment: .leading)
            Knob(value: Double(settings.volume * 100), range: 0...100, size: 38) {
                model.setVolume(Float($0) / 100, for: uid)
            }
            Text("\(Int(settings.volume * 100))").font(Theme.mono(13)).frame(width: 34, alignment: .leading)
            LevelBar(level: model.levels[uid] ?? 0, segments: 10)
            HStack(spacing: 4) {
                Button { model.moveOutput(uid, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                Button { model.moveOutput(uid, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == model.settings.selected.count - 1)
                Button { model.removeOutput(uid) } label: { Image(systemName: "xmark") }
            }
            .buttonStyle(.tactile)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .panel()
    }
}
