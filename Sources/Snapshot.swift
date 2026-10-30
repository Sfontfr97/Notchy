import SwiftUI
import AppKit

/// `Notchy snapshot <folder>` draws the island in fixed states to PNGs, for docs and checks.
enum Snapshot {
    @MainActor
    static func render(to folder: String) {
        let now = Date().timeIntervalSince1970
        func s(_ id: String, _ p: String, _ st: SessionState, _ d: String? = nil, ago: Double) -> SessionInfo {
            SessionInfo(id: id, project: p, cwd: "/" + p, state: st, detail: d, app: nil, started: now - ago, updated: now - (st == .done ? 120 : 1))
        }
        var all = [
            s("b", "signal", .waiting, "Run npm test", ago: 48),
            s("a", "community-redesign", .working, ago: 312),
            s("c", "notchy", .done, ago: 600),
        ]
        all[0].title = "Feedback dashboard"
        all[1].title = "Hero redesign"
        all[1].activity = "Editing Hero.tsx"
        all[2].title = "Notchy polish"
        all[2].summary = "Built the DMG, 660 KB."
        let ask = ["b": Approvals.Request(session: "b", tool: "Bash", summary: "Run npm test", at: now)]
        let cases: [(String, [SessionInfo], Bool, Bool)] = [
            ("1-working", [all[1]], false, false),
            ("2-needs-you", [all[0], all[1]], false, false),
            ("3-done", [all[2]], false, false),
            ("4-open", all, true, true),
            ("5-empty", [], true, false),
        ]
        for (name, list, open, awake) in cases {
            let store = SessionStore()
            store.preview(list, requests: open ? ask : [:])
            let ui = IslandUI()
            ui.notchWidth = 185; ui.topHeight = 32; ui.hovering = open; ui.keepingAwake = awake
            if awake { ui.tally = "Claude worked 2h 14m today, 9 tasks" }
            let view = ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.55, green: 0.62, blue: 0.80), Color(red: 0.86, green: 0.80, blue: 0.86)],
                               startPoint: .top, endPoint: .bottom)
                Rectangle().fill(Color.white.opacity(0.55)).frame(height: 32)
                IslandView(store: store, ui: ui, activate: { _ in })
            }
            .frame(width: 560, height: open ? 260 : 64)
            .environment(\.colorScheme, .dark)
            let r = ImageRenderer(content: view)
            r.scale = 2
            guard let cg = r.cgImage else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            let url = URL(fileURLWithPath: folder).appendingPathComponent("island-\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print(url.path)
        }
    }

    /// The app icon: a dark tile with a lit island at the top.
    @MainActor
    static func icon(to path: String) {
        let art = ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.20, green: 0.21, blue: 0.25), Color(red: 0.04, green: 0.04, blue: 0.05)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 824, height: 824)
            VStack {
                ZStack {
                    Capsule().fill(Color.black).frame(width: 520, height: 150)
                        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 3))
                    HStack {
                        Circle().trim(from: 0, to: 0.72)
                            .stroke(Color.white, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                            .frame(width: 68, height: 68)
                            .rotationEffect(.degrees(-90))
                        Spacer()
                        ZStack {
                            Circle().fill(Palette.green).frame(width: 74, height: 74)
                            Image(systemName: "checkmark").font(.system(size: 38, weight: .heavy)).foregroundColor(.black)
                        }
                    }
                    .padding(.horizontal, 48)
                    .frame(width: 520)
                }
                .padding(.top, 170)
                Spacer()
            }
            .frame(width: 824, height: 824)
        }
        .frame(width: 1024, height: 1024)
        let r = ImageRenderer(content: art)
        r.scale = 1
        guard let cg = r.cgImage else { return }
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
