import AppKit
import Carbon
import CoreAudio

// MARK: Keyboard shortcut (Control-Option-N). Carbon hot keys need no Accessibility permission.

enum Hotkey {
    static let pressed = Notification.Name("NotchyHotkey")
    private static var ref: EventHotKeyRef?

    static func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            NotificationCenter.default.post(name: Hotkey.pressed, object: nil)
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4E544359), id: 1)   // "NTCY"
        RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }
}

// MARK: Quiet during calls: the microphone is in use by any app.

enum Calls {
    static var micInUse: Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr,
              device != 0 else { return false }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        addr.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }
}

// MARK: Sounds

enum Sounds {
    static let choices = ["Purr", "Glass", "Tink", "Pop", "Ping", "Hero", "Submarine", "Funk", "Blow", "Bottle", "Frog", "Morse"]

    private static var current: NSSound?

    /// Plays a sound, cutting off the one before so quick previews don't pile up.
    static func play(_ name: String?) {
        current?.stop()
        current = nil
        guard let name, name != "None", let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        current = sound
        sound.play()
    }
}

// MARK: Today's tally, from the log the hook appends to on every finished turn.

enum Tally {
    static let log = Paths.support.appendingPathComponent("log.jsonl")

    static func append(seconds: Double) {
        Paths.ensure()
        let line = "{\"t\":\(Int(Date().timeIntervalSince1970)),\"s\":\(Int(seconds))}\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: log) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: log)
        }
    }

    /// "Claude worked 2h 14m today, 9 tasks", or nil before the first task.
    static func today() -> String? {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return nil }
        let start = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        var total = 0.0, count = 0
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Double],
                  let t = obj["t"], t >= start, let s = obj["s"] else { continue }
            total += s
            count += 1
        }
        guard count > 0 else { return nil }
        return "Claude worked \(shortDuration(total)) today, \(count) \(count == 1 ? "task" : "tasks")"
    }
}

// MARK: Paused flag: set when you quit, so hooks don't reopen Notchy behind your back.

enum Paused {
    static let flag = Paths.support.appendingPathComponent("paused")
    static var isOn: Bool { FileManager.default.fileExists(atPath: flag.path) }
    static func set(_ on: Bool) {
        Paths.ensure()
        if on { FileManager.default.createFile(atPath: flag.path, contents: nil) }
        else { try? FileManager.default.removeItem(at: flag) }
    }
}
