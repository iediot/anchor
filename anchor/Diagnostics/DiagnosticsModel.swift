import AppKit
import SwiftUI

@MainActor
@Observable
final class DiagnosticsModel {
    private(set) var scan: WindowScan?
    private(set) var apps: [InstalledApp] = AppCatalog.survey()
    private(set) var automation: [IntegrationKind: AutomationAccess] = [:]
    private(set) var probes: [IntegrationKind: ProbeResult] = [:]
    private(set) var busy: Set<IntegrationKind> = []
    private(set) var scanning = false
    var accessibilityGranted = Permissions.accessibilityGranted
    var screenRecordingGranted = Permissions.screenRecordingGranted

    // recorded from workspace activation so a menu click never picks anchor's own display
    private(set) var lastExternalPID: pid_t?

    // the observer lives as long as the app does so it is never torn down
    private var activationObserver: NSObjectProtocol?

    init() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier != ownPID
                else { return }
                let pid = app.processIdentifier
                MainActor.assumeIsolated { self?.lastExternalPID = pid }
            }
    }

    func refreshPermissions() {
        accessibilityGranted = Permissions.accessibilityGranted
        screenRecordingGranted = Permissions.screenRecordingGranted
        apps = AppCatalog.survey()
    }

    func inspect() {
        scanning = true
        refreshPermissions()
        scan = WindowInspector.scan(preferredOwner: lastExternalPID)
        scanning = false
    }

    // automation consent is asked for one app at a time and only when its probe is run
    func probe(_ kind: IntegrationKind) async {
        guard !busy.contains(kind) else { return }
        guard let app = apps.first(where: { $0.kind == kind }) else { return }
        guard app.isInstalled else {
            probes[kind] = .skipped(kind, "not installed on this machine, untested")
            return
        }
        guard app.isRunning else {
            probes[kind] = .skipped(kind, "not running, anchor does not launch apps to probe them")
            return
        }
        if scan == nil { inspect() }
        guard let scan else { return }

        busy.insert(kind)
        defer { busy.remove(kind) }

        if kind.usesAppleEvents {
            let access = await ScriptRunner.shared.determineAutomationAccess(bundleID: kind.bundleID, askUser: true)
            automation[kind] = access
            guard access == .granted else {
                probes[kind] = .skipped(kind, "automation access \(access.label)")
                return
            }
        }

        switch kind {
        case .safari, .chrome:
            probes[kind] = await BrowserProbe.run(kind, scan: scan)
        case .terminal, .iTerm:
            probes[kind] = await TerminalProbe.run(kind, scan: scan)
        case .pycharm, .clion:
            probes[kind] = await JetBrainsProbe.run(kind, scan: scan)
        case .xcode:
            probes[kind] = await XcodeProbe.run(scan: scan)
        }
    }

    // reads stored consent without prompting so the panel can show status on open
    func refreshAutomationStatus() async {
        for app in apps where app.isInstalled && app.kind.usesAppleEvents {
            automation[app.kind] = await ScriptRunner.shared
                .determineAutomationAccess(bundleID: app.kind.bundleID, askUser: false)
        }
    }
}
