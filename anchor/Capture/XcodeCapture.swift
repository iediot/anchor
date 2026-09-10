import AppKit

// the working document path is the project, the accessibility document is the active file
// they are two different facts and are stored as two different fields
enum XcodeCapture {
    private static func documentScript(windowID: Int) -> String {
        """
        tell application "Xcode"
            set pvWin to window id \(windowID)
            set pvState to "window has no document"
            set pvPath to ""
            set pvError to ""
            set pvDoc to missing value
            try
                set pvDoc to document of pvWin
            on error pvErr
                set pvState to "reading the document failed"
                set pvError to pvErr
            end try
            if pvDoc is not missing value then
                try
                    set pvPath to (path of pvDoc) as text
                    set pvState to "document present"
                on error pvErr
                    set pvState to "the document path could not be read"
                    set pvError to pvErr
                end try
            end if
            return {pvState, pvPath, pvError}
        end tell
        """
    }

    static func capture(scan: WindowScan) async -> AdapterOutput {
        let kind = IntegrationKind.xcode
        let scoped = scan.windows(ofBundleID: kind.bundleID).filter(\.inScope)
        switch await ScriptedCapture.windowPass(app: "Xcode", kind: kind, scan: scan) {
        case .failure(let description):
            var output = AdapterOutput.allWindows(scoped,
                                                  kind: .xcode,
                                                  status: ScriptedCapture.failureStatus(description),
                                                  detail: description,
                                                  outcome: description)
            output.issues.append(CaptureIssue(severity: .omission,
                                              scope: kind.displayName,
                                              message: "no project path was captured, \(description)"))
            return output
        case .success(let pass):
            return await attach(scoped: scoped, pass: pass)
        }
    }

    private static func attach(scoped: [InspectedWindow], pass: ScriptedCapture.Pass) async -> AdapterOutput {
        var output = AdapterOutput()
        output.windowsAttempted = scoped.count
        output.matchingBasis = pass.report.basis.label
        let byID = Dictionary(uniqueKeysWithValues: scoped.map { ($0.id, $0) })

        for resolution in pass.resolutions {
            guard let windowID = resolution.outcome.scriptWindowID else {
                let reason = resolution.outcome.reason ?? "unresolved"
                output.resources[resolution.serverID] = .empty(.xcode, .windowNotResolved, reason)
                output.issues.append(CaptureIssue(severity: .omission,
                                                  scope: IntegrationKind.xcode.displayName,
                                                  message: "a window on the destination display kept its geometry only, \(reason)"))
                continue
            }
            let activeFile = byID[resolution.serverID]?.documentPath
            let outcome = await ScriptRunner.shared.runStructured(documentScript(windowID: windowID))
            guard case .value(let value) = outcome else {
                let description = outcome.failureDescription ?? "the app returned no result"
                output.resources[resolution.serverID] = .empty(.xcode,
                                                               ScriptedCapture.failureStatus(description),
                                                               description)
                output.issues.append(CaptureIssue(severity: .omission,
                                                  scope: IntegrationKind.xcode.displayName,
                                                  message: "reading the document of one window failed, \(description)"))
                continue
            }
            let fields = value.strings
            let state = fields[safe: 0] ?? "unknown"
            let path = fields[safe: 1] ?? ""
            let error = fields[safe: 2] ?? ""
            let resource = XcodeResource(scriptWindowID: windowID,
                                         workingDocumentPath: path.isEmpty ? nil : path,
                                         workingDocumentIssue: path.isEmpty ? issue(state: state, error: error) : nil,
                                         accessibilityActiveFile: activeFile)
            output.resources[resolution.serverID] = WindowResources(kind: .xcode,
                                                                    status: path.isEmpty ? .resourceNotIdentified : .captured,
                                                                    detail: path.isEmpty ? issue(state: state, error: error) : nil,
                                                                    xcode: resource)
            if !path.isEmpty { output.windowsCaptured += 1 }
        }

        output.outcome = "\(output.windowsCaptured) of \(scoped.count) scoped windows yielded a project path"
        return output
    }

    private static func issue(state: String, error: String) -> String {
        error.isEmpty ? state : "\(state): \(error)"
    }
}
