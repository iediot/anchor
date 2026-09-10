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
    private(set) var copiedAt: Date?
    var accessibilityGranted = Permissions.accessibilityGranted
    var screenRecordingGranted = Permissions.screenRecordingGranted

    // recorded from workspace activation so a menu click never picks anchor's own display
    var lastExternalPID: pid_t? { FocusTracker.shared.lastExternalPID }

    func refreshPermissions() {
        copiedAt = nil
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

    // window evidence is refreshed right before a probe so the two are not minutes apart
    // the destination display the user already selected is carried over, anchor's own
    // focus must never redefine it
    private func refreshWindowEvidence() {
        scan = WindowInspector.scan(preferredOwner: lastExternalPID, pinnedTarget: scan?.target)
    }

    // automation consent is asked for one app at a time and only when its probe is run
    func probe(_ kind: IntegrationKind) async {
        guard !busy.contains(kind) else { return }
        copiedAt = nil
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

        // taken after consent so the scan is as close to the apple event as it can be
        refreshWindowEvidence()
        guard let scan else { return }

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

    // copies whatever is already on screen, it never starts a scan or a probe
    // copiedAt is cleared by anything that changes the panel so the marker cannot go stale
    func copyReport() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(DiagnosticsReport.plainText(self), forType: .string)
        copiedAt = Date()
    }

    // reads stored consent without prompting so the panel can show status on open
    func refreshAutomationStatus() async {
        for app in apps where app.isInstalled && app.kind.usesAppleEvents {
            automation[app.kind] = await ScriptRunner.shared
                .determineAutomationAccess(bundleID: app.kind.bundleID, askUser: false)
        }
    }
}
