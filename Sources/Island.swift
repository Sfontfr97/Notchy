import SwiftUI
import AppKit

final class IslandUI: ObservableObject {
    @Published var hovering = false
    @Published var peeking = false          // opens by itself for a few seconds after a change
    @Published var pinned = false           // swiped down: stays open until swiped up or clicked
    var holdClosed = false                  // swiped up while hovering: stay closed until the pointer leaves
    @Published var notchWidth: CGFloat = 190
    @Published var topHeight: CGFloat = 32
    @Published var keepingAwake = false
    @Published var tally: String?
    var hasFooter: Bool { keepingAwake || tally != nil }
    var open: Bool { (hovering && !holdClosed) || peeking || pinned }
}

enum Palette {
    static let amber = Color(red: 1.0, green: 0.70, blue: 0.25)
    static let green = Color(red: 0.20, green: 0.84, blue: 0.40)
    static let secondary = Color.white.opacity(0.66)
    static let rowHover = Color.white.opacity(0.09)

    /// One calm tint per project for the working spinner. Amber and green stay reserved
    /// for "needs you" and "done"; every tint passes 3:1 on black.
    static let tints: [Color] = [
        Color(red: 0.42, green: 0.66, blue: 1.00),   // blue
        Color(red: 0.75, green: 0.55, blue: 1.00),   // violet
        Color(red: 1.00, green: 0.48, blue: 0.71),   // pink
        Color(red: 0.31, green: 0.82, blue: 0.77),   // teal
        Color(red: 0.56, green: 0.61, blue: 1.00),   // indigo
        Color(red: 0.94, green: 0.94, blue: 0.96),   // white
    ]

    static func tint(for project: String) -> Color {
        // A stable hash (String.hashValue changes every launch).
        let h = project.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return tints[Int(h % UInt32(tints.count))]
    }
}

enum Metrics {
    static let wing: CGFloat = 38
    static let corner: CGFloat = 8          // concave corners where the island meets the bezel
    static let bottomRadius: CGFloat = 18
    static let row: CGFloat = 50
    static let openWidth: CGFloat = 400
    static let maxRows = 6                  // keeps the island inside its window

    static func size(ui: IslandUI, rows: Int) -> CGSize {
        if ui.open {
            let footer: CGFloat = ui.hasFooter ? 30 : 0
            return CGSize(width: max(openWidth, ui.notchWidth + 160),
                          height: ui.topHeight + 8 + CGFloat(min(max(rows, 1), maxRows)) * row + footer + 12)
        }
        return CGSize(width: ui.notchWidth + 2 * wing + 2 * corner, height: ui.topHeight)
    }
}

/// The black shape: flat top that melts into the bezel, rounded bottom.
struct IslandShape: Shape {
    var bottomRadius: CGFloat
    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = Metrics.corner, b = min(bottomRadius, rect.height / 2), w = rect.width, h = rect.height
        var p = Path()
        p.move(to: .zero)
        p.addQuadCurve(to: CGPoint(x: r, y: r), control: CGPoint(x: r, y: 0))
        p.addLine(to: CGPoint(x: r, y: h - b))
        p.addQuadCurve(to: CGPoint(x: r + b, y: h), control: CGPoint(x: r, y: h))
        p.addLine(to: CGPoint(x: w - r - b, y: h))
        p.addQuadCurve(to: CGPoint(x: w - r, y: h - b), control: CGPoint(x: w - r, y: h))
        p.addLine(to: CGPoint(x: w - r, y: r))
        p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - r, y: 0))
        p.closeSubpath()
        return p
    }
}

/// Shape and word for each state, so it never depends on color alone.
struct StateGlyph: View {
    let state: SessionState
    var size: CGFloat = 14
    var tint: Color = .white
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var body: some View {
        // Motion is drawn from the clock on every frame instead of a repeating animation,
        // so re-renders (the 1 s clock, new rows, the island's spring) can't restart or bend it.
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion || state == .done)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            glyph(at: t)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func glyph(at t: Double) -> some View {
        switch state {
        case .working:
            // One turn every 0.9 s
            let degrees = reduceMotion ? 0 : (t / 0.9).truncatingRemainder(dividingBy: 1) * 360
            Circle()
                .trim(from: 0, to: reduceMotion ? 1 : 0.72)
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: reduceMotion ? [2, 3] : []))
                .rotationEffect(.degrees(degrees))
                .animation(nil, value: degrees)
                .padding(1)
        case .waiting:
            // Breathes between 94% and 112%, 0.7 s each way
            let scale = reduceMotion ? 1 : 0.94 + 0.18 * (0.5 - 0.5 * cos(.pi * t / 0.7))
            ZStack {
                Circle().fill(Palette.amber)
                Text("!").font(.system(size: size * 0.72, weight: .heavy)).foregroundColor(.black)
            }
            .scaleEffect(scale)
            .animation(nil, value: scale)
        case .done:
            ZStack {
                Circle().fill(Palette.green)
                Image(systemName: "checkmark").font(.system(size: size * 0.5, weight: .bold)).foregroundColor(.black)
            }
        }
    }
}

struct IslandView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: IslandUI
    var activate: (SessionInfo) -> Void
    var playDemo: () -> Void = {}
    var showMenu: () -> Void = {}
    var dismiss: (SessionInfo) -> Void = { _ in }
    var answer: (SessionInfo, Approvals.Answer) -> Void = { _, _ in }
    @State private var hoveredRow: String?
    @State private var now = Date()
    @State private var appearedAt = Date()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let size = Metrics.size(ui: ui, rows: store.sessions.count)
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                IslandShape(bottomRadius: ui.open ? Metrics.bottomRadius : 10)
                    .fill(Color.black)
                    .shadow(color: .black.opacity(ui.open ? 0.35 : 0), radius: 18, y: 8)
                VStack(spacing: 0) {
                    collapsedBar
                    if ui.open { expanded.transition(.opacity) }
                }
                .padding(.horizontal, Metrics.corner)
            }
            .frame(width: size.width, height: size.height)
            .opacity(store.sessions.isEmpty && !ui.open ? 0 : 1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: ui.open)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: store.sessions.count)
        .onReceive(clock) { now = $0 }
        .onChange(of: ui.open) { _, open in
            if open { appearedAt = Date(); now = Date() }
            // Re-render once the guard has passed, without waiting for the next clock tick.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { now = Date() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
    }

    // Left wing: the headline state. Right wing: how many sessions.
    private var collapsedBar: some View {
        HStack(spacing: 0) {
            if let h = store.headline {
                StateGlyph(state: h, tint: store.sessions.first.map { Palette.tint(for: $0.project) } ?? .white)
            }
            Spacer(minLength: ui.notchWidth)
            if ui.open {
                // Settings live here whenever the island is open.
                Button(action: showMenu) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(0.14)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Notchy settings")
                .help("Settings")
            } else {
                Text(rightLabel)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundColor(store.headline == .waiting ? Palette.amber : .white)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: ui.topHeight)
    }

    private var rightLabel: String {
        if !store.waiting.isEmpty { return "\(store.waiting.count)" }
        if !store.working.isEmpty { return "\(store.working.count)" }
        return store.done.isEmpty ? "" : "Done"
    }

    private var expanded: some View {
        VStack(spacing: 0) {
            if store.sessions.isEmpty { emptyRow }
            ForEach(store.sessions.prefix(Metrics.maxRows)) { s in row(s) }
            if ui.hasFooter {
                HStack(spacing: 6) {
                    if let t = ui.tally { Text(t) }
                    Spacer(minLength: 8)
                    if ui.keepingAwake {
                        Image(systemName: "moon.zzz").font(.system(size: 11))
                        Text("Keeping Mac awake")
                    }
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(Palette.secondary)
                .frame(height: 30)
                .padding(.horizontal, 12)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 12)
        .padding(.horizontal, 8)
    }

    // What you see when you hover the notch with nothing running.
    private var emptyRow: some View {
        HStack(spacing: 8) {
            Text("No Claude sessions right now")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Palette.secondary)
            Spacer(minLength: 8)
            Button(action: playDemo) {
                Text("Play demo")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(Capsule().fill(Color.white))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: Metrics.row)
    }

    private func row(_ s: SessionInfo) -> some View {
        let hovered = hoveredRow == s.id
        return HStack(spacing: 4) {
            Button { activate(s) } label: {
                HStack(spacing: 12) {
                    StateGlyph(state: s.state, size: 16, tint: Palette.tint(for: s.project))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                        Text(s.place.map { "\(s.statusLine) · \($0)" } ?? s.statusLine)
                            .help(store.requests[s.id]?.full ?? s.statusLine)
                            .font(.system(size: 11.5))
                            .foregroundColor(s.state == .waiting ? Palette.amber : Palette.secondary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 8)
                    if store.requests[s.id] == nil {
                        Text(timeLabel(s))
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundColor(Palette.secondary)
                    }
                }
                .padding(.leading, 12)
                .frame(height: Metrics.row)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(s.name), \(s.statusLine), \(timeLabel(s))")
            .accessibilityHint("Opens this chat")
            .accessibilityAction(named: "Remove from Notchy") { dismiss(s) }

            if store.requests[s.id] != nil {
                approvalButtons(s)
            } else {
                closeButton(s)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(hovered ? Palette.rowHover : .clear))
        .onHover { hoveredRow = $0 ? s.id : nil }
    }

    /// Deny and Allow for a waiting permission request. Clicking the row instead hands it back to Claude.
    private func approvalButtons(_ s: SessionInfo) -> some View {
        // Ignore clicks for a moment after the buttons appear, so a click meant for the
        // menu bar can't land on Allow when the island opens by itself.
        let ready = Date().timeIntervalSince1970 - (store.requests[s.id]?.at ?? 0) > 0.6 && now > appearedAt.addingTimeInterval(0.6)
        return HStack(spacing: 6) {
            Button { if ready { answer(s, .deny) } } label: {
                Text("Deny")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Deny: \(s.statusLine)")
            Button { if ready { answer(s, .allow) } } label: {
                Text("Allow")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 14)
                    .frame(height: 26)
                    .background(Capsule().fill(Color.white))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Allow: \(s.statusLine)")
        }
        .padding(.trailing, 10)
    }

    /// Remove a session that's stuck or finished. Shown on hover, always there for VoiceOver.
    private func closeButton(_ s: SessionInfo) -> some View {
        Group {
            Button { dismiss(s) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(s.name) from Notchy")
            .padding(.trailing, 10)
        }
        .opacity(hoveredRow == s.id ? 1 : 0)
    }

    private func timeLabel(_ s: SessionInfo) -> String {
        let t = now.timeIntervalSince1970
        return s.state == .done ? shortDuration(t - s.updated) + " ago" : shortDuration(t - s.started)
    }

    private var accessibilitySummary: String {
        var parts: [String] = []
        if !store.waiting.isEmpty { parts.append("\(store.waiting.count) need you") }
        if !store.working.isEmpty { parts.append("\(store.working.count) working") }
        if !store.done.isEmpty { parts.append("\(store.done.count) done") }
        return "Claude sessions: " + (parts.isEmpty ? "none" : parts.joined(separator: ", "))
    }
}
