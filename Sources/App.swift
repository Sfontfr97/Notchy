import AppKit
import SwiftUI
import IOKit.pwr_mgt
import ServiceManagement
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = SessionStore()
    var islands: [IslandController] = []
    var statusItem: NSStatusItem!
    var mouseTimer: Timer?
    var slowTimer: Timer?
    var sleepAssertion: IOPMAssertionID = 0
    var reminded: Set<String> = []
    var bag = Set<AnyCancellable>()
    let defaults = UserDefaults.standard

    var keepAwake: Bool { defaults.object(forKey: "keepAwake") as? Bool ?? true }
    var quietInCalls: Bool { defaults.object(forKey: "quietInCalls") as? Bool ?? true }
    var allDisplays: Bool { defaults.object(forKey: "allDisplays") as? Bool ?? true }
    var remind: Bool { defaults.object(forKey: "remind") as? Bool ?? true }
    var waitingSound: String { defaults.string(forKey: "soundWaiting") ?? "Purr" }
    var doneSound: String { defaults.string(forKey: "soundDone") ?? "Glass" }

    func applicationDidFinishLaunching(_ note: Notification) {
        if moveOutOfDiskImageIfNeeded() { return }
        Paused.set(false)
        makeIslands()
        makeStatusItem()
        store.onChange = { [weak self] old, new in self?.changed(old: old, new: new) }
        store.start()
        // @Published fires before the value changes, so read it on the next run loop pass.
        store.$sessions.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &bag)
        NotificationCenter.default.addObserver(self, selector: #selector(makeIslands),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(toggleIsland), name: Hotkey.pressed, object: nil)
        Hotkey.register()
        // Poll the pointer instead of a global monitor: needs no permissions.
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 1 / 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            let mouse = NSEvent.mouseLocation
            self.islands.forEach { $0.track(mouse) }
        }
        slowTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.remindIfWaiting(); self?.refresh() }
        // Swipes reach us only while the pointer is over an island (the panel takes events then).
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            self?.islands.first { $0.panel === e.window }?.scrolled(e)
            return e
        }
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.welcomeIfNeeded() }
    }

    // MARK: Islands

    /// One island per display (or only the notch screen), rebuilt when displays change.
    @objc func makeIslands() {
        islands.forEach { $0.panel.orderOut(nil) }
        let notched = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
        let screens = allDisplays ? NSScreen.screens : [notched ?? NSScreen.main ?? NSScreen.screens[0]]
        islands = screens.map { IslandController(screen: $0, store: store, app: self) }
        refresh()
    }

    /// The island where the pointer is, or the main one.
    var focusedIsland: IslandController? {
        let mouse = NSEvent.mouseLocation
        return islands.first { $0.screen.frame.contains(mouse) } ?? islands.first
    }

    func peekAll(_ seconds: Double) { islands.forEach { $0.peek(for: seconds) } }

    /// Control-Option-N: open the island for a few seconds, or close it.
    @objc func toggleIsland() {
        guard let island = focusedIsland else { return }
        if island.ui.open { islands.forEach { $0.close() } }
        else { store.reload(); island.peek(for: 6) }
    }

    /// The menu bar icon can hide behind the notch, so the island opens the same menu.
    func popMenu(from island: IslandController? = nil) {
        guard let menu = statusItem.menu, let island = island ?? focusedIsland else { return }
        let f = island.islandRect
        menu.popUp(positioning: nil, at: CGPoint(x: f.maxX - 40, y: f.minY - 4), in: nil)
        island.ui.hovering = false
    }

    func activate(_ s: SessionInfo) {
        // Opening the chat hands a pending permission question back to Claude's own dialog.
        if store.requests[s.id] != nil { Approvals.answer(s.id, .pass) }
        let id = s.app ?? "com.anthropic.claudefordesktop"
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if id == "com.anthropic.claudefordesktop", let link = store.desktop.link(for: s.id),
           let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            // Opens the exact chat. Going through Launch Services also brings the app forward
            // reliably; a plain activate() can be ignored since macOS 14.
            NSWorkspace.shared.open([link], withApplicationAt: app, configuration: config)
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.openApplication(at: app, configuration: config)
        }
        if s.state == .done { store.dismiss(s) }
        islands.forEach { $0.close() }
    }

    func answer(_ s: SessionInfo, _ a: Approvals.Answer) {
        Approvals.answer(s.id, a)
        store.reload()
    }

    // MARK: State changes

    var quiet: Bool { quietInCalls && Calls.micInUse }

    func changed(old: SessionInfo?, new: SessionInfo) {
        // In a call the island still opens; only the sound stays off.
        switch new.state {
        case .waiting:
            if !quiet { Sounds.play(waitingSound) }
            peekAll(8)
        case .done where old != nil:
            if !quiet { Sounds.play(doneSound) }
            peekAll(5)
        default: break
        }
    }

    /// A chat that has waited five minutes gets one more nudge.
    func remindIfWaiting() {
        guard remind else { return }
        let now = Date().timeIntervalSince1970
        for s in store.waiting where now - s.updated > 300 {
            let key = "\(s.id)-\(Int(s.updated))"
            guard !reminded.contains(key) else { continue }
            reminded.insert(key)
            if !quiet { Sounds.play(waitingSound) }
            peekAll(8)
        }
    }

    func refresh() {
        // Keep the Mac awake while anything is working or waiting.
        let want = keepAwake && store.isBusy
        if want && sleepAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Claude is working" as CFString, &sleepAssertion)
        } else if !want && sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
        let tally = Tally.today()
        for island in islands {
            island.ui.keepingAwake = sleepAssertion != 0
            island.ui.tally = tally
        }
        updateStatusIcon()
    }

    // MARK: Menu bar

    func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon()
    }

    func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let (symbol, label): (String, String) = {
            switch store.headline {
            case .waiting: return ("exclamationmark.circle.fill", "Claude needs you")
            case .working: return ("circle.dotted.circle", "Claude is working")
            case .done: return ("checkmark.circle", "Claude is done")
            case nil: return ("circle.dashed", "Notchy")
            }
        }()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.toolTip = label
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }   // sound submenus share this delegate
        store.reload()
        menu.removeAllItems()
        if store.sessions.isEmpty {
            menu.addItem(withTitle: "No Claude sessions right now", action: nil, keyEquivalent: "")
        } else {
            for s in store.sessions {
                let item = item("\(s.name)  ·  \(s.statusLine)", #selector(openSession(_:)))
                item.representedObject = s.id
                menu.addItem(item)
            }
        }
        if let t = Tally.today() { menu.addItem(withTitle: t, action: nil, keyEquivalent: "") }

        menu.addItem(.separator())
        let open = item("Open island", #selector(toggleIsland))
        open.keyEquivalent = "n"
        open.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(open)
        if !store.done.isEmpty { menu.addItem(item("Clear finished sessions", #selector(clearFinished))) }
        if !store.sessions.isEmpty { menu.addItem(item("Clear all sessions", #selector(clearAll))) }
        menu.addItem(item("Restart Notchy", #selector(restart)))

        menu.addItem(.separator())
        menu.addItem(toggle("Keep Mac awake while Claude works", on: keepAwake, #selector(toggleAwake)))
        menu.addItem(toggle("Quiet during calls", on: quietInCalls, #selector(toggleQuiet)))
        menu.addItem(toggle("Remind me after 5 minutes", on: remind, #selector(toggleRemind)))
        menu.addItem(toggle("Show on all displays", on: allDisplays, #selector(toggleDisplays)))
        menu.addItem(soundMenu("Sound when Claude needs you", key: "soundWaiting", current: waitingSound))
        menu.addItem(soundMenu("Sound when Claude is done", key: "soundDone", current: doneSound))
        menu.addItem(toggle("Open at login", on: SMAppService.mainApp.status == .enabled, #selector(toggleLogin)))

        menu.addItem(.separator())
        let connected = HookInstaller.isCurrent
        let title = connected ? "Connected to Claude Code"
            : HookInstaller.isInstalled ? "Update Claude Code connection…" : "Connect to Claude Code…"
        let connect = item(title, connected ? nil : #selector(connectHooks))
        connect.state = connected ? .on : .off
        menu.addItem(connect)
        menu.addItem(item("Play a demo", #selector(runDemo)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Notchy", #selector(quit), key: "q"))
    }

    func item(_ title: String, _ action: Selector?, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    func toggle(_ title: String, on: Bool, _ action: Selector) -> NSMenuItem {
        let i = item(title, action)
        i.state = on ? .on : .off
        return i
    }

    func soundMenu(_ title: String, key: String, current: String) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for name in ["None"] + Sounds.choices {
            let i = item(name, #selector(pickSound(_:)))
            i.representedObject = [key, name]
            i.state = name == current ? .on : .off
            sub.addItem(i)
            if name == "None" { sub.addItem(.separator()) }
        }
        sub.delegate = self
        parent.submenu = sub
        return parent
    }

    /// Hovering a sound name plays it; clicking it saves it.
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard menu !== statusItem.menu, let pair = item?.representedObject as? [String] else { return }
        Sounds.play(pair[1])
    }

    @objc func pickSound(_ i: NSMenuItem) {
        guard let pair = i.representedObject as? [String] else { return }
        defaults.set(pair[1], forKey: pair[0])
    }

    @objc func openSession(_ i: NSMenuItem) {
        if let id = i.representedObject as? String, let s = store.sessions.first(where: { $0.id == id }) { activate(s) }
    }
    @objc func clearFinished() { store.clear(onlyFinished: true) }
    @objc func clearAll() { store.clear(onlyFinished: false) }
    @objc func toggleAwake() { defaults.set(!keepAwake, forKey: "keepAwake"); refresh() }
    @objc func toggleQuiet() { defaults.set(!quietInCalls, forKey: "quietInCalls") }
    @objc func toggleRemind() { defaults.set(!remind, forKey: "remind") }
    @objc func toggleDisplays() { defaults.set(!allDisplays, forKey: "allDisplays"); makeIslands() }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            alert("Couldn't change Open at login", "Move Notchy to your Applications folder and try again.")
        }
    }

    /// Starts a fresh copy, for when something looks stuck.
    @objc func restart() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.6; /usr/bin/open \"\(Bundle.main.bundleURL.path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }

    /// Quitting on purpose stops hooks from reopening Notchy until you open it again.
    @objc func quit() {
        Paused.set(true)
        NSApp.terminate(nil)
    }

    @objc func connectHooks() {
        let a = NSAlert()
        a.messageText = "Connect Notchy to Claude Code?"
        a.informativeText = "Notchy adds small hooks to ~/.claude/settings.json so it knows when a session is working, needs you or is done, and so you can answer permission requests from the notch. A backup of the file is saved next to it."
        a.addButton(withTitle: "Connect")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do { try HookInstaller.install(); alert("Connected", "New Claude Code sessions will show up in the notch.") }
        catch { alert("Couldn't connect", error.localizedDescription) }
    }

    @objc func runDemo() {
        islands.forEach { $0.ui.hovering = false }
        Demo.run()
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    // MARK: First launch, for teammates installing from the disk image

    /// Opened straight from the disk image: copy to Applications and relaunch from there.
    func moveOutOfDiskImageIfNeeded() -> Bool {
        let here = Bundle.main.bundleURL
        guard here.path.hasPrefix("/Volumes/") else { return false }
        let a = NSAlert()
        a.messageText = "Move Notchy to Applications?"
        a.informativeText = "Notchy needs to live in your Applications folder to keep working after you eject the disk image."
        a.addButton(withTitle: "Move to Applications")
        a.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { NSApp.terminate(nil); return true }
        let fm = FileManager.default
        let targets = [URL(fileURLWithPath: "/Applications"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        for dir in targets {
            let dest = dir.appendingPathComponent("Notchy.app")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)
            if (try? fm.copyItem(at: here, to: dest)) != nil {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", "sleep 0.6; /usr/bin/xattr -dr com.apple.quarantine \"\(dest.path)\" 2>/dev/null; /usr/bin/open \"\(dest.path)\""]
                try? p.run()
                NSApp.terminate(nil)
                return true
            }
        }
        alert("Couldn't move Notchy", "Drag Notchy from the disk image into your Applications folder, then open it from there.")
        NSApp.terminate(nil)
        return true
    }

    /// One-time welcome: connect to Claude Code, then show the demo.
    func welcomeIfNeeded() {
        guard !defaults.bool(forKey: "welcomed") else { return }
        defaults.set(true, forKey: "welcomed")
        let a = NSAlert()
        a.messageText = "Notchy lives in your notch"
        a.informativeText = HookInstaller.isCurrent
            ? "It shows when Claude is working, needs you or is done. Hover the notch or press Control-Option-N to open it."
            : "It shows when Claude is working, needs you or is done. To do that, Notchy adds small hooks to ~/.claude/settings.json (a backup is saved next to it).\n\nHover the notch or press Control-Option-N to open it."
        a.addButton(withTitle: HookInstaller.isCurrent ? "Show me" : "Connect and show me")
        a.addButton(withTitle: "Not now")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if !HookInstaller.isCurrent {
            do { try HookInstaller.install() } catch { alert("Couldn't connect", error.localizedDescription); return }
        }
        Demo.run()
    }
}
