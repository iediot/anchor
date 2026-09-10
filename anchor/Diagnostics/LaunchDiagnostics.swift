import AppKit

// a temporary instrument for one open question: whether anchor's opening of a jetbrains
// ide is what precedes the crash, or one of the stages that normally follows it
// each mode adds exactly one stage, and nothing here closes, quits or answers anything
enum LaunchDiagnosticMode: String, CaseIterable, Identifiable {
    case launchOnly
    case identify
    case place

    var id: String { rawValue }

    var label: String {
        switch self {
        case .launchOnly: return "1 · Launch only"
        case .identify: return "2 · Launch and identify"
        case .place: return "3 · Launch, identify and place"
        }
    }

    var detail: String {
        switch self {
        case .launchOnly:
            return "hands the project to the ide with the same call a normal reopen uses, then stops. no window list, no accessibility, no placement, no restore"
        case .identify:
            return "adds the bounded wait for the project window. accessibility is read and never written"
        case .place:
            return "adds the placement a normal reopen does, using the rectangle saved for this project"
        }
    }
}

struct LaunchStage: Identifiable, Equatable {
    let id: String
    let name: String
    let detail: String
    let at: Date
    let duration: TimeInterval?
}

// where the rectangle for the third mode comes from
struct LaunchRectangle: Equatable {
    let frame: CGRect
    let provenance: String
}

enum LaunchRectangleSource {
    // the newest saved rectangle for this project, mapped onto the destination exactly
    // the way a normal reopen maps it
    static func resolve(projectPath: String,
                        snapshots: [Snapshot],
                        destination: DestinationDisplay) -> LaunchRectangle? {
        for snapshot in snapshots {
            for window in snapshot.windows where window.resources.jetBrains?.projectPath == projectPath {
                guard case .mapped(let mapped) = LayoutMapping.map(window: window,
                                                                   source: snapshot.display,
                                                                   destination: destination)
                else { continue }
                return LaunchRectangle(frame: mapped.appKitFrame,
                                       provenance: "the rectangle saved for this project on \(snapshot.display.name), mapped onto \(destination.name)")
            }
        }
        return fallback(destination)
    }

    static func fallback(_ destination: DestinationDisplay) -> LaunchRectangle? {
        let usable = destination.visibleFrame
        guard usable.width >= LayoutMapping.minimumSize.width,
              usable.height >= LayoutMapping.minimumSize.height
        else { return nil }
        let width = max(LayoutMapping.minimumSize.width, (usable.width * 2 / 3).rounded())
        return LaunchRectangle(frame: CGRect(x: usable.minX.rounded(),
                                             y: usable.minY.rounded(),
                                             width: width,
                                             height: usable.height.rounded()),
                               provenance: "no saved state holds this project, so anchor would use two thirds of the usable width")
    }
}

// process level only, deliberately no window list and no accessibility
@MainActor
protocol LaunchProcessProbe {
    func runningPIDs(bundleID: String) -> [pid_t]
}

struct LiveLaunchProcessProbe: LaunchProcessProbe {
    func runningPIDs(bundleID: String) -> [pid_t] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }
            .map(\.processIdentifier)
    }
}

@MainActor
@Observable
final class LaunchDiagnosticsCoordinator {
    private(set) var isRunning = false
    private(set) var mode: LaunchDiagnosticMode?
    private(set) var projectPath: String?
    private(set) var stages: [LaunchStage] = []
    private(set) var summary: String?
    private(set) var startedAt: Date?

    // the readiness wait is the same length a normal reopen gives an ide
    var identifyTimeout: TimeInterval = 40

    func run(mode requested: LaunchDiagnosticMode,
             project: ProjectOpenRequest,
             rectangle: LaunchRectangle?,
             accessibilityGranted: Bool,
             probe: LaunchProcessProbe,
             executor: RestoreExecutor) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        mode = requested
        projectPath = project.path
        stages = []
        summary = nil
        startedAt = Date()

        let before = probe.runningPIDs(bundleID: project.app.bundleID)
        record("process check", before.isEmpty
            ? "\(project.app.displayName) was not running, so this is a cold launch"
            : "\(project.app.displayName) was already running, so this run is not a cold launch comparison")

        var excluding: Set<CGWindowID> = []
        if requested != .launchOnly {
            let started = Date()
            let live = executor.liveWindows(bundleID: project.app.bundleID)
            excluding = Set(live.map(\.id))
            record("window list before launch",
                   "\(live.count) windows were already open for this application, read only",
                   since: started)
        }

        let launchedAt = Date()
        let outcome = await executor.openProject(project)
        record("launch", outcome.summary, since: launchedAt)
        guard outcome.succeeded else {
            finish("the launch call failed, so no later stage ran", probe: probe, bundleID: project.app.bundleID)
            return
        }
        guard requested != .launchOnly else {
            finish("launch only, anchor read no window list, no accessibility attribute and moved nothing",
                   probe: probe,
                   bundleID: project.app.bundleID)
            return
        }
        guard accessibilityGranted else {
            record("identify", "accessibility is not granted, so no window could be identified")
            finish("the launch happened, identification needs accessibility",
                   probe: probe,
                   bundleID: project.app.bundleID)
            return
        }

        let identifiedAt = Date()
        let evidence = await executor.awaitProjectWindow(project, excluding: excluding, timeout: identifyTimeout)
        record("identify", evidence.label, since: identifiedAt)
        guard let windowID = evidence.windowID else {
            finish("no project window was identified, so nothing was placed",
                   probe: probe,
                   bundleID: project.app.bundleID)
            return
        }
        guard requested == .place else {
            finish("identification only, anchor read the window and wrote no accessibility attribute",
                   probe: probe,
                   bundleID: project.app.bundleID)
            return
        }
        guard let rectangle else {
            record("place", "no rectangle was available for this project, so nothing was placed")
            finish("the launch and the identification happened, placement had nothing to apply",
                   probe: probe,
                   bundleID: project.app.bundleID)
            return
        }

        let placedAt = Date()
        let placement = await executor.place(windowID: windowID, appKitFrame: rectangle.frame)
        record("place", "\(rectangle.provenance). \(placement.label)", since: placedAt)
        guard placement.succeeded else {
            finish("the placement was refused", probe: probe, bundleID: project.app.bundleID)
            return
        }
        let settledAt = Date()
        let settled = await PlacementSettle.verify(windowID: windowID,
                                                   bundleID: project.app.bundleID,
                                                   requested: rectangle.frame,
                                                   executor: executor)
        record("settle", settled.text, since: settledAt)
        finish("all three stages ran", probe: probe, bundleID: project.app.bundleID)
    }

    private func finish(_ text: String, probe: LaunchProcessProbe, bundleID: String) {
        record("process check", probe.runningPIDs(bundleID: bundleID).isEmpty
            ? "the application is no longer running"
            : "the application is still running, close it by hand when you are done")
        summary = text
    }

    private func record(_ name: String, _ detail: String, since: Date? = nil) {
        stages.append(LaunchStage(id: UUID().uuidString,
                                  name: name,
                                  detail: detail,
                                  at: Date(),
                                  duration: since.map { Date().timeIntervalSince($0) }))
    }

    // one line per stage, with the project path on its own line so it is easy to remove
    // before sharing. no environment and no project content is ever included
    var report: String {
        var lines = ["anchor launch diagnostic"]
        if let mode { lines.append("mode: \(mode.label)") }
        if let projectPath { lines.append("project path: \(projectPath)") }
        if let startedAt { lines.append("started: \(ProbeEvidence.stamp(startedAt))") }
        for stage in stages {
            let elapsed = stage.duration.map { String(format: " (%.2fs)", $0) } ?? ""
            lines.append("\(ProbeEvidence.stamp(stage.at)) \(stage.name)\(elapsed): \(stage.detail)")
        }
        if let summary { lines.append("outcome: \(summary)") }
        return lines.joined(separator: "\n")
    }
}
