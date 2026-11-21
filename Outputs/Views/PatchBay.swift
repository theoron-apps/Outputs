import AppKit
import Observation
import SwiftUI

struct CableNode: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    var missing = false
    var unplugged = false
    var level: Float = 0

    var isFree: Bool { missing || unplugged }
}

enum Haptics {
    static func click() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    static func tick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}

@Observable
final class RopeField {
    struct Anchor: Equatable {
        let id: String
        let start: CGPoint
        let end: CGPoint
        let free: Bool
        let pluggable: Bool
    }

    enum Event {
        case unplugged(String)
        case plugged(String)
    }

    fileprivate struct Rope {
        var points: [CGPoint]
        var previous: [CGPoint]
        var segment: CGFloat
        var freeSegment: CGFloat
        var start: CGPoint
        var end: CGPoint
        var free: Bool
        var pluggable: Bool
    }

    private(set) var isActive = true

    @ObservationIgnored fileprivate var ropes: [String: Rope] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var grab: (id: String, index: Int)?
    @ObservationIgnored private var grabPoint = CGPoint.zero
    @ObservationIgnored private var lastTick: Date?
    @ObservationIgnored private var accumulator: Double = 0
    @ObservationIgnored private var calm = 0
    @ObservationIgnored private var floor: CGFloat = 0
    @ObservationIgnored private var width: CGFloat = 0
    @ObservationIgnored private var pendingKick = true
    @ObservationIgnored private var lastAnchors: [Anchor] = []

    private static let count = 22
    private static let gravity: CGFloat = 1400
    private static let damping: CGFloat = 0.985
    private static let iterations = 16
    private static let step: Double = 1.0 / 120
    private static let pullOut: CGFloat = 26
    private static let snapIn: CGFloat = 14

    func sync(_ anchors: [Anchor], floor: CGFloat, width: CGFloat) {
        guard anchors != lastAnchors || floor != self.floor || width != self.width || pendingKick else { return }
        lastAnchors = anchors
        self.floor = floor
        self.width = width
        for anchor in anchors {
            let distance = max(hypot(anchor.end.x - anchor.start.x, anchor.end.y - anchor.start.y), 1)
            let room = floor - max(anchor.start.y, anchor.end.y) - 8
            let sag = max(8, min(room, 22 + distance * 0.07))
            let segment = (distance + 8 * sag * sag / (3 * distance)) / CGFloat(Self.count - 1)
            let freeSegment = max(distance * 0.9, 70) / CGFloat(Self.count - 1)
            if var rope = ropes[anchor.id] {
                let detaching = grab?.id == anchor.id && grab?.index == rope.points.count - 1
                rope.free = anchor.free || detaching
                rope.pluggable = anchor.pluggable
                rope.segment = segment
                rope.freeSegment = freeSegment
                rope.start = anchor.start
                rope.end = anchor.end
                ropes[anchor.id] = rope
            } else {
                var points: [CGPoint] = []
                for index in 0..<Self.count {
                    let t = CGFloat(index) / CGFloat(Self.count - 1)
                    let x = anchor.start.x + (anchor.end.x - anchor.start.x) * t
                    let y = anchor.start.y + (anchor.end.y - anchor.start.y) * t - sin(t * .pi) * 18
                    points.append(CGPoint(x: x, y: y))
                }
                ropes[anchor.id] = Rope(points: points, previous: points, segment: segment, freeSegment: freeSegment, start: anchor.start, end: anchor.end, free: anchor.free, pluggable: anchor.pluggable)
            }
        }
        let ids = Set(anchors.map(\.id))
        ropes = ropes.filter { ids.contains($0.key) }
        order = anchors.map(\.id)
        if pendingKick {
            pendingKick = false
            for id in ropes.keys {
                guard var rope = ropes[id] else { continue }
                for index in rope.points.indices {
                    let t = CGFloat(index) / CGFloat(rope.points.count - 1)
                    rope.previous[index].y = rope.points[index].y + sin(t * .pi) * 4.5
                }
                ropes[id] = rope
            }
        }
        wake()
    }

    func kick() {
        pendingKick = true
        wake()
    }

    func wake() {
        calm = 0
        if !isActive {
            DispatchQueue.main.async { [weak self] in
                self?.lastTick = nil
                self?.isActive = true
            }
        }
    }

    func beginGrab(at point: CGPoint) -> Bool {
        guard let hit = nearest(to: point, within: 20) else { return false }
        grab = hit
        grabPoint = point
        wake()
        return true
    }

    func moveGrab(to point: CGPoint) -> Event? {
        guard let grab, var rope = ropes[grab.id] else { return nil }
        var target = CGPoint(x: min(max(point.x, 4), width - 4), y: min(max(point.y, 4), floor))
        var event: Event?
        let isEnd = grab.index == rope.points.count - 1
        if isEnd {
            let away = hypot(target.x - rope.end.x, target.y - rope.end.y)
            if !rope.free, away > Self.pullOut {
                rope.free = true
                event = .unplugged(grab.id)
            } else if rope.free, rope.pluggable, away < Self.snapIn {
                rope.free = false
                target = rope.end
                event = .plugged(grab.id)
                self.grab = nil
            } else if !rope.free {
                target = rope.end
            }
            ropes[grab.id] = rope
        }
        grabPoint = target
        wake()
        return event
    }

    func endGrab() {
        grab = nil
        wake()
    }

    func isNear(_ point: CGPoint) -> Bool {
        nearest(to: point, within: 14) != nil
    }

    private func nearest(to point: CGPoint, within limit: CGFloat) -> (id: String, index: Int)? {
        var best: (id: String, index: Int, distance: CGFloat)?
        for (id, rope) in ropes {
            for index in 1..<rope.points.count {
                let bonus: CGFloat = index == rope.points.count - 1 ? 6 : 0
                let distance = hypot(rope.points[index].x - point.x, rope.points[index].y - point.y) - bonus
                if distance < limit, distance < (best?.distance ?? .infinity) {
                    best = (id, index, distance)
                }
            }
        }
        return best.map { ($0.id, $0.index) }
    }

    func advance(to now: Date) {
        let elapsed = lastTick.map { now.timeIntervalSince($0) } ?? Self.step
        lastTick = now
        accumulator = min(accumulator + elapsed, Self.step * 6)
        var motion: CGFloat = 0
        while accumulator >= Self.step {
            accumulator -= Self.step
            motion = max(motion, integrate(CGFloat(Self.step)))
        }
        if motion < 0.01, grab == nil {
            calm += 1
            if calm > 60, isActive {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.calm > 60, self.grab == nil else { return }
                    self.isActive = false
                }
            }
        } else {
            calm = 0
        }
    }

    private func integrate(_ h: CGFloat) -> CGFloat {
        var motion: CGFloat = 0
        for id in order {
            guard var rope = ropes[id] else { continue }
            let last = rope.points.count - 1
            let segment = rope.free ? rope.freeSegment : rope.segment
            for index in 1...last where rope.free || index < last {
                let point = rope.points[index]
                let vx = (point.x - rope.previous[index].x) * Self.damping
                let vy = (point.y - rope.previous[index].y) * Self.damping
                rope.previous[index] = point
                rope.points[index] = CGPoint(x: point.x + vx, y: point.y + vy + Self.gravity * h * h)
            }
            for _ in 0..<Self.iterations {
                pin(&rope, id: id, last: last)
                for index in 0..<last {
                    let a = rope.points[index]
                    let b = rope.points[index + 1]
                    let dx = b.x - a.x
                    let dy = b.y - a.y
                    let distance = max(hypot(dx, dy), 0.0001)
                    let difference = (distance - segment) / distance
                    let fixedA = index == 0 || isGrabbed(id, index)
                    let fixedB = (index + 1 == last && !rope.free) || isGrabbed(id, index + 1)
                    let weightA: CGFloat = fixedA ? 0 : (fixedB ? 1 : 0.5)
                    let weightB: CGFloat = fixedB ? 0 : (fixedA ? 1 : 0.5)
                    rope.points[index].x += dx * difference * weightA
                    rope.points[index].y += dy * difference * weightA
                    rope.points[index + 1].x -= dx * difference * weightB
                    rope.points[index + 1].y -= dy * difference * weightB
                }
                for index in rope.points.indices {
                    rope.points[index].y = min(rope.points[index].y, floor)
                    rope.points[index].x = min(max(rope.points[index].x, 4), width - 4)
                }
            }
            pin(&rope, id: id, last: last)
            for index in rope.points.indices {
                motion = max(motion, abs(rope.points[index].x - rope.previous[index].x) + abs(rope.points[index].y - rope.previous[index].y))
            }
            ropes[id] = rope
        }
        return motion
    }

    private func isGrabbed(_ id: String, _ index: Int) -> Bool {
        grab?.id == id && grab?.index == index
    }

    private func pin(_ rope: inout Rope, id: String, last: Int) {
        rope.points[0] = rope.start
        if !rope.free {
            rope.points[last] = rope.end
        }
        if let grab, grab.id == id {
            rope.points[grab.index] = grabPoint
        }
    }

    fileprivate func points(_ id: String) -> [CGPoint]? {
        ropes[id]?.points
    }

    fileprivate var grabbedEnd: (id: String, point: CGPoint)? {
        guard let grab, let rope = ropes[grab.id], grab.index == rope.points.count - 1 else { return nil }
        return (grab.id, grabPoint)
    }

    fileprivate func isFree(_ id: String) -> Bool {
        ropes[id]?.free ?? false
    }
}

struct PatchLayout: Equatable {
    let width: CGFloat
    let rows: Int
    var rowHeight: CGFloat = 40
    var inset: CGFloat = 14

    var height: CGFloat { CGFloat(max(rows, 1)) * rowHeight + inset * 2 }
    var labelWidth: CGFloat { min(176, width * 0.44) }
    var sourceJack: CGPoint { CGPoint(x: inset + 14, y: height / 2 - 7) }
    var plugLength: CGFloat { 15 }

    func outputJack(_ index: Int) -> CGPoint {
        CGPoint(x: width - labelWidth - inset - 10, y: inset + CGFloat(index) * rowHeight + rowHeight / 2)
    }
}

struct PatchBay: View {
    let source: String
    let nodes: [CableNode]
    var rowHeight: CGFloat = 40
    var onPlug: ((String, Bool) -> Void)?

    @State private var field = RopeField()
    @State private var dragging = false

    var body: some View {
        GeometryReader { geometry in
            let layout = PatchLayout(width: geometry.size.width, rows: nodes.count, rowHeight: rowHeight)
            ZStack(alignment: .topLeading) {
                PatchCanvas(
                    field: field,
                    layout: layout,
                    cables: nodes.map { PatchCanvas.Cable(id: $0.id, free: $0.isFree, pluggable: !$0.missing) },
                    live: Set(nodes.filter { !$0.isFree && $0.level > 0.02 }.map(\.id))
                )
                .equatable()
                labels(layout)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if !dragging {
                            dragging = field.beginGrab(at: value.startLocation)
                            if dragging { NSCursor.closedHand.set() }
                        }
                        guard dragging else { return }
                        switch field.moveGrab(to: value.location) {
                        case .unplugged(let id):
                            Haptics.click()
                            onPlug?(id, false)
                        case .plugged(let id):
                            Haptics.click()
                            NSSound(named: "Tink")?.play()
                            onPlug?(id, true)
                            dragging = false
                            NSCursor.openHand.set()
                        case nil:
                            break
                        }
                    }
                    .onEnded { _ in
                        if dragging {
                            field.endGrab()
                            NSCursor.openHand.set()
                        }
                        dragging = false
                    }
            )
            .onContinuousHover { phase in
                guard !dragging else { return }
                switch phase {
                case .active(let point): (field.isNear(point) ? NSCursor.openHand : NSCursor.arrow).set()
                case .ended: NSCursor.arrow.set()
                }
            }
        }
        .frame(height: PatchLayout(width: 0, rows: nodes.count, rowHeight: rowHeight).height)
        .panel(radius: 12, screws: true)
        .onAppear { field.kick() }
    }

    private func labels(_ layout: PatchLayout) -> some View {
        ZStack(alignment: .topLeading) {
            Text(source)
                .font(Theme.mono(9))
                .foregroundStyle(Theme.muted)
                .frame(width: 60)
                .position(x: layout.sourceJack.x, y: layout.sourceJack.y + 21)
            ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                let jack = layout.outputJack(index)
                HStack(spacing: 7) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.title.uppercased())
                            .font(Theme.mono(10))
                            .foregroundStyle(node.isFree ? Theme.muted : Theme.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(node.subtitle)
                            .font(Theme.mono(8))
                            .foregroundStyle(node.isFree ? Theme.accent : Theme.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    PowerLED(isOn: !node.isFree && node.level > 0.02, size: 6)
                }
                .frame(width: layout.labelWidth, height: rowHeight, alignment: .leading)
                .position(x: jack.x + 16 + layout.labelWidth / 2, y: jack.y)
            }
        }
        .allowsHitTesting(false)
    }
}

struct PatchCanvas: View, Equatable {
    struct Cable: Equatable {
        let id: String
        let free: Bool
        let pluggable: Bool
    }

    let field: RopeField
    let layout: PatchLayout
    let cables: [Cable]
    let live: Set<String>

    static func == (lhs: PatchCanvas, rhs: PatchCanvas) -> Bool {
        lhs.field === rhs.field && lhs.layout == rhs.layout && lhs.cables == rhs.cables && lhs.live == rhs.live
    }

    var body: some View {
        TimelineView(.animation(paused: !field.isActive && live.isEmpty && !cables.contains { $0.free && $0.pluggable })) { timeline in
            Canvas { context, _ in
                field.sync(anchors, floor: layout.height - 9, width: layout.width)
                if field.isActive {
                    field.advance(to: timeline.date)
                }
                draw(in: &context, time: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private var anchors: [RopeField.Anchor] {
        let start = CGPoint(x: layout.sourceJack.x + layout.plugLength, y: layout.sourceJack.y)
        return cables.enumerated().map { index, cable in
            let jack = layout.outputJack(index)
            return RopeField.Anchor(id: cable.id, start: start, end: CGPoint(x: jack.x - layout.plugLength, y: jack.y), free: cable.free, pluggable: cable.pluggable)
        }
    }

    private func draw(in context: inout GraphicsContext, time: TimeInterval) {
        drawJack(in: &context, at: layout.sourceJack, radius: 10)
        let grabbed = field.grabbedEnd
        let pulse = 0.5 + 0.5 * sin(time * 6)
        for (index, cable) in cables.enumerated() {
            let center = layout.outputJack(index)
            let color = Theme.cableColor(index)
            let isTarget = grabbed?.id == cable.id && cable.pluggable
            let waiting = grabbed == nil && cable.free && cable.pluggable
            let dimmed = grabbed != nil && !isTarget
            if isTarget || waiting {
                let glow = isTarget ? 15 + 4 * pulse : 13 + 2 * pulse
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: 5))
                    layer.fill(Path(ellipseIn: CGRect(x: center.x - glow, y: center.y - glow, width: glow * 2, height: glow * 2)), with: .color(color.opacity(isTarget ? 0.55 : 0.25 + 0.2 * pulse)))
                }
            }
            drawJack(in: &context, at: center, radius: 9)
            let ring = Path(ellipseIn: CGRect(x: center.x - 11.5, y: center.y - 11.5, width: 23, height: 23))
            context.stroke(ring, with: .color(color.opacity(dimmed ? 0.25 : 0.95)), lineWidth: 2.4)
            if dimmed {
                context.fill(Path(ellipseIn: CGRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20)), with: .color(.black.opacity(0.45)))
            }
            if isTarget, let grabbed {
                var guide = Path()
                guide.move(to: grabbed.point)
                guide.addLine(to: CGPoint(x: center.x - layout.plugLength, y: center.y))
                context.stroke(guide, with: .color(color.opacity(0.8)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [3, 4], dashPhase: CGFloat(-time * 30)))
                context.draw(Text("СЮДА").font(Theme.mono(8, .bold)).foregroundStyle(color), at: CGPoint(x: center.x, y: center.y + 19))
            }
        }
        for (index, cable) in cables.enumerated().reversed() {
            guard let points = field.points(cable.id), points.count > 1 else { continue }
            let color = Theme.cableColor(index)
            let path = smoothPath(points)
            drawPlug(in: &context, from: layout.sourceJack, toward: points[0], color: color)
            CableRenderer.draw(path, color: color, in: &context)
            if live.contains(cable.id), !field.isFree(cable.id) {
                drawPulse(in: &context, path: path, time: time)
            }
            if field.isFree(cable.id) {
                let tip = points[points.count - 1]
                let before = points[points.count - 2]
                let dx = tip.x - before.x
                let dy = tip.y - before.y
                let length = max(hypot(dx, dy), 0.001)
                drawPlug(in: &context, from: CGPoint(x: tip.x + dx / length * layout.plugLength, y: tip.y + dy / length * layout.plugLength), toward: tip, color: color)
            } else {
                drawPlug(in: &context, from: layout.outputJack(index), toward: points[points.count - 1], color: color)
            }
        }
    }

    private func drawPulse(in context: inout GraphicsContext, path: Path, time: TimeInterval) {
        let phase = CGFloat(-(time * 70).truncatingRemainder(dividingBy: 1000))
        let style = StrokeStyle(lineWidth: 2.2, lineCap: .round, dash: [2.5, 26], dashPhase: phase)
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 2.5))
            layer.stroke(path, with: .color(Theme.accent.opacity(0.9)), style: StrokeStyle(lineWidth: 5, lineCap: .round, dash: [2.5, 26], dashPhase: phase))
        }
        context.stroke(path, with: .color(.white.opacity(0.85)), style: style)
    }

    private func smoothPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for index in 1..<points.count - 1 {
            let mid = CGPoint(x: (points[index].x + points[index + 1].x) / 2, y: (points[index].y + points[index + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[index])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    private func drawJack(in context: inout GraphicsContext, at center: CGPoint, radius: CGFloat) {
        let outer = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.5), radius: 1.5, y: 1.2))
            layer.fill(Path(ellipseIn: outer), with: .linearGradient(Gradient(colors: [Color(white: 0.86), Color(white: 0.42)]), startPoint: CGPoint(x: outer.minX, y: outer.minY), endPoint: CGPoint(x: outer.maxX, y: outer.maxY)))
        }
        context.stroke(Path(ellipseIn: outer.insetBy(dx: 0.5, dy: 0.5)), with: .color(.black.opacity(0.35)), lineWidth: 0.6)
        let nut = outer.insetBy(dx: radius * 0.22, dy: radius * 0.22)
        context.fill(Path(ellipseIn: nut), with: .linearGradient(Gradient(colors: [Color(white: 0.38), Color(white: 0.72)]), startPoint: CGPoint(x: nut.minX, y: nut.minY), endPoint: CGPoint(x: nut.maxX, y: nut.maxY)))
        let hole = outer.insetBy(dx: radius * 0.48, dy: radius * 0.48)
        context.fill(Path(ellipseIn: hole), with: .color(.black))
    }

    private func drawPlug(in context: inout GraphicsContext, from tip: CGPoint, toward end: CGPoint, color: Color) {
        let dx = end.x - tip.x
        let dy = end.y - tip.y
        let length = max(hypot(dx, dy), 0.001)
        let angle = atan2(dy, dx)
        context.drawLayer { layer in
            layer.translateBy(x: tip.x, y: tip.y)
            layer.rotate(by: .radians(angle))
            layer.addFilter(.shadow(color: .black.opacity(0.45), radius: 1.5, y: 1.5))
            let sleeve = CGRect(x: 0, y: -2.6, width: length * 0.36, height: 5.2)
            layer.fill(Path(roundedRect: sleeve, cornerRadius: 1), with: .linearGradient(Gradient(colors: [Color(white: 0.92), Color(white: 0.5)]), startPoint: CGPoint(x: 0, y: -2.6), endPoint: CGPoint(x: 0, y: 2.6)))
            let boot = CGRect(x: length * 0.32, y: -4.2, width: length * 0.7, height: 8.4)
            layer.fill(Path(roundedRect: boot, cornerRadius: 2.5), with: .color(color))
            layer.fill(Path(roundedRect: boot, cornerRadius: 2.5), with: .linearGradient(Gradient(colors: [.white.opacity(0.32), .clear, .black.opacity(0.3)]), startPoint: CGPoint(x: 0, y: -4.2), endPoint: CGPoint(x: 0, y: 4.2)))
            for ridge in 0..<3 {
                let x = length * 0.5 + CGFloat(ridge) * 3
                layer.fill(Path(CGRect(x: x, y: -4.2, width: 0.8, height: 8.4)), with: .color(.black.opacity(0.18)))
            }
        }
    }
}


struct JackView: View {
    var size: CGFloat = 18
    var ring: Color?
    var glow = false

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(white: 0.86), Color(white: 0.42)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().fill(LinearGradient(colors: [Color(white: 0.38), Color(white: 0.72)], startPoint: .topLeading, endPoint: .bottomTrailing)).padding(size * 0.11)
            Circle().fill(Color.black).padding(size * 0.26)
        }
        .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.6))
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.5), radius: 1.5, y: 1.2)
        .padding(ring == nil ? 0 : 3)
        .overlay {
            if let ring {
                Circle().strokeBorder(ring, lineWidth: 2.2)
                    .shadow(color: ring.opacity(glow ? 0.9 : 0), radius: glow ? 6 : 0)
            }
        }
        .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: glow)
    }
}

enum CableRenderer {
    static func draw(_ path: Path, color: Color, width: CGFloat = 5.2, in context: inout GraphicsContext) {
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 2.5))
            layer.translateBy(x: 0, y: 4.5)
            layer.stroke(path, with: .color(.black.opacity(0.42)), style: StrokeStyle(lineWidth: width + 0.8, lineCap: .round, lineJoin: .round))
        }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        context.drawLayer { layer in
            layer.translateBy(x: 0, y: width * 0.29)
            layer.stroke(path, with: .color(.black.opacity(0.22)), style: StrokeStyle(lineWidth: width * 0.31, lineCap: .round, lineJoin: .round))
        }
        context.drawLayer { layer in
            layer.translateBy(x: 0, y: -width * 0.23)
            layer.stroke(path, with: .color(.white.opacity(0.38)), style: StrokeStyle(lineWidth: width * 0.25, lineCap: .round, lineJoin: .round))
        }
    }
}
