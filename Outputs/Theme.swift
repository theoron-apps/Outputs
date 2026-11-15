import AppKit
import SwiftUI

enum Theme {
    static let background = dynamic(light: 0xD8D7D3, dark: 0x161616)
    static let plateTop = dynamic(light: 0xF3F2EF, dark: 0x2A2A2A)
    static let plateBottom = dynamic(light: 0xDDDCD8, dark: 0x1E1E1E)
    static let well = dynamic(light: 0xC9C8C3, dark: 0x111111)
    static let panel = dynamic(light: 0xEAE9E5, dark: 0x242424)
    static let line = dynamic(light: 0xB4B3AD, dark: 0x3A3A38)
    static let ink = dynamic(light: 0x161616, dark: 0xE6E5E1)
    static let inverse = dynamic(light: 0xE6E5E1, dark: 0x161616)
    static let track = dynamic(light: 0xC2C1BC, dark: 0x2E2E2E)
    static let muted = dynamic(light: 0x67665F, dark: 0x8C8B85)
    static let edgeLight = dynamic(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.9, darkAlpha: 0.13)
    static let edgeDark = dynamic(light: 0x000000, dark: 0x000000, lightAlpha: 0.2, darkAlpha: 0.6)
    static let shadow = dynamic(light: 0x000000, dark: 0x000000, lightAlpha: 0.22, darkAlpha: 0.55)
    static let grainOpacity = 0.07
    static let accent = Color(nsColor: accentColor)
    static let accentColor = NSColor(srgbRed: 1, green: 0x5A / 255, blue: 0x1F / 255, alpha: 1)
    static let accentDeep = Color(nsColor: NSColor(srgbRed: 0.82, green: 0.27, blue: 0.08, alpha: 1))
    static let onAccent = Color(nsColor: NSColor(srgbRed: 0x15 / 255, green: 0x15 / 255, blue: 0x15 / 255, alpha: 1))
    static let peak = Color(nsColor: NSColor(srgbRed: 1, green: 0.22, blue: 0.2, alpha: 1))

    static let scale: CGFloat = 1.08

    private static let cables: [Color] = [
        dynamic(light: 0x2B2B2B, dark: 0xD9D8D4),
        accent,
        Color(nsColor: NSColor(srgbRed: 0.96, green: 0.76, blue: 0.29, alpha: 1)),
        Color(nsColor: NSColor(srgbRed: 0.42, green: 0.74, blue: 1, alpha: 1))
    ]

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(weight == .regular ? "Menlo-Regular" : "Menlo-Bold", fixedSize: (size * scale).rounded())
    }

    static func cableColor(_ index: Int) -> Color {
        cables[index % cables.count]
    }

    private static func dynamic(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return color(isDark ? dark : light).withAlphaComponent(isDark ? darkAlpha : lightAlpha)
        })
    }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

enum GrainTexture {
    static let image: NSImage = {
        let size = 128
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for y in 0..<size {
            for x in 0..<size {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let value = CGFloat(seed >> 56) / 255
                let light = (seed >> 40) & 1 == 0
                rep.setColor(NSColor(white: light ? 1 : 0, alpha: value * 0.9), atX: x, y: y)
            }
        }
        let image = NSImage(size: NSSize(width: size / 2, height: size / 2))
        image.addRepresentation(rep)
        return image
    }()
}

struct Grain: View {
    var opacity = Theme.grainOpacity

    var body: some View {
        Image(nsImage: GrainTexture.image)
            .resizable(resizingMode: .tile)
            .opacity(opacity)
            .blendMode(.overlay)
            .allowsHitTesting(false)
    }
}

struct WindowBackground: View {
    var body: some View {
        ZStack {
            Theme.background
            Grain(opacity: 0.09)
        }
        .ignoresSafeArea()
    }
}

struct Screw: View {
    var angle: Double = 35

    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [Color(white: 0.78), Color(white: 0.36)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Capsule().fill(Color(white: 0.16)).frame(width: 1.2, height: 5.5).rotationEffect(.degrees(angle)))
            .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5))
            .frame(width: 7, height: 7)
            .shadow(color: .black.opacity(0.45), radius: 0.5, y: 0.6)
            .allowsHitTesting(false)
    }
}

struct PlateBackground: ViewModifier {
    var radius: CGFloat = 10
    var screws = false
    var recessed = false

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    if recessed {
                        RoundedRectangle(cornerRadius: radius).fill(Theme.well)
                        Grain(opacity: 0.1).clipShape(RoundedRectangle(cornerRadius: radius))
                        RoundedRectangle(cornerRadius: radius)
                            .strokeBorder(LinearGradient(colors: [Theme.edgeDark, Theme.edgeLight], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    } else {
                        RoundedRectangle(cornerRadius: radius)
                            .fill(LinearGradient(colors: [Theme.plateTop, Theme.plateBottom], startPoint: .top, endPoint: .bottom))
                            .shadow(color: Theme.shadow, radius: 3, y: 2)
                        Grain().clipShape(RoundedRectangle(cornerRadius: radius))
                        RoundedRectangle(cornerRadius: radius)
                            .strokeBorder(LinearGradient(colors: [Theme.edgeLight, Theme.edgeDark], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if screws { Screw(angle: 35).padding(6) }
            }
            .overlay(alignment: .bottomLeading) {
                if screws { Screw(angle: -20).padding(6) }
            }
    }
}

struct InkBackground: ViewModifier {
    var radius: CGFloat = 8

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius)
                    .fill(Theme.ink)
                    .overlay(Grain(opacity: 0.08).clipShape(RoundedRectangle(cornerRadius: radius)))
                    .shadow(color: Theme.shadow, radius: 2, y: 1.5)
            }
    }
}

extension View {
    func panel(filled: Bool = false, radius: CGFloat = 10, screws: Bool = false) -> some View {
        Group {
            if filled {
                modifier(InkBackground(radius: radius))
            } else {
                modifier(PlateBackground(radius: radius, screws: screws))
            }
        }
    }

    func recessed(radius: CGFloat = 10) -> some View {
        modifier(PlateBackground(radius: radius, recessed: true))
    }
}

struct TactileButtonStyle: ButtonStyle {
    enum Kind {
        case plain
        case filled
        case accent
    }

    var kind: Kind = .plain
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(Theme.mono(10))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.black.opacity(0.35))
                        .offset(y: pressed ? 0.5 : 1.5)
                        .blur(radius: pressed ? 0.5 : 1.5)
                    RoundedRectangle(cornerRadius: 7)
                        .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                    Grain(opacity: 0.06).clipShape(RoundedRectangle(cornerRadius: 7))
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(LinearGradient(colors: [Color.white.opacity(kind == .plain ? 0.12 : 0.45), Color.black.opacity(0.4)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                }
            }
            .offset(y: pressed ? 1 : 0)
            .brightness(pressed ? -0.04 : 0)
            .animation(.snappy(duration: 0.1), value: pressed)
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }

    private var foreground: Color {
        switch kind {
        case .plain: Theme.ink
        case .filled: Theme.inverse
        case .accent: Theme.onAccent
        }
    }

    private var colors: [Color] {
        switch kind {
        case .plain: [Theme.plateTop, Theme.plateBottom]
        case .filled: [Theme.ink, Theme.ink.opacity(0.82)]
        case .accent: [Theme.accent, Theme.accentDeep]
        }
    }
}

extension ButtonStyle where Self == TactileButtonStyle {
    static var tactile: TactileButtonStyle { TactileButtonStyle() }
    static var tactileFilled: TactileButtonStyle { TactileButtonStyle(kind: .filled) }
    static var tactileAccent: TactileButtonStyle { TactileButtonStyle(kind: .accent) }
}

struct PowerLED: View {
    var isOn = true
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(isOn ? Theme.accent : Theme.track)
            .overlay(Circle().fill(Color.white.opacity(isOn ? 0.55 : 0.2)).frame(width: size * 0.35, height: size * 0.35).offset(x: -size * 0.14, y: -size * 0.14))
            .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5))
            .frame(width: size, height: size)
            .shadow(color: isOn ? Theme.accent.opacity(0.9) : .clear, radius: size * 0.5)
            .animation(.easeOut(duration: 0.2), value: isOn)
    }
}

struct PowerSwitch: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? AnyShapeStyle(LinearGradient(colors: [Theme.accentDeep, Theme.accent], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Theme.well))
                    .overlay(Capsule().strokeBorder(LinearGradient(colors: [Theme.edgeDark, Theme.edgeLight], startPoint: .top, endPoint: .bottom), lineWidth: 1))
                    .shadow(color: isOn ? Theme.accent.opacity(0.55) : .clear, radius: 5)
                Circle()
                    .fill(LinearGradient(colors: [Color(white: 0.97), Color(white: 0.72)], startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.2), lineWidth: 0.5))
                    .padding(2.5)
                    .shadow(color: .black.opacity(0.45), radius: 1.5, y: 1)
            }
            .frame(width: 40, height: 22)
            .animation(.snappy(duration: 0.2), value: isOn)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Outputs"))
        .accessibilityValue(Text(isOn ? "ВКЛ" : "ВЫКЛ"))
    }
}

struct LevelBar: View {
    let level: Float
    var segments = 10

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { index in
                let lit = Float(index) / Float(segments) < level
                let hot = index >= segments - 2
                RoundedRectangle(cornerRadius: 1)
                    .fill(lit ? (hot ? Theme.peak : Theme.accent) : Theme.track)
                    .overlay(RoundedRectangle(cornerRadius: 1).strokeBorder(Color.black.opacity(0.3), lineWidth: 0.5))
                    .shadow(color: lit ? (hot ? Theme.peak : Theme.accent).opacity(0.75) : .clear, radius: 2.5)
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.06), value: level)
    }
}
