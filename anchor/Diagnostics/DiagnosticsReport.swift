import AppKit

// plain text rendering of whatever the panel already holds
// it reads state only so producing a report never starts a scan or a probe
enum DiagnosticsReport {
    static func plainText(_ model: DiagnosticsModel) -> String {
        var lines: [String] = []
        lines.append("Anchor diagnostics")
        lines.append("generated \(stamp(Date()))")
        lines.append("host \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("anchor \(bundleVersion())")
        lines.append("")
        lines.append(contentsOf: permissions(model))
        lines.append("")
        lines.append(contentsOf: target(model))
        lines.append("")
        lines.append(contentsOf: windows(model))
        lines.append("")
        lines.append(contentsOf: integrations(model))
        return lines.joined(separator: "\n")
    }

    private static func permissions(_ model: DiagnosticsModel) -> [String] {
        ["PERMISSIONS",
         "accessibility: \(model.accessibilityGranted ? "granted" : "not granted")",
         "screen recording: \(model.screenRecordingGranted ? "granted, the window server supplies window names" : "not granted, window names come from accessibility instead")"]
    }

    private static func target(_ model: DiagnosticsModel) -> [String] {
        var lines = ["TARGET DISPLAY"]
        guard let scan = model.scan else {
            lines.append("no inspection has been run yet")
            return lines
        }
        let target = scan.target
        lines.append("display: \(target.name)\(target.isPrimary ? " (primary)" : "")")
        lines.append("chosen because: \(target.originDescription)")
        if let decidedBy = target.decidedBy {
            lines.append("decided by: \(decidedBy)")
        }
        lines.append("frame: \(ScreenGeometry.describe(target.frame))")
        lines.append("usable frame: \(ScreenGeometry.describe(target.visibleFrame))")
        lines.append("backing scale: \(String(format: "%.1fx", target.backingScale))")
        lines.append("displays attached: \(NSScreen.screens.count)")
        if scan.lostPinnedDisplay {
            lines.append("warning: the display selected earlier is no longer attached, the destination was resolved again")
        }
        return lines
    }

    private static func windows(_ model: DiagnosticsModel) -> [String] {
        var lines = ["WINDOWS"]
        guard let scan = model.scan else {
            lines.append("no inspection has been run yet")
            return lines
        }
        lines.append("scanned at \(stamp(scan.capturedAt))")
        lines.append("\(scan.inScope.count) in scope, \(scan.outOfScope.count) excluded")
        for window in scan.inScope {
            lines.append(contentsOf: describe(window, marker: "+"))
        }
        for window in scan.outOfScope {
            lines.append(contentsOf: describe(window, marker: "-"))
        }
        return lines
    }

    private static func describe(_ window: InspectedWindow, marker: String) -> [String] {
        ["\(marker) \(window.ownerName) — \(window.title ?? "no title available")",
         "    id \(window.id), pid \(window.pid), bundle \(window.bundleID ?? "unknown"), title via \(window.titleSource.rawValue)",
         "    appkit \(ScreenGeometry.describe(window.appKitFrame)), window server \(ScreenGeometry.describe(window.serverFrame)), on \(window.screenName ?? "unknown display")",
         "    \(window.availability.label) | \(window.fullScreen.rawValue)",
         "    accessibility document: \(window.documentPath ?? "none")",
         "    scope: \(window.scopeReason)"]
    }

    private static func integrations(_ model: DiagnosticsModel) -> [String] {
        var lines = ["INTEGRATIONS"]
        for app in model.apps {
            lines.append("\(app.kind.displayName) [\(app.kind.bundleID)]")
            lines.append("    installed: \(app.isInstalled ? app.installedPath ?? "yes" : "no, untested")")
            lines.append("    version: \(app.version ?? "unknown"), \(app.isRunning ? "running" : "not running")")
            if app.kind.usesAppleEvents {
                lines.append("    automation: \(model.automation[app.kind]?.label ?? "unknown")")
            } else {
                lines.append("    automation: no scripting dictionary, accessibility only")
            }
            if model.busy.contains(app.kind) {
                lines.append("    probe in progress, result not included")
            }
            guard let result = model.probes[app.kind] else {
                lines.append("    probe: not run")
                continue
            }
            lines.append("    probe \(result.succeeded ? "ok" : "failed") at \(stamp(result.ranAt)): \(result.summary)")
            for line in result.evidence?.lines ?? [] {
                lines.append("      \(line)")
            }
            for row in result.rows {
                lines.append("      \(row.label): \(row.detail)")
            }
            for note in result.notes {
                lines.append("      note: \(note)")
            }
        }
        return lines
    }

    private static func bundleVersion() -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        return "\(short) (\(build))"
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}
