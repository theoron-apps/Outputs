import SwiftUI

struct SyncTab: View {
    let model: AppModel
    let router: WindowRouter

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(
                String(localized: "СИНХРОНИЗАЦИЯ"),
                detail: String(localized: "Bluetooth и AirPlay звучат позже проводных. Outputs задерживает быстрые выходы, чтобы все играли вместе. Задержка запоминается для каждого набора устройств.")
            )
            if model.activeOutputs.isEmpty {
                Text("Подключите хотя бы один выход.")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.muted)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(model.activeOutputs.enumerated()), id: \.element.uid) { index, device in
                        DelayRow(model: model, device: device, index: index)
                    }
                }
                HStack(spacing: 8) {
                    Button("ЗАПУСТИТЬ ТЕСТ ЩЕЛЧКАМИ") { router.openTest() }
                        .buttonStyle(.tactileAccent)
                    Button("ВЕРНУТЬ АВТО") { model.resetDelays() }
                        .buttonStyle(.tactile)
                }
            }
            if !savedSets.isEmpty {
                SectionTitle(String(localized: "СОХРАНЁННЫЕ НАБОРЫ"))
                VStack(spacing: 6) {
                    ForEach(savedSets, id: \.self) { key in
                        HStack {
                            Text(title(of: key)).font(Theme.mono(10)).lineLimit(2)
                            Spacer()
                            Button("УДАЛИТЬ") { model.removeSavedDelays(key) }
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

    private var savedSets: [String] {
        model.settings.delays.keys.sorted()
    }

    private func title(of key: String) -> String {
        let delays = model.settings.delays[key] ?? [:]
        return key.split(separator: "|").map { uid in
            let name = model.name(of: String(uid)).uppercased()
            return delays[String(uid)].map { "\(name) \(Int($0)) MS" } ?? name
        }.joined(separator: " + ")
    }
}

struct DelayRow: View {
    let model: AppModel
    let device: AudioOutputDevice
    let index: Int

    var body: some View {
        let delay = model.delay(for: device.uid)
        HStack(spacing: 10) {
            Circle().fill(Theme.cableColor(index)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name.uppercased()).font(Theme.mono(11)).lineLimit(1)
                Text("\(device.shortKind) · \(String(localized: "СВОЯ ЗАДЕРЖКА")) \(Int(device.latency)) MS · \(String(localized: "АВТО")) \(Int(model.autoDelay(for: device.uid)))")
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            Stepper(delay: delay) { model.setDelay($0, for: device.uid) }
            Text("\(Int(delay))")
                .font(Theme.mono(15))
                .frame(width: 52, alignment: .trailing)
            Text(model.isAutoDelay(device.uid) ? "MS·A" : "MS")
                .font(Theme.mono(9))
                .foregroundStyle(Theme.muted)
                .frame(width: 30, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .panel()
    }

    private struct Stepper: View {
        let delay: Float
        let onChange: (Float) -> Void

        var body: some View {
            HStack(spacing: 4) {
                ForEach([-10, -1, 1, 10], id: \.self) { step in
                    Button(step > 0 ? "+\(step)" : "\(step)") { onChange(delay + Float(step)) }
                        .buttonStyle(.tactile)
                }
            }
        }
    }
}
