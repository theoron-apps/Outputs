import SwiftUI

struct EqualizerTab: View {
    let model: AppModel

    @State private var selected: String?

    private static let bands = ["60", "250", "1K", "4K", "12K"]

    private var current: String? {
        if let selected, model.settings.selected.contains(selected) {
            return selected
        }
        return model.settings.selected.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(String(localized: "ЭКВАЛАЙЗЕР"), detail: String(localized: "Свой у каждого выхода. Тяните ползунок вверх или вниз, двойной щелчок — сброс полосы."))
            if let uid = current {
                chips(selected: uid)
                sliders(uid: uid)
                presets(uid: uid)
            } else {
                Text("Сначала добавьте выходы на вкладке «Выходы».")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    private func chips(selected uid: String) -> some View {
        HStack(spacing: 6) {
            ForEach(model.settings.selected, id: \.self) { item in
                Button(model.name(of: item).uppercased()) { selected = item }
                    .buttonStyle(TactileButtonStyle(kind: item == uid ? .filled : .plain))
                    .lineLimit(1)
            }
        }
    }

    private func sliders(uid: String) -> some View {
        let gains = model.outputSettings(uid).equalizer
        return HStack(alignment: .bottom, spacing: 22) {
            ForEach(Array(Self.bands.enumerated()), id: \.offset) { index, band in
                VStack(spacing: 6) {
                    Text(String(format: "%+.0f", gains[safe: index] ?? 0))
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.muted)
                    BandSlider(value: gains[safe: index] ?? 0, highlighted: index == 0) { value in
                        var updated = model.outputSettings(uid).equalizer
                        updated += Array(repeating: 0, count: max(Self.bands.count - updated.count, 0))
                        updated[index] = value
                        model.setEqualizer(updated, for: uid)
                    }
                    Text(band).font(Theme.mono(10))
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .panel(screws: true)
    }

    private func presets(uid: String) -> some View {
        let gains = model.outputSettings(uid).equalizer
        return HStack(spacing: 6) {
            Text("ПРЕСЕТЫ").font(Theme.mono(10)).foregroundStyle(Theme.muted)
            ForEach(EqualizerPreset.allCases, id: \.self) { preset in
                Button(preset.title) { model.setEqualizer(preset.gains, for: uid) }
                    .buttonStyle(TactileButtonStyle(kind: preset.gains == gains ? .accent : .plain))
            }
        }
    }
}

struct BandSlider: View {
    let value: Float
    var highlighted = false
    let onChange: (Float) -> Void

    private let height: CGFloat = 190

    var body: some View {
        let fraction = CGFloat((value + 12) / 24)
        ZStack(alignment: .top) {
            VStack(spacing: (height - 14) / 12 - 1) {
                ForEach(0..<13, id: \.self) { index in
                    Rectangle()
                        .fill(index == 6 ? Theme.muted : Theme.line)
                        .frame(width: index % 3 == 0 ? 26 : 16, height: 1)
                }
            }
            .padding(.top, 7)
            Capsule()
                .fill(Color.black.opacity(0.85))
                .overlay(Capsule().strokeBorder(LinearGradient(colors: [Color.black, Theme.edgeLight], startPoint: .top, endPoint: .bottom), lineWidth: 1))
                .frame(width: 6, height: height)
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: [Color(white: 0.9), Color(white: 0.55), Color(white: 0.82)], startPoint: .top, endPoint: .bottom))
                VStack(spacing: 2) {
                    ForEach(0..<2, id: \.self) { _ in Rectangle().fill(Color.black.opacity(0.18)).frame(height: 1) }
                }
                .padding(.horizontal, 5)
                .offset(y: -4)
                Rectangle()
                    .fill(value == 0 ? Theme.onAccent : Theme.accent)
                    .frame(height: 2)
                    .shadow(color: value == 0 ? .clear : Theme.accent, radius: 2)
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.black.opacity(0.35), lineWidth: 0.6)
            }
            .frame(width: 30, height: 18)
            .shadow(color: .black.opacity(0.5), radius: 2, y: 2)
            .offset(y: (1 - fraction) * (height - 18))
            .animation(.snappy(duration: 0.12), value: value)
        }
        .frame(width: 36, height: height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    let position = 1 - min(max((gesture.location.y - 9) / (height - 18), 0), 1)
                    onChange(Float((position * 24 - 12).rounded()))
                }
        )
        .onTapGesture(count: 2) { onChange(0) }
        .accessibilityElement()
        .accessibilityValue(Text("\(Int(value)) dB"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(value + 1, 12))
            case .decrement: onChange(max(value - 1, -12))
            @unknown default: break
            }
        }
    }
}
