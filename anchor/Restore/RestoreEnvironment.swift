import AppKit

struct AppPresence: Equatable {
    let installed: Bool
    let path: String?
    let running: Bool
    let pids: [pid_t]

    static let notInstalled = AppPresence(installed: false, path: nil, running: false, pids: [])

    var detail: String {
        guard installed else { return "not installed on this mac" }
        return running ? "installed and running" : "installed, anchor would launch it"
    }
}

// a live window as preflight and execution see it, read only in both cases
struct LiveWindow: Equatable {
    let id: CGWindowID
    let pid: pid_t
    let title: String?
    let documentPath: String?
    let appKitFrame: CGRect
    let serverFrame: CGRect
}

// everything the planner is allowed to learn about the machine
// it is a protocol so a plan can be built against a fixture with no mac underneath it
protocol RestoreEnvironment {
    var accessibilityGranted: Bool { get }
    func fileStatus(_ path: String) -> FileStatus
    func presence(of bundleID: String) -> AppPresence
    func automationStatus(of bundleID: String) -> AutomationAccess
    func liveWindows(bundleID: String) -> [LiveWindow]
}

// the real machine, with the automation answers already gathered off the main thread
// so building a plan never blocks on a permission lookup and never prompts
struct LiveRestoreEnvironment: RestoreEnvironment {
    let accessibilityGranted: Bool
    let automation: [String: AutomationAccess]

    static func gather(bundleIDs: [String]) async -> LiveRestoreEnvironment {
        var answers: [String: AutomationAccess] = [:]
        for bundleID in Set(bundleIDs) {
            // preflight only, this call never asks the user
            answers[bundleID] = await ScriptRunner.shared.determineAutomationAccess(bundleID: bundleID, askUser: false)
        }
        return LiveRestoreEnvironment(accessibilityGranted: Permissions.accessibilityGranted, automation: answers)
    }

    // a path that is gone and a path anchor is not allowed to look at are different answers
    func fileStatus(_ path: String) -> FileStatus {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: path, isDirectory: &isDirectory) {
            guard manager.isReadableFile(atPath: path) else {
                return .inaccessible("\(path) exists but this build is not allowed to read it")
            }
            return .present(isDirectory: isDirectory.boolValue)
        }
        var parent = (path as NSString).deletingLastPathComponent
        while parent.count > 1 {
            if manager.fileExists(atPath: parent, isDirectory: &isDirectory) {
                guard manager.isReadableFile(atPath: parent) else {
                    return .inaccessible("\(parent) cannot be read, so anchor cannot tell whether \(path) is still there")
                }
                return .missing
            }
            parent = (parent as NSString).deletingLastPathComponent
        }
        return .missing
    }

    func presence(of bundleID: String) -> AppPresence {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }
        return AppPresence(installed: url != nil,
                           path: url?.path,
                           running: !running.isEmpty,
                           pids: running.map(\.processIdentifier))
    }

    func automationStatus(of bundleID: String) -> AutomationAccess {
        automation[bundleID] ?? .undetermined
    }

    // the window server list narrowed to one application, with the accessibility
    // document of each window when accessibility is granted
    func liveWindows(bundleID: String) -> [LiveWindow] {
        let pids = Set(presence(of: bundleID).pids)
        guard !pids.isEmpty else { return [] }
        var facts: [pid_t: [AXWindowFacts]] = [:]
        var found: [LiveWindow] = []
        for entry in WindowInspector.rawWindows() {
            guard let number = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  pids.contains(pid),
                  (entry[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 40, bounds.height >= 40
            else { continue }
            var document: String?
            var title = (entry[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if accessibilityGranted {
                if facts[pid] == nil { facts[pid] = AccessibilityWindows.windows(pid: pid) }
                if let matched = AccessibilityWindows.match(facts[pid] ?? [], toFrame: bounds) {
                    document = matched.documentPath
                    if title == nil { title = matched.title }
                }
            }
            found.append(LiveWindow(id: number,
                                    pid: pid,
                                    title: title,
                                    documentPath: document,
                                    appKitFrame: ScreenGeometry.appKit(fromWindowServer: bounds),
                                    serverFrame: bounds))
        }
        return found
    }
}

extension DestinationDisplay {
    init(_ target: DisplayTarget) {
        self.init(displayID: target.displayID,
                  name: target.name,
                  frame: target.frame,
                  visibleFrame: target.visibleFrame,
                  backingScale: Double(target.backingScale),
                  selectionSource: target.source.rawValue,
                  selectionDetail: target.decidedBy)
    }
}
