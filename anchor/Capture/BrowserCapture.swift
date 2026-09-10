import AppKit

// tabs are read for scoped windows only, one addressed window at a time
// a window on another desktop is inspected for geometry and never for its tabs
enum BrowserCapture {
    // neither browser exposes a private browsing property to automation, so anchor
    // cannot promise a private window was left out and says so in the record
    static let privateDetectionNote = "not available, this browser exposes no private browsing property to automation, so anchor cannot confirm a private window was excluded"
    static let privateDetectionLimitation = "private window exclusion is not available for this browser, anchor cannot confirm that this window is not a private window"

    static func appName(_ kind: IntegrationKind) -> String {
        kind == .safari ? "Safari" : "Google Chrome"
    }

    private static func tabScript(_ kind: IntegrationKind, windowID: Int) -> String {
        let selected = kind == .safari ? "index of current tab of pvWin" : "active tab index of pvWin"
        let title = kind == .safari ? "name of pvTab" : "title of pvTab"
        return """
        tell application "\(appName(kind))"
            set pvWin to window id \(windowID)
            set pvSelected to ""
            try
                set pvSelected to (\(selected)) as text
            end try
            set pvTabs to {}
            repeat with pvTab in tabs of pvWin
                set pvURLState to "ok"
                set pvURLValue to ""
                set pvTitleState to "ok"
                set pvTitleValue to ""
                try
                    set pvURLValue to (URL of pvTab) as text
                on error pvErr
                    set pvURLState to "error"
                    set pvURLValue to pvErr
                end try
                try
                    set pvTitleValue to (\(title)) as text
                on error pvErr
                    set pvTitleState to "error"
                    set pvTitleValue to pvErr
                end try
                set end of pvTabs to {pvURLState, pvURLValue, pvTitleState, pvTitleValue}
            end repeat
            return {pvSelected, pvTabs}
        end tell
        """
    }

    static func capture(_ kind: IntegrationKind, scan: WindowScan) async -> AdapterOutput {
        let scoped = scan.windows(ofBundleID: kind.bundleID).filter(\.inScope)
        switch await ScriptedCapture.windowPass(app: appName(kind), kind: kind, scan: scan) {
        case .failure(let description):
            var output = AdapterOutput.allWindows(scoped,
                                                  kind: .browser,
                                                  status: ScriptedCapture.failureStatus(description),
                                                  detail: description,
                                                  outcome: description)
            output.issues.append(CaptureIssue(severity: .omission,
                                              scope: kind.displayName,
                                              message: "no tab was captured, \(description)"))
            return output
        case .success(let pass):
            return await attach(kind, scoped: scoped, pass: pass)
        }
    }

    private static func attach(_ kind: IntegrationKind,
                               scoped: [InspectedWindow],
                               pass: ScriptedCapture.Pass) async -> AdapterOutput {
        var output = AdapterOutput()
        output.windowsAttempted = scoped.count
        output.matchingBasis = pass.report.basis.label

        for resolution in pass.resolutions {
            guard let windowID = resolution.outcome.scriptWindowID else {
                let reason = resolution.outcome.reason ?? "unresolved"
                output.resources[resolution.serverID] = .empty(.browser, .windowNotResolved, reason)
                output.issues.append(CaptureIssue(severity: .omission,
                                                  scope: kind.displayName,
                                                  message: "a window on the destination display kept its geometry only, \(reason)"))
                continue
            }
            let outcome = await ScriptRunner.shared.runStructured(tabScript(kind, windowID: windowID))
            guard case .value(let value) = outcome else {
                let description = outcome.failureDescription ?? "the app returned no result"
                output.resources[resolution.serverID] = .empty(.browser,
                                                               ScriptedCapture.failureStatus(description),
                                                               description)
                output.issues.append(CaptureIssue(severity: .omission,
                                                  scope: kind.displayName,
                                                  message: "reading the tabs of one window failed, \(description)"))
                continue
            }
            let resource = parseTabs(value, windowID: windowID)
            let failedTabs = resource.tabs.filter { $0.issue != nil }.count
            if failedTabs > 0 {
                output.issues.append(CaptureIssue(severity: .omission,
                                                  scope: kind.displayName,
                                                  message: "\(failedTabs) tabs in one window did not report an address or a title"))
            }
            output.resources[resolution.serverID] = WindowResources(kind: .browser,
                                                                    status: resource.tabs.isEmpty ? .capturedEmpty : .captured,
                                                                    detail: nil,
                                                                    browser: resource)
            if !resource.tabs.isEmpty { output.windowsCaptured += 1 }
        }

        output.outcome = "\(output.windowsCaptured) of \(scoped.count) scoped windows yielded tabs"
        return output
    }

    // the reply is {selected index, {{url state, url, title state, title}, ...}}
    // every value arrives as its own list item so an address keeps whatever characters it has
    static func parseTabs(_ value: ScriptValue, windowID: Int) -> BrowserResource {
        let top = value.items
        let selected = Int(top.first?.text ?? "")
        var tabs: [BrowserTabRecord] = []
        for (offset, row) in (top.count > 1 ? top[1].items : []).enumerated() {
            let fields = row.strings
            let urlState = fields[safe: 0] ?? "error"
            let urlValue = fields[safe: 1] ?? ""
            let titleState = fields[safe: 2] ?? "error"
            let titleValue = fields[safe: 3] ?? ""
            var issues: [String] = []
            if urlState != "ok" { issues.append("address unavailable: \(urlValue)") }
            if titleState != "ok" { issues.append("title unavailable: \(titleValue)") }
            tabs.append(BrowserTabRecord(index: offset + 1,
                                         url: urlState == "ok" && !urlValue.isEmpty ? urlValue : nil,
                                         title: titleState == "ok" && !titleValue.isEmpty ? titleValue : nil,
                                         issue: issues.isEmpty ? nil : issues.joined(separator: "; ")))
        }
        return BrowserResource(scriptWindowID: windowID,
                               selectedTabIndex: selected,
                               tabs: tabs,
                               privateWindowDetection: privateDetectionNote)
    }
}
