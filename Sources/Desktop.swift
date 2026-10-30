import Foundation

/// Reads the Claude app's own session files to pair a hook's session id with the app's
/// `local_…` id (for opening the exact chat) and its title. Re-reads only files that changed.
final class DesktopSessions {
    struct Entry { let localId: String; let title: String? }

    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)

    private var byCli: [String: Entry] = [:]
    private var seen: [String: Date] = [:]       // file path -> modification date already read
    private var lastScan = Date.distantPast

    func entry(for cliId: String) -> Entry? {
        if byCli[cliId] == nil || Date().timeIntervalSince(lastScan) > 10 { scan() }
        return byCli[cliId]
    }

    /// The link that opens this chat in the Claude app.
    func link(for cliId: String) -> URL? {
        guard let local = entry(for: cliId)?.localId else { return nil }
        return URL(string: "claude://code/continue?session=\(local)&source=notchy")
    }

    private func scan() {
        lastScan = Date()
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: Self.root, includingPropertiesForKeys: [.contentModificationDateKey],
                                         options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in walker {
            let name = url.lastPathComponent
            guard name.hasPrefix("local_"), url.pathExtension == "json" else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if seen[url.path] == modified { continue }
            seen[url.path] = modified
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cli = obj["cliSessionId"] as? String,
                  let local = obj["sessionId"] as? String,
                  local.range(of: "^local_[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil
            else { continue }
            let title = (obj["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            byCli[cli] = Entry(localId: local, title: title)
        }
    }
}
