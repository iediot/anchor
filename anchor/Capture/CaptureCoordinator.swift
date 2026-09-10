import AppKit

// one save is one coherent attempt
// the target is resolved fresh from the last external focus, every adapter is timed,
// and the screen is looked at again afterwards so drift is reported rather than hidden
enum CaptureCoordinator {
    struct Options {
        var includeBrowserTabs: Bool
        var name: String?
    }

    struct Outcome {
        var snapshot: Snapshot?
        var storeError: String?
        var summary: String
    }

    static let browserOmissionDetail = "browser tabs were left out of this save at the user's request"

    static func capture(options: Options, focusPID: pid_t?, store: SnapshotStore?) async -> Outcome {
        let scan = WindowInspector.scan(preferredOwner: focusPID)
        let scoped = scan.inScope
        var issues: [CaptureIssue] = []
        var adapters: [AdapterRun] = []
        var resources: [CGWindowID: WindowResources] = [:]

        if !scan.accessibilityGranted {
            issues.append(CaptureIssue(severity: .omission,
                                       scope: "permissions",
                                       message: "accessibility is not granted, so window titles, fullscreen state and project matching are unavailable"))
        }

        for kind in IntegrationKind.allCases {
            let windows = scoped.filter { $0.bundleID == kind.bundleID }
            guard !windows.isEmpty else { continue }
            let startedAt = Date()
            let output = await run(kind, windows: windows, scan: scan, options: options)
            adapters.append(AdapterRun(app: kind.displayName,
                                       bundleID: kind.bundleID,
                                       startedAt: startedAt,
                                       finishedAt: Date(),
                                       outcome: output.outcome,
                                       windowsAttempted: output.windowsAttempted,
                                       windowsCaptured: output.windowsCaptured,
                                       matchingBasis: output.matchingBasis))
            resources.merge(output.resources) { _, new in new }
            issues.append(contentsOf: output.issues)
        }

        // a window whose app has no adapter still gets its geometry and identity
        var unsupported = 0
        for window in scoped where resources[window.id] == nil {
            unsupported += 1
            resources[window.id] = .empty(.unsupported,
                                          .appNotSupported,
                                          "anchor has no adapter for this application, so only its window identity and geometry were stored")
        }
        if unsupported > 0 {
            issues.append(CaptureIssue(severity: .omission,
                                       scope: "unsupported apps",
                                       message: "\(unsupported) windows belong to applications anchor has no adapter for, so no application content was captured for them"))
        }

        let after = WindowInspector.scan(preferredOwner: focusPID, pinnedTarget: scan.target)
        let drift = drift(before: scan, after: after)
        issues.append(contentsOf: drift)

        let records = scoped.map { record($0, display: scan.target, resources: resources[$0.id]) }
        let completeness: SnapshotCompleteness = !drift.isEmpty
            ? .inconsistent
            : (records.contains { $0.resources.status.isOmission } ? .partial : .complete)

        if scoped.isEmpty {
            issues.append(CaptureIssue(severity: .note,
                                       scope: "scope",
                                       message: "no ordinary window was on the destination display when this snapshot was taken"))
        }

        let snapshot = Snapshot(schemaVersion: SnapshotSchema.current,
                                id: SnapshotStore.newIdentifier(),
                                createdAt: scan.capturedAt,
                                name: SnapshotName.normalize(options.name),
                                completeness: completeness,
                                host: host(),
                                display: display(scan.target, attached: NSScreen.screens.count),
                                windows: records,
                                adapters: adapters,
                                issues: issues)

        guard let store else {
            return Outcome(snapshot: nil,
                           storeError: "the snapshot folder is unavailable, nothing was written",
                           summary: "capture ran but nothing could be stored")
        }
        do {
            try store.create(snapshot)
        } catch {
            return Outcome(snapshot: nil,
                           storeError: error.localizedDescription,
                           summary: "capture ran but nothing could be stored")
        }
        return Outcome(snapshot: snapshot, storeError: nil, summary: summary(snapshot))
    }

    private static func run(_ kind: IntegrationKind,
                            windows: [InspectedWindow],
                            scan: WindowScan,
                            options: Options) async -> AdapterOutput {
        if kind == .safari || kind == .chrome, !options.includeBrowserTabs {
            var output = AdapterOutput.allWindows(windows,
                                                  kind: .browser,
                                                  status: .omittedByUser,
                                                  detail: browserOmissionDetail,
                                                  outcome: browserOmissionDetail)
            output.issues.append(CaptureIssue(severity: .omission,
                                              scope: kind.displayName,
                                              message: browserOmissionDetail))
            return output
        }

        guard kind.usesAppleEvents else {
            return await JetBrainsCapture.capture(kind, scan: scan)
        }

        let access = await ScriptRunner.shared.determineAutomationAccess(bundleID: kind.bundleID, askUser: true)
        guard access == .granted else {
            let resourceKind = resourceKind(for: kind)
            let status: ResourceStatus = access == .denied ? .automationDenied : .automationNotGranted
            let detail = "automation access for \(kind.displayName) is \(access.label), so its windows kept their geometry only"
            var output = AdapterOutput.allWindows(windows,
                                                  kind: resourceKind,
                                                  status: status,
                                                  detail: detail,
                                                  outcome: detail)
            output.issues.append(CaptureIssue(severity: .omission, scope: kind.displayName, message: detail))
            return output
        }

        switch kind {
        case .safari, .chrome: return await BrowserCapture.capture(kind, scan: scan)
        case .terminal, .iTerm: return await TerminalCapture.capture(kind, scan: scan)
        case .xcode: return await XcodeCapture.capture(scan: scan)
        case .pycharm, .clion: return await JetBrainsCapture.capture(kind, scan: scan)
        }
    }

    static func resourceKind(for kind: IntegrationKind) -> ResourceKind {
        switch kind {
        case .safari, .chrome: return .browser
        case .terminal, .iTerm: return .terminal
        case .pycharm, .clion: return .jetBrains
        case .xcode: return .xcode
        }
    }

    // the screen is looked at again after the adapters have run
    // a changed window set or a changed destination means the evidence is not one moment
    static func drift(before: WindowScan, after: WindowScan) -> [CaptureIssue] {
        var issues: [CaptureIssue] = []
        if after.lostPinnedDisplay {
            issues.append(CaptureIssue(severity: .inconsistency,
                                       scope: "capture",
                                       message: "the destination display was no longer attached when the capture finished, so this snapshot may describe a screen that changed while it was being read"))
            return issues
        }
        let old = Set(before.inScope.map(\.id))
        let new = Set(after.inScope.map(\.id))
        let gone = old.subtracting(new)
        let added = new.subtracting(old)
        if !gone.isEmpty || !added.isEmpty {
            issues.append(CaptureIssue(severity: .inconsistency,
                                       scope: "capture",
                                       message: "the windows on the destination display changed while anchor was reading them, \(gone.count) went away and \(added.count) appeared, so this snapshot is partial evidence of one moment rather than a coherent capture"))
        }
        let byID = Dictionary(uniqueKeysWithValues: after.inScope.map { ($0.id, $0) })
        let moved = before.inScope.filter { window in
            guard let now = byID[window.id] else { return false }
            return !now.serverFrame.equalTo(window.serverFrame)
        }
        if !moved.isEmpty {
            issues.append(CaptureIssue(severity: .inconsistency,
                                       scope: "capture",
                                       message: "\(moved.count) windows moved or resized while anchor was reading them, so their stored geometry is from the start of the capture"))
        }
        return issues
    }

    private static func record(_ window: InspectedWindow,
                               display: DisplayTarget,
                               resources: WindowResources?) -> WindowRecord {
        let resolved = resources ?? .empty(.unsupported, .appNotSupported, "no adapter ran for this window")
        let relative = CGRect(x: window.appKitFrame.minX - display.frame.minX,
                              y: window.appKitFrame.minY - display.frame.minY,
                              width: window.appKitFrame.width,
                              height: window.appKitFrame.height)
        return WindowRecord(id: UUID().uuidString,
                            runtimeWindowID: UInt32(window.id),
                            appName: window.ownerName,
                            bundleID: window.bundleID,
                            appVersion: appVersion(window.bundleID),
                            title: window.title,
                            titleSource: window.titleSource.rawValue,
                            appKitFrame: RectRecord(window.appKitFrame),
                            displayRelativeFrame: RectRecord(relative),
                            windowServerFrame: RectRecord(window.serverFrame),
                            fullScreenSignal: window.fullScreen.rawValue,
                            accessibilityDocument: window.documentPath,
                            resources: resolved,
                            limitations: limitations(window, resources: resolved))
    }

    static func limitations(_ window: InspectedWindow, resources: WindowResources) -> [String] {
        var notes: [String] = []
        if let detail = resources.detail { notes.append(detail) }
        if window.title == nil {
            notes.append("no window title was readable, so this window is identified by its application and geometry only")
        }
        if window.fullScreen != .ordinary {
            notes.append("observed window mode: \(window.fullScreen.rawValue). restoring native fullscreen or split view is unverified and anchor records the observed mode only")
        }
        switch resources.kind {
        case .browser where resources.status == .captured || resources.status == .capturedEmpty:
            notes.append(BrowserCapture.privateDetectionLimitation)
        case .xcode where resources.status == .captured:
            notes.append("the working document of this window was read, the full list of open editor tabs is not readable")
        case .jetBrains where resources.status == .captured:
            notes.append("the project match comes from the window title and the ide's recent projects file, and any open files come from the persisted workspace file rather than the live editor")
        case .terminal where resources.status == .captured:
            notes.append("a directory is the current directory of the tty's foreground process group, which is the shell at an idle prompt and the running job otherwise")
        case .unsupported:
            notes.append("no adapter, only window identity and geometry were stored, this window is not restorable")
        default:
            break
        }
        return notes
    }

    private static func display(_ target: DisplayTarget, attached: Int) -> DisplayRecord {
        DisplayRecord(displayID: target.displayID,
                      name: target.name,
                      frame: RectRecord(target.frame),
                      visibleFrame: RectRecord(target.visibleFrame),
                      backingScale: Double(target.backingScale),
                      isPrimary: target.isPrimary,
                      attachedDisplays: attached,
                      selectionSource: target.source.rawValue,
                      selectionDetail: target.decidedBy)
    }

    private static func host() -> HostRecord {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        return HostRecord(operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                          anchorVersion: "\(short) (\(build))")
    }

    private static func appVersion(_ bundleID: String?) -> String? {
        guard let bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    static func summary(_ snapshot: Snapshot) -> String {
        let windows = snapshot.windows.count
        let captured = snapshot.capturedResourceCount
        let omitted = snapshot.omittedResourceCount
        return "\(windows) windows on \(snapshot.display.name), \(captured) with captured resources, \(omitted) with omissions. \(snapshot.completeness.label)"
    }
}
