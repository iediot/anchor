import AppKit

// one plain text report, copied from the panel's settings menu
// it reads state that is already held, so producing it starts nothing and asks nothing
// what a person is working on never goes in: no window titles, no addresses, no paths,
// and any error text is put through the same filter before it is written down
enum TroubleshootingReport {
    static func copyToPasteboard(setup: PermissionsSetupModel, savedStates: SavedStatesModel) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text(setup: setup, savedStates: savedStates), forType: .string)
    }

    static func text(setup: PermissionsSetupModel, savedStates: SavedStatesModel) -> String {
        var lines = ["Anchor troubleshooting report",
                     "generated \(Stamp.text(Date()))",
                     "anchor \(version())",
                     "macos \(ProcessInfo.processInfo.operatingSystemVersionString)",
                     "displays attached: \(NSScreen.screens.count)"]
        lines.append("")
        lines.append(contentsOf: permissions(setup))
        lines.append("")
        lines.append(contentsOf: lastSave(savedStates))
        lines.append("")
        lines.append(contentsOf: operation("LAST REOPEN",
                                           log: savedStates.restore.log,
                                           outcome: savedStates.restore.summary))
        lines.append("")
        lines.append(contentsOf: operation("LAST SWITCH",
                                           log: savedStates.replacement.log,
                                           outcome: savedStates.replacement.stopReason))
        lines.append("")
        lines.append(contentsOf: errors(savedStates))
        lines.append("")
        lines.append("this report carries no window titles, addresses or file paths")
        return lines.joined(separator: "\n")
    }

    private static func permissions(_ setup: PermissionsSetupModel) -> [String] {
        var lines = ["PERMISSIONS",
                     "accessibility: \(setup.accessibilityGranted ? "granted" : "not granted")",
                     "screen recording: \(setup.screenRecordingGranted ? "granted" : "not granted, previews are schematic")",
                     "automation, one application at a time:"]
        for app in setup.scriptedApps {
            let state = app.isInstalled ? setup.status(app) : "not installed"
            lines.append("  \(app.kind.displayName) \(app.version ?? "version unknown"): \(state)")
        }
        return lines
    }

    private static func lastSave(_ model: SavedStatesModel) -> [String] {
        var lines = ["LAST SAVE"]
        lines.append("saved layouts stored: \(model.snapshots.count), unreadable files: \(model.failures.count)")
        guard let outcome = model.lastOutcome else {
            lines.append("no save has run in this session")
            return lines
        }
        lines.append(safe(outcome.summary))
        if let error = outcome.storeError {
            lines.append("store error: \(safe(error))")
        }
        if let issue = model.thumbnailIssue {
            lines.append("preview picture: \(safe(issue.message))")
        }
        return lines
    }

    // the stages of a run, by name, with what each one took
    // the detail a stage recorded is deliberately left out, it is where a name could hide
    private static func operation(_ heading: String, log: OperationLog, outcome: String?) -> [String] {
        var lines = [heading]
        guard let startedAt = log.startedAt else {
            lines.append("none in this session")
            return lines
        }
        lines.append("operation \(log.id), action \(safe(log.trigger ?? "unknown"))")
        lines.append("started \(Stamp.text(startedAt))")
        var previous = startedAt
        for event in log.events {
            let elapsed = String(format: "%.2f", event.at.timeIntervalSince(previous))
            lines.append("  \(event.stage) +\(elapsed)s")
            previous = event.at
        }
        lines.append("counts: \(log.counts)")
        if let outcome {
            lines.append("outcome: \(safe(outcome))")
        }
        return lines
    }

    private static func errors(_ model: SavedStatesModel) -> [String] {
        var lines = ["ERRORS"]
        var found = false
        for (label, text) in [("snapshot store", model.storeError),
                              ("delete", model.deleteError),
                              ("rename", model.renameError),
                              ("plan", model.planError)] {
            guard let text else { continue }
            found = true
            lines.append("\(label): \(safe(text))")
        }
        for failure in model.failures {
            found = true
            lines.append("unreadable saved layout: \(safe(failure.reason))")
        }
        if !found {
            lines.append("none held")
        }
        return lines
    }

    private static func version() -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        return "\(short) (\(build))"
    }

    // an address, a path, or anything a system error quoted, is replaced before it is
    // written down. the shape of the message survives, the content does not
    static func safe(_ text: String) -> String {
        var result = text
        for rule in rules {
            result = rule.expression.stringByReplacingMatches(in: result,
                                                              range: NSRange(result.startIndex..., in: result),
                                                              withTemplate: rule.replacement)
        }
        return result
    }

    private struct Rule {
        let expression: NSRegularExpression
        let replacement: String
    }

    private static let rules: [Rule] = [
        ("[A-Za-z][A-Za-z0-9+.-]*://[^\\s]+", "[address]"),
        ("(?<![\\w])[~/][A-Za-z0-9_.~/-]+", "[path]"),
        ("\u{201C}[^\u{201D}]*\u{201D}", "[name]"),
        ("\"[^\"]*\"", "[name]")
    ].compactMap { pattern, replacement -> Rule? in
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        return Rule(expression: expression, replacement: replacement)
    }
}
