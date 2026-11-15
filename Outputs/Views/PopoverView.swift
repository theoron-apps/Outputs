import SwiftUI

struct PopoverView: View {
    let model: AppModel
    let router: WindowRouter

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.settings.selected.isEmpty {
                emptyState
            } else {
                PatchBay(source: "MAC", nodes: nodes) { model.setPlugged($0, $1) }
                    .saturation(model.isOn ? 1 : 0.35)
                cards
            }
            addMenu
            HStack(spacing: 6) {
                Button("ТЕСТ") { router.openTest() }
                    .buttonStyle(TactileButtonStyle(kind: .filled, fullWidth: true))
                Button("ПРИЛОЖЕНИЯ") { router.openSettings(.apps) }
                    .buttonStyle(TactileButtonStyle(fullWidth: true))
                Button("ЭКВАЛАЙЗЕР") { router.openSettings(.equalizer) }
                    .buttonStyle(TactileButtonStyle(fullWidth: true))
            }
            footer
        }
        .padding(16)
        .frame(width: 380)
        .background(WindowBackground())
        .foregroundStyle(Theme.ink)
        .environment(\.powerToken, model.powerToken)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 9) {
            PowerLED(isOn: model.isOn && model.status == .running)
            VStack(alignment: .leading, spacing: 3) {
                Text("OUTPUTS")
                    .font(Theme.mono(14, .bold))
                Text(statusText)
                    .font(Theme.mono(8))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            PowerSwitch(isOn: model.isOn) { model.toggle() }
        }
    }

    private var statusText: String {
        switch model.status {
        case .off: String(localized: "ВЫКЛЮЧЕНО")
        case .starting: String(localized: "ПОДКЛЮЧАЮ…")
        case .noOutputs: String(localized: "НЕТ ПОДКЛЮЧЁННЫХ ВЫХОДОВ")
        case .failed: String(localized: "НЕ УДАЛОСЬ ЗАПУСТИТЬ ЗВУК")
        case .running:
            if !model.missingOutputs.isEmpty {
                String(localized: "ВЫХОД ОТКЛЮЧИЛСЯ: \(model.missingOutputs.map(model.name(of:)).joined(separator: ", ").uppercased())")
            } else {
                String(localized: "ИГРАЕТ В \(model.activeOutputs.count) ВЫХ.")
            }
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .failed: Theme.accent
        case .running where !model.missingOutputs.isEmpty: Theme.accent
        default: Theme.muted
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

    private var cards: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(Array(model.activeOutputs.enumerated()), id: \.element.uid) { index, device in
                OutputCard(model: model, device: device, index: index)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ДОБАВЬТЕ ВЫХОДЫ")
                .font(Theme.mono(11, .medium))
            Text("Выберите наушники и колонки, в которые Mac будет играть одновременно.")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(screws: true)
    }

    private var addMenu: some View {
        Menu {
            if model.availableOutputs.isEmpty {
                Text("Все выходы уже добавлены")
            }
            ForEach(model.availableOutputs) { device in
                Button {
                    model.addOutput(device.uid)
                } label: {
                    Label(device.name, systemImage: device.symbolName)
                }
            }
        } label: {
            Text("+ ДОБАВИТЬ ВЫХОД")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .recessed(radius: 8)
                .overlay {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.muted.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private var footer: some View {
        HStack {
            Button("НАСТРОЙКИ") { router.openSettings(.outputs) }
            Spacer()
            if model.updates.available != nil {
                Button("ОБНОВЛЕНИЕ") { router.openSettings(.general) }
                    .foregroundStyle(Theme.accent)
            }
            Button("ВЫЙТИ") { NSApp.terminate(nil) }
        }
        .buttonStyle(.plain)
        .font(Theme.mono(9))
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 2)
    }
}

struct OutputCard: View {
    let model: AppModel
    let device: AudioOutputDevice
    let index: Int

    var body: some View {
        let settings = model.outputSettings(device.uid)
        let delay = model.delay(for: device.uid)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.cableColor(index))
                    .frame(width: 7, height: 7)
                    .shadow(color: Theme.cableColor(index).opacity(0.8), radius: 2.5)
                Text(device.name.uppercased())
                    .font(Theme.mono(9))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.trailing, 10)
            LevelBar(level: model.levels[device.uid] ?? 0)
            HStack(spacing: 0) {
                control(title: "VOL", text: "\(Int(settings.volume * 100))") {
                    Knob(value: Double(settings.volume * 100), range: 0...100) {
                        model.setVolume(Float($0) / 100, for: device.uid)
                    }
                }
                control(title: model.isAutoDelay(device.uid) ? "DLY·A" : "DLY", text: "\(Int(delay))") {
                    Knob(value: Double(delay), range: 0...1000, sensitivity: 260) {
                        model.setDelay(Float($0), for: device.uid)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(screws: true)
        .saturation(model.isUnplugged(device.uid) ? 0 : 1)
        .opacity(model.isUnplugged(device.uid) ? 0.55 : 1)
        .animation(.easeOut(duration: 0.4), value: model.isUnplugged(device.uid))
        .contextMenu {
            Button("Убрать выход") { model.removeOutput(device.uid) }
        }
    }

    private func control<K: View>(title: String, text: String, @ViewBuilder knob: () -> K) -> some View {
        VStack(spacing: 2) {
            knob()
            HStack(spacing: 5) {
                Text(title).foregroundStyle(Theme.muted)
                Text(text).foregroundStyle(Theme.ink).contentTransition(.numericText())
            }
            .font(Theme.mono(9))
        }
        .frame(maxWidth: .infinity)
    }
}
