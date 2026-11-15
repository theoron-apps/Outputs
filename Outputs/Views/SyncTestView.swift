import SwiftUI

struct SyncTestView: View {
    let model: AppModel
    let router: WindowRouter

    @State private var selected: String?
    @State private var startedAt = Date()

    private var current: AudioOutputDevice? {
        model.activeOutputs.first { $0.uid == selected } ?? model.activeOutputs.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("ТЕСТ СИНХРОНИЗАЦИИ").font(Theme.mono(13, .medium))
                Text("Наденьте наушники и слушайте щелчки. Выберите выход и крутите ручку, пока щелчки не сольются в один.")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.activeOutputs.count < 2 {
                Text("Для теста нужны хотя бы два подключённых выхода.")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.accent)
            }
            lanes
                .padding(8)
                .recessed(radius: 10)
            if let device = current {
                controls(device)
                    .padding(.vertical, 14)
                    .panel(radius: 12, screws: true)
            }
            Spacer(minLength: 0)
            HStack {
                Button("ВЕРНУТЬ АВТО") { model.resetDelays() }
                    .buttonStyle(.tactile)
                Spacer()
                Button("ГОТОВО") { router.closeTest() }
                    .buttonStyle(.tactileFilled)
            }
        }
        .padding(20)
        .padding(.top, 14)
        .frame(width: 560, height: 520, alignment: .topLeading)
        .background(WindowBackground())
        .foregroundStyle(Theme.ink)
        .onAppear {
            startedAt = Date()
            model.setTesting(true)
        }
        .onDisappear { model.setTesting(false) }
    }

    private var lanes: some View {
        let outputs = model.activeOutputs
        let span = max(outputs.map { Double(model.delay(for: $0.uid)) }.max() ?? 0, 250) * 1.15
        return TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let phase = timeline.date.timeIntervalSince(startedAt).truncatingRemainder(dividingBy: 1) * 1000
            VStack(spacing: 8) {
                ForEach(Array(outputs.enumerated()), id: \.element.uid) { index, device in
                    let arrival = Double(model.delay(for: device.uid))
                    let lit = phase >= arrival && phase < arrival + 90
                    Button {
                        selected = device.uid
                    } label: {
                        HStack(spacing: 8) {
                            Text(device.name.uppercased())
                                .font(Theme.mono(10))
                                .lineLimit(1)
                                .frame(width: 150, alignment: .leading)
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.black.opacity(0.6)).frame(height: 3)
                                    Circle()
                                        .fill(Theme.cableColor(index))
                                        .frame(width: 14, height: 14)
                                        .opacity(lit ? 1 : 0.25)
                                        .shadow(color: lit ? Theme.cableColor(index) : .clear, radius: 5)
                                        .offset(x: CGFloat(arrival / span) * (geometry.size.width - 14))
                                }
                                .frame(maxHeight: .infinity)
                            }
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 42)
                        .background {
                            if device.uid == current?.uid {
                                Color.clear.panel(radius: 7)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func controls(_ device: AudioOutputDevice) -> some View {
        let delay = model.delay(for: device.uid)
        return HStack(spacing: 18) {
            Knob(value: Double(delay), range: 0...Double(OD_MAX_DELAY_MS), size: 76, sensitivity: 900) {
                model.setDelay(Float($0), for: device.uid)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name.uppercased()).font(Theme.mono(9)).foregroundStyle(Theme.muted).lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(Int(delay))").font(Theme.mono(28)).contentTransition(.numericText())
                    Text("MS").font(Theme.mono(11))
                }
                Text("\(String(localized: "АВТО")): \(Int(model.autoDelay(for: device.uid)))")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.muted)
                HStack(spacing: 4) {
                    ForEach([-10, -1, 1, 10], id: \.self) { step in
                        Button(step > 0 ? "+\(step)" : "\(step)") { model.setDelay(delay + Float(step), for: device.uid) }
                            .buttonStyle(.tactile)
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
