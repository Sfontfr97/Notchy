import AppKit

/// Approve from the notch. The PermissionRequest hook writes a request file and waits;
/// the island writes an answer file. If you're already in the app where Claude runs,
/// or you answer there, or nobody answers within two minutes, the hook steps aside
/// and Claude's normal permission dialog takes over.
enum Approvals {
    static let requests = Paths.support.appendingPathComponent("requests", isDirectory: true)
    static let answers = Paths.support.appendingPathComponent("answers", isDirectory: true)
    static let wait: TimeInterval = 120

    struct Request: Codable {
        let session: String; let tool: String; let summary: String; let at: Double
        var full: String? = nil   // the whole command or path, shown on hover
    }
    enum Answer: String, Codable { case allow, deny, pass }

    static func fileName(_ session: String) -> String {
        session.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression) + ".json"
    }

    // MARK: Island side

    static func pending() -> [String: Request] {
        let files = (try? FileManager.default.contentsOfDirectory(at: requests, includingPropertiesForKeys: nil)) ?? []
        var out: [String: Request] = [:]
        let now = Date().timeIntervalSince1970
        for url in files {
            guard let d = try? Data(contentsOf: url), let r = try? JSONDecoder().decode(Request.self, from: d) else { continue }
            if now - r.at > wait + 10 { try? FileManager.default.removeItem(at: url); continue }   // left behind by a killed hook
            out[r.session] = r
        }
        return out
    }

    static func answer(_ session: String, _ a: Answer) {
        try? FileManager.default.createDirectory(at: answers, withIntermediateDirectories: true)
        try? JSONEncoder().encode(a).write(to: answers.appendingPathComponent(fileName(session)), options: .atomic)
        try? FileManager.default.removeItem(at: requests.appendingPathComponent(fileName(session)))
    }

    // MARK: Hook side

    /// Runs inside the PermissionRequest hook. Prints a decision, or nothing to step aside.
    static func handle(obj: [String: Any], info: inout SessionInfo) {
        let tool = obj["tool_name"] as? String ?? "a tool"
        let input = obj["tool_input"] as? [String: Any] ?? [:]
        let summary = describe(tool: tool, input: input)
        let now = Date().timeIntervalSince1970

        info.state = .waiting
        info.detail = summary
        info.updated = now
        info.write()

        // Already looking at the app Claude runs in: answer there, as usual.
        if let host = info.app, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == host { return }

        let fm = FileManager.default
        try? fm.createDirectory(at: requests, withIntermediateDirectories: true)
        let reqURL = requests.appendingPathComponent(fileName(info.id))
        let ansURL = answers.appendingPathComponent(fileName(info.id))
        try? fm.removeItem(at: ansURL)
        let full = (input["command"] ?? input["file_path"] ?? input["url"]) as? String
        try? JSONEncoder().encode(Request(session: info.id, tool: tool, summary: summary, at: now, full: full)).write(to: reqURL, options: .atomic)
        defer { try? fm.removeItem(at: reqURL); try? fm.removeItem(at: ansURL) }

        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            if let d = try? Data(contentsOf: ansURL), let a = try? JSONDecoder().decode(Answer.self, from: d) {
                guard a != .pass else { return }
                print(decision(a))
                info.state = .working
                info.detail = nil
                info.activity = a == .allow ? info.activity : "Told not to \(summary.lowercased())"
                info.updated = Date().timeIntervalSince1970
                info.write()
                return
            }
            // Answered in Claude meanwhile: the session moved on without us.
            if let d = try? Data(contentsOf: Paths.file(for: info.id)),
               let s = try? JSONDecoder().decode(SessionInfo.self, from: d),
               s.updated > now, s.state != .waiting { return }
            if !fm.fileExists(atPath: Paths.file(for: info.id).path) { return }   // session ended
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    static func decision(_ a: Answer) -> String {
        var d: [String: Any] = ["behavior": a == .allow ? "allow" : "deny"]
        if a == .deny { d["message"] = "The user declined this from Notchy." }
        let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": d]]
        let data = (try? JSONSerialization.data(withJSONObject: out)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// "Run npm test", "Edit Island.swift", "Open example.com".
    static func describe(tool: String, input: [String: Any]) -> String {
        let path = (input["file_path"] ?? input["notebook_path"]) as? String
        let file = path.map { URL(fileURLWithPath: $0).lastPathComponent }
        switch tool {
        case "Bash":
            let cmd = (input["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let short = cmd.count > 46 ? String(cmd.prefix(44)) + "…" : cmd
            return short.isEmpty ? "Run a command" : "Run \(short)"
        case "Edit", "MultiEdit", "NotebookEdit": return "Edit \(file ?? "a file")"
        case "Write": return "Write \(file ?? "a file")"
        case "WebFetch":
            let host = (input["url"] as? String).flatMap { URL(string: $0)?.host } ?? "a web page"
            return "Open \(host)"
        case "WebSearch": return "Search the web"
        default:
            if tool.hasPrefix("mcp__") {
                let name = tool.components(separatedBy: "__").last ?? tool
                return "Use \(name.replacingOccurrences(of: "[_-]", with: " ", options: .regularExpression))"
            }
            return "Use \(tool)"
        }
    }
}
