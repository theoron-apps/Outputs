import SwiftUI

struct OnboardingView: View {
    let model: AppModel
    let router: WindowRouter

    @State private var step = 0

    private let count = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(String(format: "%02d / %02d", step + 1, count))
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.accent)
                Spacer()
                HStack(spacing: 4) {
                    ForEach(0..<count, id: \.self) { index in
                        Capsule()
                            .fill(index <= step ? Theme.accent : Theme.track)
                            .frame(width: index == step ? 18 : 8, height: 4)
                    }
                }
                .animation(.snappy, value: step)
            }
            Group {
                switch step {
                case 0: intro
                case 1: access
                case 2: volume
                case 3: outputs
                default: sync
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            .id(step)
            HStack {
                if step > 0 {
                    Button("НАЗАД") { withAnimation(.snappy) { step -= 1 } }
                        .buttonStyle(.tactile)
                }
                Spacer()
                if step < count - 1 {
                    Button("ДАЛЕЕ") { withAnimation(.snappy) { step += 1 } }
                        .buttonStyle(.tactileFilled)
                } else {
                    Button("ГОТОВО") { finish() }
                        .buttonStyle(.tactileAccent)
                }
            }
        }
        .padding(24)
        .padding(.top, 10)
        .frame(width: 620, height: 560)
        .background(WindowBackground())
        .foregroundStyle(Theme.ink)
    }

    private func title(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.mono(16, .medium))
            Text(text)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 22) {
            PatchBay(
                source: "MAC",
                nodes: [
                    CableNode(id: "a", title: "AirPods", subtitle: "BT", level: 0.5),
                    CableNode(id: "b", title: String(localized: "Проводные"), subtitle: "JACK", level: 0.5)
                ],
                rowHeight: 48
            )
            title(
                String(localized: "Один звук — много выходов"),
                String(localized: "Outputs играет звук Mac сразу в несколько наушников и колонок: Bluetooth, проводные, AirPlay, HDMI. У каждого своя громкость, задержка и эквалайзер.")
            )
        }
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsCard(
                path: String(localized: "КОНФИДЕНЦИАЛЬНОСТЬ → ЗАПИСЬ ЗВУКА"),
                item: String(localized: "OUTPUTS · ТОЛЬКО СИСТЕМНЫЙ ЗВУК")
            )
            title(
                String(localized: "Доступ к звуку"),
                String(localized: "Чтобы раздать звук по выходам, Outputs должен его забрать. Когда вы впервые включите Outputs, macOS спросит разрешение — нажмите «Разрешить». Звук никуда не записывается.")
            )
            HStack(spacing: 8) {
                Button("ОТКРЫТЬ НАСТРОЙКИ ↗") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                }
                .buttonStyle(.tactile)
            }
        }
    }

    private var volume: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                ForEach(["speaker.wave.1", "speaker.wave.3"], id: \.self) { symbol in
                    Image(systemName: symbol)
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.inverse)
                        .frame(width: 54, height: 54)
                        .panel(filled: true)
                }
                Image(systemName: "arrow.right").foregroundStyle(Theme.muted)
                Knob(value: 70, range: 0...100, size: 54) { _ in }
                Knob(value: 45, range: 0...100, size: 54) { _ in }
            }
            title(
                String(localized: "Клавиши громкости"),
                String(localized: "Клавиши громкости Mac управляют всеми выходами сразу и сохраняют разницу между ними. Громкость отдельного выхода — ручка VOL в панели.")
            )
        }
    }

    private var outputs: some View {
        VStack(alignment: .leading, spacing: 14) {
            title(
                String(localized: "Выберите выходы"),
                String(localized: "Отметьте устройства, в которые будет играть Mac. Добавить другие можно позже, в панели в меню-баре.")
            )
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(model.devices.devices) { device in
                        let selected = model.settings.selected.contains(device.uid)
                        Button {
                            selected ? model.removeOutput(device.uid) : model.addOutput(device.uid)
                        } label: {
                            HStack {
                                Image(systemName: selected ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(selected ? Theme.accent : Theme.muted)
                                Image(systemName: device.symbolName).frame(width: 18)
                                Text(device.name.uppercased()).font(Theme.mono(11)).lineLimit(1)
                                Spacer()
                                Text(device.shortKind).font(Theme.mono(9)).foregroundStyle(Theme.muted)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .panel(filled: false)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var sync: some View {
        VStack(alignment: .leading, spacing: 18) {
            Circle()
                .fill(Theme.accent)
                .frame(width: 64, height: 64)
                .overlay(RoundedRectangle(cornerRadius: 2).fill(Theme.onAccent).frame(width: 4, height: 20).offset(y: -14).rotationEffect(.degrees(50)))
            title(
                String(localized: "Подгоните синхрон"),
                String(localized: "Задержку Bluetooth Outputs подбирает сам. Чтобы было идеально, пройдите короткий тест щелчками: около 20 секунд.")
            )
            Button("ЗАПУСТИТЬ ТЕСТ") {
                finish()
                router.openTest()
            }
            .buttonStyle(.tactileAccent)
            .disabled(model.activeOutputs.count < 2)
        }
    }

    private func settingsCard(path: String, item: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(path).font(Theme.mono(10))
            HStack(spacing: 6) {
                Text(item).font(Theme.mono(10))
                Circle().fill(Theme.accent).frame(width: 7, height: 7)
                Text("ВКЛ").font(Theme.mono(10))
            }
        }
        .foregroundStyle(Theme.inverse)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(filled: true)
    }

    private func finish() {
        model.finishOnboarding()
        if !model.settings.selected.isEmpty, !model.isOn {
            model.setOn(true)
        }
        router.closeOnboarding()
    }
}
