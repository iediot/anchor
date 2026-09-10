import AppKit

// a directory is attached only when the window association resolved
// the tab exposes a tty, the directory comes from the foreground process group on it
enum TerminalCapture {
    static func appName(_ kind: IntegrationKind) -> String {
        kind == .terminal ? "Terminal" : "iTerm"
    }

    private static func tabScript(_ kind: IntegrationKind, windowID: Int) -> String {
        let body = kind == .terminal
            ? """
              repeat with pvTab in tabs of pvWin
                  set pvState to "ok"
                  set pvTTY to ""
                  set pvSel to ""
                  try
                      set pvTTY to tty of pvTab
                  on error pvErr
                      set pvState to "error"
                      set pvTTY to pvErr
                  end try
                  try
                      set pvSel to (selected of pvTab) as text
                  end try
                  set end of pvOut to {pvState, pvTTY, pvSel}
              end repeat
              """
            : """
              repeat with pvTab in tabs of pvWin
                  repeat with pvSession in sessions of pvTab
                      set pvState to "ok"
                      set pvTTY to ""
                      try
                          set pvTTY to tty of pvSession
                      on error pvErr
                          set pvState to "error"
                          set pvTTY to pvErr
                      end try
                      set end of pvOut to {pvState, pvTTY, ""}
                  end repeat
              end repeat
              """
        return """
        tell application "\(appName(kind))"
            set pvWin to window id \(windowID)
            set pvOut to {}
        \(body)
            return pvOut
        end tell
        """
    }

    static func capture(_ kind: IntegrationKind, scan: WindowScan) async -> AdapterOutput {
        let scoped = scan.windows(ofBundleID: kind.bundleID).filter(\.inScope)
        switch await ScriptedCapture.windowPass(app: appName(kind), kind: kind, scan: scan) {
        case .failure(let description):
            var output = AdapterOutput.allWindows(scoped,
                                                  kind: .terminal,
                                                  status: ScriptedCapture.failureStatus(description),
                                                  detail: description,
                                                  outcome: description)
            output.issues.append(CaptureIssue(severity: .omission,
                                              scope: kind.displayName,
                                              message: "no working directory was captured, \(description)"))
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
                output.resources[resolution.serverID] = .empty(.terminal, .windowNotResolved, reason)
                // this is the contested terminal case the user already sees, it must stay visible
                output.issues.append(CaptureIssue(severity: .omission,
                                                  scope: kind.displayName,
                                                  message: "a window on the destination display kept its geometry only and was given no directory, \(reason)"))
                continue
            }
            let outcome = await ScriptRunner.shared.runStructured(tabScript(kind, windowID: windowID))
            guard case .value(let value) = outcome else {
                let description = outcome.failureDescription ?? "the app returned no result"
                output.resources[resolution.serverID] = .empty(.terminal,
                                                               ScriptedCapture.failureStatus(description),
                                                               description)
                output.issues.append(CaptureIssue(severity: .omission,
                                                  scope: kind.displayName,
                                                  message: "reading the tabs of one window failed, \(description)"))
                continue
            }
            let resource = resolveDirectories(value, windowID: windowID)
            let unresolved = resource.tabs.filter { $0.directory == nil }.count
            if unresolved > 0 {
                output.issues.append(CaptureIssue(severity: .omission,
                                                  scope: kind.displayName,
                                                  message: "\(unresolved) tabs in one window did not resolve to a directory"))
            }
            output.resources[resolution.serverID] = WindowResources(kind: .terminal,
                                                                    status: resource.tabs.isEmpty ? .capturedEmpty : .captured,
                                                                    detail: nil,
                                                                    terminal: resource)
            if resource.tabs.contains(where: { $0.directory != nil }) { output.windowsCaptured += 1 }
        }

        output.outcome = "\(output.windowsCaptured) of \(scoped.count) scoped windows yielded a directory"
        return output
    }

    static func resolveDirectories(_ value: ScriptValue, windowID: Int) -> TerminalResource {
        var tabs: [TerminalTabRecord] = []
        for (offset, row) in value.items.enumerated() {
            let fields = row.strings
            let state = fields[safe: 0] ?? "error"
            let tty = fields[safe: 1] ?? ""
            let selected = fields[safe: 2] ?? ""
            guard state == "ok", !tty.isEmpty else {
                tabs.append(TerminalTabRecord(index: offset + 1,
                                             tty: nil,
                                             selected: flag(selected),
                                             directory: nil,
                                             directorySource: nil,
                                             issue: "the tab reported no tty: \(tty)"))
                continue
            }
            let lookup = ProcessLookup.foregroundDirectory(onTTY: tty)
            tabs.append(TerminalTabRecord(index: offset + 1,
                                          tty: tty,
                                          selected: flag(selected),
                                          directory: lookup.directory,
                                          directorySource: lookup.directory == nil ? nil : lookup.method,
                                          issue: lookup.directory == nil ? lookup.method : nil))
        }
        return TerminalResource(scriptWindowID: windowID, tabs: tabs)
    }

    private static func flag(_ value: String) -> Bool? {
        if value == "true" { return true }
        if value == "false" { return false }
        return nil
    }
}
