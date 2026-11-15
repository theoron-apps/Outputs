import SwiftUI

struct AppsTab: View {
    let model: AppModel

    private struct Drag {
        let bundleID: String
        let from: String?
        var point: CGPoint
    }

    @State private var drag: Drag?

    private let rowHeight: CGFloat = 50
    private let spacing: CGFloat = 8
    private let appWidth: CGFloat = 290
    private let outputWidth: CGFloat = 210

    private var apps: [AudioApp] {
        var list = model.processes.apps
        let known = Set(model.settings.appRoutes.keys).union(model.settings.appVolumes.keys)
        for bundleID in known.sorted() where !list.contains(where: { $0.bundleID == bundleID }) {
            list.append(AudioApp(bundleID: bundleID, name: AudioProcessReader.displayName(of: bundleID), isPlaying: false))
        }
        return list
    }

    private var outputs: [String] { model.settings.selected }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(
                String(localized: "КУДА ИГРАЕТ КАЖДОЕ ПРИЛОЖЕНИЕ"),
                detail: String(localized: "Протяните кабель от приложения к выходу. Чтобы отключить, схватите кабель и выдерните его или перетащите на другой выход. Без кабелей приложение играет во все выходы.")
            )
            if outputs.isEmpty {
                Text("Сначала добавьте выходы на вкладке «Выходы».")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.muted)
            } else if apps.isEmpty {
                Text("Включите музыку или видео — приложение со звуком появится здесь.")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.muted)
            } else {
                patchbay
            }
        }
    }

    private var patchbay: some View {
        let rows = max(apps.count, outputs.count)
        let height = CGFloat(rows) * rowHeight + CGFloat(max(rows - 1, 0)) * spacing
        return GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                VStack(spacing: spacing) {
                    ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                        appRow(app, index: index, width: width)
                    }
                }
                .frame(width: appWidth)
                VStack(spacing: spacing) {
                    ForEach(Array(outputs.enumerated()), id: \.element) { index, uid in
                        outputRow(uid, index: index, highlighted: hoveredOutput(width: width) == index)
                    }
                }
                .frame(width: outputWidth)
                .offset(x: width - outputWidth)
                .allowsHitTesting(false)
                Canvas { context, _ in
                    for (appIndex, app) in apps.enumerated() {
                        for uid in model.routes(for: app.bundleID) ?? [] {
                            guard let outputIndex = outputs.firstIndex(of: uid),
                                  !(drag?.bundleID == app.bundleID && drag?.from == uid) else { continue }
                            CableRenderer.draw(cable(from: appPort(appIndex), to: outputPort(outputIndex, width: width)), color: Theme.cableColor(outputIndex), width: 4.4, in: &context)
                        }
                    }
                    if let drag, let index = apps.firstIndex(where: { $0.bundleID == drag.bundleID }) {
                        let color = drag.from.flatMap { outputs.firstIndex(of: $0) }.map { Theme.cableColor($0) } ?? Theme.accent
                        CableRenderer.draw(cable(from: appPort(index), to: drag.point), color: color, width: 4.4, in: &context)
                    }
                }
                .allowsHitTesting(false)
            }
            .coordinateSpace(name: "patch")
            .simultaneousGesture(cableGesture(width: width))
        }
        .frame(height: height)
    }

    private func cableGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("patch"))
            .onChanged { value in
                if drag == nil {
                    guard let start = hit(value.startLocation, width: width) else { return }
                    drag = start
                    NSCursor.closedHand.set()
                }
                drag?.point = value.location
            }
            .onEnded { value in
                guard let current = drag else { return }
                drag = nil
                NSCursor.arrow.set()
                let target = outputIndex(at: value.location, width: width).map { outputs[$0] }
                switch (current.from, target) {
                case (nil, let uid?):
                    if model.routes(for: current.bundleID)?.contains(uid) != true {
                        model.toggleRoute(current.bundleID, to: uid)
                        Haptics.click()
                    }
                case (let from?, let uid?) where uid != from:
                    model.moveRoute(current.bundleID, from: from, to: uid)
                    Haptics.click()
                case (let from?, nil):
                    model.toggleRoute(current.bundleID, to: from)
                    Haptics.click()
                default:
                    break
                }
            }
    }

    private func hit(_ point: CGPoint, width: CGFloat) -> Drag? {
        for (index, app) in apps.enumerated() {
            let port = appPort(index)
            if hypot(point.x - port.x, point.y - port.y) < 18 {
                return Drag(bundleID: app.bundleID, from: nil, point: point)
            }
        }
        var best: (Drag, CGFloat)?
        for (appIndex, app) in apps.enumerated() {
            for uid in model.routes(for: app.bundleID) ?? [] {
                guard let outputIndex = outputs.firstIndex(of: uid) else { continue }
                let start = appPort(appIndex)
                let end = outputPort(outputIndex, width: width)
                for step in 4...40 {
                    let sample = bezier(start, end, CGFloat(step) / 40)
                    let distance = hypot(sample.x - point.x, sample.y - point.y)
                    if distance < 12, distance < (best?.1 ?? .infinity) {
                        best = (Drag(bundleID: app.bundleID, from: uid, point: point), distance)
                    }
                }
            }
        }
        return best?.0
    }

    private func hoveredOutput(width: CGFloat) -> Int? {
        guard let drag else { return nil }
        return outputIndex(at: drag.point, width: width)
    }

    private func outputIndex(at point: CGPoint, width: CGFloat) -> Int? {
        guard point.x > width - outputWidth - 24 else { return nil }
        let index = Int((point.y / (rowHeight + spacing)).rounded(.down))
        return outputs.indices.contains(index) ? index : nil
    }

    private func appPort(_ index: Int) -> CGPoint {
        CGPoint(x: appWidth - 14, y: CGFloat(index) * (rowHeight + spacing) + rowHeight / 2)
    }

    private func outputPort(_ index: Int, width: CGFloat) -> CGPoint {
        CGPoint(x: width - outputWidth + 19, y: CGFloat(index) * (rowHeight + spacing) + rowHeight / 2)
    }

    private func bezier(_ start: CGPoint, _ end: CGPoint, _ t: CGFloat) -> CGPoint {
        let mid = (start.x + end.x) / 2
        let c1 = CGPoint(x: mid, y: start.y)
        let c2 = CGPoint(x: mid, y: end.y)
        let u = 1 - t
        let x = u * u * u * start.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * end.x
        let y = u * u * u * start.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * end.y
        return CGPoint(x: x, y: y)
    }

    private func cable(from start: CGPoint, to end: CGPoint) -> Path {
        var path = Path()
        path.move(to: start)
        let mid = (start.x + end.x) / 2
        path.addCurve(to: end, control1: CGPoint(x: mid, y: start.y), control2: CGPoint(x: mid, y: end.y))
        return path
    }

    private func appRow(_ app: AudioApp, index: Int, width: CGFloat) -> some View {
        let volume = model.appVolume(for: app.bundleID)
        return HStack(spacing: 8) {
            if let icon = model.processes.icon(for: app.bundleID) {
                Image(nsImage: icon).resizable().frame(width: 24, height: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name.uppercased()).font(Theme.mono(10)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(app.isPlaying ? String(localized: "ИГРАЕТ") : String(localized: "ТИХО"))
                        .foregroundStyle(app.isPlaying ? Theme.accent : Theme.muted)
                    if model.routes(for: app.bundleID) == nil {
                        Text("ВСЕ")
                            .foregroundStyle(Theme.muted)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.line, lineWidth: 1))
                    }
                }
                .font(Theme.mono(8))
            }
            Spacer(minLength: 0)
            Text("\(Int((volume * 100).rounded()))%")
                .font(Theme.mono(9))
                .foregroundStyle(volume == 1 ? Theme.muted : Theme.accent)
                .frame(width: 38, alignment: .trailing)
                .contentTransition(.numericText())
            Knob(value: Double(volume * 100), range: 0...150, size: 22, step: 1, sensitivity: 220, leds: 11) {
                model.setAppVolume(Float($0) / 100, for: app.bundleID)
            }
            .frame(width: 42, height: 42)
            .onTapGesture(count: 2) { model.setAppVolume(1, for: app.bundleID) }
            JackView(size: 18)
                .padding(.trailing, 5)
        }
        .padding(.leading, 10)
        .frame(width: appWidth, height: rowHeight)
        .panel()
        .contextMenu {
            ForEach(outputs, id: \.self) { uid in
                Button {
                    model.toggleRoute(app.bundleID, to: uid)
                } label: {
                    let active = model.routes(for: app.bundleID)?.contains(uid) ?? false
                    Text((active ? "✓ " : "   ") + model.name(of: uid))
                }
            }
            Divider()
            Button("Как по умолчанию") { model.resetRoute(app.bundleID) }
            Button("Громкость 100%") { model.setAppVolume(1, for: app.bundleID) }
        }
    }

    private func outputRow(_ uid: String, index: Int, highlighted: Bool) -> some View {
        let missing = model.devices.device(uid: uid) == nil
        return HStack(spacing: 9) {
            JackView(size: 18)
            Text(model.name(of: uid).uppercased())
                .font(Theme.mono(10))
                .lineLimit(1)
                .foregroundStyle(missing ? Theme.muted : Theme.ink)
            Spacer(minLength: 0)
            Circle()
                .fill(Theme.cableColor(index))
                .frame(width: 7, height: 7)
                .shadow(color: Theme.cableColor(index).opacity(0.8), radius: 2.5)
        }
        .padding(.horizontal, 10)
        .frame(width: outputWidth, height: rowHeight)
        .panel()
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.accent, lineWidth: highlighted ? 1.5 : 0)
                .shadow(color: Theme.accent.opacity(highlighted ? 0.6 : 0), radius: 6)
        }
        .animation(.easeOut(duration: 0.15), value: highlighted)
    }
}
