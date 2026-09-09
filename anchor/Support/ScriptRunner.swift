import Foundation

enum ScriptOutcome {
    case text(String)
    case failed(code: Int, message: String)
    case timedOut(TimeInterval)

    var failureDescription: String? {
        switch self {
        case .text: return nil
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
