import Foundation

enum HookInstaller {
    static let settings = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    static let events = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Notification", "Stop", "SessionEnd"]
    /// The permission hook waits for your answer from the notch; the rest return at once.
    static func timeout(_ event: String) -> Int { event == "PermissionRequest" ? Int(Approvals.wait) + 10 : 5 }

    /// Runs the binary inside the app wherever it lives; does nothing if the app was removed.
    static var command: String {
        let bin = Bundle.main.executablePath ?? "/Applications/Notchy.app/Contents/MacOS/Notchy"
        return "[ -x \"\(bin)\" ] && \"\(bin)\" hook || true"
    }

    /// Connected at all (any Notchy hook present).
    static var isInstalled: Bool { !installedEvents.isEmpty }

    /// Connected with every event this version uses. False after an update adds a new one.
    static var isCurrent: Bool { Set(events).isSubset(of: installedEvents) }

    static var installedEvents: Set<String> {
        guard let data = try? Data(contentsOf: settings),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return [] }
        return Set(hooks.compactMap { event, value in
            let groups = value as? [[String: Any]] ?? []
            let ours = groups.contains { g in
                (g["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String ?? "").contains("Notchy") }
            }
            return ours ? event : nil
        })
    }

    static func install() throws {
        let fm = FileManager.default
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: settings) {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "Notchy", code: 1, userInfo: [NSLocalizedDescriptionKey: "settings.json isn't a JSON object."])
            }
            root = obj
            let backup = settings.deletingLastPathComponent().appendingPathComponent("settings.json.notchy-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: settings, to: backup)
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            let already = groups.contains { g in
                (g["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String ?? "").contains("Notchy") }
            }
            if !already {
                groups.append(["hooks": [["type": "command", "command": command, "timeout": timeout(event)]]])
            }
            hooks[event] = groups
        }
        root["hooks"] = hooks
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try fm.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try out.write(to: settings, options: .atomic)
    }
}

/// A 25 second story with three made-up sessions, for showing Notchy off.
enum Demo {
    static func run() {
        let now = Date().timeIntervalSince1970
        func put(_ id: String, _ project: String, _ state: SessionState, _ detail: String? = nil, started: Double,
                 activity: String? = nil, summary: String? = nil) {
            var s = SessionInfo(id: "demo-" + id, project: project, cwd: "/demo/" + project, state: state, detail: detail,
                                app: "com.anthropic.claudefordesktop", started: started, updated: Date().timeIntervalSince1970)
            s.activity = activity
            s.summary = summary
            s.write()
        }
        func ask(_ summary: String) {
            try? FileManager.default.createDirectory(at: Approvals.requests, withIntermediateDirectories: true)
            let r = Approvals.Request(session: "demo-b", tool: "Bash", summary: summary, at: Date().timeIntervalSince1970)
            try? JSONEncoder().encode(r).write(to: Approvals.requests.appendingPathComponent(Approvals.fileName("demo-b")))
        }
        func unask() {
            try? FileManager.default.removeItem(at: Approvals.requests.appendingPathComponent(Approvals.fileName("demo-b")))
            try? FileManager.default.removeItem(at: Approvals.answers.appendingPathComponent(Approvals.fileName("demo-b")))
        }
        func at(_ t: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }

        put("a", "community-redesign", .working, started: now - 312, activity: "Editing Hero.tsx")
        at(1.5) { put("b", "signal", .working, started: now, activity: "Reading 3 files") }
        at(4) { ask("Run npm test"); put("b", "signal", .waiting, "Run npm test", started: now) }
        at(11) { unask(); put("b", "signal", .working, started: now, activity: "Run the test suite") }
        at(14) { put("a", "community-redesign", .done, started: now - 312, summary: "Hero redesign is in, all checks pass.") }
        at(19) { put("b", "signal", .done, started: now, summary: "All 42 tests pass.") }
        at(26) {
            unask()
            for id in ["a", "b"] { try? FileManager.default.removeItem(at: Paths.file(for: "demo-" + id)) }
        }
    }
}
