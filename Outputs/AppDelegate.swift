import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case outputs
    case apps
    case equalizer
    case sync
    case general
    case whatsNew

    var id: String { rawValue }

    var title: String {
        switch self {
        case .outputs: String(localized: "ВЫХОДЫ")
        case .apps: String(localized: "ПРИЛОЖЕНИЯ")
        case .equalizer: String(localized: "ЭКВАЛАЙЗЕР")
        case .sync: String(localized: "СИНХРОН")
        case .general: String(localized: "ОСНОВНЫЕ")
        case .whatsNew: String(localized: "ЧТО НОВОГО")
        }
    }
}

@Observable
final class WindowRouter {
    var settingsTab: SettingsTab = .outputs

    @ObservationIgnored weak var delegate: AppDelegate?

    func openSettings(_ tab: SettingsTab) {
        settingsTab = tab
        delegate?.showSettings()
    }

    func openTest() {
        delegate?.showTest()
    }

    func openOnboarding() {
        delegate?.showOnboarding()
    }

    func closeTest() {
        delegate?.closeWindow(\.testWindow)
    }

    func closeOnboarding() {
        delegate?.closeWindow(\.onboardingWindow)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    let router = WindowRouter()

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var pulseTimer: Timer?
    private var pulsePhase: CGFloat = 0
    fileprivate var settingsWindow: NSWindow?
    fileprivate var testWindow: NSWindow?
    fileprivate var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        router.delegate = self
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(statusClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: PopoverView(model: model, router: router))

        model.onStateChange = { [weak self] in self?.refreshIcon() }
        model.start()
        model.updates.start()
        refreshIcon()
        if !model.settings.onboardingDone {
            showOnboarding()
        }
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["OUTPUTS_LIGHT"] != nil {
            NSApp.appearance = NSAppearance(named: .aqua)
        }
        if environment["OUTPUTS_POPOVER"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.togglePopover() }
        }
        if let tab = environment["OUTPUTS_SETTINGS"].flatMap(SettingsTab.init(rawValue:)) {
            router.openSettings(tab)
        }
        if environment["OUTPUTS_TEST"] != nil {
            showTest()
        }
        if environment["OUTPUTS_ONBOARDING"] != nil {
            showOnboarding()
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate()
            let match = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ?? .darkAqua
            popover.appearance = NSApp.appearance ?? NSAppearance(named: match)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let toggle = NSMenuItem(title: model.isOn ? String(localized: "Выключить") : String(localized: "Включить"), action: #selector(toggleOutputs), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: String(localized: "Настройки…"), action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: String(localized: "Выйти из Outputs"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func toggleOutputs() {
        model.toggle()
    }

    @objc private func openSettingsFromMenu() {
        router.openSettings(.outputs)
    }

    private func refreshIcon() {
        let playing = model.isPlaying
        if playing, pulseTimer == nil {
            pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.pulsePhase += 0.35
                    self?.drawIcon()
                }
            }
        } else if !playing {
            pulseTimer?.invalidate()
            pulseTimer = nil
        }
        drawIcon()
    }

    private func drawIcon() {
        let state: StatusIcon.State
        if model.isPlaying {
            let level = CGFloat(min(model.peakLevel * 1.6, 1))
            state = .playing(0.35 + 0.65 * level * (0.6 + 0.4 * (sin(pulsePhase) + 1) / 2))
        } else if model.status == .running || model.status == .starting {
            state = .on
        } else {
            state = .off
        }
        statusItem?.button?.image = StatusIcon.image(state: state, missing: model.isOn && !model.missingOutputs.isEmpty)
    }

    func showSettings() {
        popover.performClose(nil)
        present(\.settingsWindow, title: String(localized: "Outputs · Настройки"), size: NSSize(width: 880, height: 640), resizable: true) {
            SettingsView(model: self.model, router: self.router)
        }
    }

    func showTest() {
        popover.performClose(nil)
        present(\.testWindow, title: String(localized: "Тест синхронизации"), size: NSSize(width: 560, height: 520), resizable: false) {
            SyncTestView(model: self.model, router: self.router)
        }
    }

    func showOnboarding() {
        popover.performClose(nil)
        present(\.onboardingWindow, title: "Outputs", size: NSSize(width: 620, height: 560), resizable: false) {
            OnboardingView(model: self.model, router: self.router)
        }
    }

    fileprivate func closeWindow(_ keyPath: ReferenceWritableKeyPath<AppDelegate, NSWindow?>) {
        self[keyPath: keyPath]?.close()
    }

    private func present<Content: View>(
        _ keyPath: ReferenceWritableKeyPath<AppDelegate, NSWindow?>,
        title: String,
        size: NSSize,
        resizable: Bool,
        content: @escaping () -> Content
    ) {
        NSApp.activate()
        if let window = self[keyPath: keyPath] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        var style: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]
        if resizable {
            style.insert(.resizable)
            style.insert(.miniaturizable)
        }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(Theme.background)
        window.contentView = NSHostingView(rootView: content())
        window.setContentSize(size)
        if resizable {
            window.contentMinSize = size
        }
        window.center()
        window.delegate = self
        self[keyPath: keyPath] = window
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window == testWindow {
            model.setTesting(false)
            testWindow = nil
        } else if window == settingsWindow {
            settingsWindow = nil
        } else if window == onboardingWindow {
            onboardingWindow = nil
            model.finishOnboarding()
        }
    }
}
