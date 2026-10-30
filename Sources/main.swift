import AppKit

// `Notchy hook` is what Claude Code calls; anything else starts the app.
let command = CommandLine.arguments.dropFirst().first
if command == "hook" {
    Hook.run()
    exit(0)
}
if command == "demo" {
    Demo.run()
    RunLoop.main.run(until: Date().addingTimeInterval(27))
    exit(0)
}
if command == "icon" {
    MainActor.assumeIsolated { Snapshot.icon(to: CommandLine.arguments.dropFirst(2).first ?? "icon.png") }
    exit(0)
}
if command == "snapshot" {
    MainActor.assumeIsolated { Snapshot.render(to: CommandLine.arguments.dropFirst(2).first ?? ".") }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
