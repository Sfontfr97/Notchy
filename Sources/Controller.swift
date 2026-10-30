import AppKit
import SwiftUI

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// One island on one display. The MacBook screen gets the notch; other displays get a slim
/// island centered in their menu bar.
final class IslandController {
    let ui = IslandUI()
    let panel: IslandPanel
    let screen: NSScreen
    let store: SessionStore
    private var peekWork: DispatchWorkItem?
    private var swipe: CGFloat = 0
    static let size = CGSize(width: 520, height: 420)

    init(screen: NSScreen, store: SessionStore, app: AppDelegate) {
        self.screen = screen
        self.store = store
        panel = IslandPanel(contentRect: CGRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        let view = IslandView(store: store, ui: ui,
                              activate: { [weak app] s in app?.activate(s) },
                              playDemo: { [weak app, weak ui] in ui?.hovering = false; app?.runDemo() },
                              showMenu: { [weak app, weak self] in if let self { app?.popMenu(from: self) } },
                              dismiss: { [weak store] s in store?.dismiss(s) },
                              answer: { [weak app] s, a in app?.answer(s, a) })
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: Self.size)
        panel.contentView = host
        place()
        panel.orderFrontRegardless()
    }

    func place() {
        if screen.safeAreaInsets.top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            ui.notchWidth = screen.frame.width - l.width - r.width
            ui.topHeight = screen.safeAreaInsets.top
        } else {
            ui.notchWidth = 120
            let bar = screen.frame.maxY - screen.visibleFrame.maxY
            ui.topHeight = bar > 0 ? bar : 24   // menu bar hidden on this display
        }
        panel.setFrameOrigin(CGPoint(x: screen.frame.midX - Self.size.width / 2, y: screen.frame.maxY - Self.size.height))
    }

    /// The part of the panel the island covers right now, in screen coordinates.
    var islandRect: CGRect {
        let size = Metrics.size(ui: ui, rows: store.sessions.count)
        let f = panel.frame
        return CGRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height)
    }

    func track(_ mouse: CGPoint) {
        let inside: Bool
        if store.sessions.isEmpty && !ui.open {
            // Nothing running: only the notch itself opens the island, so the menu bar stays usable.
            let f = panel.frame
            inside = CGRect(x: f.midX - ui.notchWidth / 2, y: f.maxY - ui.topHeight,
                            width: ui.notchWidth, height: ui.topHeight).contains(mouse)
        } else {
            inside = islandRect.insetBy(dx: -4, dy: -4).contains(mouse)
        }
        if inside != ui.hovering {
            ui.hovering = inside
            if inside { peekWork?.cancel(); ui.peeking = false }
            else { ui.holdClosed = false }
        }
        panel.ignoresMouseEvents = !inside
    }

    func peek(for seconds: Double) {
        peekWork?.cancel()
        ui.peeking = true
        let w = DispatchWorkItem { [weak self] in self?.ui.peeking = false }
        peekWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    func close() {
        peekWork?.cancel()
        ui.peeking = false
        ui.pinned = false
        ui.hovering = false
    }

    /// Two fingers down pins the island open; two fingers up closes it.
    func scrolled(_ e: NSEvent) {
        if e.phase == .began { swipe = 0 }
        // Count finger movement, whatever the natural scrolling setting.
        swipe += e.isDirectionInvertedFromDevice ? e.scrollingDeltaY : -e.scrollingDeltaY
        guard abs(swipe) > 28 else { return }
        if swipe > 0 {
            ui.holdClosed = false
            ui.pinned = true
        } else {
            peekWork?.cancel()
            ui.peeking = false
            ui.pinned = false
            ui.holdClosed = true
        }
        swipe = 0
    }
}
