import Foundation

enum SessionState: String, Codable {
    case working, waiting, done
}

struct SessionInfo: Codable, Identifiable, Equatable {
    var id: String
    var project: String
    var cwd: String
    var state: SessionState
    var detail: String?
    var app: String?          // bundle id of the app the session runs in
    var started: Double       // start of the current turn
    var updated: Double
    var title: String? = nil  // the chat's title in the Claude app, filled in by the app
    var activity: String? = nil   // what Claude is doing right now, from the last tool call
    var summary: String? = nil    // Claude's last line when the turn finished
    var tool: String? = nil       // last tool name, to group repeated reads
    var streak: Int? = nil        // how many times in a row that tool ran
    var isCommand: Bool? = nil    // the turn began with a slash command, which may never reach Claude
    var transcript: String? = nil // the chat's transcript file, to tell a quiet chat from a dead one
}

enum Paths {
    static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Notchy", isDirectory: true)
    static let sessions = support.appendingPathComponent("sessions", isDirectory: true)

    static func ensure() {
        try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    }

    static func file(for id: String) -> URL {
        let safe = id.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        return sessions.appendingPathComponent(safe + ".json")
    }
}

extension SessionInfo {
    /// The chat title when the Claude app has one, otherwise the folder name.
    var name: String { title ?? (project.isEmpty ? "Claude" : project) }
    /// Folder shown under a titled chat, so two chats in one folder stay apart.
    var place: String? { title == nil || project.isEmpty ? nil : project }

    func write() {
        Paths.ensure()
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Paths.file(for: id), options: .atomic)
    }

    /// One short line for the expanded island and the menu.
    var statusLine: String {
        switch state {
        case .working: return activity ?? "Working"
        case .done: return summary ?? "Done"
        case .waiting:
            guard let d = detail, !d.isEmpty else { return "Needs you" }
            if !d.hasPrefix("Claude ") && !d.lowercased().contains("waiting") { return "Wants to " + d.prefix(1).lowercased() + d.dropFirst() }
            if let r = d.range(of: "permission to use ") { return "Needs your OK for " + d[r.upperBound...] }
            if d.lowercased().contains("waiting for your input") { return "Waiting for your reply" }
            return d
        }
    }
}

func shortDuration(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60) min" }
    return "\(s / 3600)h \(s % 3600 / 60)m"
}
