import AppKit

// the real operations, one per supported application
// every address, path and shell word is handed over as an apple event argument to a
// handler, never pasted into script text, and nothing here closes or quits anything
struct LiveRestoreExecutor: RestoreExecutor {
    var environment: LiveRestoreEnvironment

    func requestAutomation(bundleID: String) async -> AutomationAccess {
        await ScriptRunner.shared.determineAutomationAccess(bundleID: bundleID, askUser: true)
    }

    func liveWindows(bundleID: String) -> [LiveWindow] {
        environment.liveWindows(bundleID: bundleID)
    }

    func openBrowserWindow(_ request: BrowserOpenRequest) async -> ExecutionOutcome {
        let addresses = request.tabs.map { tab -> ScriptArgument in
            switch tab.content {
            case .web(let url), .localFile(let url): return .text(url)
            case .blank: return .text("")
            }
        }
        let source = request.app == .safari ? RestoreScripts.safari : RestoreScripts.chrome
        let outcome = await ScriptRunner.shared.runHandler(source,
                                                           handler: RestoreScripts.handler,
                                                           arguments: [.list(addresses),
                                                                       .text(request.selectedTab.map(String.init) ?? "")])
        guard case .value(let value) = outcome else {
            let description = outcome.failureDescription ?? "the application returned no result"
            return .failed("\(request.app.displayName) did not open a window, \(description)")
        }
        let reply = RestoreScripts.parse(value)
        guard reply.state == "ok" else {
            return .failed("\(request.app.displayName) did not open a window, \(reply.error.isEmpty ? "no reason was reported" : reply.error)")
        }

        var items: [String: ItemOutcome] = [:]
        for (offset, tab) in request.tabs.enumerated() {
            let state = reply.itemStates[safe: offset] ?? "the application reported nothing for this tab"
            items[tab.itemID] = state == "ok"
                ? ItemOutcome(state: .opened, detail: nil)
                : ItemOutcome(state: .failed, detail: state)
        }
        let opened = items.values.filter { $0.state == .opened }.count
        return ExecutionOutcome(succeeded: opened > 0,
                                summary: "\(opened) of \(request.tabs.count) tabs opened in a new \(request.app.displayName) window",
                                window: evidence(request.app, reportedID: reply.windowID),
                                items: items)
    }

    func openTerminalSession(_ request: TerminalOpenRequest) async -> ExecutionOutcome {
        // shell text is unavoidable here, so the directory is quoted once and the command
        // only changes directory, it never resumes anything that was running
        let command = "cd -- \(ResourceValidation.singleQuoted(request.directory))"
        let source = request.app == .terminal ? RestoreScripts.terminal : RestoreScripts.iTerm
        let outcome = await ScriptRunner.shared.runHandler(source,
                                                           handler: RestoreScripts.handler,
                                                           arguments: [.text(command)])
        guard case .value(let value) = outcome else {
            let description = outcome.failureDescription ?? "the application returned no result"
            return .failed("\(request.app.displayName) did not open a window, \(description)")
        }
        let reply = RestoreScripts.parse(value)
        guard reply.state == "ok" else {
            return .failed("\(request.app.displayName) did not open a window, \(reply.error.isEmpty ? "no reason was reported" : reply.error)")
        }
        return ExecutionOutcome(succeeded: true,
                                summary: "a new \(request.app.displayName) window was opened at \(request.directory)",
                                window: evidence(request.app, reportedID: reply.windowID),
                                items: [request.itemID: ItemOutcome(state: .opened, detail: nil)])
    }

    // a project is opened through the installed application itself, with a file url as an
    // argument, so no script text and no shell is involved
    func openProject(_ request: ProjectOpenRequest) async -> ExecutionOutcome {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: request.app.bundleID) else {
            return .failed("\(request.app.displayName) is not installed on this mac")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = true
        do {
            _ = try await NSWorkspace.shared.open([URL(fileURLWithPath: request.path)],
                                                  withApplicationAt: appURL,
                                                  configuration: configuration)
            return ExecutionOutcome(succeeded: true,
                                    summary: "\(request.projectName) was handed to \(request.app.displayName)",
                                    window: .none("the application does not report which window it used"),
                                    items: [request.itemID: ItemOutcome(state: .opened, detail: nil)])
        } catch {
            return .failed("\(request.app.displayName) refused to open \(request.projectName): \(error.localizedDescription)")
        }
    }

    // a bounded look for the one window that appeared, never a fixed sleep and never the
    // first window of the application
    func observeNewWindow(bundleID: String,
                          excluding: Set<CGWindowID>,
                          timeout: TimeInterval) async -> WindowEvidence {
        let deadline = Date().addingTimeInterval(timeout)
        var last: [LiveWindow] = []
        while Date() < deadline {
            last = liveWindows(bundleID: bundleID).filter { !excluding.contains($0.id) }
            if last.count == 1, let found = last.first { return .observed(found.id) }
            if last.count > 1 { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        if last.count > 1 {
            return .ambiguous(last.map(\.id), "the application opened more than one window while this item ran")
        }
        return .none("no new window appeared for this application within \(Int(timeout)) seconds")
    }

    // an ide shows a splash or a welcome window first, so anchor waits for the window
    // that actually carries the project rather than taking whatever appeared first
    func awaitProjectWindow(_ request: ProjectOpenRequest,
                            excluding: Set<CGWindowID>,
                            timeout: TimeInterval) async -> WindowEvidence {
        let deadline = Date().addingTimeInterval(timeout)
        var last = "no window has appeared yet"
        while Date() < deadline {
            let resolution = ProjectWindowReadiness.resolve(request: request,
                                                            candidates: liveWindows(bundleID: request.app.bundleID),
                                                            excluding: excluding,
                                                            accessibilityGranted: environment.accessibilityGranted)
            switch resolution {
            case .ready(let id, let reason):
                return .corroborated(id, reason)
            case .ambiguous(let ids, let reason):
                return .ambiguous(ids, reason)
            case .unavailable(let reason):
                return .none(reason)
            case .notYet(let reason):
                last = reason
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return .none("\(last), and anchor stopped waiting after \(Int(timeout)) seconds rather than placing a startup window")
    }

    func place(windowID: CGWindowID, appKitFrame: CGRect) async -> PlacementOutcome {
        WindowPlacement.place(windowID: windowID, appKitFrame: appKitFrame)
    }

    // an id an app reports is usable only where anchor has established it is the window
    // server number, everything else is identified by observation instead
    private func evidence(_ kind: IntegrationKind, reportedID: String) -> WindowEvidence {
        guard WindowIdentity.windowNumberApps.contains(kind),
              let value = Int(reportedID), value > 0, value <= Int(CGWindowID.max)
        else { return .none("this application does not report a window server id anchor can check") }
        let id = CGWindowID(value)
        guard liveWindows(bundleID: kind.bundleID).contains(where: { $0.id == id }) else {
            return .none("the application named window \(id), which the window server does not list for it")
        }
        return .reportedByApp(id)
    }
}

// the scripts, each one a single handler called with real arguments
enum RestoreScripts {
    static let handler = "anchoropen"

    struct Reply {
        var state: String
        var windowID: String
        var error: String
        var itemStates: [String]
    }

    static func parse(_ value: ScriptValue) -> Reply {
        let fields = value.items
        func field(_ index: Int) -> ScriptValue? {
            fields.indices.contains(index) ? fields[index] : nil
        }
        return Reply(state: field(0)?.text ?? "error",
                     windowID: field(1)?.text ?? "",
                     error: field(2)?.text ?? "",
                     itemStates: field(3)?.strings ?? [])
    }

    static let safari = """
    on anchoropen(pvurls, pvselected)
        tell application "Safari"
            set pvbefore to {}
            repeat with pvw in windows
                try
                    set end of pvbefore to (id of pvw) as text
                end try
            end repeat
            set pvfirst to item 1 of pvurls
            try
                if pvfirst is "" then
                    make new document
                else
                    make new document with properties {URL:pvfirst}
                end if
            on error pverr
                return {"error", "", pverr, {}}
            end try
            set pvtarget to missing value
            repeat with pvw in windows
                set pvthis to ""
                try
                    set pvthis to (id of pvw) as text
                end try
                if pvthis is not "" and pvbefore does not contain pvthis then set pvtarget to pvw
            end repeat
            if pvtarget is missing value then return {"error", "", "the new window could not be identified", {}}
            set pvresults to {"ok"}
            repeat with pvindex from 2 to (count of pvurls)
                set pvurl to item pvindex of pvurls
                try
                    if pvurl is "" then
                        make new tab at end of tabs of pvtarget
                    else
                        make new tab at end of tabs of pvtarget with properties {URL:pvurl}
                    end if
                    set end of pvresults to "ok"
                on error pverr
                    set end of pvresults to pverr
                end try
            end repeat
            set pvwinid to ""
            try
                set pvwinid to (id of pvtarget) as text
            end try
            if pvselected is not "" then
                try
                    set current tab of pvtarget to tab (pvselected as integer) of pvtarget
                end try
            end if
            return {"ok", pvwinid, "", pvresults}
        end tell
    end anchoropen
    """

    static let chrome = """
    on anchoropen(pvurls, pvselected)
        tell application "Google Chrome"
            set pvresults to {}
            try
                set pvtarget to make new window
            on error pverr
                return {"error", "", pverr, {}}
            end try
            set pvfirst to item 1 of pvurls
            try
                if pvfirst is not "" then set URL of active tab of pvtarget to pvfirst
                set end of pvresults to "ok"
            on error pverr
                set end of pvresults to pverr
            end try
            repeat with pvindex from 2 to (count of pvurls)
                set pvurl to item pvindex of pvurls
                try
                    if pvurl is "" then
                        make new tab at end of tabs of pvtarget
                    else
                        make new tab at end of tabs of pvtarget with properties {URL:pvurl}
                    end if
                    set end of pvresults to "ok"
                on error pverr
                    set end of pvresults to pverr
                end try
            end repeat
            if pvselected is not "" then
                try
                    set active tab index of pvtarget to (pvselected as integer)
                end try
            end if
            return {"ok", "", "", pvresults}
        end tell
    end anchoropen
    """

    static let terminal = """
    on anchoropen(pvcommand)
        tell application "Terminal"
            set pvbefore to {}
            repeat with pvw in windows
                try
                    set end of pvbefore to (id of pvw) as text
                end try
            end repeat
            try
                do script pvcommand
            on error pverr
                return {"error", "", pverr, {}}
            end try
            set pvtarget to ""
            repeat with pvw in windows
                set pvthis to ""
                try
                    set pvthis to (id of pvw) as text
                end try
                if pvthis is not "" and pvbefore does not contain pvthis then set pvtarget to pvthis
            end repeat
            if pvtarget is "" then return {"error", "", "the new window could not be identified", {}}
            return {"ok", pvtarget, "", {"ok"}}
        end tell
    end anchoropen
    """

    // unverified, iterm2 is not installed on the machine this was written on
    static let iTerm = """
    on anchoropen(pvcommand)
        tell application "iTerm"
            try
                set pvtarget to (create window with default profile)
            on error pverr
                return {"error", "", pverr, {}}
            end try
            try
                tell current session of pvtarget
                    write text pvcommand
                end tell
            on error pverr
                return {"error", "", pverr, {}}
            end try
            return {"ok", "", "", {"ok"}}
        end tell
    end anchoropen
    """
}
