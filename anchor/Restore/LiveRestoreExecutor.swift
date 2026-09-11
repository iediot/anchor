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

    // launchservices calls back when the application has taken the open event, and an ide
    // that is still starting can hold that callback for as long as it likes, so this is
    // the one wait in a reopen with no bound of its own
    static let launchAcknowledgement: TimeInterval = 25

    private enum Handover {
        case acknowledged
        case unacknowledged
        case refused(String)
    }

    // a project is opened through the installed application itself, with a file url as an
    // argument, so no script text and no shell is involved
    // the open is asked for exactly once, whatever the acknowledgement does
    func openProject(_ request: ProjectOpenRequest) async -> ExecutionOutcome {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: request.app.bundleID) else {
            return .failed("\(request.app.displayName) is not installed on this mac")
        }
        let appName = request.app.displayName
        let seconds = Int(Self.launchAcknowledgement)
        switch await hand(path: request.path, to: appURL, appName: appName) {
        case .refused(let reason):
            return .failed(reason)
        case .acknowledged:
            return ExecutionOutcome(succeeded: true,
                                    summary: "\(request.projectName) was handed to \(appName)",
                                    window: .none("the application does not report which window it used"),
                                    items: [request.itemID: ItemOutcome(state: .opened, detail: nil)])
        case .unacknowledged:
            // the launch itself carries on, anchor only stopped waiting to be told about it
            guard isRunning(bundleID: request.app.bundleID) else {
                return .failed("\(appName) did not acknowledge opening \(request.projectName) within \(seconds) seconds and is not running. anchor did not ask again")
            }
            let detail = "handed over, \(appName) did not acknowledge within \(seconds) seconds"
            return ExecutionOutcome(succeeded: true,
                                    summary: "\(request.projectName) was handed to \(appName), which is running but did not acknowledge within \(seconds) seconds. anchor did not ask again and went on to look for the window",
                                    window: .none("the application never acknowledged the open, so it named no window"),
                                    items: [request.itemID: ItemOutcome(state: .opened, detail: detail)])
        }
    }

    // the open runs against a deadline. losing the race abandons the acknowledgement only,
    // it never cancels the launch and never asks for a second one
    // with no path this opens the application itself, which is the whole of a plain open
    private func hand(path: String?, to appURL: URL, appName: String) async -> Handover {
        await withTaskGroup(of: Handover?.self) { group -> Handover in
            group.addTask {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                configuration.addsToRecentItems = true
                do {
                    if let path {
                        _ = try await NSWorkspace.shared.open([URL(fileURLWithPath: path)],
                                                              withApplicationAt: appURL,
                                                              configuration: configuration)
                    } else {
                        _ = try await NSWorkspace.shared.openApplication(at: appURL,
                                                                         configuration: configuration)
                    }
                    return .acknowledged
                } catch {
                    return .refused("\(appName) refused the open: \(error.localizedDescription)")
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(Self.launchAcknowledgement))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .unacknowledged
        }
    }

    // an application anchor has no adapter for, resolved by its saved identifier and opened
    // through the same launch call a project uses, with the saved item when there is one
    // it is opened once, and it is never asked to open anything anchor guessed
    func openApplication(_ request: AppOpenRequest) async -> ExecutionOutcome {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: request.bundleID) else {
            return .failed("\(request.appName) is not installed on this mac")
        }
        // a path saved with the window, checked again here because a preview can be old
        var path = request.path
        if let candidate = path, !FileManager.default.fileExists(atPath: candidate) {
            path = nil
        }
        let seconds = Int(Self.launchAcknowledgement)
        let opened = path == nil
            ? "\(request.appName) was opened; its previous contents are unavailable"
            : "\(request.appName) was opened with the item this window had open"
        switch await hand(path: path, to: appURL, appName: request.appName) {
        case .refused(let reason):
            return .failed(reason)
        case .acknowledged:
            return ExecutionOutcome(succeeded: true,
                                    summary: opened,
                                    window: .none("anchor did not wait for a window, so this application named none"),
                                    items: [request.itemID: ItemOutcome(state: .opened, detail: nil)])
        case .unacknowledged:
            guard isRunning(bundleID: request.bundleID) else {
                return .failed("\(request.appName) did not open within \(seconds) seconds and is not running. anchor did not ask again")
            }
            return ExecutionOutcome(succeeded: true,
                                    summary: "\(opened), though it did not acknowledge within \(seconds) seconds. anchor did not ask again",
                                    window: .none("anchor did not wait for a window, so this application named none"),
                                    items: [request.itemID: ItemOutcome(state: .opened, detail: "handed over, not acknowledged")])
        }
    }

    private func isRunning(bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { !$0.isTerminated }
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
        let result = WindowPlacement.place(windowID: windowID, appKitFrame: appKitFrame)
        guard !result.succeeded,
              LayoutMapping.finite(appKitFrame), appKitFrame.width > 0, appKitFrame.height > 0,
              let owner = WindowPlacement.serverFrame(ofWindow: windowID),
              NSRunningApplication(processIdentifier: owner.pid)?.bundleIdentifier == IntegrationKind.terminal.bundleID
        else { return result }

        // terminal also exposes bounds by window id when accessibility refuses a move
        let rect = ScreenGeometry.windowServer(fromAppKit: appKitFrame)
        let reply = await ScriptRunner.shared.runHandler(
            RestoreScripts.terminalPlacement, handler: RestoreScripts.handler,
            arguments: [.integer(Int(windowID)), .integer(Int(rect.minX.rounded())),
                        .integer(Int(rect.minY.rounded())), .integer(Int(rect.maxX.rounded())),
                        .integer(Int(rect.maxY.rounded()))])
        guard case .value(let value) = reply, value.text == "ok" else {
            return .refused("\(result.label); terminal bounds fallback: \(reply.failureDescription ?? "the addressed window refused its bounds")")
        }
        for _ in 0..<10 {
            guard let current = WindowPlacement.serverFrame(ofWindow: windowID), current.pid == owner.pid else {
                return .unavailable("the terminal window disappeared or changed owner during placement")
            }
            let actual = ScreenGeometry.appKit(fromWindowServer: current.frame)
            // terminal rounds its dimensions to whole character cells
            if abs(actual.minX - appKitFrame.minX) < 3 && abs(actual.minY - appKitFrame.minY) < 3 {
                return .applied(requested: appKitFrame, actual: actual,
                                adjustment: LayoutMapping.describeAdjustment(requested: appKitFrame, actual: actual))
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return .refused("terminal accepted bounds but its window did not settle at the requested position")
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
            try
                set pvopened to do script pvcommand
            on error pverr
                return {"error", "", pverr, {}}
            end try
            repeat 20 times
                try
                    set pvtty to tty of pvopened
                    if pvtty is not "" then
                        repeat with pvw in windows
                            repeat with pvtab in tabs of pvw
                                if (tty of pvtab) is pvtty then
                                    return {"ok", (id of pvw) as text, "", {"ok"}}
                                end if
                            end repeat
                        end repeat
                    end if
                end try
                delay 0.1
            end repeat
            return {"ok", "", "the shell opened but its window could not be identified", {"ok"}}
        end tell
    end anchoropen
    """

    static let terminalPlacement = """
    on anchoropen(pvid, pvleft, pvtop, pvright, pvbottom)
        if application "Terminal" is not running then return "unavailable"
        tell application "Terminal"
            if not (exists window id pvid) then return "unavailable"
            set bounds of window id pvid to {pvleft, pvtop, pvright, pvbottom}
            return "ok"
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
