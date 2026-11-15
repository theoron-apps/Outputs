import AppKit
import SwiftUI

struct Knob: View {
    let value: Double
    let range: ClosedRange<Double>
    var size: CGFloat = 38
    var step: Double = 1
    var sensitivity: Double = 180
    var leds = 15
    let onChange: (Double) -> Void

    @State private var dragStart: Double?
    @State private var sweep: Double?
    @Environment(\.powerToken) private var powerToken

    private var fraction: Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return min(max((value - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }

    var body: some View {
        ZStack {
            ring
            Circle()
                .fill(Color.black.opacity(0.55))
                .frame(width: size + 2, height: size + 2)
                .blur(radius: 2)
                .offset(y: 2.5)
            body3D
                .frame(width: size, height: size)
        }
        .frame(width: size + 20, height: size + 20)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    let start = dragStart ?? value
                    if dragStart == nil {
                        dragStart = value
                    }
                    let fine = NSEvent.modifierFlags.contains(.option) ? 0.2 : 1
                    let delta = (gesture.translation.width - gesture.translation.height) / sensitivity * fine
                    let raw = start + delta * (range.upperBound - range.lowerBound)
                    let stepped = min(max((raw / step).rounded() * step, range.lowerBound), range.upperBound)
                    let span = range.upperBound - range.lowerBound
                    if span > 0, Int((stepped - range.lowerBound) / span * 10) != Int((value - range.lowerBound) / span * 10) || (stepped != value && (stepped == range.lowerBound || stepped == range.upperBound)) {
                        Haptics.tick()
                    }
                    onChange(stepped)
                }
                .onEnded { _ in dragStart = nil }
        )
        .onChange(of: powerToken) { _, _ in bootSweep() }
        .accessibilityElement()
        .accessibilityValue(Text("\(Int(value.rounded()))"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(value + step * 5, range.upperBound))
            case .decrement: onChange(max(value - step * 5, range.lowerBound))
            @unknown default: break
            }
        }
    }

    private var ring: some View {
        ZStack {
            ForEach(0..<leds, id: \.self) { index in
                let position = Double(index) / Double(leds - 1)
                let lit = sweep.map { position <= $0 + 0.0001 && position >= $0 - 0.35 } ?? (fraction > 0 && position <= fraction + 0.0001)
                Circle()
                    .fill(lit ? Theme.accent : Theme.track)
                    .frame(width: 3.6, height: 3.6)
                    .shadow(color: lit ? Theme.accent.opacity(0.95) : .clear, radius: 2.5)
                    .offset(y: -(size / 2 + 6.5))
                    .rotationEffect(.degrees(-135 + position * 270))
            }
        }
        .animation(.easeOut(duration: 0.08), value: fraction)
    }

    private func bootSweep() {
        Task { @MainActor in
            for step in 0...18 {
                sweep = Double(step) / 13
                try? await Task.sleep(for: .milliseconds(28))
            }
            sweep = nil
        }
    }

    private var body3D: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(white: 0.31), Color(white: 0.11)], startPoint: .top, endPoint: .bottom))
            Circle()
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.4), .clear, Color.black.opacity(0.4)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            ForEach(0..<36, id: \.self) { index in
                Rectangle()
                    .fill(Color.black.opacity(0.28))
                    .frame(width: 0.8, height: size * 0.07)
                    .offset(y: -size / 2 + size * 0.05)
                    .rotationEffect(.degrees(Double(index) * 10))
            }
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.24), Color(white: 0.14)], center: UnitPoint(x: 0.45, y: 0.35), startRadius: 1, endRadius: size * 0.36))
                .padding(size * 0.15)
                .overlay(Circle().strokeBorder(LinearGradient(colors: [Color.black.opacity(0.5), Color.white.opacity(0.12)], startPoint: .top, endPoint: .bottom), lineWidth: 0.8).padding(size * 0.15))
            Circle()
                .fill(Color(white: 0.92))
                .frame(width: size * 0.11, height: size * 0.11)
                .shadow(color: .white.opacity(0.5), radius: 1)
                .offset(y: -size * 0.27)
                .rotationEffect(.degrees(-135 + fraction * 270))
        }
    }
}

private struct PowerTokenKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    var powerToken: Int {
        get { self[PowerTokenKey.self] }
        set { self[PowerTokenKey.self] = newValue }
    }
}
