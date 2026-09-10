import CoreServices
import Foundation

// an apple event reply as a tree, so nothing has to be squeezed through a delimiter
// a url or a title may hold any character including the separators anchor once used
nonisolated indirect enum ScriptValue: Sendable {
    case text(String)
    case list([ScriptValue])

    var text: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    var items: [ScriptValue] {
        if case .list(let values) = self { return values }
        return []
    }

    // one level of a list read as plain strings, a nested list collapses to empty
    var strings: [String] {
        items.map { $0.text ?? "" }
    }
}

// an argument handed to a script handler, built as a descriptor rather than as text
nonisolated indirect enum ScriptArgument: Sendable {
    case text(String)
    case integer(Int)
    case list([ScriptArgument])

    var descriptor: NSAppleEventDescriptor {
        switch self {
        case .text(let value):
            return NSAppleEventDescriptor(string: value)
        case .integer(let value):
            return NSAppleEventDescriptor(int32: Int32(clamping: value))
        case .list(let values):
            let list = NSAppleEventDescriptor.list()
            for (offset, value) in values.enumerated() {
                list.insert(value.descriptor, at: offset + 1)
            }
            return list
        }
    }
}

enum ScriptOutcome {
    case text(String)
    case value(ScriptValue)
    case failed(code: Int, message: String)
    case timedOut(TimeInterval)

    var failureDescription: String? {
        switch self {
        case .text, .value: return nil
        case .failed(let code, let message): return "script error \(code): \(message)"
        case .timedOut(let seconds): return "timed out after \(Int(seconds))s"
        }
    }
}

private final class OnceBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

// apple events are sent off the main thread on one serial queue
// a timeout abandons the result only, it cannot interrupt the blocking send
final class ScriptRunner: @unchecked Sendable {
    static let shared = ScriptRunner()

    private let queue = DispatchQueue(label: "anchor.script", qos: .userInitiated)

    nonisolated func run(_ source: String, timeout: TimeInterval = 6) async -> ScriptOutcome {
        await withCheckedContinuation { continuation in
            let box = OnceBox(continuation)
            queue.async {
                guard let script = NSAppleScript(source: source) else {
                    box.finish(.failed(code: -1, message: "could not compile probe script"))
                    return
                }
                var error: NSDictionary?
                let value = script.executeAndReturnError(&error)
                if let error {
                    let code = (error[NSAppleScript.errorNumber] as? Int) ?? -1
                    let message = (error[NSAppleScript.errorMessage] as? String) ?? "unknown script error"
                    box.finish(.failed(code: code, message: message))
                } else {
                    box.finish(.text(value.stringValue ?? ""))
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                box.finish(.timedOut(timeout))
            }
        }
    }

    // same queue and same timeout, the reply is converted to a value tree before it
    // leaves the queue because an apple event descriptor is not sendable
    nonisolated func runStructured(_ source: String, timeout: TimeInterval = 8) async -> ScriptOutcome {
        await withCheckedContinuation { continuation in
            let box = OnceBox(continuation)
            queue.async {
                guard let script = NSAppleScript(source: source) else {
                    box.finish(.failed(code: -1, message: "could not compile capture script"))
                    return
                }
                var error: NSDictionary?
                let reply = script.executeAndReturnError(&error)
                if let error {
                    let code = (error[NSAppleScript.errorNumber] as? Int) ?? -1
                    let message = (error[NSAppleScript.errorMessage] as? String) ?? "unknown script error"
                    box.finish(.failed(code: code, message: message))
                } else {
                    box.finish(.value(Self.value(from: reply)))
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                box.finish(.timedOut(timeout))
            }
        }
    }

    nonisolated static func value(from descriptor: NSAppleEventDescriptor) -> ScriptValue {
        guard descriptor.descriptorType == typeAEList else {
            return .text(descriptor.stringValue ?? "")
        }
        let count = descriptor.numberOfItems
        guard count > 0 else { return .list([]) }
        var items: [ScriptValue] = []
        for index in 1...count {
            guard let item = descriptor.atIndex(index) else { continue }
            items.append(value(from: item))
        }
        return .list(items)
    }

    // a handler is called with real apple event arguments, so a url, a path or a shell
    // word is never pasted into script text where it could become code
    nonisolated func runHandler(_ source: String,
                                handler: String,
                                arguments: [ScriptArgument],
                                timeout: TimeInterval = 25) async -> ScriptOutcome {
        await withCheckedContinuation { continuation in
            let box = OnceBox(continuation)
            queue.async {
                guard let script = NSAppleScript(source: source) else {
                    box.finish(.failed(code: -1, message: "could not compile restore script"))
                    return
                }
                let event = NSAppleEventDescriptor(eventClass: Self.subroutineEventClass,
                                                   eventID: Self.subroutineEventID,
                                                   targetDescriptor: NSAppleEventDescriptor(processIdentifier: ProcessInfo.processInfo.processIdentifier),
                                                   returnID: AEReturnID(kAutoGenerateReturnID),
                                                   transactionID: AETransactionID(kAnyTransactionID))
                // applescript looks handler names up in lower case
                event.setParam(NSAppleEventDescriptor(string: handler.lowercased()),
                               forKeyword: Self.subroutineNameKey)
                event.setParam(ScriptArgument.list(arguments).descriptor, forKeyword: AEKeyword(keyDirectObject))
                var error: NSDictionary?
                let reply = script.executeAppleEvent(event, error: &error)
                if let error {
                    let code = (error[NSAppleScript.errorNumber] as? Int) ?? -1
                    let message = (error[NSAppleScript.errorMessage] as? String) ?? "unknown script error"
                    box.finish(.failed(code: code, message: message))
                } else {
                    box.finish(.value(Self.value(from: reply)))
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                box.finish(.timedOut(timeout))
            }
        }
    }

    // the applescript suite, the subroutine event and its name key, spelled as their codes
    // so no deprecated carbon header has to be imported for three constants
    nonisolated static let subroutineEventClass = AEEventClass(0x61736372)
    nonisolated static let subroutineEventID = AEEventID(0x70736272)
    nonisolated static let subroutineNameKey = AEKeyword(0x736E616D)

    // permission checks block, so they share the same off-main queue
    nonisolated func determineAutomationAccess(bundleID: String, askUser: Bool) async -> AutomationAccess {
        await withCheckedContinuation { continuation in
            let box = OnceBox(continuation)
            queue.async {
                box.finish(Permissions.automationAccessBlocking(for: bundleID, askUser: askUser))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) {
                box.finish(.undetermined)
            }
        }
    }
}
