import AppKit
import Observation

@MainActor
@Observable
final class PanelShortcut {
    var enabled: Bool {
        didSet { defaults.set(enabled, forKey: "anchor.shortcut.enabled") }
    }
    private(set) var label: String
    var recording = false
    private(set) var recordingHint: String?

    private let defaults = UserDefaults.standard
    private var keyCode: UInt16
    private var modifiers: NSEvent.ModifierFlags
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var action: () -> Void = {}
    private static let mask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: "anchor.shortcut.enabled") as? Bool ?? true
        keyCode = UInt16(clamping: defaults.integer(forKey: "anchor.shortcut.key"))
        let raw = defaults.object(forKey: "anchor.shortcut.modifiers") as? UInt
        modifiers = raw.map { NSEvent.ModifierFlags(rawValue: $0) } ?? .option
        label = defaults.string(forKey: "anchor.shortcut.label") ?? "⌥A"
    }

    func start(action: @escaping () -> Void) {
        stop()
        self.action = action
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, !self.recording, self.matches(event) else { return }
                self.action()
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                if self.recording {
                    self.record(event)
                    return nil
                }
                guard self.matches(event) else { return event }
                self.action()
                return nil
            }
        }
    }

    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        cancelRecording()
    }

    func beginRecording() {
        recordingHint = nil
        recording = true
    }

    func cancelRecording() {
        recording = false
        recordingHint = nil
    }

    func reset() {
        save(key: 0, flags: .option, name: "A")
    }

    private func matches(_ event: NSEvent) -> Bool {
        enabled && !event.isARepeat && event.keyCode == keyCode
            && event.modifierFlags.intersection(Self.mask) == modifiers
    }

    private func record(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        if event.keyCode == 53 { cancelRecording(); return }
        let flags = event.modifierFlags.intersection(Self.mask)
        guard !flags.intersection([.command, .option, .control]).isEmpty,
              let name = event.characters(byApplyingModifiers: []),
              name.count == 1,
              name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
            recordingHint = "Use a letter or number with ⌥, ⌃ or ⌘. Esc cancels."
            return
        }
        save(key: event.keyCode, flags: flags, name: name.uppercased())
    }

    private func save(key: UInt16, flags: NSEvent.ModifierFlags, name: String) {
        keyCode = key
        modifiers = flags
        label = (flags.contains(.control) ? "⌃" : "")
            + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "")
            + (flags.contains(.command) ? "⌘" : "") + name
        defaults.set(Int(keyCode), forKey: "anchor.shortcut.key")
        defaults.set(flags.rawValue, forKey: "anchor.shortcut.modifiers")
        defaults.set(label, forKey: "anchor.shortcut.label")
        cancelRecording()
    }
}
