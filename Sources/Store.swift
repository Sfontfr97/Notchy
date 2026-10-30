import AppKit
import Combine

/// Watches the sessions folder and publishes what is running.
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [SessionInfo] = []
    @Published private(set) var requests: [String: Approvals.Request] = [:]   // session id -> waiting for Allow/Deny
    let desktop = DesktopSessions()
    var onChange: ((_ old: SessionInfo?, _ new: SessionInfo) -> Void)?

    private var timer: Timer?
    private var first = true

    func start() {
        Paths.ensure()
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.load() }
    }

    var working: [SessionInfo] { sessions.filter { $0.state == .working } }
    var waiting: [SessionInfo] { sessions.filter { $0.state == .waiting } }
    var done: [SessionInfo] { sessions.filter { $0.state == .done } }
    var isBusy: Bool { !working.isEmpty || !waiting.isEmpty }

    /// The one state the collapsed island shows: needs you beats working beats done.
    var headline: SessionState? {
        if !waiting.isEmpty { return .waiting }
        if !working.isEmpty { return .working }
        if !done.isEmpty { return .done }
        return nil
    }

    /// Used by `Notchy snapshot` to render fixed states.
    func preview(_ list: [SessionInfo], requests: [String: Approvals.Request] = [:]) {
        sessions = list
        self.requests = requests
    }

    func dismiss(_ s: SessionInfo) {
        try? FileManager.default.removeItem(at: Paths.file(for: s.id))
        load()
    }

    func clear(onlyFinished: Bool) {
        for s in sessions where !onlyFinished || s.state == .done {
            try? FileManager.default.removeItem(at: Paths.file(for: s.id))
        }
        load()
    }

    func reload() { load() }

    /// "Working" with no hook event and no transcript change for 10 minutes: the turn ended without a Stop
    /// (interrupted, or it never reached Claude).
    private func isDead(_ s: SessionInfo, age: Double) -> Bool {
        guard s.state == .working, age > 600 else { return false }
        guard let path = s.transcript,
              let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        else { return true }
        return Date().timeIntervalSince(modified) > 600
    }

    func load() {
        let fm = FileManager.default
        let now = Date().timeIntervalSince1970
        let pending = Approvals.pending()
        if Set(pending.keys) != Set(requests.keys) { requests = pending }
        let files = (try? fm.contentsOfDirectory(at: Paths.sessions, includingPropertiesForKeys: nil)) ?? []
        var next: [SessionInfo] = []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  var s = try? JSONDecoder().decode(SessionInfo.self, from: data) else { continue }
            if s.app == "com.anthropic.claudefordesktop" { s.title = desktop.entry(for: s.id)?.title }
            // Finished sessions fade after 15 minutes; anything silent for 3 hours probably crashed.
            let age = now - s.updated
            // A session whose app has quit can't be running any more.
            let appGone = !s.id.hasPrefix("demo-") && s.app.map {
                NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
            } ?? false
            if (s.state == .done && age > 15 * 60) || age > 3 * 3600 || appGone || isDead(s, age: age) {
                try? fm.removeItem(at: url)
                continue
            }
            // A slash command (a mod's background check, /clear, /model…) that led to no Claude
            // activity isn't work in progress: keep it out of sight until something happens.
            if s.state == .working && s.isCommand == true && s.tool == nil && age > 20 { continue }
            next.append(s)
        }
        // Needs you first, then working, then done; newest first inside each group.
        let rank: [SessionState: Int] = [.waiting: 0, .working: 1, .done: 2]
        next.sort { (rank[$0.state]!, -$0.updated) < (rank[$1.state]!, -$1.updated) }
        guard next != sessions else { return }

        let old = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        sessions = next
        if first { first = false; return }
        for s in next where old[s.id]?.state != s.state { onChange?(old[s.id], s) }
    }
}
