import AppKit

enum StatusIcon {
    enum State: Equatable {
        case off
        case on
        case playing(CGFloat)
    }

    static func image(state: State, missing: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            let scale = rect.width / 24
            let ink = NSColor.labelColor.withAlphaComponent(state == .off ? 0.4 : 1)
            let accent = Theme.accentColor

            let cables = NSBezierPath()
            cables.move(to: point(8, 12, scale))
            cables.curve(to: point(16, 6, scale), controlPoint1: point(12, 12, scale), controlPoint2: point(11, 6, scale))
            cables.move(to: point(8, 12, scale))
            cables.curve(to: point(16, 18, scale), controlPoint1: point(12, 12, scale), controlPoint2: point(11, 18, scale))
            cables.lineWidth = 2.2 * scale
            cables.lineCapStyle = .round
            ink.setStroke()
            cables.stroke()

            let top = circle(18.5, 6, 2.6, scale)
            ink.setFill()
            top.fill()

            if missing && state != .off {
                let bottom = circle(18.5, 18, 2.2, scale)
                bottom.lineWidth = 1.6 * scale
                bottom.setLineDash([2 * scale, 1.5 * scale], count: 2, phase: 0)
                ink.setStroke()
                bottom.stroke()
            } else {
                ink.setFill()
                circle(18.5, 18, 2.6, scale).fill()
            }

            switch state {
            case .off:
                ink.setFill()
                circle(5, 12, 3, scale).fill()
            case .on:
                accent.setFill()
                circle(5, 12, 3, scale).fill()
            case .playing(let level):
                accent.setFill()
                circle(5, 12, 2.2 + 1.6 * min(max(level, 0), 1), scale).fill()
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Outputs"
        return image
    }

    private static func point(_ x: CGFloat, _ y: CGFloat, _ scale: CGFloat) -> NSPoint {
        NSPoint(x: x * scale, y: y * scale)
    }

    private static func circle(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat, _ scale: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: (x - radius) * scale, y: (y - radius) * scale, width: radius * 2 * scale, height: radius * 2 * scale))
    }
}
