import AppKit

// what one adapter produced for one application during one save
struct AdapterOutput {
    var resources: [CGWindowID: WindowResources] = [:]
    var issues: [CaptureIssue] = []
    var outcome: String = ""
    var windowsAttempted: Int = 0
    var windowsCaptured: Int = 0
    var matchingBasis: String?

    static func allWindows(_ scoped: [InspectedWindow],
                           kind: ResourceKind,
                           status: ResourceStatus,
                           detail: String?,
                           outcome: String) -> AdapterOutput {
        var output = AdapterOutput()
        output.windowsAttempted = scoped.count
        output.outcome = outcome
        for window in scoped {
            output.resources[window.id] = .empty(kind, status, detail)
        }
        return output
    }
}

// the first pass every scripted adapter runs, geometry and reported state only
// scratch names are prefixed because a bare dictionary term reads as an application object
enum WindowGeometryScript {
    static func source(app: String) -> String {
        """
        tell application "\(app)"
            set pvOut to {}
            repeat with pvWindow in windows
                set pvID to "?"
                set pvLeft to "?"
                set pvTop to "?"
                set pvRight to "?"
                set pvBottom to "?"
                set pvVisible to "?"
                set pvMinimized to "?"
                set pvIndex to "?"
                try
                    set pvID to (id of pvWindow) as text
                end try
                try
                    set pvRect to bounds of pvWindow
                    set pvLeft to (item 1 of pvRect) as text
                    set pvTop to (item 2 of pvRect) as text
                    set pvRight to (item 3 of pvRect) as text
                    set pvBottom to (item 4 of pvRect) as text
                end try
                try
                    set pvVisible to (visible of pvWindow) as text
                end try
                try
                    set pvMinimized to (miniaturized of pvWindow) as text
                end try
                try
                    set pvIndex to (index of pvWindow) as text
                end try
                set end of pvOut to {pvID, pvLeft, pvTop, pvRight, pvBottom, pvVisible, pvMinimized, pvIndex}
            end repeat
            return pvOut
        end tell
        """
    }

    static func parse(_ value: ScriptValue) -> [ScriptedWindow] {
        value.items.compactMap { row in
            let fields = row.strings
            guard fields.count >= ScriptedWindow.leadingFieldCount else { return nil }
            return ScriptedWindow.parse(fields)
        }
    }
}

// shared plumbing for the scripted adapters, all of which start with the same pass
enum ScriptedCapture {
    struct Pass {
        let scripted: [ScriptedWindow]
        let report: CorrelationReport
        let resolutions: [ScopeResolution]
    }

    enum PassResult {
        case success(Pass)
        case failure(String)
    }

    static func windowPass(app: String, kind: IntegrationKind, scan: WindowScan) async -> PassResult {
        let outcome = await ScriptRunner.shared.runStructured(WindowGeometryScript.source(app: app))
        guard case .value(let value) = outcome else {
            return .failure(outcome.failureDescription ?? "the app returned no result")
        }
        let scripted = WindowGeometryScript.parse(value)
        let onScreen = scan.windows(ofBundleID: kind.bundleID)
        let scoped = onScreen.filter(\.inScope)
        let report = WindowCorrelation.correlate(scripted: scripted,
                                                 onScreen: onScreen,
                                                 inScopeCount: scoped.count,
                                                 identity: WindowIdentity.basis(for: kind))
        return .success(Pass(scripted: scripted,
                             report: report,
                             resolutions: CaptureScope.resolve(scripted: scripted,
                                                               matches: report.matches,
                                                               scopedWindows: scoped)))
    }

    static func failureStatus(_ description: String) -> ResourceStatus {
        description.hasPrefix("timed out") ? .adapterTimedOut : .adapterFailed
    }
}
