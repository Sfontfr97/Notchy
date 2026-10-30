import AppKit

/// Runs when Claude Code calls `Notchy hook`. Reads the hook JSON from stdin,
/// updates that session's status file and exits. Never prints, never fails the hook.
enum Hook {
    static func run() {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = obj["session_id"] as? String,
            let event = obj["hook_event_name"] as? String
        else { return }

        let url = Paths.file(for: id)
        let now = Date().timeIntervalSince1970
        let cwd = obj["cwd"] as? String ?? ""

        if event == "SessionEnd" {
            try? FileManager.default.removeItem(at: url)
            return
        }

        var info = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(SessionInfo.self, from: $0) }
            ?? SessionInfo(id: id, project: "", cwd: cwd, state: .working, detail: nil,
                           app: hostApp(), started: now, updated: now)

        switch event {
        case "UserPromptSubmit":
            info.state = .working
            info.detail = nil
            info.activity = nil
            info.summary = nil
            info.tool = nil
            info.streak = nil
            info.started = now
            let prompt = (obj["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            info.isCommand = prompt.hasPrefix("/") || prompt.hasPrefix("<command-name>")
            reopenAppIfClosed()
        case "PreToolUse":
            let tool = obj["tool_name"] as? String ?? ""
            let input = obj["tool_input"] as? [String: Any] ?? [:]
            info.streak = info.tool == tool ? (info.streak ?? 1) + 1 : 1
            info.tool = tool
            info.activity = activity(tool: tool, input: input, streak: info.streak ?? 1)
            if info.state != .waiting { info.state = .working }
        case "PostToolUse":
            // A tool ran, so any approval was given.
            if info.state != .working { info.state = .working; info.detail = nil }
        case "PermissionRequest":
            Approvals.handle(obj: obj, info: &info)
            return
        case "Notification":
            let message = obj["message"] as? String ?? ""
            // The idle reminder after a finished turn is not a request: keep "done".
            if info.state == .done && !message.lowercased().contains("permission") { return }
            if info.state == .waiting && info.detail != nil { return }   // PermissionRequest already said what
            info.state = .waiting
            info.detail = message
        case "Stop":
            if info.state != .done { Tally.append(seconds: now - info.started) }
            info.state = .done
            info.detail = nil
            info.activity = nil
            let last = obj["last_assistant_message"] as? String
                ?? (obj["transcript_path"] as? String).flatMap(lastAssistantText)
            info.summary = last.flatMap(firstLine)
        default:
            return
        }

        if let path = obj["transcript_path"] as? String { info.transcript = path }
        if !cwd.isEmpty { info.cwd = cwd }
        info.project = URL(fileURLWithPath: info.cwd).lastPathComponent
        info.updated = now
        info.write()
    }

    /// A few words on what a tool call is doing: "Editing Island.swift", "Reading 3 files".
    static func activity(tool: String, input: [String: Any], streak: Int) -> String {
        let path = (input["file_path"] ?? input["notebook_path"] ?? input["path"]) as? String
        let file = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "a file"
        switch tool {
        case "Read": return streak > 1 ? "Reading \(streak) files" : "Reading \(file)"
        case "Edit", "MultiEdit", "NotebookEdit": return streak > 1 ? "Editing \(streak) files" : "Editing \(file)"
        case "Write": return "Writing \(file)"
        case "Bash":
            if let d = input["description"] as? String, !d.isEmpty { return d }
            let cmd = (input["command"] as? String ?? "").split(separator: " ").first.map(String.init) ?? "a command"
            return "Running \(cmd)"
        case "Grep", "Glob": return "Searching the code"
        case "WebSearch": return "Searching the web"
        case "WebFetch": return "Reading a web page"
        case "Agent", "Task": return "Working with a helper"
        case "TodoWrite": return "Planning the next steps"
        case "Skill": return "Using a skill"
        default:
            if tool.hasPrefix("mcp__") {
                // mcp__<server>__<tool>: "search_discussions" reads as "search discussions"
                let name = tool.components(separatedBy: "__").last ?? tool
                return "Using \(name.replacingOccurrences(of: "[_-]", with: " ", options: .regularExpression))"
            }
            return "Using \(tool)"
        }
    }

    /// The last thing Claude wrote, read from the end of the transcript.
    static func lastAssistantText(_ path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let size = h.seekToEndOfFile()
        h.seek(toFileOffset: size > 262_144 ? size - 262_144 : 0)
        let text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        for line in text.split(separator: "\n").reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            let parts = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            let joined = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { return joined }
        }
        return nil
    }

    /// First sentence of a reply, without markdown, short enough for one line.
    static func firstLine(_ text: String) -> String? {
        let line = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("```") && !$0.hasPrefix("|") } ?? ""
        var clean = line.replacingOccurrences(of: "[*_`#>]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // Keep whole sentences until there's enough to say something ("Done." alone says nothing).
        var cut = clean.startIndex
        while let end = clean.range(of: "[.!?](\\s|$)", options: .regularExpression, range: cut..<clean.endIndex) {
            cut = clean.index(after: end.lowerBound)
            if clean.distance(from: clean.startIndex, to: cut) >= 16 { break }
        }
        if cut > clean.startIndex { clean = String(clean[..<cut]) }
        if clean.count > 90 { clean = String(clean.prefix(88)).trimmingCharacters(in: .whitespaces) + "…" }
        return clean.isEmpty ? nil : clean
    }

    /// If Notchy crashed or was closed by something other than Quit, bring it back quietly.
    private static func reopenAppIfClosed() {
        guard !Paused.isOn, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let me = getpid()
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.sergifont.notchy")
            .contains { $0.processIdentifier != me }
        guard !running else { return }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", Bundle.main.bundleURL.path]
        try? open.run()
    }

    /// Which app to bring forward when the session is clicked.
    private static func hostApp() -> String {
        let env = ProcessInfo.processInfo.environment
        switch env["TERM_PROGRAM"] ?? "" {
        case "Apple_Terminal": return "com.apple.Terminal"
        case "iTerm.app": return "com.googlecode.iterm2"
        case "vscode": return env["CURSOR_TRACE_ID"] != nil ? "com.todesktop.230313mzl4w4u92" : "com.microsoft.VSCode"
        case "ghostty": return "com.mitchellh.ghostty"
        case "WarpTerminal": return "dev.warp.Warp-Stable"
        default: return "com.anthropic.claudefordesktop"
        }
    }
}
